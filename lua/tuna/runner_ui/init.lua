-- lua/tuna/runner_ui/init.lua
--
-- The runner results UI. It owns a set of windows (a testcase selector plus four
-- detail panes: stdout/expected/stdin/stderr), keeps them in sync with the
-- `TCRunner`'s `tcdata`, and wires the interactive keymaps (run again, stop,
-- view in a bigger popup, toggle diff, close).
--
-- The actual window geometry is delegated to an "interface" module — `popup`
-- (floats) or `split` (real splits) — selected by `runner_ui.interface`. This
-- module is interface-agnostic: it only touches `windows[name].bufnr/winid`.
--
-- All displayed content lives in the runner's `tcdata`, so windows are never hidden
-- and restored: closing tears the UI down, and showing rebuilds it and re-renders
-- from `tcdata`.

local api = vim.api
local utils = require("tuna.utils")
local surface = require("tuna.surface")
local diff = require("tuna.diff")
local layout_util = require("tuna.runner_ui.layout")
local SKIP = require("tuna.runner.core").SKIP

local M = {}

-- The panes the build step's sources are shown in, in the order they are handed out. The
-- solution keeps the Errors pane it has always had, and every helper the run compiles takes
-- the next pane the grid is not already using.
local BUILD_PANES = { "se", "so", "eo", "si" }

---Put `panes` where the Errors pane is, one above the other, leaving the rest of the grid
---alone. A build step of several sources reads as a column of them, in the cell the
---compiler's words were already in.
---@param layout table|string
---@param panes string[]
---@return table|string
local function stack_into(layout, panes)
    if type(layout) == "string" then
        if layout ~= "se" then
            return layout
        end
        local stack = {}
        for _, name in ipairs(panes) do
            stack[#stack + 1] = { 1, name }
        end
        return stack
    end
    local out = {}
    for i, entry in ipairs(layout) do
        out[i] = { entry[1], stack_into(entry[2], panes) }
    end
    return out
end

-- Which runner each pane buffer belongs to (`M.owner_of`). A `:Tuna` command typed in a pane
-- is about the solution that pane is showing, and this answers "whose pane is this?" without
-- asking every mode module for its runners. Cleared when a UI goes: a pane buffer is wiped
-- with its window, and an entry left behind would point a command at a runner that is gone.
---@type table<integer, table>
local pane_owner = {}

local ns = api.nvim_create_namespace("tuna_runner_ui")
-- Its own namespace, so the diff can be painted and cleared without touching the
-- selector's status highlights.
local diff_ns = api.nvim_create_namespace("tuna_runner_diff")

--- How long after the last keystroke the expensive answers are worked out (ms): what
--- the panes really hold, and the diff marks over them.
local SETTLE_DELAY = 120
local augroup_counter = 0

-- The four detail panes a viewer can enlarge, and the friendly names used in
-- selector rows / viewer titles.
local detail_windows = { "so", "eo", "si", "se" }

---@class tuna.RunnerUI
---@field runner tuna.TCRunner
---@field config table
---@field interface table popup or split interface
---@field windows table<string, { bufnr: integer, winid: integer, title: string }>
---@field ui_visible boolean
---@field update_windows boolean redraw the selector on next update
---@field update_details boolean redraw the detail panes on next update
---@field update_testcase integer? selected testcase (selector line)
---@field diff_view boolean
---@field viewer_winid integer?
---@field viewer_content string? which detail window the viewer is showing
---@field make_viewer_visible boolean open the viewer on the next update
---@field restore_winid integer?
---@field latest_compile_token integer? start time of the last auto-shown compile failure
local RunnerUI = {}
RunnerUI.__index = RunnerUI

---Create a runner UI for `runner` (does not show it yet).
---@param runner tuna.TCRunner
---@return tuna.RunnerUI?
function M.new(runner)
    local interface
    local kind = runner.config.runner_ui.interface
    if kind == "popup" then
        interface = require("tuna.runner_ui.popup")
    elseif kind == "split" then
        interface = require("tuna.runner_ui.split")
    else
        utils.notify("runner_ui: unknown interface " .. vim.inspect(kind) .. ".")
        return nil
    end

    return setmetatable({
        runner = runner,
        config = runner.config,
        interface = interface,
        windows = {},
        ui_visible = false,
        update_windows = false,
        update_details = false,
        update_testcase = nil,
        -- Whether the selector has been moved by hand. Until it has, the UI picks the row
        -- worth looking at (`follow_row`); afterwards the choice is the user's and nothing
        -- moves it out from under them.
        user_moved = false,
        diff_view = false,
        viewer_winid = nil,
        viewer_content = nil,
        make_viewer_visible = false,
        restore_winid = nil,
        -- Testcase edits typed into the Input/Expected panes but not yet written,
        -- keyed by testcase number so they survive moving to another row (and, in
        -- run-all, are shared by every solution's row for that testcase).
        pending = {},
    }, RunnerUI)
end

---@private
---Normalise a mapping spec (string or list) to a list of keys. Anything else —
---including the `false` a user writes to disable a mapping — is no keys, not an
---error when the UI opens.
local function as_list(maps)
    if type(maps) == "string" then
        return { maps }
    end
    return type(maps) == "table" and maps or {}
end

-- Every abbreviation of the commands that would close a pane (or the editor) out from
-- under an unsaved testcase edit. `:wq`/`:x` are deliberately absent: they write
-- first, which through the pane's `BufWriteCmd` *is* saving the testcase.
--- The commands that close *this window*: a `:q` in a pane is a request to put the
--- results UI away, so the UI closes itself rather than letting one pane be torn out
--- of the grid. Kept apart from the quit-everything commands below, which mean what
--- they say and are only intercepted when an unsaved edit would be lost.
local QUIT_COMMANDS = {}
local function quit_cmds(names, scope, write)
    for _, name in ipairs(names) do
        QUIT_COMMANDS[name] = { scope = scope, write = write }
    end
end
quit_cmds({ "q", "qu", "qui", "quit", "clo", "clos", "close" }, "window", false)
quit_cmds({ "wq", "x", "xi", "xit", "exi", "exit" }, "window", true)
quit_cmds({ "qa", "qal", "qall", "quita", "quitall" }, "all", false)
quit_cmds({ "wqa", "wqal", "wqall", "xa", "xal", "xall" }, "all", true)

---@private
---Whether a typed command line is one of those — what it closes, whether it writes
---first, and whether it carried a `!`.
---@param line string
---@return { scope: "window"|"all", write: boolean }? nil when it isn't a quit command
---@return boolean forced
local function quit_command(line)
    local cmd, bang = line:match("^%s*(%a+)(!?)%s*$")
    if cmd and QUIT_COMMANDS[cmd] then
        return QUIT_COMMANDS[cmd], bang == "!"
    end
    return nil, false
end

---@private
---The testcase index under the selector cursor (1:1 with `tcdata`; the Compile
---pseudo-testcase, when present, is row 1).
---Whether `winid` is one of this UI's panes.
---@param winid integer
---@return boolean
function RunnerUI:owns_win(winid)
    for _, w in pairs(self.windows) do
        if w.winid == winid then
            return true
        end
    end
    return false
end

function RunnerUI:cursor_tc()
    if not (self.windows.tc and api.nvim_win_is_valid(self.windows.tc.winid)) then
        return 1
    end
    return api.nvim_win_get_cursor(self.windows.tc.winid)[1]
end

--------------------------------------------------------------------------------
-- Inline testcase editing
--
-- The Input and Expected Output panes are ordinary, always-modifiable buffers:
-- there is no "start editing" key to learn, and nothing reaches disk until `:w`
-- (`BufWriteCmd`), exactly as a file buffer behaves. Edits you haven't written are
-- held per testcase number in `self.pending`, so moving to another row — or closing
-- and reopening the UI — doesn't discard them, and a row whose pane is dirty is not
-- overwritten by results landing underneath it.
--------------------------------------------------------------------------------

---@private
---The row currently shown in the detail panes.
---@return table?
function RunnerUI:current_row()
    return self.runner.tcdata[self.update_testcase or 1]
end

---@private
---Whether a pane is one the user types into — either an editable testcase pane or
---one the mode owns (interactive's live Input). Such a pane keeps its letters:
---the plain-key mappings (close, and the selector's actions) are not bound on it.
---@param name string
---@return boolean
function RunnerUI:writable_pane(name)
    if name ~= "si" and name ~= "eo" then
        return false
    end
    if self.runner.editable_testcases then
        return true
    end
    return self.runner.owns_pane ~= nil and self.runner:owns_pane(name)
end

---@private
---Colour the border and title of the panes that can be typed into, so the two you can
---edit are told apart from the four you can only read without having to try one. The
---interfaces don't know which panes those are (it depends on the runner), so this is
---applied over their windows afterwards rather than threaded through `init_ui`.
---Borders and titles only exist on floats, so the split interface simply has none.
function RunnerUI:accent_editable_panes()
    local hl = self.config.runner_ui.editable_border_highlight
    if not hl then
        return
    end
    -- Nothing on the build step is typed into, whatever its panes are on a testcase row, so
    -- the accent is off there — and taken off again, since a pane the re-tiling left open
    -- keeps the colour it had.
    local building = self:build_assignment(self:current_row()) ~= nil
    for name, w in pairs(self.windows) do
        if w.winid and api.nvim_win_is_valid(w.winid) then
            local cfg = api.nvim_win_get_config(w.winid)
            if cfg.border and cfg.border ~= "none" then
                if not building and self:writable_pane(name) then
                    utils.set_border_highlight(w.winid, hl, "TunaEditableBorder")
                    -- A title given as `{ { text, group } }` chunks carries its own
                    -- highlight, so the name is accented too — the border alone is easy to
                    -- miss on a pane sitting next to another pane's border. It uses the
                    -- *derived* group, not the configured one: the title is painted onto
                    -- the border, and a group with no background of its own falls back to a
                    -- different one there, leaving the name sitting in a patch that doesn't
                    -- match the frame around it. The derived group carries the border's
                    -- background explicitly, so the two are the same colour by construction.
                    pcall(api.nvim_win_set_config, w.winid, {
                        title = { { w.title, "TunaEditableBorder" } },
                        title_pos = "center",
                    })
                else
                    utils.set_border_highlight(w.winid, self.config.floating_border_highlight)
                    pcall(api.nvim_win_set_config, w.winid, { title = w.title, title_pos = "center" })
                end
            end
        end
    end
end

---@private
---Render `{ label, value }` pairs into colon-free, column-aligned lines.
---@param entries string[][]
---@return string[]
local function align(entries)
    local width = 0
    for _, e in ipairs(entries) do
        width = math.max(width, #e[1])
    end
    local lines = {}
    for _, e in ipairs(entries) do
        lines[#lines + 1] = e[1] == "" and "" or string.format("%-" .. width .. "s  %s", e[1], e[2])
    end
    return lines
end

---@private
---The key legend, as the two halves the UI is actually divided into: what the panes
---you type into do, and what the ones you only read do. Which pane you are standing in
---is the thing that decides what a key means here, so the legend is organised the same
---way — and each half is shown in the colour its panes wear, so no cross-referencing
---is needed to work out which is which.
---@return string[] editable, string[] readonly
function RunnerUI:legend_sections()
    local m = self.config.runner_ui.mappings
    local function keys(action)
        return table.concat(as_list(m[action] or {}), " / ")
    end
    local switch = table.concat(as_list(self.config.switch_window_keys or {}), " ")

    local editable = {}
    if self.runner.editable_testcases then
        vim.list_extend(editable, {
            { "edit", "just type, these are ordinary buffers" },
            { "save + re-run", ":w" },
            { "", "" },
        })
    end
    vim.list_extend(editable, {
        { "switch pane", switch .. "  (also from insert mode)" },
        { "close", keys("close") .. "  (normal mode)" },
        { "this legend", keys("help") },
        { "", "" },
        { "everything else", "Vim's own, d deletes, r replaces, u undoes" },
    })

    local readonly = align({
        { "run again", keys("run_again") },
        { "run all again", keys("run_all_again") },
        -- Re-running uses the build and the file already on disk; `:Tuna run` is what
        -- saves first. The label is a space rather than empty because `align` renders
        -- an empty one as a blank separator line, and the text is kept short so the
        -- column does not widen past the pane-switch row above it.
        { " ", "neither saves the file" },
        { "", "" }, -- the note reads as a note, not as the row below it
        { "stop", keys("stop") },
        { "stop all", keys("stop_all") },
        { "toggle diff", keys("toggle_diff") },
        { "view output / expected", keys("view_stdout") .. "  " .. keys("view_output") },
        { "view input / errors", keys("view_input") .. "  " .. keys("view_stderr") },
        { "", "" },
        { "new testcase", keys("add_testcase") },
        { "delete testcase", keys("delete_testcase") },
        { "lift out marked cases", keys("split_testcase") },
        { "undo delete", keys("undo_delete") },
        { "", "" },
        { "switch pane", switch },
        { "close", keys("close") },
        { "this legend", keys("help") },
    })
    return align(editable), readonly
end

---@private
---Settle the one thing a save cannot read off the panes, then do it.
---
---Everything else a `:w` needs to know is on screen: it stores what the panes show, and
---it stores the testcase even when both are empty — an empty testcase is a testcase,
---and removing one is `x`, which is one key and undoable. So there is nothing to ask
---about an empty *input*: for an input, empty and absent are the same thing.
---
---An empty **answer** is the exception, and the only one. Absent means the testcase is
---not judged (the verdict is `DONE`); present and empty means the solution must print
---nothing, and one that prints something is `WRONG`. The panes look identical either
---way, so a save that would turn a real answer into an empty one asks which was meant.
---
---It asks **only then**. An answer that is already absent, or already empty, is not
---changing, so it goes on meaning what it meant — which is what keeps a first save
---silent and keeps re-saving a testcase from asking the same question again.
---@param tcnum integer
---@param proceed fun(expect_empty_output: boolean?)
function RunnerUI:with_answer_settled(tcnum, proceed)
    local _, expected = self:edited_text(tcnum)
    if expected ~= "" then
        proceed(false)
        return
    end
    local rows = self.runner:rows_for(tcnum)
    local tc = rows[1] and self.runner.tcdata[rows[1]]
    local stored = tc and tc.expected
    if stored == nil or stored == "" then
        proceed(stored == "") -- unchanged: it goes on meaning what it already meant
        return
    end

    -- Captured before the schedule below, and used as the window "Keep editing" returns
    -- to: the pane the `:w` was typed in.
    local back_to = api.nvim_get_current_win()
    -- Opened *out* of the write command rather than inside it. A float entered from a
    -- `BufWriteCmd` does not keep the focus: Vim restores the window the command ran in
    -- as it finishes the `:w`, which would leave the menu on screen with the cursor
    -- still in the pane behind it and no way to answer without reaching for the mouse.
    vim.schedule(function()
        require("tuna.widgets").menu(
            { "Don't specify output", "Expect empty output", "Keep editing" },
            "the answer to testcase " .. tcnum .. " is empty",
            function(idx)
                if idx == 1 or idx == 2 then
                    proceed(idx == 2)
                end
            end,
            back_to,
            function() end
        )
    end)
end

---@private
---How a set of testcase numbers is named in a prompt's title.
---@param nums integer[]
---@return string
local function testcase_label(nums)
    return #nums == 1 and ("testcase " .. nums[1]) or ("testcases " .. table.concat(nums, ", "))
end

---@private
---The three answers to "this would throw away an unsaved edit", for whichever action
---would. One list, so closing and re-running cannot drift apart: each answer names the
---outcome it produces, and the third is `Keep editing` rather than `Cancel` — what you
---get, rather than what did not happen, and the same words the empty-save prompt uses
---for the same answer. It is also what a dismissal gives.
---@param what string the action, e.g. "close" or "re-run all"
---@return string[]
local function unsaved_items(what)
    return { "Save and " .. what, "Discard and " .. what, "Keep editing" }
end

---@private
---Close the UI, asking first when testcase edits would be thrown away. The prompt is
---a float like every other tuna dialog, and it is the only one in this flow: routine
---editing never asks anything.
---@param torn boolean? the windows are already gone (a `:q` on one pane)
---@param on_closed fun()? run once the UI is actually closed — how a `:qa` that was
---cancelled to ask about an edit gets to finish afterwards. Not run on "Keep editing":
---the answer there is that the command should not happen.
function RunnerUI:request_close(torn, on_closed)
    if not self:has_pending() then
        self:delete()
        if on_closed then
            on_closed()
        end
        return
    end
    local nums = self:unsaved_testcases()
    -- A `:q` on one pane has already left a hole in the grid — Neovim closes the window
    -- before `WinClosed` fires, so there is no asking first. Put the grid back *now*,
    -- before the prompt, so the question is posed over an intact UI instead of over a
    -- gap where the pane being edited used to be. `pending` lives on this object, so
    -- the edit comes back with it, and every answer works the same from here.
    local was_in = api.nvim_get_current_win()
    if torn then
        self:delete()
        self:show_ui()
        was_in = nil
    end
    -- Where "Keep editing" puts you back. Not `restore_winid` — that is the *code*
    -- buffer the runner was launched from, i.e. behind the UI, which is the one place
    -- you were certainly not: keeping the edit means going back to the pane holding
    -- it, or failing that the selector.
    local back_to = was_in
    if not (back_to and api.nvim_win_is_valid(back_to) and back_to ~= self.viewer_winid) then
        for _, name in ipairs({ "si", "eo", "tc" }) do
            local w = self.windows[name]
            if w and w.winid and api.nvim_win_is_valid(w.winid) then
                back_to = w.winid
                break
            end
        end
    end

    -- Dismissing the prompt keeps the UI (and the edit) as it is, exactly like
    -- choosing "Keep editing" — the safe answer is the one a stray Esc gives.
    require("tuna.widgets").menu(
        unsaved_items("close"),
        "unsaved " .. testcase_label(nums),
        function(idx)
            if idx == 1 then
                self:save_all_pending()
                self:delete()
            elseif idx == 2 then
                self:discard_pending()
                self:delete()
            end
            if on_closed and idx ~= 3 then
                on_closed()
            end
        end,
        back_to,
        function() end
    )
end

---@private
---Where the rows and the disk disagree, from a single read. The results UI keeps its
---rows across a re-run — that is what makes it a results view rather than a fresh
---load — so anything that touches the testcase files behind its back (another Neovim,
---`:Tuna clean`, a checkout, a plain `rm`) leaves rows describing a state that is no
---longer there. A fresh `:Tuna run` reloads from disk and the question never arises.
---
---Two kinds of disagreement, and they have different answers. **Missing**: the
---testcase is gone, and the row holds the only copy of its text, so the user decides.
---**Changed**: the file is still there and says something else, and the file is the
---truth while the row is a cache of it, so it is simply reloaded.
---
---Three kinds of row legitimately have no file and are neither: the `bare` row of a
---run with nothing to test, a row added with `n` and never written, and one whose
---unwritten edit is still pending — all of them are testcases being *written*, not
---testcases that drifted. A pending row is excluded from `changed` for the stronger
---reason too: reloading it would throw the edit away.
---@param tcnum integer? only this testcase
---@return integer[] missing ascending
---@return integer[] changed ascending
---@return table<integer, table> disk what was read, so a caller need not read it again
function RunnerUI:disk_drift(tcnum)
    if not self.runner.editable_testcases or self.runner.preloaded then
        return {}, {}, {}
    end
    local ok, disk = pcall(require("tuna.testcases").buf_get_testcases, self.runner:edit_bufnr())
    if not ok then
        return {}, {}, {}
    end
    local seen, missing, changed = {}, {}, {}
    for _, tc in ipairs(self.runner.tcdata) do
        local n = tc.tcnum
        local considered = self.runner:row_editable(tc)
            and not tc.bare
            and not self.pending[n]
            and not seen[n]
            and (tcnum == nil or n == tcnum)
        if considered then
            seen[n] = true
            local d = disk[n]
            if d == nil then
                missing[#missing + 1] = n
            elseif (d.input or "") ~= tc.stdin or d.output ~= tc.expected then
                changed[#changed + 1] = n
            end
        end
    end
    table.sort(missing)
    table.sort(changed)
    return missing, changed, disk
end

---@private
---Write each missing row back to disk. To its own number if that is still free, else
---to the lowest free one: a testcase created since the row went missing would
---otherwise be overwritten by an older one the UI happened to still be holding. The
---row is renumbered with it, so what is on screen keeps naming what is on disk.
---
---Deliberately not `runner:save_testcase`, which re-runs what it saves: the caller is
---about to run anyway, and running each row twice is both slower and confusing to
---watch.
---@param nums integer[]
function RunnerUI:restore_missing(nums)
    local testcases = require("tuna.testcases")
    local bufnr = self.runner:edit_bufnr()
    local ok, disk = pcall(testcases.buf_get_testcases, bufnr)
    disk = ok and disk or {}
    -- Every number already spoken for: what is on disk now, plus the rows that are not
    -- themselves being restored.
    local restoring, used = {}, {}
    for _, n in ipairs(nums) do
        restoring[n] = true
    end
    for n in pairs(disk) do
        used[n] = true
    end
    for _, tc in ipairs(self.runner.tcdata) do
        if type(tc.tcnum) == "number" and not restoring[tc.tcnum] then
            used[tc.tcnum] = true
        end
    end

    local moved = {}
    for _, n in ipairs(nums) do
        local rows = self.runner:rows_for(n)
        local tc = rows[1] and self.runner.tcdata[rows[1]]
        if tc then
            local target = n
            if used[target] then
                target = 0
                while used[target] do
                    target = target + 1
                end
                moved[#moved + 1] = n .. " as " .. target
            end
            used[target] = true
            local written =
                pcall(testcases.buf_save_testcase, bufnr, target, tc.stdin or "", tc.expected or "", tc.expected == "")
            if written then
                for _, i in ipairs(rows) do
                    self.runner.tcdata[i].tcnum = target
                end
            else
                utils.notify("could not restore testcase " .. n .. ".", "WARN")
            end
        end
    end
    if #moved > 0 then
        utils.notify("restored testcase " .. table.concat(moved, ", ") .. ", the original number was taken.", "WARN")
    end
    self.update_windows = true
end

---@private
---Run `proceed`, but reconcile the rows with the disk first, so nothing is run against
---a testcase that is not what the file says any more.
---
---A **changed** testcase is reloaded outright: the file is the truth and the row is a
---cache of it, so there is nothing to decide — this is what a fresh `:Tuna run` would
---have done, and running the stale text instead would report a verdict for input the
---user has already replaced. It is said once rather than shown, since it is an event
---and not a state: the rows it happened to are on screen from then on.
---
---A **missing** testcase is the one the user has to answer, because the row is the
---last place its text exists and dropping it is not undoable. `Discard` only discards:
---the row being re-run may be the one going away, so a label promising a re-run could
---not keep it.
---@param tcnum integer? only care about this testcase (nil: any drifted row)
---@param what string the action, for the prompt's options
---@param proceed fun()
function RunnerUI:with_disk_settled(tcnum, what, proceed)
    local nums, changed, disk = self:disk_drift(tcnum)
    if #changed > 0 then
        self.runner:sync_rows(changed, disk)
        self.update_windows = true
        utils.notify(
            "reloaded testcase" .. (#changed > 1 and "s " or " ") .. table.concat(changed, ", ")
                .. " from disk, changed since the last run.",
            "INFO"
        )
    end
    if #nums == 0 then
        if #changed > 0 then
            self:update_ui()
        end
        proceed()
        return
    end
    local label = testcase_label(nums)
    -- `Discard` is not "discard and re-run": the row being re-run may be the one going
    -- away, and then there is nothing left to run — a promise the label cannot keep. So
    -- it does exactly what it says, drops the rows and stops, and the re-run is one
    -- keypress away once the UI says the truth. Dismissing is `Stop`, which changes
    -- nothing at all.
    require("tuna.widgets").menu(
        { "Restore and " .. what, "Discard", "Stop" },
        label .. " no longer on disk",
        function(idx)
            if idx == 1 then
                self:restore_missing(nums)
                -- Rendered here rather than left to `proceed`, which renumbering rows
                -- does not oblige to happen.
                self:update_ui()
                proceed()
            elseif idx == 2 then
                for _, n in ipairs(nums) do
                    self.pending[n] = nil
                    self.runner:remove_testcase_rows(n)
                end
                self.update_testcase = nil
                self.update_windows = true
                self:update_ui()
            end
        end,
        api.nvim_get_current_win(),
        function() end
    )
end

---Run `proceed`, but settle any unsaved edit it would silently throw away first.
---Re-running a testcase you have edited but not written would feed the *old* input to
---the solution and then report a verdict for text that is no longer the text on
---screen — so ask, with the same three answers as closing does.
---@param tcnum integer? only care about this testcase (nil: any unsaved edit at all)
---@param what string the action each answer names, e.g. "re-run all"
---@param proceed fun()
---@param after_save boolean? run `proceed` after saving too, for an action that replaces
---the run a save starts rather than being that run
function RunnerUI:with_pending_settled(tcnum, what, proceed, after_save)
    self:capture_pending()
    local nums = self:unsaved_testcases()
    if tcnum ~= nil then
        nums = vim.tbl_filter(function(n)
            return n == tcnum
        end, nums)
    end
    if #nums == 0 then
        proceed()
        return
    end

    require("tuna.widgets").menu(
        unsaved_items(what),
        "unsaved " .. testcase_label(nums),
        function(idx)
            if idx == 1 then
                -- Saving re-runs what it saved, so the run is already under way.
                self:save_all_pending()
                if after_save then
                    proceed()
                end
            elseif idx == 2 then
                self:discard_pending()
                proceed()
            end
        end,
        api.nvim_get_current_win(),
        function() end
    )
end

---@private
---Whether a buffer is one of this UI's panes (the viewer borrows one, so it counts).
---@param bufnr integer
---@return boolean
function RunnerUI:owns_buf(bufnr)
    for _, w in pairs(self.windows) do
        if w.bufnr == bufnr then
            return true
        end
    end
    return false
end

---@private
---Read a detail pane's buffer back as text.
---@param name string
---@return string
function RunnerUI:pane_text(name)
    local w = self.windows[name]
    if not (w and w.bufnr and api.nvim_buf_is_valid(w.bufnr)) then
        return ""
    end
    return table.concat(api.nvim_buf_get_lines(w.bufnr, 0, -1, false), "\n")
end

---@private
---Whether anything may have happened to the editable panes since they were last
---rendered — Vim's `modified` flag, or an edit already held for the row on screen.
---Free whatever the size of the testcase, and only ever a gate on the real question
---below: `modified` cannot tell text typed *back* to the original from text still
---changed, and it is cleared behind Vim's back (see `clear_pane_modified`).
---@return boolean
function RunnerUI:panes_dirty()
    if self.pane_tcnum ~= nil and self.pending[self.pane_tcnum] then
        return true
    end
    for _, name in ipairs({ "si", "eo" }) do
        local w = self.windows[name]
        if w and w.bufnr and api.nvim_buf_is_valid(w.bufnr) and vim.bo[w.bufnr].modified then
            return true
        end
    end
    return false
end

---@private
---Whether the editable panes actually differ from the **stored** testcase they are a
---view of — the real question, and the only one that survives text retyped by hand.
---Costs a comparison against the stored lines, so it runs where that is affordable (a
---repoint, or the settle after typing stops), never per keystroke.
---@return boolean
function RunnerUI:panes_changed()
    if not self:panes_dirty() then
        return false
    end
    for _, name in ipairs({ "si", "eo" }) do
        local w = self.windows[name]
        if w and w.bufnr and api.nvim_buf_is_valid(w.bufnr) then
            if not (w.baseline and surface.same_lines(w.bufnr, w.baseline)) then
                return true
            end
        end
    end
    return false
end

---@private
---Tell Vim the pane buffers are saved, because as far as Vim is concerned they are:
---an unwritten testcase edit lives in `pending`, not in a buffer waiting to be flushed
---to disk. Left `modified`, these `acwrite` buffers count as unsaved *files*, and any
---quit typed outside the UI — where the command-line guard cannot reach — comes back as
---`E37: No write since last change` / `E162: … for buffer "tuna://runner/…"`, about a
---scratch buffer the user never opened. Pressing `n` was enough to arm it. Our own state
---keeps the edit safe (and offers to save it on the way out), so the flag is noise.
function RunnerUI:clear_pane_modified()
    for _, name in ipairs({ "si", "eo" }) do
        local w = self.windows[name]
        if w and w.bufnr and api.nvim_buf_is_valid(w.bufnr) and vim.bo[w.bufnr].modified then
            vim.bo[w.bufnr].modified = false
        end
    end
end

---@private
---Move an edit in progress out of the (shared) pane buffers and into `pending`,
---before anything repoints those panes at a different row.
---
---This reads both panes out in full, so it is **not** something to do per keystroke:
---on a 500 000-line testcase that was ~127 ms of work behind every character typed,
---which is an editor that has stopped responding. It runs where a pane is actually
---about to be repointed (a row switch, a render, a save, a close, a teardown);
---while you type, `on_pane_edit` keeps the row's `EDITED` state honest for free.
function RunnerUI:capture_pending()
    -- Attributed to the row the panes were last *rendered* for, not to the selected
    -- one: between choosing a row and the render that repoints the panes, the two
    -- differ, and the text still on screen belongs to the row it came from.
    local n = self.pane_tcnum
    if n == nil then
        return
    end
    if not self:panes_changed() then
        -- Back to the stored text — undone, or retyped by hand. Either way
        -- there is no edit any more, and the row must stop reading `EDITED`. A row added
        -- with `n` keeps its entry: it is unsaved by existing, not by differing.
        self.pane_edited = false
        if not (self.pending[n] and self.pending[n].fresh) then
            self.pending[n] = nil
        end
        self:clear_pane_modified()
        return
    end
    self.pane_edited = true
    self.pending[n] = {
        stdin = self:pane_text("si"),
        expected = self:pane_text("eo"),
        fresh = self.pending[n] and self.pending[n].fresh or nil,
    }
    -- The edit is ours now, so the buffers are not carrying anything Vim has to worry
    -- about on the way out.
    self:clear_pane_modified()
end

---@private
---What a keystroke in an editable pane costs. Deliberately O(1) in the size of the
---testcase: the text itself is only read out when a pane is about to be repointed
---(`capture_pending`), never here. All that has to be true *while* typing is that the
---row reads `EDITED` from the first keystroke; whether it still deserves to is settled
---a moment later, by comparison. Re-renders **only when the set of edited rows actually
---changed**, since rewriting the selector and status buffers on every character is the
---other half of the same cost.
function RunnerUI:on_pane_edit()
    -- Raised, never lowered: something was typed, which is all that can be known for
    -- free. Whether the text is *back* to the stored testcase — by undo or by hand — is
    -- a comparison, and that is the settle pass's job.
    if self.pane_tcnum ~= nil then
        self.pane_edited = true
    end
    self:schedule_settle()
    if table.concat(self:unsaved_testcases(), ",") == self.edited_sig then
        return
    end
    self:render_selector()
    self:update_status_line()
end

---@private
---The pass that runs shortly after typing stops, where the answers that cost something
---are worked out: whether the panes still differ from the stored testcase (an
---edit typed back to the original by hand leaves Vim's `modified` set, so only a
---comparison can tell), and the diff marks, which describe what is on screen. Debounced
---rather than immediate because both are proportional to the size of the testcase, and
---that is exactly the per-keystroke cost the edit path was freed of.
function RunnerUI:schedule_settle()
    if not self.settle_timer then
        self.settle_timer = vim.uv.new_timer()
    end
    self.settle_timer:stop()
    self.settle_timer:start(
        SETTLE_DELAY,
        0,
        vim.schedule_wrap(function()
            if not self.ui_visible then
                return
            end
            local was = self.pane_edited
            self:capture_pending() -- re-decides `pane_edited` from the text itself
            if self.pane_edited ~= was then
                self:render_selector()
                self:update_status_line()
            end
            if self.diff_view then
                self:render_diff()
            end
        end)
    )
end

---@private
---Select a selector row, first rescuing any unsaved edit shown in the panes.
---@param idx integer
function RunnerUI:select_row(idx)
    -- A row has been chosen, so the opening choice is settled: it must not overrule a row
    -- selected between the UI being built and its first render.
    self.opening = false
    if idx == self.update_testcase then
        return
    end
    self:capture_pending()
    self.update_testcase = idx
    self.update_details = true
    local tc = self.runner.tcdata[idx]
    if tc then
        -- Remembered on the *runner*, so re-opening the UI (which builds a new one)
        -- returns to the row last looked at. An identity rather than a line number,
        -- so it survives the rows being rebuilt by a re-run or a reload.
        self.runner.last_row_id = self.runner:row_id(tc)
    end
end

---@private
---Whether any testcase has unsaved edits (including one being typed right now).
---@return boolean
function RunnerUI:has_pending()
    self:capture_pending()
    return next(self.pending) ~= nil
end

---@private
---Every testcase with an unsaved edit, sorted. Includes the row on screen even
---before `capture_pending` has run, so the "Run" pane can warn *while* you type
---rather than only once the edit has been moved into `pending`.
---@return integer[]
function RunnerUI:unsaved_testcases()
    local nums = vim.tbl_keys(self.pending)
    local n = self.pane_tcnum
    if n ~= nil and not self.pending[n] and self.pane_edited then
        nums[#nums + 1] = n
    end
    table.sort(nums)
    return nums
end

---@private
---Throw away every unsaved edit. The pane buffers have to be marked unmodified as
---well as `pending` cleared: `delete()` rescues a modified pane into `pending` on its
---way out, so clearing the table alone would see the edits captured straight back.
function RunnerUI:discard_pending()
    self.pending = {}
    self.pane_edited = false
    for _, name in ipairs({ "si", "eo" }) do
        local w = self.windows[name]
        if w and w.bufnr and api.nvim_buf_is_valid(w.bufnr) then
            vim.bo[w.bufnr].modified = false
        end
    end
end

---@private
---Where a row table currently sits in `tcdata`, or nil if it is gone. Rows are found
---by identity wherever an answer to a prompt could have moved or removed them, since
---the index the action started from is only good until then.
---@param tc table?
---@return integer?
function RunnerUI:row_index(tc)
    for i, row in ipairs(self.runner.tcdata) do
        if row == tc then
            return i
        end
    end
    return nil
end

---@private
---The text a save of `tcnum` would write. The panes hold this testcase's text only
---while they are showing it; for any other one, what was captured when they stopped
---showing it is the truth.
---@param tcnum integer
---@return string input, string expected
function RunnerUI:edited_text(tcnum)
    local p = self.pending[tcnum]
    if p and tcnum ~= self.pane_tcnum then
        return p.stdin, p.expected
    end
    return self:pane_text("si"), self:pane_text("eo")
end

---Write the edits shown in the panes (or held for `tcnum`) to disk and re-run.
---@param tcnum integer
---@param expect_empty_output boolean? an empty answer means "print nothing"
---@return boolean
function RunnerUI:save_testcase(tcnum, expect_empty_output)
    local input, expected = self:edited_text(tcnum)
    if not self.runner:save_testcase(tcnum, input, expected, expect_empty_output) then
        return false
    end
    self.pending[tcnum] = nil
    for _, name in ipairs({ "si", "eo" }) do
        local w = self.windows[name]
        if w and w.bufnr and api.nvim_buf_is_valid(w.bufnr) and tcnum == self.pane_tcnum then
            vim.bo[w.bufnr].modified = false
            self.pane_edited = false
        end
    end
    self.update_windows = true
    self:update_ui()
    return true
end

---@private
---Write every unsaved testcase.
function RunnerUI:save_all_pending()
    self:capture_pending()
    for tcnum in pairs(vim.deepcopy(self.pending)) do
        self:save_testcase(tcnum)
    end
end

---@private
---The testcase number of an untouched bare row, if there is one: the row a run with
---nothing to test leaves behind, before anything has been typed into it. Nil once it
---carries an edit, since it is then a testcase being written rather than an empty one
---going spare.
---@return integer?
function RunnerUI:bare_row_tcnum()
    for _, tc in ipairs(self.runner.tcdata) do
        if tc.bare and not self.pending[tc.tcnum] then
            return tc.tcnum
        end
    end
    return nil
end

---@private
---Add a testcase: a new row, selected, with both panes empty and waiting. Like any
---other edit it is only written by `:w`, so an abandoned one costs nothing.
function RunnerUI:add_testcase()
    if not self.runner.editable_testcases then
        return
    end
    if not self.runner:idle() then
        utils.notify("wait for the run to finish before adding a testcase.", "WARN")
        return
    end
    self:capture_pending()
    -- A run with no testcases already left an empty, unsaved testcase 0 on screen (the
    -- `No input` row), which is exactly what this key would otherwise create. Adding a
    -- second one beside it would number it 1 and leave a gap on disk, so `n` there
    -- means "go and type in the empty one".
    local n = self:bare_row_tcnum()
    if n == nil then
        n = self.runner:next_tcnum()
        self.runner:add_testcase_row(n)
        -- `fresh`: unsaved by existing, not by differing — a row added here has no file
        -- behind it, so it stays pending even while its (empty) panes match their render.
        self.pending[n] = { stdin = "", expected = "", fresh = true }
    end
    self.update_windows = true
    self:update_ui()
    -- The row only exists on screen after the scheduled render.
    vim.schedule(function()
        if not self.ui_visible then
            return
        end
        for i, tc in ipairs(self.runner.tcdata) do
            if tc.tcnum == n and self.runner:row_editable(tc) then
                self:goto_row(i)
                break
            end
        end
        local w = self.windows.si
        if w and w.winid and api.nvim_win_is_valid(w.winid) then
            api.nvim_set_current_win(w.winid)
            vim.cmd("startinsert")
        end
    end)
end

---@private
---Lift the cases this row's markers bracket out into rows of their own. The marker is
---`testcases_split_markers`, since a key cannot carry an argument —
---`:Tuna testcase split <n> <marker>` takes one.
function RunnerUI:split_testcase()
    local tc = self.runner.tcdata[self:cursor_tc()]
    if not self.runner:row_editable(tc) then
        return
    end
    if not self.runner:idle() then
        utils.notify("wait for the run to finish before splitting a testcase.", "WARN")
        return
    end
    -- The markers are typed into the Input pane, so an unwritten edit *is* what the
    -- user means by "this testcase". It is handed to the split rather than saved first:
    -- saving re-runs what it saves, and the marked-up input is the one text that must
    -- never be fed to the solution. The split writes every case including this row's,
    -- so the edit is committed either way.
    local n = tc.tcnum
    self:capture_pending()
    local p = self.pending[n]
    local input = p and p.stdin or nil
    local expected = p and p.expected or nil
    if n == self.pane_tcnum then
        input, expected = self:pane_text("si"), self:pane_text("eo")
    end

    if not self.runner:split_testcase(n, self.config.testcases_split_markers, input, expected) then
        return
    end
    self.pending[n] = nil
    if n == self.pane_tcnum then
        self.pane_edited = false
    end
    self:update_ui(true)
end

---Delete a testcase, the one under the cursor unless `tcnum` names another. No
---confirmation: it goes on an undo stack the runner keeps, and `u` puts it back —
---cheaper to press than a dialog, and recoverable, which a dialog does not make it.
---@param tcnum integer? the testcase to delete (default: the row under the cursor)
function RunnerUI:delete_testcase(tcnum)
    local rows = tcnum ~= nil and self.runner:rows_for(tcnum) or nil
    local tc = self.runner.tcdata[rows and rows[1] or self:cursor_tc()]
    if not self.runner:row_editable(tc) then
        return
    end
    if not self.runner:idle() then
        utils.notify("wait for the run to finish before deleting a testcase.", "WARN")
        return
    end
    local n = tc.tcnum
    local testcases = require("tuna.testcases")
    local stored = testcases.buf_get_testcases(self.runner:edit_bufnr())[n]
    -- Remember what is being lost — the pane text if it was never written, the file's
    -- content otherwise.
    local snapshot = self.pending[n]
        or {
            stdin = stored and stored.input or tc.stdin,
            expected = stored and stored.output or tc.expected,
        }
    if stored then
        pcall(testcases.buf_delete_testcase, self.runner:edit_bufnr(), n)
    end

    self.runner.deleted_testcases = self.runner.deleted_testcases or {}
    table.insert(self.runner.deleted_testcases, {
        tcnum = n,
        input = snapshot.stdin or "",
        expected = snapshot.expected or "",
        -- An answer stored present-and-empty means "expect no output", and `undo`
        -- restores through a save whose empty answer otherwise means "no answer" —
        -- so which of the two it was has to survive the round trip.
        expect_empty = stored ~= nil and stored.output == "",
    })
    self.pending[n] = nil
    self.runner:remove_testcase_rows(n)

    -- Nothing left to show the pane content of; land on a real row again.
    self.update_testcase = nil
    self.update_windows = true
    self:update_ui()
    vim.schedule(function()
        self:goto_row(math.min(self:cursor_tc(), #self.runner.tcdata))
    end)
    -- Name the key the user actually has: this is the one message that hands out a
    -- mapping, so it must not go stale when `undo_delete` is remapped.
    local undo = as_list(self.config.runner_ui.mappings.undo_delete or {})[1] or "u"
    utils.notify("testcase " .. n .. " deleted (" .. undo .. " to undo).", "INFO")
end

---@private
---Restore the most recently deleted testcase.
function RunnerUI:undo_delete()
    local stack = self.runner.deleted_testcases
    if not (stack and #stack > 0) then
        return -- nothing to restore: a key that has nothing to do says nothing
    end
    if not self.runner:idle() then
        utils.notify("wait for the run to finish before restoring a testcase.", "WARN")
        return
    end
    local last = table.remove(stack)
    self:capture_pending()
    self.runner:add_testcase_row(last.tcnum)
    self.runner:save_testcase(last.tcnum, last.input, last.expected, last.expect_empty)
    self.update_windows = true
    self:update_ui()
    utils.notify("testcase " .. last.tcnum .. " restored.", "INFO")
end

---@private
---Put the selector cursor on `idx` (and make that the shown row).
---@param idx integer
function RunnerUI:goto_row(idx)
    local w = self.windows.tc
    if not (w and w.winid and api.nvim_win_is_valid(w.winid)) then
        return
    end
    local count = api.nvim_buf_line_count(w.bufnr)
    idx = math.max(1, math.min(idx, count))
    pcall(api.nvim_win_set_cursor, w.winid, { idx, 0 })
    self:select_row(idx)
    self:update_ui()
end

---Take the choice of row back from a selector moved by hand, and make it again: a run of the
---whole set starts the way the first one did, on the build and then the first testcase it has
---nothing to say about. A single row's re-run does not come through here — that row is the one
---being re-run, and it is where the cursor belongs.
function RunnerUI:choose_row_again()
    self.user_moved = false
    self.opening = true
end

---@private
---Move to `idx` while the row on screen is still the UI's own choice. Everything that picks
---a row *for* the user goes through this: opening the board, a build that turned out to have
---nothing to say, the row a conversation is being held on. Once the selector has been moved
---by hand it stops moving on its own, since the row someone chose to read is not a default.
---@param idx integer
function RunnerUI:follow_row(idx)
    if not self.ui_visible or self.user_moved then
        return
    end
    self:goto_row(idx)
end

---@private
---Once the build is over and had nothing to say, the row worth looking at is the first
---testcase: the Compile row is only where a run *starts*. A build that failed or printed
---something is the row that answers the run, so it keeps the cursor, as does one still going.
function RunnerUI:follow_after_compile()
    local first = self.runner.tcdata[1]
    if not (first and first.tcnum == "Compile" and self.runner.tcdata[2]) then
        return -- no build step, or nothing to move on to
    end
    if self.update_testcase ~= 1 or first.judging then
        return
    end
    -- The build step is every source this run compiles, the solution and the helpers its
    -- mode needs. The cursor waits for all of them, and stays here if any of them had
    -- something to say, or a warning landing a moment later would arrive on a row nobody
    -- is looking at any more.
    if self.runner:build_pending(first) or self.runner:build_spoke(first) then
        return
    end
    self:follow_row(2)
end

---@private
---Which selector row the UI should open on. The first testcase, whenever the Compile
---step has nothing to say: an empty compile row leaves the panes of a run in front of
---someone who opened the UI to read a verdict — or, before any run, to read the
---testcase itself. Row 1 (Compile) is kept for the two cases where it is the row worth
---reading: a compilation that printed warnings or errors, and a run whose build has not
---finished, where the cursor must not be moved out from under the user as results land.
---@return integer
function RunnerUI:initial_row()
    local first = self.runner.tcdata[1]
    if not first or first.tcnum ~= "Compile" or not self.runner.tcdata[2] then
        return 1
    end
    -- Worth reading: one of its sources printed warnings or errors.
    if self.runner:build_spoke(first) then
        return 1
    end
    if self:building() then
        return 1
    end
    return 2
end

---@private
---Whether a run's build is under way: a Compile row that has not finished, on a runner that is
---running rather than listing its rows (`preloaded`). It is about the *run*, not the process:
---asking whether the compiler runs right now leaves a window between the rows being built and
---it being spawned, and a UI opened inside that window draws the panes of a run for a build
---about to start, only to redraw them a tick later.
---@return boolean
function RunnerUI:building()
    local first = self.runner.tcdata[1]
    return first ~= nil
        and first.tcnum == "Compile"
        and self.runner.tcdata[2] ~= nil
        and not self.runner.preloaded
        and first.exit_code == nil
end

---@private
---Which row to open on: the one last looked at, if it is still there. Matched by
---identity rather than line number, so it survives the rows being rebuilt — and
---falls back to `initial_row` on the first open of a runner, when the row it names
---was deleted, or after a fresh set of testcases was loaded.
---@return integer
function RunnerUI:opening_row()
    -- A run opens on its build, whatever was last looked at: that is where the run is, and
    -- `follow_after_compile` hands the row over the moment it ends with nothing to say. Every
    -- run then starts the same way, rather than the first one differing from the rest.
    if self:building() then
        return 1
    end
    local id = self.runner.last_row_id
    if id then
        for i, tc in ipairs(self.runner.tcdata) do
            if self.runner:row_id(tc) == id then
                return i
            end
        end
    end
    return self:initial_row()
end

---@private
---What the runner's mode changes about the grid: a layout of its own, and titles it gives
---panes that mean something else in it. Asked of the runner rather than configured, since
---both follow from the mode; a mode that has no opinion gets the configured layout.
---@return table
---@param idx integer? the row the grid is for (default: the row on screen)
function RunnerUI:layout_opts(idx)
    local r = self.runner
    local layout, name = self:row_layout(idx)
    local titles = r.pane_titles and r:pane_titles() or nil
    -- On the build step a pane is named after the source in it, whatever it means elsewhere.
    local build = self:build_assignment(self.runner.tcdata[idx or self.update_testcase or 1])
    if build and next(build.titles) then
        titles = vim.tbl_extend("force", titles or {}, build.titles)
    end
    return {
        layout = layout,
        layout_name = name,
        titles = titles,
    }
end

---@private
---The grid the build step is laid out with before its sources are stacked into it:
---`runner_ui.compile_layout`, or, when that is `false`, what the row would get anyway —
---the mode's own grid, else the configured one, which only the interface knows.
---@return table layout, string name
function RunnerUI:compile_base_layout()
    local compile = self.config.runner_ui.compile_layout
    if compile then
        return compile, "runner_ui.compile_layout"
    end
    if self.runner.layout then
        local own, own_name = self.runner:layout()
        if own then
            return own, own_name or "run mode layout"
        end
    end
    return self.interface.configured_layout(self.config)
end

---@private
---How the build step's sources are shown: which pane each is in, what its compiler said and
---what to call that pane. `nil` on every row but the build step, and on one whose grid has
---no Errors pane to put them in. The three are answered together because they have to
---agree: the grid stacks exactly the panes the titles name and the content fills.
---@param tc table? the row being laid out or drawn
---@return { panes: string[], text: table<string, string>, titles: table<string, string> }?
function RunnerUI:build_assignment(tc)
    if not (tc and tc.tcnum == "Compile" and self.runner.build_sources) then
        return nil
    end
    local placed = {}
    for _, name in ipairs(layout_util.leaves((self:compile_base_layout()))) do
        placed[name] = true
    end
    if not placed.se then
        return nil -- a grid with nowhere to show a compiler is a grid that doesn't want to
    end
    -- The solution keeps the Errors pane it has always had; each helper takes a pane the
    -- grid is not already using, so the build step reads as one column of its sources.
    local free = {}
    for _, name in ipairs(BUILD_PANES) do
        if name == "se" or not placed[name] then
            free[#free + 1] = name
        end
    end
    local sources = self.runner:build_sources(tc)
    local panes, holds = {}, {}
    for i, source in ipairs(sources) do
        -- More sources than panes: the last one carries them rather than leaving one unread.
        local pane = free[i] or free[#free]
        if not holds[pane] then
            panes[#panes + 1] = pane
            holds[pane] = {}
        end
        table.insert(holds[pane], source)
    end
    local text, titles = {}, {}
    for _, pane in ipairs(panes) do
        local shared, labels, parts = #holds[pane] > 1, {}, {}
        for _, source in ipairs(holds[pane]) do
            labels[#labels + 1] = source.label
            parts[#parts + 1] = shared and (source.label .. ":\n" .. source.output) or source.output
        end
        text[pane] = table.concat(parts, "\n")
        -- Named only when there is more than one source: with a single one, "Errors" is
        -- already the whole answer to which source it belongs to.
        if #sources > 1 then
            titles[pane] = (" Errors: %s "):format(table.concat(labels, ", "))
        end
    end
    return { panes = panes, text = text, titles = titles }
end

---@private
---The grid the row on screen wants, and what to call it when it doesn't validate. The build
---step is not a testcase: it has no input, no answer and no output to compare, so the four
---panes of a run would face someone reading a compiler's complaint with three empty frames.
---It gets the selector and Errors (`runner_ui.compile_layout`, `false` to keep the grid the
---mode draws). Every other row is the mode's own layout, or the configured one (nil).
---@param idx integer? the row to lay out for (default: the row on screen)
---@return table? layout, string? name
function RunnerUI:row_layout(idx)
    local tc = self.runner.tcdata[idx or self.update_testcase or 1]
    local compile = self.config.runner_ui.compile_layout
    if tc and tc.tcnum == "Compile" then
        -- More than one source to build: the Errors pane becomes a column of them.
        local build = self:build_assignment(tc)
        if build and #build.panes > 1 then
            local layout, name = self:compile_base_layout()
            return stack_into(layout, build.panes), name
        end
        if compile then
            return compile, "runner_ui.compile_layout"
        end
    end
    if not self.runner.layout then
        return nil, nil
    end
    local own, own_name = self.runner:layout()
    return own, own and (own_name or "run mode layout") or nil
end

---@private
---Lay the grid out again, in place: the panes keep their buffers, and with them their
---content, their keymaps and anything typed into them but not written. This is what a change
---of layout needs — the editor being resized, or the row on screen changing kind — and doing
---it by rebuilding the UI instead would drop all of that and race the rows landing in it.
function RunnerUI:redraw_grid()
    if not self.ui_visible then
        return
    end
    local tc = self.windows.tc
    if not (tc and tc.bufnr and api.nvim_buf_is_valid(tc.bufnr)) then
        return -- the panes are gone (wiped out from under the UI); there is nothing to lay out
    end
    local opts = self:layout_opts()
    self.drawn_layout = opts.layout
    -- Windows opening and closing here are the UI's own: a `WinClosed` on one of them is not
    -- the user closing the UI, and the cursor events they raise are not a move by hand. The
    -- flag outlives the call by a tick, which is when those events are delivered.
    self.relayouting = true
    self.interface.relayout(self.windows, self.config, self.restore_winid, math.max(1, #self:status_lines()), opts)
    vim.schedule(function()
        self.relayouting = false
    end)

    -- Windows have come and gone: what is bound per window is bound again, while everything
    -- bound per buffer (the keymaps, the write handler) is still where it was.
    api.nvim_clear_autocmds({ group = self.augroup, event = "WinClosed" })
    for _, w in pairs(self.windows) do
        if w.winid then
            self:watch_pane_window(w.winid)
        end
    end
    self:accent_editable_panes()
    if self.diff_view then
        self:set_diff_bind(true)
    end
    -- A mode that owns panes sets them up again (interactive's scroll-bound columns).
    if self.runner.on_ui_shown then
        self.runner:on_ui_shown(self)
    end
    if self.viewer_winid then
        local was = self.viewer_content
        self:close_viewer()
        self:show_viewer(was)
    end
    self.update_windows = true
    self:update_ui()
end

---@private
---Close the whole UI when one of its windows is closed: a results grid is one thing, not six
---windows to dismiss one at a time. Not while the grid is being laid out again, where the
---closing is the UI's own.
---@param winid integer
function RunnerUI:watch_pane_window(winid)
    api.nvim_create_autocmd("WinClosed", {
        group = self.augroup,
        pattern = tostring(winid),
        callback = function()
            if self.relayouting then
                return
            end
            -- Out of the autocmd before touching windows: this fires *during* the close,
            -- where opening or closing more of them is unsafe.
            vim.schedule(function()
                self:request_close(true)
            end)
        end,
    })
end

---Show the UI, building it if needed and focusing the selector.
function RunnerUI:show_ui()
    if self.ui_visible then
        api.nvim_set_current_win(self.windows.tc.winid)
        return
    end

    self.restore_winid = self.restore_winid or api.nvim_get_current_win()
    -- The "Run" pane is sized to the runner's (stable) status-line count.
    local status_height = math.max(1, #self:status_lines())
    -- Laid out for the row it is about to open on, not for line 1: the two differ exactly
    -- when the build step is not the row worth reading, and drawing the build's grid first
    -- would rebuild every pane a tick later.
    local opening = next(self.runner.tcdata) ~= nil and self:opening_row() or nil
    local opts = self:layout_opts(opening)
    self.drawn_layout = opts.layout
    self.interface.init_ui(self.windows, self.config, self.restore_winid, status_height, opts)
    self.ui_visible = true
    for _, w in pairs(self.windows) do
        if w.bufnr then
            pane_owner[w.bufnr] = self.runner
        end
    end
    self:accent_editable_panes()
    self:update_status_line()

    augroup_counter = augroup_counter + 1
    self.augroup = api.nvim_create_augroup("tuna_runner_ui_" .. augroup_counter, { clear = true })

    local mappings = self.config.runner_ui.mappings

    local function close_or_viewer()
        if self.viewer_winid then
            self:close_viewer()
        else
            self:request_close()
        end
    end

    -- Close maps on every window; ":q" handled per-window via WinClosed keyed on
    -- the *window id* (not buffer — the viewer borrows a detail pane's buffer, so
    -- a buffer-keyed autocmd would tear the UI down when the viewer is closed).
    local switch = as_list(self.config.switch_window_keys or {})
    local dirs = { "h", "j", "k", "l" }
    for name, w in pairs(self.windows) do
        -- Bound in **normal mode only**, on every pane including the editable ones.
        -- Typing happens in insert mode, where these keys are untouched, so `q` there
        -- is still the letter q and `<Esc>` still just leaves insert — dismissing what
        -- you are typing into takes the same second, deliberate press as everywhere
        -- else in tuna. In normal mode they mean what they mean in the rest of the UI,
        -- and an unsaved edit is caught by the prompt rather than by withholding the key.
        for _, key in ipairs(as_list(mappings.close)) do
            vim.keymap.set("n", key, close_or_viewer, { buffer = w.bufnr, nowait = true })
        end
        -- The key legend is reachable from wherever you are, editable panes included:
        -- being lost is exactly when it is wanted. Normal mode only, like the rest.
        for _, key in ipairs(as_list(mappings.help)) do
            vim.keymap.set("n", key, function()
                self:show_help()
            end, { buffer = w.bufnr, nowait = true })
        end
        for i, key in ipairs(switch) do
            local d = dirs[i]
            if d then
                local function go()
                    self:focus_dir(d)
                end
                vim.keymap.set("n", key, go, { buffer = w.bufnr, nowait = true })
                -- Editable panes are left mid-typing, so the same keys have to work
                -- from insert mode too (as they do in the widgets).
                if self:writable_pane(name) then
                    vim.keymap.set("i", key, function()
                        vim.cmd("stopinsert")
                        go()
                    end, { buffer = w.bufnr, nowait = true })
                end
            end
        end
        -- A pane the layout left out has a buffer but no window, so there is nothing
        -- to watch for it (its content is still reachable through the viewer).
        if w.winid then
            self:watch_pane_window(w.winid)
        end
    end

    -- `:q` (or `:close`) typed in **any** pane is **cancelled before it runs** and turned
    -- into a close of the whole UI, which is what it was asking for: a results grid is
    -- one thing, not six windows to dismiss one at a time. Cancelling at the command
    -- line is what makes it silent and still — the window is never closed, so no pane
    -- flashes out and back as the grid is rebuilt around the hole, and Vim never gets
    -- far enough to raise its own red "E37: No write since last change" about an edit
    -- the prompt is already handling. (The abort has to be set from Vimscript:
    -- `vim.v.event` reads back a *copy* in Lua, so assigning to it there is silently
    -- lost.) Two things are deliberately left alone: a `!`, an explicit
    -- discard (the edits are dropped and the command runs), and `:qa`, which means
    -- "leave Neovim" — intercepted only when it would throw an unsaved edit away.
    api.nvim_create_autocmd("CmdlineLeave", {
        group = self.augroup,
        callback = function()
            if not self.ui_visible then
                return
            end
            local cmd, forced = quit_command(vim.fn.getcmdline())
            if cmd == nil then
                return
            end
            -- Closing *this window* is only our business when the cursor is in one of
            -- our panes. Leaving Neovim is our business wherever it is typed: the UI is
            -- open somewhere with an edit in it, and Vim's own complaint would name a
            -- scratch buffer instead of the testcase.
            if cmd.scope == "window" then
                if not self:owns_buf(api.nvim_get_current_buf()) then
                    return
                end
                -- The viewer is a window of its own, over the grid: `:q` there means
                -- close the viewer, and that is exactly what Vim is about to do.
                if self.viewer_winid and api.nvim_get_current_win() == self.viewer_winid then
                    return
                end
            end
            if forced then
                self:discard_pending()
                return
            end
            if cmd.scope == "all" then
                -- `:qa`/`:xa` mean leave Neovim, so they are let through: written first
                -- if that is what was asked (each pane is `acwrite`, and a save that has
                -- nothing to write does nothing), and stopped to ask only when quitting
                -- would throw an edit away.
                if cmd.write then
                    self:save_all_pending()
                elseif self:has_pending() then
                    local line = vim.fn.getcmdline()
                    vim.cmd("let v:event.abort = v:true")
                    vim.schedule(function()
                        -- Answered, the quit carries on by itself: cancelling it was
                        -- only ever a way to ask, not a refusal.
                        self:request_close(false, function()
                            vim.schedule(function()
                                pcall(vim.cmd, line)
                            end)
                        end)
                    end)
                end
                return
            end
            vim.cmd("let v:event.abort = v:true")
            vim.schedule(function()
                if cmd.write then
                    -- `:wq` here is "Save and close", which is what it means anywhere.
                    self:save_all_pending()
                    self:delete()
                else
                    self:request_close()
                end
            end)
        end,
    })

    -- `:w` saves the testcase being edited **from whichever pane you type it in** — the
    -- same gesture as saving any other buffer, which is the whole point of leaving the
    -- editable panes modifiable. It works from the read-only panes too because the row
    -- being saved is well defined wherever you are looking, and a `:w` that answers
    -- with `E382: Cannot write, 'buftype' option is set` in one pane and saves in the
    -- next is the same inconsistency the action keys were spread out to remove.
    for name, w in pairs(self.windows) do
        if w.bufnr then
            -- `acwrite` routes `:w` through the autocmd below instead of refusing to
            -- write a scratch buffer. (The name `:w` also needs, or it aborts with E32
            -- before the autocmd fires, comes from the interface — see
            -- `utils.name_float_buffer`.) A read-only pane stays read-only: `acwrite`
            -- says how a write is handled, not that the buffer can be changed. Every
            -- pane gets it, in every mode — a mode with nothing to save (interactive)
            -- says so, which is still better than Vim's `E382`.
            vim.bo[w.bufnr].buftype = "acwrite"
            api.nvim_create_autocmd("BufWriteCmd", {
                group = self.augroup,
                buffer = w.bufnr,
                callback = function()
                    local tcnum = self.pane_tcnum
                    if not self.runner.editable_testcases then
                        utils.notify("this run mode has no testcase to save.", "WARN")
                    elseif tcnum == nil then
                        utils.notify("this row is not a testcase, so there is nothing to save.", "WARN")
                    elseif self:panes_changed() or self.pending[tcnum] then
                        -- The one save that asks: an explicit `:w` of a testcase with
                        -- nothing in it stores nothing and removes what was there.
                        self:with_answer_settled(tcnum, function(expect_empty_output)
                            self:save_testcase(tcnum, expect_empty_output)
                        end)
                    end
                    -- Nothing changed since the last write: saving would only re-run the
                    -- testcase, which is what `R` is for. Also what keeps a `:wqa`
                    -- (one write per pane) from re-running it six times over.
                end,
            })
        end
        if w.bufnr and self:writable_pane(name) and self.runner.editable_testcases then
            -- The "unsaved" warning has to appear as you type, not at the next render:
            -- the "Run" pane is the only place that says an edit is uncommitted, and a
            -- hint that arrives after the fact is no hint at all.
            api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
                group = self.augroup,
                buffer = w.bufnr,
                callback = function()
                    -- Only the selector: re-rendering the *panes* would replace the text
                    -- under the cursor with an identical copy and throw the cursor back
                    -- to line 1 on every keystroke. `TextChanged` also fires on undo and
                    -- redo, which is what keeps `EDITED` honest in both directions.
                    self:on_pane_edit()
                end,
            })
        end
    end

    -- The UI's actions, bound on **every read-only pane**, not just the selector: they
    -- all act on the row the selector's cursor is on, which is well defined wherever
    -- you happen to be looking, and a key that works in one pane and silently does
    -- nothing in the next is the kind of inconsistency that makes a UI feel broken.
    -- The editable panes are the exception, and only because their single letters
    -- belong to the buffer (`d` deletes, `r` replaces, `u` undoes); they get `close`,
    -- the pane-switch keys and `help` above, and everything else from a read-only pane
    -- one `switch_window_key` away.
    local tc_buf = self.windows.tc.bufnr
    local action_bufs = {}
    for name, w in pairs(self.windows) do
        if not self:writable_pane(name) then
            action_bufs[#action_bufs + 1] = w.bufnr
        end
    end
    local function map_tc(action, fn)
        for _, key in ipairs(as_list(mappings[action])) do
            for _, buf in ipairs(action_bufs) do
                vim.keymap.set("n", key, fn, { buffer = buf, nowait = true })
            end
        end
    end

    map_tc("stop", function()
        self.runner:kill_process(self:cursor_tc())
    end)
    map_tc("stop_all", function()
        self.runner:kill_all_processes()
    end)
    map_tc("run_again", function()
        local tc = self.runner.tcdata[self:cursor_tc()]
        -- Re-running a row you have edited but not saved would run the *old* input and
        -- report a verdict for text that is no longer what you are looking at. Ask.
        -- Then ask again if the row's testcase has gone missing from disk, for the same
        -- reason from the other side: the verdict would be about something not there.
        self:with_pending_settled(tc and tc.tcnum, "re-run", function()
            self:with_disk_settled(tc and tc.tcnum, "re-run", function()
                -- Found again by identity, not by the index we started from: settling
                -- the two questions can renumber this row, and can remove others above
                -- it. A row discarded along the way is simply not run.
                local idx = self:row_index(tc)
                if not idx then
                    return
                end
                -- Kill only a row that is actually running: on an idle row the base
                -- kill is a no-op anyway, and stress overrides `kill_process` to mean
                -- "stop the whole search" — re-running an already-settled row must
                -- not do that (nor flash its "stopped" message) as a side effect.
                if tc.running then
                    self.runner:kill_process(idx)
                end
                vim.schedule(function()
                    self.runner:run_single(idx)
                end)
            end)
        end)
    end)
    map_tc("run_all_again", function()
        self:with_pending_settled(nil, "re-run all", function()
            self:with_disk_settled(nil, "re-run all", function()
                self.runner:kill_all_processes()
                self:choose_row_again()
                vim.schedule(function()
                    self.runner:run_testcases()
                end)
            end)
        end)
    end)
    map_tc("toggle_diff", function()
        self:toggle_diff_view()
    end)
    map_tc("view_stdout", function()
        self:show_viewer("so")
    end)
    map_tc("view_output", function()
        self:show_viewer("eo")
    end)
    map_tc("view_input", function()
        self:show_viewer("si")
    end)
    map_tc("view_stderr", function()
        self:show_viewer("se")
    end)
    -- Bound in every mode, and silent where testcases can't be edited: each one checks
    -- for itself. Left unbound, `n`/`N` would fall through to Vim's search.
    map_tc("add_testcase", function()
        self:add_testcase()
    end)
    map_tc("delete_testcase", function()
        self:delete_testcase()
    end)
    map_tc("split_testcase", function()
        self:split_testcase()
    end)
    map_tc("undo_delete", function()
        self:undo_delete()
    end)

    -- Keys that would start an edit are inert on a read-only pane. Left alone they
    -- enter insert/replace/operator-pending on a buffer that cannot take a change, so
    -- the next keystroke raises `E21: Cannot make changes, 'modifiable' is off` — an
    -- error about an editing session the user never meant to start.
    for _, buf in ipairs(action_bufs) do
        surface.read_only(buf)
    end

    -- Coming back to the UI after something else took the screen. Opening a file
    -- explorer (or any window that steals focus) and closing it again leaves the cursor
    -- in whatever window Neovim picks, which for a floating grid is the code buffer
    -- *underneath* it — the UI is still on screen, and with its keys bound only inside
    -- its own panes there is then no way back to it from the keyboard.
    --
    -- So the one hop out is remembered: the pane focus left, and the window it left for.
    -- If that window is the one that closes, focus goes back to the pane. Deliberately
    -- narrow, it fires only for the window the UI was actually displaced by, so closing
    -- an unrelated split, or one entered after moving on somewhere else, does not yank
    -- the cursor into a UI the user had finished with.
    --
    -- What "moved on somewhere else" cannot be read off is a single `WinEnter`, because
    -- Neovim delivers a close in either of two orders: `WinClosed` for the window going
    -- away and then `WinEnter` for the one focus falls back to, or the two the other way
    -- round (neo-tree produces the first order on its first close of a session and the
    -- second one on every close after it, which is exactly how far a `WinEnter` that
    -- cleared the state immediately got: it worked once per session and never again).
    -- The fallback `WinEnter` is part of the close, so moving on is decided a tick later,
    -- by which time a `WinClosed` under way has been seen and has already restored.
    api.nvim_create_autocmd("WinLeave", {
        group = self.augroup,
        callback = function()
            local cur = api.nvim_get_current_win()
            self.leaving_pane = self:owns_win(cur) and cur or nil
        end,
    })
    api.nvim_create_autocmd("WinEnter", {
        group = self.augroup,
        callback = function()
            local cur = api.nvim_get_current_win()
            if self:owns_win(cur) then
                self.escaped_from, self.escaped_to = nil, nil -- back inside; nothing owed
            elseif self.leaving_pane then
                self.escaped_from, self.escaped_to = self.leaving_pane, cur
            elseif self.escaped_from and cur ~= self.escaped_to then
                local from, to = self.escaped_from, self.escaped_to
                vim.schedule(function()
                    -- Still the same excursion, its window still there (so this was not
                    -- a close), and still outside the UI: the user moved on.
                    if
                        self.escaped_from == from
                        and self.escaped_to == to
                        and to
                        and api.nvim_win_is_valid(to)
                        and not self:owns_win(api.nvim_get_current_win())
                    then
                        self.escaped_from, self.escaped_to = nil, nil
                    end
                end)
            end
            self.leaving_pane = nil
        end,
    })
    api.nvim_create_autocmd("WinClosed", {
        group = self.augroup,
        callback = function(args)
            if tonumber(args.match) ~= self.escaped_to then
                return
            end
            local pane = self.escaped_from
            self.escaped_from, self.escaped_to = nil, nil
            -- The windows that exist *now*, before the close settles. Focus landing on
            -- one of these afterwards is Neovim falling back, which is what this exists
            -- to rescue. Focus landing anywhere else means a window opened *during* the
            -- close and took it on purpose — a dialog raised from the answer to another
            -- dialog, which is how the results UI asks two questions in a row (an
            -- unsaved edit, then a testcase that has gone missing) — and pulling the
            -- cursor back into the pane there leaves the second question on screen with
            -- no way to answer it, looking for all the world as though the first prompt
            -- had swallowed it.
            local existing = {}
            for _, w in ipairs(api.nvim_list_wins()) do
                existing[w] = true
            end
            -- Scheduled: this fires *during* the close, and the window Neovim lands on
            -- is not settled until it is over.
            vim.schedule(function()
                local cur = api.nvim_get_current_win()
                if
                    self.ui_visible
                    and pane
                    and api.nvim_win_is_valid(pane)
                    and existing[cur]
                    and not self:owns_win(cur)
                then
                    api.nvim_set_current_win(pane)
                end
            end)
        end,
    })

    -- Moving in the selector switches which testcase the detail panes show.
    api.nvim_create_autocmd("CursorMoved", {
        group = self.augroup,
        buffer = tc_buf,
        callback = function()
            if self.relayouting then
                return -- the grid is being laid out again; the cursor is following it
            end
            local idx = self:cursor_tc()
            -- Anything the UI moves selects the row before the cursor event arrives, so a
            -- selection that changes *here* is one the user made.
            if idx ~= self.update_testcase then
                self.user_moved = true
                self:select_row(idx)
                self:update_ui()
            end
        end,
    })

    api.nvim_set_current_win(self.windows.tc.winid)
    self.update_windows = true
    -- The row under the cursor, which is line 1 until the selector has lines to put it on.
    -- Choosing here would leave the two disagreeing, and the first cursor event the editor
    -- sends would then read as a move made by hand. `opening` says the choice is still to be
    -- made: the first render makes it, by which time the rows exist (interactive and run-all
    -- open their UI and *then* build them).
    self.update_testcase = 1
    -- Opening is the board choosing again, and what it chooses is the row last looked at
    -- (`opening_row`) — which is the user's own choice, kept on the runner rather than here.
    self.opening = true
    self.user_moved = false
    self:update_ui()

    -- A rebuilt UI (after a resize) keeps the diff it had. Only the binding is
    -- re-armed here: the panes are filled on the scheduled render queued just above,
    -- which paints the marks itself rather than painting over empty buffers.
    if self.diff_view then
        self:set_diff_bind(true)
    end

    -- Let the runner augment the freshly-built UI (interactive makes the Input pane
    -- editable and wires its send-line keymap here).
    if self.runner.on_ui_shown then
        self.runner:on_ui_shown(self)
    end
end

---@private
---Bind the two compared panes together, so scrolling or moving in one follows in
---the other. With a positional diff the panes are already line-for-line aligned, so
---this needs none of the filler lines `:diffthis` inserts to fake that alignment.
---@param enable boolean
function RunnerUI:set_diff_bind(enable)
    for _, name in ipairs({ "so", "eo" }) do
        local w = self.windows[name]
        if w and w.winid and api.nvim_win_is_valid(w.winid) then
            vim.wo[w.winid].scrollbind = enable
            vim.wo[w.winid].cursorbind = enable
        end
    end
    if enable and self.windows.so and api.nvim_win_is_valid(self.windows.so.winid) then
        api.nvim_win_call(self.windows.so.winid, function()
            vim.cmd("syncbind")
        end)
    end
end

---@private
---Paint one pane's diff marks. Line highlights run to the edge of the window (as a
---diff does), with the disagreeing spans on top of them.
---@param bufnr integer?
---@param marks table<integer, tuna.DiffMark>
local function paint_diff(bufnr, marks)
    if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
        return
    end
    local last = api.nvim_buf_line_count(bufnr)
    for lnum, mark in pairs(marks) do
        if lnum <= last then
            local line = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
            api.nvim_buf_set_extmark(bufnr, diff_ns, lnum - 1, 0, {
                end_col = #line,
                hl_group = mark.hl,
                hl_eol = true,
                priority = 190,
            })
            for _, span in ipairs(mark.spans) do
                api.nvim_buf_set_extmark(bufnr, diff_ns, lnum - 1, math.min(span[1], #line), {
                    end_col = math.min(span[2], #line),
                    hl_group = diff.TEXT,
                    priority = 200,
                })
            end
        end
    end
end

---@private
---The two texts the marks describe. **What is on screen**, literally: while the panes
---are showing this row they *are* the text — an expected output typed but not written
---is what you are looking at, so it is what gets compared, and the marks follow it as
---you type rather than describing the file until the next `:w`. For any other row (the
---Compile row, a mode's own pane) it goes through the `pane_content` seam, which may
---return `SKIP`.
---@param tc table the row being shown
---@return string|nil output
---@return string|nil expected
function RunnerUI:diff_texts(tc)
    local output = self.runner:pane_content(tc, "so")
    local expected = self.runner:pane_content(tc, "eo")
    if output ~= SKIP and expected ~= SKIP and self.pane_tcnum ~= nil and self.pane_tcnum == tc.tcnum then
        return self:pane_text("so"), self:pane_text("eo")
    end
    return output, expected
end

---@private
---Re-highlight the Output and Expected Output panes for the selected testcase.
---Cheap enough to redo on every render, which is what keeps the marks correct as
---the selection moves or a re-run replaces the output.
---Paints nothing, quietly, on a row there is nothing to compare on: one that has no
---answer (the Compile row, an input-only testcase), one a mode owns outright, one that
---has never run, and one whose two texts agree. The panes themselves show which of
---those it is, so none of it is narrated anywhere.
---@return integer? first the first differing line, if any
function RunnerUI:render_diff()
    local so, eo = self.windows.so, self.windows.eo
    if self.diff_view and so and eo then
        -- Same two texts as last time, same method: the marks on the panes are still
        -- the right ones, so neither the walk nor the repaint has anything to do. This
        -- runs on *every* detail render, and a positional diff of a 500 000-line output
        -- is ~1.5 s of work — one to skip whenever a render didn't change the texts.
        local tc = self.runner.tcdata[self.update_testcase or 1]
        local c = self.diff_cache
        if c and tc and c.tc == tc then
            local out, exp = self:diff_texts(tc)
            if c.out == out and c.exp == exp then
                return c.first
            end
        end
    end
    self.diff_cache = nil
    for _, w in ipairs({ so, eo }) do
        if w and w.bufnr and api.nvim_buf_is_valid(w.bufnr) then
            api.nvim_buf_clear_namespace(w.bufnr, diff_ns, 0, -1)
        end
    end
    if not (self.diff_view and so and eo) then
        return nil
    end

    local tc = self.runner.tcdata[self.update_testcase or 1]
    if not tc then
        return nil
    end
    if tc.start_time == nil then
        -- Never run: there is no output to compare an answer against, so every line of
        -- what you are typing into Expected would be marked as a difference from an
        -- empty pane. A testcase added with `n` starts here, and it is the one moment
        -- the marks would be pure noise — wait until the solution has had a go at it.
        return nil
    end
    local output, expected = self:diff_texts(tc)
    if output == SKIP or expected == SKIP or expected == nil or expected == "" then
        return nil -- nothing to compare against, or a mode's own pane
    end

    local res = diff.compute(output, expected, self.runner:effective_compare())
    paint_diff(so.bufnr, res.out)
    paint_diff(eo.bufnr, res.exp)
    self.diff_cache = { tc = tc, out = output, exp = expected, first = res.first }
    return res.first
end

---Toggle the comparison between the Output and Expected Output panes.
function RunnerUI:toggle_diff_view()
    -- The marks are about to be cleared or painted from scratch, so what was cached
    -- for them no longer describes the screen.
    self.diff_cache = nil
    self.diff_view = not self.diff_view
    local first = self:render_diff()
    self:set_diff_bind(self.diff_view)
    -- The "Run" pane carries the diff's state, so pressing the key always visibly does
    -- something — even on a row where there is nothing to paint, which otherwise looks
    -- exactly like the key not working (which is how it was reported).
    self:update_status_line()
    if first then
        -- Land on the first disagreement: with a hundred lines of output, finding it
        -- is the whole reason the diff was asked for.
        for _, w in ipairs({ self.windows.so, self.windows.eo }) do
            if w and w.winid and api.nvim_win_is_valid(w.winid) then
                local line_count = api.nvim_buf_line_count(w.bufnr)
                pcall(api.nvim_win_set_cursor, w.winid, { math.min(first, line_count), 0 })
            end
        end
    end
end

---@private
function RunnerUI:disable_diff_view()
    self.diff_cache = nil
    self:set_diff_bind(false)
    for _, name in ipairs({ "so", "eo" }) do
        local w = self.windows[name]
        if w and w.bufnr and api.nvim_buf_is_valid(w.bufnr) then
            api.nvim_buf_clear_namespace(w.bufnr, diff_ns, 0, -1)
        end
    end
end

---@private
---Close the viewer popup (keeping the detail buffer it borrowed).
function RunnerUI:close_viewer()
    if self.viewer_winid and api.nvim_win_is_valid(self.viewer_winid) then
        api.nvim_win_close(self.viewer_winid, true)
    end
    self.viewer_winid = nil
    if self.windows.tc and api.nvim_win_is_valid(self.windows.tc.winid) then
        api.nvim_set_current_win(self.windows.tc.winid)
    end
end

---@private
---@private
---The geometry of the two large overlays that cover the grid — the viewer and the
---message float — both sized from `runner_ui.viewer` and centred on the editor.
---
---Both dimensions are bounded by the room there is, and both subtract the two border
---lines: a bordered float's footprint is its size *plus* its frame, so a `width` or
---`height` of 1.0 asks for a window two cells larger than the screen. The height is
---bounded by the float band (a row is kept clear above and below every float), the
---width by the screen, there being no horizontal margin.
---@param vcfg table `runner_ui.viewer`
---@return integer width, integer height, integer col, integer row
local function overlay_geometry(vcfg)
    local vim_width, vim_height = utils.get_ui_size()
    local band_row, band_h = utils.float_band()
    local width = math.max(1, math.min(math.floor(vim_width * vcfg.width + 0.5), vim_width - 2))
    local height = math.max(1, math.min(math.floor(vim_height * vcfg.height + 0.5), band_h - 2))
    -- Centred on the *footprint*, border included — `col`/`row` are where the frame is
    -- drawn, not where the text starts. Centring on the content width instead left the
    -- float a column right of centre, and at `width = 1.0` put its right border one
    -- cell off the screen even with the clamp above.
    return width,
        height,
        math.max(0, math.floor((vim_width - width - 2) / 2)),
        band_row + math.max(0, math.floor((band_h - height - 2) / 2))
end

---Open (or retarget) the viewer: a large float showing one detail pane's buffer.
---@param content string? detail window name; nil keeps the current one
function RunnerUI:show_viewer(content)
    self.viewer_content = content or self.viewer_content
    if not self.viewer_content then
        return
    end
    local source = self.windows[self.viewer_content]
    if not source then
        return
    end

    if self.viewer_winid and api.nvim_win_is_valid(self.viewer_winid) then
        api.nvim_win_set_buf(self.viewer_winid, source.bufnr)
        api.nvim_win_set_config(self.viewer_winid, { title = source.title, title_pos = "center" })
        api.nvim_set_current_win(self.viewer_winid)
        return
    end

    local vcfg = self.config.runner_ui.viewer
    local width, height, col, row = overlay_geometry(vcfg)
    self.viewer_winid = surface.float(source.bufnr, {
        layer = surface.LAYER.viewer, -- over the pane grid
        width = width,
        height = height,
        col = col,
        row = row,
        border = self.config.floating_border,
        border_highlight = self.config.floating_border_highlight,
        title = source.title,
        enter = true,
        keep_scrolloff = true, -- read like a buffer, not navigated like a list
    })
    vim.wo[self.viewer_winid].number = vcfg.show_nu
    vim.wo[self.viewer_winid].relativenumber = vcfg.show_rnu
    -- The source buffer already maps the close key to close_or_viewer (set in
    -- show_ui), which closes the viewer when it's open — no extra keymap needed.
    -- Handle the viewer being closed with ":q" so our state stays consistent.
    api.nvim_create_autocmd("WinClosed", {
        group = self.augroup,
        pattern = tostring(self.viewer_winid),
        once = true,
        callback = function()
            self.viewer_winid = nil
        end,
    })
end

---Close the UI entirely.
function RunnerUI:hide_ui()
    self:delete()
end

---@private
---Tear down every window/buffer and restore focus.
function RunnerUI:delete()
    if not self.ui_visible then
        return
    end
    for _, w in pairs(self.windows) do
        if w.bufnr and pane_owner[w.bufnr] == self.runner then
            pane_owner[w.bufnr] = nil
        end
    end
    -- The pane buffers are about to be wiped, so anything typed into them has to be
    -- moved into `pending` first — that is what lets a resize (which tears the UI
    -- down and rebuilds it) and a close-and-reopen keep an edit in progress.
    self:capture_pending()
    self.pane_tcnum = nil -- the panes are going away; nothing is on screen to capture
    self.pane_edited = false
    self.ui_visible = false
    if self.settle_timer then
        self.settle_timer:stop()
        self.settle_timer:close()
        self.settle_timer = nil
    end
    if self.augroup then
        pcall(api.nvim_del_augroup_by_id, self.augroup)
        self.augroup = nil
    end
    self:disable_diff_view()
    if self.viewer_winid and api.nvim_win_is_valid(self.viewer_winid) then
        api.nvim_win_close(self.viewer_winid, true)
    end
    self.viewer_winid = nil
    for _, w in pairs(self.windows) do
        if w.winid and api.nvim_win_is_valid(w.winid) then
            pcall(api.nvim_win_close, w.winid, true)
        end
        if w.bufnr and api.nvim_buf_is_valid(w.bufnr) then
            pcall(api.nvim_buf_delete, w.bufnr, { force = true })
        end
    end
    self.windows = {}
    if self.restore_winid and api.nvim_win_is_valid(self.restore_winid) then
        api.nvim_set_current_win(self.restore_winid)
    end
end

---Rebuild the UI after a `VimResized`, preserving the selected testcase.
function RunnerUI:resize_ui()
    self:redraw_grid()
end

---Show an ad-hoc message (e.g. a compilation error) in a large float, closable
---with the same keys as the viewer. Independent of the viewer's state.
---@param title string
---@param text string
---@param highlights table[]? `{ line, col, end_col, hl }` spans to paint, 0-based
function RunnerUI:show_message(title, text, highlights)
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
    for _, h in ipairs(highlights or {}) do
        pcall(api.nvim_buf_set_extmark, buf, ns, h.line, h.col, { end_col = h.end_col, hl_group = h.hl })
    end
    vim.bo[buf].modifiable = false
    surface.adopt(buf, "message")

    local width, height, col, row = overlay_geometry(self.config.runner_ui.viewer)
    local win = surface.float(buf, {
        layer = surface.LAYER.overlay, -- over the grid and the viewer
        width = width,
        height = height,
        col = col,
        row = row,
        border = self.config.floating_border,
        border_highlight = self.config.floating_border_highlight,
        title = title,
        enter = true,
    })
    for _, key in ipairs(as_list(self.config.runner_ui.mappings.close)) do
        vim.keymap.set("n", key, function()
            if api.nvim_win_is_valid(win) then
                api.nvim_win_close(win, true)
            end
        end, { buffer = buf, nowait = true })
    end
    surface.read_only(buf) -- read-only, like every other surface here
end

---@private
---The rectangle the results UI occupies on screen, borders included, as a footprint
---`{ row, col, width, height }` — or nil when nothing is on screen. A bordered float's
---reported position is already its **top-left border cell**, with the text one cell
---inside, so the two border lines are added to the
---size only and never subtracted from the origin — doing both shifts the box up and
---left by one, which is precisely a strip of the grid left showing along the bottom
---and the right edge. A split has no border and so needs neither.
---@return table?
function RunnerUI:ui_bounds()
    local top, left, bottom, right
    for _, w in pairs(self.windows) do
        if w.winid and api.nvim_win_is_valid(w.winid) then
            local pos = api.nvim_win_get_position(w.winid)
            local cfg = api.nvim_win_get_config(w.winid)
            local pad = (cfg.relative ~= "" and cfg.border and cfg.border ~= "none") and 2 or 0
            local r, c = pos[1], pos[2]
            local h = api.nvim_win_get_height(w.winid) + pad
            local wd = api.nvim_win_get_width(w.winid) + pad
            top = math.min(top or r, r)
            left = math.min(left or c, c)
            bottom = math.max(bottom or (r + h), r + h)
            right = math.max(right or (c + wd), c + wd)
        end
    end
    if not top then
        return nil
    end
    return { row = top, col = left, width = right - left, height = bottom - top }
end

---Show the key legend as the two columns the UI is really made of: the panes you only
---read on the left, wearing the ordinary border, and the ones you type into on the
---right, wearing their accent. Each half is framed in the colour of the panes it
---describes, so which keys apply where needs no explaining — and the halves are in the
---order the grid puts them, the read-only panes filling its left and the editable
---column down its right edge, so the legend covers each side with its own keys.
---
---The legend is sized to cover the results UI entirely rather than to its own content:
---a small float over the grid leaves the panes showing around it, and a legend read
---against half a set of testcase rows is a legend competing with what it explains.
function RunnerUI:show_help()
    local editable, readonly = self:legend_sections()
    local accent = self.config.runner_ui.editable_border_highlight
    local accent_hl = accent or self.config.floating_border_highlight
    local accent_group = accent and "TunaEditableBorder" or "TunaFloatBorder"
    local plain_hl = self.config.floating_border_highlight

    local vim_width = utils.get_ui_size()
    local band_row, band_h = utils.float_band()
    local function widest(lines)
        local w = 0
        for _, l in ipairs(lines) do
            w = math.max(w, vim.fn.strwidth(l))
        end
        return w
    end

    -- One column per pane kind, or a single stacked one when the editor is too narrow
    -- to hold both: a legend that cuts off the key it is naming is worse than a taller
    -- legend. Same story when nothing in this mode is editable — there is only one
    -- half to tell you about.
    local columns
    if not (self:writable_pane("si") or self:writable_pane("eo")) then
        columns = { { lines = readonly, title = " Keys ", hl = plain_hl, group = "TunaFloatBorder" } }
    elseif widest(editable) + widest(readonly) + 4 > vim_width - 2 then
        local lines = { "READ-ONLY PANES" }
        vim.list_extend(lines, readonly)
        vim.list_extend(lines, { "", "EDITABLE PANES" })
        vim.list_extend(lines, editable)
        columns = { { lines = lines, title = " Keys ", hl = plain_hl, group = "TunaFloatBorder" } }
    else
        columns = {
            { lines = readonly, title = " Read-only panes ", hl = plain_hl, group = "TunaFloatBorder" },
            { lines = editable, title = " Editable panes ", hl = accent_hl, group = accent_group },
        }
    end

    local height, natural = 0, 0
    for _, c in ipairs(columns) do
        c.width = widest(c.lines)
        height = math.max(height, #c.lines)
        natural = natural + c.width + 2 -- footprints, since the columns touch
    end

    -- Grow to the results UI's own rectangle, never shrink below the content: the
    -- legend has to blot out the grid it describes, and a legend that cuts off the key
    -- it is naming is worse than one larger than the grid.
    local bounds = self:ui_bounds()
    height = math.max(1, math.min(math.max(height, bounds and bounds.height - 2 or 0), band_h - 2))
    local total = math.min(math.max(natural, bounds and bounds.width or 0), vim_width)

    -- Hand the slack to the columns so their frames tile the whole footprint rather
    -- than leaving a stripe of the UI showing beside them.
    local slack = total - natural
    for i, c in ipairs(columns) do
        if slack > 0 then
            local share = math.floor(slack / #columns)
            c.width = c.width + (i == #columns and slack - share * (#columns - 1) or share)
        end
        c.width = math.max(1, math.min(c.width, vim_width - 2))
    end
    total = 0
    for _, c in ipairs(columns) do
        total = total + c.width + 2
    end

    -- Centred on the UI it covers (on the editor when there is none), then kept inside
    -- the float band and the screen.
    local row = bounds and bounds.row - math.floor((height + 2 - bounds.height) / 2)
        or band_row + math.floor((band_h - height - 2) / 2)
    local at = bounds and bounds.col - math.floor((total - bounds.width) / 2)
        or math.floor((vim_width - total) / 2)
    row = math.max(band_row, math.min(row, band_row + band_h - height - 2))
    at = math.max(0, math.min(at, vim_width - total))

    local wins = {}
    for _, c in ipairs(columns) do
        local buf = api.nvim_create_buf(false, true)
        api.nvim_buf_set_lines(buf, 0, -1, false, c.lines)
        vim.bo[buf].modifiable = false
        surface.adopt(buf, "help")
        local win = surface.float(buf, {
            layer = surface.LAYER.overlay,
            width = c.width,
            height = height,
            col = at,
            row = row,
            border = self.config.floating_border,
            border_highlight = c.hl,
            -- The title takes the *derived* group, whose background is the border's —
            -- see `accent_editable_panes` for why the configured one won't do.
            border_group = c.group,
            title = { { c.title, c.group } },
        })
        wins[#wins + 1] = { win = win, buf = buf }
        at = at + c.width + 2 -- the columns touch, as the runner UI's own panes do
    end

    -- The columns are one legend, so whichever way one of them goes — the close key, a
    -- `:q`, a `:close` — the other goes with it.
    local wins_only = {}
    for _, w in ipairs(wins) do
        wins_only[#wins_only + 1] = w.win
    end
    local close_all = surface.group(wins_only)

    local switch = as_list(self.config.switch_window_keys or {})
    for _, w in ipairs(wins) do
        for _, key in ipairs(as_list(self.config.runner_ui.mappings.close)) do
            vim.keymap.set("n", key, close_all, { buffer = w.buf, nowait = true })
        end
        -- The halves are a pair, so move between them with the keys that move between
        -- panes everywhere else (left/up → first, right/down → last).
        for i, key in ipairs(switch) do
            local target = (i == 1 or i == 3) and wins[1] or wins[#wins]
            vim.keymap.set("n", key, function()
                if target and api.nvim_win_is_valid(target.win) then
                    api.nvim_set_current_win(target.win)
                end
            end, { buffer = w.buf, nowait = true })
        end
        -- The legend is as read-only as the panes are, so it gets the same treatment:
        -- an `i` or a `c` here can only end in `E21` a keystroke later.
        surface.read_only(w.buf)
    end
    api.nvim_set_current_win(wins[1].win)
end

---@private
---Pad/truncate `str` to display width `len`.
local function fit(len, str)
    local w = vim.fn.strwidth(str)
    if w <= len then
        return str .. string.rep(" ", len - w)
    end
    return vim.fn.strcharpart(str, 0, len - 1) .. "…"
end

---@private
---The selector's three columns for a pane `width` wide: how wide the header and the verdict
---columns are, and whether the time still fits after them. Ten-wide columns are what every
---mode's rows line up on, so they are kept while they fit. A pane too narrow for them (the
---conversation layout's selector, which gives most of its width to the three columns of the
---conversation) sizes both to their content instead, and failing that gives the time up: a
---pane cutting a number in half says something untrue about the run.
---@param entries { header: string, status: string, time: string }[]
---@param width integer? nil when the selector has no window, so nothing is cutting the rows
---@return integer head_col, integer status_col, boolean with_time
local function selector_columns(entries, width)
    local WIDE = 10
    local head_w, st_w, time_w = 0, 0, 0
    for _, e in ipairs(entries) do
        head_w = math.max(head_w, vim.fn.strwidth(e.header))
        st_w = math.max(st_w, vim.fn.strwidth(e.status))
        time_w = math.max(time_w, vim.fn.strwidth(e.time))
    end
    -- A content-sized column keeps one space after it, so the longest header or verdict
    -- still reads as a column rather than running into the next one.
    local options = {
        { WIDE, WIDE, true },
        { math.min(head_w, WIDE) + 1, math.min(st_w, WIDE) + 1, true },
        { math.min(head_w, WIDE) + 1, math.min(st_w, WIDE) + 1, false },
        -- Narrower than even that: split what there is between the two, so `fit` marks the
        -- cut with an ellipsis rather than the pane's edge swallowing the end of a word.
        { math.max(3, math.floor((width or WIDE * 2) / 2)), math.max(3, math.ceil((width or WIDE * 2) / 2)), false },
    }
    for _, try in ipairs(options) do
        if not width or try[1] + try[2] + (try[3] and time_w or 0) <= width then
            return try[1], try[2], try[3]
        end
    end
    local last = options[#options]
    return last[1], last[2], last[3]
end

---The runner whose UI holds `bufnr`, if that is one of its panes (the viewer borrows a pane's
---buffer, so it is covered too).
---@param bufnr integer
---@return table?
function M.owner_of(bufnr)
    local r = pane_owner[bufnr]
    if r and r.bufnr and api.nvim_buf_is_valid(r.bufnr) then
        return r
    end
    return nil
end

---@private
---How wide the selector pane is, or nil when the layout gave it no window (its buffer is
---still kept, and nothing truncates a buffer).
---@return integer?
function RunnerUI:selector_width()
    local w = self.windows.tc
    if w and w.winid and api.nvim_win_is_valid(w.winid) then
        return api.nvim_win_get_width(w.winid)
    end
    return nil
end

---@private
---The lines shown in the "Run" status pane: the run mode, the verdict source, a mode's own
---settings (`status_settings`), which of those were forced, then any runner-specific tail
---(e.g. the stress counters). The compile
---step is *not* here — it's a testcase row, so its warnings are viewable. The
---count is stable for a given runner, so it can size the pane at build time.
---@return string[]
function RunnerUI:status_lines()
    -- Each entry is a { label, value } pair; the colons are aligned by padding
    -- every label to the widest one.
    -- Third row: whether the comparison is on, and nothing else. It is a *state*, not an
    -- event, so it belongs on screen rather than in a message — and pressing the key
    -- always visibly does something, even on a row with nothing to paint. Why a row has
    -- nothing to paint is deliberately not spelled out here: it changes as you move
    -- between rows, which turns a state row into a running commentary, and the panes
    -- themselves already say it (no answer, no run, or two texts that agree).
    local diff_state = self.diff_view and "on" or "off"
    local mode = self.runner.mode or "normal"
    local bufnr = self.runner.bufnr
    local path = (bufnr and api.nvim_buf_is_valid(bufnr)) and api.nvim_buf_get_name(bufnr) or ""
    -- Which settings are your choice rather than tuna's, on a row of their own: this is one
    -- fact about the run, not one per setting, and a word appended to each value is the
    -- first thing a pane this narrow cuts off. The names are the rows they speak for.
    local tools = require("tuna.tools")
    local forced = {}
    if path ~= "" then
        if tools.get_mode(path) == mode then
            forced[#forced + 1] = "mode"
        end
        -- A checker is only ever found, never forced on, so the judge is your choice when you
        -- turned the checker off, or when the comparison it falls back to is overridden.
        if type(self.runner.checker) ~= "table" and (tools.checker_setting(path) == "off" or tools.get_compare(path)) then
            forced[#forced + 1] = "judge"
        end
        if self.runner.source and tools.get_source(path) == self.runner.source then
            forced[#forced + 1] = "source"
        end
    end
    local entries = {
        { "mode", mode },
        { "judge", self.runner.judge_label and self.runner:judge_label() or "builtin" },
    }
    -- A mode's own settings stand with the others, above the row saying which were forced
    -- (interactive's input source). Counters and the like come after, in `status_tail`.
    if self.runner.status_settings then
        vim.list_extend(entries, self.runner:status_settings())
    end
    entries[#entries + 1] = { "forced", #forced > 0 and table.concat(forced, ", ") or "none" }
    entries[#entries + 1] = { "diff", diff_state }
    if self.runner.status_tail then
        vim.list_extend(entries, self.runner:status_tail())
    end
    -- A fixed pointer at the full legend: a digest of the keys goes stale or runs long,
    -- and an unsaved edit is shown where it belongs, on its own row as `EDITED`.
    entries[#entries + 1] = { "help", as_list(self.config.runner_ui.mappings.help or {})[1] or "?" }

    local width = 0
    for _, e in ipairs(entries) do
        width = math.max(width, #e[1])
    end
    local lines = {}
    for _, e in ipairs(entries) do
        lines[#lines + 1] = string.format("%-" .. width .. "s: %s", e[1], e[2])
    end
    return lines
end

---@private
---Fill the "Run" status pane. Its own rectangle above the Testcases pane, in both
---the popup and split interfaces.
function RunnerUI:update_status_line()
    local w = self.windows.st
    if not (w and w.bufnr and api.nvim_buf_is_valid(w.bufnr)) then
        return
    end
    surface.render(w.bufnr, self:status_lines())
end

---@private
---Move focus to the nearest pane in direction `dir` ("h"/"j"/"k"/"l"), chosen by
---window geometry. Works for the floating (popup) interface too, where the
---built-in `<C-w>hjkl` motions don't cross floating windows.
---@param dir string
function RunnerUI:focus_dir(dir)
    local cur = api.nvim_get_current_win()
    local from, targets = nil, {}
    for _, name in ipairs({ "tc", "so", "eo", "si", "se", "st" }) do
        local w = self.windows[name]
        if w and w.winid and api.nvim_win_is_valid(w.winid) then
            local pos = api.nvim_win_get_position(w.winid)
            local t = {
                winid = w.winid,
                r = pos[1] + api.nvim_win_get_height(w.winid) / 2,
                c = pos[2] + api.nvim_win_get_width(w.winid) / 2,
            }
            -- The "Run" pane is a **read-out**, not a place to be: it holds no testcase,
            -- no keys of its own and nothing to select, so stepping into it only costs a
            -- press to step back out. It stays a possible *source* — a stray click or
            -- `<C-w>w` can still put the cursor there, and the directional keys have to
            -- get you out — but never a destination.
            if name ~= "st" then
                targets[#targets + 1] = t
            end
            if w.winid == cur then
                from = t
            end
        end
    end
    if not from then
        -- The viewer isn't part of the grid, so there is no direction to move in from
        -- it. Rather than doing nothing (a big float you can only leave one way), take
        -- a directional key as "done looking": close it and move on from the selector.
        if self.viewer_winid and cur == self.viewer_winid then
            self:close_viewer()
            return self:focus_dir(dir)
        end
        return
    end
    local best, bestscore
    for _, t in ipairs(targets) do
        if t.winid ~= cur then
            local dr, dc = t.r - from.r, t.c - from.c
            local score
            if dir == "h" and dc < -0.5 then
                score = -dc + 3 * math.abs(dr)
            elseif dir == "l" and dc > 0.5 then
                score = dc + 3 * math.abs(dr)
            elseif dir == "k" and dr < -0.5 then
                score = -dr + 3 * math.abs(dc)
            elseif dir == "j" and dr > 0.5 then
                score = dr + 3 * math.abs(dc)
            end
            if score and (not bestscore or score < bestscore) then
                bestscore, best = score, t.winid
            end
        end
    end
    if best then
        api.nvim_set_current_win(best)
    end
end

---@private
---Redraw the testcase selector from `tcdata`. Split out of `update_ui` because
---typing in a pane has to refresh the rows' `EDITED` state *without* re-rendering
---the detail panes — rewriting the buffer under the cursor on every keystroke would
---throw the cursor back to line 1.
function RunnerUI:render_selector()
    if not (self.ui_visible and self.windows.tc and api.nvim_buf_is_valid(self.windows.tc.bufnr)) then
        return
    end
    local edited = self:unsaved_testcases()
    -- What `on_pane_edit` compares against: as long as the same rows are edited, a
    -- keystroke has nothing to redraw here.
    self.edited_sig = table.concat(edited, ",")
    local unsaved = {}
    for _, n in ipairs(edited) do
        unsaved[n] = true
    end
    local entries = {}
    for i, tc in ipairs(self.runner.tcdata) do
        -- The left column: a mode may relabel rows (run-all groups solution
        -- header rows above indented per-testcase rows).
        -- A row standing for no stored testcase names itself (`Compile`); a numbered
        -- one is a testcase. The bare row of a run with nothing to test is the case
        -- between the two: it is testcase 0 and editable, but nothing is on disk yet,
        -- so it says why it is there — until it has something behind it, which is
        -- either an unwritten edit or, once `bare` is cleared, a saved file.
        local header
        if self.runner.row_label then
            header = self.runner:row_label(tc)
        elseif tc.bare and not unsaved[tc.tcnum] then
            header = "No input"
        else
            header = type(tc.tcnum) == "number" and ("TC " .. tc.tcnum) or tostring(tc.tcnum)
        end
        -- No runtime for a just-saved counterexample: show its label
        -- (e.g. "saved") in the time column instead.
        local timestr = (tc.time and tc.time >= 0) and string.format("%.3f s", tc.time / 1000)
            or (tc.time_label or "")
        -- A row with an edit that hasn't been written reads `EDITED` instead of
        -- its verdict: the verdict describes the *saved* testcase, so while the
        -- two disagree it would be a claim about text that is no longer there.
        -- It says so on the row it is about, and lasts until the edit is saved
        -- (which re-runs it) or undone away. Unstyled (`TunaDone`, as `NOT RUN` is):
        -- it is the *absence* of a verdict, not a bad one, and amber is the plugin's
        -- warning colour, while nothing is wrong with an edit.
        local status, hlgroup = tc.status, tc.hlgroup
        if unsaved[tc.tcnum] then
            status, hlgroup = "EDITED", "TunaDone"
        end
        entries[i] = { header = header, status = status, time = timestr, hlgroup = hlgroup }

        -- Auto-pop the viewer onto a fresh compilation failure's stderr.
        if
            tc.tcnum == "Compile"
            and self.config.runner_ui.viewer.open_when_compilation_fails
            and not tc.killed
            and tc.exit_code
            and tc.exit_code ~= 0
            and tc.start_time ~= self.latest_compile_token
        then
            self.latest_compile_token = tc.start_time
            self.update_testcase = i
            self.viewer_content = "se"
            self.make_viewer_visible = true
        end
    end

    local head_col, st_col, with_time = selector_columns(entries, self:selector_width())
    local lines, regions = {}, {}
    for i, e in ipairs(entries) do
        -- The highlight is byte-addressed while `fit` pads by *display* width, so the
        -- status column's byte offset has to be measured off the padded header — a
        -- multibyte or truncated header (run-all's solution names) shifts it past its column.
        local head, st = fit(head_col, e.header), fit(st_col, e.status)
        lines[i] = head .. st .. (with_time and e.time or "")
        regions[i] = { line = i - 1, hlgroup = e.hlgroup, col = #head, len = #(st:gsub("%s+$", "")) }
    end

    local buf = self.windows.tc.bufnr
    surface.render(buf, lines)
    -- While the choice is still the UI's, its row stays under the cursor, and follows the
    -- list when a rebuild is shorter than it: Vim would otherwise clamp the cursor onto
    -- another row, which is indistinguishable from a move made by hand.
    local tc_win = self.windows.tc.winid
    if not self.user_moved and self.update_testcase and tc_win and api.nvim_win_is_valid(tc_win) then
        local want = math.max(1, math.min(self.update_testcase, #lines))
        if want ~= self.update_testcase then
            self:select_row(want)
        end
        if api.nvim_win_get_cursor(tc_win)[1] ~= want then
            pcall(api.nvim_win_set_cursor, tc_win, { want, 0 })
        end
    end
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, r in ipairs(regions) do
        if r.len > 0 then
            api.nvim_buf_set_extmark(buf, ns, r.line, r.col, {
                end_col = r.col + r.len,
                hl_group = r.hlgroup,
            })
        end
    end
end

---Re-render the UI from the runner's `tcdata`. Honours the `update_windows` /
---`update_details` one-shot flags set by `TCRunner:update_ui`.
function RunnerUI:update_ui()
    -- One render per tick, however many updates ask for it. The flags below are
    -- cumulative and the render reads the runner's current `tcdata`, so a queued
    -- render already covers every call that arrives before it runs, so a fast runner
    -- (stress, or a batch of testcases landing together) costs one rebuild per tick
    -- rather than one per event.
    if self.render_scheduled then
        return
    end
    self.render_scheduled = true
    vim.schedule(function()
        self.render_scheduled = false
        if not self.ui_visible then
            return
        end
        -- Anything typed into a pane and not yet written has to be in `pending` before
        -- this render touches the panes, or the saved text would be pasted over it.
        -- Here, at the top, because it is attributed to the row the panes are *showing*
        -- and a compile failure below can move `update_testcase` off it. (Nothing
        -- captures while you type — see `on_pane_edit` — so this is where that cost is
        -- paid: once per render, not once per keystroke.)
        self:capture_pending()
        -- Which row to open on, decided now that there are rows to choose from. The cursor is
        -- put on it by the render below, so the two never disagree.
        if self.opening and next(self.runner.tcdata) ~= nil then
            self.opening = false
            if not self.user_moved then
                self.update_testcase = self:opening_row()
            end
        end
        -- The row on screen decides the grid (the build step gets Errors and nothing else),
        -- so a row of another kind means the panes are rebuilt before anything is drawn into
        -- them. The redraw renders on its own tick.
        if not vim.deep_equal((self:row_layout()), self.drawn_layout) then
            self:redraw_grid()
            return
        end
        -- Always refresh the status line (stress progress updates even before any
        -- testcase/counterexample exists).
        self:update_status_line()
        if next(self.runner.tcdata) == nil then
            return
        end

        if self.update_windows then
            self.update_windows = false
            self.update_details = true
            self:render_selector()
        end
        self:follow_after_compile()

        local rendered_details = self.update_details
        if self.update_details then
            self.update_details = false
            local tc = self.runner.tcdata[self.update_testcase or 1]
            if tc then
                local editable = self.runner:row_editable(tc)
                -- An edit typed but not written wins over what is on disk: results
                -- landing on this row must not overwrite what you are in the middle
                -- of typing, and coming back to the row must show it again.
                local pending = editable and self.pending[tc.tcnum] or nil
                -- On the build step the panes are the sources being compiled, one each,
                -- whatever they mean on a testcase row, so they are filled from here and
                -- not from the mode: a build is the same thing in every mode.
                local build = self:build_assignment(tc)
                -- Ask the runner what each detail pane should show. A mode can own a
                -- pane (return SKIP) so we don't clobber it — e.g. interactive's
                -- editable Input pane while you're typing into it.
                for _, name in ipairs(detail_windows) do
                    local writable = editable and (name == "si" or name == "eo")
                    -- What is stored, and what to show: the two differ exactly when an
                    -- unwritten edit is being restored into the pane.
                    local base = (build and build.text[name]) or self.runner:pane_content(tc, name)
                    local content = base
                    if pending and name == "si" then
                        content = pending.stdin
                    elseif pending and name == "eo" then
                        content = pending.expected
                    end
                    if content ~= SKIP then
                        local shown = surface.render(self.windows[name].bufnr, content, { modifiable = writable })
                        -- Deliberately *not* marked modified when an unwritten edit is
                        -- restored: `pending` is what says the row is unsaved, and a
                        -- pane left modified is a scratch buffer Vim then refuses to
                        -- quit past (see `clear_pane_modified`).
                        -- The baseline an edit is measured against is the **stored**
                        -- text, never the pending text just put on screen: measured
                        -- against the latter, a restored edit would compare equal to
                        -- itself and stop counting as unsaved.
                        self.windows[name].baseline = content == base and shown
                            or vim.split(base ~= SKIP and base or "", "\n", { plain = true })
                    end
                end
                -- A mode that draws panes itself (interactive's conversation columns,
                -- whose rows have to be laid out together) does it here, once every pane
                -- it doesn't own has been rendered.
                if self.runner.on_details_rendered then
                    self.runner:on_details_rendered(self, tc)
                end
                -- Which testcase the panes are now showing, i.e. whom a later edit of
                -- them belongs to. `nil` on a row with nothing to edit (`Compile`,
                -- run-all's solution headers), so nothing can be captured for it.
                self.pane_tcnum = editable and tc.tcnum or nil
                -- The panes now hold exactly what they were given, so the only unwritten
                -- edit on screen is one restored from `pending`.
                self.pane_edited = pending ~= nil
                -- The panes were just rewritten, so the marks on them are stale:
                -- re-diff whatever they now hold.
                if self.diff_view then
                    self:render_diff()
                end
            end
        end

        -- The status line's "unsaved" row is derived from the *panes*, so it has to be
        -- written after them. Computed before, it read the outgoing row's dirty state
        -- against the incoming row's number — which is why stepping onto a row could
        -- announce an edit nobody had made.
        if rendered_details then
            self:update_status_line()
        end

        if self.make_viewer_visible then
            self.make_viewer_visible = false
            self:show_viewer()
        end
    end)
end

-- The pure half of the selector's layout, for the test suite.
M._test = { selector_columns = selector_columns }

return M
