-- tests/search.lua
--
-- `:Tuna go search`: where it looks, what a sidecar makes of a file, how a search orders what
-- it finds, and the picker going where it says.

local t = dofile("tests/harness.lua")
local api = vim.api
local search = require("tuna.workspace.search")
local s = search._test
local recent = require("tuna.workspace.recent")
local sidecar = require("tuna.problem.sidecar")

local function press(keys)
    api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

---Write `<dir>/<name>` as the solution of a problem.
local function problem(dir, name, title, group, url)
    vim.fn.mkdir(dir, "p")
    t.write(dir, name, "int main() {}\n")
    sidecar.set_entry(dir .. "/" .. name, "task", { name = title, group = group, url = url })
end

local home = vim.uv.os_homedir()
t.eq("a root stops at the first modifier that changes from problem to problem", {
    s.root_of("$(HOME)/cp/problems/$(JUDGE)/$(PROBLEM)/main.$(FEXT)"),
    s.root_of("$(HOME)/cp/contests/$(JUDGE)/$(CONTEST)/"),
    s.root_of("$(HOME)/cp/round-$(CONTEST)/"),
    s.root_of("$(HOME)/cp/$(FEXT)-solutions/$(PROBLEM).$(FEXT)"),
    s.root_of("~/cp/$(PROBLEM)/"),
    s.root_of("/srv/cp/"),
}, { home .. "/cp/problems", home .. "/cp/contests", home .. "/cp", home .. "/cp", home .. "/cp", "/srv/cp" })
t.eq("and `$(CWD)` and a relative path are the current directory", {
    s.root_of("$(CWD)/$(PROBLEM).$(FEXT)"),
    s.root_of("$(PROBLEM).$(FEXT)"),
}, { vim.fs.normalize(vim.fn.getcwd()), vim.fs.normalize(vim.fn.getcwd()) })

local root = vim.fs.normalize(t.tempdir())
local cf = "https://codeforces.com/contest/7/problem/"
-- One folder per problem, a contest of plain files, and a lone problem.
problem(root .. "/contests/r7/A", "main.cpp", "A. Apples", "Round 7", cf .. "A")
problem(root .. "/contests/r7/B", "main.cpp", "B. Bananas", "Round 7", cf .. "B")
problem(root .. "/flat", "A.cpp", "A. Cherries", "Round 8", "https://x.test/8/A")
problem(root .. "/flat", "B.cpp", "B. Dates", "Round 8", "https://x.test/8/B")
problem(root .. "/problems/one", "main.cpp", "Elderberries", "Set", "https://x.test/set/1")
-- Two attempts at one problem are no contest, and neither are scattered problems.
problem(root .. "/problems/two", "main.cpp", "Figs", "Figs group", "https://x.test/figs")
problem(root .. "/problems/two", "main2.cpp", "Figs", "Figs group", "https://x.test/figs")
problem(root .. "/a/deep/one", "main.cpp", "Grapes", "Spread", "https://x.test/s/1")
problem(root .. "/b/two", "main.cpp", "Honey", "Spread", "https://x.test/s/2")
-- What is not a problem: a task whose file is gone, and a sidecar with no task.
problem(root .. "/gone", "main.cpp", "Gone", nil, "https://x.test/gone")
os.remove(root .. "/gone/main.cpp")
vim.fn.mkdir(root .. "/ran", "p")
t.write(root .. "/ran", "main.cpp", "int main() {}\n")
sidecar.set_entry(root .. "/ran/main.cpp", "results", { passed = 1, total = 1 })
-- Where the walk does not go.
problem(root .. "/node_modules/x", "main.cpp", "Skipped", nil, "https://x.test/skip")
problem(root .. "/.hidden/x", "main.cpp", "Hidden", nil, "https://x.test/hidden")
problem(root .. "/library/x", "main.cpp", "Ignored", nil, "https://x.test/ignored")
vim.fn.mkdir(root .. "/linked", "p")
vim.uv.fs_symlink(root .. "/contests", root .. "/linked/loop")
vim.fn.mkdir(root .. "/broken", "p")
t.write(root .. "/broken", ".tuna.json", "not json")

require("tuna").setup({
    downloaded_problems_path = root .. "/$(PROBLEM)/main.$(FEXT)",
    downloaded_contests_directory = root .. "/$(CONTEST)",
    recent = { ignored_directories = { root .. "/library" } },
})
vim.cmd.edit(vim.fn.fnameescape(root .. "/flat/A.cpp"))

---The buffer the picker's rows are in.
local function list_buffer()
    for _, w in ipairs(api.nvim_list_wins()) do
        local title = api.nvim_win_get_config(w).title
        if type(title) == "table" and vim.trim(title[1][1]) == "Go to" then
            return api.nvim_win_get_buf(w)
        end
    end
end

---The rows the picker lists.
local function listed_rows()
    local buf = list_buffer()
    return buf and api.nvim_buf_get_lines(buf, 0, -1, false) or {}
end

---Wait for the walk to fill the picker.
local function filled()
    vim.wait(2000, function()
        return (listed_rows()[1] or "") ~= ""
    end, 5)
end

---Open the picker and wait for its rows.
local function open_picker()
    search.open(api.nvim_get_current_buf())
    filled()
end

---Dismiss the picker, typing or not.
local function close_picker()
    vim.cmd.stopinsert()
    press("<Esc>")
end

-- The picker is up before the walk is over, typing, and what was typed meanwhile narrows the
-- rows when they arrive.
search.open(api.nvim_get_current_buf())
t.eq("the picker is up when the command returns", { vim.bo.filetype, listed_rows() }, { "tuna", { "" } })
api.nvim_buf_set_lines(0, 0, -1, false, { "bananas" })
filled()
t.eq("what is typed before the rows arrive narrows them", listed_rows(), { "B. Bananas  Round 7" })
close_picker()

-- Rows arrive for the opening that asked for them, not whatever is open by then.
local widgets = require("tuna.ui.widgets")
local first = widgets.menu({}, "A first menu", function() end, api.nvim_get_current_win(), nil, nil, nil, nil, function()
    return {}
end)
widgets.menu({ "other" }, "Another menu", function() end, api.nvim_get_current_win())
widgets.menu_items(first, { "late" })
t.eq("rows for a menu since replaced leave the next one alone", api.nvim_buf_get_lines(0, 0, -1, false), { "other" })
press("<Esc>")

open_picker()
local listed = listed_rows()
-- A contest's pane has no language, so it must not keep the colours of the source before it.
local function pane_syntax()
    for _, w in ipairs(api.nvim_list_wins()) do
        local buf = api.nvim_win_get_buf(w)
        local title = api.nvim_win_get_config(w).title
        if type(title) == "table" and title[1][1]:find("/", 1, true) then
            return vim.bo[buf].syntax
        end
    end
end
press("<Down>")
vim.wait(100, function()
    return pane_syntax() == "cpp"
end, 5)
t.eq("a problem's source is coloured", pane_syntax(), "cpp")
press("<Up>")
vim.wait(100, function()
    return pane_syntax() == ""
end, 5)
t.eq("and a contest's problems are not", pane_syntax(), "")
close_picker()
t.eq("every problem and contest and nothing else, what is recent first, then by path", listed, {
    "Round 8",
    "A. Cherries  Round 8",
    "Grapes  Spread",
    "Honey  Spread",
    "Round 7",
    "A. Apples  Round 7",
    "B. Bananas  Round 7",
    "B. Dates  Round 8",
    "Elderberries  Set",
    "Figs  Figs group",
    "Figs  Figs group",
})

local rows = {
    { text = "A. Apples Round 7" },
    { text = "B. Bananas Round 7" },
    { text = "A. Cherries Round 8" },
    { text = "Round 7" },
}
t.eq("nothing typed shows every row", s.rank(rows, "  "), { 1, 2, 3, 4 })
t.eq("a search matches the name", s.rank(rows, "bananas"), { 2 })
t.eq("and the contest, in either case and word order", s.rank(rows, "CHERR 8"), { 3 })
t.eq("a contest's own row ranks first for its name", s.rank(rows, "round 7")[1], 4)
t.eq("what matches nothing shows nothing", s.rank(rows, "zzz"), {})

-- A group naming its judge twice reads as the contest, and is still found by the judge.
local round = "Codeforces - Codeforces Round 9"
local named = s.catalogue({
    {
        dir = "/r9",
        names = { ["A.cpp"] = true, ["B.cpp"] = true },
        content = vim.json.encode({
            task = {
                ["A.cpp"] = { name = "A. Ink", group = round, url = "https://x.test/9/A" },
                ["B.cpp"] = { name = "B. Jam", group = round, url = "https://x.test/9/B" },
            },
        }),
    },
})
t.eq(
    "a row says the judge once, on a contest and on its problems",
    vim.tbl_map(function(r)
        return r.name
    end, named),
    { "Codeforces Round 9", "A. Ink  Codeforces Round 9", "B. Jam  Codeforces Round 9" }
)
t.eq("the contest is entered under that name", named[1].contest, "Codeforces Round 9")
t.eq("a search still matches the whole group", #s.rank(named, "codeforces - codeforces"), 3)

-- Picking goes there, the directory moving with it.
local function pick(query, expect)
    open_picker()
    api.nvim_buf_set_lines(0, 0, -1, false, { query })
    local quiet = vim.notify
    vim.notify = function() end
    vim.cmd.stopinsert()
    press("<CR>")
    vim.notify = quiet
    vim.wait(500, function()
        return api.nvim_buf_get_name(0) == expect
    end, 5)
    return api.nvim_buf_get_name(0), vim.fs.normalize(vim.fn.getcwd())
end
local file, cwd = pick("bananas", root .. "/contests/r7/B/main.cpp")
t.eq("picking a problem opens it", file, root .. "/contests/r7/B/main.cpp")
t.eq("and moves there", cwd, root .. "/contests/r7/B")
file, cwd = pick("round 8", root .. "/flat/A.cpp")
t.eq("picking a contest opens a problem in it", file, root .. "/flat/A.cpp")
t.eq("and moves to the contest", cwd, root .. "/flat")

-- What it says when there is nothing to show, and when it stopped short.
local said = {}
local quiet = vim.notify
vim.notify = function(msg)
    said[#said + 1] = msg
end
local function search_with(opts)
    said = {}
    require("tuna").setup(opts)
    search.open(api.nvim_get_current_buf())
    vim.wait(1000, function()
        return #said > 0
    end, 5)
    return table.concat(said, " ")
end
local empty = vim.fs.normalize(t.tempdir())
t.has("with nothing under the roots it says what is listed", search_with({
    downloaded_problems_path = empty .. "/$(PROBLEM).$(FEXT)",
    downloaded_contests_directory = empty .. "/$(CONTEST)",
}), "only problems downloaded or submitted")
vim.wait(100, function()
    return not list_buffer()
end, 5)
t.eq("and closes the picker", list_buffer(), nil)
t.has("a walk stopped by its budget says so", search_with({
    downloaded_problems_path = root .. "/$(PROBLEM)/main.$(FEXT)",
    downloaded_contests_directory = root .. "/$(CONTEST)",
    search = { max_entries = 1 },
}), "stopped after 1 entries")
vim.notify = quiet

vim.fn.delete(root, "rf")
vim.fn.delete(empty, "rf")
t.report()
