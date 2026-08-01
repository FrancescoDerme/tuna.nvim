-- lua/tuna/runner_ui/init.lua
--
-- The runner results UI. It owns a set of windows (a testcase selector plus four
-- detail panes: stdout/expected/stdin/stderr), keeps them in sync with the
-- `TCRunner`'s `tcdata`, and wires the interactive keymaps (run again, kill,
-- view in a bigger popup, toggle diff, close).
--
-- The actual window geometry is delegated to an "interface" module — `popup`
-- (floats) or `split` (real splits) — selected by `runner_ui.interface`. This
-- module is interface-agnostic: it only touches `windows[name].bufnr/winid`.
--
-- Design note vs competitest: all displayed content lives in the runner's
-- `tcdata`, so we don't bother hiding-and-restoring windows. Closing tears the UI
-- down; showing rebuilds it and re-renders from `tcdata`. That removes a lot of
-- nui-era state bookkeeping while looking identical to the user.

local api = vim.api
local utils = require("tuna.utils")
local diff = require("tuna.diff")
local SKIP = require("tuna.runner.core").SKIP

local M = {}

local ns = api.nvim_create_namespace("tuna_runner_ui")
-- Its own namespace, so the diff can be painted and cleared without touching the
-- selector's status highlights.
local diff_ns = api.nvim_create_namespace("tuna_runner_diff")
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
---Normalise a mapping spec (string or list) to a list of keys.
local function as_list(maps)
    return type(maps) == "string" and { maps } or maps
end

-- Every abbreviation of the commands that would close a pane (or the editor) out from
-- under an unsaved testcase edit. `:wq`/`:x` are deliberately absent: they write
-- first, which through the pane's `BufWriteCmd` *is* saving the testcase.
local QUIT_COMMANDS = {}
for _, name in ipairs({ "q", "qu", "qui", "quit", "qa", "qal", "qall", "quita", "quitall", "clo", "clos", "close" }) do
    QUIT_COMMANDS[name] = true
end

-- Keys that begin a change. On a read-only pane they can only end in `E21: Cannot
-- make changes, 'modifiable' is off` — sometimes a keystroke later, from a mode the
-- user never meant to enter — so they are made inert wherever nothing else claims
-- them. (`u`/`<C-r>` are not here: undo on an unchangeable buffer is harmless, and
-- both are the plugin's own actions in this UI.)
local INERT_KEYS = {
    "i", "I", "a", "A", "o", "O", "c", "C", "s", "S", "r", "R", "x", "X", "d", "D",
    "p", "P", "J", "~", "v", "V", "<C-v>", "<Insert>", "gi", "gI", "gp", "gP", "gJ", "g~",
}

---@private
---Make the change-starting keys inert on a buffer that cannot take a change. Bound
---only where nothing is mapped yet, so a pane's real actions (`i`/`a`/`o`/`e` opening
---the viewer, `x`/`R`/`u` acting on a testcase) keep their meanings — which is why this
---runs *after* the actions are set. Every read-only surface the plugin puts in front of
---the user goes through it: the panes, the legend and the message float alike.
---@param bufnr integer
local function make_inert(bufnr)
    local taken = {}
    for _, m in ipairs(api.nvim_buf_get_keymap(bufnr, "n")) do
        taken[m.lhs] = true
    end
    for _, key in ipairs(INERT_KEYS) do
        if not taken[key] then
            vim.keymap.set("n", key, "<Nop>", { buffer = bufnr, nowait = true })
        end
    end
end

---@private
---Whether a typed command line is one of those, and whether it carried a `!`.
---@param line string
---@return boolean? # nil when it isn't a quit command, else true if forced
local function quit_command(line)
    local cmd, bang = line:match("^%s*(%a+)(!?)%s*$")
    if cmd and QUIT_COMMANDS[cmd] then
        return bang == "!"
    end
    return nil
end

---@private
---The testcase index under the selector cursor (1:1 with `tcdata`; the Compile
---pseudo-testcase, when present, is row 1).
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
    for name, w in pairs(self.windows) do
        if self:writable_pane(name) and w.winid and api.nvim_win_is_valid(w.winid) then
            local cfg = api.nvim_win_get_config(w.winid)
            if cfg.border and cfg.border ~= "none" then
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
            { "edit", "just type — these are ordinary buffers" },
            { "save + re-run", ":w" },
            { "", "" },
        })
    end
    vim.list_extend(editable, {
        { "switch pane", switch .. "  (also from insert mode)" },
        { "close", keys("close") .. "  (normal mode)" },
        { "this legend", keys("help") },
        { "", "" },
        { "everything else", "Vim's own — d deletes, r replaces, u undoes" },
    })

    local readonly = align({
        { "run again", keys("run_again") },
        { "run all again", keys("run_all_again") },
        { "kill", keys("kill") },
        { "kill all", keys("kill_all") },
        { "toggle diff", keys("toggle_diff") },
        { "view output / expected", keys("view_stdout") .. "  " .. keys("view_output") },
        { "view input / errors", keys("view_input") .. "  " .. keys("view_stderr") },
        { "", "" },
        { "new testcase", keys("add_testcase") },
        { "delete testcase", keys("delete_testcase") },
        { "undo delete", keys("undo_delete") },
        { "", "" },
        { "switch pane", switch },
        { "close", keys("close") },
        { "this legend", keys("help") },
    })
    return align(editable), readonly
end

---@private
---Close the UI, asking first when testcase edits would be thrown away. The prompt is
---a float like every other tuna dialog, and it is the only one in this flow: routine
---editing never asks anything.
---@param torn boolean? the windows are already gone (a `:q` on one pane)
function RunnerUI:request_close(torn)
    if not self:has_pending() then
        self:delete()
        return
    end
    local nums = self:unsaved_testcases()
    local label = #nums == 1 and ("testcase " .. nums[1]) or ("testcases " .. table.concat(nums, ", "))
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
        { "Save and close", "Discard changes", "Keep editing" },
        "unsaved " .. label,
        function(idx)
            if idx == 1 then
                self:save_all_pending()
                self:delete()
            elseif idx == 2 then
                self:discard_pending()
                self:delete()
            end
        end,
        back_to,
        function() end
    )
end

---Run `proceed`, but settle any unsaved edit it would silently throw away first.
---Re-running a testcase you have edited but not written would feed the *old* input to
---the solution and then report a verdict for text that is no longer the text on
---screen — so ask, with the same three answers as closing does.
---@param tcnum integer? only care about this testcase (nil: any unsaved edit at all)
---@param what string the action, for the prompt's title
---@param proceed fun()
function RunnerUI:with_pending_settled(tcnum, what, proceed)
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

    local label = #nums == 1 and ("testcase " .. nums[1]) or ("testcases " .. table.concat(nums, ", "))
    require("tuna.widgets").menu(
        { "Save and " .. what, "Discard and " .. what, "Cancel" },
        "unsaved " .. label,
        function(idx)
            if idx == 1 then
                -- Saving re-runs what it saved, so the run is already under way.
                self:save_all_pending()
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
---Whether the row shown in the panes is a stored testcase, i.e. editable.
---@return boolean
function RunnerUI:editing_row()
    return self.runner:row_editable(self:current_row())
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
---Move an edit in progress out of the (shared) pane buffers and into `pending`,
---before anything repoints those panes at a different row.
function RunnerUI:capture_pending()
    if not self:editing_row() then
        return
    end
    local tc = self:current_row()
    local si, eo = self.windows.si, self.windows.eo
    local dirty = (si and si.bufnr and api.nvim_buf_is_valid(si.bufnr) and vim.bo[si.bufnr].modified)
        or (eo and eo.bufnr and api.nvim_buf_is_valid(eo.bufnr) and vim.bo[eo.bufnr].modified)
    if not dirty then
        -- Undone (or redone) back to the saved text: there is no edit any more, and the
        -- row must stop reading `EDITED`.
        self.pending[tc.tcnum] = nil
        return
    end
    self.pending[tc.tcnum] = { stdin = self:pane_text("si"), expected = self:pane_text("eo") }
end

---@private
---Select a selector row, first rescuing any unsaved edit shown in the panes.
---@param idx integer
function RunnerUI:select_row(idx)
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
    local tc = self:current_row()
    if self:editing_row() and not self.pending[tc.tcnum] then
        for _, name in ipairs({ "si", "eo" }) do
            local w = self.windows[name]
            if w and w.bufnr and api.nvim_buf_is_valid(w.bufnr) and vim.bo[w.bufnr].modified then
                nums[#nums + 1] = tc.tcnum
                break
            end
        end
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
    for _, name in ipairs({ "si", "eo" }) do
        local w = self.windows[name]
        if w and w.bufnr and api.nvim_buf_is_valid(w.bufnr) then
            vim.bo[w.bufnr].modified = false
        end
    end
end

---Write the edits shown in the panes (or held for `tcnum`) to disk and re-run.
---@param tcnum integer
---@return boolean
function RunnerUI:save_testcase(tcnum)
    local p = self.pending[tcnum]
    local input, expected
    if p and tcnum ~= (self:current_row() or {}).tcnum then
        input, expected = p.stdin, p.expected
    else
        input, expected = self:pane_text("si"), self:pane_text("eo")
    end
    if not self.runner:save_testcase(tcnum, input, expected) then
        return false
    end
    self.pending[tcnum] = nil
    for _, name in ipairs({ "si", "eo" }) do
        local w = self.windows[name]
        if w and w.bufnr and api.nvim_buf_is_valid(w.bufnr) and tcnum == (self:current_row() or {}).tcnum then
            vim.bo[w.bufnr].modified = false
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
    local n = self.runner:next_tcnum()
    self.runner:add_testcase_row(n)
    self.pending[n] = { stdin = "", expected = "" }
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
---Delete the testcase under the cursor. No confirmation: it goes on an undo stack
---the runner keeps, and `u` puts it back — cheaper to press than a dialog, and
---recoverable, which a dialog does not make it.
function RunnerUI:delete_testcase()
    local tc = self.runner.tcdata[self:cursor_tc()]
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
    utils.notify("testcase " .. n .. " deleted (u to undo).", "INFO")
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
    self.runner:save_testcase(last.tcnum, last.input, last.expected)
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

---@private
---Which selector row the UI should open on. The first testcase, whenever the Compile
---step has nothing to say: an empty compile row leaves four empty panes in front of
---someone who opened the UI to read a verdict — or, before any run, to read the
---testcase itself. Row 1 (Compile) is kept for the two cases where it is the row worth
---reading: a compilation that printed warnings or errors, and a run still in flight,
---where the cursor must not be moved out from under the user as results land.
---@return integer
function RunnerUI:initial_row()
    local first = self.runner.tcdata[1]
    if not first or first.tcnum ~= "Compile" or not self.runner.tcdata[2] then
        return 1
    end
    -- Worth reading: it printed warnings or errors, or it is still being written to.
    if (first.stdout or "") ~= "" or (first.stderr or "") ~= "" or first.running or first.judging then
        return 1
    end
    return 2
end

---@private
---Which row to open on: the one last looked at, if it is still there. Matched by
---identity rather than line number, so it survives the rows being rebuilt — and
---falls back to `initial_row` on the first open of a runner, when the row it names
---was deleted, or after a fresh set of testcases was loaded.
---@return integer
function RunnerUI:opening_row()
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

---Show the UI, building it if needed and focusing the selector.
function RunnerUI:show_ui()
    if self.ui_visible then
        api.nvim_set_current_win(self.windows.tc.winid)
        return
    end

    self.restore_winid = self.restore_winid or api.nvim_get_current_win()
    -- The "Run" pane is sized to the runner's (stable) status-line count.
    local status_height = math.max(1, #self:status_lines())
    self.interface.init_ui(self.windows, self.config, self.restore_winid, status_height)
    self.ui_visible = true
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
            api.nvim_create_autocmd("WinClosed", {
                group = self.augroup,
                pattern = tostring(w.winid),
                callback = function()
                    -- Out of the autocmd before touching windows: this fires *during*
                    -- the close, where opening or closing more of them is unsafe.
                    vim.schedule(function()
                        self:request_close(true)
                    end)
                end,
            })
        end
    end

    -- `:q` (or `:close`, or `:qa`) typed in a pane holding an unsaved testcase edit is
    -- **cancelled before it runs**, and the same Save / Discard / Keep prompt is shown
    -- instead. Cancelling at the command line is what makes this silent and still: the
    -- window is never closed, so there is nothing to flash back into place, and Vim
    -- never gets far enough to raise its own red "E37: No write since last change" —
    -- which would be shouting about something the prompt is already handling. (The
    -- abort has to be set from Vimscript: `vim.v.event` reads back a *copy* in Lua, so
    -- assigning to it there is silently lost — verified.) A `!` is an explicit
    -- discard, so it is honoured: drop the edits and let the command through.
    api.nvim_create_autocmd("CmdlineLeave", {
        group = self.augroup,
        callback = function()
            if not self.ui_visible then
                return
            end
            local buf = api.nvim_get_current_buf()
            local editing = false
            for _, name in ipairs({ "si", "eo" }) do
                local w = self.windows[name]
                if w and w.bufnr == buf and self:writable_pane(name) then
                    editing = true
                end
            end
            if not editing then
                return
            end
            local forced = quit_command(vim.fn.getcmdline())
            if forced == nil or not self:has_pending() then
                return
            end
            if forced then
                self:discard_pending()
                return
            end
            vim.cmd("let v:event.abort = v:true")
            vim.schedule(function()
                self:request_close()
            end)
        end,
    })

    -- `:w` in an editable pane saves that testcase — the same gesture as saving any
    -- other buffer, which is the whole point of leaving the panes modifiable.
    for _, name in ipairs({ "si", "eo" }) do
        local w = self.windows[name]
        if w and w.bufnr and self:writable_pane(name) and self.runner.editable_testcases then
            -- `acwrite` routes `:w` through the autocmd below instead of trying to
            -- write a scratch buffer to disk. (The name `:w` also needs, or it aborts
            -- with E32 before the autocmd fires, comes from the interface — see
            -- `utils.name_float_buffer`.)
            vim.bo[w.bufnr].buftype = "acwrite"
            api.nvim_create_autocmd("BufWriteCmd", {
                group = self.augroup,
                buffer = w.bufnr,
                callback = function()
                    local tc = self:current_row()
                    if self.runner:row_editable(tc) then
                        self:save_testcase(tc.tcnum)
                    else
                        utils.notify("this row is not a testcase, so there is nothing to save.", "WARN")
                    end
                end,
            })
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
                    self:capture_pending()
                    self:render_selector()
                    self:update_status_line()
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

    map_tc("kill", function()
        self.runner:kill_process(self:cursor_tc())
    end)
    map_tc("kill_all", function()
        self.runner:kill_all_processes()
    end)
    map_tc("run_again", function()
        local idx = self:cursor_tc()
        local tc = self.runner.tcdata[idx]
        -- Re-running a row you have edited but not saved would run the *old* input and
        -- report a verdict for text that is no longer what you are looking at. Ask.
        self:with_pending_settled(tc and tc.tcnum, "re-run", function()
            self.runner:kill_process(idx)
            vim.schedule(function()
                self.runner:run_single(idx)
            end)
        end)
    end)
    map_tc("run_all_again", function()
        self:with_pending_settled(nil, "re-run all", function()
            self.runner:kill_all_processes()
            vim.schedule(function()
                self.runner:run_testcases()
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
    if self.runner.editable_testcases then
        map_tc("add_testcase", function()
            self:add_testcase()
        end)
        map_tc("delete_testcase", function()
            self:delete_testcase()
        end)
        map_tc("undo_delete", function()
            self:undo_delete()
        end)
    end

    -- Keys that would start an edit are inert on a read-only pane. Left alone they
    -- enter insert/replace/operator-pending on a buffer that cannot take a change, so
    -- the next keystroke raises `E21: Cannot make changes, 'modifiable' is off` — an
    -- error about an editing session the user never meant to start.
    for _, buf in ipairs(action_bufs) do
        make_inert(buf)
    end

    -- Moving in the selector switches which testcase the detail panes show.
    api.nvim_create_autocmd("CursorMoved", {
        group = self.augroup,
        buffer = tc_buf,
        callback = function()
            local idx = self:cursor_tc()
            if idx ~= self.update_testcase then
                self:select_row(idx)
                self:update_ui()
            end
        end,
    })

    api.nvim_set_current_win(self.windows.tc.winid)
    self.update_windows = true
    local initial = self:opening_row()
    self.update_testcase = initial
    self:update_ui()

    -- The selector is filled on a scheduled tick, so the row only exists by the time
    -- this (queued after it) runs.
    vim.schedule(function()
        if self.ui_visible and self.windows.tc and api.nvim_win_is_valid(self.windows.tc.winid) then
            local line_count = api.nvim_buf_line_count(self.windows.tc.bufnr)
            api.nvim_win_set_cursor(self.windows.tc.winid, { math.min(initial, line_count), 0 })
        end
    end)

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
---Re-highlight the Output and Expected Output panes for the selected testcase.
---Cheap enough to redo on every render, which is what keeps the marks correct as
---the selection moves or a re-run replaces the output.
---Records on `self.diff_note` *why* it painted nothing, when it painted nothing
---(`"no_expected"` — this row has no answer to compare against, i.e. the Compile row
---or an input-only testcase — or `"match"`, the two agree), so the "Run" pane can say
---so rather than leaving the user looking at an unchanged screen.
---@return integer? first the first differing line, if any
function RunnerUI:render_diff()
    self.diff_note = nil
    local so, eo = self.windows.so, self.windows.eo
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
    -- Through the pane seam, so a mode that rewrites these panes is diffed on what
    -- it actually shows; a pane it owns outright is left alone. An unsaved edit to the
    -- expected output is what the pane shows, so it is also what gets diffed —
    -- otherwise the marks would describe text that isn't on screen.
    local output = self.runner:pane_content(tc, "so")
    local pending = self.runner:row_editable(tc) and self.pending[tc.tcnum] or nil
    local expected = pending and pending.expected or self.runner:pane_content(tc, "eo")
    if output == SKIP or expected == SKIP or expected == nil or expected == "" then
        self.diff_note = "no_expected" -- nothing to compare against, or a mode's own pane
        return nil
    end

    local res = diff.compute(output, expected, self.runner:effective_compare())
    paint_diff(so.bufnr, res.out)
    paint_diff(eo.bufnr, res.exp)
    if res.first == nil then
        self.diff_note = "match"
    end
    return res.first
end

---Toggle the comparison between the Output and Expected Output panes.
function RunnerUI:toggle_diff_view()
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

    local vim_width, vim_height = utils.get_ui_size()
    local vcfg = self.config.runner_ui.viewer
    local band_row, band_h = utils.float_band()
    local width = math.floor(vim_width * vcfg.width + 0.5)
    local height = math.max(1, math.min(math.floor(vim_height * vcfg.height + 0.5), band_h - 2))
    self.viewer_winid = api.nvim_open_win(source.bufnr, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim_width - width) / 2),
        row = band_row + math.max(0, math.floor((band_h - height - 2) / 2)),
        border = self.config.floating_border,
        title = source.title,
        title_pos = "center",
        style = "minimal",
        zindex = 60, -- above the popup grid (50)
    })
    require("tuna.utils").set_border_highlight(self.viewer_winid, self.config.floating_border_highlight)
    vim.wo[self.viewer_winid].number = vcfg.show_nu
    vim.wo[self.viewer_winid].relativenumber = vcfg.show_rnu
    vim.wo[self.viewer_winid].wrap = false
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
    -- The pane buffers are about to be wiped, so anything typed into them has to be
    -- moved into `pending` first — that is what lets a resize (which tears the UI
    -- down and rebuilds it) and a close-and-reopen keep an edit in progress.
    self:capture_pending()
    self.ui_visible = false
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
    if not self.ui_visible then
        return
    end
    local cursor = self:cursor_tc()
    local viewer_was = self.viewer_content
    local viewer_visible = self.viewer_winid ~= nil
    local restore = self.restore_winid
    self:delete()
    self.restore_winid = restore
    self:show_ui()
    -- show_ui repopulates the selector on a scheduled tick; restore the cursor
    -- (and the viewer) afterwards so the line is actually present.
    vim.schedule(function()
        if self.windows.tc and api.nvim_win_is_valid(self.windows.tc.winid) then
            local line_count = api.nvim_buf_line_count(self.windows.tc.bufnr)
            api.nvim_win_set_cursor(self.windows.tc.winid, { math.min(cursor, line_count), 0 })
        end
        if viewer_visible then
            self:show_viewer(viewer_was)
        end
    end)
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
    vim.bo[buf].filetype = "tuna"
    utils.name_float_buffer(buf, "message")

    local vim_width, vim_height = utils.get_ui_size()
    local band_row, band_h = utils.float_band()
    local vcfg = self.config.runner_ui.viewer
    local width = math.floor(vim_width * vcfg.width + 0.5)
    local height = math.max(1, math.min(math.floor(vim_height * vcfg.height + 0.5), band_h - 2))
    local win = api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim_width - width) / 2),
        row = band_row + math.max(0, math.floor((band_h - height - 2) / 2)),
        border = self.config.floating_border,
        title = title,
        title_pos = "center",
        style = "minimal",
        zindex = 70,
    })
    utils.set_border_highlight(win, self.config.floating_border_highlight)
    vim.wo[win].wrap = false
    for _, key in ipairs(as_list(self.config.runner_ui.mappings.close)) do
        vim.keymap.set("n", key, function()
            if api.nvim_win_is_valid(win) then
                api.nvim_win_close(win, true)
            end
        end, { buffer = buf, nowait = true })
    end
    make_inert(buf) -- read-only, like every other surface here
end

---@private
---The rectangle the results UI occupies on screen, borders included, as a footprint
---`{ row, col, width, height }` — or nil when nothing is on screen. A bordered float's
---reported position is already its **top-left border cell** (verified against a real
---terminal), with the text one cell inside, so the two border lines are added to the
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

---Show the key legend as the two columns the UI is really made of: the panes you
---type into on the left, wearing their accent, and the ones you only read on the
---right, wearing the ordinary border. Each half is framed in the colour of the panes
---it describes, so which keys apply where needs no explaining.
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
        local lines = { "EDITABLE PANES" }
        vim.list_extend(lines, editable)
        vim.list_extend(lines, { "", "READ-ONLY PANES" })
        vim.list_extend(lines, readonly)
        columns = { { lines = lines, title = " Keys ", hl = plain_hl, group = "TunaFloatBorder" } }
    else
        columns = {
            { lines = editable, title = " Editable panes ", hl = accent_hl, group = accent_group },
            { lines = readonly, title = " Read-only panes ", hl = plain_hl, group = "TunaFloatBorder" },
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
        vim.bo[buf].filetype = "tuna"
        utils.name_float_buffer(buf, "help")
        local win = api.nvim_open_win(buf, false, {
            relative = "editor",
            width = c.width,
            height = height,
            col = at,
            row = row,
            border = self.config.floating_border,
            -- The title takes the *derived* group, whose background is the border's —
            -- see `accent_editable_panes` for why the configured one won't do.
            title = { { c.title, c.group } },
            title_pos = "center",
            style = "minimal",
            zindex = 70,
        })
        utils.set_border_highlight(win, c.hl, c.group)
        vim.wo[win].wrap = false
        wins[#wins + 1] = { win = win, buf = buf }
        at = at + c.width + 2 -- the columns touch, as the runner UI's own panes do
    end

    local function close_all()
        for _, w in ipairs(wins) do
            if api.nvim_win_is_valid(w.win) then
                api.nvim_win_close(w.win, true)
            end
        end
    end
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
        make_inert(w.buf)
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
---The lines shown in the "Run" status pane: the run mode and verdict source, then
---any runner-specific tail (e.g. the stress iteration/save counters). The compile
---step is *not* here — it's a testcase row, so its warnings are viewable. The
---count is stable for a given runner, so it can size the pane at build time.
---@return string[]
function RunnerUI:status_lines()
    -- Each entry is a { label, value } pair; the colons are aligned by padding
    -- every label to the widest one.
    -- Third row: whether the comparison is on. It is a *state*, not an event, so it
    -- belongs on screen rather than in a message — and it carries the reason when the
    -- diff is on but has nothing to paint, which is otherwise indistinguishable from
    -- the key not working.
    local diff_state = self.diff_view and "on" or "off"
    local entries = {
        { "mode", self.runner.mode or "normal" },
        { "judge", self.runner.judge_label and self.runner:judge_label() or "builtin" },
        { "diff", diff_state },
    }
    if self.runner.status_tail then
        vim.list_extend(entries, self.runner:status_tail())
    end
    -- A fixed pointer at the full legend rather than a digest of it: the digest was
    -- always either stale or too long, and an unsaved edit now says so where it
    -- belongs — on its own row in the selector, as an `EDITED` verdict.
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
    vim.bo[w.bufnr].modifiable = true
    api.nvim_buf_set_lines(w.bufnr, 0, -1, false, self:status_lines())
    vim.bo[w.bufnr].modifiable = false
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
            targets[#targets + 1] = t
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
---Replace a buffer's content. A pane left `editable` stays modifiable afterwards.
---`modified` is cleared **always**, whether or not this row is editable, because the
---flag's one job is to mean "the user typed here" and a render is not typing: a
---non-editable row (`Compile`, run-all's solution headers) used to leave the panes
---dirty behind it, which the next row then reported as an unsaved edit of its own.
local function set_buf(bufnr, content, editable)
    if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
        return
    end
    vim.bo[bufnr].modifiable = true
    -- Renders are not edits, so they must not land in the undo history: with a dozen
    -- of them behind you (every re-run, every row you looked at), `u` in an editable
    -- pane walked back through *our* writes before reaching yours — it looked like the
    -- undo had failed. `undolevels = -1` around the write drops both the entry and the
    -- history before it, so one `u` undoes what the user typed and no more.
    local undolevels = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content or "", "\n", { plain = true }))
    vim.bo[bufnr].undolevels = undolevels
    vim.bo[bufnr].modifiable = editable == true
    vim.bo[bufnr].modified = false
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
    local unsaved = {}
    for _, n in ipairs(self:unsaved_testcases()) do
        unsaved[n] = true
    end
    local lines, regions = {}, {}
    for i, tc in ipairs(self.runner.tcdata) do
        -- The left column: a mode may relabel rows (run-all groups solution
        -- header rows above indented per-testcase rows).
        local header
        if self.runner.row_label then
            header = self.runner:row_label(tc)
        else
            header = tc.tcnum == "Compile" and "Compile" or ("TC " .. tc.tcnum)
        end
        -- No runtime for a just-saved counterexample: show its label
        -- (e.g. "saved") in the time column instead.
        local timestr = (tc.time and tc.time >= 0) and string.format("%.3f s", tc.time / 1000)
            or (tc.time_label or "")
        -- A row with an edit that hasn't been written reads `EDITED` instead of
        -- its verdict: the verdict describes the *saved* testcase, so while the
        -- two disagree it would be a claim about text that is no longer there.
        -- It says so on the row it is about, and lasts until the edit is saved
        -- (which re-runs it) or undone away.
        local status, hlgroup = tc.status, tc.hlgroup
        if unsaved[tc.tcnum] then
            status, hlgroup = "EDITED", "TunaWarning"
        end
        table.insert(lines, fit(10, header) .. fit(10, status) .. timestr)
        table.insert(regions, { line = i - 1, hlgroup = hlgroup, len = #status })

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

    local buf = self.windows.tc.bufnr
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, r in ipairs(regions) do
        if r.len > 0 then
            api.nvim_buf_set_extmark(buf, ns, r.line, 10, {
                end_col = 10 + r.len,
                hl_group = r.hlgroup,
            })
        end
    end
end

---Re-render the UI from the runner's `tcdata`. Honours the `update_windows` /
---`update_details` one-shot flags set by `TCRunner:update_ui`.
function RunnerUI:update_ui()
    vim.schedule(function()
        if not self.ui_visible then
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
                -- Ask the runner what each detail pane should show. A mode can own a
                -- pane (return SKIP) so we don't clobber it — e.g. interactive's
                -- editable Input pane while you're typing into it.
                for _, name in ipairs(detail_windows) do
                    local writable = editable and (name == "si" or name == "eo")
                    local content = self.runner:pane_content(tc, name)
                    if pending and name == "si" then
                        content = pending.stdin
                    elseif pending and name == "eo" then
                        content = pending.expected
                    end
                    if content ~= SKIP then
                        set_buf(self.windows[name].bufnr, content, writable)
                        if pending and writable then
                            vim.bo[self.windows[name].bufnr].modified = true
                        end
                    end
                end
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

return M
