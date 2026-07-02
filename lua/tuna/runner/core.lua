-- lua/tuna/runner/core.lua
--
-- RunnerCore: the shared base every run mode (normal, stress, interactive, and
-- later run-all) is built on. It owns the half of the runner that the results UI
-- (`runner_ui`) actually talks to — the `tcdata` rows, the UI show/update/resize
-- plumbing, the verdict label, kill helpers — plus one reusable "spawn a process
-- and judge it" routine (`execute_process`). A mode subclass supplies only its own
-- driving loop (parallel lanes / a generation search / interactive sessions) and,
-- if it wants, a `status_tail`, a `pane_content` override, or an `on_ui_shown` hook.
--
-- Inheritance is plain Lua metatable single-dispatch: `M.extend()` returns a
-- subclass table chained to `RunnerCore`, and instances `setmetatable(obj, Sub)`.
-- An instance looks up a method on the subclass first, then falls through to the
-- base — so a subclass overrides just what it needs (see `stress.lua`'s `kill_*`).

local api = vim.api
local utils = require("tuna.utils")
local checker = require("tuna.checker")

local M = {}

---Sentinel a mode's `pane_content` returns to mean "this pane is owned by the mode;
---the UI must not overwrite it" — used by interactive's editable Input pane.
M.SKIP = setmetatable({}, {
    __tostring = function()
        return "RunnerCore.SKIP"
    end,
})

local RunnerCore = {}
RunnerCore.__index = RunnerCore
M.RunnerCore = RunnerCore

---Create a subclass table chained to `RunnerCore` (so instances resolve
---subclass method → base method).
---@return table
function M.extend()
    local sub = {}
    sub.__index = sub
    return setmetatable(sub, { __index = RunnerCore })
end

--------------------------------------------------------------------------------
-- UI contract (what runner_ui drives)
--------------------------------------------------------------------------------

---Notify the attached UI that data changed (no-op when no UI is attached).
---@param update_windows boolean? redraw the selector too, not just the detail panes
function RunnerCore:update_ui(update_windows)
    if self.ui then
        if update_windows then
            self.ui.update_windows = true
        end
        self.ui.update_details = true
        self.ui:update_ui()
    end
end

---Show the results UI, creating it on first use.
function RunnerCore:show_ui()
    if not self.ui then
        self.ui = require("tuna.runner_ui").new(self)
    end
    if self.ui then
        self.ui:show_ui()
    elseif self.display_results then
        self:display_results() -- normal runner's fallback float
    end
end

---Re-show/refresh the UI after a `VimResized`.
function RunnerCore:resize_ui()
    if self.ui then
        self.ui:resize_ui()
    end
end

---Tear the UI down.
function RunnerCore:delete_ui()
    if self.ui then
        self.ui:hide_ui()
    end
    self.ui = nil
end

---A short human label for how verdicts are decided, shown in the "Run" pane.
---@return string
function RunnerCore:judge_label()
    if type(self.checker) == "table" then
        return "checker"
    end
    return "builtin (" .. tostring(self.config.output_compare_method) .. ")"
end

---What text a detail pane should show for `tc`. Overridable so a mode can own or
---relabel a pane; return `M.SKIP` to tell the UI to leave the pane untouched.
---@param tc table the selected testcase row
---@param name string pane name: "so" | "eo" | "si" | "se"
---@return string|table content, or `M.SKIP`
function RunnerCore:pane_content(tc, name)
    if name == "so" then
        return tc.stdout
    elseif name == "eo" then
        return tc.expected
    elseif name == "si" then
        return tc.stdin
    elseif name == "se" then
        return tc.stderr
    end
    return ""
end

--------------------------------------------------------------------------------
-- Shared execution: spawn one process, judge it
--------------------------------------------------------------------------------

---Reset a row's per-run state so a re-run starts clean.
---@param tc table
function RunnerCore:reset_row(tc)
    tc.status = ""
    tc.hlgroup = "TunaRunning"
    tc.stdout = nil
    tc.stderr = nil
    tc.time = nil
    tc.time_label = nil
    tc.running = false
    tc.judging = false
    tc.killed = false
    tc.timed_out = false
    tc.exit_code = nil
    tc.exit_signal = nil
end

---Spawn one `tcdata` process and, on a clean exit, judge it. Used by every
---`vim.system`-based mode. A per-process timeout timer labels a kill as TIMEOUT
---precisely rather than as an anonymous signal.
---@param tcindex integer index into `self.tcdata`
---@param cmd { exec: string, args: string[]? }
---@param dir string working directory
---@param opts { stdin: string?, timelimit: integer?, checker: any?, judge: boolean? }?
---   `stdin`/`timelimit` default to the row's; `checker` defaults to `self.checker`;
---   `judge == false` skips judging (the Compile row) and marks a clean exit DONE.
---@param on_done fun()? called once the row reaches a terminal state
function RunnerCore:execute_process(tcindex, cmd, dir, opts, on_done)
    opts = opts or {}
    local tc = self.tcdata[tcindex]
    utils.ensure_directory(dir)

    local timelimit = opts.timelimit or tc.timelimit
    if timelimit then
        tc.timer = vim.uv.new_timer()
        tc.timer:start(timelimit, 0, function()
            if tc.running then
                tc.timed_out = true
                tc.handle:kill("sigkill")
            end
        end)
    end

    tc.start_time = vim.uv.now()
    local stdin = opts.stdin
    if stdin == nil then
        stdin = tc.stdin
    end
    local argv = vim.list_extend({ cmd.exec }, cmd.args or {})
    local ok, handle = pcall(vim.system, argv, { cwd = dir, stdin = stdin }, function(res)
        -- on_exit is a fast context; defer API/UI work to the main loop.
        vim.schedule(function()
            self:finish_process(tcindex, res, opts, on_done)
        end)
    end)

    if not ok then
        if tc.timer and not tc.timer:is_closing() then
            tc.timer:stop()
            tc.timer:close()
        end
        tc.timer = nil
        tc.status, tc.hlgroup = "FAILED", "TunaWarning"
        tc.stderr = tostring(handle) -- the pcall error message
        tc.time = -1
        self:update_ui(true)
        if on_done then
            on_done()
        end
        return
    end

    tc.handle = handle
    tc.running = true
    tc.status = "RUNNING"
    tc.hlgroup = "TunaRunning"
    self:update_ui(true)
end

---@private
---Record a finished process's result and decide its status (may judge async).
---@param tcindex integer
---@param res vim.SystemCompleted
---@param opts table
---@param on_done fun()?
function RunnerCore:finish_process(tcindex, res, opts, on_done)
    local tc = self.tcdata[tcindex]
    tc.running = false
    tc.time = vim.uv.now() - tc.start_time
    tc.exit_code = res.code
    tc.exit_signal = res.signal
    tc.stdout = res.stdout or ""
    tc.stderr = res.stderr or ""
    tc.handle = nil
    if tc.timer and not tc.timer:is_closing() then
        tc.timer:stop()
        tc.timer:close()
    end
    tc.timer = nil

    local function finalize()
        self:update_ui(true)
        if on_done then
            on_done()
        end
    end

    if tc.timed_out then
        tc.status, tc.hlgroup = "TIMEOUT", "TunaWrong"
        finalize()
    elseif tc.killed then
        tc.status, tc.hlgroup = "KILLED", "TunaWarning"
        finalize()
    elseif tc.exit_signal and tc.exit_signal ~= 0 then
        tc.status, tc.hlgroup = "SIG " .. tc.exit_signal, "TunaWarning"
        finalize()
    elseif tc.exit_code ~= 0 then
        tc.status, tc.hlgroup = "RET " .. tc.exit_code, "TunaWarning"
        finalize()
    elseif opts.judge == false then
        -- The Compile row (or any non-judged step): a clean exit is just DONE, but
        -- its stdout/stderr (compiler warnings) stay viewable in the detail panes.
        tc.status, tc.hlgroup = "DONE", "TunaDone"
        finalize()
    else
        -- Derive the verdict via the checker (nil expected → DONE). External
        -- checkers are async, so flag the row as judging until the verdict lands.
        tc.judging = true
        local chk = opts.checker or self.checker
        checker.judge(tc, chk, self.config.output_compare_method, function(correct, message)
            tc.judging = false
            tc.checker_message = message
            if correct == true then
                tc.status, tc.hlgroup = "CORRECT", "TunaCorrect"
            elseif correct == false then
                tc.status, tc.hlgroup = "WRONG", "TunaWrong"
            else
                tc.status, tc.hlgroup = "DONE", "TunaDone"
            end
            finalize()
        end)
    end
end

--------------------------------------------------------------------------------
-- Kill helpers (stress overrides these to "stop the search")
--------------------------------------------------------------------------------

---Kill a single running process. Its `on_exit` then advances that lane.
---@param tcindex integer
function RunnerCore:kill_process(tcindex)
    local tc = self.tcdata[tcindex]
    if tc and tc.running and tc.handle then
        tc.killed = true
        tc.handle:kill("sigkill")
    end
end

---Kill every running process.
function RunnerCore:kill_all_processes()
    for tcindex in ipairs(self.tcdata) do
        self:kill_process(tcindex)
    end
end

return M
