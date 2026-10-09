-- tests/modes.lua
--
-- How a problem is run, as one rule for every helper and every setting. A helper
-- (checker, generator, bruteforce, interactor) is available when it is configured or a
-- sibling file names it. Each run setting (mode, interactive source, checker) is automatic
-- until forced, and a forced setting that needs a missing helper gives way to the
-- automatic choice until the helper is back. Every run looks its helpers up again.

local t = dofile("tests/harness.lua")
require("tuna").setup({})
local tools = require("tuna.tools")
local cfg = require("tuna.config").current_setup
local function with(extra)
    return vim.tbl_deep_extend("force", cfg, extra)
end

local function problem(files)
    local dir = t.tempdir()
    t.write(dir, "sol.py", "print(input())\n")
    for _, f in ipairs(files or {}) do
        t.write(dir, f, "print()\n")
    end
    return dir, dir .. "/sol.py"
end

--------------------------------------------------------------------------------
-- Which helpers are available
--------------------------------------------------------------------------------

local _, all = problem({ "checker.py", "gen.py", "brute.py", "interactor.py" })
for _, role in ipairs({ "checker", "generator", "bruteforce", "interactor" }) do
    t.ok("a sibling file is the " .. role, tools.helper(role, all, cfg) ~= nil)
end
local _, bare = problem()
t.eq("no file and nothing configured is no helper, and nothing to report", { tools.helper("checker", bare, cfg) }, {})

local own = t.tempdir()
t.write(own, "mine.py", "print()\n")
local spec = tools.helper("checker", bare, with({ checker = own .. "/mine.py" }))
t.eq("a configured path is used", spec and spec.source, vim.fn.fnamemodify(own .. "/mine.py", ":p"))
local gone, note = tools.helper("checker", all, with({ checker = own .. "/nope.py" }))
t.eq("a configured path that does not exist is no helper, a sibling file notwithstanding", gone, nil)
t.ok("and says why", note ~= nil and note:find("does not exist") ~= nil, note)
local cmd = tools.helper("interactor", bare, with({ interactive = { interactor = { exec = "python3", args = { "$(ABSDIR)/i.py", "$(INPUT)" } } } }))
t.eq(
    "a configured command expands file modifiers and keeps the per-run placeholders",
    cmd and cmd.args,
    { vim.fn.fnamemodify(bare, ":p:h") .. "/i.py", "$(INPUT)" }
)
-- A command given no arguments is handed its role's, as a helper file is; one given some has
-- placed them itself.
local plain = tools.helper("checker", bare, with({ checker = { exec = "python3" } }))
t.eq("a configured checker command with no arguments gets the testlib ones", plain and plain.args, { "$(INPUT)", "$(OUTPUT)", "$(ANSWER)" })
local plain_gen = tools.helper("generator", bare, with({ stress = { generator = { exec = "python3" } } }))
t.eq("and a role that takes none gets none", plain_gen and plain_gen.args, {})
local _, cannot = tools.helper("generator", bare, with({ stress = { generator = { exec = "no-such-program-tuna" } } }))
t.ok("a configured command that can't run says so", cannot ~= nil and cannot:find("can't be run") ~= nil, cannot)

--------------------------------------------------------------------------------
-- The automatic mode
--------------------------------------------------------------------------------

local function mode_of(files, extra)
    local _, sol = problem(files)
    return (tools.resolve_mode(sol, extra and with(extra) or cfg))
end
local helpers = t.tempdir()
t.write(helpers, "g.py", "print(1)\n")
t.write(helpers, "b.py", "print(1)\n")
local configured_stress = { stress = { generator = helpers .. "/g.py", bruteforce = helpers .. "/b.py" } }

t.eq("nothing: normal", mode_of({}), "normal")
t.eq("a checker alone changes no mode", mode_of({ "checker.py" }), "normal")
t.eq("a generator alone changes no mode", mode_of({ "gen.py" }), "normal")
t.eq("a generator and a bruteforce: stress", mode_of({ "gen.py", "brute.py" }), "stress")
t.eq("an interactor: interactive, ahead of stress", mode_of({ "gen.py", "brute.py", "interactor.py" }), "interactive")
t.eq("configured helpers count the same as files", mode_of({}, configured_stress), "stress")

--------------------------------------------------------------------------------
-- Forcing, and making automatic again
--------------------------------------------------------------------------------

local _, fsol = problem({ "interactor.py" })
tools.set_mode(fsol, "normal")
t.eq("a forced mode wins over the helpers", { tools.resolve_mode(fsol, cfg) }, { "normal" })
tools.set_mode(fsol, nil)
t.eq("made automatic again, the helpers decide", (tools.resolve_mode(fsol, cfg)), "interactive")
t.eq("and nothing is left stored", require("tuna.sidecar").get_entry(fsol, "run"), nil)

--------------------------------------------------------------------------------
-- A forced setting gives way while what it needs is missing
--------------------------------------------------------------------------------

local sdir, ssol = problem({ "gen.py", "brute.py" })
tools.set_mode(ssol, "stress")
os.remove(sdir .. "/brute.py")
local m, mnote = tools.resolve_mode(ssol, cfg)
t.eq("a forced stress without its bruteforce gives way to the automatic mode", m, "normal")
t.ok("and says so", mnote ~= nil)
t.write(sdir, "brute.py", "print()\n")
t.eq("it applies again once the bruteforce is back", { tools.resolve_mode(ssol, cfg) }, { "stress" })
local _, csol = problem()
tools.set_mode(csol, "stress")
t.eq("a forced stress with configured helpers runs", (tools.resolve_mode(csol, with(configured_stress))), "stress")

local idir, isol = problem({ "interactor.py" })
t.eq("automatic source: the interactor when there is one", (tools.resolve_source(isol, cfg)), "interactor")
tools.set_source(isol, "interactor")
os.remove(idir .. "/interactor.py")
local src, snote = tools.resolve_source(isol, cfg)
t.eq("a forced interactor source with no interactor gives way to live", { src, snote ~= nil }, { "live", true })
t.write(idir, "interactor.py", "print()\n")
t.eq("it applies again once the interactor is back", { tools.resolve_source(isol, cfg) }, { "interactor" })
tools.set_source(isol, "feed")
t.eq("a forced source that needs nothing always runs", (tools.resolve_source(isol, cfg)), "feed")

local cdir, chsol = problem({ "checker.py" })
t.eq("automatic checker: the one beside the solution", type(tools.resolve_checker(chsol, cfg)), "table")
tools.set_checker(chsol, "off")
t.eq("forced off: plain comparison", tools.resolve_checker(chsol, cfg), "builtin")
tools.set_checker(chsol, "auto")
os.remove(cdir .. "/checker.py")
t.eq("automatic with none: plain comparison", tools.resolve_checker(chsol, cfg), "builtin")

--------------------------------------------------------------------------------
-- What an existing sidecar says
--------------------------------------------------------------------------------

-- Read back, and validated on the way in: the file is a user's to edit.
local ldir, lsol = problem()
t.write(ldir, ".tuna.json", vim.json.encode({ run = { ["sol.py"] = { mode = "interactive", checker = "off", source = "feed" } } }))
t.eq("a stored forced mode, source and checker read back", { tools.get_mode(lsol), tools.get_source(lsol), tools.checker_setting(lsol) }, { "interactive", "feed", "off" })
local l2dir, l2sol = problem()
t.write(l2dir, ".tuna.json", vim.json.encode({ run = { ["sol.py"] = { mode = "sideways", source = "nobody", checker = true } } }))
t.eq("a setting that means nothing reads as automatic", { tools.get_mode(l2sol), tools.get_source(l2sol), tools.checker_setting(l2sol) }, { nil, nil, "auto" })

--------------------------------------------------------------------------------
-- Every run looks its helpers up again
--------------------------------------------------------------------------------

local real_system = vim.system
vim.system = function(_, _, on_exit)
    if on_exit then
        vim.schedule(function()
            on_exit({ code = 0, signal = 0, stdout = "", stderr = "" })
        end)
    end
    return { kill = function() end, wait = function() return { code = 0 } end, pid = 0, is_closing = function() return false end }
end
local function settle(ms)
    vim.wait(ms or 200, function()
        return false
    end)
end
local function open(sol)
    vim.cmd("edit " .. sol)
    vim.bo.filetype = "python"
    return vim.api.nvim_get_current_buf()
end

-- `:Tuna checker` and `:Tuna compare` change only when the new value is named (`off` forces
-- the checker, `auto` hands it back), and bare they say how they are set, changing nothing.
do
    local _, ksol = problem({ "checker.py" })
    open(ksol)
    local commands = require("tuna.commands")
    local function setting()
        return tools.checker_setting(ksol) == "off" and "off" or "auto"
    end
    local quiet = vim.notify
    local said = t.capture_notifications()
    local seen = {}
    for _, args in ipairs({ { "checker", "off" }, { "checker" }, { "checker", "auto" }, { "checker" }, { "checker", "toggle" } }) do
        commands.execute(args)
        seen[#seen + 1] = setting()
    end
    t.eq("off forces, auto hands back, and neither bare nor a word it does not know changes it", seen, { "off", "off", "auto", "auto", "auto" })
    t.eq("bare, it says how it is set", { said[2], said[4] }, {
        "Tuna: checker: off for this problem, comparing outputs.",
        "Tuna: checker: automatic for this problem, using checker.py.",
    })
    t.has("and the unknown word is answered", said[5], "use auto or off")
    t.eq("completion offers the two words", commands.complete("", "Tuna checker ", 13), { "auto", "off" })

    commands.execute({ "compare", "exact" })
    commands.execute({ "compare" })
    t.eq("bare compare leaves the method alone", tools.get_compare(ksol), "exact")
    t.eq("and says what it is", said[#said], "Tuna: compare: exact for this problem.")
    -- There is no word for "the configured one": naming the configured method is how a
    -- problem goes back to it, so a later change to the config reaches it.
    commands.execute({ "compare", "default" })
    t.has("default is not a method", said[#said], "unknown method 'default' (exact | squish | float [tol])")
    t.eq("and changes nothing", tools.get_compare(ksol), "exact")
    commands.execute({ "compare", "squish" })
    t.eq("naming the configured method keeps no override", tools.get_compare(ksol), nil)
    t.eq("and says so", said[#said], "Tuna: compare: squish, the configured method.")
    t.eq("completion offers the methods", commands.complete("", "Tuna compare ", 13), { "exact", "float", "squish" })

    -- Configured as float, a float with the configured tolerance is it, another is not.
    local fdir, fsol = problem({})
    t.write(fdir, ".tuna.lua", 'return { output_compare_method = { "float", tol = 1e-3 } }')
    open(fsol)
    commands.execute({ "compare", "float", "1e-9" })
    t.eq("a float of another tolerance is the problem's own", tools.get_compare(fsol), { "float", tol = 1e-9 })
    commands.execute({ "compare", "float", "1e-3" })
    t.eq("the configured one is no override", tools.get_compare(fsol), nil)

    -- A method of the user's own has a name (`compare_methods`), and is used by it like any
    -- other: offered, kept for the problem, and judged with.
    local cdir, csol = problem({})
    t.write(cdir, ".tuna.lua", "return { compare_methods = { lenient = function() return true end } }")
    local cbuf = open(csol)
    t.eq("a method of your own is offered by its name", commands.complete("", "Tuna compare ", 13), {
        "exact", "float", "lenient", "squish",
    })
    commands.execute({ "compare", "lenient" })
    t.eq("and kept for the problem by it", tools.get_compare(csol), "lenient")
    local cr = require("tuna.runner").new(cbuf)
    cr:refresh_judge(csol)
    t.eq("a run judges with it", require("tuna.compare").compare_output("a", "b", cr:effective_compare()), true)
    t.eq("and the Run pane names it", cr:judge_label(), "lenient")
    open(fsol)
    commands.execute({ "compare", "lenient" })
    t.has("where it is not defined it is no method", said[#said], "unknown method 'lenient'")

    -- The menu's "Compare:" entry steps through the methods from the one in use, and landing
    -- on the configured one hands the problem back to it.
    local kbuf = open(ksol)
    local cycled = {}
    for _ = 1, 3 do
        commands.cycle_compare(kbuf)
        cycled[#cycled + 1] = tools.get_compare(ksol) or "configured"
    end
    t.eq("the menu cycles from the configured method back to it", cycled, { { "float", tol = 1e-6 }, "exact", "configured" })
    vim.notify = quiet
end

local rdir, rsol = problem({ "checker.py" })
local rbuf = open(rsol)
local r = require("tuna.runner").new(rbuf)
r.cc = nil -- no build step: these runs are about the judge
t.eq("a runner starts with the checker beside the solution", type(r.checker), "table")
os.remove(rdir .. "/checker.py")
r:run_testcases({ [0] = { input = "1\n", output = "1\n" } })
settle()
t.eq("a run after the checker is deleted compares outputs", r.checker, "builtin")
t.write(rdir, "checker.py", "print()\n")
r:run_single(1)
settle()
t.eq("and a run after one is added uses it", type(r.checker), "table")

local mdir, msol = problem({ "checker.py" })
t.write(mdir, "sol_input0.txt", "1\n")
local mbuf = open(msol)
tools.set_checker(msol, "off")
require("tuna.multi").run(mbuf, { show_only = true })
local mr = require("tuna.multi").active[mbuf]
t.eq("run-all honours the checker forced off", mr and mr.checker, "builtin")
mr:delete_ui()

-- `:Tuna run auto` makes a forced mode automatic again.
local C = require("tuna.commands")
local kdir, ksol = problem({ "interactor.py" })
local kbuf = open(ksol)
C.execute({ "run", "normal" })
settle()
t.eq(":Tuna run normal forces normal", tools.get_mode(ksol), "normal")
C.settle_results(kbuf, { run = true }, function() end) -- back on the solution
vim.api.nvim_set_current_buf(kbuf)
C.execute({ "run", "auto" })
settle()
t.eq(":Tuna run auto makes the mode automatic", tools.get_mode(ksol), nil)
C.settle_results(kbuf, { run = true }, function() end)

-- A rerun keeps its mode, so a helper that mode needs being gone stops it, and nothing runs:
-- the run offers to write the missing starter instead, and Stop writes nothing.
local function rerun_after_deleting(open_mode, file, answer)
    local dir, sol = problem({ "interactor.py", "gen.py", "brute.py" })
    local buf = open(sol)
    local runner_of
    if open_mode == "interactive" then
        require("tuna.interactive").run(buf, { "interactor" }, { show_only = true })
        runner_of = require("tuna.interactive").active[buf]
    else
        require("tuna.stress").run(buf, nil, { show_only = true })
        runner_of = require("tuna.stress").active[buf]
    end
    local widgets = require("tuna.widgets")
    local menu, asked = widgets.menu, nil
    widgets.menu = function(items, title, on_choice)
        asked = { title = title, items = items }
        on_choice(answer or 2)
    end
    os.remove(dir .. "/" .. file)
    runner_of:run_testcases()
    settle(300)
    widgets.menu = menu
    -- What the answer left on screen, before this cleans the board up.
    local after = {
        board = runner_of.ui ~= nil and runner_of.ui.ui_visible,
        file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
        float = vim.api.nvim_win_get_config(0).relative ~= "",
    }
    runner_of:kill_all_processes()
    runner_of:delete_ui()
    return asked, runner_of, dir, after
end
local asked, ir, idir = rerun_after_deleting("interactive", "interactor.py")
t.eq("an interactor rerun with the interactor gone offers to write it", asked, {
    title = "The interactor source needs an interactor",
    items = { "Create interactor.py", "Stop" },
})
t.eq("and runs no session", ir.sol_handle, nil)
t.eq("stopping writes nothing", vim.fn.glob(idir .. "/interactor.*"), "")
local sasked, sr = rerun_after_deleting("stress", "brute.py")
t.eq("a stress restart with its bruteforce gone offers that one", sasked, {
    title = "Stress needs a bruteforce",
    items = { "Create brute.py", "Stop" },
})
t.eq("and searches nothing", sr.iter, 0)
-- Created from the board, the starter opens in the editor the board was over, not in a pane.
local _, _, _, after = rerun_after_deleting("stress", "gen.py", 1)
t.eq("a starter created from the board puts the board away", after.board, false)
t.eq("and opens in the editor window", { after.file, after.float }, { "gen.py", false })

-- A sidecar travels with a problem's folder, so a buffer that is not a file gets none:
-- `:Tuna run all` typed while standing in a results pane would otherwise write a `tuna:/`
-- tree wherever the editor was started.
local cwd = vim.fn.getcwd()
tools.set_mode("tuna://runner/7/tuna", "all")
t.eq("a buffer that is not a file gets no sidecar", vim.fn.isdirectory(cwd .. "/tuna:"), 0)
t.eq("and the forcing is still remembered for this session", tools.get_mode("tuna://runner/7/tuna"), "all")

--------------------------------------------------------------------------------
-- What the "Run" pane says about the settings
--------------------------------------------------------------------------------

-- Each fact on its own row: the mode alone, and whatever you forced named on a row of its
-- own, since a word appended to every value is what a narrow pane cuts off first.
local pdir, psol = problem({ "checker.py" })
local pbuf = open(psol)
local pr = require("tuna.runner").new(pbuf)
pr.cc = nil -- no build step: the Run pane is the subject
local ptcs = { [0] = { input = "1\n", output = "1\n" } }
pr:run_testcases(ptcs)
settle()
pr:show_ui()
local function status()
    return pr.ui:status_lines()
end
t.eq("nothing forced: the mode stands alone, and the row says so", status(), {
    "mode  : normal",
    "judge : checker.py",
    "forced: none",
    "diff  : off",
    "help  : ?",
})

tools.set_mode(psol, "normal")
pr:run_testcases(ptcs)
settle()
t.eq("a forced mode is named there, the mode row unchanged", { status()[1], status()[3] }, { "mode  : normal", "forced: mode" })

tools.set_checker(psol, "off")
pr:run_testcases(ptcs)
settle()
t.eq("a checker forced off forces the judge, which then reads as the comparison", { status()[2], status()[3] }, { "judge : squish", "forced: mode, judge" })

tools.set_mode(psol, nil)
tools.set_checker(psol, "auto")

-- The judge is looked up again by every run, the comparison override included, so this
-- reaches the runner that is already open.
tools.set_compare(psol, "exact")
os.remove(pdir .. "/checker.py")
pr:run_testcases(ptcs)
settle()
t.eq("an overridden comparison forces the judge on its own", { status()[2], status()[3] }, { "judge : exact", "forced: judge" })

tools.set_compare(psol, nil)
t.write(pdir, "checker.py", "print()\n")
pr:run_testcases(ptcs)
settle()
t.eq("handing it back, with a checker of its own, is no forcing", { status()[2], status()[3] }, { "judge : checker.py", "forced: none" })

-- An override the checker makes no use of is not what the judge row shows, so it forces
-- nothing: a checker is only ever found.
tools.set_compare(psol, "exact")
pr:run_testcases(ptcs)
settle()
t.eq("an override a checker overrules forces nothing", { status()[2], status()[3] }, { "judge : checker.py", "forced: none" })
tools.set_compare(psol, nil)

-- `:Tuna compare` reaches the board that is open before any run, and leaves the buffer its
-- runner: a board whose runner the buffer no longer knows is one no later run hides.
os.remove(pdir .. "/checker.py")
pr:run_testcases(ptcs)
settle()
local commands = require("tuna.commands")
commands.runners[pbuf] = pr
local quiet = vim.notify
vim.notify = function() end
commands.set_compare(pbuf, { "exact" })
t.eq("`:Tuna compare` shows on the open board at once", { status()[2], status()[3] }, { "judge : exact", "forced: judge" })
t.eq("and the buffer keeps the board's runner", commands.runners[pbuf], pr)
commands.set_compare(pbuf, { "squish" })
vim.notify = quiet
t.eq("and so does handing it back", { status()[2], status()[3] }, { "judge : squish", "forced: none" })
commands.runners[pbuf] = nil
pr.ui:delete()

-- A `.tuna.lua` is run again only when its text changes. Run again, every function in it is
-- a new one, so a buffer's config would never equal its cached runner's and every run would
-- build a new runner, and a new board.
do
    local commands = require("tuna.commands")
    local config = require("tuna.config")
    local ldir, lsol = problem({})
    t.write(ldir, "sol_input0.txt", "1\n")
    t.write(ldir, ".tuna.lua", "return { compare_methods = { lenient = function() return true end } }")
    local lbuf = open(lsol)
    t.eq("an unchanged .tuna.lua gives the same config", config.load_local_config(ldir), config.load_local_config(ldir))
    local runners = {}
    for i = 1, 2 do
        commands.run_testcases(lbuf, nil, false)
        settle()
        runners[i] = commands.runners[lbuf]
    end
    t.ok("so a function in it keeps the runner from one run to the next", runners[1] ~= nil and runners[1] == runners[2])
    local before = config.load_local_config(ldir)
    t.write(ldir, ".tuna.lua", "return { compare_methods = { lenient = function() return false end } }")
    t.ok("an edited one is run again", config.load_local_config(ldir) ~= before)
    commands.run_testcases(lbuf, nil, false)
    settle()
    t.ok("and the runner follows it", commands.runners[lbuf] ~= runners[2])
    commands.runners[lbuf]:delete_ui()
end

-- The interactive source is a setting like the others, so it is named the same way.
local _, vsol = problem({ "interactor.py" })
local vbuf = open(vsol)
tools.set_source(vsol, "live")
require("tuna.interactive").run(vbuf, {}, { show_only = true })
local vr = require("tuna.interactive").active[vbuf]
settle()
t.eq("the source sits under the judge, and is named on the forced row below it", vim.list_slice(vr.ui:status_lines(), 2, 4), {
    "judge : squish",
    "source: live",
    "forced: source",
})
vr:delete_ui()

vim.system = real_system
--------------------------------------------------------------------------------
-- A per-directory .tuna.lua that cannot be used
--------------------------------------------------------------------------------

-- A `.tuna.lua` that fails is ignored and said so, with the reason: one with an error in it
-- reports the error, which is the thing to go and fix, rather than being folded in with one
-- that merely returned something other than a table.
do
    local config = require("tuna.config")
    local said = {}
    local notify_before = vim.notify
    vim.notify = function(msg)
        said[#said + 1] = tostring(msg)
    end
    local broken = t.tempdir()
    t.write(broken, ".tuna.lua", "return { oops = \n")
    t.eq("a .tuna.lua with an error in it is ignored", config.load_local_config(broken), nil)
    t.has("and its error is what is said", said[1], "has an error, so it is ignored:")
    t.ok("with the error itself, file and line", (said[1] or ""):find("%.tuna%.lua:%d+:") ~= nil, said)
    said = {}
    local odd = t.tempdir()
    t.write(odd, ".tuna.lua", "return 42\n")
    t.eq("one that returns something else is ignored too", config.load_local_config(odd), nil)
    t.has("and says so", said[1], "did not return a table, so it is ignored.")
    vim.notify = notify_before
end

t.report()
