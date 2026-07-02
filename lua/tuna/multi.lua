-- lua/tuna/multi.lua
--
-- Run *every* solution version in a problem directory against the shared testcases
-- (`:Tuna run all`). This is for when you keep several attempts side by side —
-- `main.cpp`, `slow.cpp`, `wrong.cpp` — and want to see at a glance which pass.
--
-- The candidate files are the runnable sibling *source* files, of any language
-- (each file's compile/run commands come from its own filetype), minus helper files
-- (`checker.*`/`gen.*`/`brute.*`/`interactor.*`). Commands are resolved per file with
-- `utils.eval_string` (no buffer needed), and each verdict goes through the same
-- `checker` as a normal run.
--
-- A `MultiRunner` (a `RunnerCore` subclass) drives the shared `runner_ui` as a
-- flattened matrix: one solution *header* row (name + a live `correct/total`) above
-- its indented per-testcase rows. Selecting a testcase row shows that exact run in
-- the detail panes; selecting a solution row shows its per-testcase summary and any
-- compile output.

local config = require("tuna.config")
local utils = require("tuna.utils")
local checker = require("tuna.checker")
local testcases = require("tuna.testcases")
local tools = require("tuna.tools")
local core = require("tuna.runner.core")

local M = {}

-- Live run-all runners keyed by buffer, so `VimResized` can rebuild their UIs and
-- `show_ui` can re-open them (mirrors stress/interactive `M.active`).
---@type table<integer, table>
M.active = {}

---Expand $(FNOEXT)/… in a command against a concrete file path.
---@param filepath string
---@param command { exec: string, args: string[]? }
---@return { exec: string, args: string[] }?
local function eval_command(filepath, command)
    local exec = utils.eval_string(filepath, command.exec)
    if not exec then
        return nil
    end
    local args = {}
    for i, a in ipairs(command.args or {}) do
        args[i] = utils.eval_string(filepath, a)
        if not args[i] then
            return nil
        end
    end
    return { exec = exec, args = args }
end

---Resolve the shared checker for a problem directory (mirrors `runner.new`).
---@param dir string problem directory
---@param cfg table
---@return "builtin"|table
local function resolve_checker(dir, cfg)
    if cfg.checker == "builtin" then
        local cpath = tools.find(dir, "checker", cfg)
        return cpath and tools.checker_spec(cpath, cfg) or "builtin"
    elseif type(cfg.checker) == "string" then
        local exec = utils.eval_string(dir, cfg.checker)
        return exec and tools.checker_spec(exec, cfg) or "builtin"
    elseif type(cfg.checker) == "table" and cfg.checker.exec then
        local exec = utils.eval_string(dir, cfg.checker.exec)
        return exec and { exec = exec, args = cfg.checker.args } or "builtin"
    end
    return "builtin"
end

--------------------------------------------------------------------------------
-- MultiRunner (a RunnerCore subclass the runner UI drives)
--------------------------------------------------------------------------------

local MultiRunner = core.extend()

---One extra "Run" pane row: how many solution versions are being tested.
---@return string[][]
function MultiRunner:status_tail()
    return { { "solutions", tostring(#self.files) } }
end

---The selector's left column: solution names at column 0, their testcases indented.
---@param tc table
---@return string
function MultiRunner:row_label(tc)
    if tc.kind == "solution" then
        return tc.name
    end
    return "  TC " .. tostring(tc.tcnum)
end

---A per-testcase summary shown when a solution header row is selected.
---@param hrow table
---@return string
function MultiRunner:solution_summary(hrow)
    local sol = hrow.sol
    if not sol then
        return ""
    end
    local lines = {}
    for _, ci in ipairs(sol.case_idxs) do
        local c = self.tcdata[ci]
        local t = (c.time and c.time >= 0) and string.format(" (%.3f s)", c.time / 1000) or ""
        lines[#lines + 1] = string.format("TC %s: %s%s", tostring(c.tcnum), c.status ~= "" and c.status or "pending", t)
    end
    return table.concat(lines, "\n")
end

---Detail-pane content: testcase rows use their run's streams; solution rows show a
---per-testcase summary (Output) and any compile output (Errors).
function MultiRunner:pane_content(tc, name)
    if tc.kind == "solution" then
        if name == "so" then
            return self:solution_summary(tc)
        elseif name == "se" then
            return tc.compile_output or ""
        end
        return ""
    end
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

---Build the matrix rows: for each solution, a header row then one row per testcase.
function MultiRunner:load_rows()
    self.tcdata = {}
    for _, sol in ipairs(self.files) do
        table.insert(self.tcdata, {
            kind = "solution",
            name = sol.name,
            sol = sol,
            status = "",
            hlgroup = "TunaRunning",
            time_label = "", -- header rows never show a time
        })
        sol.header_idx = #self.tcdata
        sol.case_idxs = {}
        for _, n in ipairs(self.nums) do
            table.insert(self.tcdata, {
                kind = "case",
                tcnum = n,
                sol = sol,
                stdin = self.tctbl[n].input or "",
                expected = self.tctbl[n].output,
                status = "",
                hlgroup = "TunaRunning",
            })
            table.insert(sol.case_idxs, #self.tcdata)
        end
    end
end

---Recompute a solution header row's `correct/total` from its testcase rows.
---@param sol table
function MultiRunner:recompute_header(sol)
    local hrow = self.tcdata[sol.header_idx]
    local correct, total = 0, 0
    for _, ci in ipairs(sol.case_idxs) do
        local c = self.tcdata[ci]
        if c.status ~= "" and c.status ~= "RUNNING" then
            total = total + 1
            if c.status == "CORRECT" then
                correct = correct + 1
            end
        end
    end
    hrow.correct, hrow.total = correct, total
    hrow.status = correct .. "/" .. total
    if total > 0 and correct == total then
        hrow.hlgroup = "TunaCorrect"
    elseif total == #sol.case_idxs then
        hrow.hlgroup = "TunaWrong"
    else
        hrow.hlgroup = "TunaRunning"
    end
end

---@param sol table
---@param status string
---@param hl string
function MultiRunner:set_cases(sol, status, hl)
    for _, ci in ipairs(sol.case_idxs) do
        local c = self.tcdata[ci]
        c.status, c.hlgroup = status, hl
    end
end

---Compile one solution (no-op for interpreted languages), reporting via `cb(ok)`.
---A failure becomes a `CE` header row (cases marked `—`) shown in the UI.
---@param sol table
---@param cb fun(ok: boolean)
function MultiRunner:compile_solution(sol, cb)
    if not sol.cc then
        return cb(true)
    end
    local hrow = self.tcdata[sol.header_idx]
    hrow.status, hrow.hlgroup = "compiling", "TunaRunning"
    self:update_ui(true)
    utils.ensure_directory(self.compdir)
    vim.system(vim.list_extend({ sol.cc.exec }, vim.deepcopy(sol.cc.args)), { cwd = self.compdir }, function(res)
        vim.schedule(function()
            hrow.compile_output = (res.stdout or "") .. (res.stderr or "")
            if res.code ~= 0 then
                hrow.status, hrow.hlgroup = "CE", "TunaWarning"
                self:set_cases(sol, "—", "TunaDone")
                self:update_ui(true)
                return cb(false)
            end
            cb(true)
        end)
    end)
end

---Run every solution version: compile them all first (in parallel), then run every
---testcase across all compiled solutions through a shared pool of `multiple_testing`
---concurrent processes. Header `correct/total`s update live as cases land.
function MultiRunner:run_all()
    self.completed = false
    self.stopped = false

    -- Phase 1: compile every solution concurrently. A guard (`pending` starts at 1,
    -- released after the loop) keeps the case phase from starting until every
    -- compile has been *issued* and the synchronous (interpreted) ones have returned.
    local pending = 1
    local function compiled()
        pending = pending - 1
        if pending == 0 then
            self:run_cases_parallel()
        end
    end
    for _, sol in ipairs(self.files) do
        sol.skip = false
        local hrow = self.tcdata[sol.header_idx]
        if not sol.rc then
            hrow.status, hrow.hlgroup = "no run cmd", "TunaWarning"
            self:set_cases(sol, "—", "TunaDone")
            sol.skip = true
        else
            pending = pending + 1
            self:compile_solution(sol, function(ok)
                if ok then
                    self:recompute_header(sol)
                else
                    sol.skip = true
                end
                compiled()
            end)
        end
    end
    self:update_ui(true)
    compiled() -- release the guard
end

---@private
---Run every case of every non-skipped solution through a shared lane pool.
function MultiRunner:run_cases_parallel()
    self.queue = {}
    for _, sol in ipairs(self.files) do
        if not sol.skip then
            for _, ci in ipairs(sol.case_idxs) do
                self.queue[#self.queue + 1] = ci
            end
        end
    end
    self.qpos = 0
    self.running_cases = 0
    if #self.queue == 0 then
        self.completed = true
        self:update_ui(true)
        return
    end

    local parallel = self.config.multiple_testing
    if parallel == -1 then
        parallel = vim.uv.available_parallelism()
    elseif parallel == 0 then
        parallel = #self.queue
    end
    parallel = math.max(1, parallel)
    for _ = 1, parallel do
        self:next_case_lane()
    end
end

---@private
---Start the next queued case in a lane; on finish it recomputes its solution's
---header, pulls the next case, and checks for overall completion.
function MultiRunner:next_case_lane()
    if self.stopped then
        return
    end
    self.qpos = self.qpos + 1
    if self.qpos > #self.queue then
        return
    end
    local idx = self.queue[self.qpos]
    local tc = self.tcdata[idx]
    self:reset_row(tc)
    self.running_cases = self.running_cases + 1
    self:execute_process(idx, tc.sol.rc, self.rundir, { timelimit = self.timeout }, function()
        self.running_cases = self.running_cases - 1
        self:recompute_header(tc.sol)
        self:update_ui(true)
        self:next_case_lane()
        if self.qpos >= #self.queue and self.running_cases == 0 and not self.completed then
            self.completed = true
            self:update_ui(true)
        end
    end)
end

---Stop the batch: kill running case processes and stop pulling new ones.
function MultiRunner:kill_all_processes()
    self.stopped = true
    for _, tc in ipairs(self.tcdata) do
        if tc.running and tc.handle then
            tc.killed = true
            pcall(function()
                tc.handle:kill("sigkill")
            end)
        end
    end
end

---@private
---Recompile a single solution, then run its cases sequentially (used by the UI's
---"run again" on a solution header row).
---@param sol table
function MultiRunner:rerun_solution(sol)
    sol.skip = false
    self:compile_solution(sol, function(ok)
        if not ok then
            return
        end
        local ci = 0
        local function step()
            ci = ci + 1
            if ci > #sol.case_idxs then
                self:recompute_header(sol)
                self:update_ui(true)
                return
            end
            local idx = sol.case_idxs[ci]
            self:reset_row(self.tcdata[idx])
            self:execute_process(idx, sol.rc, self.rundir, { timelimit = self.timeout }, function()
                self:recompute_header(sol)
                self:update_ui(true)
                step()
            end)
        end
        step()
    end)
end

---Re-run one row: a testcase row re-runs just that case (reusing the existing
---binary); a solution header row recompiles and re-runs that whole solution.
---@param idx integer
function MultiRunner:run_single(idx)
    local tc = self.tcdata[idx]
    if not tc then
        return
    end
    if tc.kind == "solution" then
        self:rerun_solution(tc.sol)
        return
    end
    self:reset_row(tc)
    self:execute_process(idx, tc.sol.rc, self.rundir, { timelimit = self.timeout }, function()
        self:recompute_header(tc.sol)
        self:update_ui(true)
    end)
end

---Re-run the whole matrix (the UI's "run all again").
function MultiRunner:run_testcases()
    for _, tc in ipairs(self.tcdata) do
        if tc.kind == "case" then
            self:reset_row(tc)
        end
    end
    self:update_ui(true)
    self:run_all()
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

---Rebuild any open run-all UIs after a `VimResized`.
function M.resize_all()
    for _, mr in pairs(M.active) do
        mr:resize_ui()
    end
end

---Run every sibling solution version against the testcases, in a matrix UI.
---@param bufnr integer? defaults to the current buffer
function M.run(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)

    local curpath = vim.fs.normalize(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p"))
    local dir = vim.fn.fnamemodify(curpath, ":h")

    -- A candidate's filetype: the current buffer's own is authoritative for it
    -- (respects a manual `:set ft`), others are matched from the filename.
    local function candidate_filetype(f)
        if vim.fs.normalize(vim.fn.fnamemodify(f, ":p")) == curpath then
            local ft = vim.bo[bufnr].filetype
            if ft and ft ~= "" then
                return ft
            end
        end
        return vim.filetype.match({ filename = f }) or ""
    end

    -- Discover every runnable sibling *source* file, of any language — so run_all
    -- can compare, say, a C++ and a Python attempt side by side. A file qualifies
    -- when its filetype has a run_command and it isn't a helper (checker/gen/…).
    local paths = {}
    for _, f in ipairs(vim.fn.globpath(dir, "*", false, true)) do
        if vim.fn.isdirectory(f) == 0 and not tools.is_helper(f, cfg) then
            local ft = candidate_filetype(f)
            if ft ~= "" and cfg.run_command[ft] then
                paths[#paths + 1] = { path = f, ft = ft }
            end
        end
    end
    table.sort(paths, function(a, b)
        return a.path < b.path
    end)
    if #paths == 0 then
        utils.notify("run_all: no runnable solution files found beside this one.")
        return
    end

    -- Flush buffers before running: run_all runs *every* sibling version.
    tools.save_sources(bufnr, cfg)
    if cfg.save_current_file or cfg.save_all_files then
        for _, p in ipairs(paths) do
            tools.flush_buffer(p.path)
        end
    end

    local tctbl = testcases.buf_get_testcases(bufnr)
    local nums = vim.tbl_keys(tctbl)
    table.sort(nums)
    if #nums == 0 then
        utils.notify("run_all: no testcases to run.")
        return
    end

    -- Resolve each solution's run/compile commands from *its own* filetype, and the
    -- shared checker. So a C++ and a Python attempt each compile/run correctly.
    local files = {}
    for i, p in ipairs(paths) do
        local f, ft = p.path, p.ft
        files[i] = {
            si = i,
            name = vim.fn.fnamemodify(f, ":t"),
            path = f,
            rc = cfg.run_command[ft] and eval_command(f, cfg.run_command[ft]) or nil,
            cc = cfg.compile_command[ft] and eval_command(f, cfg.compile_command[ft]) or nil,
        }
    end

    local timeout = (cfg.maximum_time and cfg.maximum_time > 0) and cfg.maximum_time or nil

    if M.active[bufnr] then
        M.active[bufnr]:delete_ui()
    end

    local mr = setmetatable({
        config = cfg,
        bufnr = bufnr,
        checker = resolve_checker(dir, cfg),
        mode = "all",
        files = files,
        nums = nums,
        tctbl = tctbl,
        dir = dir,
        rundir = vim.fs.normalize(dir .. "/" .. cfg.running_directory) .. "/",
        compdir = vim.fs.normalize(dir .. "/" .. cfg.compile_directory) .. "/",
        timeout = timeout,
        tcdata = {},
        completed = false,
    }, MultiRunner)
    M.active[bufnr] = mr
    utils.ensure_directory(mr.rundir)

    vim.api.nvim_create_autocmd("BufUnload", {
        buffer = bufnr,
        once = true,
        callback = function()
            M.active[bufnr] = nil
        end,
    })

    mr:show_ui()
    mr:load_rows()
    mr:update_ui(true)
    mr:run_all()
end

return M
