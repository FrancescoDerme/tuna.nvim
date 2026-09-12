-- lua/tuna/runner/core.lua
--
-- RunnerCore: the shared base every run mode (normal, stress, interactive, and
-- later run-all) is built on. It owns the half of the runner that the results UI
-- (`runner_ui`) actually talks to — the `tcdata` rows, the UI show/update/resize
-- plumbing, the verdict label, kill helpers — plus one reusable "spawn a process
-- and judge it" routine (`execute_process`). A mode subclass supplies only its own
-- driving loop (parallel lanes / a generation search / interactive sessions) and,
-- if it wants, a `status_tail`, a `pane_content` override, an `on_ui_shown` hook, a
-- `layout`/`pane_titles` of its own, or `on_details_rendered` to draw the panes it owns.
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
    return require("tuna.compare").method_name(self:effective_compare())
end

---Look the checker up again, as every run does, so a checker added, deleted or switched
---off since the last run is the one that judges this run.
---@param solution string absolute path of the solution being run
function RunnerCore:refresh_checker(solution)
    local checker, note = require("tuna.tools").resolve_checker(solution, self.config)
    self.checker = checker
    if note then
        require("tuna.utils").notify("checker: " .. note .. ", comparing outputs instead.", "WARN")
    end
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
        timer = vim.uv.new_timer()
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
---@param timer uv_timer_t? that spawn's timeout timer
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
    for n in pairs(require("tuna.testcases").buf_get_testcases(self:edit_bufnr())) do
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
    local timelimit = (self.config.maximum_time and self.config.maximum_time > 0) and self.config.maximum_time or nil
    table.insert(self.tcdata, {
        tcnum = tcnum,
        stdin = "",
        expected = nil,
        timelimit = timelimit,
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
        require("tuna.testcases").buf_save_testcase(self:edit_bufnr(), tcnum, input, expected, expect_empty_output)
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
    local tc_module = require("tuna.testcases")
    local bufnr = self:edit_bufnr()
    -- Read before the split, since the split rewrites it. The pane text wins where
    -- there is one: it is the input the user marked up, and the input being split.
    local before = input or (tc_module.buf_get_testcases(bufnr)[tcnum] or {}).input

    local numbers, err, summary = tc_module.buf_split_testcase(bufnr, tcnum, char, input, expected)
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
    tc_module.offer_case_counts(bufnr, numbers, before, function()
        self:run_rows(self:sync_rows(numbers))
    end)
    return true
end

---@private
---Point the rows for `numbers` at what is now on disk.
---@param numbers integer[]
---@param tctbl table<integer, table>? testcases already read, to save a second scan
---@return integer[] rows the row indices that stand for them
function RunnerCore:sync_rows(numbers, tctbl)
    tctbl = tctbl or require("tuna.testcases").buf_get_testcases(self:edit_bufnr())
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
