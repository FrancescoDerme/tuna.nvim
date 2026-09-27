-- lua/tuna/runner/core.lua
--
-- RunnerCore: the shared base every run mode (normal, stress, interactive, run-all) is
-- built on. It owns the half of the runner that the results UI (`runner_ui`) talks to —
-- the `tcdata` rows, the UI show/update/resize plumbing, the verdict label, kill helpers —
-- the build step every mode shares (`build_all`), and one "spawn a process and judge it"
-- routine (`execute_process`). A mode subclass supplies its own driving loop (parallel
-- lanes, a generation search, interactive sessions), what a failed build means to it
-- (`on_build_failed`), and whichever UI seams it needs (`status_settings`,
-- `status_tail`, `pane_content`, `on_ui_shown`, `layout`, `pane_titles`,
-- `on_details_rendered`, `legend_rows`).
--
-- Inheritance is plain Lua metatable single-dispatch: `M.extend()` returns a
-- subclass table chained to `RunnerCore`, and instances `setmetatable(obj, Sub)`.
-- An instance looks up a method on the subclass first, then falls through to the
-- base — so a subclass overrides just what it needs (see `stress.lua`'s `kill_*`).

local api = vim.api
local utils = require("tuna.utils")
local checker = require("tuna.checker")
local compare = require("tuna.compare")
local sidecar = require("tuna.sidecar")
local testcases = require("tuna.testcases")
local tools = require("tuna.tools")

local M = {}

---Sentinel a mode's `pane_content` returns to mean "this pane is owned by the mode;
---the UI must not overwrite it" — used by interactive's editable Input pane.
M.SKIP = setmetatable({}, {
    __tostring = function()
        return "RunnerCore.SKIP"
    end,
})

---What every mode's runner carries. The build commands come from the normal runner a mode
---holds (`r`), or are the normal runner's own.
---@class tuna.RunnerCore
---@field config table buffer configuration
---@field bufnr integer the solution's buffer
---@field tcdata table[] the rows, 1-indexed
---@field tc_size integer number of rows
---@field completed boolean whether nothing is in flight
---@field preloaded boolean? rows are listed for review, never run
---@field build fun(cont: fun())? the build a listed runner runs first (`defer_build`)
---@field builds table[]? this run's helper build steps (`plan_builds`)
---@field checker "builtin"|table the resolved judge (a helper spec when a checker program judges)
---@field compare_method tuna.CompareSpec? the per-buffer `:Tuna compare` override
---@field r tuna.TCRunner? the normal runner whose commands a mode runs
---@field ui tuna.RunnerUI? the results UI, once shown
---@field last_row_id any? the row the UI was last on (`row_id`)
---@field deleted_testcases table[]? what `u` restores
---@field run_single fun(self: tuna.RunnerCore, idx: integer) re-run one row
---@field run_testcases fun(self: tuna.RunnerCore) re-run every row
---@field mode string? the run mode the UI shows
---@field source string? the interactive source playing the other side
---The seams a mode may fill for the UI (see the header):
---@field layout (fun(self: tuna.RunnerCore): table?, string?)? its own grid, and the option naming it
---@field pane_titles (fun(self: tuna.RunnerCore): table<string, string>?)? names its panes go by
---@field legend_rows (fun(self: tuna.RunnerCore): { title: string, rows: string[][] }?)? its legend section
---@field on_ui_shown fun(self: tuna.RunnerCore, ui: tuna.RunnerUI)? after the UI is shown or re-tiled
---@field on_details_rendered fun(self: tuna.RunnerCore, ui: tuna.RunnerUI, tc: table)? after the detail panes are drawn
---@field status_settings (fun(self: tuna.RunnerCore): string[][])? its settings rows in the Run pane
---@field status_tail (fun(self: tuna.RunnerCore): string[][])? rows after them
---@field row_label (fun(self: tuna.RunnerCore, tc: table): string)? a row's header in the selector
---@field owns_pane (fun(self: tuna.RunnerCore, name: string): boolean)? whether it types into a pane itself
local RunnerCore = {}
RunnerCore.__index = RunnerCore
M.RunnerCore = RunnerCore

---The expected output to *store* for `text`: an empty one means the testcase has no
---answer, not that its answer is empty. That is what reaches the disk — `write_or_delete`
---removes an empty output file rather than writing one — so a row holding `""` would
---disagree with what was just saved, and the judge would compare the run against an
---empty answer and call it WRONG on a testcase that has nothing to be wrong about.
---@param text string?
---@return string?
function M.answer(text)
    if text == nil or text == "" then
        return nil
    end
    return text
end

---The time limit a solution run is held to, in ms, or nil for none (`maximum_time`).
---@param cfg table resolved buffer config
---@return integer?
function M.time_limit(cfg)
    local limit = cfg.maximum_time
    return (limit and limit > 0) and limit or nil
end

---How many processes run at once over `jobs` of them: `multiple_testing`, where -1 is one per
---core and 0 is all of them.
---@param cfg table resolved buffer config
---@param jobs integer
---@return integer
function M.parallelism(cfg, jobs)
    local parallel = cfg.multiple_testing
    if parallel == -1 then
        parallel = vim.uv.available_parallelism()
    elseif parallel == 0 then
        parallel = jobs
    end
    return math.max(1, parallel)
end

---Whether a row's status is a verdict on the solution, what a local verdict counts. A
---testcase with no answer (`DONE`), one stopped (`KILLED`) or one that could not start
---(`FAILED`) says nothing about whether the solution is right.
---@param status string
---@return boolean
local function judged(status)
    return status == "CORRECT"
        or status == "WRONG"
        or status == "TIMEOUT"
        or status:match("^RET ") ~= nil
        or status:match("^SIG ") ~= nil
end

---Save how a finished run of `solution` went over `rows`: how many judged testcases passed,
---with the hash of the source they ran, so the menu can say how a problem went until a
---judge says otherwise, and only while the source is unchanged. A run that judged nothing
---(every testcase without an answer) leaves what was saved alone.
---@param solution string absolute path of the solution
---@param rows table[]
function M.save_local_verdict(solution, rows)
    if not solution or solution == "" then
        return
    end
    local passed, total = 0, 0
    for _, tc in ipairs(rows) do
        if type(tc.tcnum) == "number" and type(tc.status) == "string" and judged(tc.status) then
            total = total + 1
            if tc.status == "CORRECT" then
                passed = passed + 1
            end
        end
    end
    local hash = total > 0 and utils.file_hash(solution)
    if hash then
        sidecar.set_entry(solution, "results", { passed = passed, total = total, hash = hash })
    end
end

---`save_local_verdict` for the solution a runner's buffer holds, when that buffer is still
---there: a run can settle after the buffer is wiped, and its file is then unknown.
---@param bufnr integer
---@param rows table[]
function M.save_buffer_verdict(bufnr, rows)
    if api.nvim_buf_is_valid(bufnr) then
        M.save_local_verdict(api.nvim_buf_get_name(bufnr), rows)
    end
end

---How the last finished run of `solution` went, while its source is still the one that ran.
---@param solution string absolute path of the solution
---@return integer? passed, integer? total
function M.local_verdict(solution)
    local entry = sidecar.get_entry(solution, "results")
    if not (entry and type(entry.passed) == "number" and type(entry.total) == "number") then
        return nil
    end
    if entry.hash ~= utils.file_hash(solution) then
        return nil
    end
    return entry.passed, entry.total
end

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
    self.ui = self.ui or require("tuna.runner_ui").new(self)
    self.ui:show_ui()
end

---Re-show/refresh the UI after a `VimResized`.
function RunnerCore:resize_ui()
    if self.ui then
        self.ui:redraw_grid()
    end
end

---Tear the UI down.
function RunnerCore:delete_ui()
    if self.ui then
        self.ui:delete()
    end
    self.ui = nil
end

---List the rows without running them: every row reads `NOT RUN` (the absence of a
---verdict, so unstyled) and the runner is `preloaded` until its first run.
function RunnerCore:mark_not_run()
    for _, tc in ipairs(self.tcdata) do
        tc.status, tc.hlgroup = "NOT RUN", "TunaDone"
    end
    self.preloaded = true
end

---A runner opened only to list its rows (`preloaded`, carrying a `build` of its own) has
---built nothing, so its first run builds and then does `cont`. Returns whether it took
---over; a runner that has run goes on as usual.
---@param cont fun()
---@return boolean
function RunnerCore:built_first(cont)
    local build = self.preloaded and self.build
    if not build then
        return false
    end
    self.preloaded, self.build = false, nil
    build(cont)
    return true
end

---The build step's row, which every mode that compiles has as row 1 and `build_solution`
---drives. `compile` marks it as standing for no testcase, which is what keeps a checker from
---being asked to judge it.
---@return table
function M.compile_row()
    return { tcnum = "Compile", stdin = "", expected = nil, compile = true, status = "", hlgroup = "TunaRunning" }
end

---What a mode does when the build failed and nothing will run. The base class has nothing to
---settle; a mode whose "is anything in flight?" answer is its own has to give it here, or
---every later edit is refused for a run that never started.
function RunnerCore:on_build_failed() end

---Build the solution, driving the Compile row, and then `cont`. A run that has nothing to
---compile (no Compile row) goes straight on. Every mode builds through here, so a build
---reads the same everywhere: the same verdicts, the same timing, and the same answer when a
---helper beside it failed (`refresh_build_row`). The commands are the runner's own for the
---normal mode and those of the normal runner it holds (`r`) for the others.
---@param cont fun() run only when the build succeeded
function RunnerCore:build_solution(cont)
    local tc, r = self.tcdata[1], self.r or self
    if not (tc and tc.compile and r.cc) then
        cont()
        return
    end
    self:reset_row(tc)
    self:execute_process(1, r.cc, r.compile_directory, { judge = false }, function()
        if tc.exit_code == 0 then
            cont()
        else
            self:on_build_failed()
        end
    end)
end

---Build every helper this run needs, all at once, and then `cont`. They are separate
---programs with separate compilers, so they are not queued behind one another: waiting for
---them is most of what a run waits for. The first failure stops there and is the mode's to
---settle (`on_build_failed`): the build step already shows which source it was and what its
---compiler said.
---@param specs table[]
---@param cont fun() once every one of them is built
function RunnerCore:build_helpers(specs, cont)
    local pending = #specs
    if pending == 0 then
        cont()
        return
    end
    local stopped = false
    for _, spec in ipairs(specs) do
        self:build_helper(spec, function(ok)
            if stopped then
                return
            end
            if not ok then
                stopped = true
                self:on_build_failed()
                return
            end
            pending = pending - 1
            if pending == 0 then
                cont()
            end
        end)
    end
end

---Build everything this run compiles, at once: the solution, which is the Compile row, and
---the helpers its mode needs. `on_solution` runs as soon as the solution alone is built, for
---what does not need the rest (stress puts the testcases already on disk through it there),
---and `cont` once the last of them lands. A failure anywhere settles at `on_build_failed`,
---and `cont` is never reached.
---@param specs table[] helper specs
---@param cont fun() once everything is built
---@param on_solution fun()? once the solution alone is built
function RunnerCore:build_all(specs, cont, on_solution)
    local pending = 2
    local function landed()
        pending = pending - 1
        if pending == 0 then
            cont()
        end
    end
    self:build_solution(function()
        if on_solution then
            on_solution()
        end
        landed()
    end)
    self:build_helpers(specs, landed)
end

---Keep this run's build on the runner instead of running it: a UI opened with its rows only
---listed has built nothing, so the first run key saves the sources and builds before anything
---runs (`built_first`).
---@param build fun(cont: fun()) what this run builds
function RunnerCore:defer_build(build)
    self.build = function(cont)
        tools.save_sources(self.bufnr, self.config)
        build(cont)
    end
end

---The effective output-compare method: a per-buffer runtime override
---(`:Tuna compare …`, carried on the runner as `compare_method`) if set, else the
---configured `output_compare_method`.
---@return tuna.CompareSpec
function RunnerCore:effective_compare()
    return self.compare_method or self.config.output_compare_method
end

---A short human label for how verdicts are decided, shown in the "Run" pane.
---@return string
function RunnerCore:judge_label()
    if type(self.checker) == "table" then
        return vim.fn.fnamemodify(self.checker.source or self.checker.exec, ":t")
    end
    return compare.method_name(self:effective_compare())
end

---Look the judge up again, as every run does, so a checker added, deleted or switched off
---since the last run, and a comparison overridden since, are the ones that judge this run.
---The two are one setting to the user (the "judge" row of the Run pane), so they are resolved
---in one place and at one moment, like every helper.
---@param solution string absolute path of the solution being run
function RunnerCore:refresh_judge(solution)
    local judge, note = tools.resolve_checker(solution, self.config)
    self.checker = judge
    self.compare_method = tools.get_compare(solution)
    if note then
        utils.notify("checker: " .. note .. ", comparing outputs instead.", "WARN")
    end
end

---What text a detail pane should show for `tc`. Overridable so a mode can own or
---relabel a pane; return `M.SKIP` to tell the UI to leave the pane untouched.
---@param tc table the selected testcase row
---@param name string pane name: "so" | "eo" | "si" | "se"
---@return string|table|nil content # nil for nothing to show, `M.SKIP` to leave the pane alone
function RunnerCore:pane_content(tc, name)
    if name == "so" then
        return tc.stdout
    elseif name == "eo" then
        return tc.expected
    elseif name == "si" then
        return tc.stdin
    elseif name == "se" then
        -- The checker's own words belong with the errors: for an external checker its
        -- stderr *is* the explanation of the verdict ("wrong answer: expected 5, got
        -- 3"), and a WRONG with the reason collected but never shown is a checker the
        -- user cannot hear.
        local msg = tc.checker_message
        if msg and msg ~= "" then
            local err = tc.stderr or ""
            if err ~= "" and not err:match("\n$") then
                err = err .. "\n"
            end
            return err .. "checker: " .. msg
        end
        return tc.stderr
    end
    return ""
end

--------------------------------------------------------------------------------
-- The build step: one source per pane
--------------------------------------------------------------------------------

---What a compiler said, in one piece: its complaints first, then anything it wrote to
---stdout, which is nearly always empty but is the only place some compilers talk.
---@param stderr string?
---@param stdout string?
---@return string
local function compiler_text(stderr, stdout)
    local parts = {}
    for _, s in ipairs({ stderr, stdout }) do
        if s and s ~= "" then
            parts[#parts + 1] = s
        end
    end
    return table.concat(parts, "\n")
end

---What a source is called on its pane: the file being compiled, else the command running
---in its place.
---@param spec table
---@return string
function M.build_label(spec)
    return vim.fn.fnamemodify(tostring(spec.source or spec.exec), ":t")
end

---The build step for `spec`, created on first use. Steps are keyed by their label, so a
---helper prepared twice in one run (a rerun answered from the compile cache) redraws the
---pane it already has instead of taking another.
---@param spec table helper spec (`tools.helper`)
---@return table
function RunnerCore:build_step(spec)
    local label = M.build_label(spec)
    self.builds = self.builds or {}
    for _, step in ipairs(self.builds) do
        if step.label == label then
            return step
        end
    end
    local step = { label = label, role = spec.role }
    self.builds[#self.builds + 1] = step
    return step
end

---Declare the sources this run compiles besides the solution, before anything is spawned.
---Declaring them up front is what keeps the build step's grid still: a pane appearing
---halfway through would re-tile the row under someone reading it. A spec with nothing to
---compile (a prebuilt binary, an interpreted helper) has no compiler to quote and gets no
---pane.
---@param specs any[] helper specs, anything that is not one is skipped
function RunnerCore:plan_builds(specs)
    self.builds = {}
    for _, spec in ipairs(specs) do
        if type(spec) == "table" and spec.compile then
            self:build_step(spec)
        end
    end
end

---Compile one helper as part of the build step: the compiler's words land in the pane that
---helper was given, whether it failed or merely warned.
---@param spec table helper spec from `tools.helper`
---@param cb fun(ok: boolean, err: string?)
function RunnerCore:build_helper(spec, cb)
    if not (type(spec) == "table" and spec.compile) then
        tools.prepare(spec, cb)
        return
    end
    local step = self:build_step(spec)
    step.failed, step.output = false, nil -- building: no output is what "not done yet" is
    self:update_ui(true)
    tools.prepare(spec, function(ok, err, output)
        step.failed = not ok
        step.output = ok and (output or "") or (err or "")
        self:refresh_build_row()
        self:update_ui(true)
        cb(ok, err)
    end)
end

---Compile this run's checker as part of the build step, when it is a program of its own.
---Nothing waits for it: the testcases do not need it until there is a verdict to reach, and
---`tools.prepare` hands that caller the same build. It is built here so a checker that
---failed or warned says so on the build step, beside every other source, rather than on the
---first verdict, where the only place left to say it is a notification.
function RunnerCore:build_judge()
    local spec = self.checker
    if type(spec) == "table" and spec.compile then
        self:build_helper(spec, function() end)
    end
end

---The Compile row answers for the whole build step, not only the solution: a helper that
---failed to compile is a failed build, said where every build is said, beside the pane
---holding what its compiler wrote. Only a build that came back clean is downgraded — the
---solution's own failure is the more specific answer, and keeps its exit code.
function RunnerCore:refresh_build_row()
    local tc = self.tcdata[1]
    if not (tc and tc.compile and tc.status == "DONE") then
        return
    end
    for _, step in ipairs(self.builds or {}) do
        if step.failed then
            tc.status, tc.hlgroup = "FAILED", "TunaWarning"
            return
        end
    end
end

---What the build step shows, source by source, in the order their panes are handed out:
---the solution first, whose compile *is* the Compile row, then every helper this run
---builds.
---@param tc table the Compile row
---@return { label: string, role: string, output: string, failed: boolean, done: boolean }[]
function RunnerCore:build_sources(tc)
    local name = api.nvim_buf_is_valid(self.bufnr) and api.nvim_buf_get_name(self.bufnr) or ""
    local sources = {
        {
            label = name ~= "" and vim.fn.fnamemodify(name, ":t") or "solution",
            role = "solution",
            output = compiler_text(tc.stderr, tc.stdout),
            failed = tc.exit_code ~= nil and tc.exit_code ~= 0,
            done = tc.exit_code ~= nil,
        },
    }
    for _, step in ipairs(self.builds or {}) do
        sources[#sources + 1] = {
            label = step.label,
            role = step.role,
            output = step.output or "",
            failed = step.failed == true,
            done = step.output ~= nil,
        }
    end
    return sources
end

---Whether any source of the build step said something: a failure, or a warning. The row
---worth reading is the one that has something on it, so this is what keeps the UI on the
---build step instead of handing the cursor to the first testcase.
---@param tc table the Compile row
---@return boolean
function RunnerCore:build_spoke(tc)
    for _, source in ipairs(self:build_sources(tc)) do
        if source.failed or source.output ~= "" then
            return true
        end
    end
    return false
end

---Whether the build step is still going. A helper compiling beside the solution is part of
---the same step, so the cursor waits for it too, or a warning landing a moment later would
---arrive on a row nobody is looking at any more.
---@param tc table the Compile row
---@return boolean
function RunnerCore:build_pending(tc)
    for _, source in ipairs(self:build_sources(tc)) do
        if not source.done then
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- Shared execution: spawn one process, judge it
--------------------------------------------------------------------------------

---Reset a row's per-run state so a re-run starts clean. Bumping `run_id` here as
---well as at spawn means a reset alone orphans any callback still in flight for the
---row — the result of a process that was killed to make way for this reset must not
---land on the fresh row (see `execute_process`).
---@param tc table
function RunnerCore:reset_row(tc)
    tc.run_id = (tc.run_id or 0) + 1
    tc.status = ""
    tc.hlgroup = "TunaRunning"
    tc.stdout = nil
    tc.stderr = nil
    tc.checker_message = nil
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

    -- One token per spawn, checked again when the result lands. A process's exit
    -- callback arrives on a *scheduled* tick, so a re-run that killed this child and
    -- spawned a replacement — or rebuilt the rows entirely — has already happened by
    -- the time the dead child reports in. Without the token that stale report would
    -- write into whatever row now sits at this index: clearing `running` (declaring a
    -- run complete early), nilling the fresh handle (making the new process
    -- unkillable), stamping `SIG 9` over a row mid-run, and pulling another lane out of
    -- the *new* run's queue through its `on_done`, double-running rows.
    tc.run_id = (tc.run_id or 0) + 1
    local run_id = tc.run_id

    local timelimit = opts.timelimit or tc.timelimit
    -- The timer is a local, not a row field: a superseded callback must still close
    -- the timer *it* started, which a shared `tc.timer` slot cannot tell apart from
    -- the replacement run's.
    local timer
    if timelimit then
        timer = assert(vim.uv.new_timer())
        timer:start(timelimit, 0, function()
            if tc.run_id == run_id and tc.running and tc.handle then
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
            self:finish_process(tc, run_id, timer, res, opts, on_done)
        end)
    end)

    if not ok then
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
        end
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
---Whether `tc` is still one of this runner's rows. Row tables are replaced wholesale
---by a rebuild (`build_rows`, run-all's `rebuild_rows`), so a callback holding an old
---row must not act on the runner at all — its `on_done` would feed a lane into a run
---it was never part of.
---@param tc table
---@return boolean
function RunnerCore:owns_row(tc)
    for _, row in ipairs(self.tcdata) do
        if row == tc then
            return true
        end
    end
    return false
end

---@private
---Record a finished process's result and decide its status (may judge async).
---Takes the row *object* it was spawned for, never an index: prompts answered while
---the child ran can renumber or remove rows, and the result belongs to the row it
---came from wherever that row now sits.
---@param tc table
---@param run_id integer the spawn token captured by `execute_process`
---@param timer uv.uv_timer_t? that spawn's timeout timer
---@param res vim.SystemCompleted
---@param opts table
---@param on_done fun()?
function RunnerCore:finish_process(tc, run_id, timer, res, opts, on_done)
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
    -- Superseded (the row was reset or re-spawned) or orphaned (the rows were
    -- rebuilt): this result describes a process the runner has already disowned, so
    -- nothing of it may land — not the row state, not `on_done`.
    if tc.run_id ~= run_id or not self:owns_row(tc) then
        return
    end
    tc.running = false
    tc.time = vim.uv.now() - tc.start_time
    tc.exit_code = res.code
    tc.exit_signal = res.signal
    tc.stdout = res.stdout or ""
    tc.stderr = res.stderr or ""
    tc.handle = nil

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
        self:refresh_build_row() -- a helper may have failed while this one was building
        finalize()
    else
        -- Derive the verdict via the checker (nil expected → DONE). External
        -- checkers are async, so flag the row as judging until the verdict lands.
        tc.judging = true
        local chk = opts.checker or self.checker
        checker.judge(tc, chk, self:effective_compare(), function(correct, message)
            -- An external checker takes real time, and the row can be reset or
            -- re-spawned while it judges — the same window the token guards above.
            if tc.run_id ~= run_id then
                return
            end
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

--------------------------------------------------------------------------------
-- Inline testcase editing (what the UI's always-editable panes drive)
--------------------------------------------------------------------------------

---Whether this mode's testcases can be edited from the results UI. True for every
---mode whose rows *are* the stored testcases (normal, stress, run-all); interactive
---turns it off — it owns the Input pane as the thing you type at the solution.
RunnerCore.editable_testcases = true

---Whether a given row stands for a stored testcase, and so can be edited, re-saved
---or deleted. Excludes the `Compile` pseudo-row and run-all's solution headers
---without either having to be special-cased anywhere else.
---@param tc table?
---@return boolean
function RunnerCore:row_editable(tc)
    return self.editable_testcases and tc ~= nil and type(tc.tcnum) == "number"
end

---A stable identity for a row, so the UI can reopen on the row you left even after
---the rows themselves were rebuilt (a re-run, or `show_ui` reloading testcases).
---@param tc table
---@return string
function RunnerCore:row_id(tc)
    return tostring(tc.tcnum)
end

---The buffer testcase paths are resolved against. Normally the solution the runner
---was started from; run-all overrides it, since it can be launched from a scratch
---buffer that is not itself a solution.
---@return integer
function RunnerCore:edit_bufnr()
    return self.bufnr
end

---Whether no run is in flight. Structural edits (adding or deleting a testcase)
---wait for one, since they renumber the rows the running lanes are indexing.
---@return boolean
function RunnerCore:idle()
    return self.completed ~= false
end

---Every row index standing for testcase `tcnum` (one for most modes; in run-all's
---matrix, one per solution).
---@param tcnum integer
---@return integer[]
function RunnerCore:rows_for(tcnum)
    local idxs = {}
    for i, tc in ipairs(self.tcdata) do
        if tc.tcnum == tcnum and self:row_editable(tc) then
            idxs[#idxs + 1] = i
        end
    end
    return idxs
end

---The lowest unused testcase number, counting both what is on disk and the rows
---already added in this session but not yet saved.
---@return integer
function RunnerCore:next_tcnum()
    local used = {}
    for n in pairs(testcases.buf_get_testcases(self:edit_bufnr())) do
        used[n] = true
    end
    for _, tc in ipairs(self.tcdata) do
        if type(tc.tcnum) == "number" then
            used[tc.tcnum] = true
        end
    end
    local n = 0
    while used[n] do
        n = n + 1
    end
    return n
end

---Append a row for a new testcase. Modes whose rows are a plain list just add one;
---run-all overrides this to add the testcase to every solution.
---@param tcnum integer
function RunnerCore:add_testcase_row(tcnum)
    table.insert(self.tcdata, {
        tcnum = tcnum,
        stdin = "",
        expected = nil,
        timelimit = M.time_limit(self.config),
        status = "NOT RUN",
        hlgroup = "TunaDone",
    })
    self.tc_size = #self.tcdata
end

---Drop every row standing for `tcnum`.
---@param tcnum integer
function RunnerCore:remove_testcase_rows(tcnum)
    for i = #self.tcdata, 1, -1 do
        local tc = self.tcdata[i]
        if tc.tcnum == tcnum and self:row_editable(tc) then
            table.remove(self.tcdata, i)
        end
    end
    self.tc_size = #self.tcdata
end

---Save an edited testcase to disk, refresh the rows that show it, and re-run them.
---Nothing is re-run for a UI that was only *listing* testcases (`:Tuna show_ui`
---before any run): there is no build to run yet, so the rows stay `NOT RUN`.
---@param tcnum integer
---@param input string
---@param expected string
---@param expect_empty_output boolean? an empty answer means the solution must print
---nothing, rather than that the testcase has no answer — the one thing a save cannot
---read off the panes, so it is the one thing asked
---@return boolean # whether the write succeeded
function RunnerCore:save_testcase(tcnum, input, expected, expect_empty_output)
    local ok, err = pcall(function()
        testcases.buf_save_testcase(self:edit_bufnr(), tcnum, input, expected, expect_empty_output)
    end)
    if not ok then
        utils.notify("could not save testcase " .. tcnum .. ": " .. tostring(err))
        return false
    end
    local rows = self:rows_for(tcnum)
    -- What was stored for the answer: `""` when an empty one means "print nothing",
    -- `nil` when it means the testcase has no answer.
    local stored_answer = expect_empty_output and "" or M.answer(expected)
    for _, i in ipairs(rows) do
        self.tcdata[i].stdin = input
        self.tcdata[i].expected = stored_answer
        -- A save always leaves the testcase on disk, so the row always has a file behind
        -- it — which is what `bare` says it has not.
        self.tcdata[i].bare = nil
    end
    if self.preloaded or not self:idle() then
        self:update_ui(true)
    else
        for _, i in ipairs(rows) do
            self:run_single(i)
        end
    end
    return true
end

---Lift the cases this row's markers bracket out into rows of their own, writing them
---to disk as it goes.
---
---The rows are what makes this worth having: a case buried in a testcase that fails as
---a whole gets a verdict of its own, so the answer is on screen instead of somewhere in
---a wall of output. The row keeps its number and its place, holding what was outside
---the markers; the lifted cases are appended.
---
---Worth knowing when a case passes on its own but the original still fails: that is
---state left over between cases (an uncleared array, a stale answer), and it is only
---visible because the two are in front of each other.
---@param tcnum integer
---@param char string separator character
---@param input string? text to split instead of the stored input (an unsaved edit)
---@param expected string? text to split instead of the stored expected output
---@return boolean # whether anything was split
function RunnerCore:split_testcase(tcnum, char, input, expected)
    local bufnr = self:edit_bufnr()
    -- Read before the split, since the split rewrites it. The pane text wins where
    -- there is one: it is the input the user marked up, and the input being split.
    local before = input or (testcases.buf_get_testcases(bufnr)[tcnum] or {}).input

    local numbers, err, summary = testcases.buf_split_testcase(bufnr, tcnum, char, input, expected)
    if not numbers then
        utils.notify("split testcase " .. tcnum .. ": " .. err .. ".")
        return false
    end

    for _, n in ipairs(numbers) do
        if n ~= tcnum then
            self:add_testcase_row(n)
        end
    end
    self:sync_rows(numbers)
    self:update_ui(true) -- the new rows show while the question is still up
    utils.notify(summary .. ".", "INFO")
    -- Held back until the count question is answered: accepting rewrites the same
    -- testcases, so running now would judge input that is about to change — and by the
    -- time the answer came the first run would still be in flight, which is precisely
    -- when a re-run is refused. `offer_case_counts` settles either way, so the run
    -- happens whatever the answer, and only once.
    testcases.offer_case_counts(bufnr, numbers, before, function()
        self:run_rows(self:sync_rows(numbers))
    end)
    return true
end

---Point the rows for `numbers` at what is now on disk.
---@param numbers integer[]
---@param tctbl table<integer, table>? testcases already read, to save a second scan
---@return integer[] rows the row indices that stand for them
function RunnerCore:sync_rows(numbers, tctbl)
    tctbl = tctbl or testcases.buf_get_testcases(self:edit_bufnr())
    local rows = {}
    for _, n in ipairs(numbers) do
        local case = tctbl[n] or {}
        for _, i in ipairs(self:rows_for(n)) do
            self.tcdata[i].stdin = case.input or ""
            -- Straight from disk, not through `answer`: that normalizes *typed* text,
            -- and an answer stored as empty means "expect no output", which squashing
            -- it to nil would turn back into "no answer".
            self.tcdata[i].expected = case.output
            rows[#rows + 1] = i
        end
    end
    return rows
end

---@private
---A run of the whole set has been asked for: the board chooses the row again
---(`RunnerUI:choose_row_again`).
function RunnerCore:choose_row_again()
    if self.ui then
        self.ui:choose_row_again()
    end
end

---Run the rows a split produced. Splitting exists to get a verdict per case, so the
---cases run without being asked for a second time.
---@param rows integer[]
function RunnerCore:run_rows(rows)
    if not self:idle() then
        self:update_ui(true) -- a run is in flight; renumbering its lanes is not safe
    elseif self.preloaded then
        -- Nothing has been built yet (`:Tuna show_ui` before any run), so the rows
        -- cannot be run one at a time: the first `run_single` compiles and clears
        -- `preloaded`, leaving every row after it to spawn a binary that is not there
        -- yet. Running the lot builds first, and every mode the UI drives has it.
        self:run_testcases()
    else
        for _, i in ipairs(rows) do
            self:run_single(i)
        end
    end
end

return M
