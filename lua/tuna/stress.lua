-- lua/tuna/stress.lua
--
-- Stress testing: hunt for inputs on which the current solution disagrees with a
-- trusted bruteforce. A generator produces a random input (seeded by a number new for
-- every run plus the iteration, so each run tries new inputs and the seed shown
-- reproduces one); the solution and the
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
-- UI is the same `runner_ui` every mode drives, through a `RunnerCore` subclass.

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

---A command as the argv `vim.system` takes.
---@param cmd { exec: string, args: string[]? }
---@return string[]
local function argv(cmd)
    return vim.list_extend({ cmd.exec }, vim.deepcopy(cmd.args or {}))
end

-- Shown instead of a (silent) timed-out bruteforce's stderr: the budget is the one thing to
-- change about it.
local BRUTEFORCE_TIME_HINT = "stress.bruteforce_time sets how long it may take on one generated input,\n"
    .. "in milliseconds, false removes the limit."

-- Live stress runners keyed by buffer, so `VimResized` can rebuild their UIs and
-- a fresh `:Tuna run stress` can tear the previous one down.
---@type table<integer, table>
M.active = {}

--------------------------------------------------------------------------------
-- StressRunner: a RunnerCore subclass adding the generation search and its counters
--------------------------------------------------------------------------------

local StressRunner = core.extend()

---The generator and bruteforce of a solution, or nil and what to tell the user about the
---ones that are missing: in words, and as the roles a starter can stand in for, which is
---every missing one only when none of them is a configured helper that is broken (a starter
---written beside the solution would not be the one used).
---@param solution string
---@param cfg table
---@return table? gen, table? ref, string? missing, string[]? absent
local function stress_helpers(solution, cfg)
    local gen, gen_note = tools.helper("generator", solution, cfg)
    local ref, ref_note = tools.helper("bruteforce", solution, cfg)
    if gen and ref then
        return gen, ref
    end
    local names = cfg.tool_names
    local missing, absent = {}, {}
    if not gen then
        missing[#missing + 1] = gen_note
            or ("no generator (a " .. names.generator[1] .. ".* file or stress.generator)")
        absent[#absent + 1] = "generator"
    end
    if not ref then
        missing[#missing + 1] = ref_note
            or ("no bruteforce (a " .. names.bruteforce[1] .. ".* file or stress.bruteforce)")
        absent[#absent + 1] = "bruteforce"
    end
    local broken = (not gen and gen_note) or (not ref and ref_note)
    return nil, nil, "stress needs a generator and a bruteforce, " .. table.concat(missing, " and "), not broken and absent or nil
end

---What stress asks for when its helpers are simply not there: to write their starters.
---@param absent string[]
---@param bufnr integer
---@param opts { win: integer?, before: fun()? }?
local function offer_helpers(absent, bufnr, opts)
    local title = "Stress needs a " .. table.concat(absent, " and a ")
    require("tuna.scaffold").create_missing(absent, bufnr, title, opts)
end

---What the `?` legend adds for a stress run: the row the search is shown on, and what the
---keys that act on a whole run do to the search.
---@return { title: string, rows: string[][] }
function StressRunner:legend_rows()
    return {
        title = "STRESS",
        rows = {
            { "the search row", "the last one, the input being tried and both outputs," },
            { " ", "numbered as the counterexample it is looking for" },
            { "run again on it", "does nothing, it is not a testcase" },
            { "stop", "ends the search and the testcases re-running beside it" },
            { "run all again", "searches again, from a new seed" },
        },
    }
end

---Extra "Run" pane rows below mode/judge: the live stress counters, as
---{ label, value } pairs (the UI aligns the colons), one per line.
---@return string[][]
function StressRunner:status_tail()
    local rows = {
        { "iter", ("%d / %d"):format(self.iter, self.count) },
        { "saved", ("%d / %d"):format(self.saved_this_run, self.saves_per_run) },
        { "max", ("%d testcases"):format(self.max_saved) },
    }
    if self.pass_seed then
        -- The seed of the input being tried, the one to hand the generator to see it again.
        table.insert(rows, 2, { "seed", self.iter > 0 and tostring(self:seed(self.iter)) or "—" })
    end
    return rows
end

---The seed the generator is handed for the `i`-th input of this run: the run's own base, so
---every run tries new inputs, plus `i`.
---@param i integer
---@return integer
function StressRunner:seed(i)
    return (self.seed_base or 0) + i
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

---A testcase added, restored or split off while the board is idle goes above the search row,
---which stays last, and moves the number the search would save under past it: the search row
---wears that number, and would otherwise read the same as the row just added. Every search
---rebuilds its rows from disk first, so this is what keeps the board honest in between.
---@param tcnum integer
function StressRunner:add_testcase_row(tcnum)
    core.RunnerCore.add_testcase_row(self, tcnum)
    if self.search_entry then
        local row = table.remove(self.tcdata)
        for i, tc in ipairs(self.tcdata) do
            if tc == self.search_entry then
                table.insert(self.tcdata, i, row)
                break
            end
        end
    end
    self.next_num = math.max(self.next_num, tcnum + 1)
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
    self:reset_row(self.tcdata[idx])
    self:execute_process(idx, self.r.rc, self.rundir, { timelimit = self.timeout }, cb)
end

---Save a counterexample as a new testcase and add it to the UI.
---@param i integer the iteration that produced it
---@param input string
---@param expected string the bruteforce's (correct) output, stored as expected output
---@param sol_out string the solution's (wrong) output
---@param sol_err string the solution's stderr
---@param status string the verdict it earned, in a testcase's words (`WRONG`, `TIMEOUT`, `SIG n`…)
---@param hlgroup string? its colour
function StressRunner:record_counterexample(i, input, expected, sol_out, sol_err, status, hlgroup)
    -- Don't save a counterexample whose input we already have (as a pre-existing
    -- testcase or one saved earlier this run); just keep searching. The search row
    -- is holding this very input, and is not a testcase.
    local norm = vim.trim(input)
    for _, tc in ipairs(self.tcdata) do
        if type(tc.tcnum) == "number" and tc.stdin and vim.trim(tc.stdin) == norm then
            self:generation(i + 1)
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
        hlgroup = hlgroup or "TunaWrong",
        -- A freshly-saved counterexample has no runtime to show; the UI displays
        -- this in the time column instead (re-running it fills in a real time).
        time_label = "saved",
    })
    self:update_ui(true)
    -- Keep searching; the thresholds are re-checked at the top of `generation`.
    self:generation(i + 1)
end

---A generator or bruteforce process failed at *runtime*. It is reported the way a testcase
---reports its own failure, because that is what it is: the row that was doing the work takes
---the verdict, and the Errors pane takes what the process said. The search stops with it —
---every verdict is read off those two programs, so one of them failing makes the rest of the
---search meaningless rather than merely incomplete — and the row stays behind holding the
---seed's input, which is what there is to debug.
---@param label string "generator" | "bruteforce" | "solution"
---@param i integer the iteration it failed on
---@param output string? the failing process's stderr/stdout
---@param reason string? how it failed, in words
---@param status string? the verdict for the selector (`core.ending`'s), else FAILED
---@param hlgroup string? its colour
function StressRunner:helper_failed(label, i, output, reason, status, hlgroup)
    -- The seed is what reproduces the input, when the generator was handed one.
    local which = self.pass_seed and ("seed %d"):format(self:seed(i)) or ("input %d"):format(i)
    local what = ("%s %s (%s)"):format(label, reason or "failed", which)
    local row = self.search_entry
    if row then
        row.status = status or "FAILED"
        row.hlgroup = hlgroup or "TunaWarning"
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
---@param i integer iteration
function StressRunner:generation(i)
    if self:aborted() then
        return
    end
    if self.saved_this_run >= self.saves_per_run then
        -- The save limit (deduplicated counterexamples) ends the search silently: the saved
        -- row is the answer, on the board.
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
    if self.pass_seed then
        table.insert(gen_argv, tostring(self:seed(i)))
    end
    self:spawn("generator", i, gen_argv, { timeout = self.timeout }, function(gres)
        local failed, hl, words = core.ending(gres, self.timeout)
        if failed then
            return self:helper_failed("generator", i, gres.stderr, words, failed, hl)
        end
        local input = gres.stdout or ""
        row.stdin = input
        self:update_ui(false)

        self:spawn("solution", i, argv(self.r.rc), { stdin = input, timeout = self.timeout }, function(sres)
            row.stdout, row.stderr = sres.stdout or "", sres.stderr or ""
            self:update_ui(false)
            -- The bruteforce on its own budget: it is slow on purpose, and `maximum_time` is
            -- what the solution is being held to.
            self:spawn("bruteforce", i, argv(self.ref), { stdin = input, timeout = self.ref_timeout }, function(rres)
                -- Nothing past here may run on a bruteforce that did not finish: its output is
                -- the answer every verdict is read against, and a crash reports no failing exit
                -- code of its own, so an empty output would be judged as the correct answer and
                -- every input would look like a counterexample.
                local ref_failed, ref_hl, ref_words = core.ending(rres, self.ref_timeout)
                if ref_failed then
                    local said = ref_failed == "TIMEOUT" and BRUTEFORCE_TIME_HINT or rres.stderr
                    return self:helper_failed("bruteforce", i, said, ref_words, ref_failed, ref_hl)
                end
                local expected = rres.stdout or ""
                row.expected = expected
                self:update_ui(false)

                -- A solution that did not finish is itself a counterexample, wearing the verdict a
                -- testcase would for the same ending.
                local sol_out, sol_err = sres.stdout or "", sres.stderr or ""
                local ended, ended_hl = core.ending(sres, self.timeout)
                if ended then
                    return self:record_counterexample(i, input, expected, sol_out, sol_err, ended, ended_hl)
                end
                local tc = { stdin = input, stdout = sol_out, expected = expected }
                checker.judge(tc, self.checker, self:effective_compare(), function(correct, message)
                    if self:aborted() then
                        return
                    end
                    -- A checker that gives no verdict judges nothing, so searching on would
                    -- only end in "no counterexample found", which would not be true.
                    if correct == nil then
                        return self:helper_failed("checker", i, message, "gave no verdict")
                    end
                    if correct == false then
                        self:record_counterexample(i, input, expected, sol_out, "", "WRONG", "TunaWrong")
                    else
                        self:generation(i + 1)
                    end
                end)
            end)
        end)
    end)
end

---The helpers the search cannot run without, built before it starts: the generator, the
---bruteforce, and the checker when it is a program of its own.
---@return tuna.HelperSpec[]
function StressRunner:search_helpers()
    local specs = { self.gen, self.ref }
    if type(self.checker) == "table" then
        specs[#specs + 1] = self.checker
    end
    return specs
end

---One step of the search: spawn `argv` in the running directory, and hand its result to `cb`
---on the main loop unless the search was stopped meanwhile. A program that cannot be started
---at all (a binary that is not there makes `vim.system` throw) ends the search, reported as
---that step's failure.
---@param label string "generator" | "solution" | "bruteforce"
---@param i integer the iteration
---@param cmd string[]
---@param opts table `vim.system` options besides `cwd`
---@param cb fun(res: vim.SystemCompleted)
function StressRunner:spawn(label, i, cmd, opts, cb)
    opts.cwd = self.rundir
    local ok, err = pcall(vim.system, cmd, opts, function(res)
        vim.schedule(function()
            if not self:aborted() then
                cb(res)
            end
        end)
    end)
    if not ok then
        self:helper_failed(label, i, tostring(err), "could not start")
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
    -- A board that was only listed had nothing running to stop.
    self:finish(not self.preloaded and "stopped" or nil)
end

---A single kill stops the whole search (there's only one lane).
function StressRunner:kill_process()
    self:kill_all_processes()
end

---Re-run the solution on one displayed testcase and re-judge it.
---@param idx integer
function StressRunner:run_single(idx)
    local tc = self.tcdata[idx]
    if not tc or tc == self.search_entry then
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

---Run the whole search from scratch: the first run, and the UI's "run all again".
function StressRunner:run_testcases()
    self:claim_listed()
    -- Every run looks its helpers up again, as every run does. It keeps its mode, so a
    -- helper that is gone is reported and nothing runs: `:Tuna run` picks the mode again.
    local solution = vim.api.nvim_buf_get_name(self.bufnr)
    local gen, ref, missing, absent = stress_helpers(solution, self.config)
    if not gen then
        self.finished = true
        self:update_ui(true)
        if absent then
            -- Written, they open in the editor the board was over, the board having nothing
            -- to run until they are filled in.
            offer_helpers(absent, self.bufnr, {
                win = self.ui and self.ui.restore_winid,
                before = function()
                    self:delete_ui()
                end,
            })
        elseif self.ui then
            self.ui:show_message(" stress: a helper is missing ", missing .. ".\n\n:Tuna run picks the run mode again.")
        else
            utils.notify(missing .. ".", "WARN")
        end
        return
    end
    self.gen, self.ref = gen, ref
    self:refresh_judge(solution)
    self:plan_builds({ gen, ref, self.checker })
    -- The checker is built with the generator and the bruteforce, and waited for like them:
    -- the search judges every input with it, so one that did not build stops it before any
    -- input is tried.
    self.stopped = false
    self.finished = false
    self.iter = 0
    -- A base new for every run, so a run after one that found nothing tries new inputs: the
    -- clock's microseconds, kept small enough to read in the Run pane.
    self.seed_base = math.floor(vim.uv.hrtime() / 1000) % 1000000
    self.saved_this_run = 0
    self:load_testcases()
    self:update_ui(true)
    -- All three compile at once, as every run of the whole set builds. The testcases on disk
    -- go through the solution the moment *it* is built, in a lane of their own, and the search
    -- starts when the last of the three lands: the hunt is what the run is for. An unchanged
    -- helper's build is reused, and an edited one, or one that failed, is built again
    -- instead of the search spawning a binary never produced.
    self:build_all(self:search_helpers(), function()
        if not self:aborted() then
            self:generation(1)
        end
    end, function()
        self:run_existing()
    end)
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

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
    if not opts.show_only then
        tools.save_sources(bufnr, cfg) -- save the solution (helpers are saved in tools.prepare)
    end

    local gen, ref, missing, absent = stress_helpers(vim.api.nvim_buf_get_name(bufnr), cfg)
    if not gen then
        if absent then
            offer_helpers(absent, bufnr)
        else
            utils.notify(missing .. ".", "WARN")
        end
        return
    end

    local timeout = core.time_limit(cfg)
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
        rundir = rundir,
        timeout = timeout,
        -- The bruteforce is slow on purpose, so it is not held to the solution's limit.
        ref_timeout = (scfg.bruteforce_time and scfg.bruteforce_time > 0) and scfg.bruteforce_time or nil,
        pass_seed = scfg.pass_seed ~= false,
        count = count_override or scfg.count or 100,
        saves_per_run = math.max(1, scfg.saves_per_run or 1),
        max_saved = scfg.max_saved or 10,
        mode = "stress",
        -- The build step's row, nil for an interpreted solution.
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

    -- Open the results UI with the rows listed (the Compile row, the testcases on disk and the
    -- search's row) right away.
    sr:load_testcases()
    if opts.show_only then
        sr:mark_not_run()
    end
    sr:show_ui()
    sr:update_ui(true)

    if opts.show_only then
        -- Listed, not run: a row's run key builds and runs that row (`built_first`); a run of
        -- the whole set builds anyway.
        sr:defer_build(function(cont)
            sr:build_all(sr:search_helpers(), cont)
        end)
        return
    end
    sr:run_testcases()
end

---Open the stress UI for a buffer with its rows listed and nothing run.
---@param bufnr integer
function M.show(bufnr)
    M.run(bufnr, nil, { show_only = true })
end

return M
