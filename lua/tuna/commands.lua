-- lua/tuna/commands.lua
--
-- The `:Tuna <subcommand> [args…]` surface. `execute` dispatches the parsed
-- argument list to a handler; `complete` provides context-aware tab-completion
-- (subcommand names, then per-subcommand argument lists). The heavier handlers
-- (`edit_testcase`, `delete_testcase`, `convert_testcases`, `run_testcases`,
-- `download`) live as module functions so they're easy to call and test.

local api = vim.api
local config = require("tuna.config")
local utils = require("tuna.utils")
local testcases = require("tuna.testcases")
local runner = require("tuna.runner")
local tools = require("tuna.tools")

local M = {}

-- Sub-argument completions for subcommands that take a second word.
local subcommand_args = {
    run = vim.list_extend({ "auto" }, vim.deepcopy(tools.MODES)),
    testcase = { "add", "edit", "delete", "split" },
    convert = { "files", "single_file", "directory" },
    download = { "testcases", "problem", "contest", "sync", "persistently", "status", "stop" },
    scaffold = tools.ROLES,
    checker = { "auto", "off", "toggle" },
    compare = { "exact", "squish", "float", "default" },
    submit = { "clear" },
    lib = { "snippet", "search" },
    last = { "problem", "contest" },
}

-- Third-level completions: `:Tuna run interactive <Tab>` offers its input sources.
local interactive_sources = { "auto", "live", "feed", "interactor" }

-- Run modes selectable via `:Tuna run <mode>` and the menu. Kept as a set for
-- quick "is this arg a mode keyword?" checks.
local MODE_SET = {}
for _, m in ipairs(tools.MODES) do
    MODE_SET[m] = true
end
MODE_SET.auto = true

--------------------------------------------------------------------------------
-- Testcase editing
--------------------------------------------------------------------------------

---Add a new testcase, or edit an existing one (via the editor, picking first if
---no number is given).
---@param add boolean add a fresh testcase instead of editing
---@param tcnum integer? testcase number to edit
function M.edit_testcase(add, tcnum)
    local bufnr = M.target_buffer()
    config.load_buffer_config(bufnr) -- refresh: a local config may have changed
    local tctbl = testcases.buf_get_testcases(bufnr)

    if add then
        tcnum = 0
        while tctbl[tcnum] do
            tcnum = tcnum + 1
        end
        tctbl[tcnum] = { input = "", output = "" }
    end

    local function start_editor(n)
        if not tctbl[n] then
            utils.notify("testcase edit: testcase " .. tostring(n) .. " doesn't exist.")
            return
        end
        local function save(tc)
            testcases.buf_save_testcase(bufnr, n, tc.input, tc.output)
        end
        local widgets = require("tuna.widgets")
        widgets.editor(bufnr, n, tctbl[n].input, tctbl[n].output, save, api.nvim_get_current_win())
    end

    if tcnum then
        start_editor(tcnum)
    else
        require("tuna.widgets").picker(bufnr, tctbl, "Edit a Testcase", start_editor, api.nvim_get_current_win())
    end
end

---Delete a testcase (picking first if no number is given).
---@param tcnum integer?
function M.delete_testcase(tcnum)
    local bufnr = M.target_buffer()
    config.load_buffer_config(bufnr)
    local tctbl = testcases.buf_get_testcases(bufnr)

    local function delete(n)
        if not tctbl[n] then
            utils.notify("testcase delete: testcase " .. tostring(n) .. " doesn't exist.")
            return
        end
        -- A float like every other tuna prompt, not `vim.fn.confirm`: a command-line
        -- question in the middle of a floating UI is exactly what the download path
        -- stopped doing.
        require("tuna.widgets").menu({ "Delete", "Keep" }, "delete testcase " .. n .. "?", function(idx)
            if idx == 1 then
                testcases.buf_delete_testcase(bufnr, n)
            end
        end, api.nvim_get_current_win())
    end

    if tcnum then
        delete(tcnum)
    else
        require("tuna.widgets").picker(bufnr, tctbl, "Delete a Testcase", delete, api.nvim_get_current_win())
    end
end

---Lift the cases a testcase's markers bracket out into testcases of their own.
---
---`sep` defaults to `testcases_split_markers`, so the common form is just
---`:Tuna testcase split 0`. Markers come in pairs and what they bracket is the user's
---call — see `testcases.split_testcase` for why nothing can infer it.
---@param tcnum integer? testcase to split
---@param sep string? marker character
function M.split_testcase(tcnum, sep)
    local bufnr = M.target_buffer()
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    sep = (sep and sep ~= "") and sep or cfg.testcases_split_markers

    -- With one testcase there is nothing to choose between, so `:Tuna testcase split`
    -- means that one. With several, ask the way `edit`/`delete` ask.
    if not tcnum then
        local tctbl = testcases.buf_get_testcases(bufnr)
        local nums = vim.tbl_keys(tctbl)
        if #nums == 0 then
            utils.notify("testcase split: there are no testcases to split.")
            return
        end
        if #nums > 1 then
            require("tuna.widgets").picker(bufnr, tctbl, "Split a Testcase", function(n)
                M.split_testcase(n, sep)
            end, api.nvim_get_current_win())
            return
        end
        tcnum = nums[1]
    end

    -- Read before the split, since the split rewrites it: whether the count offer is
    -- made at all depends on how the testcase looked going in.
    local before = (testcases.buf_get_testcases(bufnr)[tcnum] or {}).input

    local numbers, err, summary = testcases.buf_split_testcase(bufnr, tcnum, sep)
    if not numbers then
        utils.notify("testcase split: " .. err .. ".")
        return
    end
    utils.notify(summary .. ".", "INFO")
    testcases.offer_case_counts(bufnr, numbers, before)
end

---Convert this buffer's testcases to any of the three storage backends.
---@param target string "files" | "single_file" | "directory"
function M.convert_testcases(target)
    if not testcases.backends[target] then
        utils.notify("convert: unknown storage '" .. tostring(target) .. "'. Use files | single_file | directory.")
        return
    end
    local bufnr = M.target_buffer()
    config.load_buffer_config(bufnr)
    -- buf_get_testcases auto-detects whichever backend currently holds them.
    local tctbl = testcases.buf_get_testcases(bufnr)
    if next(tctbl) == nil then
        utils.notify("convert: there's nothing to convert.")
        return
    end

    -- Clear every backend's on-disk storage, then write to the target one.
    for _, backend in pairs(testcases.backends) do
        backend.buf_clear(bufnr)
    end
    testcases.buf_write_testcases(bufnr, tctbl, target)
    utils.notify("converted testcases to '" .. target .. "' storage.", "INFO")
end

--------------------------------------------------------------------------------
-- Running
--------------------------------------------------------------------------------

---Runners kept per buffer so re-runs and `show_ui` reuse the same state.
---@type table<integer, tuna.TCRunner>
M.runners = {}

---The mode each buffer was last run in, so `show_ui` re-opens the matching UI
---(e.g. the stress runner's, not a fresh normal one).
---@type table<integer, string>
M.last_mode = {}

---Resolve the buffer a run should target — redirecting a helper buffer (e.g.
---`checker.cpp`) to the solution beside it. Notifies and returns nil on failure.
---@return integer? bufnr, string? mode label of the resolved buffer's active mode
function M.solution_bufnr()
    local bufnr = M.target_buffer()
    config.load_buffer_config(bufnr)
    local target, note = tools.solution_bufnr(bufnr, config.get_buffer_config(bufnr))
    if not target then
        utils.notify("run: " .. tostring(note))
        return nil
    end
    if note then
        utils.notify(note, "INFO")
    end
    return target
end

---Run testcases (or a subset), and show the results UI.
---@param bufnr integer the solution buffer to run
---@param list string[]? testcase numbers to run, or nil for all
---@param compile boolean compile before running
---@param only_show boolean just (re)open the UI without running
function M.run_testcases(bufnr, list, compile, only_show)
    config.load_buffer_config(bufnr)
    local tctbl = testcases.buf_get_testcases(bufnr)

    -- The cached runner keeps the commands/dirs/checker resolved when it was built,
    -- while the line above re-reads the config, so an edited `.tuna.lua` would change
    -- which testcases are found but not how they are run. If the config changed, drop
    -- the runner: the results it holds describe runs under settings that no longer apply.
    local cached = M.runners[bufnr]
    -- Kept when only showing a runner that holds unsaved edits: they would go with it, and
    -- a run asks about them before getting here (`settle_results`).
    local holds_edits = only_show and cached and cached.ui and cached.ui:has_pending()
    if cached and not holds_edits and not vim.deep_equal(cached.config, config.get_buffer_config(bufnr)) then
        cached:delete_ui()
        M.runners[bufnr] = nil
    end

    if list then
        local subset = {}
        for _, s in ipairs(list) do
            local n = tonumber(s)
            if not n or not tctbl[n] then
                utils.notify("run: testcase " .. s .. " doesn't exist.")
            else
                subset[n] = tctbl[n]
            end
        end
        -- Named testcases, none of which exist: each was reported above, and there is
        -- nothing left to run. Returning here keeps it out of the bare-run path below,
        -- which runs the program on empty stdin — right for "run this file", wrong as
        -- the answer to "run testcase 5" when testcase 5 is missing.
        if next(subset) == nil then
            return
        end
        tctbl = subset
    end

    if not M.runners[bufnr] then
        local r = runner.new(bufnr)
        if not r then
            return -- runner.new already notified
        end
        M.runners[bufnr] = r
        -- Drop the runner when its buffer unloads.
        api.nvim_create_autocmd("BufUnload", {
            buffer = bufnr,
            callback = function()
                M.runners[bufnr] = nil
            end,
        })
    end

    local r = M.runners[bufnr]
    if only_show then
        -- Opening the UI without a run: show the testcases themselves (inputs and
        -- expected outputs, reviewable in the detail panes) rather than an empty
        -- window. Only when there is nothing to show yet — a runner that has already
        -- run keeps its results.
        if #r.tcdata == 0 or r.preloaded then
            -- No testcases is not nothing to show: `build_rows` lists the same `No input`
            -- row a run with nothing to test would build, so the UI opens on an editable
            -- testcase 0 waiting to be typed into rather than on a warning. That is the
            -- way in to writing a problem's first testcase from the results UI.
            r:load_testcases(tctbl)
        end
    else
        r:kill_all_processes()
        r:choose_row_again()
        r:run_testcases(tctbl, compile)
    end
    r:show_ui()
end

---Run a buffer in a given mode (dispatching to the right engine).
---@param mode string "normal" | "all" | "stress" | "interactive"
---@param args string[] mode arguments (testcase numbers, or a stress count)
---@param compile boolean compile before running (normal mode only)
---@param bufnr integer
function M.dispatch_mode(mode, args, compile, bufnr)
    M.settle_results(bufnr, { run = true, keep = mode == "normal" and M.runners[bufnr] or nil }, function()
        M.last_mode[bufnr] = mode
        if mode == "all" then
            require("tuna.multi").run(bufnr)
        elseif mode == "stress" then
            require("tuna.stress").run(bufnr, tonumber(args[1]))
        elseif mode == "interactive" then
            require("tuna.interactive").run(bufnr, #args > 0 and args or nil)
        else -- "normal"
            M.run_testcases(bufnr, #args > 0 and args or nil, compile, false)
        end
    end)
end

---Every runner a buffer has, whichever run mode built it. A mode module is only looked
---at when it is already loaded: a mode that never ran has no runner.
---@param bufnr integer
---@return table[]
local function runners_of(bufnr)
    local list = {}
    if M.runners[bufnr] then
        list[#list + 1] = M.runners[bufnr]
    end
    for _, mod in ipairs({ "tuna.interactive", "tuna.stress", "tuna.multi" }) do
        local m = package.loaded[mod]
        if m and m.active and m.active[bufnr] then
            list[#list + 1] = m.active[bufnr]
        end
    end
    return list
end

---The buffer a `:Tuna` command is about. Standing in one of tuna's own windows — a results
---pane, its viewer — that is the solution the pane is showing: a pane is not a file, so a
---command acting on it would compile nothing, save nothing, and keep the problem's run state
---under a name that is not a path. Every other buffer is itself, including a helper file,
---which each run resolves for itself (`tools.solution_bufnr`).
---@param bufnr integer? defaults to the current buffer
---@return integer
function M.target_buffer(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    local owner = require("tuna.runner_ui").owner_of(bufnr)
    return owner and owner.bufnr or bufnr
end

---Settle a buffer's results UIs before `proceed` puts one on screen. One results UI per
---buffer is shown at a time, so every other one is hidden, its unsaved edits kept on the
---runner that holds them.
---
---Before a **run** (`opts.run`) two more things hold. An unwritten testcase edit is asked
---about first (`Save and run` / `Discard and run` / `Keep editing`), because a run replaces
---the rows the edit lives in, and interactive, stress and run-all replace the whole runner.
---And the buffer's other runs are stopped, since one mode runs at a time: a live session
---left behind would wait on its input forever, and a stress search keeps rebuilding the
---binary the new run executes.
---@param bufnr integer
---@param opts { run: boolean?, keep: table? } `keep`: the runner `proceed` shows, left on screen
---@param proceed fun()
function M.settle_results(bufnr, opts, proceed)
    local runners = runners_of(bufnr)
    if opts.run then
        for _, r in ipairs(runners) do
            local ui = r.ui
            if ui and ui:has_pending() then
                if not ui.ui_visible then
                    r:show_ui()
                end
                ui:with_pending_settled(nil, "run", function()
                    M.settle_results(bufnr, opts, proceed)
                end, true)
                return
            end
        end
        for _, r in ipairs(runners) do
            r:kill_all_processes()
        end
    end
    for _, r in ipairs(runners) do
        if r ~= opts.keep and r.ui and r.ui.ui_visible then
            r.ui:delete()
        end
    end
    proceed()
end

---(Re)open the results UI for a buffer without running — honouring the last run's
---mode, so a stress run re-opens its own UI rather than a fresh normal one.
---@param bufnr integer
function M.show_results_ui(bufnr)
    -- The mode last run in this session, else the one the problem is set to: after a
    -- restart nothing has run, and the sidecar still says how this problem is run.
    config.load_buffer_config(bufnr)
    local path = api.nvim_buf_get_name(bufnr)
    local mode = M.last_mode[bufnr]
        or (tools.resolve_mode(path, config.get_buffer_config(bufnr)))
    local mod = (mode == "stress" and "tuna.stress")
        or (mode == "interactive" and "tuna.interactive")
        or (mode == "all" and "tuna.multi")
    local active = mod and require(mod).active[bufnr] or nil
    local keep = active or (not mod and M.runners[bufnr]) or nil
    M.settle_results(bufnr, { keep = keep }, function()
        M.last_mode[bufnr] = mode
        if active then
            active:show_ui()
        elseif mod then
            -- No runner of that mode yet: its UI opens with the rows listed and nothing
            -- run, as the normal runner's does, and the run keys start it.
            require(mod).show(bufnr)
        else
            M.run_testcases(bufnr, nil, false, true)
        end
    end)
end

---Handle `:Tuna run [mode] [args]`. A leading mode keyword forces that mode (it sticks)
---and runs it, `auto` makes the mode automatic again. Without one the resolved mode runs:
---the forced one while it can run, else the one the problem's helpers point to.
---@param args string[] the arguments after `run`
function M.run_mode(args)
    local bufnr = M.solution_bufnr()
    if not bufnr then
        return
    end
    local path = api.nvim_buf_get_name(bufnr)
    local mode, note
    if args[1] and MODE_SET[args[1]] then
        local chosen = table.remove(args, 1)
        tools.set_mode(path, chosen ~= "auto" and chosen or nil)
        mode = chosen ~= "auto" and chosen or nil
    end
    if not mode then
        mode, note = tools.resolve_mode(path, config.get_buffer_config(bufnr))
    end
    if note then
        utils.notify("run: " .. note .. ".", "INFO")
    end
    M.dispatch_mode(mode, args, true, bufnr)
end

---Set a problem's checker to automatic or off, or flip between the two. Every run looks
---the checker up, so it applies to the next run of any mode, and an open results UI shows
---the new judge straight away.
---@param bufnr integer
---@param want "auto"|"off"|nil nil flips the current setting
function M.set_checker(bufnr, want)
    local path = api.nvim_buf_get_name(bufnr)
    if want == nil then
        want = tools.checker_setting(path) == "off" and "auto" or "off"
    end
    tools.set_checker(path, want)
    local cfg = config.get_buffer_config(bufnr)
    local checker = tools.resolve_checker(path, cfg)
    for _, r in ipairs(runners_of(bufnr)) do
        r.checker = checker
        r:update_ui()
    end
    if want == "off" then
        utils.notify("checker: off for this problem, comparing outputs.", "INFO")
    elseif type(checker) == "table" then
        local name = vim.fn.fnamemodify(checker.source or checker.exec, ":t")
        utils.notify("checker: automatic for this problem, using " .. name .. ".", "INFO")
    else
        utils.notify("checker: automatic for this problem, none found, comparing outputs.", "INFO")
    end
end

---Parse `:Tuna compare` args into a compare-method spec (or nil to clear the
---override back to the configured default). Notifies and returns false on a bad name.
---@param args string[] e.g. { "float", "1e-9" } or { "exact" } or { "default" }
---@return boolean ok, tuna.CompareSpec? method, boolean cleared
local function parse_compare(args)
    local name = args[1]
    if name == nil or name == "default" then
        return true, nil, true -- clear the override
    elseif name == "exact" or name == "squish" then
        return true, name, false
    elseif name == "float" then
        local tol = args[2] and tonumber(args[2]) or nil
        if args[2] and not tol then
            utils.notify("compare: '" .. args[2] .. "' is not a valid tolerance.")
            return false
        end
        return true, { "float", tol = tol or 1e-6 }, false
    end
    utils.notify("compare: unknown method '" .. tostring(name) .. "' (exact | squish | float [tol] | default).")
    return false
end

-- Order the menu's "Compare" entry cycles through (default = clear the override).
local COMPARE_CYCLE = { "default", "exact", "squish", "float" }

-- The float tolerance each buffer last asked for (`:Tuna compare float 1e-9`), so
-- cycling away from float and back does not silently reset it to 1e-6. Session-local
-- on purpose: the sidecar already persists the tolerance while float is *active*.
---@type table<string, number>
local last_float_tol = {}

---The cycle token naming the buffer's current compare override (or "default").
---@param path string
---@return string
local function compare_token(path)
    local cur = tools.get_compare(path)
    if cur == nil then
        return "default"
    elseif type(cur) == "table" then
        return cur[1]
    end
    return cur
end

---Advance the per-buffer compare method to the next one in `COMPARE_CYCLE` (used by
---the menu, where a click cycles rather than takes an argument).
---@param bufnr integer
function M.cycle_compare(bufnr)
    local path = api.nvim_buf_get_name(bufnr)
    local token = compare_token(path)
    local i = 1
    for k, t in ipairs(COMPARE_CYCLE) do
        if t == token then
            i = k
            break
        end
    end
    local next_token = COMPARE_CYCLE[i % #COMPARE_CYCLE + 1]
    local args = { next_token }
    if next_token == "float" and last_float_tol[path] then
        args[2] = tostring(last_float_tol[path]) -- come back to the tolerance last set
    end
    M.set_compare(bufnr, args)
end

---Set (or clear) the per-buffer output-compare override. Drops the cached runner so
---the next run re-resolves.
---@param bufnr integer
---@param args string[]
function M.set_compare(bufnr, args)
    local ok, method, cleared = parse_compare(args)
    if not ok then
        return
    end
    local path = api.nvim_buf_get_name(bufnr)
    if type(method) == "table" and method[1] == "float" then
        last_float_tol[path] = method.tol
    end
    tools.set_compare(path, method)
    M.runners[bufnr] = nil
    if cleared then
        utils.notify("compare method reset to config default for this buffer.", "INFO")
    else
        utils.notify(
            "compare method set to " .. require("tuna.compare").method_name(method) .. " for this buffer.",
            "INFO"
        )
    end
end

--------------------------------------------------------------------------------
-- Downloading
--------------------------------------------------------------------------------

---Drive the Competitive Companion listener.
---@param mode string "testcases" | "problem" | "contest" | "sync" | "persistently" | "status" | "stop"
function M.download(mode)
    local download = require("tuna.download")
    local err
    if mode == "sync" then
        -- A download that folds the `:Tuna temp` scratch into the problem it opens:
        -- `temp.sync` arms the merge and starts the download itself.
        require("tuna.temp").sync(M.target_buffer())
    elseif mode == "stop" then
        download.stop_downloading()
    elseif mode == "status" then
        download.show_status()
    elseif mode == "testcases" then
        local bufnr = M.target_buffer()
        config.load_buffer_config(bufnr)
        local cfg = config.get_buffer_config(bufnr)
        err = download.start_downloading("testcases", cfg.companion_port, cfg.download_print_message, cfg.download_print_message, bufnr, cfg)
    elseif mode == "problem" or mode == "contest" or mode == "persistently" then
        local cfg = config.load_local_config_and_extend(vim.fn.getcwd())
        err = download.start_downloading(mode, cfg.companion_port, cfg.download_print_message, cfg.download_print_message, nil, cfg)
    else
        err = "unrecognized mode '" .. tostring(mode) .. "'"
    end
    if err then
        utils.notify("download: " .. err)
    end
end

--------------------------------------------------------------------------------
-- Dispatch + completion
--------------------------------------------------------------------------------

---Subcommand handlers. Each receives the trailing argument list.
---@type table<string, fun(args: string[])>
M.subcommands = {
    -- `:Tuna testcase [add|edit|delete] [n]` — one subcommand per *subject*, with the
    -- verb as its argument, matching `run`/`download`/`convert` rather than spelling
    -- three separate commands whose shared noun the completion could not group.
    -- Bare `:Tuna testcase` is `edit`: it opens the picker, which is the one that shows
    -- what is there before asking you to choose.
    testcase = function(args)
        local mode = args[1]
        if mode == nil or mode == "edit" then
            M.edit_testcase(false, tonumber(args[2]))
        elseif mode == "add" then
            M.edit_testcase(true)
        elseif mode == "delete" then
            M.delete_testcase(tonumber(args[2]))
        elseif mode == "split" then
            -- `:Tuna testcase split -` — a first argument that is not a number is the
            -- marker, since the testcase it would otherwise name can be implied. Spelled
            -- out rather than with `and`/`or`: the middle value is nil whenever no marker
            -- was given, which collapses the expression onto the number.
            local n = tonumber(args[2])
            if n then
                M.split_testcase(n, args[3])
            else
                M.split_testcase(nil, args[2])
            end
        elseif tonumber(mode) then
            -- `:Tuna testcase 3` — a bare number is the testcase to edit, since that is
            -- what the bare form does.
            M.edit_testcase(false, tonumber(mode))
        else
            utils.notify("testcase: unknown mode '" .. tostring(mode) .. "' (add | edit | delete | split).")
        end
    end,
    convert = function(args)
        if not args[1] then
            utils.notify("convert: a target storage is required (files | single_file | directory).")
            return
        end
        M.convert_testcases(args[1])
    end,
    run = function(args)
        M.run_mode(args)
    end,
    run_no_compile = function(args)
        local bufnr = M.solution_bufnr()
        if bufnr then
            M.settle_results(bufnr, { run = true, keep = M.runners[bufnr] }, function()
                M.last_mode[bufnr] = "normal"
                M.run_testcases(bufnr, #args > 0 and args or nil, false, false)
            end)
        end
    end,
    show_ui = function()
        local bufnr = M.solution_bufnr()
        if bufnr then
            M.show_results_ui(bufnr)
        end
    end,
    download = function(args)
        if not args[1] then
            utils.notify(
                "download: a mode is required (testcases | problem | contest | sync | persistently | status | stop)."
            )
            return
        end
        M.download(args[1])
    end,
    checker = function(args)
        local want
        if args[1] == "auto" or args[1] == "off" then
            want = args[1]
        elseif args[1] ~= nil and args[1] ~= "toggle" then
            utils.notify("checker: use auto, off or toggle.", "WARN")
            return
        end
        local bufnr = M.solution_bufnr()
        if bufnr then
            M.set_checker(bufnr, want)
        end
    end,
    compare = function(args)
        local bufnr = M.solution_bufnr()
        if bufnr then
            M.set_compare(bufnr, args)
        end
    end,
    scaffold = function(args)
        if not args[1] then
            utils.notify("scaffold: a role is required, " .. table.concat(tools.ROLES, ", ") .. ".")
            return
        end
        require("tuna.scaffold").create(args[1], M.target_buffer(), args[2])
    end,
    submit = function(args)
        local bufnr = M.solution_bufnr()
        if not bufnr then
            return
        end
        if args[1] == "clear" then
            require("tuna.submit").clear(bufnr) -- dismiss the lualine verdict / cancel a running submit
        else
            require("tuna.submit").submit(bufnr)
        end
    end,
    clean = function()
        require("tuna.clean").clean(M.target_buffer())
    end,
    -- Contest navigation: step to the sibling problem directory either side of this
    -- one. Deliberately not routed through `solution_bufnr`, since navigating away
    -- from a helper file (say `gen.cpp`) is a perfectly reasonable thing to do.
    next = function()
        require("tuna.navigate").next(M.target_buffer())
    end,
    prev = function()
        require("tuna.navigate").prev(M.target_buffer())
    end,
    -- Back to what you were working on, across restarts: the solution itself, or the
    -- contest it belongs to. Both also move Neovim's directory there (`cd_command`),
    -- since coming back to a problem means working *in* it. Bare `:Tuna last` is the
    -- problem — the one reached for most often.
    last = function(args)
        local recent = require("tuna.recent")
        if args[1] == "contest" then
            recent.open_contest()
        else
            recent.open_problem()
        end
    end,
    -- Two ways into the snippet library, because two things happen in practice: you
    -- remember the file it is in, or you remember the snippet.
    lib = function(args)
        local library = require("tuna.library")
        local bufnr = M.target_buffer()
        if args[1] == "snippet" then
            library.pick(bufnr)
        elseif args[1] == "search" then
            library.search(bufnr) -- telescope, when installed
        else
            library.browse(bufnr)
        end
    end,
    -- The scratch itself. Folding it back into a real problem is a *download*
    -- (`:Tuna download sync`), since that is what it does — it downloads.
    temp = function()
        require("tuna.temp").start(M.target_buffer())
    end,
    menu = function()
        require("tuna.menu").open(M.target_buffer())
    end,
}

---Dispatch a parsed `:Tuna` argument list (subcommand + its arguments).
---@param args string[] the full fargs list (args[1] is the subcommand)
function M.execute(args)
    local sub = M.subcommands[args[1]]
    if not sub then
        utils.notify("unknown subcommand '" .. tostring(args[1]) .. "'.")
        return
    end
    sub({ unpack(args, 2) })
end

---Tab-completion for `:Tuna`: subcommand names, then per-subcommand arguments.
---@param arg_lead string the word being completed
---@param cmd_line string the whole command line so far
---@param cursor_pos integer cursor byte position in `cmd_line`
---@return string[]
function M.complete(arg_lead, cmd_line, cursor_pos)
    local prefix = cmd_line:sub(1, cursor_pos)
    local ending_space = prefix:sub(-1) == " "
    local words = vim.split(prefix, "%s+", { trimempty = true }) -- words[1] == "Tuna"
    local count = #words

    ---@type string[]
    local candidates
    if count == 1 or (count == 2 and not ending_space) then
        candidates = vim.tbl_keys(M.subcommands)
    elseif count == 2 or (count == 3 and not ending_space) then
        candidates = subcommand_args[words[2]] or {}
    elseif (count == 3 or (count == 4 and not ending_space)) and words[2] == "run" and words[3] == "interactive" then
        candidates = interactive_sources
    elseif (count == 3 or (count == 4 and not ending_space)) and words[2] == "scaffold" then
        -- The languages the role has a template in, so what is offered is what exists.
        candidates = vim.tbl_contains(tools.ROLES, words[3])
                and require("tuna.scaffold").languages(words[3], M.target_buffer())
            or {}
    elseif
        (count == 3 or (count == 4 and not ending_space))
        and words[2] == "testcase"
        and (words[3] == "edit" or words[3] == "delete" or words[3] == "split")
    then
        -- The numbers that actually exist, so `:Tuna testcase delete <Tab>` never
        -- offers one the next thing it says is "doesn't exist".
        candidates = {}
        local ok, tctbl = pcall(testcases.buf_get_testcases, M.target_buffer())
        if ok then
            for n in pairs(tctbl) do
                candidates[#candidates + 1] = tostring(n)
            end
            table.sort(candidates, function(a, b)
                return (tonumber(a) or 0) < (tonumber(b) or 0)
            end)
            return vim.tbl_filter(function(c)
                return c:sub(1, #arg_lead) == arg_lead
            end, candidates)
        end
    else
        return {}
    end

    table.sort(candidates)
    return vim.tbl_filter(function(c)
        return c:sub(1, #arg_lead) == arg_lead
    end, candidates)
end

return M
