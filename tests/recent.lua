-- tests/recent.lua
--
-- What `:Tuna last` and the menu remember: the last problems and contests, most recent
-- first and as many of each as `recent.problems`/`recent.contests` ask, a revisited one
-- moving back to the top, one whose directory is gone forgotten, and the histories read back
-- from the state file; and the pinned problems, most recently pinned first with no limit,
-- toggled by `:Tuna pin` (a helper file pinning its solution), and forgotten once deleted.

local t = dofile("tests/harness.lua")
-- This test writes the state file, so it only runs where `stdpath("state")` is a throwaway
-- one, as `tests/run.sh` makes it.
assert(vim.env.XDG_STATE_HOME and vim.env.XDG_STATE_HOME ~= "", "run through tests/run.sh")

local store_dir = vim.fn.stdpath("state") .. "/tuna"
local stored = t.tempdir()
t.write(stored, "main.cpp", "int main() {}\n")
local stored_contest = t.tempdir()
local stored_pin = t.tempdir()
t.write(stored_pin, "main.cpp", "int main() {}\n")
vim.fn.mkdir(store_dir, "p")
t.write(store_dir, "recent.json", vim.json.encode({
    problems = { { file = stored .. "/main.cpp", dir = stored, name = "L" } },
    contests = { { dir = stored_contest, name = "LC", judge = "codeforces" } },
    pinned = {
        { file = stored_pin .. "/gone.cpp", dir = stored_pin, name = "G" },
        { file = stored_pin .. "/main.cpp", dir = stored_pin, name = "P" },
    },
}))

require("tuna").setup({})
local recent = require("tuna.recent")
local cfg = require("tuna.config").current_setup
local function norm(path)
    return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end
local function files()
    return vim.tbl_map(function(p)
        return p.file
    end, recent.snapshot().problems or {})
end
local function contests()
    return vim.tbl_map(function(c)
        return c.dir
    end, recent.snapshot().contests or {})
end

t.eq("the problems in the state file are read back", files(), { stored .. "/main.cpp" })
t.eq("and the contests", contests(), { stored_contest })
local function pins()
    return vim.tbl_map(function(p)
        return p.file
    end, recent.snapshot().pinned or {})
end
t.eq("and the pinned problems, one whose solution is gone dropped", pins(), { stored_pin .. "/main.cpp" })
t.eq("five problems and three contests by default", { cfg.recent.problems, cfg.recent.contests }, { 5, 3 })

--------------------------------------------------------------------------------
-- Problems
--------------------------------------------------------------------------------

local dirs = {}
for i = 1, 6 do
    dirs[i] = t.tempdir()
    t.write(dirs[i], "main.cpp", "int main() {}\n")
    recent.record_problem(dirs[i] .. "/main.cpp", cfg)
end
local function file_of(i)
    return norm(dirs[i] .. "/main.cpp")
end
t.eq("five are kept, the most recent first", files(), { file_of(6), file_of(5), file_of(4), file_of(3), file_of(2) })
t.eq("problems outside any contest leave the contests alone", contests(), { stored_contest })

recent.record_problem(dirs[3] .. "/main.cpp", cfg)
t.eq("a problem visited again moves back to the top, once", files(), { file_of(3), file_of(6), file_of(5), file_of(4), file_of(2) })

vim.fn.delete(dirs[5], "rf")
recent.record_problem(dirs[4] .. "/main.cpp", cfg)
t.eq("one whose directory is gone is forgotten", files(), { file_of(4), file_of(3), file_of(6), file_of(2) })

recent.open_problem(2)
t.eq("any of them can be opened", norm(vim.api.nvim_buf_get_name(0)), file_of(3))

--------------------------------------------------------------------------------
-- Contests
--------------------------------------------------------------------------------

---A contest directory of two problems whose sidecars agree on its group.
local function contest_of(group)
    local dir = t.tempdir()
    for _, p in ipairs({ "A", "B" }) do
        vim.fn.mkdir(dir .. "/" .. p, "p")
        t.write(dir .. "/" .. p, "main.cpp", "int main() {}\n")
        t.write(dir .. "/" .. p, ".tuna.json", vim.json.encode({ group = group }))
    end
    return norm(dir)
end

local cs = {}
for i = 1, 4 do
    cs[i] = contest_of("Judge - Round " .. i)
    recent.record_problem(cs[i] .. "/A/main.cpp", cfg)
end
t.eq("a problem whose sibling agrees on a group adds its contest, three kept", contests(), { cs[4], cs[3], cs[2] })
t.eq("named by the judge and contest its group parses into", { recent.snapshot().contests[1].judge, recent.snapshot().contests[1].name }, { "judge", "round 4" })

recent.record_problem(cs[2] .. "/B/main.cpp", cfg)
t.eq("a problem inside a known contest brings it back to the top", contests(), { cs[2], cs[4], cs[3] })
t.eq("as the problem last visited in it", recent.snapshot().contests[1].problem, cs[2] .. "/B/main.cpp")

recent.record_contest(cs[3], "Named", cs[3] .. "/A/main.cpp", "judge")
t.eq("a downloaded contest goes to the top", contests(), { cs[3], cs[2], cs[4] })

recent.record_problem(cs[2] .. "/B/main.cpp", cfg)
t.eq("returning to the current problem brings its contest back to the top too", contests(), { cs[2], cs[3], cs[4] })

vim.fn.delete(cs[4], "rf")
recent.record_problem(cs[3] .. "/B/main.cpp", cfg)
t.eq("a contest whose directory is gone is forgotten", contests(), { cs[3], cs[2] })

recent.open_contest(2)
t.eq("any of them can be opened, at the problem last visited in it", norm(vim.api.nvim_buf_get_name(0)), cs[2] .. "/B/main.cpp")
t.eq("which brings it back to the top", contests(), { cs[2], cs[3] })

--------------------------------------------------------------------------------
-- Pinned
--------------------------------------------------------------------------------

do
    local many = {}
    for i = 1, 12 do
        many[i] = norm(t.tempdir() .. "/main.cpp")
        t.write(vim.fs.dirname(many[i]), "main.cpp", "int main() {}\n")
        t.eq("pinning says it is pinned " .. i, recent.toggle_pin(many[i]), true)
    end
    local want = { many[12], many[11] }
    t.eq("the most recently pinned first, and every one kept", { #pins(), pins()[1], pins()[2] }, { 13, want[1], want[2] })
    t.eq("each one is pinned", recent.is_pinned(many[5]), true)

    t.eq("pinning again unpins", recent.toggle_pin(many[5]), false)
    t.eq("and it is gone from the list", { recent.is_pinned(many[5]), #pins() }, { false, 12 })

    os.remove(many[7])
    t.eq("deleting a pinned solution unpins it", { recent.is_pinned(many[7]), #pins() }, { false, 11 })
    recent.unpin(many[8])
    t.eq("and unpin takes one off", vim.tbl_contains(pins(), many[8]), false)

    recent.open_pinned(2)
    t.eq("a pinned problem can be opened", norm(vim.api.nvim_buf_get_name(0)), pins()[2])

    -- `:Tuna pin` acts on the problem: a solution tuna can run, the solution beside a helper.
    local commands = require("tuna.commands")
    local quiet = vim.notify
    local said = t.capture_notifications()
    local pdir = t.tempdir()
    t.write(pdir, "main.cpp", "int main() {}\n")
    t.write(pdir, "gen.cpp", "int main() {}\n")
    t.write(pdir, "notes.txt", "later\n")
    vim.cmd("edit " .. pdir .. "/notes.txt")
    commands.toggle_pin()
    t.eq("a file that is not a solution is not pinned", recent.is_pinned(pdir .. "/notes.txt"), false)
    t.has("and it says why", said[#said], "no problem to pin")
    vim.cmd("edit " .. pdir .. "/gen.cpp")
    commands.execute({ "pin" })
    t.eq("`:Tuna pin` in a helper pins its solution", { recent.is_pinned(pdir .. "/main.cpp"), recent.is_pinned(pdir .. "/gen.cpp") }, { true, false })
    commands.execute({ "pin" })
    t.eq("and again unpins it", recent.is_pinned(pdir .. "/main.cpp"), false)
    vim.notify = quiet
end

--------------------------------------------------------------------------------
-- How many
--------------------------------------------------------------------------------

require("tuna").setup({ recent = { problems = 2, contests = 1 } })
recent.record_problem(dirs[6] .. "/main.cpp", cfg)
t.eq("recent.problems sets how many problems are kept", files(), { file_of(6), cs[2] .. "/B/main.cpp" })
recent.record_problem(cs[1] .. "/A/main.cpp", cfg)
t.eq("and recent.contests how many contests", contests(), { cs[1] })

recent.flush()
local written = vim.json.decode(table.concat(vim.fn.readfile(store_dir .. "/recent.json"), "\n"))
t.eq("the histories and the pins are what gets written, in order", {
    vim.tbl_map(function(p)
        return p.file
    end, written.problems),
    vim.tbl_map(function(c)
        return c.dir
    end, written.contests),
    vim.tbl_map(function(p)
        return p.file
    end, written.pinned),
}, { files(), contests(), pins() })
t.eq("however few problems are remembered, every pin is", #pins(), 10)

t.report()
