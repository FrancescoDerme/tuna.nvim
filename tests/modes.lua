-- tests/modes.lua
--
-- How a problem is run, as one rule for every helper and every setting. A helper
-- (checker, generator, reference, interactor) is available when it is configured or a
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
for _, role in ipairs({ "checker", "generator", "reference", "interactor" }) do
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
local configured_stress = { stress = { generator = helpers .. "/g.py", reference = helpers .. "/b.py" } }

t.eq("nothing: normal", mode_of({}), "normal")
t.eq("a checker alone changes no mode", mode_of({ "checker.py" }), "normal")
t.eq("a generator alone changes no mode", mode_of({ "gen.py" }), "normal")
t.eq("a generator and a reference: stress", mode_of({ "gen.py", "brute.py" }), "stress")
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
t.eq("a forced stress without its reference gives way to the automatic mode", m, "normal")
t.ok("and says so", mnote ~= nil)
t.write(sdir, "brute.py", "print()\n")
t.eq("it applies again once the reference is back", { tools.resolve_mode(ssol, cfg) }, { "stress" })
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

local ldir, lsol = problem()
t.write(ldir, ".tuna.json", vim.json.encode({ run = { ["sol.py"] = { mode = "interactive", explicit = true, checker = false, source = "feed" } } }))
t.eq("a stored forced mode, source and checker read back", { tools.get_mode(lsol), tools.get_source(lsol), tools.checker_setting(lsol) }, { "interactive", "feed", "off" })
local l2dir, l2sol = problem()
t.write(l2dir, ".tuna.json", vim.json.encode({ run = { ["sol.py"] = { mode = "normal", explicit = false, checker = true } } }))
t.eq("an entry that forced nothing reads as automatic", { tools.get_mode(l2sol), tools.checker_setting(l2sol) }, { nil, "auto" })

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

local rdir, rsol = problem({ "checker.py" })
local rbuf = open(rsol)
local r = require("tuna.runner").new(rbuf)
t.eq("a runner starts with the checker beside the solution", type(r.checker), "table")
os.remove(rdir .. "/checker.py")
r:run_testcases({ [0] = { input = "1\n", output = "1\n" } }, false)
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

-- A rerun keeps its mode, so a helper that mode needs being gone is said, and nothing runs.
local function rerun_after_deleting(open_mode, file)
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
    local said
    runner_of.ui.show_message = function(_, title, text)
        said = title .. text
    end
    os.remove(dir .. "/" .. file)
    runner_of:run_testcases()
    settle(300)
    runner_of:kill_all_processes()
    runner_of:delete_ui()
    return said, runner_of
end
local said, ir = rerun_after_deleting("interactive", "interactor.py")
t.ok("an interactor rerun with the interactor gone says so", said ~= nil and said:find("no interactor") ~= nil, said)
t.eq("and runs no session", ir.sol_handle, nil)
local ssaid, sr = rerun_after_deleting("stress", "brute.py")
t.ok("a stress restart with its reference gone says so", ssaid ~= nil and ssaid:find("reference") ~= nil, ssaid)
t.eq("and searches nothing", sr.iter, 0)

vim.system = real_system
t.report()
