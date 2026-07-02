-- lua/tuna/stress.lua
--
-- Stress testing: hunt for inputs on which the current solution disagrees with a
-- trusted reference (brute force). A generator produces a random input (seeded by
-- the iteration number, so failures are reproducible); the solution and the
-- reference both run on it; their outputs are judged with the same `checker` the
-- runner uses (so checker-based problems with multiple correct answers work too).
-- Every counterexample — a wrong answer, a crash, or a timeout — is appended as a
-- new testcase (so it doubles as a regression test) and shown in a dedicated
-- results UI. The search also re-runs any testcases that already exist.
--
-- The search stops as soon as one of two thresholds is hit: `saves_per_run`
-- counterexamples saved this run, or `max_saved` total testcases on disk. Both,
-- plus the live iteration count, are surfaced in the UI's status line.
--
-- Reuse: `runner.new()` resolves the solution's compile/run commands, working
-- directories, and checker; `checker.judge()` decides each verdict; the results
-- UI is the same `runner_ui` the normal runner uses — a `StressRunner` exposes
-- just enough of the `TCRunner` surface (`tcdata`, `mode`, `judge_label`,
-- `kill_*`, `run_single`, `run_testcases`) to drive it.

local config = require("tuna.config")
local utils = require("tuna.utils")
local runner = require("tuna.runner")
local checker = require("tuna.checker")
local testcases = require("tuna.testcases")
local tools = require("tuna.tools")
local core = require("tuna.runner.core")

local M = {}

-- Live stress runners keyed by buffer, so `VimResized` can rebuild their UIs and
-- a fresh `:Tuna run stress` can tear the previous one down.
---@type table<integer, table>
M.active = {}

--------------------------------------------------------------------------------
-- StressRunner: a TCRunner-shaped object the runner UI can drive.
--------------------------------------------------------------------------------

-- StressRunner subclasses RunnerCore: it inherits the UI plumbing
-- (update_ui/show_ui/resize_ui/delete_ui), judge_label, and execute_process, and
-- adds only the generation search + its counters. It sets `self.checker` to the
-- solution runner's checker so the inherited `judge_label`/`execute_process` decide
-- verdicts exactly as a normal run would.
local StressRunner = core.extend()

---Extra "Run" pane rows below mode/judge: the live stress counters, as
---{ label, value } pairs (the UI aligns the colons), one per line.
---@return string[][]
function StressRunner:status_tail()
    return {
        { "iter", ("%d / %d"):format(self.iter, self.count) },
        { "saved", ("%d / %d"):format(self.saved_this_run, self.saves_per_run) },
        { "max", ("%d testcases"):format(self.max_saved) },
    }
end

---@return boolean # whether the search should no longer progress
function StressRunner:aborted()
    return self.stopped or self.finished
end

---Load the existing testcases into `tcdata` (pending), resetting the counters
---that decide where new counterexamples are numbered.
function StressRunner:load_testcases()
    local tctbl = testcases.buf_get_testcases(self.bufnr)
    local nums = vim.tbl_keys(tctbl)
    table.sort(nums)
    self.tcdata = {}
    -- The solution's compile step is the first row (its warnings/errors are then
    -- viewable in the detail panes, like competitest's compile-as-testcase).
    if self.compile_entry then
        table.insert(self.tcdata, self.compile_entry)
    end
    local maxnum = -1
    for _, num in ipairs(nums) do
        table.insert(self.tcdata, {
            tcnum = num,
            stdin = tctbl[num].input or "",
            expected = tctbl[num].output,
            status = "",
            hlgroup = "TunaRunning",
        })
        if num > maxnum then
            maxnum = num
        end
    end
    self.next_num = maxnum + 1 -- next free testcase number for a counterexample
end

---Run the solution on a single `tcdata` entry and judge it against that entry's
---expected output (used for pre-existing testcases and for the UI's "run again").
---Delegates to the inherited `execute_process` (which spawns, times, judges via
---`self.checker`, and updates the UI); a just-saved row's "saved" label is dropped
---so a real runtime shows on re-run.
---@param idx integer
---@param cb fun()?
function StressRunner:execute_entry(idx, cb)
    local tc = self.tcdata[idx]
    if not tc then
        if cb then
            cb()
        end
        return
    end
    self:reset_row(tc)
    self:execute_process(idx, self.r.rc, self.rundir, { timelimit = self.timeout }, cb)
end

---Save a counterexample as a new testcase and add it to the UI.
---@param seed integer generator seed that produced it
---@param input string
---@param expected string reference (correct) output, stored as expected output
---@param sol_out string the solution's (wrong) output
---@param sol_err string the solution's stderr
---@param status string short verdict label ("WRONG" / "RE" / "TLE" / …)
function StressRunner:record_counterexample(seed, input, expected, sol_out, sol_err, status)
    -- Don't save a counterexample whose input we already have (as a pre-existing
    -- testcase or one saved earlier this run); just keep searching.
    local norm = vim.trim(input)
    for _, tc in ipairs(self.tcdata) do
        if tc.tcnum ~= "Compile" and tc.stdin and vim.trim(tc.stdin) == norm then
            self:generation(seed + 1)
            return
        end
    end

    local n = self.next_num
    self.next_num = n + 1
    testcases.buf_save_testcase(self.bufnr, n, input, expected or "")
    self.saved_this_run = self.saved_this_run + 1
    table.insert(self.tcdata, {
        tcnum = n,
        stdin = input,
        expected = expected,
        stdout = sol_out,
        stderr = sol_err,
        status = status,
        hlgroup = "TunaWrong",
        -- A freshly-saved counterexample has no runtime to show; the UI displays
        -- this in the time column instead (re-running it fills in a real time).
        time_label = "saved",
    })
    self:update_ui(true)
    -- Keep searching; the thresholds are re-checked at the top of `generation`.
    self:generation(seed + 1)
end

---A generator/reference process failed at *runtime* (nonzero exit). Show its output
---in the UI (like a compile failure) rather than dumping a traceback into a
---notification, and stop the search quietly.
---@param label string "generator" | "reference"
---@param seed integer
---@param output string? the failing process's stderr/stdout
function StressRunner:helper_failed(label, seed, output)
    if self.ui then
        self.ui:show_message((" stress: %s failed (seed %d) "):format(label, seed), output or "")
        self:finish()
    else
        self:finish(("%s failed (seed %d)"):format(label, seed))
    end
end

---Finish the search (idempotent), refreshing the status line and notifying why.
---@param msg string? reason to report
function StressRunner:finish(msg)
    if self.finished then
        return
    end
    self.finished = true
    self:update_ui(true)
    if msg then
        utils.notify("stress: " .. msg .. ".", "INFO")
    end
end

---One generation iteration: generator → solution → reference → judge.
---@param i integer iteration / seed
function StressRunner:generation(i)
    if self:aborted() then
        return
    end
    if self.saved_this_run >= self.saves_per_run then
        -- Save limit hit (only actually-saved, deduplicated counterexamples count):
        -- stop the search. No message → finishes silently, per your notify change.
        self:finish()
        return
    end
    if #self.tcdata >= self.max_saved then
        self:finish("reached the max of " .. self.max_saved .. " testcases")
        return
    end
    if i > self.count then
        self:finish(string.format("no counterexample found in %d runs", self.count))
        return
    end
    self.iter = i
    self:update_ui(false)

    local gen_argv = vim.list_extend({ self.gen.exec }, vim.deepcopy(self.gen.args))
    if self.seed_arg then
        table.insert(gen_argv, tostring(i))
    end
    vim.system(gen_argv, { cwd = self.rundir, timeout = self.timeout }, function(gres)
        vim.schedule(function()
            if self:aborted() then
                return
            end
            if gres.code ~= 0 then
                self:helper_failed("generator", i, gres.stderr)
                return
            end
            local input = gres.stdout or ""

            -- Solution on the generated input.
            vim.system(
                vim.list_extend({ self.r.rc.exec }, vim.deepcopy(self.r.rc.args)),
                { cwd = self.rundir, stdin = input, timeout = self.timeout },
                function(sres)
                    vim.schedule(function()
                        if self:aborted() then
                            return
                        end
                        -- Reference on the same input (for the expected output).
                        vim.system(
                            vim.list_extend({ self.ref.exec }, vim.deepcopy(self.ref.args)),
                            { cwd = self.rundir, stdin = input, timeout = self.timeout },
                            function(rres)
                                vim.schedule(function()
                                    if self:aborted() then
                                        return
                                    end
                                    if rres.code ~= 0 then
                                        self:helper_failed("reference", i, rres.stderr)
                                        return
                                    end
                                    local expected = rres.stdout or ""

                                    -- A crash/timeout is itself a counterexample.
                                    if sres.signal and sres.signal ~= 0 then
                                        self:record_counterexample(
                                            i,
                                            input,
                                            expected,
                                            sres.stdout or "",
                                            sres.stderr or "",
                                            "RE/TLE"
                                        )
                                        return
                                    elseif sres.code ~= 0 then
                                        self:record_counterexample(
                                            i,
                                            input,
                                            expected,
                                            sres.stdout or "",
                                            sres.stderr or "",
                                            "RET " .. tostring(sres.code)
                                        )
                                        return
                                    end

                                    -- Judge the solution's output against the reference.
                                    local tc = { stdin = input, stdout = sres.stdout or "", expected = expected }
                                    checker.judge(
                                        tc,
                                        self.r.checker,
                                        self.config.output_compare_method,
                                        function(correct)
                                            if self:aborted() then
                                                return
                                            end
                                            if correct == false then
                                                self:record_counterexample(
                                                    i,
                                                    input,
                                                    expected,
                                                    sres.stdout or "",
                                                    "",
                                                    "WRONG"
                                                )
                                            else
                                                self:generation(i + 1)
                                            end
                                        end
                                    )
                                end)
                            end
                        )
                    end)
                end
            )
        end)
    end)
end

---Run the pre-existing testcases (in order) through the solution, then call `cb`.
---This needs only the solution compiled, so it can run while the generator and
---reference are still building.
---@param cb fun()?
function StressRunner:run_existing(cb)
    -- The real testcase rows (everything except the Compile row).
    local idxs = {}
    for i, tc in ipairs(self.tcdata) do
        if tc.tcnum ~= "Compile" then
            idxs[#idxs + 1] = i
        end
    end
    local function step(k)
        if self:aborted() then
            return
        end
        if k > #idxs then
            if cb then
                cb()
            end
            return
        end
        self:execute_entry(idxs[k], function()
            step(k + 1)
        end)
    end
    step(1)
end

--- UI-driven controls (the runner UI calls these on the "runner"). ---

---Stop the search: kill any in-flight testcase process and halt the generation
---loop (`aborted()` gates every step). The generator/reference/solution processes
---spawned inside `generation` aren't tracked individually; they finish and are
---ignored because every continuation checks `aborted()` first.
function StressRunner:kill_all_processes()
    if self.stopped then
        return
    end
    self.stopped = true
    for _, tc in ipairs(self.tcdata) do
        if tc.running and tc.handle then
            tc.killed = true
            pcall(function()
                tc.handle:kill("sigkill")
            end)
        end
    end
    self:finish("stopped")
end

---A single kill stops the whole search (there's only one lane).
function StressRunner:kill_process()
    self:kill_all_processes()
end

---Re-run the solution on one displayed testcase and re-judge it.
---@param idx integer
function StressRunner:run_single(idx)
    self:execute_entry(idx)
end

---Restart the whole search from scratch (the UI's "run all again"). The helpers
---are already compiled (cached), so re-run the existing testcases, then generate.
function StressRunner:run_testcases()
    self.stopped = false
    self.finished = false
    self.iter = 0
    self.saved_this_run = 0
    self:load_testcases()
    self:update_ui(true)
    self:run_existing(function()
        if not self:aborted() then
            self:generation(1)
        end
    end)
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

---Resolve a stress command spec (a string, or a `{ exec, args }` table) into an
---argv table, expanding `$(FNOEXT)` etc. against the buffer.
---@param bufnr integer
---@param spec string|{ exec: string, args: string[]? }
---@return { exec: string, args: string[] }?
local function resolve_cmd(bufnr, spec)
    if type(spec) == "string" then
        local exec = utils.buf_eval_string(bufnr, spec)
        return exec and { exec = exec, args = {} } or nil
    elseif type(spec) == "table" and spec.exec then
        local exec = utils.buf_eval_string(bufnr, spec.exec)
        if not exec then
            return nil
        end
        local args = {}
        for i, a in ipairs(spec.args or {}) do
            args[i] = utils.buf_eval_string(bufnr, a)
            if not args[i] then
                return nil
            end
        end
        return { exec = exec, args = args }
    end
    return nil
end

---Rebuild any open stress UIs after a `VimResized`.
function M.resize_all()
    for _, sr in pairs(M.active) do
        sr:resize_ui()
    end
end

---Run stress testing for a buffer's solution.
---@param bufnr integer? defaults to the current buffer
---@param count_override integer? overrides `stress.count`
function M.run(bufnr, count_override)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)

    -- Reuse the runner to resolve the solution's compile/run commands, dirs, checker.
    local r = runner.new(bufnr)
    if not r then
        return -- runner.new already notified
    end
    local cfg = r.config
    local scfg = cfg.stress or {}
    local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
    tools.save_sources(bufnr, cfg) -- save the solution (helpers are saved in tools.prepare)

    -- Resolve a helper (generator/reference): an explicit config spec wins,
    -- otherwise discover a sibling source file (gen.* / brute.*) and compile it.
    local function resolve_helper(role, override, label)
        if override then
            local spec = resolve_cmd(bufnr, override)
            if not spec then
                utils.notify("stress: 'stress." .. label .. "' command is malformed.")
            end
            return spec
        end
        local path = tools.find(dir, role, cfg)
        if not path then
            utils.notify(
                "stress: no "
                    .. label
                    .. " found, create a sibling '"
                    .. tools.DEFAULT_NAMES[role][1]
                    .. ".*' "
                    .. "file, or set 'stress."
                    .. label
                    .. "'."
            )
            return nil
        end
        local spec, err = tools.program(path, cfg)
        if not spec then
            utils.notify("stress: " .. label .. " " .. err .. ".")
        end
        return spec
    end

    local gen = resolve_helper("generator", scfg.generator, "generator")
    if not gen then
        return
    end
    local ref = resolve_helper("reference", scfg.reference, "reference")
    if not ref then
        return
    end

    local timeout = (cfg.maximum_time and cfg.maximum_time > 0) and cfg.maximum_time or nil
    local rundir = r.running_directory
    utils.ensure_directory(rundir)

    -- Tear down a previous stress UI for this buffer before starting a fresh run.
    if M.active[bufnr] then
        M.active[bufnr]:delete_ui()
    end

    local sr = setmetatable({
        config = cfg,
        bufnr = bufnr,
        r = r,
        -- The inherited execute_process/judge_label judge with self.checker; reuse
        -- the solution runner's resolved checker so verdicts match a normal run.
        checker = r.checker,
        gen = gen,
        ref = ref,
        dir = dir,
        rundir = rundir,
        timeout = timeout,
        seed_arg = scfg.seed_arg ~= false,
        count = count_override or scfg.count or 100,
        saves_per_run = math.max(1, scfg.saves_per_run or 1),
        max_saved = scfg.max_saved or 10,
        mode = "stress",
        -- The solution's compile step is shown as the first testcase row (so its
        -- warnings are viewable), like the normal runner. nil for interpreted
        -- solutions. gen/ref compile separately (errors shown in a float).
        compile_entry = r.compile
                and { tcnum = "Compile", stdin = "", expected = nil, status = "", hlgroup = "TunaRunning" }
            or nil,
        tcdata = {},
        next_num = 0,
        iter = 0,
        saved_this_run = 0,
        stopped = false,
        finished = false,
    }, StressRunner)
    M.active[bufnr] = sr

    vim.api.nvim_create_autocmd("BufUnload", {
        buffer = bufnr,
        once = true,
        callback = function()
            M.active[bufnr] = nil
        end,
    })

    -- Open the results UI and show the testcase list (incl. the Compile row and any
    -- existing testcases, pending) right away, like competitest.
    sr:show_ui()
    sr:load_testcases()
    sr:update_ui(true)

    -- A gen/ref compile failure is a normal outcome, not an editor error: show the
    -- compiler output in a UI float (no error notify).
    local function helper_compile_failed(label, err)
        if sr.ui then
            sr.ui:show_message(" stress: " .. label .. " failed to compile ", err or "")
        end
    end

    -- Compile the generator and reference; `cb()` once both are ready.
    local function prepare_helpers(cb)
        tools.prepare(gen, function(gok, gerr)
            if not gok then
                helper_compile_failed("generator", gerr)
                return
            end
            tools.prepare(ref, function(rok, rerr)
                if not rok then
                    helper_compile_failed("reference", rerr)
                    return
                end
                cb()
            end)
        end)
    end

    -- With the solution built, run the existing testcases *immediately* while the
    -- generator/reference compile in parallel; generation waits for both the
    -- helpers to be ready and the existing run to finish.
    local function start()
        local existing_done, helpers_ready = false, false
        local function maybe_generate()
            if existing_done and helpers_ready and not sr:aborted() then
                sr:generation(1)
            end
        end

        sr:run_existing(function()
            existing_done = true
            maybe_generate()
        end)

        prepare_helpers(function()
            helpers_ready = true
            maybe_generate()
        end)
    end

    -- Compile the solution once (if it needs compiling), driving the Compile row.
    if r.compile then
        local ce = sr.compile_entry
        ce.status, ce.hlgroup, ce.start_time = "RUNNING", "TunaRunning", vim.uv.now()
        sr:update_ui(true)
        utils.ensure_directory(r.compile_directory)
        vim.system(vim.list_extend({ r.cc.exec }, vim.deepcopy(r.cc.args)), { cwd = r.compile_directory }, function(res)
            vim.schedule(function()
                ce.time = vim.uv.now() - ce.start_time
                ce.stdout, ce.stderr, ce.exit_code = res.stdout or "", res.stderr or "", res.code
                if res.code ~= 0 then
                    -- Failure stays in the UI (compile row + auto-viewer), no notify.
                    ce.status, ce.hlgroup = "RET " .. tostring(res.code), "TunaWarning"
                    sr:update_ui(true)
                    return
                end
                -- Success (warnings, if any, are viewable by selecting this row).
                ce.status, ce.hlgroup = "DONE", "TunaDone"
                sr:update_ui(true)
                start()
            end)
        end)
    else
        start()
    end
end

return M
