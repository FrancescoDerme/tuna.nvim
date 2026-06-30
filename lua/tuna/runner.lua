-- lua/tuna/runner.lua
--
-- Runs the current buffer's solution against its testcases and records the
-- result of each. The engine is async and parallel: every testcase is a
-- `vim.system` child process, and up to `multiple_testing` of them run at once.
--
-- A note on `vim.system`: it is Neovim's modern process wrapper (over libuv's
-- spawn). We give it `{ exec, args... }`, an options table (`cwd`, `stdin`), and
-- an `on_exit` callback that receives `{ code, signal, stdout, stderr }`. It
-- handles the stdin/stdout/stderr pipes for us — far less plumbing than driving
-- `vim.uv.spawn` and three pipes by hand. We still manage our own timeout timer
-- so we can label a kill as TIMEOUT precisely rather than as a generic signal.
--
-- The "compile" step is modelled as a special testcase at index 1 (`tcnum =
-- "Compile"`): it runs first, and the real testcases only start if it succeeds.
--
-- This module is the execution engine only. The rich results UI is `runner_ui`
-- (a later port); until it exists, `display_results()` shows a temporary float
-- so `:Tuna run` is usable. When `runner_ui` lands it sets `runner.ui` and the
-- `update_ui` hooks below drive it instead.

local config = require("tuna.config")
local utils = require("tuna.utils")
local testcases = require("tuna.testcases")
local checker = require("tuna.checker")

local M = {}

---@class tuna.TCRunner
---@field config table buffer configuration
---@field bufnr integer
---@field cc { exec: string, args: string[] }? compile command (nil for interpreted languages)
---@field rc { exec: string, args: string[] } run command
---@field checker "builtin"|fun(tc: table): boolean?, string?|{ exec: string, args: string[]? } resolved verdict checker
---@field compile_directory string
---@field running_directory string
---@field tcdata table[] per-testcase status/data/results (1-indexed)
---@field tc_size integer number of entries in tcdata
---@field compile boolean whether this run compiles first
---@field next_tc integer index of the next unstarted testcase
---@field completed boolean whether the current run has finished
---@field ui table? results UI (set by runner_ui once ported)
---@field on_complete fun(runner: tuna.TCRunner)? called once when a run finishes
local TCRunner = {}
TCRunner.__index = TCRunner

---Create a runner for `bufnr`, resolving its compile/run commands.
---@param bufnr integer? defaults to the current buffer
---@return tuna.TCRunner? # the runner, or `nil` if the commands are missing/malformed
function M.new(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local filetype = vim.bo[bufnr].filetype or ""
    local filedir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
    local cfg = config.get_buffer_config(bufnr)

    -- Expand $(FNAME)/$(FNOEXT)/... in a command's exec and every arg.
    local function eval_command(command)
        local exec = utils.buf_eval_string(bufnr, command.exec)
        if not exec then
            return nil
        end
        local args = {}
        for i, arg in ipairs(command.args or {}) do
            args[i] = utils.buf_eval_string(bufnr, arg)
            if not args[i] then
                return nil
            end
        end
        return { exec = exec, args = args }
    end

    local compile_command
    if cfg.compile_command[filetype] then
        compile_command = eval_command(cfg.compile_command[filetype])
        if not compile_command then
            utils.notify("compile command for '" .. filetype .. "' is malformed; cannot run.")
            return nil
        end
    end
    if not cfg.run_command[filetype] then
        utils.notify("no run command configured for filetype '" .. filetype .. "'; cannot run.")
        return nil
    end
    local run_command = eval_command(cfg.run_command[filetype])
    if not run_command then
        utils.notify("run command for '" .. filetype .. "' is malformed; cannot run.")
        return nil
    end

    -- Resolve the checker. "builtin" (the default) uses output_compare_method.
    -- An external checker may be a path string or a { exec, args } table; only
    -- the exec is modifier-expanded here — its args keep the $(INPUT)/$(OUTPUT)/
    -- $(ANSWER) placeholders, which `checker.judge` fills in per testcase.
    local resolved_checker = "builtin"
    if type(cfg.checker) == "function" then
        resolved_checker = cfg.checker
    elseif type(cfg.checker) == "string" and cfg.checker ~= "builtin" then
        local exec = utils.buf_eval_string(bufnr, cfg.checker)
        if exec then
            resolved_checker = { exec = exec }
        else
            utils.notify("checker path is malformed; falling back to builtin comparison.", "WARN")
        end
    elseif type(cfg.checker) == "table" and cfg.checker.exec then
        local exec = utils.buf_eval_string(bufnr, cfg.checker.exec)
        if exec then
            resolved_checker = { exec = exec, args = cfg.checker.args }
        else
            utils.notify("checker command is malformed; falling back to builtin comparison.", "WARN")
        end
    end

    return setmetatable({
        config = cfg,
        bufnr = bufnr,
        cc = compile_command,
        rc = run_command,
        checker = resolved_checker,
        compile_directory = vim.fs.normalize(filedir .. "/" .. cfg.compile_directory) .. "/",
        running_directory = vim.fs.normalize(filedir .. "/" .. cfg.running_directory) .. "/",
        tcdata = {},
        tc_size = 0,
        compile = compile_command ~= nil,
        next_tc = 1,
        completed = false,
    }, TCRunner)
end

---Run testcases. Pass a `tctbl` for a fresh run, or `nil` to re-run the testcases
---loaded by the previous call (keeping their inputs/expected outputs).
---@param tctbl table<integer, { input: string, output: string? }>? testcases, or nil to re-run
---@param do_compile boolean? whether to compile first (defaults to true)
function TCRunner:run_testcases(tctbl, do_compile)
    if tctbl then
        if self.config.save_all_files then
            vim.cmd("silent! wall")
        elseif self.config.save_current_file then
            vim.api.nvim_buf_call(self.bufnr, function()
                vim.cmd("silent! write")
            end)
        end

        if do_compile == nil then
            do_compile = true
        end
        self.compile = do_compile and self.cc ~= nil

        self.tcdata = {}
        if self.compile then -- compilation is testcase #1
            table.insert(self.tcdata, { tcnum = "Compile", stdin = "", expected = nil })
        end
        -- Insert testcases in ascending tcnum order for a stable display.
        local nums = vim.tbl_keys(tctbl)
        table.sort(nums)
        local timelimit = (self.config.maximum_time and self.config.maximum_time > 0) and self.config.maximum_time or nil
        for _, tcnum in ipairs(nums) do
            local tc = tctbl[tcnum]
            table.insert(self.tcdata, {
                tcnum = tcnum,
                stdin = tc.input or "",
                expected = tc.output,
                timelimit = timelimit,
            })
        end
    end

    -- Reset per-run state (so re-runs start clean).
    for _, tc in ipairs(self.tcdata) do
        tc.status = ""
        tc.hlgroup = "TunaRunning"
        tc.stdout = nil
        tc.stderr = nil
        tc.time = nil
        tc.running = false
        tc.judging = false
        tc.killed = false
        tc.timed_out = false
        tc.exit_code = nil
        tc.exit_signal = nil
    end

    self.tc_size = #self.tcdata
    self.completed = false
    if self.tc_size == 0 then
        utils.notify("no testcases to run.", "WARN")
        return
    end

    -- How many testcases to run concurrently.
    local parallel = self.config.multiple_testing
    if parallel == -1 then
        parallel = vim.uv.available_parallelism()
    elseif parallel == 0 then
        parallel = self.tc_size
    end
    parallel = math.max(1, parallel)

    if self.compile then
        self.next_tc = 2
        self:execute_testcase(1, self.cc, self.compile_directory, function()
            if self.tcdata[1].exit_code == 0 then
                self:fill_lanes(parallel)
            else
                -- compilation failed: skip the rest so the run can complete
                self.next_tc = self.tc_size + 1
            end
        end)
    else
        self.next_tc = 1
        self:fill_lanes(parallel)
    end
end

---@private
---Start up to `parallel` testcases; each, on finishing, pulls the next one.
---@param parallel integer
function TCRunner:fill_lanes(parallel)
    for _ = 1, parallel do
        if self.next_tc > self.tc_size then
            break
        end
        local n = self.next_tc
        self.next_tc = self.next_tc + 1
        self:execute_testcase(n, self.rc, self.running_directory, function()
            self:run_next_testcase()
        end)
    end
end

---@private
---Run the next unstarted testcase, if any (one parallel lane's continuation).
function TCRunner:run_next_testcase()
    if self.next_tc > self.tc_size then
        return
    end
    local n = self.next_tc
    self.next_tc = self.next_tc + 1
    self:execute_testcase(n, self.rc, self.running_directory, function()
        self:run_next_testcase()
    end)
end

---@private
---Spawn one testcase process.
---@param tcindex integer index in `self.tcdata`
---@param cmd { exec: string, args: string[] }
---@param dir string working directory
---@param callback fun()? run when the process exits
function TCRunner:execute_testcase(tcindex, cmd, dir, callback)
    local tc = self.tcdata[tcindex]
    utils.ensure_directory(dir)

    -- Our own timeout timer, so a timed-out process is labelled TIMEOUT rather
    -- than as an anonymous kill.
    if tc.timelimit then
        tc.timer = vim.uv.new_timer()
        tc.timer:start(tc.timelimit, 0, function()
            if tc.running then
                tc.timed_out = true
                tc.handle:kill("sigkill")
            end
        end)
    end

    tc.start_time = vim.uv.now()
    local argv = vim.list_extend({ cmd.exec }, cmd.args or {})
    local ok, handle = pcall(vim.system, argv, {
        cwd = dir,
        stdin = tc.stdin,
    }, function(res)
        -- on_exit runs in a fast context; defer the API/UI work to the main loop.
        vim.schedule(function()
            self:finish_testcase(tcindex, res, callback)
        end)
    end)

    if not ok then
        if tc.timer then
            tc.timer:stop()
            tc.timer:close()
            tc.timer = nil
        end
        tc.status = "FAILED"
        tc.hlgroup = "TunaWarning"
        tc.stderr = tostring(handle) -- the pcall error message
        tc.time = -1
        self:update_ui(true)
        if callback then
            callback()
        end
        self:check_complete()
        return
    end

    tc.handle = handle
    tc.running = true
    tc.status = "RUNNING"
    tc.hlgroup = "TunaRunning"
    self:update_ui(true)
end

---@private
---Record a finished process's result and decide its status.
---@param tcindex integer
---@param res vim.SystemCompleted
---@param callback fun()?
function TCRunner:finish_testcase(tcindex, res, callback)
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

    -- Updating the UI, advancing the lane, and checking for completion happens
    -- once the verdict is known. The checker may be async (external program), so
    -- this is wrapped and called either inline or from the checker callback.
    local function finalize()
        self:update_ui(true)
        if callback then
            callback()
        end
        self:check_complete()
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
    else
        -- exited cleanly: derive the verdict via the checker (nil expected → DONE).
        -- An external checker is async: mark the testcase as still being judged so
        -- `check_complete` doesn't declare the run finished before the verdict lands.
        tc.judging = true
        checker.judge(tc, self.checker, self.config.output_compare_method, function(correct, message)
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

---@private
---Fire the completion hook once every testcase has reached a terminal state.
function TCRunner:check_complete()
    if self.completed or self.next_tc <= self.tc_size then
        return
    end
    for _, tc in ipairs(self.tcdata) do
        if tc.running or tc.judging then
            return
        end
    end
    self.completed = true
    self:update_ui(true)
    if self.on_complete then
        self.on_complete(self)
    end
    if not self.ui then
        self:display_results()
    end
end

---Re-run a single testcase (used by the UI's "run again"). Resets that entry and
---executes it with the appropriate command/directory.
---@param tcindex integer
function TCRunner:run_single(tcindex)
    local tc = self.tcdata[tcindex]
    if not tc then
        return
    end
    tc.status = ""
    tc.hlgroup = "TunaRunning"
    tc.stdout = nil
    tc.stderr = nil
    tc.time = nil
    tc.running = false
    tc.judging = false
    tc.killed = false
    tc.timed_out = false
    tc.exit_code = nil
    tc.exit_signal = nil
    if tcindex == 1 and self.compile then
        self:execute_testcase(tcindex, self.cc, self.compile_directory)
    else
        self:execute_testcase(tcindex, self.rc, self.running_directory)
    end
end

---Kill a single running testcase process. Killing triggers its `on_exit`, which
---then pulls the next queued testcase in that lane.
---@param tcindex integer
function TCRunner:kill_process(tcindex)
    local tc = self.tcdata[tcindex]
    if tc and tc.running and tc.handle then
        tc.killed = true
        tc.handle:kill("sigkill")
    end
end

---Kill every running testcase process.
function TCRunner:kill_all_processes()
    for tcindex in ipairs(self.tcdata) do
        self:kill_process(tcindex)
    end
end

--------------------------------------------------------------------------------
-- UI hooks
--------------------------------------------------------------------------------

---Notify the attached UI that data changed (no-op until `runner_ui` is ported).
---@param update_windows boolean? redraw all windows, not just the details pane
function TCRunner:update_ui(update_windows)
    if self.ui then
        if update_windows then
            self.ui.update_windows = true
        end
        self.ui.update_details = true
        self.ui:update_ui()
    end
end

---Show the results UI, creating it on first use. Falls back to the temporary
---results float if the UI can't be created (e.g. a bad `runner_ui.interface`).
function TCRunner:show_ui()
    if not self.ui then
        self.ui = require("tuna.runner_ui").new(self)
    end
    if self.ui then
        self.ui:show_ui()
    else
        self:display_results()
    end
end

---Re-show/refresh the runner UI after a `VimResized`.
function TCRunner:resize_ui()
    if self.ui then
        self.ui:resize_ui()
    end
end

---@private
---Temporary results display used until `runner_ui` (step 8) lands: a read-only
---float summarising each testcase, with expected/actual shown on a mismatch.
function TCRunner:display_results()
    local lines = {}
    for _, tc in ipairs(self.tcdata) do
        local label = tc.tcnum == "Compile" and "Compile" or ("Testcase " .. tc.tcnum)
        local timestr = (tc.time and tc.time >= 0) and (" (" .. tc.time .. "ms)") or ""
        table.insert(lines, ("%-12s %s%s"):format(label, tc.status, timestr))
        if tc.stderr and tc.stderr ~= "" then
            table.insert(lines, "  stderr:")
            for _, l in ipairs(vim.split(tc.stderr:gsub("%s+$", ""), "\n", { plain = true })) do
                table.insert(lines, "    " .. l)
            end
        end
        if tc.status == "WRONG" then
            table.insert(lines, "  expected:")
            for _, l in ipairs(vim.split((tc.expected or ""):gsub("%s+$", ""), "\n", { plain = true })) do
                table.insert(lines, "    " .. l)
            end
            table.insert(lines, "  got:")
            for _, l in ipairs(vim.split((tc.stdout or ""):gsub("%s+$", ""), "\n", { plain = true })) do
                table.insert(lines, "    " .. l)
            end
        end
    end
    if #lines == 0 then
        lines = { "no results" }
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "tuna"

    local width, height = utils.get_ui_size()
    local win_w = math.min(math.max(40, width - 8), 100)
    local win_h = math.min(#lines + 1, math.floor(height * 0.6))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = win_w,
        height = win_h,
        row = math.floor((height - win_h) / 2),
        col = math.floor((width - win_w) / 2),
        border = self.config.floating_border,
        title = " Results ",
        title_pos = "center",
        style = "minimal",
    })
    utils.set_border_highlight(win, self.config.floating_border_highlight)
    for _, key in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", key, function()
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
        end, { buffer = buf, nowait = true })
    end
end

return M
