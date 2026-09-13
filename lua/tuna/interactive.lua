-- lua/tuna/interactive.lua
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
--                  judged against it; otherwise DONE.
--   * interactor — a written interactor program (interactor.*) is cross-wired to the
--                  solution and decides the verdict (exit 0 = accepted). Secondary:
--                  used automatically only when an interactor.* sibling exists, or
--                  when asked for explicitly.
--
-- `vim.system` only hands back stdout when a process *finishes*, so it can't cross-
-- wire live processes. We drop to `vim.uv.spawn` and forward bytes between pipes by
-- hand. Reuse: `runner.new()` resolves the solution's compile/run commands, dirs and
-- checker; the results UI is the shared `runner_ui` (this `InteractiveRunner` is a
-- `RunnerCore` subclass, like the normal and stress runners).

local api = vim.api
local uv = vim.uv
local config = require("tuna.config")
local utils = require("tuna.utils")
local runner = require("tuna.runner")
local checker = require("tuna.checker")
local testcases = require("tuna.testcases")
local tools = require("tuna.tools")
local core = require("tuna.runner.core")

local M = {}

-- Live interactive runners keyed by buffer, so `VimResized` can rebuild their UIs
-- and a fresh run can tear the previous one down (mirrors `stress.M.active`).
---@type table<integer, table>
M.active = {}

local SOURCES = { live = true, feed = true, interactor = true }
local DEFAULT_ARGS = { "$(INPUT)", "$(ANSWER)" }

---Write `content` to a fresh temp file and return its path.
---@param content string?
---@return string
local function temp_with(content)
    local path = vim.fn.tempname()
    utils.write_file(path, content or "")
    return path
end

--------------------------------------------------------------------------------
-- The conversation (live and interactor)
--------------------------------------------------------------------------------

-- The columns a conversation is laid out in, left to right beside the selector.
local CONVERSATION_PANES = { "se", "so", "si" }

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
            last.text = last.text .. piece
            entry = last
        else
            entry = { col = col, text = piece }
            tc.log[#tc.log + 1] = entry
        end
        entry.open = i == #pieces and not ends_line
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
---every column but the one that wrote it. The three come back the same length, so the
---columns stay line for line.
---@param log table[]?
---@return table<string, string[]>
local function conversation(log)
    local out = { so = {}, se = {}, si = {} }
    for _, entry in ipairs(log or {}) do
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

---The grid follows the source. `feed` keeps whatever layout is configured, with the
---canonical Input and Expected Output panes, editable as in a normal run: what it replays is
---a stored testcase, its input the script and its expected output the verdict. `live` and
---`interactor` are a conversation and are laid out as one — the selector, then a column
---each for Output, Live and Errors, every one full height, so a row of one faces the same
---row of the others. Expected output has no place in it, a sample exchange being one
---example of a conversation rather than the only correct one.
---@return table?
function InteractiveRunner:layout()
    if not self:conversational() then
        return nil
    end
    -- The selector takes the share it has in the configured grid (3 of 11), so it is the
    -- width it is in every other mode, compile time and all. Output and Live share a ratio,
    -- which is what makes them the same width: the last column absorbs whatever the grid's
    -- division leaves over, so Errors goes last, its two lines of tuna's own notes being
    -- what can spare a cell.
    return { { 3, "tc" }, { 3, "so" }, { 3, "si" }, { 2, "se" } }
end

---`si` is named for what it is in a conversation: the other side of it, not a stored
---testcase's input.
---@return table<string, string>?
function InteractiveRunner:pane_titles()
    if not self:conversational() then
        return nil
    end
    return { si = " Live " }
end

---In live mode the Live pane is typed into, so the UI must leave its letters alone
---(no `q`-to-close on it) even though testcases aren't editable in this mode.
---@param name string
---@return boolean
function InteractiveRunner:owns_pane(name)
    return name == "si" and self.source == "live"
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
---shows the input being fed, and Errors carries a checker's message.
function InteractiveRunner:pane_content(tc, name)
    if self:conversational() and (name == "so" or name == "se" or name == "si" or name == "eo") then
        return core.SKIP
    end
    return core.RunnerCore.pane_content(self, tc, name)
end

---A single session runs at a time; killing it ends that session.
function InteractiveRunner:kill_all_processes()
    if self.sol_handle and self.sol_handle:is_active() then
        pcall(function()
            self.sol_handle:kill("sigkill")
        end)
    end
    if self.int_handle and self.int_handle:is_active() then
        pcall(function()
            self.int_handle:kill("sigkill")
        end)
    end
end

function InteractiveRunner:kill_process()
    self:kill_all_processes()
end

---Re-running one row restarts its session. It claims the runner while the session runs,
---as the normal runner's `run_single` does: `idle()` reads `completed`, and a re-run that
---left it true let the structural edits `feed` allows (`n`, `x`, a split) through
---mid-session.
---@param idx integer
function InteractiveRunner:run_single(idx)
    local tc = self.tcdata[idx]
    if not tc or tc.tcnum == "Compile" then
        return
    end
    self.completed = false
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

---Restart every session from the top (the UI's "run all again").
function InteractiveRunner:run_testcases()
    if self:built_first(function()
        self:run_testcases()
    end) then
        return
    end
    self:with_helpers(function()
        self:run_sessions()
    end)
end

---Look this run's helpers up again before a rerun, as every run does: the checker, and for
---the interactor source the interactor, prepared again so an edited one rebuilds. A rerun
---keeps its source, so an interactor that is gone is reported and nothing runs: `:Tuna run`
---picks the source again.
---@param cont fun()
function InteractiveRunner:with_helpers(cont)
    local solution = api.nvim_buf_get_name(self.bufnr)
    self:refresh_judge(solution)
    if self.source ~= "interactor" then
        return cont()
    end
    local function stop(title, text)
        self.completed = true
        if self.ui then
            self.ui:show_message(title, text)
        else
            utils.notify("interactive: " .. text, "WARN")
        end
        self:update_ui(true)
    end
    local spec, missing = tools.helper("interactor", solution, self.config)
    if not spec then
        return stop(" interactive: no interactor ", (missing or "the interactor is gone") .. ", :Tuna run picks the source again.")
    end
    self.interactor = spec
    tools.prepare(spec, function(ok, err)
        if not ok then
            return stop(" interactive: interactor failed to compile ", err or "")
        end
        cont()
    end)
end

---In a conversation the three columns are scroll-bound and unwrapped, so reading back
---through one keeps the rows of all three level. When `live`, the Live column is also
---typed into, and <CR> sends the line being typed.
---@param ui table the RunnerUI
function InteractiveRunner:on_ui_shown(ui)
    if not self:conversational() then
        return
    end
    for _, name in ipairs(CONVERSATION_PANES) do
        local w = ui.windows[name]
        if w and w.winid and api.nvim_win_is_valid(w.winid) then
            api.nvim_set_option_value("scrollbind", true, { scope = "local", win = w.winid })
            api.nvim_set_option_value("wrap", false, { scope = "local", win = w.winid })
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
        if api.nvim_win_is_valid(w.winid) then
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
    if not self:conversational() then
        return
    end
    local w = {}
    for _, name in ipairs(CONVERSATION_PANES) do
        w[name] = ui.windows[name]
        if not (w[name] and w[name].bufnr and api.nvim_buf_is_valid(w[name].bufnr)) then
            return
        end
    end

    local cols
    if tc.tcnum == "Compile" then
        -- The build is not a conversation: it has output and errors, and nobody answers.
        cols = {
            so = vim.split(tc.stdout or "", "\n", { plain = true }),
            se = vim.split(tc.stderr or "", "\n", { plain = true }),
            si = {},
        }
    else
        cols = conversation(tc.log)
    end

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

    local composing = self.source == "live"
        and self.sol_in ~= nil
        and tc.tcnum ~= "Compile"
        and tc == self.tcdata[self.active_index]
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

---Spawn the solution with three pipes and forward its output through `cbs`.
---`cbs`: on_stdout(data), on_stderr(data), on_exit(code, signal), on_error(msg),
---optional on_timeout() when `cbs.timed` and `self.timeout` are set.
---@param cbs table
function InteractiveRunner:spawn_solution(cbs)
    local sol_in, sol_out, sol_err = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    self.sol_in = sol_in
    local timer
    local done = false
    local handle

    local function cleanup()
        for _, p in ipairs({ sol_in, sol_out, sol_err }) do
            if p and not p:is_closing() then
                p:close()
            end
        end
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
        end
    end

    handle = uv.spawn(self.r.rc.exec, {
        args = self.r.rc.args,
        cwd = self.rundir,
        stdio = { sol_in, sol_out, sol_err },
    }, function(code, signal)
        if done then
            return
        end
        done = true
        self.sol_handle = nil
        cleanup()
        vim.schedule(function()
            cbs.on_exit(code, signal)
        end)
    end)

    if not handle then
        cleanup()
        vim.schedule(function()
            cbs.on_error("could not start solution '" .. tostring(self.r.rc.exec) .. "'")
        end)
        return
    end
    self.sol_handle = handle

    sol_out:read_start(function(err, data)
        if err or done or not data then
            return
        end
        vim.schedule(function()
            if not done then
                cbs.on_stdout(data)
            end
        end)
    end)
    sol_err:read_start(function(err, data)
        if err or done or not data then
            return
        end
        vim.schedule(function()
            if not done then
                cbs.on_stderr(data)
            end
        end)
    end)

    if self.timeout and cbs.timed then
        timer = uv.new_timer()
        timer:start(self.timeout, 0, function()
            if not done then
                vim.schedule(cbs.on_timeout)
                if handle:is_active() then
                    pcall(function()
                        handle:kill("sigkill")
                    end)
                end
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
    tc.status, tc.hlgroup = "LIVE", "TunaRunning"
    tc.stdout, tc.stderr, tc.log = "", "", {}
    self:update_ui(true)

    self:spawn_solution({
        on_stdout = function(data)
            tc.stdout = tc.stdout .. data
            log_append(tc, "so", data)
            self:update_ui(false)
        end,
        on_stderr = function(data)
            tc.stderr = tc.stderr .. data
            log_append(tc, "se", data)
            self:update_ui(false)
        end,
        on_error = function(msg)
            tc.status, tc.hlgroup, tc.stderr = "FAILED", "TunaWarning", msg
            log_note(tc, msg)
            self.sol_in = nil
            self:update_ui(true)
            on_done()
        end,
        on_exit = function()
            tc.status, tc.hlgroup = "DONE", "TunaDone"
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
    tc.status, tc.hlgroup = "RUNNING", "TunaRunning"
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

    self:spawn_solution({
        timed = true,
        on_stdout = function(data)
            tc.stdout = tc.stdout .. data
            self:update_ui(false)
            -- One input line per *line* of output: a chunk carrying several newlines
            -- is several completed turns, and answering it with a single line
            -- deadlocked any protocol that prints more than one line per query.
            for _ in data:gmatch("\n") do
                send_next()
            end
        end,
        on_stderr = function(data)
            tc.stderr = tc.stderr .. data
            self:update_ui(false)
        end,
        on_timeout = function()
            timed_out = true
        end,
        on_error = function(msg)
            tc.status, tc.hlgroup, tc.stderr = "FAILED", "TunaWarning", msg
            self.sol_in = nil
            self:update_ui(true)
            on_done()
        end,
        on_exit = function(code, signal)
            self.sol_in = nil
            if timed_out then
                tc.status, tc.hlgroup = "TIMEOUT", "TunaWrong"
                self:update_ui(true)
                return on_done()
            elseif signal and signal ~= 0 then
                tc.status, tc.hlgroup = "SIG " .. signal, "TunaWarning"
                self:update_ui(true)
                return on_done()
            elseif code ~= 0 then
                tc.status, tc.hlgroup = "RET " .. code, "TunaWarning"
                self:update_ui(true)
                return on_done()
            elseif tc.expected ~= nil then
                tc.judging = true
                checker.judge(tc, self.checker, self:effective_compare(), function(correct, message)
                    tc.judging = false
                    tc.checker_message = message
                    if correct == true then
                        tc.status, tc.hlgroup = "CORRECT", "TunaCorrect"
                    elseif correct == false then
                        tc.status, tc.hlgroup = "WRONG", "TunaWrong"
                    else
                        tc.status, tc.hlgroup = "DONE", "TunaDone"
                    end
                    self:update_ui(true)
                    on_done()
                end)
            else
                tc.status, tc.hlgroup = "DONE", "TunaDone"
                self:update_ui(true)
                on_done()
            end
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
    tc.status, tc.hlgroup = "RUNNING", "TunaRunning"
    tc.stdout, tc.stderr, tc.log = "", "", {}
    self:update_ui(true)

    local input_file = temp_with(tc.stdin or "")
    local answer_file = temp_with(tc.expected or "")
    local files = { INPUT = input_file, OUTPUT = "/dev/null", ANSWER = answer_file }
    local raw = (#self.interactor.args > 0) and self.interactor.args or DEFAULT_ARGS
    local int_args = {}
    for i, a in ipairs(raw) do
        int_args[i] = a:gsub("%$%((%u+)%)", function(name)
            return files[name]
        end)
    end

    local sol_in, sol_out = uv.new_pipe(false), uv.new_pipe(false)
    local int_in, int_out, int_err = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    local sol_handle, int_handle, timer
    local done, verdict, int_exited, failed = false, nil, false, false

    local function safe_close(h)
        if h and not h:is_closing() then
            h:close()
        end
    end
    local function finish()
        if done then
            return
        end
        done = true
        if timer then
            timer:stop()
            safe_close(timer)
        end
        if sol_handle and sol_handle:is_active() then
            pcall(function()
                sol_handle:kill("sigkill")
            end)
        end
        if int_handle and int_handle:is_active() then
            pcall(function()
                int_handle:kill("sigkill")
            end)
        end
        for _, p in ipairs({ sol_in, sol_out, int_in, int_out, int_err }) do
            safe_close(p)
        end
        utils.delete_file(input_file)
        utils.delete_file(answer_file)
        self.sol_handle, self.int_handle = nil, nil
        vim.schedule(function()
            if failed then
                -- The session never happened (the interactor would not start): that is
                -- not a DONE, which reads as a session that ran and was not judged.
                tc.status, tc.hlgroup = "FAILED", "TunaWarning"
            elseif verdict == true then
                tc.status, tc.hlgroup = "CORRECT", "TunaCorrect"
            elseif verdict == false then
                tc.status, tc.hlgroup = "WRONG", "TunaWrong"
            else
                tc.status, tc.hlgroup = "DONE", "TunaDone"
            end
            self:update_ui(true)
            on_done()
        end)
    end

    sol_handle = uv.spawn(self.r.rc.exec, {
        args = self.r.rc.args,
        cwd = self.rundir,
        stdio = { sol_in, sol_out, nil },
    }, function(code, signal)
        safe_close(sol_handle)
        sol_handle = nil
        if not int_exited and not done and (code ~= 0 or (signal and signal ~= 0)) then
            verdict = false
            tc.stderr = (tc.stderr or "") .. "\n[solution exited with code " .. tostring(code) .. "]"
            log_note(tc, "[solution exited with code " .. tostring(code) .. "]")
            finish()
        end
    end)
    if not sol_handle then
        for _, p in ipairs({ sol_in, sol_out, int_in, int_out, int_err }) do
            safe_close(p)
        end
        tc.status, tc.hlgroup, tc.stderr = "FAILED", "TunaWarning", "could not start solution"
        log_note(tc, tc.stderr)
        self:update_ui(true)
        return on_done()
    end
    self.sol_handle = sol_handle

    int_handle = uv.spawn(self.interactor.exec, {
        args = int_args,
        cwd = self.rundir,
        stdio = { int_in, int_out, int_err },
    }, function(code, signal)
        safe_close(int_handle)
        int_handle = nil
        int_exited = true
        verdict = (code == 0 and (not signal or signal == 0))
        finish()
    end)
    if not int_handle then
        tc.stderr = "could not start interactor '" .. tostring(self.interactor.exec) .. "'"
        log_note(tc, tc.stderr)
        failed = true
        finish()
        return
    end
    self.int_handle = int_handle

    -- Cross-wire, teeing each side of the exchange into the transcript.
    sol_out:read_start(function(err, data)
        if err or done then
            return
        end
        if data then
            if not int_in:is_closing() then
                int_in:write(data)
            end
            vim.schedule(function()
                if not done then
                    tc.stdout = (tc.stdout or "") .. data
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
        if data then
            if not sol_in:is_closing() then
                sol_in:write(data)
            end
            vim.schedule(function()
                if not done then
                    log_append(tc, "si", data)
                    self:update_ui(false)
                end
            end)
        elseif not sol_in:is_closing() then
            sol_in:shutdown()
        end
    end)
    int_err:read_start(function(err, data)
        if not err and data then
            vim.schedule(function()
                if not done then
                    tc.stderr = (tc.stderr or "") .. data
                    log_append(tc, "se", data)
                    self:update_ui(false)
                end
            end)
        end
    end)

    if self.timeout then
        timer = uv.new_timer()
        timer:start(self.timeout, 0, function()
            if not done then
                verdict = false
                tc.stderr = (tc.stderr or "") .. "\n[timed out after " .. self.timeout .. "ms]"
                log_note(tc, "[timed out after " .. self.timeout .. "ms]")
                finish()
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
        if tc.tcnum ~= "Compile" then
            self:reset_row(tc)
            order[#order + 1] = i
        end
    end
    self.completed = false
    local k = 0
    local function step()
        k = k + 1
        if k > #order then
            self.completed = true
            core.save_buffer_verdict(self.bufnr, self.tcdata)
            self:update_ui(true)
            return
        end
        self:run_one_session(order[k], step)
    end
    step()
end

---Build the testcase rows (plus the solution Compile row).
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

---Rebuild any open interactive UIs after a `VimResized`.
function M.resize_all()
    for _, ir in pairs(M.active) do
        ir:resize_ui()
    end
end

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
    local dir = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":p:h")
    local path = api.nvim_buf_get_name(bufnr)
    if not opts.show_only then
        tools.save_sources(bufnr, cfg) -- save the solution (interactor saved in tools.prepare)
    end

    -- Pull a leading source keyword out of the args (the rest are testcase numbers). A
    -- source typed now is forced and runs as typed, `auto` makes it automatic again.
    local list = args and vim.deepcopy(args) or nil
    local typed
    if list and list[1] and (SOURCES[list[1]] or list[1] == "auto") then
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
            utils.notify(
                "interactive: "
                    .. (missing or "no interactor, add an interactor.* file or set interactive.interactor")
                    .. ", or run ':Tuna run interactive live' or 'feed'.",
                "WARN"
            )
            return
        end
    end
    if note then
        utils.notify("interactive: " .. note .. ".", "INFO")
    end

    local timeout = (cfg.maximum_time and cfg.maximum_time > 0) and cfg.maximum_time or nil
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
        dir = dir,
        rundir = rundir,
        timeout = timeout,
        mode = "interactive",
        compile_entry = r.compile
                and { tcnum = "Compile", stdin = "", expected = nil, status = "", hlgroup = "TunaRunning" }
            or nil,
        tcdata = {},
        completed = false,
    }, InteractiveRunner)
    M.active[bufnr] = ir

    api.nvim_create_autocmd("BufUnload", {
        buffer = bufnr,
        once = true,
        callback = function()
            M.active[bufnr] = nil
        end,
    })

    -- Rows first: the UI lays its grid out for the row it opens on, and an empty list leaves
    -- it nothing to open on but line 1.
    ir:load_rows()
    ir:show_ui()
    ir:update_ui(true)

    -- Build the solution once (driving the Compile row) and the interactor, if any, then
    -- run `cont`.
    local function build(cont)
        local function prepare_and_start()
            if source ~= "interactor" then
                cont()
                return
            end
            tools.prepare(ir.interactor, function(ok, err)
                if not ok then
                    -- Nothing will run, so nothing is in flight either: left `false`, the
                    -- runner would refuse every edit with "wait for the run to finish".
                    ir.completed = true
                    if ir.ui then
                        ir.ui:show_message(" interactive: interactor failed to compile ", err or "")
                    end
                    return
                end
                cont()
            end)
        end

        if not r.compile then
            prepare_and_start()
            return
        end
        local ce = ir.compile_entry
        ce.status, ce.hlgroup, ce.start_time = "RUNNING", "TunaRunning", vim.uv.now()
        -- Said the way `execute_process` says it of a testcase row: the UI reads `running` to
        -- know a build is still in flight, and keeps the cursor on it until it is not.
        ce.running = true
        ir:update_ui(true)
        utils.ensure_directory(r.compile_directory)
        -- pcall'd: a compiler that is not installed makes `vim.system` itself throw,
        -- and that failure belongs on the Compile row like any other.
        local ok, err = pcall(
            vim.system,
            vim.list_extend({ r.cc.exec }, vim.deepcopy(r.cc.args)),
            { cwd = r.compile_directory },
            function(res)
                vim.schedule(function()
                    ce.time = vim.uv.now() - ce.start_time
                    ce.running = false
                    ce.stdout, ce.stderr, ce.exit_code = res.stdout or "", res.stderr or "", res.code
                    if res.code ~= 0 then
                        ce.status, ce.hlgroup = "RET " .. tostring(res.code), "TunaWarning"
                        ir.completed = true -- nothing will run; see the interactor case above
                        ir:update_ui(true)
                        return
                    end
                    ce.status, ce.hlgroup = "DONE", "TunaDone"
                    ir:update_ui(true)
                    prepare_and_start()
                end)
            end
        )
        if not ok then
            ce.status, ce.hlgroup, ce.stderr, ce.running = "FAILED", "TunaWarning", tostring(err), false
            ir.completed = true
            ir:update_ui(true)
        end
    end

    if opts.show_only then
        -- Listed, not run: the first run key builds and starts the sessions (`built_first`).
        ir:mark_not_run()
        ir.completed = true
        ir.build = function(cont)
            tools.save_sources(bufnr, cfg)
            build(cont)
        end
        ir:update_ui(true)
        return
    end
    build(function()
        ir:run_sessions()
    end)
end

---Open the interactive UI for a buffer with its rows listed and nothing run.
---@param bufnr integer
function M.show(bufnr)
    M.run(bufnr, nil, { show_only = true })
end

-- The pure half of the conversation, for the test suite.
M._test = { log_append = log_append, conversation = conversation }

return M
