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

local tcs = require("tuna.problem.testcases")

---The line of a board's `?` legend (its read-only column) that contains `text`, if any.
---@return string?
local function legend_line(ui, text)
    local _, readonly = ui:legend_sections()
    for _, line in ipairs(readonly) do
        if line:find(text, 1, true) then
            return line
        end
    end
end

--------------------------------------------------------------------------------
-- The stub: record every spawn, answer it successfully.
--------------------------------------------------------------------------------

local spawns = {}
local real_system = vim.system
local function stub_system()
    spawns = {}
    vim.system = function(argv, opts, on_exit)
        spawns[#spawns + 1] = { argv = argv, stdin = opts and opts.stdin, env = opts and opts.env }
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
            -- libstdc++'s debug mode wraps its reports at 78 columns, which a narrower pane
            -- would wrap again.
            t.eq(
                ("%s: run %d is told not to wrap a debug-mode report"):format(what, i),
                s.env and s.env.GLIBCXX_DEBUG_MESSAGE_LENGTH,
                "0"
            )
        end
    end
    t.ok(what .. ": a solution was actually run", runs > 0, spawns)
end

-- `RUN_ENV` reaches a program on top of the editor's environment: `vim.system` adds it, and
-- `uv.spawn`, which replaces the environment, is handed all of it with `RUN_ENV` over it.
do
    local tools = require("tuna.run.tools")
    local probe = { "sh", "-c", 'printf "%s:%s" "$GLIBCXX_DEBUG_MESSAGE_LENGTH" "$HOME"' }
    local through_system = real_system(probe, { env = tools.RUN_ENV, text = true }):wait().stdout
    local out, got = vim.uv.new_pipe(), ""
    local handle = vim.uv.spawn(probe[1], { args = { probe[2], probe[3] }, env = tools.spawn_env(), stdio = { nil, out, nil } }, function() end)
    out:read_start(function(_, data)
        got = got .. (data or "")
    end)
    vim.wait(2000, function()
        return got ~= ""
    end, 10)
    handle:close()
    t.eq("what tuna runs gets RUN_ENV over the editor's environment, by vim.system and uv.spawn alike", {
        through_system,
        got,
    }, { "0:" .. vim.env.HOME, "0:" .. vim.env.HOME })
end

-- Until what the board has scheduled has run, its debounced settle pass included.
local function drain(ui)
    t.drain(function()
        return ui ~= nil and (ui.render_scheduled or ui.relayouting or (ui.settle_timer and ui.settle_timer:is_active()))
    end)
end

-- Until the run is over: every run claims its runner as it starts, so an idle runner with no
-- row still running or being judged has nothing left to land. Read off the runner rather than
-- off the rows' words, which a run legitimately leaves blank (a failed build's testcases) or
-- `NOT RUN`.
local function settled(runner)
    vim.wait(5000, function()
        if not (runner and runner.tcdata and runner.tcdata[1] and runner:idle()) then
            return false
        end
        for _, r in ipairs(runner.tcdata) do
            if r.running or r.judging then
                return false
            end
        end
        return true
    end, 10)
end

--------------------------------------------------------------------------------
-- Rows built without running: `:Tuna show_ui` before any `:Tuna run`
--------------------------------------------------------------------------------

local function rows_of(tctbl)
    local r = require("tuna.run").new(buf)
    r:load_testcases(tctbl)
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
local ui_test = require("tuna.runner_ui")._test
local columns, build_text, build_titles = ui_test.selector_columns, ui_test.build_text, ui_test.build_titles
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
r = require("tuna.run").new(buf)
r:run_testcases({ [0] = { output = "42\n" }, [1] = { input = "hi\n" } })
settled(r)
vim.system = real_system
check_spawns("run", r.rc.exec)
t.ok("both testcases ran", #spawns >= 3, #spawns) -- compile + two testcases
vim.wait(1000, function()
    return r.completed
end, 20)
local core = require("tuna.run.core")
local sidecar = require("tuna.problem.sidecar")
-- The stub prints nothing: testcase 0 is WRONG, and testcase 1 has no answer to judge.
t.eq("a finished run saves its local verdict, over the testcases it judged", { core.local_verdict(dir .. "/sol.cpp") }, { 0, 1 })
sidecar.set_entry(dir .. "/sol.cpp", "results", nil)

-- How many run at once: `multiple_testing`, where 0 is all of them and -1 one per core.
t.eq("multiple_testing is how many run at once", core.parallelism({ multiple_testing = 2 }, 5), 2)
t.eq("0 runs every one at once", core.parallelism({ multiple_testing = 0 }, 5), 5)
t.eq("-1 runs one per core", core.parallelism({ multiple_testing = -1 }, 5), vim.uv.available_parallelism())
t.eq("and never fewer than one", core.parallelism({ multiple_testing = 0 }, 0), 1)

--------------------------------------------------------------------------------
-- Reusing a build
--------------------------------------------------------------------------------

-- A build is reused while what it was made from is unchanged: the compile command, the
-- source, and every header the source includes that can be found, beside the file
-- including it or in the command's include directories. The compiler's own (system)
-- headers are not followed.
do
    local tools = require("tuna.run.tools")
    local bdir, idir = t.tempdir(), t.tempdir()
    t.write(bdir, "sol.cpp", '#include <vector>\n#include "local.h"\n  #  include <lib.h>\nint main(){}\n')
    t.write(bdir, "local.h", '#include "local.h"\n#include "deeper.h"\n') -- includes itself: a cycle
    t.write(bdir, "deeper.h", "\n")
    t.write(idir, "lib.h", "\n")
    local edits = 0
    ---Change a file's contents.
    local function edit(path)
        edits = edits + 1
        local f = assert(io.open(path, "a"))
        f:write("// edit " .. edits .. "\n")
        f:close()
    end
    ---Change a file's modification time and nothing else.
    local function touch(path)
        local st = assert(vim.uv.fs_stat(path))
        vim.uv.fs_utime(path, st.atime.sec, st.mtime.sec + 10)
    end
    local cmd = { exec = "g++", args = { "-I", idir, "sol.cpp", "-o", "sol" } }
    ---The files a stamp is made from, by name.
    local function inputs(c)
        local files = {}
        for line in (tools.build_stamp(bdir .. "/sol.cpp", c, bdir) or ""):gmatch("[^\n]+") do
            local path = line:match("^(/.-)%z")
            files[#files + 1] = path and vim.fs.basename(path) or nil
        end
        return files
    end
    local stamp = tools.build_stamp(bdir .. "/sol.cpp", cmd, bdir)
    t.ok("a source has a stamp, its include cycle notwithstanding", stamp ~= nil)
    t.eq("it reads the source and every header found, and no system header", inputs(cmd), { "sol.cpp", "local.h", "deeper.h", "lib.h" })
    t.eq("and the same files make the same stamp", tools.build_stamp(bdir .. "/sol.cpp", cmd, bdir), stamp)
    for _, edited in ipairs({ bdir .. "/sol.cpp", bdir .. "/deeper.h", idir .. "/lib.h" }) do
        local before = tools.build_stamp(bdir .. "/sol.cpp", cmd, bdir)
        edit(edited)
        t.ok("editing " .. vim.fs.basename(edited) .. " changes it", tools.build_stamp(bdir .. "/sol.cpp", cmd, bdir) ~= before)
    end
    -- The contents decide, not the modification time: a save that leaves the text as it was
    -- (an edit a formatter undid on save) is no change.
    local before = tools.build_stamp(bdir .. "/sol.cpp", cmd, bdir)
    touch(bdir .. "/sol.cpp")
    touch(idir .. "/lib.h")
    t.eq("a file saved unchanged leaves it as it was", tools.build_stamp(bdir .. "/sol.cpp", cmd, bdir), before)
    local text = vim.fn.readfile(bdir .. "/deeper.h", "b")
    edit(bdir .. "/deeper.h")
    vim.fn.writefile(text, bdir .. "/deeper.h", "b")
    t.eq("and so does an edit undone", tools.build_stamp(bdir .. "/sol.cpp", cmd, bdir), before)
    local joined = { exec = "g++", args = { "-I" .. idir, "sol.cpp", "-o", "sol" } }
    t.eq("-Idir is read like -I dir", inputs(joined), inputs(cmd))
    local flagged = { exec = "g++", args = { "-I", idir, "-O2", "sol.cpp", "-o", "sol" } }
    t.ok("a flag changes it", tools.build_stamp(bdir .. "/sol.cpp", flagged, bdir) ~= tools.build_stamp(bdir .. "/sol.cpp", cmd, bdir))
    t.eq("a source that can't be read has none, so is never reused", tools.build_stamp(bdir .. "/gone.cpp", cmd, bdir), nil)

    -- The solution's build, run after run. The compiler is stubbed and says something, so the
    -- reused build can be seen to keep its words.
    t.write(bdir, "sol.cpp", '#include "local.h"\nint main(){}\n')
    t.write(bdir, "sol_input0.txt", "1\n")
    vim.cmd("edit " .. bdir .. "/sol.cpp")
    vim.bo.filetype = "cpp"
    local bbuf = vim.api.nvim_get_current_buf()
    local function run_once(compiler_code)
        spawns = {}
        vim.system = function(argv, opts, on_exit)
            spawns[#spawns + 1] = { argv = argv, stdin = opts and opts.stdin }
            local building = argv[1] == "g++"
            vim.schedule(function()
                on_exit({ code = building and compiler_code or 0, signal = 0, stdout = "", stderr = building and "sol.cpp:1: warning\n" or "" })
            end)
            return { kill = function() end, wait = function() return { code = 0 } end, pid = 0 }
        end
        local br = require("tuna.run").new(bbuf)
        br:run_testcases({ [0] = { input = "1\n" } })
        settled(br)
        vim.system = real_system
        local built = false
        for _, s in ipairs(spawns) do
            built = built or s.argv[1] == "g++"
        end
        return built, br.tcdata[1]
    end
    t.ok("the first run builds", (run_once(0)))
    local built, row = run_once(0)
    t.ok("with no program to run, the next one builds again", built)
    t.write(bdir, "sol", "") -- what the compiler would have written
    run_once(0)
    built, row = run_once(0)
    t.eq("an unchanged solution is not built again", built, false)
    t.eq("its row says the build was reused", { row.status, row.exit_code }, { "CACHED", 0 })
    t.eq("and keeps what its compiler said", row.stderr, "sol.cpp:1: warning\n")
    touch(bdir .. "/sol.cpp")
    t.eq("a solution saved with nothing changed is not built again either", (run_once(0)), false)
    edit(bdir .. "/local.h")
    t.ok("a header it includes edited, it is built again", (run_once(0)))
    edit(bdir .. "/sol.cpp")
    built, row = run_once(1)
    t.ok("a build that fails", built and row.status == "RET 1", row)
    t.ok("is never reused", (run_once(0)))
    os.remove(bdir .. "/sol")
    t.ok("nor is one whose program is gone", (run_once(0)))

    -- Run-all and the helpers go by the same rule, and share the builds.
    t.write(bdir, "sol", "")
    run_once(0)
    stub_system()
    require("tuna.run.modes.multi").run(bbuf)
    local mr = require("tuna.run.modes.multi").active[bbuf]
    settled(mr)
    vim.system = real_system
    t.eq("run-all reuses the build a run made", vim.tbl_filter(function(s)
        return vim.tbl_contains(s.argv, "sol.cpp")
    end, spawns), {})
    mr:kill_all_processes()
    mr:delete_ui()
    t.write(bdir, "gen.cpp", '#include "local.h"\nint main(){}\n')
    t.write(bdir, "gen", "")
    local gen = { exec = "./gen", args = {}, cwd = bdir, source = bdir .. "/gen.cpp", compile = { exec = "g++", args = { "gen.cpp", "-o", "gen" } }, compile_dir = bdir }
    ---Prepare `spec` as a run would, and count the compiles. A run resolves its helpers
    ---anew, so a new run is a copy of the spec, and the same table is the same run.
    local function prepared(spec, code)
        spawns = {}
        vim.system = function(argv, _, on_exit)
            spawns[#spawns + 1] = { argv = argv }
            vim.schedule(function()
                on_exit({ code = code or 0, signal = 0, stdout = "", stderr = "" })
            end)
            return { kill = function() end, wait = function() return { code = 0 } end, pid = 0 }
        end
        local done
        tools.prepare(spec or vim.deepcopy(gen), function(ok)
            done = ok
        end)
        vim.wait(1000, function()
            return done ~= nil
        end, 10)
        vim.system = real_system
        return #spawns, done
    end
    prepared()
    t.eq("a helper unchanged is not built again", prepared(), 0)
    edit(bdir .. "/local.h")
    t.eq("and is when a header it includes is edited", prepared(), 1)
    -- Within the run that built it, a build is answered as it is, without reading anything
    -- again: the checker is prepared for every testcase it judges.
    local run = vim.deepcopy(gen)
    prepared(run)
    os.rename(bdir .. "/gen.cpp", bdir .. "/gen.away")
    t.eq("within its run a build is answered without its sources being read", prepared(run), 0)
    os.rename(bdir .. "/gen.away", bdir .. "/gen.cpp")
    -- A failure is answered within its run, and built again by the next one.
    local broken = vim.deepcopy(gen)
    edit(bdir .. "/gen.cpp")
    prepared(broken, 1)
    t.eq("a failed build is answered as failed within its run", { prepared(broken) }, { 0, false })
    t.eq("and built again by the next run", { prepared() }, { 1, true })

    -- A language whose includes tuna does not follow may build from files it can't see (a
    -- Rust `mod`), so its builds are not reused across runs: a helper is built once per run
    -- (a run resolves its specs anew, and a checker is prepared for every testcase), and a
    -- solution on every run.
    t.write(bdir, "gen.rs", "fn main(){}\n")
    t.write(bdir, "gen_rs", "")
    local rs = { exec = "./gen_rs", args = {}, cwd = bdir, source = bdir .. "/gen.rs", compile = { exec = "rustc", args = { "gen.rs" } }, compile_dir = bdir }
    t.eq("a Rust source has no stamp", tools.build_stamp(rs.source, rs.compile, bdir), nil)
    prepared(rs)
    t.eq("its build is reused within the run that made it", prepared(rs), 0)
    t.eq("and made again by the next run", prepared(vim.deepcopy(rs)), 1)
    t.write(bdir, "rsol.rs", "fn main(){}\n")
    t.write(bdir, "rsol", "")
    vim.cmd("edit " .. bdir .. "/rsol.rs")
    vim.bo.filetype = "rust"
    local rbuf = vim.api.nvim_get_current_buf()
    local builds = 0
    for _ = 1, 2 do
        stub_system()
        local rr = require("tuna.run").new(rbuf)
        rr:run_testcases({ [0] = { input = "1\n" } })
        settled(rr)
        vim.system = real_system
        for _, sp in ipairs(spawns) do
            builds = builds + (sp.argv[1] == "rustc" and 1 or 0)
        end
        t.eq("a Rust solution's row never reads CACHED", rr.tcdata[1].status, "DONE")
    end
    t.eq("and it is built on every run", builds, 2)
    vim.cmd("silent! bwipeout!")
    vim.fn.delete(bdir, "rf")
    vim.fn.delete(idir, "rf")
end

-- An interface that does not exist is said once and the results open as a popup, the same
-- board as ever.
do
    local quiet = vim.notify
    local said = t.capture_notifications()
    r = require("tuna.run").new(buf)
    r.config = vim.deepcopy(r.config)
    r.config.runner_ui.interface = "tabs"
    stub_system()
    r:run_testcases({ [0] = { input = "1\n" } })
    r:show_ui()
    settled(r)
    vim.system = real_system
    vim.notify = quiet
    t.has("an unknown interface is reported", table.concat(said, "\n"), "runner_ui.interface is \"tabs\", using popup instead.")
    t.ok("and the results open as the popup board", r.ui ~= nil and r.ui.interface == require("tuna.runner_ui.popup"), r.ui)
    r:delete_ui()
end

--------------------------------------------------------------------------------
-- Both interfaces, as the row on screen changes kind
--------------------------------------------------------------------------------

-- The build step and a testcase row are drawn with different grids, so moving between them
-- re-tiles the board. The split interface opens its windows anew each time, the popup one
-- moves them, and either way focus stays on the pane it was in, the selector stays on the
-- row, the titles follow the row (the zoom's too), and a grid that can't be used is said
-- once, not on every re-tile.
local function board(interface, bad_layout)
    local quiet = vim.notify
    local said = t.capture_notifications()
    local br = require("tuna.run").new(buf)
    br.config = vim.deepcopy(br.config)
    br.config.runner_ui.interface = interface
    -- Unaccented, so a popup's titles are the ones the interface draws.
    br.config.runner_ui.editable_border_highlight = false
    if bad_layout then
        br.config.popup_ui.layout = { { 1, "tc" }, { 1, "nope" } }
        br.config.split_ui.vertical_layout = { { 1, "tc" }, { 1, "nope" } }
    end
    stub_system()
    br:run_testcases({ [0] = { input = "1\n" }, [1] = { input = "2\n" } })
    br:show_ui()
    settled(br)
    drain(br.ui)
    vim.system = real_system
    local ui = br.ui
    local function move(row)
        vim.api.nvim_set_current_win(ui.windows.tc.winid)
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui.windows.tc.bufnr })
        drain(ui)
    end
    local function state()
        local tcw = ui.windows.tc.winid
        return {
            focus = vim.api.nvim_get_current_win() == tcw and "tc" or "elsewhere",
            row = tcw and vim.api.nvim_win_is_valid(tcw) and vim.api.nvim_win_get_cursor(tcw)[1] or nil,
        }
    end
    return br, ui, move, state, function()
        vim.notify = quiet
        return said
    end
end

t.write(dir, "checker.cpp", "int main() {}\n")
-- Text to be read wraps, at word boundaries and keeping its indent: the Errors pane on a
-- testcase row and every pane on the build step, which holds compiler output. The Output,
-- Expected Output and Input panes keep their lines whole, since the diff pairs them line by line.
local function wrapping(win)
    return win and vim.api.nvim_win_is_valid(win) and { vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].breakindent }
        or nil
end
local WRAPS, WHOLE = { true, true, true }, { false, false, false }
---A conversation column's `{ wrap, scrollbind }`.
local function column(ui, name)
    local w = ui.windows[name].winid
    return w and { vim.wo[w].wrap, vim.wo[w].scrollbind }
end
---Whether a pane wears the accent that says it is typed into.
local function accented(ui, name)
    local w = ui.windows[name]
    return w.winid ~= nil
        and vim.api.nvim_win_is_valid(w.winid)
        and vim.wo[w.winid].winhighlight:find("TunaEditableBorder", 1, true) ~= nil
end
-- With the user's cursorline on: the selector's line is the row selected, always shown; a
-- pane being read has it while focused, and none otherwise, the zoom included.
local user_cursorline = vim.go.cursorline
vim.go.cursorline = true
for _, interface in ipairs({ "split", "popup" }) do
    local br, ui, move, state, done = board(interface)
    done()
    t.eq(interface .. ": a run hands the selector the first testcase, focus in it", state(), { focus = "tc", row = 2 })
    local function lit()
        local out = {}
        for _, name in ipairs({ "tc", "so", "si" }) do
            out[name] = vim.wo[ui.windows[name].winid].cursorline
        end
        return out
    end
    t.eq(interface .. ": the selector's line shows, the panes' do not", lit(), { tc = true, so = false, si = false })
    vim.api.nvim_set_current_win(ui.windows.so.winid)
    t.eq(interface .. ": the pane being read shows its line, the selector still its own", lit(), { tc = true, so = true, si = false })
    ui:zoom("si")
    t.eq(interface .. ": a zoom shows its line, the pane left does not", {
        vim.wo[ui.zoom_winid].cursorline,
        vim.wo[ui.windows.so.winid].cursorline,
    }, { true, false })
    ui:unzoom()
    -- The diff keeps the cursorline: a disagreeing line is marked only where it disagrees.
    ui:toggle_diff_view()
    vim.api.nvim_set_current_win(ui.windows.so.winid)
    t.eq(interface .. ": with the diff on, the pane being read keeps its cursorline", vim.wo[ui.windows.so.winid].cursorline, true)
    ui:toggle_diff_view()
    vim.api.nvim_set_current_win(ui.windows.tc.winid)
    -- The pane keys move from the cursor, as Vim's own window moves do: right from the
    -- selector's first rows reaches Output, level with them, not the pane level with its
    -- middle. In an editor of a usual height, where the selector runs below Output.
    if interface == "popup" then
        local lines = vim.o.lines
        vim.o.lines = 40
        ui:redraw_grid()
        local names = {}
        for name, w in pairs(ui.windows) do
            if w.winid then
                names[w.winid] = name
            end
        end
        vim.api.nvim_set_current_win(ui.windows.tc.winid)
        local walk = {}
        for _, dir in ipairs({ "l", "l", "h", "j", "h" }) do
            ui:focus_dir(dir)
            walk[#walk + 1] = names[vim.api.nvim_get_current_win()]
        end
        t.eq("popup: the pane keys move from the cursor", walk, { "so", "eo", "so", "se", "tc" })
        -- From insert mode typing carries on into a pane that can be typed into, and stops in
        -- one that cannot. Insert mode cannot be held open in a headless test, so the key's
        -- insert-mode mapping is called as it would be, and asking to leave it is recorded.
        local keys = require("tuna.config").current_setup.switch_window_keys
        local function from_insert(key)
            local code = vim.api.nvim_replace_termcodes(key, true, false, true)
            local map
            for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "i")) do
                if vim.api.nvim_replace_termcodes(m.lhs, true, false, true) == code then
                    map = m
                end
            end
            local real_cmd, stopped = vim.cmd, false
            vim.cmd = setmetatable({}, {
                __call = function(_, c)
                    stopped = stopped or c == "stopinsert"
                    return real_cmd(c)
                end,
                __index = real_cmd,
            })
            map.callback()
            vim.cmd = real_cmd
            return { names[vim.api.nvim_get_current_win()], stopped }
        end
        vim.api.nvim_set_current_win(ui.windows.si.winid)
        t.eq("popup: from insert mode, typing carries on into Expected Output, and stops in Output", {
            from_insert(keys[3]),
            from_insert(keys[1]),
        }, { { "eo", false }, { "so", true } })
        -- A zoom is the pane it shows, larger: a key there moves from that pane, from the line
        -- the zoom was on, and with no pane that way leaves the cursor on the pane.
        local function from_zoom(name, dir)
            ui:zoom(name)
            ui:focus_dir(dir)
            return names[vim.api.nvim_get_current_win()]
        end
        t.eq("popup: a pane key in a zoom moves as it would from the pane", {
            from_zoom("so", "l"),
            from_zoom("si", "h"),
            from_zoom("eo", "k"),
        }, { "eo", "se", "eo" })
        local si = ui.windows.si
        local text = vim.api.nvim_buf_get_lines(si.bufnr, 0, -1, false)
        vim.api.nvim_buf_set_lines(si.bufnr, 0, -1, false, { "1", "2", "3", "4", "5" })
        ui:zoom("si")
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        ui:focus_dir("h")
        t.eq("popup: leaving a zoom, its pane's cursor is on the line the zoom was on",
            vim.api.nvim_win_get_cursor(si.winid), { 4, 0 })
        vim.api.nvim_buf_set_lines(si.bufnr, 0, -1, false, text)
        vim.bo[si.bufnr].modified = false
        -- A pane the grid leaves out is zoomed all the same, the one way to read it, and a key
        -- there moves from the selector: from insert mode, with nothing to its left, typing
        -- stops in the selector it lands on.
        local layout = ui.config.popup_ui.layout
        ui.config.popup_ui.layout = { { 3, "tc" }, { 4, { { 1, "so" }, { 1, "se" } } }, { 4, "eo" } }
        ui:redraw_grid()
        ui:zoom("si")
        t.eq("popup: from insert mode in the zoom of a pane the grid leaves out, typing stops in the selector",
            from_insert(keys[1]), { "tc", true })
        ui.config.popup_ui.layout = layout
        vim.o.lines = lines
        ui:redraw_grid()
    end
    -- A row reads EDITED for what is typed, not for the pane's own filling, which Vim reports
    -- as a change the first time the pane is entered after it.
    local function edited()
        return table.concat(vim.api.nvim_buf_get_lines(ui.windows.tc.bufnr, 0, -1, false), "\n"):find("EDITED") ~= nil
    end
    local si = ui.windows.si.bufnr
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = si })
    t.eq(interface .. ": a change reported for a pane not typed into marks nothing", edited(), false)
    vim.api.nvim_buf_set_lines(si, 0, -1, false, { "typed" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = si })
    t.eq(interface .. ": typing marks the row at once", edited(), true)
    ui:discard_pending()
    ui.update_windows, ui.update_details = true, true
    ui:update_ui()
    drain(ui)
    t.eq(interface .. ": on a testcase row the Errors pane wraps, the others keep lines whole", {
        wrapping(ui.windows.se.winid),
        wrapping(ui.windows.so.winid),
        wrapping(ui.windows.eo.winid),
        wrapping(ui.windows.si.winid),
    }, { WRAPS, WHOLE, WHOLE, WHOLE })
    -- The selector's own line-number options, `false` by default, beside panes numbered by default.
    t.eq(interface .. ": the selector has no line numbers, the panes do", {
        vim.wo[ui.windows.tc.winid].number,
        vim.wo[ui.windows.tc.winid].relativenumber,
        vim.wo[ui.windows.se.winid].number,
    }, { false, false, true })
    move(1)
    t.eq(interface .. ": moving onto the build step keeps focus and the row", state(), { focus = "tc", row = 1 })
    t.has(interface .. ": its panes are named after their sources", ui.windows.so.title, "checker.cpp")
    t.eq(interface .. ": and every one of them wraps", { wrapping(ui.windows.se.winid), wrapping(ui.windows.so.winid) }, { WRAPS, WRAPS })
    if interface == "popup" then
        local drawn = vim.api.nvim_win_get_config(ui.windows.so.winid).title
        t.has("popup: and drawn with that name", drawn and drawn[1][1] or "", "checker.cpp")
    end
    ui:zoom("so")
    local zoomed = ui.zoom_winid and vim.api.nvim_win_get_config(ui.zoom_winid).title
    t.has(interface .. ": and zoomed with that name", zoomed and zoomed[1][1] or "", "checker.cpp")
    t.eq(interface .. ": wrapped, as the pane it shows", wrapping(ui.zoom_winid), WRAPS)
    ui:unzoom()
    move(2)
    t.eq(interface .. ": and back to a testcase row", state(), { focus = "tc", row = 2 })
    t.eq(interface .. ": where the pane is Output again", ui.windows.so.title, " Output (o) ")
    t.eq(interface .. ": keeping its lines whole again", wrapping(ui.windows.so.winid), WHOLE)
    ui:zoom("so")
    t.eq(interface .. ": as its zoom does", wrapping(ui.zoom_winid), WHOLE)
    ui:unzoom()
    -- A zoom key does nothing in a zoom: an editable pane's zoom types the letter, so no zoom
    -- takes it.
    ui:zoom("se")
    vim.api.nvim_feedkeys("o", "xt", false)
    local still = vim.api.nvim_win_get_config(ui.zoom_winid).title
    t.has(interface .. ": a zoom key in a zoom leaves it as it is", still and still[1][1] or "", "Errors")
    ui:unzoom()
    if interface == "popup" then
        local drawn = vim.api.nvim_win_get_config(ui.windows.so.winid).title
        t.eq("popup: and drawn as Output again", drawn and drawn[1][1], " Output (o) ")
    end
    -- A file opened from inside the board (`:Tuna next`, `:Tuna go`, a starter) opens in the
    -- window the board was opened over, the board put away: its panes are pinned to their own
    -- buffers, and a file shown in one would be lost with it.
    local opened_over = ui.restore_winid
    t.write(dir, "other.txt", "x\n")
    vim.api.nvim_set_current_win(ui.windows.tc.winid)
    require("tuna.ui.surface").edit(dir .. "/other.txt")
    t.eq(interface .. ": a file opened from the board opens where the board was opened over, the board put away", {
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
        vim.api.nvim_get_current_win() == opened_over,
        ui.ui_visible,
    }, { "other.txt", true, false })
    vim.cmd("buffer " .. buf)
    vim.fn.delete(dir .. "/other.txt")
    -- A board kept between runs goes back to the window it is shown over this time, not the
    -- one it was first shown over, which may show another file by now.
    br:show_ui()
    br.ui:delete()
    vim.cmd("vsplit")
    local split = vim.api.nvim_get_current_win()
    br:show_ui()
    br.ui:delete()
    t.eq(interface .. ": a board shown again from another window closes back to that one", {
        split ~= opened_over,
        vim.api.nvim_get_current_win() == split,
    }, { true, true })
    vim.api.nvim_win_close(split, true)
    br:delete_ui()
end
vim.go.cursorline = user_cursorline
vim.fn.delete(dir .. "/checker.cpp")

-- The testcase list moves like every list tuna draws: the list keys step a row (a count
-- steps that many) and wrap at the ends, and Tab does nothing.
do
    local br, ui, move, state, done = board("popup")
    done()
    local function press(k)
        vim.api.nvim_set_current_win(ui.windows.tc.winid)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "x", false)
        return state().row
    end
    move(3)
    t.eq("the testcase list wraps, counts, and ignores Tab", { press("j"), press("2j"), press("k"), press("<Tab>") }, { 1, 3, 2, 2 })
    br:delete_ui()
end

-- `:w` in any pane saves the testcase the panes show, a read-only one included.
do
    local br, ui, move, _, done = board("popup")
    done()
    move(2)
    vim.api.nvim_buf_set_lines(ui.windows.si.bufnr, 0, -1, false, { "7" })
    stub_system()
    vim.api.nvim_buf_call(ui.windows.so.bufnr, function()
        vim.cmd("write")
    end)
    settled(br)
    vim.system = real_system
    t.eq("a :w typed in the Output pane saves the input typed into Input", (tcs.buf_get_testcases(buf)[0] or {}).input, "7")
    tcs.buf_delete_testcase(buf, 0)
    br:delete_ui()
end

for _, interface in ipairs({ "split", "popup" }) do
    local br, _, move, _, done = board(interface, true)
    move(1)
    move(2)
    move(1)
    local warned = vim.tbl_filter(function(m)
        return m:match("using the default layout") ~= nil
    end, done())
    t.eq(interface .. ": a grid that can't be used is said once, however often the board re-tiles", #warned, 1)
    br:delete_ui()
end

--------------------------------------------------------------------------------
-- No testcases at all: the program still runs, on empty stdin
--------------------------------------------------------------------------------

-- Hitting run on a file with no testcases means "execute this". Without it the two
-- kinds of language disagreed: a compiled file built and showed a lone `Compile` row
-- with nothing to say why, an interpreted one only warned, and neither ran anything.
stub_system()
r = require("tuna.run").new(buf)
r:run_testcases({})
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
require("tuna.problem.testcases").buf_delete_testcase(buf, 0)

-- A row added once a run is over (`n`) runs and settles like any other: the run's lanes
-- ended with it, so the new row is not a testcase one of them has still to start.
do
    tcs.buf_save_testcase(buf, 0, "1\n", "")
    stub_system()
    local nr = require("tuna.run").new(buf)
    nr:run_testcases(tcs.buf_get_testcases(buf))
    vim.wait(2000, function()
        return nr.completed
    end, 20)
    local n = nr:next_tcnum()
    nr:add_testcase_row(n)
    nr:save_testcase(n, "2\n", "")
    vim.wait(2000, function()
        return nr.completed
    end, 20)
    t.eq("a row added after a run settles once it has run", nr:idle(), true)
    nr:save_testcase(n, "2\n", "x\n")
    vim.wait(2000, function()
        return nr.completed and nr.tcdata[#nr.tcdata].status ~= "DONE"
    end, 20)
    vim.system = real_system
    t.eq("so saving an answer for it judges it", nr.tcdata[#nr.tcdata].status, "WRONG")
    tcs.buf_delete_testcase(buf, n)
    tcs.buf_delete_testcase(buf, 0)
end

--------------------------------------------------------------------------------
-- `:Tuna run all` builds the same rows for every solution
--------------------------------------------------------------------------------

t.write(dir, "out.txt", "42\n") -- an answer with no input, on disk
t.eq("it loads with no input", tcs.buf_get_testcases(buf)[0].input, nil)

local run_exec = require("tuna.run").new(buf).rc.exec
stub_system()
require("tuna.run.modes.multi").run(buf)
local mr = require("tuna.run.modes.multi").active[buf]
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

-- Trailing numbers pick the testcases, as in normal mode: a missing one is reported, and
-- with none left nothing runs.
do
    local quiet = vim.notify
    local said = t.capture_notifications()
    stub_system()
    require("tuna.run.modes.multi").run(buf, { list = { "0", "7" } })
    local picked = require("tuna.run.modes.multi").active[buf]
    settled(picked)
    t.eq("run all with numbers runs only those testcases", picked and picked:testcase_numbers(), { 0 })
    t.has("and reports one that doesn't exist", table.concat(said, "\n"), "run: testcase 7 doesn't exist.")
    require("tuna.run.modes.multi").run(buf, { list = { "7" } })
    vim.system = real_system
    vim.notify = quiet
    t.ok("and with none that exist runs nothing", require("tuna.run.modes.multi").active[buf] == picked)
    picked:kill_all_processes()
    picked:delete_ui()
end

--------------------------------------------------------------------------------
-- Stress and interactive build their rows from the same testcases
--------------------------------------------------------------------------------

-- Interactive replays a testcase's input, so an input-less one is exactly the case
-- that would hand `nil` to the solution.
stub_system()
require("tuna.run.modes.interactive").run(buf, {})
local ir = require("tuna.run.modes.interactive").active[buf]
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
t.ok("interactive opened its runner UI", iui ~= nil and iui.ui_visible)
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
    t.eq("and is titled Live, with the key that opens it", si.title, " Live (i) ")
    local sc = vim.api.nvim_win_get_config(si.winid)
    t.eq("with that title on its border", sc.title and sc.title[1][1], " Live (i) ")
    t.eq("in the accent, since live mode is typed into", sc.title and sc.title[1][2], "TunaEditableBorder")
    -- The legend says how this source is played: the mode adds a section of its own.
    t.ok("the legend has a section for the source being played", legend_line(iui, "INTERACTIVE, LIVE") ~= nil)
    t.has("saying how a line is sent", legend_line(iui, "send a line"), "<CR>")
    t.has("and how to reach the other sources", legend_line(iui, "other sources"), ":Tuna run interactive feed or interactor")
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
    t.eq("the row being talked to is the row the UI shows", iui:selected_index(), 2)
    local row
    for _, r in ipairs(ir.tcdata) do
        if r.tcnum ~= "Compile" then
            row = r
            iui.selected_row = r
        end
    end
    row.log = nil
    local conv = require("tuna.run.modes.interactive")._test
    conv.log_append(row, "so", "hello\n")
    conv.log_append(row, "si", "hi\n")
    conv.log_append(row, "se", "oops\n")
    ir:update_ui(false)
    drain(iui)
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
    drain(iui)
    local sib = iui.windows.si.bufnr
    local last = vim.api.nvim_buf_line_count(sib)
    vim.api.nvim_buf_set_lines(sib, last - 1, last, false, { "typing" })
    conv.log_append(row, "so", "reply\n")
    ir:update_ui(false)
    drain(iui)
    t.eq("the line being typed survives output arriving under it", lines_of("si"), { "42", "", "typing" })
    t.eq("faced by a blank line in the other columns", lines_of("so"), { "", "reply", "" })
    ir.sol_in = nil

    -- Reading back through one column holds all three level with it, output landing or not.
    for k = 1, 80 do
        conv.log_append(row, "so", "line " .. k .. "\n")
    end
    ir:update_ui(false)
    drain(iui)
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
    drain(iui)
    t.eq("and output landing meanwhile does not pull them away", { top(sow), top(sew) }, { 1, 1 })
    local hidden = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(sow)) - vim.fn.line("w$", sow)
    local said = vim.api.nvim_win_get_config(sow).footer
    t.eq("the column read back counts what landed below it", said and said[1] and said[1][1], " ↓ " .. hidden .. " ")
    vim.api.nvim_set_current_win(back)
end

-- The grid follows the source. `feed` replays a stored testcase, so it keeps the canonical
-- Input and Expected Output panes and edits them like a normal run; `interactor` looks
-- like live, but nothing in it is typed into, so nothing wears the accent.
stub_system()
require("tuna.run.modes.interactive").run(buf, { "feed" })
local fr = require("tuna.run.modes.interactive").active[buf]
-- A run opens on its build step, which is shown with Errors alone, so the panes of the mode
-- are there once the build has handed the row over.
vim.wait(2000, function()
    return fr ~= nil and fr.ui ~= nil and fr.ui.ui_visible and fr.ui:selected_index() ~= 1
end, 20)
drain(fr and fr.ui)
vim.system = real_system
local fui = fr and fr.ui
t.ok("feed opened its runner UI", fui ~= nil and fui.ui_visible)
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
    t.eq("with their canonical titles", titles, { " Input (i) ", " Expected Output (a) " })
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
require("tuna.run.modes.interactive").run(buf, { "live" }, { show_only = true })
local lr = require("tuna.run.modes.interactive").active[buf]
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
drain(lr.ui)
t.eq(
    "it opens on the conversation, its columns unwrapped and scroll-bound",
    { lr.ui:selected_index(), column(lr.ui, "se"), column(lr.ui, "so") },
    { 2, { false, true }, { false, true } }
)
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
drain(lr.ui)

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
drain(lr.ui)
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
require("tuna.run.modes.interactive").run(buf, { "feed" })
local cr = require("tuna.run.modes.interactive").active[buf]
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
    require("tuna.run.modes.interactive").run(nbuf, { "feed" })
    local nr = require("tuna.run.modes.interactive").active[nbuf]
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
require("tuna.run.modes.interactive").run(buf, { "interactor" })
local xr = require("tuna.run.modes.interactive").active[buf]
-- Once the build has handed the row over, so the mode's own panes are the ones drawn.
vim.wait(2000, function()
    return xr ~= nil and xr.ui ~= nil and xr.ui.ui_visible and xr.ui:selected_index() ~= 1
end, 20)
drain(xr and xr.ui)
vim.system = real_system
local xui = xr and xr.ui
t.ok("interactor opened its runner UI", xui ~= nil and xui.ui_visible)
if xui then
    t.eq("interactor does not edit testcases", xr.editable_testcases, false)
    t.eq("interactor draws no expected output", xui.windows.eo.winid, nil)
    local xc = vim.api.nvim_win_get_config(xui.windows.si.winid)
    t.eq("its conversation pane is titled Live", xc.title and xc.title[1][1], " Live (i) ")
    t.ok("and wears no accent, since nothing is typed into it", not (xc.title and xc.title[1][2] == "TunaEditableBorder"), xc.title)
    -- The conversation's columns stay level: unwrapped and scroll-bound, Errors included. The
    -- build step is no conversation, so there its panes wrap and scroll on their own.
    local function show_row(row)
        vim.api.nvim_set_current_win(xui.windows.tc.winid)
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = xui.windows.tc.bufnr })
        drain(xui)
    end
    show_row(2)
    t.eq("a conversation's columns stay unwrapped and scroll together", { column(xui, "se"), column(xui, "so") }, { { false, true }, { false, true } })
    show_row(1)
    t.eq("while the build step's panes wrap and scroll on their own", column(xui, "se"), { true, false })
    xui:delete()
end
vim.fn.delete(dir .. "/interactor.cpp")

-- The title a mode gives a pane is drawn by the interface itself, not only patched on by
-- the accent pass afterwards: a pane that isn't accented (Live in feed mode) would
-- otherwise keep the default title on its border.
do
    local popup = require("tuna.runner_ui.popup")
    local wins = {}
    for name, title in pairs(require("tuna.runner_ui.layout").titles) do
        wins[name] = { bufnr = vim.api.nvim_create_buf(false, true), title = name == "si" and " Live " or title }
    end
    local setup = require("tuna.config").current_setup
    popup.relayout(wins, setup, nil, 2, setup.popup_ui.layout)
    local cfg = vim.api.nvim_win_get_config(wins.si.winid)
    t.eq("the interface draws a renamed pane's title", cfg.title and cfg.title[1][1], " Live ")
    for _, w in pairs(wins) do
        if w.winid and vim.api.nvim_win_is_valid(w.winid) then
            vim.api.nvim_win_close(w.winid, true)
        end
    end
end

-- The conversation itself: one row per thing said, owned by the column that said it.
do
    local conv = require("tuna.run.modes.interactive")._test
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
require("tuna.run.modes.stress").run(buf, 1)
local sr = require("tuna.run.modes.stress").active[buf]
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
    local script, budgets, held, calls, envs = {}, {}, nil, {}, {}
    vim.system = function(argv, opts, on_exit)
        local name = vim.fn.fnamemodify(argv[1], ":t")
        local res = script[name]
        calls[#calls + 1] = name
        budgets[name] = opts and opts.timeout
        envs[name] = opts and opts.env and opts.env.GLIBCXX_DEBUG_MESSAGE_LENGTH
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

    local stress = require("tuna.run.modes.stress")
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
        require("tuna.run.tools")._test.forget_builds() -- each search scripts its own compiler
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
    t.eq("each program of the search is told not to wrap a debug-mode report", {
        envs.genx,
        envs.solx,
        envs.refx,
    }, { "0", "0", "0" })
    t.eq("so nothing is written beside the solution", testcase_files(), {})
    t.eq("and the search stops on the seed it happened on", crashed.iter, 1)
    t.ok("finished, so the rows can be edited again", crashed:idle(), crashed.finished)
    local hunt = crashed.tcdata[#crashed.tcdata]
    t.eq("the row that was doing the work takes the verdict", {
        crashed:row_label(hunt),
        hunt.status,
        hunt.hlgroup,
    }, { "TC 0", "SIG 6", "TunaWarning" })
    t.has("and its Errors pane says which program failed, and on which seed", crashed:pane_content(hunt, "se"), ("bruteforce was killed by signal 6 (seed %d)"):format(crashed:seed(1)))
    -- Without a seed handed to the generator, the input is named by its number instead.
    crashed.pass_seed = false
    crashed.search_entry = hunt
    crashed:helper_failed("generator", 2, nil, "failed")
    t.has("and by its number when no seed was handed over", hunt.stderr or "", "generator failed (input 2)")

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
    t.eq("holding the input being tried", row.stdin, ("in %d\n"):format(looking:seed(1)))
    -- The generator is handed the run's own base plus the iteration, so a run after one that
    -- found nothing tries new inputs, and the Run pane says which seed is being tried.
    t.ok("every run searches from a seed of its own", looking.seed_base ~= crashed.seed_base, { looking.seed_base, crashed.seed_base })
    t.ok("and the Run pane shows the one being tried", vim.tbl_contains(vim.tbl_map(function(r)
        return r[1] .. "=" .. r[2]
    end, looking:status_tail()), "seed=" .. looking:seed(1)), looking:status_tail())
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
    drain(halted.ui)
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
    drain(found.ui)
    t.ok("and it is marked up in both panes", (function()
        local out = #vim.api.nvim_buf_get_extmarks(found.ui.windows.so.bufnr, ns, 0, -1, {})
        local exp = #vim.api.nvim_buf_get_extmarks(found.ui.windows.eo.bufnr, ns, 0, -1, {})
        return out > 0 and exp > 0
    end)(), found.tcdata[2])
    -- What is painted: the disagreeing token alone on a line that disagrees, a cell put in
    -- where a line ends short of the other, and a line the other side lacks coloured whole.
    local painted = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(painted, 0, -1, false, { "3 9", "2 1 1", "extra" })
    local marks = require("tuna.run.diff").compute("3 9\n2 1 1\nextra\n", "3 4\n2 1 1 1\n", "squish").out
    ui_test.paint_diff(painted, marks)
    local drawn = vim.tbl_map(function(m)
        local d = m[4]
        return { m[2], m[3], d.end_col, d.hl_group or (d.virt_text and ("cell " .. d.virt_text[1][2] .. " " .. d.virt_text_pos)) }
    end, vim.api.nvim_buf_get_extmarks(painted, ns, 0, -1, { details = true }))
    t.eq("a diff marks what disagrees, where a line ends short, and a line the other lacks", drawn, {
        { 0, 2, 3, "TunaDiffText" },
        { 1, 5, nil, "cell TunaDiffText inline" },
        { 2, 0, 5, "TunaDiffAdd" },
    })

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

    -- Editing them keeps the search row last and honest. A testcase added, restored or split
    -- off goes above it, and the number it wears moves past the one just taken, or the board
    -- would show two rows reading the same number until the next run rebuilt it.
    local labels = function()
        return vim.tbl_map(function(row)
            return row[1]
        end, listing(listed))
    end
    local quiet = vim.notify
    vim.notify = function() end
    listed.ui:add_testcase()
    t.eq("a testcase added goes above the search row, which moves on", labels(), { "Compile", "TC 0", "TC 1" })
    listed.ui:delete_testcase(0)
    listed.ui:restore_testcase()
    vim.notify = quiet
    t.eq("and so does one restored", labels(), { "Compile", "TC 0", "TC 1" })
    t.eq("the search row last throughout", listed.tcdata[#listed.tcdata], listed.search_entry)
    listed.ui:delete()

    -- The search judges every input with the checker, so one that did not build stops it
    -- before any input is tried, said on the build step and nowhere else: searching on would
    -- end in "no counterexample found", which would not be true.
    t.write(sdir2, "checker.cpp", "int main(){}\n")
    local quiet = vim.notify
    local said = t.capture_notifications()
    local unjudged = search({
        ccx = function(argv)
            return argv[#argv]:match("checker") and { code = 1, stderr = "checker.cpp: error\n" } or {}
        end,
        genx = seeded,
        solx = { stdout = "5\n" },
        refx = { stdout = "6\n" },
    })
    vim.notify = quiet
    t.eq("a checker that did not build stops the search before any input", unjudged.iter, 0)
    t.eq("its build says so on the Compile row", unjudged.tcdata[1].status, "FAILED")
    t.eq("and nothing is notified, input by input or otherwise", said, {})

    -- One that built but gives no verdict (it cannot start) stops the search on the input it
    -- had, for the same reason, reported on the search row. (Written again, so the failed
    -- build above is not what the compile cache answers with.)
    t.write(sdir2, "checker.cpp", "int main() { return 0; }\n")
    local silent = search({
        ccx = {},
        genx = seeded,
        refx = { stdout = "6\n" },
        solx = function(argv)
            if #argv > 1 then -- the checker, handed its three files: it cannot start
                error("no such file")
            end
            return { stdout = "5\n" }
        end,
    })
    local row = silent.tcdata[#silent.tcdata]
    t.eq("a checker that gives no verdict stops the search on that input", { silent.iter, row.status }, { 1, "FAILED" })
    t.has("saying so on the search row", row.stderr or "", ("checker gave no verdict (seed %d)"):format(silent:seed(1)))

    -- A restart judges with the checker as it is now, like every run.
    local judged = search({ ccx = {}, genx = seeded, solx = { stdout = "5\n" }, refx = { stdout = "6\n" } })
    t.eq("a checker that accepts every output saves nothing, having judged every input", { saved_rows(judged), judged.iter }, { {}, 3 })
    require("tuna.run.tools").set_checker(sdir2 .. "/main.cpp", "off")
    judged:run_testcases()
    vim.wait(5000, function()
        return judged.finished
    end, 10)
    t.eq("switched off, a restart judges by plain comparison and finds the difference", #saved_rows(judged), 1)
    require("tuna.run.tools").set_checker(sdir2 .. "/main.cpp", "auto")
    vim.fn.delete(sdir2 .. "/checker.cpp")
    for _, f in ipairs(vim.fn.globpath(sdir2, "main_*.txt", false, true)) do
        vim.fn.delete(f)
    end

    -- A solution that never compiled searches for nothing.
    local broken = search({ ccx = { code = 1 }, genx = seeded, solx = { stdout = "5\n" }, refx = { stdout = "5\n" } })
    t.eq("a failed build leaves the compile row saying so", broken.tcdata[1].status, "RET 1")
    t.ok("and finishes the search, which is what lets the rows be edited", broken:idle(), broken.finished)

    -- With no bruteforce a run of stress asked for offers to search for crashes alone, which
    -- `:Tuna run` never picks by itself. Only how the solution ended counts, and an input it
    -- crashed on is saved with no answer. The Run pane names no bruteforce, and one written
    -- later makes the board a stress run again.
    require("tuna.run.tools")._test.forget_builds()
    for _, f in ipairs(vim.fn.globpath(sdir2, "main_*.txt", false, true)) do
        vim.fn.delete(f)
    end
    require("tuna.config").setup({
        compile_command = { cpp = { exec = ccx, args = { "$(FNAME)" } } },
        run_command = { cpp = { exec = solx } },
        stress = { generator = { exec = genx, args = {} }, count = 3 },
    })
    local tools = require("tuna.run.tools")
    t.eq("a generator alone is no stress run unless asked for", tools.detect_mode(sdir2 .. "/main.cpp", require("tuna.config").current_setup), "normal")
    local widgets = require("tuna.ui.widgets")
    local real_menu, offered = widgets.menu, nil
    widgets.menu = function(items, title, on_choice)
        offered = { title, items }
        on_choice(2)
    end
    local runs = 0
    script, held, calls = {
        ccx = {},
        genx = seeded,
        solx = function()
            runs = runs + 1
            return runs == 2 and { signal = 11 } or { stdout = "5\n" }
        end,
    }, nil, {}
    stress.run(sbuf, 3)
    widgets.menu = real_menu
    local hunt = stress.active[sbuf]
    vim.wait(5000, function()
        return hunt ~= nil and hunt.finished
    end, 10)
    t.eq("asked for, it offers the bruteforce's starter or a search for crashes without one", offered, {
        "Stress needs a bruteforce",
        { "Create brute.cpp", "Search for crashes without one", "Stop" },
    })
    t.eq("which runs no bruteforce, and keeps the input the solution crashed on", {
        vim.tbl_contains(calls, "refx"),
        saved_rows(hunt),
        testcase_files(),
    }, { false, { { 0, "SIG 11" } }, { "main_input0.txt" } })
    local function brute_row(r2)
        for _, line in ipairs(r2.ui:status_lines()) do
            if line:match("^brute") then
                return line
            end
        end
    end
    t.eq("the Run pane says there is no bruteforce", brute_row(hunt), "brute: none")
    t.has("and the legend what is kept instead", legend_line(hunt.ui, "with no bruteforce"), "crashes")
    t.write(sdir2, "brute.cpp", "int main(){}\n")
    hunt:run_testcases()
    vim.wait(5000, function()
        return hunt.finished
    end, 10)
    t.eq("a bruteforce written since makes it a stress run again", { hunt.hunt, brute_row(hunt) }, { false, "brute: brute.cpp" })
    vim.fn.delete(sdir2 .. "/brute.cpp")

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
    -- A testcase on disk, so the board keeps a testcase row once the search row is gone.
    require("tuna.problem.testcases").buf_save_testcase(bbuf, 0, "1\n", "1\n")
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

    require("tuna.run.modes.stress").run(bbuf, 1)
    local br = require("tuna.run.modes.stress").active[bbuf]
    vim.wait(5000, function()
        return br and br.tcdata[1] and not br:build_pending(br.tcdata[1])
    end, 10)
    local bui, first = br.ui, br.tcdata[1]

    t.eq("the build step stacks one pane per source it compiles", bui:grid(bui.runner.tcdata[1]), {
        { 3, "tc" },
        { 8, { { 1, "se" }, { 1, "so" }, { 1, "eo" }, { 1, "si" } } },
    })
    local assigned = bui:build_assignment(first)
    t.eq("the solution first, then the helpers the mode needs", build_titles(assigned), {
        se = " Errors: main.cpp ",
        so = " Errors: gen.cpp ",
        eo = " Errors: brute.cpp ",
        si = " Errors: checker.cpp ",
    })
    t.eq("each holding what its own compiler said, and nothing when it said nothing", build_text(assigned), {
        se = "",
        so = "gen.cpp warns\n",
        eo = "",
        si = "checker.cpp warns\n",
    })
    t.eq("a testcase row keeps the grid of the run", bui:grid(bui.runner.tcdata[2]), require("tuna.config").current_setup.popup_ui.layout)
    t.ok("a row that is not the build step has no sources", bui:build_assignment(br.tcdata[2]) == nil)
    t.ok("a helper that warned keeps the cursor on the build step", br:build_spoke(first), first.stderr)
    t.eq("though the solution itself built quietly", { first.stderr, first.exit_code }, { "", 0 })

    -- What the panes are actually drawn with, and that they are named back again: a pane
    -- that stays open through a re-tiling would otherwise keep the name it was opened with.
    bui:select_row(1)
    bui.update_windows, bui.update_details = true, true
    bui:update_ui()
    drain(bui)
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
    }, { " Errors: main.cpp (e) ", " Errors: gen.cpp (i) ", "gen.cpp warns" })
    t.ok("and wear no accent, nothing on the build step is typed into", not accented(bui, "eo"), "eo")
    t.eq("four sources, and still the six panes every board has, not one buffer more", vim.tbl_count(bui.windows), 6)
    t.ok("the legend has a section for the search", legend_line(bui, "STRESS") ~= nil)
    t.has("saying what the search row is", legend_line(bui, "the search row"), "the input being tried")
    t.has(
        "and spells out the build row's keys, which follow its sources",
        legend_line(bui, "zoom on the build row"),
        "e main.cpp  i gen.cpp  a brute.cpp  o checker.cpp"
    )

    -- Every pane on the build step opens with a key of its own: the key of the pane its
    -- program is about when a testcase runs. The solution by its errors, the generator by the
    -- input it writes, the bruteforce by the answer it writes, the checker by the output it
    -- judges.
    vim.api.nvim_set_current_win(bui.windows.tc.winid)
    local opened = {}
    for _, key in ipairs({ "e", "i", "a", "o" }) do
        vim.api.nvim_feedkeys(key, "xt", false)
        opened[key] = bui.zoom_winid and vim.api.nvim_win_get_config(bui.zoom_winid).title[1][1]
        bui:unzoom()
    end
    t.eq("every source on the build step opens with its own key", opened, {
        e = " Errors: main.cpp (e) ",
        i = " Errors: gen.cpp (i) ",
        a = " Errors: brute.cpp (a) ",
        o = " Errors: checker.cpp (o) ",
    })
    bui:select_row(2)
    bui.update_windows, bui.update_details = true, true
    bui:update_ui()
    drain(bui)
    t.eq("and named back for a testcase row", { drawn_title("so"), drawn_title("se") }, { " Output (o) ", " Errors (e) " })
    t.ok("which is where the accent comes back", accented(bui, "eo"), "eo")
    -- And goes again: a pane the re-tiling leaves open keeps the colour it had, so the
    -- accent has to be taken off as well as put on.
    bui:select_row(1)
    bui.update_windows, bui.update_details = true, true
    bui:update_ui()
    drain(bui)
    t.ok("and goes again on the way back to the build step", not accented(bui, "eo"), "eo")

    -- `show_title_keys` (on by default) writes the key that zooms each pane at the end
    -- of its title, and on the build step that is each source's own key.
    local function render()
        bui.update_windows, bui.update_details = true, true
        bui:update_ui()
        drain(bui)
    end
    local function titles_of(...)
        return vim.tbl_map(drawn_title, { ... })
    end
    t.eq("each source's pane is named with the key that opens it", titles_of("se", "so", "eo", "si"), {
        " Errors: main.cpp (e) ",
        " Errors: gen.cpp (i) ",
        " Errors: brute.cpp (a) ",
        " Errors: checker.cpp (o) ",
    })
    bui:select_row(2)
    render()
    t.eq("while a testcase row names every pane's key", titles_of("so", "eo", "si", "se"), {
        " Output (o) ",
        " Expected Output (a) ",
        " Input (i) ",
        " Errors (e) ",
    })
    bui.config = vim.tbl_deep_extend("force", bui.config, { runner_ui = { show_title_keys = false } })
    bui:select_row(1)
    render()
    bui:select_row(2)
    render()
    t.eq("and turned off, the titles are the panes' names alone", titles_of("so", "se"), { " Output ", " Errors " })

    br:kill_all_processes()
    bui:delete()

    -- A helper that is a command rather than a source has no compiler to quote, so it takes
    -- no pane: the build step is what this run builds, not what it runs.
    require("tuna.config").setup({
        compile_command = { cpp = { exec = bdir .. "/ccx", args = { "$(FNAME)" } } },
        run_command = { cpp = { exec = bdir .. "/solx" } },
        stress = { generator = { exec = bdir .. "/solx", args = {} } },
    })
    require("tuna.run.modes.stress").run(bbuf, 1)
    local cr = require("tuna.run.modes.stress").active[bbuf]
    vim.wait(5000, function()
        return cr and cr.tcdata[1] and not cr:build_pending(cr.tcdata[1])
    end, 10)
    t.eq("a helper with nothing to compile takes no pane", build_titles(cr.ui:build_assignment(cr.tcdata[1])), {
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
    require("tuna.run.modes.stress").run(bbuf, 1)
    local broke = require("tuna.run.modes.stress").active[bbuf]
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
        build_text(broke.ui:build_assignment(broke.tcdata[1])).so,
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
    require("tuna.run.modes.stress").run(bbuf, 1)
    local at_once = require("tuna.run.modes.stress").active[bbuf]
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
    require("tuna.run.tools")._test.forget_builds() -- the checker built cleanly in the searches above
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
    local late = require("tuna.run").new(bbuf)
    late:show_ui()
    late:run_testcases({ [0] = { input = "1\n" } })
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
    local onl = require("tuna.run").new(obuf)
    onl:show_ui()
    onl:run_testcases({ [0] = { input = "1\n" } })
    -- The build is held by the stub above and never lands: the step is what is looked at.
    drain(onl.ui)
    t.eq("one source alone keeps the build step's configured grid", onl.ui:grid(onl.ui.runner.tcdata[1]), {
        { 3, "tc" },
        { 8, "se" },
    })
    t.eq("and the Errors pane its own name", build_titles(onl.ui:build_assignment(onl.tcdata[1])), {})
    -- One source is one key: the others have no source of their own to open here.
    onl.ui:select_row(1)
    onl.ui.update_windows, onl.ui.update_details = true, true
    onl.ui:update_ui()
    drain(onl.ui)
    vim.api.nvim_set_current_win(onl.ui.windows.tc.winid)
    local lone = {}
    for _, key in ipairs({ "i", "a", "o", "e" }) do
        vim.api.nvim_feedkeys(key, "xt", false)
        lone[key] = onl.ui.zoom_winid and vim.api.nvim_win_get_config(onl.ui.zoom_winid).title[1][1] or false
        onl.ui:unzoom()
    end
    t.eq("with the solution alone, only its key opens anything", lone, { i = false, a = false, o = false, e = " Errors (e) " })
    t.eq("and a plain run's legend adds no section and no build row line", {
        legend_line(onl.ui, "zoom on the build row"),
        legend_line(onl.ui, "STRESS"),
        legend_line(onl.ui, "INTERACTIVE"),
    }, {})
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
local tools = require("tuna.run.tools")
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

-- A header beside a solution has the solution's filetype (Neovim calls a `.h` C++), but it
-- is code to include, not a program: nothing takes it for a solution, and a run started
-- from it runs the solution beside it, as from a helper.
do
    local hd = t.tempdir()
    t.write(hd, "debug.h", "#pragma once\n") -- sorts before main.cpp
    t.write(hd, "main.cpp", '#include "debug.h"\nint main(){}\n')
    t.write(hd, "checker.h", "\n")
    t.write(hd, "main_input0.txt", "1\n")
    t.eq("headers are told by extension", vim.tbl_map(tools.is_header, { "a.h", "a.hpp", "a.HPP", "a.hh", "a.cpp", "a.c", "a.py" }), {
        true, true, true, true, false, false, false,
    })
    vim.cmd("edit " .. hd .. "/debug.h")
    local hb = vim.api.nvim_get_current_buf()
    local hcfg = require("tuna.config").get_buffer_config(hb)
    t.eq("a run from a header runs the solution beside it", vim.api.nvim_buf_get_name(tools.solution_bufnr(hb, hcfg) or hb), hd .. "/main.cpp")
    t.eq("a header is never a helper either", tools.find(hd, "checker", hcfg), nil)
    local only = t.tempdir()
    t.write(only, "debug.h", "\n")
    t.eq("the solution of a problem directory is never its header", require("tuna.workspace.navigate").solution_in(only, nil, hcfg), nil)
    vim.fn.delete(only, "rf")
    t.write(hd, "lib.hpp", "\n")
    t.eq("nor a contest's problem", vim.tbl_map(vim.fs.basename, require("tuna.workspace.recent").contest_problems(hd, nil, hcfg)), { "main.cpp" })
    local sol = tools.solution_bufnr(hb, hcfg)
    stub_system()
    require("tuna.run.modes.multi").run(sol)
    local mr = require("tuna.run.modes.multi").active[sol]
    vim.system = real_system
    t.eq("nor one of run-all's solutions", mr and vim.tbl_map(function(f)
        return f.name
    end, mr.files), { "main.cpp" })
    if mr then
        mr:kill_all_processes()
        mr:delete_ui()
    end
    vim.cmd("silent! %bwipeout!")
    -- A header with no solution beside it (a `debug.h` kept in an include directory) is
    -- nothing tuna can run.
    local lone = t.tempdir()
    t.write(lone, "debug.h", "\n")
    vim.cmd("edit " .. lone .. "/debug.h")
    vim.bo.filetype = "cpp"
    local quiet = vim.notify
    local said = t.capture_notifications()
    require("tuna.commands").toggle_pin()
    vim.notify = quiet
    t.has("and a header alone is no problem to pin", table.concat(said, "\n"), "not a solution file tuna can run")
    t.eq("so nothing is pinned", require("tuna.workspace.recent").is_pinned(lone .. "/debug.h"), false)
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(hd, "rf")
    vim.fn.delete(lone, "rf")
end

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
    local r = require("tuna.run").new(wbuf)
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
local gtcs = require("tuna.problem.testcases")

-- A save stores what it is given, and stores the testcase even with nothing in it: an
-- empty testcase is a testcase. Removing one is `buf_delete_testcase` — one way in, and
-- an undoable one — so a save never leaves the row standing for something that is not
-- there, which is what `bare` would have to mean afterwards.
local gr = require("tuna.run").new(gbuf)
gr.cc = nil -- rows only, no build step, so testcase 0 is row 1
gr:load_testcases({ [0] = { input = "x\n" } })
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

-- A row whose testcase is deleted behind the UI's back. The runner UI keeps its rows
-- across a re-run, so unlike a fresh `:Tuna run` it cannot just drop them — by then the
-- row holds the only copy of that text.
for i = 0, 2 do
    gtcs.buf_save_testcase(gbuf, i, "in" .. i .. "\n", "in" .. i .. "\n")
end
stub_system()
gr = require("tuna.run").new(gbuf)
gr.cc = nil
gr:run_testcases(gtcs.buf_get_testcases(gbuf))
settled(gr)
vim.system = real_system
gr:show_ui()
drain(gr.ui)
local gui = gr.ui
t.ok("the runner UI opened", gui ~= nil and gui.ui_visible)

-- The focus rescue that brings the cursor back into a pane when the window displacing
-- the UI goes away must not fire when a *new* window took the focus during that close.
-- That is how the UI asks two questions in a row — an unsaved edit, then a testcase
-- gone missing — the second dialog being opened from the first one's answer: pulling
-- the cursor back into the pane there leaves the question on screen unanswerable, and
-- reads exactly as though the first prompt had swallowed the second.
vim.api.nvim_set_current_win(gui.windows.tc.winid)
vim.cmd("botright split | enew")
local excursion = vim.api.nvim_get_current_win()
drain(gui)
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
drain(gui)
t.eq("a dialog opened during the close keeps the focus", vim.api.nvim_get_current_buf(), dialog_buf)
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)

-- ...while the case it exists for still works: focus falling back to a window that was
-- already there is Neovim's, and the cursor belongs in the pane.
vim.api.nvim_set_current_win(gui.windows.tc.winid)
vim.cmd("botright split | enew")
excursion = vim.api.nvim_get_current_win()
drain(gui)
vim.api.nvim_win_close(excursion, true)
drain(gui)
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
t.eq("with the row renumbered to match, in number order", vim.tbl_map(function(tc)
    return tc.tcnum
end, gr.tcdata), { 0, 2, 3 })

-- What the board shows stays what is on disk through the editing keys: a row added or
-- restored goes into number order, as the next run would list it, and is selected; undo
-- restores the testcase deleted last whatever was done since, under its own number while
-- that is free, else under the lowest free one, never over a testcase saved there since.
do
    local udir = t.tempdir()
    t.write(udir, "sol.cpp", "int main(){}\n")
    vim.cmd("edit " .. udir .. "/sol.cpp")
    vim.bo.filetype = "cpp"
    local ubuf = vim.api.nvim_get_current_buf()
    for i = 0, 2 do
        gtcs.buf_save_testcase(ubuf, i, "in" .. i .. "\n", "out" .. i .. "\n")
    end
    stub_system()
    local ur = require("tuna.run").new(ubuf)
    ur.cc = nil
    ur:run_testcases(gtcs.buf_get_testcases(ubuf))
    settled(ur)
    ur:show_ui()
    drain(ur.ui)
    local uui = ur.ui
    local function nums()
        return vim.tbl_map(function(tc)
            return tc.tcnum
        end, ur.tcdata)
    end
    local function selected()
        return ur.tcdata[uui:selected_index()].tcnum
    end
    local quiet = vim.notify
    local said = t.capture_notifications()

    uui:goto_row(3)
    uui:delete_testcase(1)
    uui:restore_testcase()
    settled(ur) -- a restore is a save, which runs what it saved
    t.eq("a testcase restored goes back in number order, selected", { nums(), selected() }, { { 0, 1, 2 }, 1 })

    uui:delete_testcase(1)
    uui:add_testcase()
    drain(uui)
    t.eq("a testcase added takes the lowest free number, in number order, selected", { nums(), selected() }, { { 0, 1, 2 }, 1 })

    -- The number is held by the row just added though nothing is saved under it yet.
    uui:restore_testcase()
    settled(ur)
    local disk = gtcs.buf_get_testcases(ubuf)
    t.eq("undo after another action still restores the deletion, past a number an unsaved row holds", {
        disk[1] == nil,
        disk[3] and disk[3].input,
        nums(),
        selected(),
        uui.pending[1] ~= nil,
    }, { true, "in1\n", { 0, 1, 2, 3 }, 3, true })
    t.has("and says where it went", table.concat(said, "\n"), "testcase 1 restored as 3, the original number was taken.")

    -- And never over a testcase saved under its number since, wherever the cursor was moved.
    uui:delete_testcase(2)
    uui:add_testcase()
    drain(uui)
    uui.pending[2] = nil
    ur:save_testcase(2, "brand new\n", "brand new\n")
    settled(ur)
    uui.user_moved = true
    uui:restore_testcase()
    settled(ur)
    drain(uui)
    disk = gtcs.buf_get_testcases(ubuf)
    t.eq("a testcase saved under the number since is left as it is", { disk[2].input, disk[4] and disk[4].input }, { "brand new\n", "in2\n" })
    t.eq("the cursor on the row restored", {
        selected(),
        vim.api.nvim_win_get_cursor(uui.windows.tc.winid)[1],
    }, { 4, uui:selected_index() })

    -- A testcase written to disk from elsewhere gets a row on the next re-run of the set, in
    -- number order and with its text, the selection staying on its row; unless the board was
    -- asked for named testcases, whose others it leaves out.
    gtcs.buf_save_testcase(ubuf, 6, "elsewhere\n", "answer\n")
    ur.subset = true
    uui:with_disk_settled(nil, "re-run all", function() end)
    t.eq("a board of named testcases adds none found on disk", nums(), { 0, 1, 2, 3, 4 })
    ur.subset = nil
    uui:delete_testcase(0)
    drain(uui)
    uui:goto_row(ur:rows_for(4)[1])
    gtcs.buf_save_testcase(ubuf, 0, "also elsewhere\n", "")
    local before = ur.tcdata[uui:selected_index()]
    uui:with_disk_settled(nil, "re-run all", function() end)
    local added = ur.tcdata[ur:rows_for(0)[1]]
    t.eq("a re-run adds a row for each testcase found on disk, the selection staying on its row", {
        nums(),
        added and added.stdin,
        ur.tcdata[uui:selected_index()] == before,
    }, { { 0, 1, 2, 3, 4, 6 }, "also elsewhere\n", true })
    t.has("and says so", table.concat(said, "\n"), "added testcases 0, 6, found on disk since the last run.")

    -- Rows built anew by a fresh run leave the selection only its line, so the row on it is
    -- the one followed from then on, and a row added above it does not take its place.
    uui.pending[1] = nil
    uui.user_moved = true
    ur:run_testcases(gtcs.buf_get_testcases(ubuf))
    settled(ur)
    drain(uui)
    local held = ur.tcdata[uui:selected_index()]
    gtcs.buf_save_testcase(ubuf, 1, "from elsewhere\n", "")
    uui:with_disk_settled(nil, "re-run all", function() end)
    t.eq("after a fresh run, the selection still follows its row", ur.tcdata[uui:selected_index()] == held, true)

    vim.system = real_system
    vim.notify = quiet
    uui:delete()
    vim.cmd("buffer " .. gbuf)
    vim.cmd("silent! bwipeout! " .. ubuf)
    vim.fn.delete(udir, "rf")
end

-- With no testcases, run-all does what a normal run does: every solution runs once on empty
-- stdin, on a bare testcase 0 named `No input`, and saving it writes the first testcase,
-- which every solution then shows. A testcase added on the board is every solution's too.
do
    local edir = t.tempdir()
    t.write(edir, "a.cpp", "int main(){}\n")
    t.write(edir, "b.cpp", "int main(){}\n")
    vim.cmd("edit " .. edir .. "/a.cpp")
    vim.bo.filetype = "cpp"
    local ebuf = vim.api.nvim_get_current_buf()
    local quiet = vim.notify
    vim.notify = function() end
    stub_system()
    require("tuna.run.modes.multi").run(ebuf)
    local mr = require("tuna.run.modes.multi").active[ebuf]
    settled(mr)
    local function cases()
        local out = {}
        for _, tc in ipairs(mr and mr.tcdata or {}) do
            if tc.kind == "case" then
                out[#out + 1] = { tc.sol.name, mr:row_label(tc), tc.status }
            end
        end
        return out
    end
    t.eq("run-all with no testcases runs every solution on a bare testcase 0", cases(), {
        { "a.cpp", "  No input", "DONE" },
        { "b.cpp", "  No input", "DONE" },
    })
    -- Named for what is typed into it from the first keystroke, as on the normal board.
    mr.ui:goto_row(2)
    drain(mr.ui)
    local si = mr.ui.windows.si.bufnr
    vim.api.nvim_buf_set_lines(si, 0, -1, false, { "typed" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = si })
    t.has("typing into it names it a testcase at once", vim.api.nvim_buf_get_lines(mr.ui.windows.tc.bufnr, 1, 2, false)[1], "TC 0")
    mr.ui:discard_pending()
    mr:save_testcase(0, "5\n", "6\n")
    settled(mr)
    t.eq("saved, it is the first testcase, every solution's", {
        gtcs.buf_get_testcases(ebuf)[0],
        vim.tbl_map(function(c)
            return c[2]
        end, cases()),
    }, { { input = "5\n", output = "6\n" }, { "  TC 0", "  TC 0" } })
    mr.ui:add_testcase()
    drain(mr.ui)
    t.eq("and a testcase added on the board is added under every solution", vim.tbl_map(function(c)
        return c[1] .. " " .. c[2]
    end, cases()), { "a.cpp   TC 0", "a.cpp   TC 1", "b.cpp   TC 0", "b.cpp   TC 1" })
    vim.system = real_system
    vim.notify = quiet
    mr:kill_all_processes()
    mr:delete_ui()
    vim.cmd("buffer " .. gbuf)
    vim.cmd("silent! bwipeout! " .. ebuf)
    vim.fn.delete(edir, "rf")
end

-- Run-all keeps the user under the solution they are on: a testcase deleted there selects the
-- next one under it, though every solution above lost a row too, and one restored or added
-- there is selected under it, the cursor with it. A delete takes what was typed and not yet
-- captured with it, and leaves no edit behind for a testcase that is gone.
do
    local sdir = t.tempdir()
    for _, name in ipairs({ "a.cpp", "b.cpp", "c.cpp" }) do
        t.write(sdir, name, "int main(){}\n")
    end
    vim.cmd("edit " .. sdir .. "/a.cpp")
    vim.bo.filetype = "cpp"
    local sbuf = vim.api.nvim_get_current_buf()
    for n = 0, 2 do
        gtcs.buf_save_testcase(sbuf, n, "in" .. n .. "\n", "")
    end
    local quiet = vim.notify
    vim.notify = function() end
    stub_system()
    require("tuna.run.modes.multi").run(sbuf)
    local mr = require("tuna.run.modes.multi").active[sbuf]
    settled(mr)
    local ui = mr.ui
    local function rest()
        drain(ui)
    end
    local function named(idx)
        local tc = mr.tcdata[idx]
        return tc.sol.name .. " " .. tostring(tc.tcnum)
    end
    local function on()
        return { named(ui:selected_index()), named(vim.api.nvim_win_get_cursor(ui.windows.tc.winid)[1]) }
    end
    for i, tc in ipairs(mr.tcdata) do
        if tc.kind == "case" and tc.sol.name == "b.cpp" and tc.tcnum == 1 then
            ui:goto_row(i)
        end
    end
    rest()
    ui:delete_testcase()
    rest()
    t.eq("a testcase deleted in run-all selects the next one under the same solution", on(), { "b.cpp 2", "b.cpp 2" })
    ui:restore_testcase()
    settled(mr)
    rest()
    t.eq("one restored is selected under the solution the user is on", on(), { "b.cpp 1", "b.cpp 1" })

    vim.api.nvim_buf_set_lines(ui.windows.si.bufnr, 0, -1, false, { "typed" })
    ui:delete_testcase()
    rest()
    t.eq("a testcase deleted with an edit typed into it leaves no edit behind", ui.pending[1], nil)
    ui:restore_testcase()
    settled(mr)
    t.eq("and restoring it brings the edit back", gtcs.buf_get_testcases(sbuf)[1].input, "typed")

    -- Rows leaving above the selection, before the render moves the cursor after its row: a
    -- cursor event then, the cursor still on its old line, is no move by hand.
    rest()
    ui.user_moved = true
    ui:delete_testcase(0)
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ui.windows.tc.bufnr })
    t.eq("a cursor event before the render is not a move", named(ui:selected_index()), "b.cpp 1")
    rest()
    t.eq("and the cursor follows its row once drawn", on(), { "b.cpp 1", "b.cpp 1" })

    ui:add_testcase()
    rest()
    t.eq("one added is selected under the solution the user is on", on(), { "b.cpp 0", "b.cpp 0" })
    vim.system = real_system
    vim.notify = quiet
    mr:kill_all_processes()
    mr:delete_ui()
    vim.cmd("stopinsert")
    vim.cmd("buffer " .. gbuf)
    vim.cmd("silent! bwipeout! " .. sbuf)
    vim.fn.delete(sdir, "rf")
end

-- Run-all keeps no list of its testcases beside its rows: a row renumbered by a restore is
-- the number the grid goes on showing when it is laid out again, in every solution.
do
    local mdir = t.tempdir()
    t.write(mdir, "a.cpp", "int main(){}\n")
    t.write(mdir, "b.cpp", "int main(){}\n")
    vim.cmd("edit " .. mdir .. "/a.cpp")
    vim.bo.filetype = "cpp"
    local abuf = vim.api.nvim_get_current_buf()
    for i = 0, 2 do
        gtcs.buf_save_testcase(abuf, i, "in" .. i .. "\n", "in" .. i .. "\n")
    end
    local quiet = vim.notify
    vim.notify = function() end
    stub_system()
    require("tuna.run.modes.multi").run(abuf)
    local mr = require("tuna.run.modes.multi").active[abuf]
    settled(mr)
    gtcs.buf_delete_testcase(abuf, 1)
    local missing = mr.ui:disk_drift()
    gtcs.buf_save_testcase(abuf, 1, "brand new\n", "brand new\n")
    mr.ui:restore_missing(missing)
    mr:remove_testcase_rows(0)
    local by_solution = {}
    for _, tc in ipairs(mr.tcdata) do
        if tc.kind == "case" then
            by_solution[#by_solution + 1] = tc.sol.name .. " " .. tc.tcnum .. " " .. tc.stdin
        end
    end
    t.eq("run-all laid out again shows the numbers its rows were renumbered to", by_solution, {
        "a.cpp 2 in2\n",
        "a.cpp 3 in1\n",
        "b.cpp 2 in2\n",
        "b.cpp 3 in1\n",
    })
    vim.system = real_system
    vim.notify = quiet
    mr:kill_all_processes()
    mr:delete_ui()
    vim.cmd("buffer " .. gbuf)
    vim.cmd("silent! bwipeout! " .. abuf)
    vim.fn.delete(mdir, "rf")
end

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
local widgets = require("tuna.ui.widgets")
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
    require("tuna.run.modes.stress")
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
    require("tuna.run.modes.stress").active[fb] = stress_r
    local ran = false
    C.settle_runners(fb, { run = true, keep = normal_r }, function()
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
    C.settle_runners(fb, { keep = normal_r }, function()
        shown = true
    end)
    t.eq("showing a UI asks nothing and stops nothing", { shown, normal_r.killed, stress_r.killed }, { true, false, false })
    t.eq("and hides the others", stress_r.ui.ui_visible, false)
    C.runners[fb] = nil
    require("tuna.run.modes.stress").active[fb] = nil
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
    local tools = require("tuna.run.tools")
    local path = vim.api.nvim_buf_get_name(rbuf)
    local function clear_runners()
        for _, m in ipairs({ "tuna.run.modes.interactive", "tuna.run.modes.stress", "tuna.run.modes.multi" }) do
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
    local compiler = require("tuna.run").new(rbuf).cc.exec

    clear_runners()
    tools.set_mode(path, "interactive")
    tools.set_source(path, "feed")
    stub_system()
    C.show_runner_ui(rbuf)
    local shown = require("tuna.run.modes.interactive").active[rbuf]
    drain(shown and shown.ui)
    t.ok("after a restart, show_ui opens the mode the problem is set to", shown ~= nil and shown.ui ~= nil and shown.ui.ui_visible)
    t.eq("and not the normal runner's", C.runners[rbuf], nil)
    t.eq("nothing is run to show it", #spawns, 0)
    local last = shown and shown.tcdata[#shown.tcdata]
    t.eq("its rows read NOT RUN", last and last.status, "NOT RUN")
    t.eq("and the runner is idle, so feed's testcases can be edited", shown and shown:idle(), true)
    if shown then
        shown:run_testcases()
        settled(shown)
    end
    t.eq("the first run builds before running", spawns[1] and spawns[1].argv[1], compiler)
    vim.system = real_system

    clear_runners()
    tools.set_mode(path, "all")
    stub_system()
    C.show_runner_ui(rbuf)
    local matrix = require("tuna.run.modes.multi").active[rbuf]
    drain(matrix and matrix.ui)
    t.ok("run-all opens listed too", matrix ~= nil and matrix.ui ~= nil and matrix.ui.ui_visible)
    t.eq("with nothing run", #spawns, 0)
    vim.system = real_system

    -- The normal board listed has built nothing either: a testcase's run key builds first
    -- through the same build every mode has, and a build that fails leaves the row saying it
    -- was never run, which is the truth. The Compile row's run key is the build, once.
    local function listed_normal(compile_code)
        clear_runners()
        spawns = {}
        vim.system = function(argv, opts, on_exit)
            spawns[#spawns + 1] = { argv = argv, stdin = opts and opts.stdin }
            local code = argv[1] == compiler and compile_code or 0
            if on_exit then
                vim.schedule(function()
                    on_exit({ code = code, signal = 0, stdout = "", stderr = "" })
                end)
            end
            return { kill = function() end, wait = function() return { code = code } end, pid = 0 }
        end
        C.run_testcases(rbuf, nil, true)
        return C.runners[rbuf]
    end
    local function commands_run()
        return vim.tbl_map(function(s)
            return s.argv[1]
        end, spawns)
    end
    local nr = listed_normal(0)
    drain(nr.ui)
    t.eq(
        "a listed board opens on a testcase, its editable panes accented",
        { nr.ui:selected_index(), accented(nr.ui, "eo"), accented(nr.ui, "si") },
        { 2, true, true }
    )
    nr:run_single(2)
    settled(nr)
    t.eq("a listed normal board's run key builds, then runs the row", commands_run(), { compiler, "./sol" })
    t.ok("which then has a verdict", nr.tcdata[2].status ~= "NOT RUN", nr.tcdata[2].status)

    nr = listed_normal(1)
    nr:run_single(2)
    settled(nr)
    t.eq("a build that fails runs nothing behind it", commands_run(), { compiler })
    t.eq("and leaves the row saying it was never run", nr.tcdata[2].status, "NOT RUN")
    t.eq("with the runner idle again", nr:idle(), true)

    nr = listed_normal(0)
    nr:run_single(1)
    settled(nr)
    t.eq("the Compile row's run key builds once", commands_run(), { compiler })
    t.eq("and settles", nr:idle(), true)

    -- An interpreted solution builds nothing, but its first run still saves it: the row runs
    -- the file on disk.
    local py = rdir .. "/sol.py"
    t.write(rdir, "sol.py", "print(1)\n")
    vim.cmd("edit " .. py)
    vim.bo.filetype = "python"
    local pybuf = vim.api.nvim_get_current_buf()
    stub_system()
    C.run_testcases(pybuf, nil, true)
    vim.api.nvim_buf_set_lines(pybuf, 0, -1, false, { "print(2)" })
    C.runners[pybuf]:run_single(1)
    settled(C.runners[pybuf])
    t.eq("a listed interpreted solution is saved before its first row runs", vim.fn.readfile(py), { "print(2)" })
    C.runners[pybuf]:delete_ui()
    C.runners[pybuf] = nil
    vim.system = real_system
    vim.cmd("buffer " .. rbuf)

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
local wtcs = require("tuna.problem.testcases").buf_get_testcases(wbuf)

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
            local r = require("tuna.run").new(wbuf)
            r:load_testcases(wtcs)
            r:show_ui()
            return r
        end,
        run = function()
            local r = require("tuna.run").new(wbuf)
            r:show_ui()
            r:run_testcases(wtcs)
            return r
        end,
    },
    {
        name = "run-all",
        show = function()
            require("tuna.run.modes.multi").show(wbuf)
            return require("tuna.run.modes.multi").active[wbuf]
        end,
        run = function()
            require("tuna.run.modes.multi").run(wbuf)
            return require("tuna.run.modes.multi").active[wbuf]
        end,
    },
    {
        name = "stress",
        show = function()
            require("tuna.run.modes.stress").show(wbuf)
            return require("tuna.run.modes.stress").active[wbuf]
        end,
        run = function()
            require("tuna.run.modes.stress").run(wbuf, 1)
            return require("tuna.run.modes.stress").active[wbuf]
        end,
    },
    {
        name = "interactive",
        -- Sessions are held one row at a time, so the row shown is the one being talked to.
        run_row = function(r)
            return r.active_index
        end,
        show = function()
            require("tuna.run.modes.interactive").show(wbuf)
            return require("tuna.run.modes.interactive").active[wbuf]
        end,
        run = function()
            require("tuna.run.modes.interactive").run(wbuf, { "feed" })
            return require("tuna.run.modes.interactive").active[wbuf]
        end,
    },
}

---Let the rows, the build and the scheduled renders settle, then say which row is shown.
local function shown_row(r, want)
    vim.wait(3000, function()
        return r.ui ~= nil and r.ui.ui_visible and #r.tcdata > 0 and r.ui:selected_index() == want
    end, 20)
    drain(r.ui)
    return r.ui and r.ui:selected_index()
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
    settled(r)
    drain(r.ui)
    local want = board.run_row and board.run_row(r) or first_real_row(r)
    t.eq(board.name .. ": run, a silent build hands over the row the run is about", r.ui:selected_index(), want)
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
    settled(r)
    if r.tcdata[1] and r.tcdata[1].tcnum == "Compile" then
        built = built + 1
        t.eq(board.name .. ": a build that failed says so on its row", {
            r.tcdata[1].status,
            r.tcdata[1].hlgroup,
        }, { "RET 1", "TunaWarning" })
        t.ok(board.name .. ": and the run settles, nothing having started", r:idle(), r.tcdata[1])
        -- The build step's own grid has an Errors pane whatever the configured one lacks,
        -- so the failure is read where the run left the cursor, with nothing opened over it.
        drain(r.ui)
        t.eq(board.name .. ": read on the build step itself, nothing opened over the board", {
            r.ui:selected_index(),
            r.ui.zoom_winid,
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

-- How a process ended reads the same in every mode, for a testcase, a session or a stress
-- helper alike.
do
    local ending = core.ending
    t.eq("a timeout", { ending({ timed_out = true }, 1500) }, { "TIMEOUT", "TunaWrong", "timed out after 1.5 s" })
    t.eq("vim.system's own timeout kill is one too", (ending({ code = 124, signal = 15 })), "TIMEOUT")
    t.eq("a stop", { ending({ killed = true, signal = 9 }) }, { "KILLED", "TunaWarning", "was stopped" })
    t.eq("a signal", { ending({ code = 0, signal = 6 }) }, { "SIG 6", "TunaWarning", "was killed by signal 6" })
    t.eq("an exit code", { ending({ code = 3, signal = 0 }) }, { "RET 3", "TunaWarning", "exited with code 3" })
    t.eq("and a clean exit is no ending at all", ending({ code = 0, signal = 0 }), nil)
end

-- A run of the whole set builds the solution first, in every mode: "run all again" after an
-- edit runs the program as it now is, not the one built last time.
local function compiled_solution()
    for _, s in ipairs(spawns) do
        if s.argv[1] == "g++" then
            for _, arg in ipairs(s.argv) do
                if arg:match("sol%.cpp$") then
                    return true
                end
            end
        end
    end
    return false
end
for _, board in ipairs(boards) do
    stub_system()
    local r = board.run()
    vim.wait(3000, function()
        return r:idle()
    end, 20)
    -- As the UI's key does it: whatever runs is stopped, then the run starts over.
    r:kill_all_processes()
    spawns = {}
    r:run_testcases()
    vim.wait(3000, function()
        return #spawns > 0 and r:idle()
    end, 20)
    t.ok(board.name .. ": run all again builds the solution again", compiled_solution(), spawns)
    local ran = 0
    for _, tc in ipairs(r.tcdata) do
        if type(tc.tcnum) == "number" and tc.status ~= "NOT RUN" and tc.status ~= "" then
            ran = ran + 1
        end
    end
    t.ok(board.name .. ": and runs the testcases, the stop before it forgotten", ran > 0, r.tcdata)
    r:kill_all_processes()
    r:delete_ui()
    vim.system = real_system
end

-- Stopping a run stops it, in every mode: what runs is killed, nothing queued starts, the rows
-- that never ran say so, and the board is idle again, so it can be edited.
local function hanging_system()
    spawns = {}
    vim.system = function(argv, _, on_exit)
        spawns[#spawns + 1] = { argv = argv }
        if argv[1] == "g++" then -- a build finishes at once, a solution runs until stopped
            vim.schedule(function()
                on_exit({ code = 0, signal = 0, stdout = "", stderr = "" })
            end)
        end
        return {
            pid = 0,
            wait = function()
                return { code = 0 }
            end,
            kill = function()
                vim.schedule(function()
                    on_exit({ code = 0, signal = 9, stdout = "", stderr = "" })
                end)
            end,
        }
    end
end
require("tuna.config").setup({ multiple_testing = 1 })
for _, board in ipairs(boards) do
    if board.name == "a normal run" or board.name == "run-all" then
        hanging_system()
        local r = board.run()
        vim.wait(3000, function()
            for _, tc in ipairs(r.tcdata) do
                if tc.status == "RUNNING" and tc.tcnum ~= "Compile" then
                    return true
                end
            end
            return false
        end, 20)
        r:kill_all_processes()
        local spawned = #spawns
        drain(r.ui)
        local cases = {}
        for _, tc in ipairs(r.tcdata) do
            if type(tc.tcnum) == "number" then
                cases[#cases + 1] = tc.status
            end
        end
        t.eq(board.name .. ": a stopped run kills what runs, and nothing it queued starts", cases, { "KILLED", "NOT RUN" })
        t.eq(board.name .. ": nothing is spawned after the stop", #spawns, spawned)
        t.eq(board.name .. ": and the board is idle again", r:idle(), true)
        if board.name == "run-all" then
            local header = r.tcdata[1]
            t.eq("run-all: its header counts no stopped row as a failure", { header.status, header.hlgroup }, { "0/0", "TunaDone" })
        end
        r:delete_ui()
        vim.system = real_system
    end
end
require("tuna.config").setup({})

-- Interactive holds one session at a time: a stop ends the one running and starts no other,
-- and the row it was on reads KILLED, as a stopped testcase does everywhere.
do
    stub_system()
    local ir = boards[4].run()
    vim.wait(3000, function()
        return ir:idle()
    end, 20)
    local held, sessions = nil, 0
    ir.run_one_session = function(_, idx, on_done)
        sessions = sessions + 1
        ir.active_index, held = idx, on_done
    end
    ir:run_testcases()
    vim.wait(3000, function()
        return held ~= nil
    end, 20)
    ir.sol_handle = {
        is_active = function()
            return true
        end,
        kill = function() end,
    }
    ir:kill_all_processes()
    ir.sol_handle = nil
    t.eq("interactive: the session being stopped is marked killed", ir.tcdata[ir.active_index].killed, true)
    held()
    local last = ir.tcdata[#ir.tcdata]
    t.eq("interactive: no session starts after a stop", sessions, 1)
    t.eq("interactive: the one that never started says so", { last.status, ir:idle() }, { "NOT RUN", true })
    ir:delete_ui()
    vim.system = real_system
end

-- A run-all board only listed has judged nothing, so adding a testcase to it leaves every
-- header saying so rather than counting the rows as failures.
do
    local mr2 = boards[2].show()
    mr2:add_testcase_row(7)
    t.eq("run-all: a listed board's header counts nothing", { mr2.tcdata[1].status, mr2.tcdata[1].hlgroup }, { "0/0", "TunaDone" })
    mr2:delete_ui()
end

-- Leaving a stress board that was only listed says nothing about stopping: nothing ran.
do
    local sr3 = boards[3].show()
    local quiet = vim.notify
    local said = t.capture_notifications()
    sr3:kill_all_processes()
    vim.notify = quiet
    t.eq("stress: a listed board stops without a word", said, {})
    sr3:delete_ui()
end

-- The board's own choice is not a move by hand: while it opens, the row it is about to choose
-- and the line the cursor is on have to agree, or the first cursor event the editor sends
-- reads as the user taking over and the board never chooses again.
stub_system()
local fresh = require("tuna.run").new(wbuf)
fresh:load_testcases(wtcs)
fresh:show_ui()
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = fresh.ui.windows.tc.bufnr })
vim.wait(1000, function()
    return fresh.ui:selected_index() == 2
end, 20)
t.eq("a cursor event while the board opens is not a move by hand", { fresh.ui:selected_index(), fresh.ui.user_moved }, { 2, false })
fresh:delete_ui()
vim.system = real_system

-- A conversation follows its sessions, but not once the selector has been taken over: the
-- next session would pull the cursor off the row someone chose to read.
stub_system()
require("tuna.run.modes.interactive").run(wbuf, { "feed" })
local held = require("tuna.run.modes.interactive").active[wbuf]
vim.wait(3000, function()
    return held.ui ~= nil and held.ui.ui_visible and held.completed
end, 20)
local held_tc = held.ui.windows.tc
vim.api.nvim_win_set_cursor(held_tc.winid, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = held_tc.bufnr })
t.eq("the selector can be taken over mid-conversation", held.ui:selected_index(), 1)
held:run_testcases()
drain(held.ui)
vim.wait(3000, function()
    return held.completed
end, 20)
drain(held.ui)
t.eq("and the sessions that follow leave it where it was put", held.ui:selected_index(), 1)
held:kill_all_processes()
held:delete_ui()
vim.system = real_system

-- A list that gets shorter than the row the board chose takes the choice with it, rather than
-- leaving Vim to clamp the cursor onto another row, which reads as a move by hand.
stub_system()
local shrink = require("tuna.run").new(wbuf)
shrink:load_testcases(wtcs)
shrink:show_ui()
vim.wait(1000, function()
    return shrink.ui ~= nil and shrink.ui:selected_index() == 2
end, 20)
shrink.ui:follow_row(3) -- as a conversation does, ending on the row it was held on
t.eq("the board can choose the last row", { shrink.ui:selected_index(), shrink.ui.user_moved }, { 3, false })
shrink:load_testcases({ [0] = { input = "1\n", output = "1\n" } })
vim.wait(1000, function()
    return #shrink.tcdata == 2
end, 20)
drain(shrink.ui)
t.eq("a shorter list moves the choice down with it", { shrink.ui:selected_index(), shrink.ui.user_moved }, { 2, false })
t.eq("with the cursor on it", vim.api.nvim_win_get_cursor(shrink.ui.windows.tc.winid)[1], 2)
shrink:delete_ui()
vim.system = real_system

-- Which row a board opens on, as a rule over the rows themselves. A run's build is the row
-- from the moment the run starts, not from the moment the compiler is spawned: the two are a
-- tick apart, and a board opened in between drew the panes of a run for a build about to
-- start, then redrew them — the flash of a grid that was never the right one.
stub_system()
local opening = require("tuna.run").new(wbuf)
opening:load_testcases(wtcs)
opening:show_ui()
vim.wait(1000, function()
    return opening.ui:selected_index() == 2
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
vim.system = function(argv, _, on_exit)
    -- The helpers' builds answer at once: the build being held is the solution's.
    if vim.tbl_contains(argv, "gen.cpp") or vim.tbl_contains(argv, "brute.cpp") then
        vim.schedule(function()
            on_exit({ code = 0, signal = 0, stdout = "", stderr = "" })
        end)
    else
        held_exit = on_exit
    end
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
        require("tuna.run.modes.interactive").run(wbuf, { "feed" })
        return require("tuna.run.modes.interactive").active[wbuf]
    end },
    { name = "stress", start = function()
        require("tuna.run.modes.stress").run(wbuf, 1)
        return require("tuna.run.modes.stress").active[wbuf]
    end },
}) do
    held_exit = nil
    local r = building.start()
    vim.wait(2000, function()
        return r.ui ~= nil and r.ui.ui_visible and #r.tcdata > 0 and held_exit ~= nil
    end, 20)
    drain(r.ui)
    t.eq(building.name .. ": a run opens on the build while it is still going", {
        r.ui:selected_index(),
        r.compile_entry.running,
    }, { 1, true })
    held_exit({ code = 0, signal = 0, stdout = "", stderr = "" })
    vim.wait(2000, function()
        return r.ui:selected_index() ~= 1
    end, 20)
    -- Off the build and onto a real row: which one is the mode's business (interactive walks
    -- its sessions from there), the point being that it waited for the build to end.
    t.ok(building.name .. ": and moves on once it ends with nothing to say", r.ui:selected_index() >= 2, r.ui:selected_index())
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
local noisy = require("tuna.run").new(wbuf)
noisy:show_ui()
noisy:run_testcases(wtcs)
vim.wait(2000, function()
    return noisy.completed
end, 20)
drain(noisy.ui)
t.eq("a build that printed something keeps the row, so it can be read", noisy.ui:selected_index(), 1)
noisy:delete_ui()
vim.system = real_system

-- A selector moved by hand holds its row while the run it is watching lands, the next run
-- asked for hands the choice back, and reopening the board returns to the row last looked at.
stub_system()
vim.api.nvim_set_current_buf(wbuf)
local C3 = require("tuna.commands")
-- The generator and bruteforce beside this solution would make `:Tuna run` a stress run.
require("tuna.run.tools").set_mode(wdir .. "/sol.cpp", "normal")
C3.execute({ "run" })
local chosen = C3.runners[wbuf]
vim.wait(3000, function()
    return chosen ~= nil and chosen.ui ~= nil and chosen.ui.ui_visible and chosen.completed
end, 20)
drain(chosen.ui)
local function move_to(row)
    local w = chosen.ui.windows.tc
    vim.api.nvim_win_set_cursor(w.winid, { row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = w.bufnr })
end
move_to(3)
move_to(2)
t.eq("moving back before a render selects the row moved back to", chosen.ui:selected_index(), 2)
move_to(3)
t.eq("moving the selector by hand selects that row", { chosen.ui:selected_index(), chosen.ui.user_moved }, { 3, true })
chosen:update_ui(true)
drain(chosen.ui)
t.eq("and results landing leave it where it was put", chosen.ui:selected_index(), 3)
-- A move whose cursor event has not arrived yet is the user's too: a render meanwhile leaves
-- the cursor where they put it.
vim.api.nvim_win_set_cursor(chosen.ui.windows.tc.winid, { 2, 0 })
chosen:update_ui(true)
drain(chosen.ui)
t.eq("a render before a move's cursor event leaves the cursor where it was put", vim.api.nvim_win_get_cursor(chosen.ui.windows.tc.winid)[1], 2)

C3.execute({ "run" })
vim.wait(3000, function()
    return chosen.completed and chosen.ui:selected_index() == 2
end, 20)
t.eq("a run asked for hands the choice back", { chosen.ui:selected_index(), chosen.ui.user_moved }, { 2, false })

move_to(3)
chosen.ui:delete()
C3.show_runner_ui(wbuf)
vim.wait(2000, function()
    return chosen.ui.ui_visible and chosen.ui:selected_index() == 3
end, 20)
t.eq("and reopening the board returns to the row last looked at", chosen.ui:selected_index(), 3)
chosen:kill_all_processes()
chosen:delete_ui()
C3.runners[wbuf] = nil
require("tuna.run.tools").set_mode(wdir .. "/sol.cpp", nil)
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
local grid = require("tuna.run").new(wbuf)
grid:load_testcases(wtcs)
grid:show_ui()
vim.wait(1000, function()
    return grid.ui:selected_index() == 2
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
require("tuna.run.modes.interactive").run(wbuf, { "live" }, { show_only = true })
local conv_grid = require("tuna.run.modes.interactive").active[wbuf]
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
require("tuna.run.modes.interactive").run(wbuf, { "live" }, { show_only = true })
local shaped = require("tuna.run.modes.interactive").active[wbuf]
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
require("tuna.run.modes.interactive").run(wbuf, { "feed" }, { show_only = true })
local fed = require("tuna.run.modes.interactive").active[wbuf]
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

-- The build step's grid is written in its own vocabulary: the selector and one `build` cell,
-- split into a pane per source. The detail panes' names say what they show on a testcase row,
-- a stdout or a stdin, and none of that is on the build step, so a grid naming them there is
-- refused, as is one with nowhere to put the build. The two vocabularies do not mix.
local layout_util = require("tuna.runner_ui.layout")
local build_default = require("tuna.config").defaults.runner_ui.compile_layout
local warned = {}
local notify_before = vim.notify
vim.notify = function(msg)
    warned[#warned + 1] = tostring(msg)
end
for what, bad in pairs({
    ["a pane that shows a run"] = { { 3, "tc" }, { 4, "build" }, { 4, "so" } },
    ["no build cell"] = { { 1, "tc" } },
    ["no grid at all"] = false,
}) do
    warned = {}
    t.eq("a build grid with " .. what .. " gives way to the default", (layout_util.resolve(bad, "runner_ui.compile_layout", build_default, "build")), build_default)
    t.has("and says which option it was", warned[1], "runner_ui.compile_layout")
end
warned = {}
t.eq("the selector and a build cell are all it needs", (layout_util.resolve({ { 1, "tc" }, { 1, "build" } }, "x", build_default, "build")), { { 1, "tc" }, { 1, "build" } })
t.eq("and nothing warned about it", warned, {})
local run_default = require("tuna.config").defaults.popup_ui.layout
t.eq("while a testcase row's grid may not place a build cell", (layout_util.resolve({ { 1, "tc" }, { 1, "build" } }, "popup_ui.layout", run_default)), run_default)
vim.notify = notify_before
vim.system = real_system

--------------------------------------------------------------------------------
-- A `:Tuna` command typed in one of tuna's own windows
--------------------------------------------------------------------------------

-- A runner UI pane is not a file, so a command typed there is about the solution the pane is
-- showing. Acting on the pane itself compiled nothing and kept the problem's run state under
-- a name that is not a path, writing it under whatever directory the editor was started in.
local C2 = require("tuna.commands")
local tools2 = require("tuna.run.tools")
local pdir = t.tempdir()
t.write(pdir, "sol.cpp", "int main(){}\n")
t.write(pdir, "sol_input0.txt", "1\n")
vim.cmd("edit " .. pdir .. "/sol.cpp")
vim.bo.filetype = "cpp"
local pbuf = vim.api.nvim_get_current_buf()
local sol_path = pdir .. "/sol.cpp"

stub_system()
local pane_runner = require("tuna.run").new(pbuf)
pane_runner:show_ui()
vim.api.nvim_set_current_win(pane_runner.ui.windows.so.winid)
t.eq("a command typed in a pane is about the solution it shows", C2.target_buffer(), pbuf)
t.eq("a buffer of its own is itself", C2.target_buffer(pbuf), pbuf)

C2.execute({ "run", "all" })
vim.wait(3000, function()
    local matrix = require("tuna.run.modes.multi").active[pbuf]
    return matrix ~= nil and matrix.completed
end, 20)
vim.system = real_system
t.eq("so a run typed there forces the mode for the solution", tools2.get_mode(sol_path), "all")
t.eq("and nothing is written beside a name that is not a path", vim.fn.isdirectory(vim.fn.getcwd() .. "/tuna:"), 0)
local pane_buf = pane_runner.ui.windows.so.bufnr
local matrix = require("tuna.run.modes.multi").active[pbuf]
if matrix then
    matrix:delete_ui()
end
pane_runner:delete_ui()
-- A pane's buffer is wiped with its window, so what it belonged to is forgotten with it, or a
-- later command would be sent to a runner that is gone.
t.eq("a pane that is gone belongs to nothing", require("tuna.runner_ui").owner_of(pane_buf), nil)
vim.fn.delete(pdir, "rf")

-- A runner is kept by buffer until the buffer unloads, however often it is replaced: one
-- unload watcher per registry and buffer, not one per run.
do
    local reg = {}
    local b = vim.api.nvim_create_buf(true, false)
    for i = 1, 3 do
        core.register(reg, b, { i = i })
    end
    t.eq("a runner registered again replaces the last, under one unload watcher", {
        reg[b].i,
        #vim.api.nvim_get_autocmds({ event = "BufUnload", buffer = b }),
    }, { 3, 1 })
    vim.api.nvim_buf_delete(b, { force = true })
    t.eq("and is forgotten when its buffer unloads", reg[b], nil)
end


--------------------------------------------------------------------------------
-- Generating a testcase: the generator run once, with no stress around it
--------------------------------------------------------------------------------

-- The generator writes a testcase's input, with no answer, under the lowest free number, from a
-- seed of its own that the message names. From the command it is a file; on a board, and from
-- the command while a board is open, a row, selected and run, reading DONE. A generator that
-- fails writes nothing, and one that is missing offers its starter.
do
    local gdir = t.tempdir()
    t.write(gdir, "main.cpp", "int main(){}\n")
    local function program(name)
        t.write(gdir, name, "#!/bin/sh\n")
        vim.fn.setfperm(gdir .. "/" .. name, "rwxr-xr-x")
        return gdir .. "/" .. name
    end
    local ccx, solx, genx = program("ccx"), program("solx"), program("genx")
    local function configure(pass_seed, generator)
        require("tuna.config").setup({
            compile_command = { cpp = { exec = ccx, args = { "$(FNAME)" } } },
            run_command = { cpp = { exec = solx } },
            stress = { generator = generator, pass_seed = pass_seed },
        })
    end
    configure(true, { exec = genx, args = {} })
    vim.cmd("edit " .. gdir .. "/main.cpp")
    vim.bo.filetype = "cpp"
    local buf = vim.api.nvim_get_current_buf()
    local gen_argv, gen_result = nil, nil
    vim.system = function(argv, _, on_exit)
        local name = vim.fn.fnamemodify(argv[1], ":t")
        local res = { stdout = name == "solx" and "6\n" or "" }
        if name == "genx" then
            gen_argv, res = argv, gen_result
        end
        if on_exit then
            vim.schedule(function()
                on_exit(vim.tbl_extend("keep", res, { code = 0, signal = 0, stdout = "", stderr = "" }))
            end)
        end
        return { kill = function() end, wait = function() return { code = 0 } end, pid = 0 }
    end
    local quiet = vim.notify
    local said = t.capture_notifications()
    local C3 = require("tuna.commands")
    local function stored(n)
        return gtcs.buf_get_testcases(buf)[n]
    end

    gen_result = { stdout = "3\n1 2 3\n" }
    C3.generate_testcase()
    t.drain()
    t.eq("the command writes the generator's input as a testcase with no answer", stored(0), { input = "3\n1 2 3\n" })
    local seed = gen_argv and gen_argv[#gen_argv]
    t.ok("handed a seed of its own", tonumber(seed) ~= nil, gen_argv)
    t.eq("which the message names", said[#said], "Tuna: testcase 0 generated, seed " .. tostring(seed) .. ".")

    C3.execute({ "run" })
    local r = C3.runners[buf]
    settled(r)
    gen_result = { stdout = "4\n" }
    r.ui:generate_testcase()
    t.drain()
    settled(r)
    drain(r.ui)
    local function row(n)
        return r.tcdata[r:rows_for(n)[1] or 0]
    end
    t.eq("on a board it is a row of its own, run, with no answer to judge it by", {
        row(1) and row(1).stdin,
        row(1) and row(1).status,
        stored(1),
    }, { "4\n", "DONE", { input = "4\n" } })
    t.eq("selected", r.tcdata[r.ui:selected_index()] == row(1), true)

    C3.generate_testcase()
    t.drain()
    t.eq("the command hands it to a board open on the solution", row(2) ~= nil and stored(2) ~= nil, true)
    r:delete_ui()
    drain(r.ui)

    gen_result = { code = 1, stderr = "boom" }
    C3.generate_testcase()
    t.drain()
    t.eq("a generator that fails writes nothing", stored(3), nil)
    t.has("and says how it ended", said[#said], "exited with code 1")

    configure(false, { exec = genx, args = {} })
    gen_result = { stdout = "5\n" }
    C3.generate_testcase()
    t.drain()
    t.eq("with pass_seed off it is handed none, and none is named", { #gen_argv, said[#said] }, { 1, "Tuna: testcase 3 generated." })

    configure(true, nil)
    local scaffold = require("tuna.workspace.scaffold")
    local real_create, offered = scaffold.create_missing, nil
    scaffold.create_missing = function(absent)
        offered = absent
    end
    C3.generate_testcase()
    t.drain()
    scaffold.create_missing = real_create
    t.eq("a missing generator offers its starter", offered, { "generator" })

    vim.notify = quiet
    vim.system = real_system
    C3.runners[buf] = nil
    require("tuna.config").setup({})
    vim.cmd("enew")
    vim.cmd("silent! bwipeout! " .. buf)
    vim.fn.delete(gdir, "rf")
end


--------------------------------------------------------------------------------
-- A pane cut off says so in its border
--------------------------------------------------------------------------------

-- A float has no scrollbar, so each pane's footer counts the lines out of sight: below the last
-- on show, above the first once scrolled, nothing when all of it shows. It follows what is drawn
-- into the pane, the pane scrolling and the zoom.
do
    local odir = t.tempdir()
    t.write(odir, "main.cpp", "int main(){}\n")
    vim.cmd("edit " .. odir .. "/main.cpp")
    vim.bo.filetype = "cpp"
    local obuf = vim.api.nvim_get_current_buf()
    local long = {}
    for i = 1, 60 do
        long[i] = tostring(i)
    end
    local output = table.concat(long, "\n") .. "\n"
    vim.system = function(_, _, on_exit)
        if on_exit then
            vim.schedule(function()
                on_exit({ code = 0, signal = 0, stdout = output, stderr = "" })
            end)
        end
        return { kill = function() end, wait = function() return { code = 0 } end, pid = 0 }
    end
    local r = require("tuna.run").new(obuf)
    r.cc = nil
    r:run_testcases({ [0] = { input = "1\n", output = output } })
    r:show_ui()
    settled(r)
    drain(r.ui)
    local function footer(win)
        local f = vim.api.nvim_win_get_config(win).footer
        return f and f[1] and f[1][1] or ""
    end
    local function hidden(win)
        return vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) - vim.fn.line("w$", win)
    end
    local so = r.ui.windows.so.winid
    t.eq("an output cut off counts the lines below the pane", footer(so), " ↓ " .. hidden(so) .. " ")
    t.eq("and a pane that shows all of it says nothing", footer(r.ui.windows.si.winid), "")
    local function colours(win)
        local hl = vim.wo[win].winhighlight
        return { hl:match("FloatBorder:([%w_]+)"), hl:match("FloatFooter:([%w_]+)") }
    end
    local plain, accented = colours(so), colours(r.ui.windows.si.winid)
    t.eq("in the colour of the border, the editable panes' accent included", {
        plain[1] == plain[2],
        accented[1] == accented[2],
        accented[1] ~= plain[1],
    }, { true, true, true })
    -- A headless editor, with no UI attached, raises no `WinScrolled` of its own.
    vim.api.nvim_win_call(so, function()
        vim.cmd("normal! G")
    end)
    vim.api.nvim_exec_autocmds("WinScrolled", {})
    drain(r.ui)
    t.has("scrolled to its end, it counts the lines above instead", footer(so), "↑ ")
    t.ok("and none below", not footer(so):find("↓"), footer(so))
    local si = r.ui.windows.si.winid
    vim.api.nvim_set_current_win(si)
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(si), 0, -1, false, long)
    drain(r.ui)
    t.has("typing past the bottom of a pane says so as it is typed", footer(si), "↓ ")
    r.ui:zoom("so")
    drain(r.ui)
    t.has("a zoomed pane says so too", footer(r.ui.zoom_winid), "↓ ")
    r.ui:unzoom()
    r.ui:zoom("si")
    drain(r.ui)
    local ztitle = vim.api.nvim_win_get_config(r.ui.zoom_winid).title
    t.eq("an editable pane zoomed keeps its accent, border and title", {
        colours(r.ui.zoom_winid)[1],
        ztitle and ztitle[1] and ztitle[1][2],
    }, { accented[1], accented[1] })
    r.ui:unzoom()
    vim.system = real_system
    r:delete_ui()
    vim.cmd("enew")
    vim.cmd("silent! bwipeout! " .. obuf)
    vim.fn.delete(odir, "rf")
end

t.report()
