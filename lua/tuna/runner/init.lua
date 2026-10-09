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
-- build, the spawn-and-judge routine (`execute_process`), kill helpers — lives in
-- `RunnerCore` (`runner/core.lua`); `TCRunner` is a thin subclass that only adds the
-- parallel lanes and the completion check.
--
-- The build is row 1 (`tcnum = "Compile"`): it runs first, and the real testcases only
-- start if it succeeds.

local config = require("tuna.config")
local utils = require("tuna.utils")
local tools = require("tuna.tools")
local core = require("tuna.runner.core")

local M = {}

---@class tuna.TCRunner : tuna.RunnerCore
---@field cc { exec: string, args: string[] }? compile command (nil for interpreted languages)
---@field rc { exec: string, args: string[] } run command
---@field compile_directory string
---@field running_directory string
---@field compile boolean whether runs have a build step (a compiled language)
---@field next_tc integer index of the next unstarted testcase
local TCRunner = core.extend()
M.TCRunner = TCRunner

---Create a runner for `bufnr`, resolving its compile/run commands and checker.
---@param bufnr integer? defaults to the current buffer
---@return tuna.TCRunner? # the runner, or `nil` if the commands are missing/malformed
function M.new(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local filetype = vim.bo[bufnr].filetype or ""
    local path = vim.api.nvim_buf_get_name(bufnr)
    local filedir = vim.fn.fnamemodify(path, ":p:h")
    local cfg = config.get_buffer_config(bufnr)

    local compile_command
    if cfg.compile_command[filetype] then
        compile_command = utils.eval_command(path, cfg.compile_command[filetype])
        if not compile_command then
            utils.notify("compile command for '" .. filetype .. "' is malformed, cannot run.")
            return nil
        end
    end
    if not cfg.run_command[filetype] then
        utils.notify("no run command configured for filetype '" .. filetype .. "', cannot run.")
        return nil
    end
    local run_command = utils.eval_command(path, cfg.run_command[filetype])
    if not run_command then
        utils.notify("run command for '" .. filetype .. "' is malformed, cannot run.")
        return nil
    end

    -- Every run looks the judge up again (`refresh_judge`); this first answer is what
    -- the results UI shows before one.
    local resolved_checker = tools.resolve_checker(path, cfg)

    return setmetatable({
        config = cfg,
        bufnr = bufnr,
        cc = compile_command,
        rc = run_command,
        checker = resolved_checker,
        compare_method = tools.get_compare(path), -- per-buffer `:Tuna compare` override (nil = use config)
        -- Resolved against the source's directory only when relative, so an absolute
        -- `/tmp/build` and a `~/build` mean what they say.
        compile_directory = utils.normalize_path(cfg.compile_directory, filedir) .. "/",
        running_directory = utils.normalize_path(cfg.running_directory, filedir) .. "/",
        tcdata = {},
        tc_size = 0,
        compile = compile_command ~= nil,
        next_tc = 1,
        completed = false,
        mode = "normal", -- run mode shown in the UI (set by commands)
    }, TCRunner) --[[@as tuna.TCRunner]]
end

---Build the `tcdata` rows for a set of testcases: the compile pseudo-testcase first
---when compiling, then one row per testcase in ascending order. Split out of
---`run_testcases` because the rows are also what the UI needs to *show* testcases that
---have not been run yet (see `load_testcases`).
---@param tctbl table<integer, tuna.StoredTestcase>
function TCRunner:build_rows(tctbl)
    self.compile = self.cc ~= nil

    self.tcdata = {}
    if self.compile then -- compilation is testcase #1
        table.insert(self.tcdata, core.compile_row())
    end
    -- Insert testcases in ascending tcnum order for a stable display.
    local nums = vim.tbl_keys(tctbl)
    table.sort(nums)
    local timelimit = core.time_limit(self.config)
    for _, tcnum in ipairs(nums) do
        local tc = tctbl[tcnum]
        table.insert(self.tcdata, {
            tcnum = tcnum,
            stdin = tc.input or "",
            expected = tc.output,
            timelimit = timelimit,
        })
    end
    -- Nothing to test, but the program is still worth running: hitting run on a file
    -- with no testcases means "execute this", which is how a scratch solution gets
    -- built and run without first inventing a dummy empty testcase. So it runs once on
    -- empty stdin, with no expected output — it reads DONE and can never claim a pass
    -- on a problem whose testcases simply failed to arrive. It is also what makes the
    -- two languages agree: without it a compiled file built and showed a lone `Compile`
    -- row while an interpreted one only warned, and neither ran anything.
    --
    -- It is testcase 0 (nothing is on disk, so that number is free) and editable like
    -- any other row, which is what turns "just run it" into the start of a testcase:
    -- read the output, type the input and the answer you wanted into the panes, `:w`,
    -- and the row is a stored testcase from then on. `bare` only says it has no file
    -- behind it *yet* — the selector labels it `No input` rather than `TC 0` until it
    -- does, and `save_testcase` clears the flag.
    if next(tctbl) == nil then
        table.insert(self.tcdata, { tcnum = 0, bare = true, stdin = "", expected = nil, timelimit = timelimit })
    end
    self.tc_size = #self.tcdata
end

---Fill the UI with testcases without running anything, so `:Tuna show_ui` before any
---`:Tuna run` shows what there is to run — each testcase's input and expected output,
---reviewable in the detail panes — instead of an empty results window. The rows are
---built exactly as a run would build them (compile row included), so `R` on a row and
---`<C-r>` for all of them work straight from this view.
---@param tctbl table<integer, tuna.StoredTestcase>
function TCRunner:load_testcases(tctbl)
    self:build_rows(tctbl)
    for _, tc in ipairs(self.tcdata) do
        self:reset_row(tc)
        tc.status = "NOT RUN"
        -- `TunaDone` is the unstyled group: "not run" is the absence of a verdict, not
        -- a bad one, so it must not read like a warning.
        tc.hlgroup = "TunaDone"
    end
    -- Nothing is in flight, so the runner counts as idle: a re-run starts from a clean
    -- state and `check_complete` has nothing to wait for.
    self.next_tc = self.tc_size + 1
    self.completed = true
    -- Marks these rows as "listed, never run", so re-opening the UI picks up testcases
    -- added or edited since — results, by contrast, are kept as they are. Nothing is built
    -- yet, so a single row's run key builds first (`built_first`).
    self.preloaded = true
    self:defer_build(function(cont)
        self:build_solution(cont)
    end)
    self:update_ui(true)
end

---Run testcases. Pass a `tctbl` for a fresh run, or `nil` to re-run the testcases
---loaded by the previous call (keeping their inputs/expected outputs).
---@param tctbl table<integer, tuna.StoredTestcase>? testcases, or nil to re-run
function TCRunner:run_testcases(tctbl)
    -- A fresh run saves its source; a re-run keeps the rows it has, and the file on disk,
    -- unless the rows were only listed and nothing has saved it yet.
    if tctbl then
        tools.save_sources(self.bufnr, self.config)
    end
    self:claim_listed()
    self.stopped = false
    self:refresh_judge(vim.api.nvim_buf_get_name(self.bufnr))
    -- What this run compiles besides the solution: a checker, when it is a program of its
    -- own. Declared before anything is spawned, so the build step is laid out once.
    self:plan_builds({ self.checker })
    self:build_judge()
    if tctbl then
        self:build_rows(tctbl)
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

    self.next_tc = self.compile and 2 or 1
    self:build_solution(function()
        for _ = 1, core.parallelism(self.config, self.tc_size) do
            self:run_next_testcase()
        end
        self:check_complete() -- a run stopped while it built starts nothing, and is over
    end)
end

---Nothing will run after a failed build, so the lanes are done and the run completes.
function TCRunner:on_build_failed()
    self.next_tc = self.tc_size + 1
    self:check_complete()
end

---@private
---Run the next unstarted testcase, if any; each, on finishing, pulls the next one, so
---starting it `parallel` times keeps that many lanes busy. A stopped run starts nothing.
function TCRunner:run_next_testcase()
    if self.stopped then
        self.next_tc = self.tc_size + 1
    end
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
    core.save_buffer_verdict(self.bufnr, self.tcdata)
    self:update_ui(true)
end

---Re-run a single row (the UI's "run again"). The Compile row is the build, so running it
---builds. A testcase row of a runner that was only listed builds first (`built_first`),
---since nothing it would spawn exists yet, and is reset only once the build succeeded: a
---build that fails leaves it saying `NOT RUN`, which is the truth.
---@param tcindex integer
function TCRunner:run_single(tcindex)
    local tc = self.tcdata[tcindex]
    if not tc then
        return
    end
    -- A single re-run is a run: while it is in flight the runner must not read as
    -- idle, or the structural edits (`n`/`x`/`c`/`u`) that wait on `idle()` would be
    -- let through mid-flight. `check_complete` flips it back once the row settles.
    self.completed = false
    self.stopped = false
    local function settle()
        self:check_complete()
    end
    if tc.compile then
        if not self:built_first(settle) then
            self:build_solution(settle)
        end
        return
    end
    if self:built_first(function()
        self:run_single(tcindex)
    end) then
        return
    end
    self:refresh_judge(vim.api.nvim_buf_get_name(self.bufnr))
    self:reset_row(tc)
    self:execute_process(tcindex, self.rc, self.running_directory, {}, settle)
end

return M
