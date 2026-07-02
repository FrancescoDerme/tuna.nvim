-- lua/tuna/runner/init.lua
--
-- The normal run mode plus the shared *resolver* every mode reuses. `M.new(bufnr)`
-- resolves a buffer's compile/run commands, working directories, and checker into a
-- runner object — stress/interactive/multi all call it to get those pieces, then
-- drive their own loops. The normal runner itself runs the buffer's solution against
-- its testcases in parallel (`multiple_testing` at a time), each a `vim.system`
-- child process.
--
-- Everything the results UI touches — `tcdata`, the show/update/resize plumbing, the
-- spawn-and-judge routine (`execute_process`), kill helpers — lives in `RunnerCore`
-- (`runner/core.lua`); `NormalRunner` is a thin subclass that only adds the parallel
-- lane scheduling, completion check, and a fallback results float.
--
-- The "compile" step is modelled as a special testcase at index 1 (`tcnum =
-- "Compile"`): it runs first, and the real testcases only start if it succeeds.

local config = require("tuna.config")
local utils = require("tuna.utils")
local tools = require("tuna.tools")
local core = require("tuna.runner.core")

local M = {}

---@class tuna.TCRunner : tuna.RunnerCore
---@field config table buffer configuration
---@field bufnr integer
---@field cc { exec: string, args: string[] }? compile command (nil for interpreted languages)
---@field rc { exec: string, args: string[] } run command
---@field checker "builtin"|{ exec: string, args: string[]? } resolved verdict checker
---@field compile_directory string
---@field running_directory string
---@field tcdata table[] per-testcase status/data/results (1-indexed)
---@field tc_size integer number of entries in tcdata
---@field compile boolean whether this run compiles first
---@field next_tc integer index of the next unstarted testcase
---@field completed boolean whether the current run has finished
---@field ui table? results UI (set by runner_ui)
---@field on_complete fun(runner: tuna.TCRunner)? called once when a run finishes
local TCRunner = core.extend()
M.TCRunner = TCRunner

---Create a runner for `bufnr`, resolving its compile/run commands and checker.
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

    -- Resolve the checker. The per-buffer toggle (tools.checker_enabled) forces
    -- plain comparison when off. Otherwise:
    --   * "builtin"          -> auto-discover a sibling checker.* source file; if
    --                           found it's compiled (on first judge) and used, else
    --                           plain output_compare_method comparison.
    --   * a path string      -> a checker source file (compiled) or prebuilt binary.
    --   * a { exec, args }    -> a prebuilt checker; only exec is modifier-expanded,
    --     table                 args keep their $(INPUT)/$(OUTPUT)/$(ANSWER) markers.
    local path = vim.api.nvim_buf_get_name(bufnr)
    local resolved_checker = "builtin"
    if not tools.checker_enabled(path) then
        resolved_checker = "builtin"
    elseif cfg.checker == "builtin" then
        local cpath = tools.find(filedir, "checker", cfg)
        if cpath then
            resolved_checker = tools.checker_spec(cpath, cfg)
        end
    elseif type(cfg.checker) == "string" then
        local expanded = utils.buf_eval_string(bufnr, cfg.checker)
        if expanded then
            resolved_checker = tools.checker_spec(expanded, cfg)
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
        mode = "normal", -- run mode shown in the UI (set by commands)
    }, TCRunner)
end

---Run testcases. Pass a `tctbl` for a fresh run, or `nil` to re-run the testcases
---loaded by the previous call (keeping their inputs/expected outputs).
---@param tctbl table<integer, { input: string, output: string? }>? testcases, or nil to re-run
---@param do_compile boolean? whether to compile first (defaults to true)
function TCRunner:run_testcases(tctbl, do_compile)
    if tctbl then
        tools.save_sources(self.bufnr, self.config)

        if do_compile == nil then
            do_compile = true
        end
        self.compile = do_compile and self.cc ~= nil

        self.tcdata = {}
        if self.compile then -- compilation is testcase #1
            table.insert(self.tcdata, { tcnum = "Compile", stdin = "", expected = nil, compile = true })
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
        self:reset_row(tc)
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
        self:execute_process(1, self.cc, self.compile_directory, { judge = false }, function()
            if self.tcdata[1].exit_code == 0 then
                self:fill_lanes(parallel)
            else
                -- compilation failed: skip the rest so the run can complete
                self.next_tc = self.tc_size + 1
                self:check_complete()
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
        self:execute_process(n, self.rc, self.running_directory, {}, function()
            self:run_next_testcase()
            self:check_complete()
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
    self:execute_process(n, self.rc, self.running_directory, {}, function()
        self:run_next_testcase()
        self:check_complete()
    end)
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
    self:reset_row(tc)
    if tcindex == 1 and self.compile then
        self:execute_process(tcindex, self.cc, self.compile_directory, { judge = false }, function()
            self:check_complete()
        end)
    else
        self:execute_process(tcindex, self.rc, self.running_directory, {}, function()
            self:check_complete()
        end)
    end
end

---@private
---Temporary results display used when the runner UI can't be created: a read-only
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
