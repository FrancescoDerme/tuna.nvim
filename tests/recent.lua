-- tests/recent.lua
--
-- What `:Tuna last` and the menu remember: the last problems and contests, most recent
-- first and as many of each as `recent.problems`/`recent.contests` ask, a revisited one
-- moving back to the top, one whose directory is gone forgotten, and a state file holding a
-- single problem or contest reading as a history of one.

local t = dofile("tests/harness.lua")
-- This test writes the state file, so it only runs where `stdpath("state")` is a throwaway
-- one, as `tests/run.sh` makes it.
assert(vim.env.XDG_STATE_HOME and vim.env.XDG_STATE_HOME ~= "", "run through tests/run.sh")

local store_dir = vim.fn.stdpath("state") .. "/tuna"
local legacy = t.tempdir()
t.write(legacy, "main.cpp", "int main() {}\n")
local legacy_contest = t.tempdir()
vim.fn.mkdir(store_dir, "p")
t.write(store_dir, "recent.json", vim.json.encode({
    problem = { file = legacy .. "/main.cpp", dir = legacy, name = "L" },
    contest = { dir = legacy_contest, name = "LC" },
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

t.eq("a state file with one problem reads as a history of one", files(), { legacy .. "/main.cpp" })
t.eq("and one with one contest too", contests(), { legacy_contest })
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
t.eq("problems outside any contest leave the contests alone", contests(), { legacy_contest })

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

-- A contest with no judge recorded, as the menu names it.
local cf = t.tempdir()
vim.fn.mkdir(cf .. "/B", "p")
local group = "Codeforces - Codeforces Round 1120 (Div. 2)"
t.write(cf .. "/B", ".tuna.json", vim.json.encode({ group = group, url = "https://codeforces.com/contest/2263/problem/B" }))
local legacy_entry = { dir = cf, name = "2263", problem = cf .. "/B/main.cpp" }
t.eq("a contest with no judge takes it from its last problem's sidecar", { recent.contest_label(legacy_entry, cfg) }, { "codeforces", "2263" })
legacy_entry.name = group
t.eq("and its contest name too, when named by the raw group", { recent.contest_label(legacy_entry, cfg) }, { "codeforces", "2263" })
t.eq("a recorded judge is kept", { recent.contest_label({ dir = cf, name = "abc400", judge = "atcoder" }, cfg) }, { "atcoder", "abc400" })

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
t.eq("the histories are what gets written, in order", {
    vim.tbl_map(function(p)
        return p.file
    end, written.problems),
    vim.tbl_map(function(c)
        return c.dir
    end, written.contests),
}, { files(), contests() })
t.eq("with no single problem or contest beside them", { written.problem, written.contest }, {})

t.report()
