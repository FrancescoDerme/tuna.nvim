-- lua/tuna/run/modes/interactive.lua
--
-- Interactive problems: the solution talks to something over stdio, turn by turn.
-- Tuna offers three *sources* for the other side of that conversation:
--
--   * live       — YOU are the other side. The conversation is laid out in three
--                  columns, Output, Live and Errors, each writing on rows the other
--                  two leave blank; you type into Live and <CR> sends the line to the
--                  solution's stdin. No auto-verdict.
--   * feed       — a pre-written input plays the other side, one line per turn: each
--                  time the solution emits a line, the next input line is sent. If
--                  the testcase has an expected output, the solution's stdout is
--                  judged against it; otherwise done.
--   * interactor — a written interactor program (interactor.*) is cross-wired to the
--                  solution and decides the verdict (exit 0 = accepted). Secondary:
--                  used automatically only when an interactor.* sibling exists, or
--                  when asked for explicitly.
--
-- `vim.system` only hands back stdout when a process *finishes*, so it can't cross-
-- wire live processes. We drop to `vim.uv.spawn` and forward bytes between pipes by
-- hand. Reuse: `runner.new()` resolves the solution's compile/run commands, dirs and
-- checker; the runner UI is the shared one (this `InteractiveRunner` is a
-- `RunnerCore` subclass, like the normal and stress runners).

local api = vim.api
local uv = vim.uv
local config = require("tuna.config")
local utils = require("tuna.utils")
local runner = require("tuna.run")
local checker = require("tuna.run.checker")
local testcases = require("tuna.problem.testcases")
local tools = require("tuna.run.tools")
local core = require("tuna.run.core")

local M = {}

-- Live interactive runners keyed by buffer, so `VimResized` can rebuild their UIs
-- and a fresh run can tear the previous one down (mirrors `stress.M.active`).
---@type table<integer, table>
M.active = {}

---A pipe for one side of a session.
---@return uv.uv_pipe_t
local function pipe()
    return assert(uv.new_pipe(false))
end

---A budget of `limit` bytes over what a session prints, counted as it is read, in the fast
---context: scheduled first, a program printing in a loop would fill the editor's queue faster
---than it empties. `on_over` runs once, as the budget runs out, and nothing more fits after.
---@param limit integer? none when nil
---@param on_over fun()
---@return fun(data: string): boolean within whether `data` still fits
---@return fun(): boolean over whether the budget ran out
local function budget(limit, on_over)
    local printed, over = 0, false
    local function within(data)
        if over then
            return false
        end
        printed = printed + #data
        if limit and printed > limit then
            over = true
            on_over()
            return false
        end
        return true
    end
    return within, function()
        return over
    end
end

---Kill a process handle that may have exited already.
---@param handle uv.uv_process_t?
local function kill(handle)
    if handle and handle:is_active() then
        pcall(handle.kill, handle, "sigkill")
    end
end

--------------------------------------------------------------------------------
-- The conversation (live and interactor)
--------------------------------------------------------------------------------

-- The panes a conversation's columns are drawn in.
local CONVERSATION_PANES = { "se", "so", "si" }

-- How many rows of a conversation its columns show, the latest ones, and so how many its log
-- keeps. A session is drawn whole again on every render, so a program printing in a loop would
-- make each render cost more than the last, until reading its output fell behind printing it.
-- What the columns never show is only counted (`log.dropped`): `tc.stdout` holds the output.
local SHOWN_ROWS = 5000

-- How long a row of a conversation grows before it ends in `…`: a program printing without a
-- newline would otherwise build one row as long as all it prints, copied on every piece and
-- drawn whole on every render.
local ROW_BYTES = 2000

---`text` as a row holds it: whole, or its first `ROW_BYTES` bytes, a character never split, and
---`…`, with `true` when it was cut.
---@param text string
---@return string, true?
local function clipped(text)
    if #text <= ROW_BYTES then
        return text, nil
    end
    return text:sub(1, ROW_BYTES + vim.str_utf_end(text, ROW_BYTES)) .. "…", true
end

---Append what one side said to a session's conversation. Each entry of `tc.log` is one
---row, owned by the column that wrote it; the other columns are blank on that row, which
---is what puts a reply on a line of its own instead of beside the message it answers, and
---why nothing is ever copied from one column into another. A side that keeps writing
---without a newline (a prompt, or output arriving in pieces) carries on along its own row,
---but only while nobody else has spoken: once another column has taken a row, whatever
---comes next starts a fresh one.
---@param tc table the session's row
---@param col "so"|"se"|"si"
---@param data string?
local function log_append(tc, col, data)
    tc.log = tc.log or {}
    if data == nil or data == "" then
        return
    end
    local pieces = vim.split(data, "\n", { plain = true })
    local ends_line = pieces[#pieces] == ""
    if ends_line then
        table.remove(pieces)
    end
    for i, piece in ipairs(pieces) do
        local last = tc.log[#tc.log]
        local entry
        if i == 1 and last and last.col == col and last.open then
            if not last.cut then
                last.text, last.cut = clipped(last.text .. piece)
            end
            entry = last
        else
            entry = { col = col }
            entry.text, entry.cut = clipped(piece)
            tc.log[#tc.log + 1] = entry
        end
        entry.open = i == #pieces and not ends_line
    end
    -- Trimmed in batches, so each row costs the same however long the session runs.
    if #tc.log > 2 * SHOWN_ROWS then
        local kept = { dropped = (tc.log.dropped or 0) + #tc.log - SHOWN_ROWS }
        table.move(tc.log, #tc.log - SHOWN_ROWS + 1, #tc.log, 1, kept)
        tc.log = kept
    end
end

---Put a line of tuna's own (a session ending, a timeout) into the Errors column, on a row
---of its own: whatever row was left open is closed first, so the note can't run into it.
---@param tc table
---@param text string
local function log_note(tc, text)
    tc.log = tc.log or {}
    local last = tc.log[#tc.log]
    if last then
        last.open = false
    end
    log_append(tc, "se", text .. "\n")
end

---Lay a conversation out as the lines of its three columns: one row per entry, blank in
---every column but the one that wrote it, its latest `SHOWN_ROWS` under a note of how many
---went before. The three come back the same length, so the columns stay line for line.
---@param log table[]?
---@return table<string, string[]>
local function conversation(log)
    log = log or {}
    local out = { so = {}, se = {}, si = {} }
    local first = math.max(1, #log - SHOWN_ROWS + 1)
    local earlier = (log.dropped or 0) + first - 1
    if earlier > 0 then
        out.so[1], out.si[1] = "", ""
        out.se[1] = ("[%d earlier lines not shown]"):format(earlier)
    end
    for i = first, #log do
        local entry = log[i]
        for _, col in ipairs(CONVERSATION_PANES) do
            out[col][#out[col] + 1] = col == entry.col and entry.text or ""
        end
    end
    return out
end

---Write a column's lines without touching the undo history or leaving the buffer
---`modified`, and without writing at all when it already says the same thing, so a
---redraw leaves a column being read alone. With `keep_last`, the buffer's own last line is
---left in place and everything above it replaced: that line is being typed into.
---@param bufnr integer
---@param lines string[]
---@param keep_last boolean
---@param modifiable boolean
local function set_column(bufnr, lines, keep_last, modifiable)
    if not keep_last and #lines == 0 then
        lines = { "" }
    end
    local stop = keep_last and api.nvim_buf_line_count(bufnr) - 1 or -1
    if not vim.deep_equal(api.nvim_buf_get_lines(bufnr, 0, stop, false), lines) then
        vim.bo[bufnr].modifiable = true
        local undolevels = vim.bo[bufnr].undolevels
        vim.bo[bufnr].undolevels = -1
        api.nvim_buf_set_lines(bufnr, 0, stop, false, lines)
        vim.bo[bufnr].undolevels = undolevels
    end
    vim.bo[bufnr].modifiable = modifiable
    vim.bo[bufnr].modified = false
end

---What the interactor source asks for when there is no interactor at all: to write its
---starter.
---@param bufnr integer
---@param opts { win: integer?, before: fun()? }?
local function offer_interactor(bufnr, opts)
    require("tuna.workspace.scaffold").create_missing({ "interactor" }, bufnr, "the interactor source needs an interactor", opts)
end

--------------------------------------------------------------------------------
-- InteractiveRunner (a RunnerCore subclass the runner UI drives)
--------------------------------------------------------------------------------

local InteractiveRunner = core.extend()

-- Testcases are not edited from this UI by default: in `live` and `interactor` the `si`
-- pane is the other side of a conversation, not a stored input. `feed` is the exception
-- and turns it on per runner (see `M.run`), since what it replays *is* a stored testcase.
InteractiveRunner.editable_testcases = false

---Whether this runner's source is a conversation, laid out in aligned columns. `feed` is
---not one: it replays a stored testcase, whose input and output are read as texts.
---@return boolean
function InteractiveRunner:conversational()
    return self.source ~= "feed"
end

---The grid this source draws, from `interactive.layouts` (`false` there means the configured
---one), and the name to report it by when it does not validate. `feed` keeps the configured
---grid, with the canonical Input and Expected Output panes, editable as in a normal run: what
---it replays is a stored testcase. `live` and `interactor` are a conversation and are laid out
---as one, the selector, then a column each for Output, Live and Errors, every one full height,
---so a row of one faces the same row of the others. Expected output has no place in it, a
---sample exchange being one example of a conversation rather than the only correct one.
---
---The shipped conversation grid gives the selector the share it has in the configured one
---(3 of 11), so it is the width it is in every other mode, compile time and all. Output and
---Live share a ratio, which is what makes them the same width: the last column absorbs
---whatever the grid's division leaves over, so Errors goes last, its two lines of tuna's own
---notes being what can spare a cell.
---@return table? layout, string? name
function InteractiveRunner:layout()
    local own = ((self.config.interactive or {}).layouts or {})[self.source]
    if not own then
        return nil
    end
    return own, "interactive.layouts." .. self.source
end

---`si` is named for what it is in a conversation: the other side of it, not a stored
---testcase's input.
---@return table<string, string>?
function InteractiveRunner:pane_titles()
    if not self:conversational() then
        return nil
    end
    return { si = " live " }
end

---In live mode the Live pane is typed into, so the UI must leave its letters alone
---(no `q`-to-close on it) even though testcases aren't editable in this mode.
---@param name string
---@return boolean
function InteractiveRunner:owns_pane(name)
    return name == "si" and self.source == "live"
end

-- What each source adds to the `?` legend: who plays the other side and how, and what decides
-- the verdict. The other sources are named last, since switching is a command, not a key.
local LEGEND = {
    live = {
        { "you", "play the other side, in the live column" },
        { "start typing", "i, a, o or <CR> in the live column" },
        { "send a line", "<CR>" },
        { "the verdict", "none, you are the judge" },
    },
    feed = {
        { "the input", "is sent to the solution a line at a time" },
        { "the verdict", "its output against the expected output" },
    },
    interactor = {
        { "the interactor", "plays the other side, in the live column" },
        { "the verdict", "the interactor's exit code, 0 is correct" },
    },
}

---What the `?` legend adds for an interactive run: the source playing the other side.
---@return { title: string, rows: string[][] }
function InteractiveRunner:legend_rows()
    local rows = vim.deepcopy(LEGEND[self.source] or {})
    local others = {}
    for _, source in ipairs({ "live", "feed", "interactor" }) do
        if source ~= self.source then
            others[#others + 1] = source
        end
    end
    rows[#rows + 1] = { "other sources", ":Tuna run interactive " .. table.concat(others, " or ") }
    return { title = "interactive, " .. self.source, rows = rows }
end

---One extra "Run" pane row, under the judge: which side is playing the interactor. A
---setting like the mode and the judge, so it sits with them rather than below the run's
---own rows.
---@return string[][]
function InteractiveRunner:status_settings()
    return { { "source", self.source } }
end

---In a conversation the three columns are drawn by `on_details_rendered`, since their rows
---have to be laid out together and the Live column is typed into, where the base render
---would replace each pane on its own and overwrite the line being typed. There is no
---expected output to show or diff against. In `feed` every pane is the base class's: `si`
---shows the input being fed, and Errors carries a checker's message. The build step is
---nobody's conversation: its panes are the sources being compiled, drawn by the UI as they
---are in every other mode.
function InteractiveRunner:pane_content(tc, name)
    if
        not tc.compile
        and self:conversational()
        and (name == "so" or name == "se" or name == "si" or name == "eo")
    then
        return core.SKIP
    end
    return core.RunnerCore.pane_content(self, tc, name)
end

---Nothing will run, so nothing is in flight either: left `false`, the runner would refuse
---every edit with "wait for the run to finish".
function InteractiveRunner:on_build_failed()
    self.completed = true
    self:update_ui(true)
end

---End the session running now, and only it: its row reads `killed`, as a testcase stopped in
---any mode does, and the run goes on to the next one.
function InteractiveRunner:kill_process()
    local tc = self.active_index and self.tcdata[self.active_index]
    if tc and (self.sol_handle or self.int_handle) then
        tc.killed = true
    end
    kill(self.sol_handle)
    kill(self.int_handle)
end

---Stop the run: the session running now ends, and none starts after it.
function InteractiveRunner:kill_all_processes()
    self.stopped = true
    self:kill_process()
end

---Re-running one row restarts its session. It claims the runner while the session runs,
---as the normal runner's `run_single` does: `idle()` reads `completed`, and a re-run that
---left it true let the structural edits `feed` allows (`n`, `x`, a split) through
---mid-session.
---@param idx integer
function InteractiveRunner:run_single(idx)
    local tc = self.tcdata[idx]
    if not tc or tc.compile then
        return
    end
    self.completed = false
    self.stopped = false
    if self:built_first(function()
        self:run_single(idx)
    end) then
        return
    end
    self:with_helpers(function()
        self:run_one_session(idx, function()
            self.completed = true
            core.save_buffer_verdict(self.bufnr, self.tcdata)
            self:update_ui(true)
        end)
    end)
end

---Run every session from the top: the first run, and the UI's "run all again". Like a run
---of the whole set in every mode, it builds the solution first.
function InteractiveRunner:run_testcases()
    self:claim_listed()
    self.completed = false
    self:with_helpers(function()
        self:run_sessions()
    end, true)
end

---Look this run's helpers up again before a run, as every run does: the checker, and for the
---interactor source the interactor, prepared again so an edited one rebuilds. A rerun keeps
---its source, so an interactor that is gone is reported and nothing runs: `:Tuna run` picks
---the source again.
---@param cont fun()
---@param whole boolean? a run of the whole set, which builds the solution too
function InteractiveRunner:with_helpers(cont, whole)
    local solution = api.nvim_buf_get_name(self.bufnr)
    local build = whole and self.build_all or self.build_helpers
    self:refresh_judge(solution)
    if self.source ~= "interactor" then
        self:plan_builds({ self.checker })
        self:build_judge()
        return build(self, {}, cont)
    end
    local spec, missing = tools.helper("interactor", solution, self.config)
    if not spec then
        self.completed = true
        self:update_ui(true)
        if not missing then
            -- Simply not there: its starter can stand in. Written, it opens in the editor the
            -- board was over, the board having nothing to run until it is filled in.
            return offer_interactor(self.bufnr, {
                win = self.ui and self.ui.restore_winid,
                before = function()
                    self:delete_ui()
                end,
            })
        end
        local text = missing .. ", :Tuna run picks the source again."
        if self.ui then
            self.ui:show_message(" interactive: no interactor ", text)
        else
            utils.notify("interactive: " .. text, "WARN")
        end
        return
    end
    self.interactor = spec
    self:plan_builds({ spec, self.checker })
    self:build_judge()
    build(self, { spec }, cont)
end

---In a conversation the three columns are scroll-bound and unwrapped, so reading back
---through one keeps the rows of all three level. The build step is no conversation: its panes
---hold each source's compiler output, read on its own and wrapped by the UI. When `live`, the
---Live column is also typed into, and <CR> sends the line being typed.
---@param ui table the RunnerUI
function InteractiveRunner:on_ui_shown(ui)
    if not self:conversational() then
        return
    end
    local talking = not (ui.drawn_row and ui.drawn_row.compile)
    for _, name in ipairs(CONVERSATION_PANES) do
        local w = ui.windows[name]
        if w and w.winid and api.nvim_win_is_valid(w.winid) then
            api.nvim_set_option_value("scrollbind", talking, { scope = "local", win = w.winid })
            if talking then
                api.nvim_set_option_value("wrap", false, { scope = "local", win = w.winid })
            end
        end
    end
    if self.source ~= "live" then
        return
    end
    local w = ui.windows.si
    if not (w and w.winid and api.nvim_buf_is_valid(w.bufnr)) then
        return
    end
    local buf = w.bufnr

    ---Send the line being typed, the Live column's last line, since everything above it is
    ---conversation already. It is cleared at once rather than at the next redraw, so a key
    ---pressed in between is not swallowed with it.
    ---Nothing is running yet (or the row being shown is not the one that is): there is no
    ---program to talk to, so a key that means "type here" means "build it and talk to it".
    ---`type_when_live` is picked up by the render that makes the column typable, which puts
    ---the cursor at the end of it and starts insert, so the keystroke is not swallowed.
    local function start_talking()
        self.type_when_live = true
        if self.sol_in and self.active_index then
            -- A session is running on another row: that is where typing works.
            if self.ui and self.ui.ui_visible then
                self.ui:goto_row(self.active_index)
            end
        else
            self:run_testcases()
        end
    end

    local function send()
        if not (self.sol_in and not self.sol_in:is_closing()) then
            start_talking()
            return
        end
        local n = api.nvim_buf_line_count(buf)
        local line = api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ""
        vim.bo[buf].modifiable = true
        api.nvim_buf_set_lines(buf, n - 1, n, false, { "" })
        vim.bo[buf].modified = false
        if w.winid and api.nvim_win_is_valid(w.winid) then
            pcall(api.nvim_win_set_cursor, w.winid, { n, 0 })
        end
        self:live_send(line)
    end
    vim.keymap.set("i", "<CR>", send, { buffer = buf })
    vim.keymap.set("n", "<CR>", send, { buffer = buf, nowait = true })

    -- The keys that mean "I am typing here". While the column is typable they are Vim's own;
    -- before that they would only raise `E21` at someone who is being invited to talk, so
    -- they start the session instead.
    for _, key in ipairs({ "i", "I", "a", "A", "o", "O" }) do
        vim.keymap.set("n", key, function()
            if vim.bo[buf].modifiable then
                api.nvim_feedkeys(key, "n", false)
            else
                start_talking()
            end
        end, { buffer = buf, nowait = true })
    end
end

---Draw the conversation for the row the UI is showing, then follow the latest line. Called
---after every detail render, which the UI coalesces to one per tick, so a burst of output
---is laid out once rather than once per chunk.
---
---During a live session the Live column ends in the line being typed, which is not part of
---the conversation yet: the other columns get a blank line to face it, and it is carried
---across the redraw rather than rewritten, or a keystroke landing between two chunks of
---output would be lost. A column follows the latest line unless the cursor is in it and
---off the bottom, which is someone reading back; with the columns scroll-bound, the
---others then stay level with them.
---@param ui table the RunnerUI
---@param tc table the row being shown
function InteractiveRunner:on_details_rendered(ui, tc)
    -- The build step is drawn by the UI, one pane per source compiled.
    if not self:conversational() or tc.compile then
        return
    end
    local w = {}
    for _, name in ipairs(CONVERSATION_PANES) do
        w[name] = ui.windows[name]
        if not (w[name] and w[name].bufnr and api.nvim_buf_is_valid(w[name].bufnr)) then
            return
        end
    end

    local cols = conversation(tc.log)

    local cur = api.nvim_get_current_win()
    local follow, col_of = {}, {}
    for _, name in ipairs(CONVERSATION_PANES) do
        local win = w[name].winid
        if win and api.nvim_win_is_valid(win) then
            local pos = api.nvim_win_get_cursor(win)
            follow[name] = win ~= cur or pos[1] >= api.nvim_buf_line_count(w[name].bufnr)
            col_of[name] = pos[2]
        end
    end

    local composing = self.source == "live" and self.sol_in ~= nil and tc == self.tcdata[self.active_index]
    if composing then
        cols.so[#cols.so + 1] = ""
        cols.se[#cols.se + 1] = ""
        if self.composing_row == tc then
            set_column(w.si.bufnr, cols.si, true, true)
        else
            local fresh = vim.list_extend(vim.deepcopy(cols.si), { "" })
            set_column(w.si.bufnr, fresh, false, true)
        end
        self.composing_row = tc
        -- Asked to type before there was anything to type to: the column is live now, so the
        -- cursor goes to the end of it and insert starts, which is what the key pressed then
        -- was for.
        if self.type_when_live then
            self.type_when_live = nil
            local win, sbuf = w.si.winid, w.si.bufnr
            vim.schedule(function()
                if not (win and api.nvim_win_is_valid(win) and vim.bo[sbuf].modifiable) then
                    return
                end
                api.nvim_set_current_win(win)
                local n = api.nvim_buf_line_count(sbuf)
                pcall(api.nvim_win_set_cursor, win, { n, #(api.nvim_buf_get_lines(sbuf, n - 1, n, false)[1] or "") })
                vim.cmd("startinsert!")
            end)
        end
    else
        self.composing_row = nil
        set_column(w.si.bufnr, cols.si, false, false)
        if cur == w.si.winid and api.nvim_get_mode().mode:sub(1, 1) == "i" then
            vim.cmd("stopinsert") -- the session is over: there is nothing left to type to
        end
    end
    set_column(w.so.bufnr, cols.so, false, false)
    set_column(w.se.bufnr, cols.se, false, false)

    -- Someone reading back through one column holds all three where they are: the others
    -- are scroll-bound to it, and following the latest line would pull them out of level.
    for _, name in ipairs(CONVERSATION_PANES) do
        if col_of[name] ~= nil and not follow[name] then
            return
        end
    end
    for _, name in ipairs(CONVERSATION_PANES) do
        local win = w[name].winid
        if follow[name] then
            local last = api.nvim_buf_line_count(w[name].bufnr)
            pcall(api.nvim_win_set_cursor, win, { last, win == cur and col_of[name] or 0 })
            api.nvim_win_call(win, function()
                vim.fn.winrestview({ topline = math.max(1, last - api.nvim_win_get_height(win) + 1) })
                -- Scrolling from code leaves the position 'scrollbind' measures from behind,
                -- so the next scroll by hand would move the other columns by the wrong amount.
                vim.wo[win].scrollbind = false
                vim.wo[win].scrollbind = true
            end)
        end
    end
end

---Send one line to the live session's solution. It goes into the conversation as a row of
---the Live column's own; nothing is copied into Output, which holds only what the solution
---printed.
---@param line string
function InteractiveRunner:live_send(line)
    local tc = self.tcdata[self.active_index]
    if not (tc and self.sol_in and not self.sol_in:is_closing()) then
        return
    end
    self.sol_in:write(line .. "\n")
    log_append(tc, "si", line .. "\n")
    self:update_ui(false)
end

--------------------------------------------------------------------------------
-- Sessions
--------------------------------------------------------------------------------

-- How long a session waits, past its solution's exit, for the end of its output: a child the
-- solution left behind (a shell's) can hold a pipe open for ever.
local LINGER = 200

---Spawn the solution with three pipes and forward its output through `cbs`.
---`cbs`: on_stdout(data), on_stderr(data), on_exit(code, signal, over), on_error(msg),
---optional on_timeout() when `cbs.timed` and `self.timeout` are set. A solution printing past
---`maximum_output` is stopped there, and `over` is that limit. The session ends once the
---process is gone and all it printed is read: its exit can come before the last of its output,
---which is still its output, so `LINGER` past the exit it ends whatever is left open.
---@param cbs table
function InteractiveRunner:spawn_solution(cbs)
    local sol_in, sol_out, sol_err = pipe(), pipe(), pipe()
    self.sol_in = sol_in
    local timer, linger
    -- `done` is the session over, read in the fast context; `settled` is its end handled, on the
    -- main loop after whatever was read before it, which is still to be shown.
    local done, settled = false, false
    local exit_code, exit_signal, lingered = nil, nil, false
    local open = { out = true, err = true }
    local handle
    local limit = tools.output_limit(self.config)
    local within, over = budget(limit, function()
        kill(handle)
    end)

    local function cleanup()
        for _, p in ipairs({ sol_in, sol_out, sol_err }) do
            if p and not p:is_closing() then
                p:close()
            end
        end
        for _, t in ipairs({ timer, linger }) do
            if t and not t:is_closing() then
                t:stop()
                t:close()
            end
        end
    end

    local function finish()
        if done or exit_code == nil or ((open.out or open.err) and not lingered) then
            return
        end
        done = true
        self.sol_handle = nil
        cleanup()
        vim.schedule(function()
            settled = true
            cbs.on_exit(exit_code, exit_signal, over() and limit or nil)
        end)
    end

    handle = uv.spawn(self.r.rc.exec, {
        args = self.r.rc.args,
        cwd = self.rundir,
        env = tools.spawn_env(),
        stdio = { sol_in, sol_out, sol_err },
    }, function(code, signal)
        exit_code, exit_signal = code, signal
        linger = uv.new_timer()
        if linger then
            linger:start(LINGER, 0, function()
                lingered = true
                finish()
            end)
        else
            lingered = true
        end
        finish()
    end)

    if not handle then
        cleanup()
        vim.schedule(function()
            cbs.on_error("could not start solution '" .. tostring(self.r.rc.exec) .. "'")
        end)
        return
    end
    self.sol_handle = handle

    ---Read one of the solution's streams into `forward`, on the main loop, until its end.
    ---@param p uv.uv_pipe_t
    ---@param which "out"|"err"
    ---@param forward fun(data: string)
    local function read(p, which, forward)
        p:read_start(function(err, data)
            if done then
                return
            end
            if err or not data then
                open[which] = false
                return finish()
            end
            if not within(data) then
                return
            end
            vim.schedule(function()
                if not settled then
                    forward(data)
                end
            end)
        end)
    end
    read(sol_out, "out", cbs.on_stdout)
    read(sol_err, "err", cbs.on_stderr)

    if self.timeout and cbs.timed then
        timer = assert(uv.new_timer())
        timer:start(self.timeout, 0, function()
            if not done and exit_code == nil then
                vim.schedule(cbs.on_timeout)
                kill(handle)
            end
        end)
    end
end

---live: you are the interactor. No timeout (human-paced); kill via the UI.
---@param idx integer
---@param on_done fun()
function InteractiveRunner:run_live(idx, on_done)
    local tc = self.tcdata[idx]
    self.active_index = idx
    tc.status, tc.hlgroup = "live", "TunaRunning"
    tc.stdout, tc.stderr, tc.log = "", "", {}
    self:update_ui(true)
    -- Joined once the session ends: the columns show the log, so nothing reads them before, and
    -- joined as they arrive they would be copied whole on every piece.
    local out, errs = {}, {}

    self:spawn_solution({
        on_stdout = function(data)
            out[#out + 1] = data
            log_append(tc, "so", data)
            self:update_ui(false)
        end,
        on_stderr = function(data)
            errs[#errs + 1] = data
            log_append(tc, "se", data)
            self:update_ui(false)
        end,
        on_error = function(msg)
            tc.status, tc.hlgroup, tc.stderr = "failed", "TunaWarning", msg
            tc.stdout = table.concat(out)
            log_note(tc, msg)
            self.sol_in = nil
            self:update_ui(true)
            on_done()
        end,
        on_exit = function(code, signal, over)
            -- You are the judge, so a session that ended on its own is `done`; one stopped or
            -- crashed ends the way a testcase would.
            local ended, hl, words = core.ending({ code = code, signal = signal, killed = tc.killed, over = over })
            tc.stdout, tc.stderr = table.concat(out), table.concat(errs)
            if over then
                log_note(tc, "[" .. words .. "]")
            end
            tc.status, tc.hlgroup = ended or "done", hl or "TunaDone"
            self.sol_in = nil
            self:update_ui(true)
            on_done()
        end,
    })
end

---feed: the testcase input plays the interactor, one line per turn.
---@param idx integer
---@param on_done fun()
function InteractiveRunner:run_feed(idx, on_done)
    local tc = self.tcdata[idx]
    self.active_index = idx
    tc.status, tc.hlgroup = "running", "TunaRunning"
    tc.stdout, tc.stderr = "", ""
    self:update_ui(true)

    local lines = vim.split(tc.stdin or "", "\n", { plain = true })
    if #lines > 0 and lines[#lines] == "" then
        table.remove(lines) -- drop the empty part after a trailing newline
    end
    local li = 0
    local timed_out = false
    local function send_next()
        li = li + 1
        if li > #lines then
            if self.sol_in and not self.sol_in:is_closing() then
                self.sol_in:shutdown()
            end
            return
        end
        if self.sol_in and not self.sol_in:is_closing() then
            self.sol_in:write(lines[li] .. "\n")
        end
    end

    -- What arrives is joined once a tick rather than once a piece: the Output and Errors panes
    -- show it as it streams, and joined piece by piece it would be copied whole every time.
    local pending, flushing = { stdout = {}, stderr = {} }, false
    local function flush()
        for _, field in ipairs({ "stdout", "stderr" }) do
            if #pending[field] > 0 then
                tc[field] = tc[field] .. table.concat(pending[field])
                pending[field] = {}
            end
        end
    end
    local function queue(field, data)
        local parts = pending[field]
        parts[#parts + 1] = data
        if not flushing then
            flushing = true
            vim.schedule(function()
                flushing = false
                flush()
                self:update_ui(false)
            end)
        end
    end

    self:spawn_solution({
        timed = true,
        on_stdout = function(data)
            queue("stdout", data)
            -- One input line per *line* of output: a chunk carrying several newlines
            -- is several completed turns, and answering it with a single line
            -- deadlocked any protocol that prints more than one line per query.
            for _ in data:gmatch("\n") do
                send_next()
            end
        end,
        on_stderr = function(data)
            queue("stderr", data)
        end,
        on_timeout = function()
            timed_out = true
        end,
        on_error = function(msg)
            tc.status, tc.hlgroup, tc.stderr = "failed", "TunaWarning", msg
            self.sol_in = nil
            self:update_ui(true)
            on_done()
        end,
        on_exit = function(code, signal, over)
            self.sol_in = nil
            flush()
            local ended, hl, words = core.ending({ code = code, signal = signal, timed_out = timed_out, killed = tc.killed, over = over })
            if over then
                tc.stderr = tc.stderr .. (tc.stderr ~= "" and "\n" or "") .. "[" .. words .. "]"
            end
            if ended then
                tc.status, tc.hlgroup = ended, hl
                self:update_ui(true)
                return on_done()
            end
            -- Judged as a testcase is in every mode: with no answer a comparison has nothing
            -- to say (`done`), and a checker of its own still reads the output.
            tc.judging = true
            checker.judge(tc, self.checker, self:effective_compare(), function(correct, message)
                tc.judging = false
                tc.checker_message = message
                tc.status, tc.hlgroup = core.verdict(correct)
                self:update_ui(true)
                on_done()
            end)
        end,
    })
    -- Prime: many interactive solutions read a line before printing anything.
    send_next()
end

---interactor: cross-wire the solution and the interactor; the interactor rules. The
---conversation is laid out like live's: the solution's output in Output, the interactor's
---in Live, and the interactor's stderr with tuna's own notes in Errors.
---@param idx integer
---@param on_done fun()
function InteractiveRunner:run_interactor(idx, on_done)
    local tc = self.tcdata[idx]
    self.active_index = idx
    tc.status, tc.hlgroup = "running", "TunaRunning"
    tc.stdout, tc.stderr, tc.log = "", "", {}
    self:update_ui(true)

    local input_file = utils.temp_file(tc.stdin)
    local answer_file = utils.temp_file(tc.expected)
    local int_args = tools.expand_args(
        self.interactor.args,
        { INPUT = input_file, OUTPUT = "/dev/null", ANSWER = answer_file }
    )

    local sol_in, sol_out = pipe(), pipe()
    local int_in, int_out, int_err = pipe(), pipe(), pipe()
    local sol_handle, int_handle, timer
    local done, verdict, int_exited, failed = false, nil, false, false
    local limit = tools.output_limit(self.config)
    local over = false
    -- Joined once the session ends, as in live: the columns show the log. tuna's own notes go
    -- into `errs` too, in the order they come.
    local out, errs = {}, {}
    -- The session's end handled, on the main loop: what was read before it is still shown.
    local settled = false

    local function safe_close(h)
        if h and not h:is_closing() then
            h:close()
        end
    end
    ---End the session. `status` is how it ended when that was not the interactor's verdict:
    ---the solution crashing, or the time running out.
    ---@param status string?
    ---@param hl string?
    local function finish(status, hl)
        if done then
            return
        end
        done = true
        if timer then
            timer:stop()
            safe_close(timer)
        end
        kill(sol_handle)
        kill(int_handle)
        for _, p in ipairs({ sol_in, sol_out, int_in, int_out, int_err }) do
            safe_close(p)
        end
        utils.delete_file(input_file)
        utils.delete_file(answer_file)
        self.sol_handle, self.int_handle = nil, nil
        vim.schedule(function()
            settled = true
            tc.stdout, tc.stderr = table.concat(out), table.concat(errs)
            if failed then
                -- The session never happened (the interactor would not start): that is
                -- not a `done`, which reads as a session that ran and was not judged.
                tc.status, tc.hlgroup = "failed", "TunaWarning"
            elseif tc.killed then
                tc.status, tc.hlgroup = "killed", "TunaWarning"
            elseif status then
                tc.status, tc.hlgroup = status, hl
            else
                tc.status, tc.hlgroup = core.verdict(verdict)
            end
            self:update_ui(true)
            on_done()
        end)
    end

    sol_handle = uv.spawn(self.r.rc.exec, {
        args = self.r.rc.args,
        cwd = self.rundir,
        env = tools.spawn_env(),
        stdio = { sol_in, sol_out, nil },
    }, function(code, signal)
        safe_close(sol_handle)
        sol_handle = nil
        local ended, hl, words = core.ending({ code = code, signal = signal })
        if ended and not int_exited and not done and not over then
            local note = "[solution " .. words .. "]"
            errs[#errs + 1] = "\n" .. note
            log_note(tc, note)
            finish(ended, hl)
        end
    end)
    if not sol_handle then
        for _, p in ipairs({ sol_in, sol_out, int_in, int_out, int_err }) do
            safe_close(p)
        end
        tc.status, tc.hlgroup, tc.stderr = "failed", "TunaWarning", "could not start solution"
        log_note(tc, tc.stderr)
        self:update_ui(true)
        return on_done()
    end
    self.sol_handle = sol_handle

    int_handle = uv.spawn(self.interactor.exec, {
        args = int_args,
        cwd = self.rundir,
        env = tools.spawn_env(),
        stdio = { int_in, int_out, int_err },
    }, function(code, signal)
        safe_close(int_handle)
        int_handle = nil
        int_exited = true
        verdict = (code == 0 and (not signal or signal == 0))
        -- Stopped at the limit, the session's end is already on its way.
        if not over then
            finish()
        end
    end)
    if not int_handle then
        local said = "could not start interactor '" .. tostring(self.interactor.exec) .. "'"
        errs[#errs + 1] = said
        log_note(tc, said)
        failed = true
        finish()
        return
    end
    self.int_handle = int_handle

    -- What the two print together has one budget. Past it they are stopped, and the session
    -- ended once what they printed before is shown, on the main loop.
    local within = budget(limit, function()
        over = true
        kill(sol_handle)
        kill(int_handle)
        vim.schedule(function()
            local ended, hl, words = core.ending({ over = limit })
            errs[#errs + 1] = "\n[" .. words .. "]"
            log_note(tc, "[" .. words .. "]")
            finish(ended, hl)
        end)
    end)

    -- Cross-wire, teeing each side of the exchange into the transcript.
    sol_out:read_start(function(err, data)
        if err or done then
            return
        end
        if data and not within(data) then
            return
        end
        if data then
            if not int_in:is_closing() then
                int_in:write(data)
            end
            vim.schedule(function()
                if not settled then
                    out[#out + 1] = data
                    log_append(tc, "so", data)
                    self:update_ui(false)
                end
            end)
        elseif not int_in:is_closing() then
            int_in:shutdown()
        end
    end)
    int_out:read_start(function(err, data)
        if err or done then
            return
        end
        if data and not within(data) then
            return
        end
        if data then
            if not sol_in:is_closing() then
                sol_in:write(data)
            end
            vim.schedule(function()
                if not settled then
                    log_append(tc, "si", data)
                    self:update_ui(false)
                end
            end)
        elseif not sol_in:is_closing() then
            sol_in:shutdown()
        end
    end)
    int_err:read_start(function(err, data)
        if not err and data and not done and within(data) then
            vim.schedule(function()
                if not settled then
                    errs[#errs + 1] = data
                    log_append(tc, "se", data)
                    self:update_ui(false)
                end
            end)
        end
    end)

    if self.timeout then
        timer = assert(uv.new_timer())
        timer:start(self.timeout, 0, function()
            if not done and not over then
                local ended, hl, words = core.ending({ timed_out = true }, self.timeout)
                errs[#errs + 1] = "\n[" .. words .. "]"
                log_note(tc, "[" .. words .. "]")
                finish(ended, hl)
            end
        end)
    end
end

---Run one session for row `idx`, dispatching on the source.
---@param idx integer
---@param on_done fun()
function InteractiveRunner:run_one_session(idx, on_done)
    -- The row being talked to is the row to look at: its columns are where the conversation
    -- appears, and in live it is the only row whose Live column can be typed into. Every
    -- other mode's rows can be read at leisure while they run, and the UI opens on whichever
    -- it opened on; here one row *is* the session, so the session takes the cursor with it.
    if self.ui then
        self.ui:follow_row(idx)
    end
    self:reset_row(self.tcdata[idx])
    if self.source == "interactor" then
        self:run_interactor(idx, on_done)
    elseif self.source == "feed" then
        self:run_feed(idx, on_done)
    else
        self:run_live(idx, on_done)
    end
end

---Run every testcase row's session, one after another.
function InteractiveRunner:run_sessions()
    local order = {}
    for i, tc in ipairs(self.tcdata) do
        if not tc.compile then
            self:reset_row(tc)
            order[#order + 1] = i
        end
    end
    self.completed = false
    self.stopped = false
    local k = 0
    local function step()
        k = k + 1
        if k > #order or self.stopped then
            for j = k, #order do -- stopped: the sessions after this one never started
                self.tcdata[order[j]].status, self.tcdata[order[j]].hlgroup = "not run", "TunaDone"
            end
            self.completed = true
            core.save_buffer_verdict(self.bufnr, self.tcdata)
            self:update_ui(true)
            return
        end
        self:run_one_session(order[k], step)
    end
    step()
end

---Build the testcase rows (plus the solution compile row).
function InteractiveRunner:load_rows()
    self.tcdata = {}
    if self.compile_entry then
        table.insert(self.tcdata, self.compile_entry)
    end
    local tctbl = testcases.buf_get_testcases(self.bufnr)
    local nums = {}
    if self.list then
        for _, s in ipairs(self.list) do
            local n = tonumber(s)
            if n and tctbl[n] then
                nums[#nums + 1] = n
            else
                utils.notify("interactive: testcase " .. tostring(s) .. " doesn't exist.")
            end
        end
    else
        nums = vim.tbl_keys(tctbl)
        table.sort(nums)
    end
    if #nums == 0 then
        -- Nothing to feed/replay: a single blank session (you just interact). In `feed`,
        -- where testcases are editable, it is flagged `bare` like the normal runner's row
        -- of the same kind: nothing is on disk behind it *yet*, which is not the same as a
        -- testcase that went missing, and typing into it is how the first one is written.
        table.insert(self.tcdata, {
            tcnum = 0,
            bare = self.source == "feed" or nil,
            stdin = "",
            expected = nil,
            status = "",
            hlgroup = "TunaRunning",
        })
    else
        for _, n in ipairs(nums) do
            table.insert(self.tcdata, {
                tcnum = n,
                stdin = tctbl[n].input or "",
                expected = tctbl[n].output,
                status = "",
                hlgroup = "TunaRunning",
            })
        end
    end
end

--------------------------------------------------------------------------------
-- Helpers + entry point
--------------------------------------------------------------------------------

---Run interactive judging for a buffer's solution.
---@param bufnr integer? defaults to the current buffer
---@param args string[]? a leading source keyword (live|feed|interactor) then testcase numbers
---@param opts { show_only: boolean? }? open the UI with the rows listed and nothing run
function M.run(bufnr, args, opts)
    opts = opts or {}
    bufnr = bufnr or api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)

    local r = runner.new(bufnr)
    if not r then
        return
    end
    local cfg = r.config
    local path = api.nvim_buf_get_name(bufnr)
    if not opts.show_only then
        tools.save_sources(bufnr, cfg) -- save the solution (interactor saved in tools.prepare)
    end

    -- Pull a leading source keyword out of the args (the rest are testcase numbers). A
    -- source typed now is forced and runs as typed, `auto` makes it automatic again.
    local list = args and vim.deepcopy(args) or nil
    local typed
    if list and list[1] and (vim.tbl_contains(tools.SOURCES, list[1]) or list[1] == "auto") then
        typed = table.remove(list, 1)
        tools.set_source(path, typed ~= "auto" and typed or nil)
    end
    if list and #list == 0 then
        list = nil
    end
    local source, note
    if typed and typed ~= "auto" then
        source = typed
    else
        source, note = tools.resolve_source(path, cfg)
    end

    local interactor
    if source == "interactor" then
        local missing
        interactor, missing = tools.helper("interactor", path, cfg)
        if not interactor then
            if missing then
                utils.notify("interactive: " .. missing .. ", or run ':Tuna run interactive live' or 'feed'.", "WARN")
            else
                offer_interactor(bufnr)
            end
            return
        end
    end
    if note then
        utils.notify("interactive: " .. note .. ".", "INFO")
    end

    local timeout = core.time_limit(cfg)
    local rundir = r.running_directory
    utils.ensure_directory(rundir)

    if M.active[bufnr] then
        M.active[bufnr]:kill_all_processes() -- a session left running waits on its input forever
        M.active[bufnr]:delete_ui()
    end

    local ir = setmetatable({
        config = cfg,
        bufnr = bufnr,
        r = r,
        checker = r.checker,
        compare_method = r.compare_method, -- carry the per-buffer `:Tuna compare` override
        source = source,
        -- `feed` replays a stored testcase, so it is edited like one; see `layout`.
        editable_testcases = source == "feed",
        interactor = interactor,
        list = list,
        subset = list ~= nil,
        rundir = rundir,
        timeout = timeout,
        mode = "interactive",
        compile_entry = r.compile and core.compile_row() or nil,
        tcdata = {},
        completed = false,
    }, InteractiveRunner)
    core.register(M.active, bufnr, ir)

    -- What this run compiles, declared before the board opens so the build step is laid out
    -- once: the solution is the compile row itself, the interactor is one when it plays the
    -- other side, and the checker is one whenever it is a program of its own.
    ir:plan_builds({ source == "interactor" and ir.interactor or false, ir.checker })

    -- Rows first, and marked before the board opens: the UI lays its grid out for the row it
    -- opens on, which an empty list leaves as line 1, and which is the build step while a run
    -- is building but a testcase when the rows are only being listed.
    ir:load_rows()
    if opts.show_only then
        ir:mark_not_run()
    end
    ir:show_ui()
    ir:update_ui(true)

    if opts.show_only then
        -- Listed, not run: a row's run key builds the solution and, when it plays the other
        -- side, the interactor, then runs (`built_first`); a run of the whole set builds anyway.
        ir.completed = true
        ir:defer_build(function(cont)
            ir:build_all(source == "interactor" and { ir.interactor } or {}, cont)
        end)
        return
    end
    ir:run_testcases()
end

---Open the interactive UI for a buffer with its rows listed and nothing run.
---@param bufnr integer
function M.show(bufnr)
    M.run(bufnr, nil, { show_only = true })
end

-- The pure half of the conversation, for the test suite.
M._test = { log_append = log_append, conversation = conversation }

return M
