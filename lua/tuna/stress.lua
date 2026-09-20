-- lua/tuna/stress.lua
--
-- Stress testing: hunt for inputs on which the current solution disagrees with a
-- trusted bruteforce. A generator produces a random input (seeded by
-- the iteration number, so failures are reproducible); the solution and the
-- bruteforce both run on it; their outputs are judged with the same `checker` the
-- runner uses (so checker-based problems with multiple correct answers work too).
-- Every counterexample — a wrong answer, a crash, or a timeout — is appended as a
-- new testcase (so it doubles as a regression test) and shown in a dedicated
-- results UI. The search also re-runs any testcases that already exist, beside it, and while
-- it hunts it shows a row of its own, numbered as the counterexample it is looking
-- for would be.
--
-- A verdict is only as good as the bruteforce's answer, so a generator or bruteforce that
-- fails stops the search instead of feeding it: their output is what every comparison is made
-- of, and the failure is reported on the search's own row, the way a testcase reports its
-- own. The bruteforce runs on a budget of its own (`stress.bruteforce_time`), because it is
-- slow by design and `maximum_time` is the limit the *solution* is being held to.
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

-- The `tcnum` of the row standing for the search in progress. Not a number, so it is
-- neither editable nor compared against disk: it holds the input being tried right
-- now, which nothing on disk answers for.
local SEARCH = "Stress"

-- Shown instead of a (silent) timed-out bruteforce's stderr: the budget is the one thing to
-- change about it.
local BRUTEFORCE_TIME_HINT = "stress.bruteforce_time sets how long it may take on one generated input,\n"
    .. "in milliseconds, false removes the limit."

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

---The generator and bruteforce of a solution, or nil and what to tell the user about the
---ones that are missing.
---@param solution string
---@param cfg table
---@return table? gen, table? ref, string? missing
local function stress_helpers(solution, cfg)
    local gen, gen_note = tools.helper("generator", solution, cfg)
    local ref, ref_note = tools.helper("bruteforce", solution, cfg)
    if gen and ref then
        return gen, ref
    end
    local names = cfg.tool_names or tools.DEFAULT_NAMES
    local missing = {}
    if not gen then
        missing[#missing + 1] = gen_note
            or ("no generator (a " .. names.generator[1] .. ".* file or stress.generator)")
    end
    if not ref then
        missing[#missing + 1] = ref_note
            or ("no bruteforce (a " .. names.bruteforce[1] .. ".* file or stress.bruteforce)")
    end
    return nil, nil, "stress needs a generator and a bruteforce, " .. table.concat(missing, " and ")
end

---Why a helper process failed, in words and as a verdict, or nil when it succeeded. A
---crash exits with code 0 and reports the signal that killed it, so reading the code alone
---(a sanitizer abort, a segfault) passes an empty output off as an answer. `vim.system`
---marks its own timeout kill with code 124 and SIGTERM. The verdict is the one a testcase
---would wear for the same ending, since it is read in the same column.
---@param res table `vim.system` result
---@param timeout integer? the budget it was given, in milliseconds
---@return string? reason, string? status, boolean? timed_out
local function failure_reason(res, timeout)
    if res.code == 124 and res.signal == 15 then
        return ("timed out after %.1f s"):format((timeout or 0) / 1000), "TIMEOUT", true
    end
    if res.signal and res.signal ~= 0 then
        return ("was killed by signal %d"):format(res.signal), "SIG " .. res.signal
    end
    if res.code ~= 0 then
        return ("exited with code %d"):format(res.code), "RET " .. res.code
    end
end

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

---Rows name themselves as they do everywhere else, except the search row, which
---wears the number the counterexample it is hunting for would take.
---@param tc table
---@return string
function StressRunner:row_label(tc)
    if tc.tcnum == SEARCH then
        return "TC " .. self.next_num
    end
    return type(tc.tcnum) == "number" and ("TC " .. tc.tcnum) or tostring(tc.tcnum)
end

---How many rows stand for a testcase on disk: neither the Compile row nor the search
---row is one, and counting either would trip `max_saved` early.
---@return integer
function StressRunner:testcase_count()
    local n = 0
    for _, tc in ipairs(self.tcdata) do
        if type(tc.tcnum) == "number" then
            n = n + 1
        end
    end
    return n
end

---The row standing for the search, listed with the testcases from the moment they are and
---removed when the search stops. It shows the input being tried and the two outputs it is
---compared with, so there is something to watch before a counterexample exists, and it is
---there from the start rather than appearing at the end: what a stress run spends its time
---doing is the hunt, not the testcases it re-runs on the way in.
---@return table
function StressRunner:search_row()
    if not self.search_entry then
        self.search_entry = { tcnum = SEARCH, stdin = "", expected = nil, status = "STRESS", hlgroup = "TunaRunning" }
        table.insert(self.tcdata, self.search_entry)
        self:update_ui(true)
    end
    return self.search_entry
end

---Drop the search row: the search has stopped, so nothing is being tried. A row that ended
---up carrying a verdict stays, the way a testcase that failed stays on the board — it is the
---answer to what happened, and the input it holds is what there is to look at.
function StressRunner:drop_search_row()
    if not self.search_entry or self.search_entry.status ~= "STRESS" then
        self.search_entry = nil
        return
    end
    for i, tc in ipairs(self.tcdata) do
        if tc == self.search_entry then
            table.remove(self.tcdata, i)
            break
        end
    end
    self.search_entry = nil
end

---A build that failed searches for nothing, and a search that never finishes is never idle,
---so the rows could not be edited either.
function StressRunner:on_build_failed()
    self:finish()
end

---@return boolean # whether the search should no longer progress
function StressRunner:aborted()
    return self.stopped or self.finished
end

---A stress run has no `completed` flag — it ends when the search is stopped or a
---threshold is hit — so "idle enough to add or delete a testcase" is that, not the
---base class's per-run flag. A live search appends counterexamples as rows, which is
---exactly what must not happen underneath a structural edit. The testcases already on disk
---re-run in a lane of their own, so they count too: the search can stop first.
---@return boolean
function StressRunner:idle()
    return self.preloaded or (self:aborted() and not self.rerunning)
end

---`NOT RUN` is a testcase's word for "no verdict yet"; the search row has no verdict to
---have, so it goes on saying what it is for whether or not anything has run.
function StressRunner:mark_not_run()
    core.RunnerCore.mark_not_run(self)
    if self.search_entry then
        self.search_entry.status, self.search_entry.hlgroup = "STRESS", "TunaRunning"
    end
end

---Load the existing testcases into `tcdata` (pending), resetting the counters
---that decide where new counterexamples are numbered.
function StressRunner:load_testcases()
    local tctbl = testcases.buf_get_testcases(self.bufnr)
    local nums = vim.tbl_keys(tctbl)
    table.sort(nums)
    self.tcdata = {}
    self.search_entry = nil
    -- The solution's compile step is the first row, so its warnings/errors are
    -- viewable in the detail panes.
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
    self:search_row()
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
---@param expected string the bruteforce's (correct) output, stored as expected output
---@param sol_out string the solution's (wrong) output
---@param sol_err string the solution's stderr
---@param status string short verdict label ("WRONG" / "RE" / "TLE" / …)
function StressRunner:record_counterexample(seed, input, expected, sol_out, sol_err, status)
    -- Don't save a counterexample whose input we already have (as a pre-existing
    -- testcase or one saved earlier this run); just keep searching. The search row
    -- is holding this very input, and is not a testcase.
    local norm = vim.trim(input)
    for _, tc in ipairs(self.tcdata) do
        if type(tc.tcnum) == "number" and tc.stdin and vim.trim(tc.stdin) == norm then
            self:generation(seed + 1)
            return
        end
    end

    local n = self.next_num
    self.next_num = n + 1
    -- A bruteforce that legitimately printed nothing is an answer of its own: saved as
    -- an *empty* answer (`expect_empty_output`), the solution has to print nothing
    -- too. Dropped instead, the testcase would have no answer file at all, and the row
    -- would come back unjudged on every re-run.
    testcases.buf_save_testcase(self.bufnr, n, input, expected or "", true)
    self.saved_this_run = self.saved_this_run + 1
    -- Before the search row, which stays last and moves on to the next number.
    table.insert(self.tcdata, #self.tcdata + (self.search_entry and 0 or 1), {
        tcnum = n,
        stdin = input,
        -- What was stored: an empty answer is a real one here, so unlike typed text it
        -- is not folded into "no answer".
        expected = expected or "",
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

---A generator or bruteforce process failed at *runtime*. It is reported the way a testcase
---reports its own failure, because that is what it is: the row that was doing the work takes
---the verdict, and the Errors pane takes what the process said. The search stops with it —
---every verdict is read off those two programs, so one of them failing makes the rest of the
---search meaningless rather than merely incomplete — and the row stays behind holding the
---seed's input, which is what there is to debug.
---@param label string "generator" | "bruteforce" | "solution"
---@param seed integer
---@param output string? the failing process's stderr/stdout
---@param reason string? how it failed, in words
---@param status string? the verdict for the selector
function StressRunner:helper_failed(label, seed, output, reason, status)
    local what = ("%s %s (seed %d)"):format(label, reason or "failed", seed)
    local row = self.search_entry
    if row then
        row.status = status or "FAILED"
        row.hlgroup = row.status == "TIMEOUT" and "TunaWrong" or "TunaWarning"
        local said = output and vim.trim(output) ~= "" and output or nil
        row.stderr = said and (what .. "\n\n" .. said) or what
        self:finish()
    else
        self:finish(what)
    end
end

---Finish the search (idempotent), refreshing the status line and notifying why.
---@param msg string? reason to report
function StressRunner:finish(msg)
    if self.finished then
        return
    end
    self.finished = true
    self:drop_search_row()
    self:update_ui(true)
    if msg then
        utils.notify("stress: " .. msg .. ".", "INFO")
    end
end

---One generation iteration: generator → solution → bruteforce → judge.
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
    if self:testcase_count() >= self.max_saved then
        self:finish("reached the max of " .. self.max_saved .. " testcases")
        return
    end
    if i > self.count then
        self:finish(string.format("no counterexample found in %d runs", self.count))
        return
    end
    self.iter = i
    -- The row the search is shown on: this iteration's input and outputs land on it,
    -- so a candidate can be read while it is being tried.
    local row = self:search_row()
    row.stdin, row.stdout, row.expected, row.stderr = "", nil, nil, nil
    self:update_ui(false)

    local gen_argv = vim.list_extend({ self.gen.exec }, vim.deepcopy(self.gen.args))
    if self.seed_arg then
        table.insert(gen_argv, tostring(i))
    end
    -- Every spawn in this loop is pcall'd: a binary that is not there (a helper whose
    -- compile failed, then a restart) makes `vim.system` itself throw, and from a
    -- scheduled callback that is a raw traceback rather than a stress message.
    local gen_ok, gen_err = pcall(vim.system, gen_argv, { cwd = self.rundir, timeout = self.timeout }, function(gres)
        vim.schedule(function()
            if self:aborted() then
                return
            end
            local gen_bad, gen_status = failure_reason(gres, self.timeout)
            if gen_bad then
                self:helper_failed("generator", i, gres.stderr, gen_bad, gen_status)
                return
            end
            local input = gres.stdout or ""
            row.stdin = input
            self:update_ui(false)

            -- Solution on the generated input.
            local sol_ok, sol_err = pcall(
                vim.system,
                vim.list_extend({ self.r.rc.exec }, vim.deepcopy(self.r.rc.args)),
                { cwd = self.rundir, stdin = input, timeout = self.timeout },
                function(sres)
                    vim.schedule(function()
                        if self:aborted() then
                            return
                        end
                        row.stdout, row.stderr = sres.stdout or "", sres.stderr or ""
                        self:update_ui(false)
                        -- The bruteforce on the same input (for the expected output), on its
                        -- own budget: it is slow on purpose, and `maximum_time` is what
                        -- the solution is being held to.
                        local ref_ok, ref_err = pcall(
                            vim.system,
                            vim.list_extend({ self.ref.exec }, vim.deepcopy(self.ref.args)),
                            { cwd = self.rundir, stdin = input, timeout = self.ref_timeout },
                            function(rres)
                                vim.schedule(function()
                                    if self:aborted() then
                                        return
                                    end
                                    -- Nothing past here may run on a bruteforce that did
                                    -- not finish: its output is the answer every verdict
                                    -- is read against, and a crash reports no failing
                                    -- exit code of its own, so an empty output would be
                                    -- judged as the correct answer and every input would
                                    -- look like a counterexample.
                                    local ref_bad, ref_status, ref_slow =
                                        failure_reason(rres, self.ref_timeout)
                                    if ref_bad then
                                        self:helper_failed(
                                            "bruteforce",
                                            i,
                                            ref_slow and BRUTEFORCE_TIME_HINT or rres.stderr,
                                            ref_bad,
                                            ref_status
                                        )
                                        return
                                    end
                                    local expected = rres.stdout or ""
                                    row.expected = expected
                                    self:update_ui(false)

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

                                    -- Judge the solution's output against the bruteforce.
                                    local tc = { stdin = input, stdout = sres.stdout or "", expected = expected }
                                    checker.judge(
                                        tc,
                                        self.r.checker,
                                        self:effective_compare(),
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
                        if not ref_ok then
                            self:helper_failed("bruteforce", i, tostring(ref_err), "could not start")
                        end
                    end)
                end
            )
            if not sol_ok then
                self:helper_failed("solution", i, tostring(sol_err), "could not start")
            end
        end)
    end)
    if not gen_ok then
        self:helper_failed("generator", i, tostring(gen_err), "could not start")
    end
end

---Run the pre-existing testcases (in order) through the solution. This needs only the
---solution compiled, so it is a lane of its own: it starts while the generator and bruteforce
---are still building and goes on beside the search. Only a *stop* ends it, not the search
---ending — a search that found its counterexample on the first seed would otherwise leave
---half the testcases on disk sitting at no verdict.
function StressRunner:run_existing()
    -- The real testcase rows (neither the Compile row nor the search row).
    local idxs = {}
    for i, tc in ipairs(self.tcdata) do
        if type(tc.tcnum) == "number" then
            idxs[#idxs + 1] = i
        end
    end
    self.rerunning = #idxs > 0
    local function step(k)
        if self.stopped or k > #idxs then
            self.rerunning = false
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
---loop (`aborted()` gates every step). The generator/bruteforce/solution processes
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
    if self.tcdata[idx] == self.search_entry then
        return -- the search's own row: there is no stored testcase behind it to run again
    end
    if self:built_first(function()
        self:run_single(idx)
    end) then
        return
    end
    self:refresh_judge(vim.api.nvim_buf_get_name(self.bufnr))
    self:execute_entry(idx)
end

---Restart the whole search from scratch (the UI's "run all again").
function StressRunner:run_testcases()
    if self:built_first(function()
        self:run_testcases()
    end) then
        return
    end
    -- A restart looks its helpers up again, as every run does. It keeps its mode, so a
    -- helper that is gone is reported and nothing runs: `:Tuna run` picks the mode again.
    local solution = vim.api.nvim_buf_get_name(self.bufnr)
    local gen, ref, missing = stress_helpers(solution, self.config)
    if not gen then
        self.finished = true
        if self.ui then
            self.ui:show_message(" stress: a helper is missing ", missing .. ".\n\n:Tuna run picks the run mode again.")
        else
            utils.notify(missing .. ".", "WARN")
        end
        self:update_ui(true)
        return
    end
    self.gen, self.ref = gen, ref
    self:refresh_judge(solution)
    self:plan_builds({ gen, ref, self.checker })
    self:build_judge()
    self.stopped = false
    self.finished = false
    self.iter = 0
    self.saved_this_run = 0
    self:load_testcases()
    self:update_ui(true)
    -- Two lanes: the testcases on disk go through the solution while the helpers build, and
    -- the search starts the moment they are built rather than waiting for them. The helpers
    -- go back through `build_helpers`: the compile cache makes an unchanged one free, an
    -- edited one rebuilds, and one whose first compile failed is retried instead of the
    -- search spawning a binary that was never produced.
    self:run_existing()
    self:build_helpers({ self.gen, self.ref }, function()
        if not self:aborted() then
            self:generation(1)
        end
    end)
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

---Rebuild any open stress UIs after a `VimResized`.
function M.resize_all()
    for _, sr in pairs(M.active) do
        sr:resize_ui()
    end
end

---Run stress testing for a buffer's solution.
---@param bufnr integer? defaults to the current buffer
---@param count_override integer? overrides `stress.count`
---@param opts { show_only: boolean? }? open the UI with the rows listed and nothing run
function M.run(bufnr, count_override, opts)
    opts = opts or {}
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
    if not opts.show_only then
        tools.save_sources(bufnr, cfg) -- save the solution (helpers are saved in tools.prepare)
    end

    local gen, ref, missing = stress_helpers(vim.api.nvim_buf_get_name(bufnr), cfg)
    if not gen then
        utils.notify(missing .. ", `:Tuna scaffold` writes starters.", "WARN")
        return
    end

    local timeout = (cfg.maximum_time and cfg.maximum_time > 0) and cfg.maximum_time or nil
    local rundir = r.running_directory
    utils.ensure_directory(rundir)

    -- Tear down a previous stress UI for this buffer before starting a fresh run.
    if M.active[bufnr] then
        M.active[bufnr]:kill_all_processes() -- stop the previous search
        M.active[bufnr]:delete_ui()
    end

    local sr = setmetatable({
        config = cfg,
        bufnr = bufnr,
        r = r,
        -- The inherited execute_process/judge_label judge with self.checker; reuse
        -- the solution runner's resolved checker so verdicts match a normal run.
        checker = r.checker,
        compare_method = r.compare_method, -- carry the per-buffer `:Tuna compare` override

        gen = gen,
        ref = ref,
        dir = dir,
        rundir = rundir,
        timeout = timeout,
        -- The bruteforce is slow on purpose, so it is not held to the solution's limit.
        ref_timeout = (scfg.bruteforce_time and scfg.bruteforce_time > 0) and scfg.bruteforce_time or nil,
        seed_arg = scfg.seed_arg ~= false,
        count = count_override or scfg.count or 100,
        saves_per_run = math.max(1, scfg.saves_per_run or 1),
        max_saved = scfg.max_saved or 10,
        mode = "stress",
        -- The solution's compile step is shown as the first testcase row (so its
        -- warnings are viewable), like the normal runner. nil for interpreted
        -- solutions. gen/ref compile separately (errors shown in a float).
        compile_entry = r.compile and core.compile_row() or nil,
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

    -- What this run compiles, declared before the board opens so the build step is laid out
    -- once: the solution is the Compile row itself, and the generator, the bruteforce and a
    -- checker each get a pane beside it.
    sr:plan_builds({ gen, ref, sr.checker })
    if not opts.show_only then
        sr:build_judge()
    end

    -- Open the results UI and show the testcase list (incl. the Compile row and any
    -- existing testcases, pending) right away.
    sr:load_testcases()
    if opts.show_only then
        sr:mark_not_run()
    end
    sr:show_ui()
    sr:update_ui(true)

    local function search()
        if not sr:aborted() then
            sr:generation(1)
        end
    end

    if opts.show_only then
        -- Listed, not run: the first run key builds and then searches (`built_first` hands
        -- over to `run_testcases`, which puts the testcases on disk through the solution).
        sr:defer_build(function(cont)
            sr:build_all({ sr.gen, sr.ref }, cont)
        end)
        sr:update_ui(true)
        return
    end
    -- All three compile at once, each costing a compile of its own. The testcases already on
    -- disk go through the solution the moment *it* is built, in a lane of their own, and the
    -- search starts when the last of the three lands: the hunt is what the run is for, and it
    -- needs all of them.
    sr:build_all({ sr.gen, sr.ref }, search, function()
        sr:run_existing()
    end)
end

---Open the stress UI for a buffer with its rows listed and nothing run.
---@param bufnr integer
function M.show(bufnr)
    M.run(bufnr, nil, { show_only = true })
end

return M
