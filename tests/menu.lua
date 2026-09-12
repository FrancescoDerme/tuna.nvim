-- tests/menu.lua
--
-- The menu's Contests and Problems lists: a contest summarised over every problem in
-- it, in either layout and counting only verdicts that still describe the file on disk; a
-- problem's judge verdict, else its saved local verdict; statuses in the results grid's
-- words and colours, counts left plain and flush right; and `widgets.panels` stacking the
-- two lists in one column, scrolling a list that does not fit.

local t = dofile("tests/harness.lua")
require("tuna").setup({})
local menu = require("tuna.menu")._test
local core = require("tuna.runner.core")

---A solution file, with a recorded verdict for it when `verdict` is given.
local function solution(dir, name, verdict)
    local text = "int main() {}\n"
    t.write(dir, name, text)
    if verdict then
        local path = dir .. "/.tuna.json"
        local store = vim.fn.filereadable(path) == 1 and vim.json.decode(table.concat(vim.fn.readfile(path), "\n")) or {}
        store.submit = store.submit or {}
        store.submit[name] = { state = verdict, text = verdict, hash = vim.fn.sha256(text) }
        t.write(dir, ".tuna.json", vim.json.encode(store))
    end
end

--------------------------------------------------------------------------------
-- A contest, summarised
--------------------------------------------------------------------------------

-- One directory per problem.
local contest = t.tempdir()
for name, verdict in pairs({ A = "accepted", B = "rejected", C = false, D = "partial" }) do
    vim.fn.mkdir(contest .. "/" .. name, "p")
    solution(contest .. "/" .. name, "main.cpp", verdict or nil)
end
vim.fn.mkdir(contest .. "/E", "p")
t.write(contest .. "/E", "checker.cpp", "int main() {}\n") -- a helper alone is no problem
vim.fn.mkdir(contest .. "/.git", "p")
t.eq("every problem directory counts, verdicts summed, only the words coloured", menu.contest_status({ dir = contest, name = "c" }), {
    { "1/4 " },
    { "ACCEPTED", "TunaCorrect" },
    { ", " },
    { "1 " },
    { "REJECTED", "TunaWrong" },
    { ", " },
    { "1 " },
    { "PARTIAL", "TunaWarning" },
})

-- A verdict for a source edited since describes a different program.
t.write(contest .. "/A", "main.cpp", "int main() { return 1; }\n")
t.eq("a verdict the file has moved past is not counted, and none accepted is dimmed", vim.list_slice(menu.contest_status({ dir = contest, name = "c" }), 1, 2), { { "0/4 " }, { "ACCEPTED", "TunaDone" } })

-- Problems as plain files in the contest directory.
local flat = t.tempdir()
solution(flat, "a.cpp", "accepted")
solution(flat, "b.cpp", nil)
t.write(flat, "gen.cpp", "int main() {}\n")
t.eq("plain files are problems too, helpers aside", menu.contest_status({ dir = flat, name = "f" }), { { "1/2 " }, { "ACCEPTED", "TunaCorrect" } })

t.eq("a contest with no problems says nothing", menu.contest_status({ dir = t.tempdir(), name = "e" }), {})
t.eq("and neither does one whose directory is gone", menu.contest_status({ dir = "/nonexistent/tuna/contest", name = "g" }), {})

--------------------------------------------------------------------------------
-- A problem: the judge's verdict, else the local one
--------------------------------------------------------------------------------

t.eq("an accepted problem reads ACCEPTED, in green", menu.entry_status(flat .. "/a.cpp"), { { "ACCEPTED", "TunaCorrect" } })
t.eq("a rejected one REJECTED, in red", menu.entry_status(contest .. "/B/main.cpp"), { { "REJECTED", "TunaWrong" } })
t.eq("one with nothing to say says nothing", menu.entry_status(flat .. "/b.cpp"), {})

core.save_local_verdict(flat .. "/b.cpp", {
    { tcnum = "Compile", status = "CORRECT" }, -- not a testcase
    { tcnum = 0, status = "CORRECT" },
    { tcnum = 1, status = "WRONG" },
    { tcnum = 2, status = "TIMEOUT" },
    { tcnum = 3, status = "RET 1" },
    { tcnum = 4, status = "SIG 11" },
    { tcnum = 5, status = "DONE" },
    { tcnum = 6, status = "KILLED" },
    { tcnum = 7, status = "FAILED" },
    { tcnum = 8, status = "NOT RUN" },
})
t.eq("a run's local verdict counts the testcases it judged", { core.local_verdict(flat .. "/b.cpp") }, { 1, 5 })
t.eq("a problem the judge has not spoken on shows it, only the word coloured", menu.entry_status(flat .. "/b.cpp"), { { "1/5 " }, { "PASSED", "TunaWrong" } })
core.save_local_verdict(flat .. "/b.cpp", { { tcnum = 0, status = "DONE" } })
t.eq("a run that judged nothing leaves the saved verdict alone", { core.local_verdict(flat .. "/b.cpp") }, { 1, 5 })
core.save_local_verdict(flat .. "/b.cpp", { { tcnum = 0, status = "CORRECT" }, { tcnum = 1, status = "CORRECT" } })
t.eq("all passing is green", menu.entry_status(flat .. "/b.cpp"), { { "2/2 " }, { "PASSED", "TunaCorrect" } })
t.write(flat, "b.cpp", "int main() { return 2; }\n")
t.eq("a local verdict the source has moved past is not shown", menu.entry_status(flat .. "/b.cpp"), {})

core.save_local_verdict(flat .. "/a.cpp", { { tcnum = 0, status = "WRONG" } })
t.eq("a judge verdict still describing the source wins over a local one", menu.entry_status(flat .. "/a.cpp"), { { "ACCEPTED", "TunaCorrect" } })
t.write(flat, "a.cpp", "int main() { return 3; }\n")
core.save_local_verdict(flat .. "/a.cpp", { { tcnum = 0, status = "WRONG" } })
t.eq("once the source changes, the new run's local verdict shows", menu.entry_status(flat .. "/a.cpp"), { { "0/1 " }, { "PASSED", "TunaWrong" } })
t.eq("a contest counts judge verdicts only", vim.list_slice(menu.contest_status({ dir = flat, name = "f" }), 1, 2), { { "0/2 " }, { "ACCEPTED", "TunaDone" } })
local keys = vim.tbl_keys(vim.json.decode(table.concat(vim.fn.readfile(flat .. "/.tuna.json"), "\n")))
table.sort(keys)
t.eq("the local verdict sits beside the judge's in the sidecar", keys, { "results", "submit" })

--------------------------------------------------------------------------------
-- The rows, and where their colours go
--------------------------------------------------------------------------------

local contests = { { judge = "codeforces", name = "2263", status = { { "1/2 " }, { "ACCEPTED", "TunaCorrect" }, { ", " }, { "1 " }, { "REJECTED", "TunaWrong" } } } }
local problems = {
    { name = "A", status = { { "ACCEPTED", "TunaCorrect" } } },
    { name = "C2. Floor of MEX (Hard Version)", status = {} },
    { name = "C", status = { { "3/4 " }, { "PASSED", "TunaWrong" } } },
}
local lists = { contests, problems }

local function covered(laid)
    local out = {}
    for l, list in ipairs(laid) do
        out[l] = {}
        for _, h in ipairs(list.highlights) do
            table.insert(out[l], { h.row, list.rows[h.row]:sub(h.col + 1, h.end_col), h.group })
        end
    end
    return out
end
local WORDS = {
    { { 1, "ACCEPTED", "TunaCorrect" }, { 1, "REJECTED", "TunaWrong" } },
    { { 1, "ACCEPTED", "TunaCorrect" }, { 3, "PASSED", "TunaWrong" } },
}

-- Names are 31 cells at most ("C2. …"), statuses 24 ("1/2 ACCEPTED, 1 REJECTED").
local laid = menu.recent_layout(lists)
t.eq("a contest row is its judge and name, then its status", laid[1].rows, { "codeforces 2263" .. (" "):rep(18) .. "1/2 ACCEPTED, 1 REJECTED" })
t.eq("every status sits right of the longest name, flush right", laid[2].rows, {
    "A" .. (" "):rep(48) .. "ACCEPTED",
    "C2. Floor of MEX (Hard Version)",
    "C" .. (" "):rep(46) .. "3/4 PASSED",
})
t.eq("each colour covers exactly its word", covered(laid), WORDS)

local function widest(l)
    local w = 0
    for _, list in ipairs(l) do
        for _, row in ipairs(list.rows) do
            w = math.max(w, vim.api.nvim_strwidth(row))
        end
    end
    return w
end
laid = menu.recent_layout(lists, 40)
t.eq("too narrow, the names give way, a contest's judge first", { laid[1].rows, laid[2].rows }, {
    { "codeforc… 2263  1/2 ACCEPTED, 1 REJECTED" },
    { "A" .. (" "):rep(31) .. "ACCEPTED", "C2. Floor of…", "C" .. (" "):rep(29) .. "3/4 PASSED" },
})
t.eq("and the rows fit", widest(laid), 40)
t.eq("with the colours still on their words", covered(laid), WORDS)
laid = menu.recent_layout(lists, 30)
t.eq("narrower still, the judge goes and the names shorten", { laid[1].rows[1], laid[2].rows[2] }, { "2263  1/2 ACCEPTED, 1 REJECTED", "C2.…" })
t.eq("statuses whole all the same", widest(laid), 30)

t.eq("problems are named by their directory, told apart by what differs", menu.problem_names({
    { file = "/cp/2263/A/main.cpp", dir = "/cp/2263/A", name = "A" },
    { file = "/cp/2264/A/main.cpp", dir = "/cp/2264/A", name = "A" },
    { file = "/cp/2264/B/main.cpp", dir = "/cp/2264/B", name = "B" },
    { file = "/cp/2264/B/other.cpp", dir = "/cp/2264/B", name = "B" },
    { file = "/cp/2264/C/main.cpp", dir = "/cp/2264/C", name = "C" },
}), { "2263/A", "2264/A", "B (main.cpp)", "B (other.cpp)", "C" })

--------------------------------------------------------------------------------
-- The board: two lists stacked in a column, Commands beside them
--------------------------------------------------------------------------------

local api = vim.api
local widgets = require("tuna.widgets")
vim.o.columns, vim.o.lines = 140, 40

local function press(keys)
    api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

---The board's lists by title, with where they were drawn.
local function board()
    local out = {}
    for _, w in ipairs(api.nvim_list_wins()) do
        local c = api.nvim_win_get_config(w)
        if c.relative ~= "" and type(c.title) == "table" then
            local name = vim.trim(c.title[1][1])
            out[name] = { win = w, row = c.row, col = c.col, width = c.width, height = c.height }
        end
    end
    return out
end

local function format(l)
    return function(width)
        local x = menu.recent_layout(lists, width)[l]
        return x.rows, x.highlights
    end
end
widgets.panels({
    { title = "Contests", format = format(1), column = 1 },
    { title = "Problems", format = format(2), column = 1 },
    { title = "Commands", items = { "Run", "Submit" }, column = 2 },
}, "Tuna")
local b = board()
t.ok("three lists are drawn", b.Contests and b.Problems and b.Commands, vim.tbl_keys(b))
t.eq("stacked lists share a column", { b.Problems.col, b.Problems.width }, { b.Contests.col, b.Contests.width })
t.eq("the second sits under the first, borders touching", b.Problems.row, b.Contests.row + b.Contests.height + 2)
t.ok("the other column is beside them", b.Commands.col >= b.Contests.col + b.Contests.width + 2, { b.Commands, b.Contests })
t.eq("its top level with the column's", b.Commands.row, b.Contests.row)

local ns = api.nvim_get_namespaces()["tuna_panels"]
local function marks(win)
    return #api.nvim_buf_get_extmarks(api.nvim_win_get_buf(win), ns, 0, -1, {})
end
t.eq("each list colours its own statuses", { marks(b.Contests.win), marks(b.Problems.win) }, { 2, 2 })

t.eq("the board opens on the first list", api.nvim_get_current_win(), b.Contests.win)
press("<C-j>")
t.eq("down moves to the list below", api.nvim_get_current_win(), b.Problems.win)
press("<C-j>")
t.eq("and stops at the bottom of the column", api.nvim_get_current_win(), b.Problems.win)
press("<C-l>")
t.eq("right moves to the column beside", api.nvim_get_current_win(), b.Commands.win)
press("<C-h>")
t.eq("and left back to the list level with it", api.nvim_get_current_win(), b.Contests.win)

-- An editor too narrow for the board: the recent lists give way, the commands don't.
local commands_width = b.Commands.width
vim.o.columns = 60
widgets.panels(nil)
b = board()
local function lines(win)
    return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
end
t.eq("a narrow editor keeps the commands whole", b.Commands.width, commands_width)
t.ok("and the board inside it", b.Commands.col + b.Commands.width + 2 <= 60, { b.Commands, b.Contests })
local fitted = true
for _, name in ipairs({ "Contests", "Problems" }) do
    for _, l in ipairs(lines(b[name].win)) do
        fitted = fitted and api.nvim_strwidth(l) <= b[name].width
    end
end
t.ok("the recent lists are laid out again for the width they get", fitted, { lines(b.Contests.win), lines(b.Problems.win), b.Problems.width })
t.eq("keeping their statuses whole", lines(b.Problems.win)[3]:sub(-10), "3/4 PASSED")
t.eq("and their colours", marks(b.Problems.win), 2)
vim.o.columns = 140
press("<Esc>")

-- A list longer than the editor leaves room for.
vim.o.lines = 24
local many = {}
for i = 1, 40 do
    many[i] = "problem " .. i
end
widgets.panels({
    { title = "Contests", items = { "c1", "c2", "c3" }, column = 1 },
    { title = "Problems", items = many, column = 1 },
    { title = "Commands", items = { "Run" }, column = 2 },
}, "Tuna", nil, nil, nil, { "BANNER" })
b = board()
local band_row, band_h = require("tuna.utils").float_band()
t.eq("a short list keeps all its rows", b.Contests.height, 3)
t.ok("a long one gets the rows left over", b.Problems.height < 40 and b.Problems.height > 3, b.Problems.height)
t.ok("and the stack fits the editor", b.Problems.row + b.Problems.height + 2 <= band_row + band_h, { b.Problems, band_row, band_h })
api.nvim_set_current_win(b.Problems.win)
for _ = 1, 39 do
    press("j")
end
t.eq("walking it reaches the last row", api.nvim_win_get_cursor(b.Problems.win)[1], 40)
t.ok("scrolling it into view", vim.fn.line("w0", b.Problems.win) > 1, vim.fn.line("w0", b.Problems.win))

widgets.panels(nil)
local resized = board()
t.eq("a resize keeps the stack", resized.Problems.row, resized.Contests.row + resized.Contests.height + 2)
t.eq("and the selection", api.nvim_win_get_cursor(resized.Problems.win)[1], 40)
press("<Esc>")

--------------------------------------------------------------------------------
-- The menu itself: a free-standing banner over its lists
--------------------------------------------------------------------------------

---Whether a float's border draws nothing.
local function borderless(c)
    if c.border == nil or c.border == "none" then
        return true
    end
    for _, part in ipairs(type(c.border) == "table" and c.border or { c.border }) do
        if (type(part) == "table" and part[1] or part) ~= "" then
            return false
        end
    end
    return true
end

vim.o.columns, vim.o.lines = 140, 45
require("tuna.menu").open()
local titles, lists_top, banner = {}, math.huge, nil
for _, w in ipairs(api.nvim_list_wins()) do
    local c = api.nvim_win_get_config(w)
    if c.relative ~= "" then
        if type(c.title) == "table" then
            titles[#titles + 1] = vim.trim(c.title[1][1])
            lists_top = math.min(lists_top, c.row)
        else
            banner = { win = w, config = c }
        end
    end
end
table.sort(titles)
t.eq("the menu's lists, the commands being the catch of the day", titles, { "Catch of the day", "Contests", "Problems" })
t.ok("the banner is drawn", banner ~= nil)
if banner then
    t.ok("with no border around it", borderless(banner.config), banner.config.border)
    t.has("on the editor's own background", vim.wo[banner.win].winhighlight, "NormalFloat:Normal")
    t.eq("a blank row above the lists", lists_top, banner.config.row + banner.config.height + 1)
end
press("<Esc>")

vim.fn.delete(contest, "rf")
vim.fn.delete(flat, "rf")
t.report()
