-- tests/runner.lua
--
-- A testcase may carry only an input or only an answer, and what a *row* holds has to
-- survive that. Two rules, both invisible until they are wrong:
--
--   * a missing input becomes an empty stdin, never `nil` — competitest crashed here,
--     the absent input going straight to the child and dying with "data must be string
--     or table of strings, got nil", so this checks the value at the point it is handed
--     to the process, not just at the point it is loaded;
--   * an empty answer is `nil`, so a testcase with nothing to be wrong about is not
--     judged against `""` and reported WRONG.
--
-- `vim.system` is stubbed, so no compiler is needed and nothing is really spawned: the
-- stub records what each child would have been given and reports a clean exit, which
-- is what lets the pipeline reach the testcase rows at all.

local t = dofile("tests/harness.lua")

local dir = t.tempdir()
t.write(dir, "sol.cpp", "int main(){}\n")
vim.cmd("edit " .. dir .. "/sol.cpp")
vim.bo.filetype = "cpp"
local buf = vim.api.nvim_get_current_buf()
require("tuna").setup({})

local tcs = require("tuna.testcases")

--------------------------------------------------------------------------------
-- The stub: record every spawn, answer it successfully.
--------------------------------------------------------------------------------

local spawns = {}
local real_system = vim.system
local function stub_system()
    spawns = {}
    vim.system = function(argv, opts, on_exit)
        spawns[#spawns + 1] = { argv = argv, stdin = opts and opts.stdin }
        if on_exit then
            vim.schedule(function()
                on_exit({ code = 0, signal = 0, stdout = "", stderr = "" })
            end)
        end
        return { kill = function() end, wait = function() return { code = 0 } end, pid = 0 }
    end
end

---Every child that is being *fed a testcase* got a string, whatever the testcase was
---missing. A compiler is spawned with no stdin at all, which is a different thing from
---a solution handed `nil` where its input should be, so the two are told apart by the
---command: `run_exec` is the resolved run command, everything else is a build.
local function check_spawns(what, run_exec)
    t.ok(what .. ": something was spawned", #spawns > 0, #spawns)
    local runs = 0
    for i, s in ipairs(spawns) do
        if s.argv[1] == run_exec then
            runs = runs + 1
            t.ok(
                ("%s: run %d was handed a string stdin"):format(what, i),
                type(s.stdin) == "string",
                { argv = s.argv, stdin = s.stdin }
            )
        end
    end
    t.ok(what .. ": a solution was actually run", runs > 0, spawns)
end

local FINAL = { CORRECT = true, WRONG = true, DONE = true, TIMEOUT = true, FAILED = true, CE = true }
local function settled(runner)
    vim.wait(5000, function()
        if not runner or not runner.tcdata or #runner.tcdata == 0 then
            return false
        end
        for _, r in ipairs(runner.tcdata) do
            if not (r.status and (FINAL[r.status] or r.status:match("^RET") or r.status:match("^%d+/%d+$"))) then
                return false
            end
        end
        return true
    end, 20)
end

--------------------------------------------------------------------------------
-- Rows built without running: `:Tuna show_ui` before any `:Tuna run`
--------------------------------------------------------------------------------

local function rows_of(tctbl)
    local r = require("tuna.runner").new(buf)
    r:load_testcases(tctbl, true)
    return r
end

-- An answer with no input: the row runs the solution against empty stdin.
local r = rows_of({ [0] = { output = "42\n" } })
t.eq("an answer-only testcase still becomes a row", r.tcdata[2] and r.tcdata[2].tcnum, 0)
t.eq("its stdin is the empty string, not nil", r.tcdata[2].stdin, "")
t.eq("and it keeps its answer", r.tcdata[2].expected, "42\n")

-- An input with no answer: there is nothing to judge against, which is a `nil`
-- expected output (the verdict is then DONE, not WRONG — see tests/compare.lua).
r = rows_of({ [0] = { input = "hi\n" } })
t.eq("an input-only testcase keeps its input", r.tcdata[2].stdin, "hi\n")
t.eq("and has no answer to be judged against", r.tcdata[2].expected, nil)

-- The compile row is a row like any other and has to hold a string too.
t.eq("the compile row's stdin is a string", r.tcdata[1].stdin, "")

--------------------------------------------------------------------------------
-- What reaches the process
--------------------------------------------------------------------------------

stub_system()
r = require("tuna.runner").new(buf)
r:run_testcases({ [0] = { output = "42\n" }, [1] = { input = "hi\n" } }, true)
settled(r)
vim.system = real_system
check_spawns("run", r.rc.exec)
t.ok("both testcases ran", #spawns >= 3, #spawns) -- compile + two testcases

--------------------------------------------------------------------------------
-- No testcases at all: the program still runs, on empty stdin
--------------------------------------------------------------------------------

-- Hitting run on a file with no testcases means "execute this". Without it the two
-- kinds of language disagreed: a compiled file built and showed a lone `Compile` row
-- with nothing to say why, an interpreted one only warned, and neither ran anything.
stub_system()
r = require("tuna.runner").new(buf)
r:run_testcases({}, true)
settled(r)
vim.system = real_system
t.eq("a run with nothing to test still builds a row for it", #r.tcdata, 2)
local bare = r.tcdata[2]
t.eq("its stdin is the empty string, not nil", bare.stdin, "")
t.eq("it has no answer, so it can never read CORRECT", bare.expected, nil)
-- It is testcase 0 and editable, which is what lets typing into the panes and `:w`
-- turn "just run it" into a stored testcase. `bare` is what says it has no file behind
-- it yet: the selector labels it `No input` until it does.
t.eq("the row is testcase 0", bare.tcnum, 0)
t.eq("and is editable, so it can be saved into one", r:row_editable(bare), true)
t.eq("it is flagged as having nothing behind it yet", bare.bare, true)
t.eq("and 0 is taken, so a further testcase is 1", r:next_tcnum(), 1)
check_spawns("bare run", r.rc.exec)

-- Saving it writes a real testcase and the row stops explaining itself.
r:save_testcase(0, "2 3\n", "5\n")
t.eq("saving writes the testcase to disk", tcs.buf_get_testcases(buf)[0], { input = "2 3\n", output = "5\n" })
t.eq("and the row is no longer bare", r.tcdata[2].bare, nil)
require("tuna.testcases").buf_delete_testcase(buf, 0)

--------------------------------------------------------------------------------
-- `:Tuna run all` builds the same rows for every solution
--------------------------------------------------------------------------------

t.write(dir, "out.txt", "42\n") -- an answer with no input, on disk
t.eq("it loads with no input", tcs.buf_get_testcases(buf)[0].input, nil)

local run_exec = require("tuna.runner").new(buf).rc.exec
stub_system()
require("tuna.multi").run(buf)
local mr = require("tuna.multi").active[buf]
settled(mr)
vim.system = real_system
t.ok("run all built a matrix", mr ~= nil and #mr.tcdata >= 2, mr and #mr.tcdata)
for _, row in ipairs(mr and mr.tcdata or {}) do
    if row.kind == "case" then
        t.eq("a run-all case row has a string stdin", type(row.stdin), "string")
    end
end
check_spawns("run all", run_exec)

--------------------------------------------------------------------------------
-- Stress and interactive build their rows from the same testcases
--------------------------------------------------------------------------------

-- Interactive replays a testcase's input, so an input-less one is exactly the case
-- that would hand `nil` to the solution.
stub_system()
require("tuna.interactive").run(buf, {})
local ir = require("tuna.interactive").active[buf]
vim.wait(300, function()
    return ir ~= nil and ir.tcdata ~= nil and #ir.tcdata > 0
end, 20)
vim.system = real_system
t.ok("interactive built rows", ir ~= nil and #ir.tcdata > 0, ir and ir.tcdata)
for _, row in ipairs(ir and ir.tcdata or {}) do
    t.eq("an interactive row has a string stdin", type(row.stdin), "string")
end

-- Interactive has no use for expected output: a sample exchange is one example of a
-- conversation, not the only correct one. So its grid drops Expected Output and the pane
-- you talk to the solution through takes that cell, titled for what it is here.
local iui = ir and ir.ui
t.ok("interactive opened its results UI", iui ~= nil and iui.ui_visible)
if iui then
    t.eq("expected output is not drawn in interactive mode", iui.windows.eo.winid, nil)
    local si, so, se = iui.windows.si, iui.windows.so, iui.windows.se
    t.ok("the live pane is drawn", si.winid ~= nil and vim.api.nvim_win_is_valid(si.winid))
    t.eq("and is titled Live", si.title, " Live ")
    local sc = vim.api.nvim_win_get_config(si.winid)
    t.eq("with that title on its border", sc.title and sc.title[1][1], " Live ")
    t.eq("in the accent, since live mode is typed into", sc.title and sc.title[1][2], "TunaEditableBorder")
    -- A mode that can't edit testcases still binds the keys that would, silently: left
    -- unbound, `n`/`N` fall through to Vim's search and raise "Pattern not found".
    local bound = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(iui.windows.tc.bufnr, "n")) do
        bound[m.lhs] = m.callback ~= nil
    end
    t.eq("n and N are bound where nothing can be added", { bound.n, bound.N }, { true, true })
    -- The conversation is laid out as columns beside the selector, Errors then Output then
    -- Live, each full height so a row of one faces the same row of the others.
    local function box(w)
        local c = vim.api.nvim_win_get_config(w.winid)
        return c.col, c.row, c.height
    end
    local tcol = box(iui.windows.tc)
    local ecol, erow, eh = box(se)
    local ocol, orow, oh = box(so)
    local lcol, lrow, lh = box(si)
    t.ok(
        "columns run selector, Errors, Output, Live",
        tcol < ecol and ecol < ocol and ocol < lcol,
        { tcol, ecol, ocol, lcol }
    )
    t.eq("each full height and level with the others", { erow, orow, eh, oh }, { lrow, lrow, lh, lh })

    -- What each side says lands on a row of its own in its own column, blank in the other
    -- two, and every column follows the latest line.
    vim.wait(500, function()
        return ir.completed
    end, 20)
    local row
    for i, r in ipairs(ir.tcdata) do
        if r.tcnum ~= "Compile" then
            row = r
            iui.update_testcase = i
        end
    end
    row.log = nil
    local conv = require("tuna.interactive")._test
    conv.log_append(row, "so", "hello\n")
    conv.log_append(row, "si", "hi\n")
    conv.log_append(row, "se", "oops\n")
    ir:update_ui(false)
    vim.wait(200, function()
        return false
    end)
    local function lines_of(name)
        return vim.api.nvim_buf_get_lines(iui.windows[name].bufnr, 0, -1, false)
    end
    t.eq("the columns are drawn line for line", { lines_of("se"), lines_of("so"), lines_of("si") }, {
        { "", "", "oops" },
        { "hello", "", "" },
        { "", "hi", "" },
    })
    t.eq("and follow the latest line", vim.api.nvim_win_get_cursor(so.winid)[1], 3)

    -- Live: what you send is Live's own row, never copied into Output, and the line being
    -- typed survives output landing under it. A stand-in pipe makes the session "live".
    for i, r in ipairs(ir.tcdata) do
        if r == row then
            ir.active_index = i
        end
    end
    ir.sol_in = {
        is_closing = function()
            return false
        end,
        write = function() end,
    }
    row.log = nil
    ir:live_send("42")
    t.eq("a sent line is Live's own row and nothing else's", row.log, { { col = "si", text = "42", open = false } })
    ir:update_ui(false)
    vim.wait(200, function()
        return false
    end)
    local sib = iui.windows.si.bufnr
    local last = vim.api.nvim_buf_line_count(sib)
    vim.api.nvim_buf_set_lines(sib, last - 1, last, false, { "typing" })
    conv.log_append(row, "so", "reply\n")
    ir:update_ui(false)
    vim.wait(200, function()
        return false
    end)
    t.eq("the line being typed survives output arriving under it", lines_of("si"), { "42", "", "typing" })
    t.eq("faced by a blank line in the other columns", lines_of("so"), { "", "reply", "" })
    ir.sol_in = nil

    -- Reading back through one column holds all three level with it, output landing or not.
    for k = 1, 80 do
        conv.log_append(row, "so", "line " .. k .. "\n")
    end
    ir:update_ui(false)
    vim.wait(200, function()
        return false
    end)
    local sow, sew = iui.windows.so.winid, iui.windows.se.winid
    local function top(win)
        return vim.api.nvim_win_call(win, vim.fn.winsaveview).topline
    end
    t.eq("a long conversation follows the latest line, level", top(sow) > 1 and top(sew) == top(sow), true)
    local back = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(sow)
    vim.api.nvim_feedkeys("gg", "x", false)
    t.eq("scrolling back in one column scrolls the others with it", top(sew), 1)
    conv.log_append(row, "se", "late\n")
    ir:update_ui(false)
    vim.wait(200, function()
        return false
    end)
    t.eq("and output landing meanwhile does not pull them away", { top(sow), top(sew) }, { 1, 1 })
    vim.api.nvim_set_current_win(back)
end

-- The grid follows the source. `feed` replays a stored testcase, so it keeps the canonical
-- Input and Expected Output panes and edits them like a normal run; `interactor` looks
-- like live, but nothing in it is typed into, so nothing wears the accent.
stub_system()
require("tuna.interactive").run(buf, { "feed" })
local fr = require("tuna.interactive").active[buf]
vim.wait(300, function()
    return fr ~= nil and fr.ui ~= nil and fr.ui.ui_visible
end, 20)
vim.system = real_system
local fui = fr and fr.ui
t.ok("feed opened its results UI", fui ~= nil and fui.ui_visible)
if fui then
    t.eq("feed edits testcases, like a normal run", fr.editable_testcases, true)
    local titles, accents = {}, {}
    for _, name in ipairs({ "si", "eo" }) do
        local w = fui.windows[name]
        local drawn = w.winid ~= nil and vim.api.nvim_win_is_valid(w.winid)
        t.ok(("feed draws %s"):format(name), drawn)
        if drawn then
            local c = vim.api.nvim_win_get_config(w.winid)
            titles[#titles + 1] = c.title and c.title[1][1]
            accents[#accents + 1] = c.title and c.title[1][2]
        end
    end
    t.eq("with their canonical titles", titles, { " Input ", " Expected Output " })
    t.eq("both in the accent", accents, { "TunaEditableBorder", "TunaEditableBorder" })
    -- Editable means `idle()` gates the structural edits, so a single re-run has to claim
    -- the runner for as long as its session runs, and give it back when it settles.
    vim.wait(500, function()
        return fr.completed
    end, 20)
    local idx
    for i, row in ipairs(fr.tcdata) do
        if row.tcnum == 0 then
            idx = i
        end
    end
    stub_system()
    fr:run_single(idx)
    t.eq("a single re-run claims the runner while its session runs", fr:idle(), false)
    vim.wait(500, function()
        return fr:idle()
    end, 20)
    vim.system = real_system
    t.eq("and gives it back once the session settles", fr:idle(), true)
    fui:delete()
end

-- A build that fails leaves nothing running, so the runner must say it is idle: left
-- claimed, every edit is refused with "wait for the run to finish" for good.
vim.system = function(_, _, on_exit)
    if on_exit then
        vim.schedule(function()
            on_exit({ code = 1, signal = 0, stdout = "", stderr = "error" })
        end)
    end
    return { kill = function() end, wait = function() return { code = 1 } end, pid = 0 }
end
require("tuna.interactive").run(buf, { "feed" })
local cr = require("tuna.interactive").active[buf]
vim.wait(500, function()
    return cr ~= nil and cr.compile_entry ~= nil and cr.compile_entry.exit_code == 1
end, 20)
vim.system = real_system
t.eq("a failed build leaves the runner idle, so edits are not locked out", cr and cr:idle(), true)
if cr and cr.ui then
    cr.ui:delete()
end

-- Feed's row for "no testcases" has nothing on disk *yet*, which is not a testcase that
-- went missing: flagged `bare` like the normal runner's, a re-run asks about nothing.
do
    local ndir = t.tempdir()
    t.write(ndir, "sol.cpp", "int main(){}\n")
    vim.cmd("edit " .. ndir .. "/sol.cpp")
    vim.bo.filetype = "cpp"
    local nbuf = vim.api.nvim_get_current_buf()
    stub_system()
    require("tuna.interactive").run(nbuf, { "feed" })
    local nr = require("tuna.interactive").active[nbuf]
    vim.wait(300, function()
        return nr ~= nil and nr.ui ~= nil and nr.ui.ui_visible
    end, 20)
    vim.system = real_system
    local row = nr and nr.tcdata[#nr.tcdata]
    t.eq("feed's no-testcase row is bare", row and row.bare, true)
    t.eq("so a re-run finds nothing missing", nr and nr.ui and (nr.ui:disk_drift()), {})
    if nr and nr.ui then
        nr.ui:delete()
    end
    vim.cmd("buffer " .. buf)
    vim.fn.delete(ndir, "rf")
end

t.write(dir, "interactor.cpp", "int main(){}\n")
stub_system()
require("tuna.interactive").run(buf, { "interactor" })
local xr = require("tuna.interactive").active[buf]
vim.wait(300, function()
    return xr ~= nil and xr.ui ~= nil and xr.ui.ui_visible
end, 20)
vim.system = real_system
local xui = xr and xr.ui
t.ok("interactor opened its results UI", xui ~= nil and xui.ui_visible)
if xui then
    t.eq("interactor does not edit testcases", xr.editable_testcases, false)
    t.eq("interactor draws no expected output", xui.windows.eo.winid, nil)
    local xc = vim.api.nvim_win_get_config(xui.windows.si.winid)
    t.eq("its conversation pane is titled Live", xc.title and xc.title[1][1], " Live ")
    t.ok("and wears no accent, since nothing is typed into it", not (xc.title and xc.title[1][2] == "TunaEditableBorder"), xc.title)
    xui:delete()
end
vim.fn.delete(dir .. "/interactor.cpp")

-- The title a mode gives a pane is drawn by the interface itself, not only patched on by
-- the accent pass afterwards: a pane that isn't accented (Live in feed mode) would
-- otherwise keep the default title on its border.
do
    local popup = require("tuna.runner_ui.popup")
    local wins = {}
    popup.init_ui(wins, require("tuna.config").current_setup, nil, 2, { titles = { si = " Live " } })
    local cfg = vim.api.nvim_win_get_config(wins.si.winid)
    t.eq("the interface draws a renamed pane's title", cfg.title and cfg.title[1][1], " Live ")
    t.eq("and records it for the viewer", wins.si.title, " Live ")
    t.eq("a pane nobody renamed keeps its own", wins.so.title, " Output ")
    for _, w in pairs(wins) do
        if w.winid and vim.api.nvim_win_is_valid(w.winid) then
            vim.api.nvim_win_close(w.winid, true)
        end
    end
end

-- The conversation itself: one row per thing said, owned by the column that said it.
do
    local conv = require("tuna.interactive")._test
    local tc = {}
    conv.log_append(tc, "so", "Guess: ")
    conv.log_append(tc, "so", "a number\n")
    t.eq("output arriving in pieces stays on one row", conv.conversation(tc.log).so, { "Guess: a number" })
    conv.log_append(tc, "si", "5\n")
    conv.log_append(tc, "so", "higher\nguess again\n")
    t.eq("each side writes on rows the other two leave blank", conv.conversation(tc.log), {
        so = { "Guess: a number", "", "higher", "guess again" },
        se = { "", "", "", "" },
        si = { "", "5", "", "" },
    })
    local open = {}
    conv.log_append(open, "so", "prompt> ")
    conv.log_append(open, "se", "warning\n")
    conv.log_append(open, "so", "still prompting\n")
    t.eq(
        "a row left open is not run into once another column has spoken",
        conv.conversation(open.log).so,
        { "prompt> ", "", "still prompting" }
    )
    local empty = {}
    conv.log_append(empty, "so", "")
    t.eq("an empty chunk says nothing", #(empty.log or {}), 0)
    local blank = {}
    conv.log_append(blank, "so", "\n")
    t.eq("a bare newline is an empty line of its own", conv.conversation(blank.log).so, { "" })
end

-- Stress needs a generator and a reference beside the solution to start at all.
t.write(dir, "gen.cpp", "int main(){}\n")
t.write(dir, "brute.cpp", "int main(){}\n")
stub_system()
require("tuna.stress").run(buf, 1)
local sr = require("tuna.stress").active[buf]
vim.wait(300, function()
    return sr ~= nil and sr.tcdata ~= nil and #sr.tcdata > 0
end, 20)
if sr then
    sr:kill_all_processes()
end
vim.system = real_system
t.ok("stress built rows", sr ~= nil and #sr.tcdata > 0, sr and sr.tcdata)
for _, row in ipairs(sr and sr.tcdata or {}) do
    t.eq("a stress row has a string stdin", type(row.stdin), "string")
end

--------------------------------------------------------------------------------
-- Running from a helper file must not leave a swapfile behind
--------------------------------------------------------------------------------

-- `:Tuna run` from a helper (you are editing `checker.cpp`) redirects to the sibling
-- solution, which means loading a buffer for a file the user never opened. Loading one
-- normally creates a swapfile, so that left a stray `.main.cpp.swp` in the problem
-- directory and an E325 ATTENTION prompt about it after a crash. The suite runs with
-- `noswapfile`, so this section turns it on for itself — without that it would pass
-- whatever the code did.
local sdir = t.tempdir()
vim.go.swapfile = true
vim.o.directory = sdir .. "//"

local function swap_for(name)
    for _, f in ipairs(vim.fn.glob(sdir .. "/*", false, true)) do
        if vim.fn.fnamemodify(f, ":t"):find(name, 1, true) then
            return true
        end
    end
    return false
end

local hdir = t.tempdir()
t.write(hdir, "main.cpp", "int main(){}\n")
t.write(hdir, "checker.cpp", "int main(){ return 0; }\n")
vim.cmd("edit " .. hdir .. "/checker.cpp")
vim.bo.filetype = "cpp"
local hbuf = vim.api.nvim_get_current_buf()
local tools = require("tuna.tools")
local sb = tools.solution_bufnr(hbuf, require("tuna.config").get_buffer_config(hbuf))

t.ok("the run redirects to the sibling solution", sb ~= nil and sb ~= hbuf, sb)
t.ok("which is loaded, so it can be written and its filetype read", vim.api.nvim_buf_is_loaded(sb))
t.ok("but no swapfile is left for a file the user never opened", not swap_for("main.cpp"))
t.ok("while the helper they did open keeps its own", swap_for("checker.cpp"))

-- Displaying it makes it theirs again, and the protection comes back.
vim.cmd("buffer " .. sb)
t.ok("opening it restores the swapfile", swap_for("main.cpp"))

vim.cmd("silent! %bwipeout!")
for _, f in ipairs(vim.fn.glob(sdir .. "/*", false, true)) do
    vim.fn.delete(f)
end

-- The other order: the solution is already open in the session when the run redirects
-- to it. That buffer is the user's, with a swapfile of its own, and the redirect must
-- leave it alone — turning the option off on a *loaded* buffer deletes the swap it
-- already has, which would take the protection away from a file they are editing.
vim.cmd("edit " .. hdir .. "/main.cpp")
vim.bo.filetype = "cpp"
t.ok("a solution the user opened has a swapfile", swap_for("main.cpp"))
vim.cmd("edit " .. hdir .. "/checker.cpp")
vim.bo.filetype = "cpp"
hbuf = vim.api.nvim_get_current_buf()
tools.solution_bufnr(hbuf, require("tuna.config").get_buffer_config(hbuf))
t.ok("and the redirect leaves it alone", swap_for("main.cpp"))

vim.cmd("silent! %bwipeout!")
vim.go.swapfile = false
vim.fn.delete(sdir, "rf")
vim.fn.delete(hdir, "rf")

--------------------------------------------------------------------------------
-- Where a run compiles and runs
--------------------------------------------------------------------------------

-- `compile_directory`/`running_directory` are relative to the source's directory, and
-- were joined onto it unconditionally: an absolute `/tmp/build` then became
-- `<source dir>/tmp/build` and a `~/build` a directory literally named `~`. The second
-- is visibly wrong; the first is worse, for looking as though it had worked.
local wdir = t.tempdir()
t.write(wdir, "sol.cpp", "int main(){}\n")
vim.cmd("edit " .. wdir .. "/sol.cpp")
vim.bo.filetype = "cpp"
local wbuf = vim.api.nvim_get_current_buf()
local function dirs(opts)
    require("tuna.config").setup(opts)
    require("tuna.config").load_buffer_config(wbuf)
    local r = require("tuna.runner").new(wbuf)
    return { compile = r.compile_directory, run = r.running_directory }
end
local wh = vim.uv.os_homedir()
t.eq("a relative directory is taken against the source", dirs({ compile_directory = "build", running_directory = "." }), {
    compile = wdir .. "/build/",
    run = wdir .. "/",
})
t.eq("an absolute one is used as it is", dirs({ compile_directory = "/tmp/build", running_directory = "/tmp/run" }), {
    compile = "/tmp/build/",
    run = "/tmp/run/",
})
t.eq("and a leading ~ is the home directory, not a folder called ~", dirs({
    compile_directory = "~/build",
    running_directory = "~/run",
}), { compile = wh .. "/build/", run = wh .. "/run/" })
require("tuna.config").setup({})
require("tuna.config").load_buffer_config(wbuf)
vim.cmd("silent! bwipeout!")
vim.fn.delete(wdir, "rf")

--------------------------------------------------------------------------------
-- Rows and the disk: what a row means when there is no file behind it
--------------------------------------------------------------------------------

local gdir = t.tempdir()
t.write(gdir, "sol.cpp", "int main(){}\n")
vim.cmd("edit " .. gdir .. "/sol.cpp")
vim.bo.filetype = "cpp"
local gbuf = vim.api.nvim_get_current_buf()
local gtcs = require("tuna.testcases")

-- A save stores what it is given, and stores the testcase even with nothing in it: an
-- empty testcase is a testcase. Removing one is `buf_delete_testcase` — one way in, and
-- an undoable one — so a save never leaves the row standing for something that is not
-- there, which is what `bare` would have to mean afterwards.
local gr = require("tuna.runner").new(gbuf)
gr:load_testcases({ [0] = { input = "x\n" } }, false)
gr:save_testcase(0, "x\n", "y\n")
t.eq("a save clears bare", gr.tcdata[1].bare, nil)
t.eq("and the testcase is on disk", gtcs.buf_get_testcases(gbuf)[0], { input = "x\n", output = "y\n" })
gr:save_testcase(0, "", "")
t.eq("an empty save stores an empty testcase", gtcs.buf_get_testcases(gbuf)[0] ~= nil, true)
t.eq("the row still has a file behind it", gr.tcdata[1].bare, nil)
t.eq("with nothing to feed the solution", gr.tcdata[1].stdin, "")
t.eq("and no answer, so it is not judged", gr.tcdata[1].expected, nil)

-- The answer is the one half a save cannot read off what it is given: an empty one is
-- absent (not judged) unless it is meant as "print nothing", which is what the single
-- prompt asks and `expect_empty_output` carries.
gr:save_testcase(0, "5\n", "", true)
t.eq("an expected-empty answer is empty, not absent, on the row", gr.tcdata[1].expected, "")
t.eq("and on disk", gtcs.buf_get_testcases(gbuf)[0].output, "")
gr:save_testcase(0, "5\n", "")
t.eq("while an ordinary empty save leaves no answer", gr.tcdata[1].expected, nil)
t.eq("and none on disk", gtcs.buf_get_testcases(gbuf)[0].output, nil)
gtcs.buf_delete_testcase(gbuf, 0)

-- A row whose testcase is deleted behind the UI's back. The results UI keeps its rows
-- across a re-run, so unlike a fresh `:Tuna run` it cannot just drop them — by then the
-- row holds the only copy of that text.
for i = 0, 2 do
    gtcs.buf_save_testcase(gbuf, i, "in" .. i .. "\n", "in" .. i .. "\n")
end
stub_system()
gr = require("tuna.runner").new(gbuf)
gr:run_testcases(gtcs.buf_get_testcases(gbuf), false)
settled(gr)
vim.system = real_system
gr:show_ui()
vim.wait(400, function()
    return false
end)
local gui = gr.ui
t.ok("the results UI opened", gui ~= nil and gui.ui_visible)

-- The focus rescue that brings the cursor back into a pane when the window displacing
-- the UI goes away must not fire when a *new* window took the focus during that close.
-- That is how the UI asks two questions in a row — an unsaved edit, then a testcase
-- gone missing — the second dialog being opened from the first one's answer: pulling
-- the cursor back into the pane there leaves the question on screen unanswerable, and
-- reads exactly as though the first prompt had swallowed the second.
vim.api.nvim_set_current_win(gui.windows.tc.winid)
vim.cmd("botright split | enew")
local excursion = vim.api.nvim_get_current_win()
vim.wait(80, function()
    return false
end)
t.eq("leaving the UI is recorded as an excursion", gui.escaped_to, excursion)
-- A window opened while the excursion closes: focus is its own, and must be left alone.
local dialog_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    pattern = tostring(excursion),
    callback = function()
        vim.api.nvim_open_win(dialog_buf, true, {
            relative = "editor",
            width = 10,
            height = 3,
            row = 1,
            col = 1,
            style = "minimal",
        })
    end,
})
vim.api.nvim_win_close(excursion, true)
vim.wait(200, function()
    return false
end)
t.eq("a dialog opened during the close keeps the focus", vim.api.nvim_get_current_buf(), dialog_buf)
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)

-- ...while the case it exists for still works: focus falling back to a window that was
-- already there is Neovim's, and the cursor belongs in the pane.
vim.api.nvim_set_current_win(gui.windows.tc.winid)
vim.cmd("botright split | enew")
excursion = vim.api.nvim_get_current_win()
vim.wait(80, function()
    return false
end)
vim.api.nvim_win_close(excursion, true)
vim.wait(200, function()
    return false
end)
t.ok("a plain close still returns the cursor to the pane", gui:owns_win(vim.api.nvim_get_current_win()))
local gm, gc = gui:disk_drift()
t.eq("with nothing changed, no row has drifted", { gm, gc }, { {}, {} })

gtcs.buf_delete_testcase(gbuf, 1)
t.eq("a row whose testcase was deleted is missing", (gui:disk_drift()), { 1 })
t.eq("and can be asked about on its own", (gui:disk_drift(1)), { 1 })
t.eq("while another row is not", (gui:disk_drift(2)), {})

-- Three kinds of row legitimately have no file: they are testcases being *written*.
gr.tcdata[2].bare = true
t.eq("a bare row is not missing, it never had a file", (gui:disk_drift()), {})
gr.tcdata[2].bare = nil
gui.pending[1] = { stdin = "", expected = "", fresh = true }
t.eq("nor is one whose edit is still unwritten", (gui:disk_drift()), {})
gui.pending[1] = nil

-- A testcase that is still there but no longer says what the row says. The file is the
-- truth and the row is a cache of it, so this one is not a question: it is reloaded,
-- which is what a fresh `:Tuna run` would have done anyway. Running the stale text
-- instead would report a verdict for input the user has already replaced.
gtcs.buf_save_testcase(gbuf, 1, "in1\n", "in1\n") -- put the missing one back first
gtcs.buf_save_testcase(gbuf, 2, "edited elsewhere\n", "and a new answer\n")
local dm, dc = gui:disk_drift()
t.eq("a testcase edited on disk is not missing", dm, {})
t.eq("it has changed", dc, { 2 })
gui:with_disk_settled(nil, "re-run", function() end)
t.eq("and the row is reloaded from the file", gr.tcdata[3].stdin, "edited elsewhere\n")
t.eq("answer included", gr.tcdata[3].expected, "and a new answer\n")
t.eq("after which nothing has drifted", (select(2, gui:disk_drift())), {})

-- Either half counts. An answer edited on disk with the input left alone is the case a
-- comparison of inputs alone would wave through, and it is the half that decides the
-- verdict, so the row would go on being judged against the old answer.
gtcs.buf_save_testcase(gbuf, 2, "edited elsewhere\n", "a different answer\n")
t.eq("a changed answer alone is drift", (select(2, gui:disk_drift())), { 2 })
gui:with_disk_settled(nil, "re-run", function() end)
t.eq("and the row takes the new answer", gr.tcdata[3].expected, "a different answer\n")
t.eq("with its input untouched", gr.tcdata[3].stdin, "edited elsewhere\n")

-- `sync_rows` reads the testcases it is handed rather than scanning again: the caller
-- has already paid for that read, and on a re-run it is every testcase file.
gr:sync_rows({ 2 }, { [2] = { input = "handed in\n", output = "handed out\n" } })
t.eq("a sync uses the table it was given", gr.tcdata[3].stdin, "handed in\n")
t.eq("answer included", gr.tcdata[3].expected, "handed out\n")
gr:sync_rows({ 2 }) -- back to what is actually on disk

-- ...unless the row carries an unwritten edit, which reloading would throw away.
gtcs.buf_save_testcase(gbuf, 2, "changed again\n", "and again\n")
gui.pending[2] = { stdin = "mine\n", expected = "" }
t.eq("a row being edited is left alone", (select(2, gui:disk_drift())), {})
gui.pending[2] = nil
t.eq("and counts again once the edit is gone", (select(2, gui:disk_drift())), { 2 })
gui:with_disk_settled(nil, "re-run", function() end)

-- Restoring writes the row back. Its own number when that is still free.
gtcs.buf_delete_testcase(gbuf, 1)
gui:restore_missing({ 1 })
t.eq("a restored testcase keeps its number", gtcs.buf_get_testcases(gbuf)[1], { input = "in1\n", output = "in1\n" })
t.eq("and the row keeps it too", gr.tcdata[2].tcnum, 1)

-- ...but never over a testcase created since. An older row the UI happened to still be
-- holding must not overwrite a newer file that took its number, so it lands on the
-- lowest free one and the row is renumbered with it.
gtcs.buf_delete_testcase(gbuf, 1)
local still_missing = gui:disk_drift()
gtcs.buf_save_testcase(gbuf, 1, "brand new\n", "brand new\n")
gui:restore_missing(still_missing)
t.eq("the newer testcase is untouched", gtcs.buf_get_testcases(gbuf)[1], { input = "brand new\n", output = "brand new\n" })
t.eq("and the restored one takes the lowest free number", gtcs.buf_get_testcases(gbuf)[3], { input = "in1\n", output = "in1\n" })
t.eq("with the row renumbered to match", gr.tcdata[2].tcnum, 3)

-- `sync_rows` takes the disk's answer as it is rather than through `answer`, which
-- normalizes *typed* text: squashing a stored empty answer to nil would turn "expect no
-- output" back into "no answer" every time a row was reloaded.
gtcs.buf_save_testcase(gbuf, 0, "5\n", "", { output = true })
gr:sync_rows({ 0 })
t.eq("a reload keeps a stored empty answer", gr.tcdata[1].expected, "")
gtcs.buf_delete_testcase(gbuf, 0)

--------------------------------------------------------------------------------
-- The one question a save asks, and when it asks nothing
--------------------------------------------------------------------------------

-- Everything a `:w` needs is on the panes except one thing: an empty answer is either
-- "no answer" (not judged) or "print nothing" (judged), and the panes look identical.
-- So that is the only question, and it is asked only when a *real* answer is being
-- turned into an empty one — which is what keeps a first save silent and keeps
-- re-saving from asking the same thing over and over.
local widgets = require("tuna.widgets")
local real_menu = widgets.menu
local asked
widgets.menu = function(items)
    asked = items
end

---What `:w` on this testcase would ask, with the panes holding `input`/`expected`.
---@return string[]? items, nil when nothing is asked
local function question(tcnum, input, expected)
    asked = nil
    gui.pending[tcnum] = { stdin = input, expected = expected }
    local saved = gui.pane_tcnum
    gui.pane_tcnum = nil -- read the pending text, not the panes
    gui:with_answer_settled(tcnum, function() end)
    gui.pane_tcnum = saved
    gui.pending[tcnum] = nil
    vim.wait(50, function()
        return asked ~= nil
    end)
    return asked
end

local ANSWER_PROMPT = { "Don't specify output", "Expect empty output", "Keep editing" }

gtcs.buf_save_testcase(gbuf, 0, "5\n", "5\n")
gr:sync_rows({ 0 })
t.eq("a testcase with both halves filled asks nothing", question(0, "9\n", "9\n"), nil)
t.eq("clearing a real answer asks which was meant", question(0, "5\n", ""), ANSWER_PROMPT)
-- The same question, and the *only* question: emptying the input as well does not add
-- one, because an empty input is not ambiguous and a save does not delete a testcase.
t.eq("emptying everything asks the same one thing", question(0, "", ""), ANSWER_PROMPT)

-- Nothing to lose, nothing to ask: an answer that is already absent stays absent.
gtcs.buf_save_testcase(gbuf, 0, "5\n", "")
gr:sync_rows({ 0 })
t.eq("saving a testcase that never had an answer is silent", question(0, "9\n", ""), nil)
t.eq("and emptying that one is silent too", question(0, "", ""), nil)

-- ...and an answer that is already empty keeps meaning "print nothing", so re-saving
-- does not put the same question up again.
gtcs.buf_save_testcase(gbuf, 0, "5\n", "", true)
gr:sync_rows({ 0 })
t.eq("re-saving an expected-empty answer is silent", question(0, "9\n", ""), nil)
local kept
gui.pending[0] = { stdin = "9\n", expected = "" }
local sv = gui.pane_tcnum
gui.pane_tcnum = nil
gui:with_answer_settled(0, function(e)
    kept = e
end)
gui.pane_tcnum = sv
gui.pending[0] = nil
t.eq("and it goes on meaning what it meant", kept, true)

gtcs.buf_delete_testcase(gbuf, 0)

-- Every prompt that stands between the user and a lost edit offers the same three
-- answers, named after the outcome each produces. Closing used to say `Discard changes`
-- and `Cancel` where re-running said `Discard and re-run` and `Cancel`: the same
-- question in two vocabularies, one of which named the action and one of which did not.
gtcs.buf_save_testcase(gbuf, 0, "5\n", "5\n")
gr:sync_rows({ 0 })
local function unsaved_prompt(fn)
    asked = nil
    gui.pending[0] = { stdin = "edited\n", expected = "5\n" }
    local sv = gui.pane_tcnum
    gui.pane_tcnum = nil
    fn()
    gui.pane_tcnum = sv
    gui.pending[0] = nil
    vim.wait(50, function()
        return asked ~= nil
    end)
    return asked
end
t.eq("re-running one asks in the shared vocabulary", unsaved_prompt(function()
    gui:with_pending_settled(0, "re-run", function() end)
end), { "Save and re-run", "Discard and re-run", "Keep editing" })
t.eq("re-running all asks the same way", unsaved_prompt(function()
    gui:with_pending_settled(nil, "re-run all", function() end)
end), { "Save and re-run all", "Discard and re-run all", "Keep editing" })
t.eq("and so does closing", unsaved_prompt(function()
    gui:request_close()
end), { "Save and close", "Discard and close", "Keep editing" })

-- `Discard` says exactly what it does. It used to read "Discard and re-run", which for
-- a single row is a promise it cannot keep: the row being re-run is the one going away.
gtcs.buf_save_testcase(gbuf, 0, "5\n", "5\n")
gr:sync_rows({ 0 })
gtcs.buf_delete_testcase(gbuf, 0)
asked = nil
gui:with_disk_settled(nil, "re-run all", function() end)
vim.wait(50, function()
    return asked ~= nil
end)
t.eq("the missing-testcase prompt offers a plain Discard", asked, {
    "Restore and re-run all",
    "Discard",
    "Stop",
})

widgets.menu = real_menu
gtcs.buf_delete_testcase(gbuf, 0)

gui:delete()
vim.cmd("silent! %bwipeout!")
vim.fn.delete(gdir, "rf")

vim.fn.delete(dir, "rf")
--------------------------------------------------------------------------------
-- Switching runs: unsaved edits are asked about, one mode runs, one UI is shown
--------------------------------------------------------------------------------

-- A run replaces the rows an unwritten edit lives in (interactive, stress and run-all
-- replace the whole runner), so it asks first. Stand-in runners record what was done
-- to them.
do
    local C = require("tuna.commands")
    require("tuna.stress")
    local function fake(pending)
        local f = { killed = false }
        f.ui = { ui_visible = true, pending = pending }
        function f.ui:has_pending()
            return self.pending ~= nil
        end
        function f.ui:delete()
            self.ui_visible = false
        end
        function f.ui:with_pending_settled(_, what, proceed, after_save)
            self.asked, self.answer, self.after_save = what, proceed, after_save
        end
        function f:show_ui()
            self.ui.ui_visible = true
        end
        function f:kill_all_processes()
            self.killed = true
        end
        return f
    end
    local fb = 424242
    local normal_r, stress_r = fake(nil), fake({ [1] = { stdin = "9" } })
    stress_r.ui.ui_visible = false
    C.runners[fb] = normal_r
    require("tuna.stress").active[fb] = stress_r
    local ran = false
    C.settle_results(fb, { run = true, keep = normal_r }, function()
        ran = true
    end)
    t.eq("an unsaved edit, even in a hidden UI, is asked about before a run", { ran, stress_r.ui.asked }, { false, "run" })
    t.eq("with its UI brought back to ask over", stress_r.ui.ui_visible, true)
    t.eq("and saving goes on to the run", stress_r.ui.after_save, true)
    stress_r.ui.pending = nil
    stress_r.ui.answer()
    t.eq("once it is settled the run starts", ran, true)
    t.eq("with the buffer's runs stopped", { normal_r.killed, stress_r.killed }, { true, true })
    t.eq("every other UI off the screen, the one being run left up", { stress_r.ui.ui_visible, normal_r.ui.ui_visible }, { false, true })

    -- Showing a UI hides the others and nothing more: no question, nothing stopped.
    normal_r.killed, stress_r.killed = false, false
    stress_r.ui.ui_visible, stress_r.ui.pending = true, { [1] = { stdin = "9" } }
    local shown = false
    C.settle_results(fb, { keep = normal_r }, function()
        shown = true
    end)
    t.eq("showing a UI asks nothing and stops nothing", { shown, normal_r.killed, stress_r.killed }, { true, false, false })
    t.eq("and hides the others", stress_r.ui.ui_visible, false)
    C.runners[fb] = nil
    require("tuna.stress").active[fb] = nil
end

--------------------------------------------------------------------------------
-- After a restart: show_ui opens the mode the problem is set to, nothing run
--------------------------------------------------------------------------------

-- Nothing has run in a fresh session, so the mode to show is the one saved for the
-- problem, and a mode with no runner yet opens with its rows listed rather than running.
do
    -- A problem of its own: earlier sections wipe the buffer the file started with.
    local rdir = t.tempdir()
    t.write(rdir, "sol.cpp", "int main(){}\n")
    t.write(rdir, "sol_input0.txt", "1\n")
    t.write(rdir, "sol_output0.txt", "1\n")
    vim.cmd("edit " .. rdir .. "/sol.cpp")
    vim.bo.filetype = "cpp"
    local rbuf = vim.api.nvim_get_current_buf()
    local C = require("tuna.commands")
    local tools = require("tuna.tools")
    local path = vim.api.nvim_buf_get_name(rbuf)
    local function clear_runners()
        for _, m in ipairs({ "tuna.interactive", "tuna.stress", "tuna.multi" }) do
            local mod = package.loaded[m]
            local a = mod and mod.active[rbuf]
            if a then
                a:kill_all_processes()
                a:delete_ui()
                mod.active[rbuf] = nil
            end
        end
        if C.runners[rbuf] then
            C.runners[rbuf]:delete_ui()
            C.runners[rbuf] = nil
        end
        C.last_mode[rbuf] = nil
    end
    local compiler = require("tuna.runner").new(rbuf).cc.exec
    local function settle_ms(ms)
        vim.wait(ms, function()
            return false
        end)
    end

    clear_runners()
    tools.set_mode(path, "interactive")
    tools.set_source(path, "feed")
    stub_system()
    C.show_results_ui(rbuf)
    settle_ms(200)
    local shown = require("tuna.interactive").active[rbuf]
    t.ok("after a restart, show_ui opens the mode the problem is set to", shown ~= nil and shown.ui ~= nil and shown.ui.ui_visible)
    t.eq("and not the normal runner's", C.runners[rbuf], nil)
    t.eq("nothing is run to show it", #spawns, 0)
    local last = shown and shown.tcdata[#shown.tcdata]
    t.eq("its rows read NOT RUN", last and last.status, "NOT RUN")
    t.eq("and the runner is idle, so feed's testcases can be edited", shown and shown:idle(), true)
    if shown then
        shown:run_testcases()
        settle_ms(300)
    end
    t.eq("the first run builds before running", spawns[1] and spawns[1].argv[1], compiler)
    vim.system = real_system

    clear_runners()
    tools.set_mode(path, "all")
    stub_system()
    C.show_results_ui(rbuf)
    settle_ms(200)
    local matrix = require("tuna.multi").active[rbuf]
    t.ok("run-all opens listed too", matrix ~= nil and matrix.ui ~= nil and matrix.ui.ui_visible)
    t.eq("with nothing run", #spawns, 0)
    vim.system = real_system

    clear_runners()
    vim.fn.delete(rdir, "rf")
end

t.report()
