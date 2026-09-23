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
-- The selector's columns
--------------------------------------------------------------------------------

-- Ten-wide columns are what the rows line up on in every mode, but the conversation's
-- selector is narrower than three of them, and a pane that cuts `0.266 s` in half reports
-- a run that never happened.
local columns = require("tuna.runner_ui")._test.selector_columns
local sel_rows = {
    { header = "Compile", status = "DONE", time = "0.266 s" },
    { header = "TC 0", status = "RUNNING", time = "" },
}
t.eq("a pane with room keeps the ten-wide columns", { columns(sel_rows, 40) }, { 10, 10, true })
t.eq("and so does a selector with no window of its own", { columns(sel_rows, nil) }, { 10, 10, true })
t.eq("a narrow one sizes them to their content, to keep the time", { columns(sel_rows, 24) }, { 8, 8, true })
t.eq("and narrower still gives the time up rather than cutting it", { columns(sel_rows, 18) }, { 8, 8, false })
t.eq("narrower than the columns themselves, it splits what there is", { columns(sel_rows, 12) }, { 6, 6, false })

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
vim.wait(1000, function()
    return r.completed
end, 20)
local core = require("tuna.runner.core")
local sidecar = require("tuna.sidecar")
-- The stub prints nothing: testcase 0 is WRONG, and testcase 1 has no answer to judge.
t.eq("a finished run saves its local verdict, over the testcases it judged", { core.local_verdict(dir .. "/sol.cpp") }, { 0, 1 })
sidecar.set_entry(dir .. "/sol.cpp", "results", nil)

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
vim.wait(1000, function()
    return mr and mr.completed
end, 20)
t.eq("run all saves each solution's local verdict", { core.local_verdict(dir .. "/sol.cpp") }, { 0, 1 })
sidecar.set_entry(dir .. "/sol.cpp", "results", nil)
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
    -- The conversation's selector is the narrow pane of the grid, and a row wider than it
    -- is a verdict or a time cut in half by the pane's edge.
    local function selector_lines()
        return vim.api.nvim_buf_get_lines(iui.windows.tc.bufnr, 0, -1, false)
    end
    vim.wait(1000, function()
        return #selector_lines() >= #ir.tcdata
    end, 20)
    local tcw = vim.api.nvim_win_get_width(iui.windows.tc.winid)
    local widest = 0
    for _, line in ipairs(selector_lines()) do
        widest = math.max(widest, vim.fn.strwidth(line))
    end
    t.ok("the conversation's selector rows fit its pane", widest <= tcw and widest > 0, { selector_lines(), tcw })
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
    -- The conversation is laid out as columns beside the selector, Output then Live then
    -- Errors, each full height so a row of one faces the same row of the others. Errors goes
    -- last because the last column takes whatever the grid's division leaves over, which is
    -- what lets Output and Live be exactly as wide as each other.
    local function box(w)
        local c = vim.api.nvim_win_get_config(w.winid)
        return c.col, c.row, c.height
    end
    local tcol = box(iui.windows.tc)
    local ecol, erow, eh = box(se)
    local ocol, orow, oh = box(so)
    local lcol, lrow, lh = box(si)
    t.ok(
        "columns run selector, Output, Live, Errors",
        tcol < ocol and ocol < lcol and lcol < ecol,
        { tcol, ocol, lcol, ecol }
    )
    t.eq("each full height and level with the others", { erow, orow, eh, oh }, { lrow, lrow, lh, lh })

    -- The conversation's selector is the width it is in every other mode, and its two
    -- conversing columns are exactly as wide as each other. Checked on the layout arithmetic
    -- at several editor widths, because what the grid's division leaves over depends on it,
    -- and that rounding is what used to make them differ.
    local geometry = require("tuna.runner_ui.popup")._test.compute_layout
    local ui_cfg = require("tuna.config").get_buffer_config(buf)
    local conv_layout = ir:layout()
    -- The editor's size is asked for rather than read, so it can be answered here: setting
    -- `columns` would resize the windows this section is standing in.
    local tuna_utils = require("tuna.utils")
    local real_size = tuna_utils.get_ui_size
    for _, cols in ipairs({ 100, 140, 141, 183 }) do
        tuna_utils.get_ui_size = function()
            return cols, 40
        end
        local normal = geometry(ui_cfg, 4, ui_cfg.popup_ui.layout)
        local conv = geometry(ui_cfg, 4, conv_layout)
        t.eq(("the conversation's selector is as wide as a normal run's, at %d columns"):format(cols), conv.tc.width, normal.tc.width)
        t.eq(("Output and Live are the same width, at %d columns"):format(cols), conv.so.width, conv.si.width)
    end
    tuna_utils.get_ui_size = real_size

    -- What each side says lands on a row of its own in its own column, blank in the other
    -- two, and every column follows the latest line.
    vim.wait(500, function()
        return ir.completed
    end, 20)
    -- One row *is* the session, so it is the row the UI shows: its columns are where the
    -- conversation appears, and in live it is the only row that can be typed into.
    t.eq("the row being talked to is the row the UI shows", iui.update_testcase, 2)
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
-- A run opens on its build step, which is shown with Errors alone, so the panes of the mode
-- are there once the build has handed the row over.
vim.wait(2000, function()
    return fr ~= nil and fr.ui ~= nil and fr.ui.ui_visible and fr.ui.update_testcase ~= 1
end, 20)
vim.wait(200, function()
    return false
end)
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
    -- Feed talks to the built program itself, which the stub never built: a script standing
    -- in for it prints the answer.
    local exec = fr.r.rc.exec
    if exec:sub(1, 1) ~= "/" then
        exec = dir .. "/" .. exec:gsub("^%./", "")
    end
    local had_exec = vim.uv.fs_stat(exec) ~= nil
    if not had_exec then
        vim.fn.writefile({ "#!/bin/sh", "echo 42" }, exec)
        vim.fn.setfperm(exec, "rwxr-xr-x")
        fr:run_testcases()
        vim.wait(2000, function()
            return fr.completed == false
        end, 10)
        vim.wait(2000, function()
            return fr.completed
        end, 20)
        -- Whether the row came back CORRECT is a race with a real process being torn down,
        -- so what is checked is that the session saved a verdict over the case it judged.
        local _, feed_total = core.local_verdict(dir .. "/sol.cpp")
        t.eq("a finished feed session saves its local verdict", feed_total, 1)
        vim.fn.delete(exec)
        sidecar.set_entry(dir .. "/sol.cpp", "results", nil)
    end
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

-- Live invites you to talk to the program, so the keys that mean "I am typing here" have to
-- reach one: on a column that is not live yet they would only raise `E21` at someone the UI
-- is asking to type, which is an answer about `modifiable` to a question about the problem.
stub_system()
require("tuna.interactive").run(buf, { "live" }, { show_only = true })
local lr = require("tuna.interactive").active[buf]
vim.wait(500, function()
    return lr ~= nil and lr.ui ~= nil and lr.ui.ui_visible
end, 20)
local live_buf = lr.ui.windows.si.bufnr
local typing_keys = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(live_buf, "n")) do
    typing_keys[m.lhs] = m.callback
end
t.ok(
    "the keys that start typing are bound on the Live column",
    typing_keys.i and typing_keys.I and typing_keys.a and typing_keys.A and typing_keys.o and typing_keys.O ~= nil,
    vim.tbl_keys(typing_keys)
)
t.eq("nothing is typable before a session", vim.bo[live_buf].modifiable, false)
t.eq("and nothing is built", lr.preloaded, true)
typing_keys.i()
t.eq("pressing one builds and starts the session", lr.preloaded, false)
t.eq("and remembers to hand the column over once it is live", lr.type_when_live, true)
-- The runner is `completed` until the sessions start, so both edges are waited for: the
-- sessions run (and fail, nothing being built for real) before the stand-in pipe below.
vim.wait(1000, function()
    return lr.completed == false
end, 10)
vim.wait(2000, function()
    return lr.completed
end, 20)
vim.wait(200, function()
    return false
end)

-- The column going live is what hands it over: the cursor ends up in it, in insert, at the
-- end of the line being composed. A stand-in pipe makes the session "live". The row is chosen
-- through the UI and left to settle first, since the grid is rebuilt when the kind of row on
-- screen changes and that takes the panes with it.
lr.active_index = 2
lr.sol_in = {
    is_closing = function()
        return false
    end,
    write = function() end,
}
lr.ui:follow_row(2)
vim.wait(500, function()
    return false
end)
lr.type_when_live = true
lr:update_ui(true)
vim.wait(500, function()
    return lr.type_when_live == nil
end, 20)
t.eq("the column is handed over once it is live", lr.type_when_live, nil)
local live_pane = lr.ui.windows.si
t.eq("with the cursor in it", vim.api.nvim_get_current_win(), live_pane.winid)
local composing_line = vim.api.nvim_buf_line_count(live_pane.bufnr)
t.eq("at the end of the line being composed", vim.api.nvim_win_get_cursor(live_pane.winid), {
    composing_line,
    #(vim.api.nvim_buf_get_lines(live_pane.bufnr, composing_line - 1, composing_line, false)[1] or ""),
})
-- Insert mode itself needs a UI to enter, so that part is verified against a real session
-- rather than here.
vim.cmd("stopinsert")
lr.sol_in = nil
lr:kill_all_processes()
lr.ui:delete()
vim.system = real_system

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
-- Once the build has handed the row over, so the mode's own panes are the ones drawn.
vim.wait(2000, function()
    return xr ~= nil and xr.ui ~= nil and xr.ui.ui_visible and xr.ui.update_testcase ~= 1
end, 20)
vim.wait(200, function()
    return false
end)
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

-- Stress needs a generator and a bruteforce beside the solution to start at all.
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
-- The stress search: what it trusts, and what it shows while it looks
--------------------------------------------------------------------------------

-- Every stress verdict is read off the bruteforce's output, so a bruteforce that did not
-- finish has to stop the search rather than feed it: a process killed by a signal (a
-- sanitizer abort, a segfault) exits with code 0, so reading the code alone passes its
-- empty output off as the correct answer, and then every input looks like a
-- counterexample and is saved with no answer beside it. The bruteforce also gets a
-- budget of its own, being slow on purpose. And while the search runs it has a row,
-- numbered as the counterexample it is hunting for, which is where a generator or
-- bruteforce that failed is reported: the row that was doing the work takes the verdict and
-- the Errors pane takes what the process said, as a testcase's own failure is reported.
do
    local sdir2 = t.tempdir()
    t.write(sdir2, "main.cpp", "int main(){}\n")
    vim.cmd("edit " .. sdir2 .. "/main.cpp")
    vim.bo.filetype = "cpp"
    local sbuf = vim.api.nvim_get_current_buf()
    -- Real files, because a configured helper that cannot be run is reported instead of
    -- being spawned. Nothing runs them: `vim.system` is scripted below.
    local function program(name)
        t.write(sdir2, name, "#!/bin/sh\n")
        vim.fn.setfperm(sdir2 .. "/" .. name, "rwxr-xr-x")
        return sdir2 .. "/" .. name
    end
    local ccx, solx, genx, refx = program("ccx"), program("solx"), program("genx"), program("refx")
    require("tuna.config").setup({
        compile_command = { cpp = { exec = ccx, args = { "$(FNAME)" } } },
        run_command = { cpp = { exec = solx } },
        maximum_time = 1234,
        stress = {
            generator = { exec = genx, args = {} },
            bruteforce = { exec = refx, args = {} },
            count = 3,
            bruteforce_time = 9876,
        },
    })

    -- One scripted answer per program, by name. A "hold" answer is kept until the test
    -- releases it, which is how the search is caught in the middle of an iteration.
    local script, budgets, held, calls = {}, {}, nil, {}
    vim.system = function(argv, opts, on_exit)
        local name = vim.fn.fnamemodify(argv[1], ":t")
        local res = script[name]
        calls[#calls + 1] = name
        budgets[name] = opts and opts.timeout
        res = type(res) == "function" and res(argv) or res
        local function answer(r)
            on_exit(vim.tbl_extend("keep", type(r) == "table" and r or {}, {
                code = 0,
                signal = 0,
                stdout = "",
                stderr = "",
            }))
        end
        if on_exit then
            if res == "hold" then
                held = answer -- released by the test, with the result it wants
            else
                vim.schedule(function()
                    answer(res)
                end)
            end
        end
        return { kill = function() end, wait = function() return { code = 0 } end, pid = 0 }
    end

    local stress = require("tuna.stress")
    local function seeded(argv)
        return { stdout = "in " .. argv[#argv] .. "\n" }
    end
    ---Every row as it reads in the selector.
    local function listing(sr2)
        return vim.tbl_map(function(tc)
            return { sr2:row_label(tc), tc.status }
        end, sr2.tcdata)
    end
    local opening
    ---Start a search over `spec` and wait for it to stop (unless it is held). Each one
    ---starts from a solution with no testcases beside it, so the row a search is caught
    ---on can only be its own.
    local function search(spec)
        for _, f in ipairs(vim.fn.globpath(sdir2, "main_*.txt", false, true)) do
            vim.fn.delete(f)
        end
        script, held = spec, nil
        stress.run(sbuf, 3)
        local sr2 = stress.active[sbuf]
        -- Nothing has been answered yet: the stub replies on the next tick, so this is the
        -- board as it opens.
        opening = listing(sr2)
        vim.wait(5000, function()
            return sr2 and (sr2.finished or held ~= nil)
        end, 10)
        return sr2
    end
    ---The rows standing for a testcase on disk, as { number, status } pairs.
    local function saved_rows(sr2)
        local out = {}
        for _, tc in ipairs(sr2.tcdata) do
            if type(tc.tcnum) == "number" then
                out[#out + 1] = { tc.tcnum, tc.status }
            end
        end
        return out
    end
    local function testcase_files()
        local names = vim.tbl_map(function(f)
            return vim.fn.fnamemodify(f, ":t")
        end, vim.fn.globpath(sdir2, "main_*.txt", false, true))
        table.sort(names)
        return names
    end

    -- A bruteforce killed by a signal.
    local crashed = search({ genx = seeded, solx = { stdout = "5\n" }, refx = { code = 0, signal = 6 } })
    t.eq("the search is listed with the other rows the moment the board opens", opening, {
        { "Compile", "RUNNING" },
        { "TC 0", "STRESS" },
    })
    t.eq("a bruteforce killed by a signal is a failure, not an empty answer", saved_rows(crashed), {})
    t.eq("so nothing is written beside the solution", testcase_files(), {})
    t.eq("and the search stops on the seed it happened on", crashed.iter, 1)
    t.ok("finished, so the rows can be edited again", crashed:idle(), crashed.finished)
    local hunt = crashed.tcdata[#crashed.tcdata]
    t.eq("the row that was doing the work takes the verdict", {
        crashed:row_label(hunt),
        hunt.status,
        hunt.hlgroup,
    }, { "TC 0", "SIG 6", "TunaWarning" })
    t.has("and its Errors pane says which program failed, and on which seed", crashed:pane_content(hunt, "se"), "bruteforce was killed by signal 6 (seed 1)")

    -- A bruteforce that ran out of its budget.
    local slow = search({ genx = seeded, solx = { stdout = "5\n" }, refx = { code = 124, signal = 15 } })
    t.eq("a bruteforce that timed out saves nothing either", saved_rows(slow), {})
    t.eq("the bruteforce is held to its own budget", budgets.refx, 9876)
    t.eq("while the generator and the solution keep maximum_time", { budgets.genx, budgets.solx }, { 1234, 1234 })
    local waited = slow.tcdata[#slow.tcdata]
    t.eq("a timeout reads as one, in the word a testcase would use", { waited.status, waited.hlgroup }, { "TIMEOUT", "TunaWrong" })
    t.has("with the budget that ran out named", slow:pane_content(waited, "se"), "stress.bruteforce_time")

    -- A bruteforce that finished and printed nothing: that is its answer.
    local empty = search({ genx = seeded, solx = { stdout = "5\n" }, refx = { stdout = "" } })
    t.eq("a bruteforce that printed nothing still answers for the input", saved_rows(empty), { { 0, "WRONG" } })
    t.eq("saved as an answer that is empty, not an answer that is missing", testcase_files(), {
        "main_input0.txt",
        "main_output0.txt",
    })
    t.eq("which is what the row is judged against on a re-run", empty.tcdata[#empty.tcdata].expected, "")

    -- The row the search is shown on, caught mid-iteration.
    local looking = search({ genx = seeded, solx = "hold", refx = { stdout = "5\n" } })
    local row = looking.search_entry
    t.ok("the search has a row of its own before it finds anything", row ~= nil, looking.tcdata)
    t.eq("numbered as the counterexample it is hunting for", { looking:row_label(row), row.status }, { "TC 0", "STRESS" })
    t.eq("holding the input being tried", row.stdin, "in 1\n")
    t.eq("last in the list, so a counterexample lands above it", looking.tcdata[#looking.tcdata], row)
    t.ok("and is no testcase, nothing on disk answers for it", not looking:row_editable(row), row)
    script.solx = { stdout = "5\n" }
    held(script.solx)
    vim.wait(5000, function()
        return looking.finished
    end, 10)
    t.eq("once the search stops, the row goes with it", looking.search_entry, nil)
    t.eq("leaving nothing behind, the two agreed on every input", saved_rows(looking), {})

    -- The search and the testcases already on disk are two lanes. The search starts as soon
    -- as the helpers are built, rather than waiting for testcases that have nothing to do
    -- with it, and a search that stops first must not abandon them half-run.
    for _, f in ipairs(vim.fn.globpath(sdir2, "main_*.txt", false, true)) do
        vim.fn.delete(f)
    end
    for n = 0, 1 do
        t.write(sdir2, "main_input" .. n .. ".txt", n .. "\n")
        t.write(sdir2, "main_output" .. n .. ".txt", "5\n")
    end
    local first_run = true
    calls, held = {}, nil
    script = {
        genx = seeded,
        refx = { stdout = "9\n" }, -- disagrees at once, so the search stops on the first seed
        solx = function()
            if first_run then
                first_run = false
                return "hold" -- the first testcase from disk, left in flight
            end
            return { stdout = "5\n" }
        end,
    }
    stress.run(sbuf, 3)
    local both = stress.active[sbuf]
    vim.wait(5000, function()
        return both.finished
    end, 10)
    t.ok("the search runs without waiting for the testcases on disk", vim.tbl_contains(calls, "genx"), calls)
    t.eq("and can stop while one of them is still going", {
        both.finished,
        both.tcdata[2].running,
        both.tcdata[3].status,
    }, { true, true, "" })
    t.ok("which is not idle, whatever the search is doing", not both:idle())
    t.eq("with the counterexample it found already saved", saved_rows(both)[3], { 2, "WRONG" })
    held({ stdout = "5\n" })
    vim.wait(5000, function()
        return both.tcdata[3].status ~= ""
    end, 10)
    t.eq("the testcases still get their verdicts, the one running and the one after it", {
        both.tcdata[2].status,
        both.tcdata[3].status,
    }, { "CORRECT", "CORRECT" })
    t.ok("and only then is the run idle", both:idle())
    both.ui:delete()

    -- Stopping is what ends that lane, and it ends it where it is: the testcases behind the
    -- one in flight are not run afterwards.
    first_run = true
    held = nil
    stress.run(sbuf, 3)
    local halted = stress.active[sbuf]
    vim.wait(5000, function()
        return held ~= nil
    end, 10)
    halted:kill_all_processes()
    held({ stdout = "5\n" })
    vim.wait(400, function()
        return false
    end)
    t.eq("a stop ends the re-runs where they are", {
        halted.tcdata[2].status,
        halted.tcdata[3].status,
        halted.tcdata[4].status,
    }, { "KILLED", "", "" })
    t.ok("and leaves nothing running", halted:idle(), halted.rerunning)
    halted.ui:delete()

    -- A counterexample the search wrote is compared like any other row. What decides
    -- whether a row can be diffed is that something has answered on it, not that it spawned
    -- a process of its own: the search fills its rows in itself.
    local ns = vim.api.nvim_create_namespace("tuna_runner_diff")
    local found = search({ genx = seeded, solx = { stdout = "5\n" }, refx = { stdout = "9\n" } })
    t.eq("the search saved what it disagreed on", saved_rows(found), { { 0, "WRONG" } })
    found.ui:toggle_diff_view()
    found.ui:select_row(2)
    found.ui.update_windows, found.ui.update_details = true, true
    found.ui:update_ui()
    vim.wait(400, function()
        return false
    end)
    t.ok("and it is marked up in both panes", (function()
        local out = #vim.api.nvim_buf_get_extmarks(found.ui.windows.so.bufnr, ns, 0, -1, {})
        local exp = #vim.api.nvim_buf_get_extmarks(found.ui.windows.eo.bufnr, ns, 0, -1, {})
        return out > 0 and exp > 0
    end)(), found.tcdata[2])

    -- With the comparison on, moving to the build step lays the grid out again without an
    -- Output pane: it has a buffer, but no window to bind.
    found.ui:select_row(1)
    local bound, why = pcall(function()
        found.ui:redraw_grid()
    end)
    t.ok("a grid with no Output pane is not a window to bind", bound, why)
    t.eq("the pane being one with a buffer and no window", {
        found.ui.windows.so.winid,
        vim.api.nvim_buf_is_valid(found.ui.windows.so.bufnr),
    }, { nil, true })
    found.ui:delete()

    -- Listed and not run, the search row says what it is for: `NOT RUN` is a testcase's word
    -- for having no verdict yet, and the search has no verdict to have.
    for _, f in ipairs(vim.fn.globpath(sdir2, "main_*.txt", false, true)) do
        vim.fn.delete(f)
    end
    script = {}
    stress.show(sbuf)
    local listed = stress.active[sbuf]
    t.eq("and is listed when the rows are only listed", listing(listed), {
        { "Compile", "NOT RUN" },
        { "TC 0", "STRESS" },
    })
    t.ok("with nothing running, so the rows can be edited", listed:idle(), listed.finished)
    listed.ui:delete()

    -- A solution that never compiled searches for nothing.
    local broken = search({ ccx = { code = 1 }, genx = seeded, solx = { stdout = "5\n" }, refx = { stdout = "5\n" } })
    t.eq("a failed build leaves the compile row saying so", broken.tcdata[1].status, "RET 1")
    t.ok("and finishes the search, which is what lets the rows be edited", broken:idle(), broken.finished)

    if stress.active[sbuf] then
        stress.active[sbuf]:delete_ui()
    end
    vim.system = real_system
    require("tuna.config").setup({})
end

--------------------------------------------------------------------------------
-- The build step: one pane per source the run compiles
--------------------------------------------------------------------------------

-- A run compiles more than the solution — a generator and a bruteforce, an interactor, a
-- checker — and each of them has a compiler with something to say. The build step shows
-- them one above the other, each pane named after its source, so a warning is read where
-- it belongs instead of in the one Errors pane the solution used to have to itself.
do
    local bdir = t.tempdir()
    for _, name in ipairs({ "main.cpp", "gen.cpp", "brute.cpp", "checker.cpp" }) do
        t.write(bdir, name, "int main(){}\n")
    end
    -- Real files: a compile command is looked up before it is run, and nothing here runs.
    for _, name in ipairs({ "ccx", "solx" }) do
        t.write(bdir, name, "#!/bin/sh\n")
        vim.fn.setfperm(bdir .. "/" .. name, "rwxr-xr-x")
    end
    vim.cmd("edit " .. bdir .. "/main.cpp")
    vim.bo.filetype = "cpp"
    local bbuf = vim.api.nvim_get_current_buf()
    require("tuna.config").setup({
        compile_command = { cpp = { exec = bdir .. "/ccx", args = { "$(FNAME)" } } },
        run_command = { cpp = { exec = bdir .. "/solx" } },
    })

    -- The generator and the checker compile with a warning, the solution and the bruteforce
    -- quietly, so each pane can be told apart by what is in it and the build step is one
    -- that only its helpers had anything to say about.
    local warns = { ["gen.cpp"] = true, ["checker.cpp"] = true }
    vim.system = function(argv, _, on_exit)
        local said = ""
        for _, a in ipairs(argv) do
            if warns[a] then
                said = a .. " warns\n"
            end
        end
        if on_exit then
            vim.schedule(function()
                on_exit({ code = 0, signal = 0, stdout = "", stderr = said })
            end)
        end
        return { kill = function() end, wait = function() return { code = 0 } end, pid = 0 }
    end

    require("tuna.stress").run(bbuf, 1)
    local br = require("tuna.stress").active[bbuf]
    vim.wait(5000, function()
        return br and br.tcdata[1] and not br:build_pending(br.tcdata[1])
    end, 10)
    local bui, first = br.ui, br.tcdata[1]

    t.eq("the build step stacks one pane per source it compiles", (bui:row_layout(1)), {
        { 3, "tc" },
        { 8, { { 1, "se" }, { 1, "so" }, { 1, "eo" }, { 1, "si" } } },
    })
    local assigned = bui:build_assignment(first)
    t.eq("the solution first, then the helpers the mode needs", assigned.titles, {
        se = " Errors: main.cpp ",
        so = " Errors: gen.cpp ",
        eo = " Errors: brute.cpp ",
        si = " Errors: checker.cpp ",
    })
    t.eq("each holding what its own compiler said, and nothing when it said nothing", assigned.text, {
        se = "",
        so = "gen.cpp warns\n",
        eo = "",
        si = "checker.cpp warns\n",
    })
    t.eq("a testcase row keeps the grid of the run", (bui:row_layout(2)), nil)
    t.ok("a row that is not the build step has no sources", bui:build_assignment(br.tcdata[2]) == nil)
    t.ok("a helper that warned keeps the cursor on the build step", br:build_spoke(first), assigned.text)
    t.eq("though the solution itself built quietly", { first.stderr, first.exit_code }, { "", 0 })

    -- What the panes are actually drawn with, and that they are named back again: a pane
    -- that stays open through a re-tiling would otherwise keep the name it was opened with.
    bui:select_row(1)
    bui.update_windows, bui.update_details = true, true
    bui:update_ui()
    vim.wait(400, function()
        return false
    end)
    ---Whether a pane wears the accent that says it is typed into.
    local function accented(name)
        local w = bui.windows[name]
        return w.winid
            and vim.api.nvim_win_is_valid(w.winid)
            and vim.wo[w.winid].winhighlight:find("TunaEditableBorder", 1, true) ~= nil
    end
    ---What a pane's border actually says, which is what a rename has to reach.
    local function drawn_title(name)
        local w = bui.windows[name]
        local cfg = w.winid and vim.api.nvim_win_is_valid(w.winid) and vim.api.nvim_win_get_config(w.winid)
        return cfg and cfg.title and cfg.title[1][1] or nil
    end
    t.eq("the panes are drawn under the names of their sources", {
        drawn_title("se"),
        drawn_title("so"),
        vim.api.nvim_buf_get_lines(bui.windows.so.bufnr, 0, 1, false)[1],
    }, { " Errors: main.cpp ", " Errors: gen.cpp ", "gen.cpp warns" })
    t.ok("and wear no accent, nothing on the build step is typed into", not accented("eo"), "eo")
    bui:select_row(2)
    bui.update_windows, bui.update_details = true, true
    bui:update_ui()
    vim.wait(400, function()
        return false
    end)
    t.eq("and named back for a testcase row", { drawn_title("so"), drawn_title("se") }, { " Output ", " Errors " })
    t.ok("which is where the accent comes back", accented("eo"), "eo")
    -- And goes again: a pane the re-tiling leaves open keeps the colour it had, so the
    -- accent has to be taken off as well as put on.
    bui:select_row(1)
    bui.update_windows, bui.update_details = true, true
    bui:update_ui()
    vim.wait(400, function()
        return false
    end)
    t.ok("and goes again on the way back to the build step", not accented("eo"), "eo")

    br:kill_all_processes()
    bui:delete()

    -- A helper that is a command rather than a source has no compiler to quote, so it takes
    -- no pane: the build step is what this run builds, not what it runs.
    require("tuna.config").setup({
        compile_command = { cpp = { exec = bdir .. "/ccx", args = { "$(FNAME)" } } },
        run_command = { cpp = { exec = bdir .. "/solx" } },
        stress = { generator = { exec = bdir .. "/solx", args = {} } },
    })
    require("tuna.stress").run(bbuf, 1)
    local cr = require("tuna.stress").active[bbuf]
    vim.wait(5000, function()
        return cr and cr.tcdata[1] and not cr:build_pending(cr.tcdata[1])
    end, 10)
    t.eq("a helper with nothing to compile takes no pane", cr.ui:build_assignment(cr.tcdata[1]).titles, {
        se = " Errors: main.cpp ",
        so = " Errors: brute.cpp ",
        eo = " Errors: checker.cpp ",
    })
    cr:kill_all_processes()
    cr.ui:delete()

    -- A helper that failed to compile is a failed build: the Compile row says so, beside the
    -- pane holding what its compiler wrote, rather than over the board in a float.
    require("tuna.config").setup({
        -- A different compile command, so the build cache answers this run afresh.
        compile_command = { cpp = { exec = ccx, args = { "$(FNAME)", "-again" } } },
        run_command = { cpp = { exec = solx } },
    })
    vim.system = function(argv, _, on_exit)
        local broke = vim.tbl_contains(argv, "gen.cpp")
        if on_exit then
            vim.schedule(function()
                on_exit({
                    code = broke and 1 or 0,
                    signal = 0,
                    stdout = "",
                    stderr = broke and "gen.cpp:1: error\n" or "",
                })
            end)
        end
        return { kill = function() end, wait = function() return { code = 0 } end, pid = 0 }
    end
    require("tuna.stress").run(bbuf, 1)
    local broke = require("tuna.stress").active[bbuf]
    vim.wait(5000, function()
        return broke.tcdata[1].exit_code ~= nil and not broke:build_pending(broke.tcdata[1])
    end, 10)
    t.eq("a helper that failed to compile is a failed build", {
        broke.tcdata[1].status,
        broke.tcdata[1].hlgroup,
        broke.tcdata[1].exit_code,
    }, { "FAILED", "TunaWarning", 0 })
    t.has(
        "with what its compiler said in that source's pane",
        broke.ui:build_assignment(broke.tcdata[1]).text.so,
        "gen.cpp:1: error"
    )
    t.ok("and nothing searching, the run being over", broke:idle(), broke.finished)
    t.eq("the search never started on a helper that is not there", broke.iter, 0)
    broke:kill_all_processes()
    broke.ui:delete()

    -- Everything a run compiles goes at once: four programs with four compilers, and
    -- queueing them behind one another is most of what a run waits for. Nothing here ever
    -- answers, so what is in flight is what was started before anything finished.
    require("tuna.config").setup({
        compile_command = { cpp = { exec = ccx, args = { "$(FNAME)", "-at-once" } } },
        run_command = { cpp = { exec = solx } },
    })
    local inflight = {}
    vim.system = function(argv, _, _)
        for _, a in ipairs(argv) do
            if a:match("%.cpp$") then
                inflight[a] = true
            end
        end
        return { kill = function() end, wait = function() return { code = 0 } end, pid = 0 }
    end
    require("tuna.stress").run(bbuf, 1)
    local at_once = require("tuna.stress").active[bbuf]
    t.eq("every source a run compiles is building at once", inflight, {
        ["main.cpp"] = true,
        ["gen.cpp"] = true,
        ["brute.cpp"] = true,
        ["checker.cpp"] = true,
    })
    at_once:kill_all_processes()
    at_once.ui:delete()

    -- The other order: a helper that failed while the solution was still compiling. The
    -- solution's own clean exit must not write the failure off the row.
    require("tuna.config").setup({
        compile_command = { cpp = { exec = ccx, args = { "$(FNAME)", "-once-more" } } },
        run_command = { cpp = { exec = solx } },
    })
    local release
    vim.system = function(argv, _, on_exit)
        local function answer(code, said)
            on_exit({ code = code, signal = 0, stdout = "", stderr = said or "" })
        end
        if vim.tbl_contains(argv, "main.cpp") then
            release = function()
                answer(0) -- the solution builds cleanly, but only once the test says so
            end
        elseif on_exit then
            vim.schedule(function()
                answer(vim.tbl_contains(argv, "checker.cpp") and 1 or 0, "checker.cpp:1: error\n")
            end)
        end
        return { kill = function() end, wait = function() return { code = 0 } end, pid = 0 }
    end
    local late = require("tuna.runner").new(bbuf)
    late:show_ui()
    late:run_testcases({ [0] = { input = "1\n" } }, true)
    vim.wait(5000, function()
        return release ~= nil and (late.builds[1] or {}).output ~= nil
    end, 10)
    t.ok("the checker failed while the solution was still building", late.builds[1].failed, late.builds)
    release()
    settled(late)
    t.eq("and the solution's own clean build does not write that off the row", late.tcdata[1].status, "FAILED")
    late.ui:delete()

    -- With only the solution to build there is nothing to tell apart: the Errors pane keeps
    -- its name and the grid is the one that was configured for the build step.
    local odir = t.tempdir()
    t.write(odir, "main.cpp", "int main(){}\n")
    vim.cmd("edit " .. odir .. "/main.cpp")
    vim.bo.filetype = "cpp"
    local obuf = vim.api.nvim_get_current_buf()
    local onl = require("tuna.runner").new(obuf)
    onl:show_ui()
    onl:run_testcases({ [0] = { input = "1\n" } }, true)
    settled(onl)
    t.eq("one source alone keeps the build step's configured grid", (onl.ui:row_layout(1)), {
        { 3, "tc" },
        { 8, "se" },
    })
    t.eq("and the Errors pane its own name", onl.ui:build_assignment(onl.tcdata[1]).titles, {})
    onl.ui:delete()

    vim.system = real_system
    require("tuna.config").setup({})
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

--------------------------------------------------------------------------------
-- Which row the board opens on, in every mode
--------------------------------------------------------------------------------

-- One rule, whatever built the rows: listing a problem opens on its first real row, since the
-- Compile step is where a run starts rather than something to read; a run moves to the row it
-- is about once the build turns out to have had nothing to say; and neither happens once the
-- selector has been moved by hand, because a row someone chose is not a default. The row a run
-- is about is its first real row everywhere except interactive, which holds one session at a
-- time and follows it — in live that row is the only one that can be typed into.
local wdir = t.tempdir()
t.write(wdir, "sol.cpp", "int main(){}\n")
t.write(wdir, "gen.cpp", "int main(){}\n")
t.write(wdir, "brute.cpp", "int main(){}\n")
t.write(wdir, "sol_input0.txt", "1\n")
t.write(wdir, "sol_output0.txt", "1\n")
t.write(wdir, "sol_input1.txt", "2\n")
t.write(wdir, "sol_output1.txt", "2\n")
vim.cmd("edit " .. wdir .. "/sol.cpp")
vim.bo.filetype = "cpp"
local wbuf = vim.api.nvim_get_current_buf()
local wtcs = require("tuna.testcases").buf_get_testcases(wbuf)

---The first row that is not the build step: what every mode is expected to land on.
local function first_real_row(r)
    for i, tc in ipairs(r.tcdata) do
        if tc.tcnum ~= "Compile" then
            return i
        end
    end
    return 1
end

local boards = {
    {
        name = "a normal run",
        show = function()
            local r = require("tuna.runner").new(wbuf)
            r:load_testcases(wtcs)
            r:show_ui()
            return r
        end,
        run = function()
            local r = require("tuna.runner").new(wbuf)
            r:show_ui()
            r:run_testcases(wtcs, true)
            return r
        end,
    },
    {
        name = "run-all",
        show = function()
            require("tuna.multi").show(wbuf)
            return require("tuna.multi").active[wbuf]
        end,
        run = function()
            require("tuna.multi").run(wbuf)
            return require("tuna.multi").active[wbuf]
        end,
    },
    {
        name = "stress",
        show = function()
            require("tuna.stress").show(wbuf)
            return require("tuna.stress").active[wbuf]
        end,
        run = function()
            require("tuna.stress").run(wbuf, 1)
            return require("tuna.stress").active[wbuf]
        end,
    },
    {
        name = "interactive",
        -- Sessions are held one row at a time, so the row shown is the one being talked to.
        run_row = function(r)
            return r.active_index
        end,
        show = function()
            require("tuna.interactive").show(wbuf)
            return require("tuna.interactive").active[wbuf]
        end,
        run = function()
            require("tuna.interactive").run(wbuf, { "feed" })
            return require("tuna.interactive").active[wbuf]
        end,
    },
}

---Let the rows, the build and the scheduled renders settle, then say which row is shown.
local function shown_row(r, want)
    vim.wait(3000, function()
        return r.ui ~= nil and r.ui.ui_visible and #r.tcdata > 0 and r.ui.update_testcase == want
    end, 20)
    vim.wait(150, function()
        return false
    end)
    return r.ui and r.ui.update_testcase
end

for _, board in ipairs(boards) do
    stub_system()
    local r = board.show()
    t.eq(board.name .. ": listed, it opens on the first row that is not the build", shown_row(r, first_real_row(r)), first_real_row(r))
    t.eq(board.name .. ": with the cursor on it, the choice still the board's", {
        vim.api.nvim_win_get_cursor(r.ui.windows.tc.winid)[1],
        r.ui.user_moved,
    }, { first_real_row(r), false })
    r:kill_all_processes()
    r:delete_ui()

    r = board.run()
    vim.wait(3000, function()
        return r.ui ~= nil and r.ui.ui_visible and #r.tcdata > 0 and r.completed
    end, 20)
    vim.wait(200, function()
        return false
    end)
    local want = board.run_row and board.run_row(r) or first_real_row(r)
    t.eq(board.name .. ": run, a silent build hands over the row the run is about", r.ui.update_testcase, want)
    r:kill_all_processes()
    r:delete_ui()
    vim.system = real_system
end

-- A build that failed reads the same in every mode that has a Compile row: it is one piece of
-- code (`build_solution`), so the row wears the verdict the compiler gave it, and the runner
-- settles instead of holding the board open for a run that never started.
local built = 0
for _, board in ipairs(boards) do
    spawns = {}
    vim.system = function(argv, _, on_exit)
        spawns[#spawns + 1] = { argv = argv }
        local broke = argv[1] == "g++"
        if on_exit then
            vim.schedule(function()
                on_exit({ code = broke and 1 or 0, signal = 0, stdout = "", stderr = "" })
            end)
        end
        return { kill = function() end, wait = function() return { code = 0 } end, pid = 0 }
    end
    local r = board.run()
    vim.wait(3000, function()
        return r.tcdata[1] ~= nil and r.tcdata[1].exit_code ~= nil and r:idle()
    end, 20)
    if r.tcdata[1] and r.tcdata[1].tcnum == "Compile" then
        built = built + 1
        t.eq(board.name .. ": a build that failed says so on its row", {
            r.tcdata[1].status,
            r.tcdata[1].hlgroup,
        }, { "RET 1", "TunaWarning" })
        t.ok(board.name .. ": and the run settles, nothing having started", r:idle(), r.tcdata[1])
        -- The build step's own grid has an Errors pane whatever the configured one lacks,
        -- so the failure is read where the run left the cursor, with nothing opened over it.
        vim.wait(300, function()
            return false
        end)
        t.eq(board.name .. ": read on the build step itself, nothing opened over the board", {
            r.ui.update_testcase,
            r.ui.viewer_winid,
        }, { 1, nil })
        local ran = 0
        for _, spawn in ipairs(spawns) do
            if spawn.argv[1] ~= "g++" then
                ran = ran + 1
            end
        end
        t.eq(board.name .. ": with nothing spawned behind it", ran, 0)
    end
    r:kill_all_processes()
    r:delete_ui()
    vim.system = real_system
end
t.ok("which is every mode that builds a solution of its own", built >= 3, built)

-- The board's own choice is not a move by hand: while it opens, the row it is about to choose
-- and the line the cursor is on have to agree, or the first cursor event the editor sends
-- reads as the user taking over and the board never chooses again.
stub_system()
local fresh = require("tuna.runner").new(wbuf)
fresh:load_testcases(wtcs)
fresh:show_ui()
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = fresh.ui.windows.tc.bufnr })
vim.wait(1000, function()
    return fresh.ui.update_testcase == 2
end, 20)
t.eq("a cursor event while the board opens is not a move by hand", { fresh.ui.update_testcase, fresh.ui.user_moved }, { 2, false })
fresh:delete_ui()
vim.system = real_system

-- A conversation follows its sessions, but not once the selector has been taken over: the
-- next session would pull the cursor off the row someone chose to read.
stub_system()
require("tuna.interactive").run(wbuf, { "feed" })
local held = require("tuna.interactive").active[wbuf]
vim.wait(3000, function()
    return held.ui ~= nil and held.ui.ui_visible and held.completed
end, 20)
local held_tc = held.ui.windows.tc
vim.api.nvim_win_set_cursor(held_tc.winid, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = held_tc.bufnr })
t.eq("the selector can be taken over mid-conversation", held.ui.update_testcase, 1)
held:run_testcases()
vim.wait(200, function()
    return false
end)
vim.wait(3000, function()
    return held.completed
end, 20)
vim.wait(200, function()
    return false
end)
t.eq("and the sessions that follow leave it where it was put", held.ui.update_testcase, 1)
held:kill_all_processes()
held:delete_ui()
vim.system = real_system

-- A list that gets shorter than the row the board chose takes the choice with it, rather than
-- leaving Vim to clamp the cursor onto another row, which reads as a move by hand.
stub_system()
local shrink = require("tuna.runner").new(wbuf)
shrink:load_testcases(wtcs)
shrink:show_ui()
vim.wait(1000, function()
    return shrink.ui ~= nil and shrink.ui.update_testcase == 2
end, 20)
shrink.ui:follow_row(3) -- as a conversation does, ending on the row it was held on
t.eq("the board can choose the last row", { shrink.ui.update_testcase, shrink.ui.user_moved }, { 3, false })
shrink:load_testcases({ [0] = { input = "1\n", output = "1\n" } })
vim.wait(1000, function()
    return #shrink.tcdata == 2
end, 20)
vim.wait(200, function()
    return false
end)
t.eq("a shorter list moves the choice down with it", { shrink.ui.update_testcase, shrink.ui.user_moved }, { 2, false })
t.eq("with the cursor on it", vim.api.nvim_win_get_cursor(shrink.ui.windows.tc.winid)[1], 2)
shrink:delete_ui()
vim.system = real_system

-- Which row a board opens on, as a rule over the rows themselves. A run's build is the row
-- from the moment the run starts, not from the moment the compiler is spawned: the two are a
-- tick apart, and a board opened in between drew the panes of a run for a build about to
-- start, then redrew them — the flash of a grid that was never the right one.
stub_system()
local opening = require("tuna.runner").new(wbuf)
opening:load_testcases(wtcs)
opening:show_ui()
vim.wait(1000, function()
    return opening.ui.update_testcase == 2
end, 20)
local build_row = opening.tcdata[1]
t.eq("listed, with nothing built, the board opens on the first testcase", opening.ui:initial_row(), 2)
opening.preloaded = false
build_row.running, build_row.exit_code = false, nil
t.eq("a run whose build has not finished opens on it, spawned or not", opening.ui:initial_row(), 1)
build_row.exit_code = 0
t.eq("and on the first testcase once the build ends with nothing to say", opening.ui:initial_row(), 2)
build_row.stderr = "warning: unused variable"
t.eq("unless it said something", opening.ui:initial_row(), 1)
-- The row last looked at is where a board reopens, except while a run is building: every run
-- starts on its build, rather than the first one differing from the ones after it.
build_row.stderr, build_row.exit_code = "", 0
opening.ui:goto_row(3)
t.eq("a board reopens on the row last looked at", opening.ui:opening_row(), 3)
build_row.exit_code = nil
t.eq("unless a run is building, which every run opens on", opening.ui:opening_row(), 1)
opening:delete_ui()
vim.system = real_system

-- A build still going keeps the cursor on itself, whatever drives it: interactive and stress
-- compile by hand rather than through a testcase row, and a row that is building has to say so
-- or the board moves off it before there is anything to move to.
local held_exit
vim.system = function(_, _, on_exit)
    held_exit = on_exit
    return {
        kill = function() end,
        wait = function()
            return { code = 0 }
        end,
        pid = 0,
        is_closing = function()
            return false
        end,
    }
end
for _, building in ipairs({
    { name = "interactive", start = function()
        require("tuna.interactive").run(wbuf, { "feed" })
        return require("tuna.interactive").active[wbuf]
    end },
    { name = "stress", start = function()
        require("tuna.stress").run(wbuf, 1)
        return require("tuna.stress").active[wbuf]
    end },
}) do
    held_exit = nil
    local r = building.start()
    vim.wait(2000, function()
        return r.ui ~= nil and r.ui.ui_visible and #r.tcdata > 0 and held_exit ~= nil
    end, 20)
    vim.wait(200, function()
        return false
    end)
    t.eq(building.name .. ": a run opens on the build while it is still going", {
        r.ui.update_testcase,
        r.compile_entry.running,
    }, { 1, true })
    held_exit({ code = 0, signal = 0, stdout = "", stderr = "" })
    vim.wait(2000, function()
        return r.ui.update_testcase ~= 1
    end, 20)
    -- Off the build and onto a real row: which one is the mode's business (interactive walks
    -- its sessions from there), the point being that it waited for the build to end.
    t.ok(building.name .. ": and moves on once it ends with nothing to say", r.ui.update_testcase >= 2, r.ui.update_testcase)
    t.eq(building.name .. ": the build stops saying it is running", r.compile_entry.running, false)
    r:kill_all_processes()
    r:delete_ui()
end
vim.system = real_system

-- A build with something to say keeps the cursor: that row is the answer to the run.
vim.system = function(argv, _, on_exit)
    if on_exit then
        vim.schedule(function()
            on_exit({ code = 0, signal = 0, stdout = "", stderr = "warning: unused variable" })
        end)
    end
    return { kill = function() end, wait = function() return { code = 0 } end, pid = 0 }
end
local noisy = require("tuna.runner").new(wbuf)
noisy:show_ui()
noisy:run_testcases(wtcs, true)
vim.wait(2000, function()
    return noisy.completed
end, 20)
vim.wait(200, function()
    return false
end)
t.eq("a build that printed something keeps the row, so it can be read", noisy.ui.update_testcase, 1)
noisy:delete_ui()
vim.system = real_system

-- A selector moved by hand holds its row while the run it is watching lands, the next run
-- asked for hands the choice back, and reopening the board returns to the row last looked at.
stub_system()
vim.api.nvim_set_current_buf(wbuf)
local C3 = require("tuna.commands")
-- The generator and bruteforce beside this solution would make `:Tuna run` a stress run.
require("tuna.tools").set_mode(wdir .. "/sol.cpp", "normal")
C3.execute({ "run" })
local chosen = C3.runners[wbuf]
vim.wait(3000, function()
    return chosen ~= nil and chosen.ui ~= nil and chosen.ui.ui_visible and chosen.completed
end, 20)
vim.wait(200, function()
    return false
end)
local function move_to(row)
    local w = chosen.ui.windows.tc
    vim.api.nvim_win_set_cursor(w.winid, { row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = w.bufnr })
end
move_to(3)
t.eq("moving the selector by hand selects that row", { chosen.ui.update_testcase, chosen.ui.user_moved }, { 3, true })
chosen:update_ui(true)
vim.wait(300, function()
    return false
end)
t.eq("and results landing leave it where it was put", chosen.ui.update_testcase, 3)

C3.execute({ "run" })
vim.wait(3000, function()
    return chosen.completed and chosen.ui.update_testcase == 2
end, 20)
t.eq("a run asked for hands the choice back", { chosen.ui.update_testcase, chosen.ui.user_moved }, { 2, false })

move_to(3)
chosen.ui:delete()
C3.show_results_ui(wbuf)
vim.wait(2000, function()
    return chosen.ui.ui_visible and chosen.ui.update_testcase == 3
end, 20)
t.eq("and reopening the board returns to the row last looked at", chosen.ui.update_testcase, 3)
chosen:kill_all_processes()
chosen:delete_ui()
C3.runners[wbuf] = nil
require("tuna.tools").set_mode(wdir .. "/sol.cpp", nil)
vim.system = real_system
vim.fn.delete(wdir, "rf")

--------------------------------------------------------------------------------
-- The build step's own grid
--------------------------------------------------------------------------------

-- The build is not a testcase: no input, no answer, nothing to compare. Its row is shown with
-- the Errors pane alone, where a compiler's complaint has the room to be read, rather than
-- with three empty frames beside it. The panes are re-tiled rather than rebuilt, so they keep
-- their buffers and everything held on them.
local function drawn_panes(ui)
    local names = {}
    for name, w in pairs(ui.windows) do
        if w.winid and vim.api.nvim_win_is_valid(w.winid) then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end
local FULL_GRID = { "eo", "se", "si", "so", "st", "tc" }
local BUILD_GRID = { "se", "st", "tc" }

stub_system()
local grid = require("tuna.runner").new(wbuf)
grid:load_testcases(wtcs)
grid:show_ui()
vim.wait(1000, function()
    return grid.ui.update_testcase == 2
end, 20)
t.eq("a testcase row is shown with the mode's panes", drawn_panes(grid.ui), FULL_GRID)
local pane_buffers = {}
for name, w in pairs(grid.ui.windows) do
    pane_buffers[name] = w.bufnr
end
local selector_win = grid.ui.windows.tc.winid

grid.ui:goto_row(1)
vim.wait(1000, function()
    return #drawn_panes(grid.ui) == #BUILD_GRID
end, 20)
t.eq("the build step is shown with Errors and nothing else", drawn_panes(grid.ui), BUILD_GRID)
local kept = true
for name, w in pairs(grid.ui.windows) do
    kept = kept and w.bufnr == pane_buffers[name]
end
t.ok("the panes keep their buffers across the change", kept, { pane_buffers })
t.eq("and a pane that stays is moved, not drawn anew", grid.ui.windows.tc.winid, selector_win)

grid.ui:goto_row(2)
vim.wait(1000, function()
    return #drawn_panes(grid.ui) == #FULL_GRID
end, 20)
t.eq("and moving off it brings the grid back", drawn_panes(grid.ui), FULL_GRID)
grid:delete_ui()

-- Interactive draws its own grid for a conversation, and the build step is the build step.
require("tuna.interactive").run(wbuf, { "live" }, { show_only = true })
local conv_grid = require("tuna.interactive").active[wbuf]
vim.wait(1000, function()
    return conv_grid.ui ~= nil and conv_grid.ui.ui_visible and #conv_grid.tcdata > 0
end, 20)
t.eq("a conversation keeps its columns", drawn_panes(conv_grid.ui), { "se", "si", "so", "st", "tc" })
conv_grid.ui:goto_row(1)
vim.wait(1000, function()
    return #drawn_panes(conv_grid.ui) == #BUILD_GRID
end, 20)
t.eq("and its build step is shown the same way as everything else's", drawn_panes(conv_grid.ui), BUILD_GRID)
conv_grid:kill_all_processes()
conv_grid:delete_ui()

-- Each interactive source draws the grid `interactive.layouts` gives it.
require("tuna.interactive").run(wbuf, { "live" }, { show_only = true })
local shaped = require("tuna.interactive").active[wbuf]
vim.wait(1000, function()
    return shaped.ui ~= nil and shaped.ui.ui_visible and #shaped.tcdata > 0
end, 20)
t.eq("live draws the conversation by default", drawn_panes(shaped.ui), { "se", "si", "so", "st", "tc" })
t.eq("named by the option it came from", select(2, shaped:layout()), "interactive.layouts.live")
shaped.config = vim.tbl_deep_extend("force", shaped.config, {
    interactive = { layouts = { live = { { 1, "tc" }, { 1, "eo" } } } },
})
shaped:update_ui(true)
vim.wait(1000, function()
    return #drawn_panes(shaped.ui) == 3
end, 20)
t.eq("and a grid of your own instead", drawn_panes(shaped.ui), { "eo", "st", "tc" })

-- A layout that does not hold up is reported as the option it came from, not as "the run
-- mode's", which is no help in finding it.
local said = {}
local real_notify = vim.notify
vim.notify = function(msg)
    said[#said + 1] = tostring(msg)
end
shaped.config = vim.tbl_deep_extend("force", shaped.config, {
    interactive = { layouts = { live = { { 1, "so" } } } }, -- no selector
})
shaped:update_ui(true)
vim.wait(1000, function()
    return #said > 0
end, 20)
vim.notify = real_notify
t.ok("a broken layout is reported by the option it came from", (said[1] or ""):find("interactive.layouts.live", 1, true) ~= nil, said)
shaped:kill_all_processes()
shaped:delete_ui()

-- `feed` replays a stored testcase, so it keeps the grid configured for a run until told not to.
require("tuna.interactive").run(wbuf, { "feed" }, { show_only = true })
local fed = require("tuna.interactive").active[wbuf]
vim.wait(1000, function()
    return fed.ui ~= nil and fed.ui.ui_visible and #fed.tcdata > 0
end, 20)
t.eq("feed keeps the grid of a run", { fed:layout() }, {})
fed.config = vim.tbl_deep_extend("force", fed.config, {
    interactive = { layouts = { feed = { { 1, "tc" }, { 2, "si" } } } },
})
fed:update_ui(true)
vim.wait(1000, function()
    return #drawn_panes(fed.ui) == 3
end, 20)
t.eq("until one is configured for it", drawn_panes(fed.ui), { "si", "st", "tc" })
fed:kill_all_processes()
fed:delete_ui()

-- `runner_ui.compile_layout = false` keeps whatever grid the mode draws.
local kept_grid = require("tuna.runner").new(wbuf)
kept_grid.config = vim.tbl_deep_extend("force", kept_grid.config, { runner_ui = { compile_layout = false } })
kept_grid:load_testcases(wtcs)
kept_grid:show_ui()
vim.wait(1000, function()
    return kept_grid.ui.update_testcase == 2
end, 20)
kept_grid.ui:goto_row(1)
vim.wait(500, function()
    return false
end)
t.eq("turned off, the build step keeps the grid of a run", drawn_panes(kept_grid.ui), FULL_GRID)
kept_grid:delete_ui()
vim.system = real_system

--------------------------------------------------------------------------------
-- A `:Tuna` command typed in one of tuna's own windows
--------------------------------------------------------------------------------

-- A results pane is not a file, so a command typed there is about the solution the pane is
-- showing. Acting on the pane itself compiled nothing and kept the problem's run state under
-- a name that is not a path, writing it under whatever directory the editor was started in.
local C2 = require("tuna.commands")
local tools2 = require("tuna.tools")
local pdir = t.tempdir()
t.write(pdir, "sol.cpp", "int main(){}\n")
t.write(pdir, "sol_input0.txt", "1\n")
vim.cmd("edit " .. pdir .. "/sol.cpp")
vim.bo.filetype = "cpp"
local pbuf = vim.api.nvim_get_current_buf()
local sol_path = pdir .. "/sol.cpp"

stub_system()
local pane_runner = require("tuna.runner").new(pbuf)
pane_runner:show_ui()
vim.api.nvim_set_current_win(pane_runner.ui.windows.so.winid)
t.eq("a command typed in a pane is about the solution it shows", C2.target_buffer(), pbuf)
t.eq("a buffer of its own is itself", C2.target_buffer(pbuf), pbuf)

C2.execute({ "run", "all" })
vim.wait(3000, function()
    local matrix = require("tuna.multi").active[pbuf]
    return matrix ~= nil and matrix.completed
end, 20)
vim.system = real_system
t.eq("so a run typed there forces the mode for the solution", tools2.get_mode(sol_path), "all")
t.eq("and nothing is written beside a name that is not a path", vim.fn.isdirectory(vim.fn.getcwd() .. "/tuna:"), 0)
local pane_buf = pane_runner.ui.windows.so.bufnr
local matrix = require("tuna.multi").active[pbuf]
if matrix then
    matrix:delete_ui()
end
pane_runner:delete_ui()
-- A pane's buffer is wiped with its window, so what it belonged to is forgotten with it, or a
-- later command would be sent to a runner that is gone.
t.eq("a pane that is gone belongs to nothing", require("tuna.runner_ui").owner_of(pane_buf), nil)
vim.fn.delete(pdir, "rf")

t.report()
