-- tests/navigate.lua
--
-- `:Tuna next` / `:Tuna prev`: the sibling problem opened, and Neovim's directory brought
-- along only when it was the problem left, or a folder inside it, however that folder's path
-- is spelt; from the contest's folder it stays, and `cd_command = false` keeps it anywhere. From
-- a runner UI pane the problem opens in the window under the board, which takes the `lcd`. A
-- contest tuna knows is stepped in its problems' order, plain files in one folder as well.

local t = dofile("tests/harness.lua")
require("tuna").setup({})
local navigate = require("tuna.workspace.navigate")

local real = vim.uv.fs_realpath
local contest = real(t.tempdir())
for _, name in ipairs({ "A", "B" }) do
    vim.fn.mkdir(contest .. "/" .. name .. "/tests", "p")
    t.write(contest .. "/" .. name, "main.cpp", "int main() {}\n")
end
local a, b = contest .. "/A", contest .. "/B"
local function at(dir, step)
    vim.cmd("silent cd " .. vim.fn.fnameescape(dir))
    vim.cmd.edit(vim.fn.fnameescape((step > 0 and a or b) .. "/main.cpp"))
    navigate.step(step)
    return { vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h:t"), real(vim.fn.getcwd()) }
end
local quiet = vim.notify
vim.notify = function() end

t.eq("in the problem's folder, next opens the next problem and moves there", at(a, 1), { "B", b })
t.eq("and prev the previous one", at(b, -1), { "A", a })
t.eq("from a folder inside the problem too", at(a .. "/tests", 1), { "B", b })
-- Neovim names a buffer it opens by its real path, so a link is tried on the comparison
-- itself: a path through one is still the folder the directory is in.
local link = vim.fn.tempname()
vim.uv.fs_symlink(contest, link)
vim.cmd("silent cd " .. vim.fn.fnameescape(a))
t.eq("however its path is spelt", navigate._test.working_in(link .. "/A"), true)
t.eq("from the contest's folder the directory stays", at(contest, 1), { "B", contest })

-- A contest of plain files, as a download writes one by default, steps between its files, not to
-- the folders beside its own, and Neovim's directory, the one folder they share, stays.
local recent = require("tuna.workspace.recent")
local files = real(t.tempdir())
vim.fn.mkdir(files .. "/Notes", "p")
local round = files .. "/Round"
vim.fn.mkdir(round, "p")
for _, name in ipairs({ "A", "B", "C" }) do
    t.write(round, name .. ".cpp", "int main() {}\n")
end
recent.record_contest(round, "Round")
vim.cmd("silent cd " .. vim.fn.fnameescape(round))
local said = {}
vim.notify = function(msg)
    said[#said + 1] = msg
end
local function from(name, offset)
    vim.cmd.edit(vim.fn.fnameescape(round .. "/" .. name .. ".cpp"))
    navigate.step(offset)
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") .. " " .. said[#said]
end
t.eq("a contest of files steps between them, and says where it is at its end", {
    from("B", 1),
    from("B", -1),
    from("C", 1),
    real(vim.fn.getcwd()),
}, { "C.cpp Tuna: problem 3/3: C", "A.cpp Tuna: problem 1/3: A", "C.cpp Tuna: problem 3/3 is the last one.", round })
require("tuna").setup({ cd_command = "lcd" })
from("A", 1)
t.eq("and stepping within its folder leaves the window without a directory of its own", vim.fn.haslocaldir(), 0)
require("tuna").setup({})
-- One tuna does not remember is told apart by its sidecar, which names each file's problem.
local forgotten = real(t.tempdir())
for _, name in ipairs({ "A", "B" }) do
    t.write(forgotten, name .. ".cpp", "int main() {}\n")
    require("tuna.problem.submit").write_task_store(forgotten .. "/" .. name .. ".cpp", {
        url = "https://codeforces.com/contest/9/problem/" .. name,
        name = name,
        group = "Codeforces - Round 9",
    }, require("tuna.config").current_setup)
end
vim.cmd.edit(vim.fn.fnameescape(forgotten .. "/A.cpp"))
navigate.step(1)
t.eq("and so does one tuna does not remember, by what its sidecar says of each file", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "B.cpp")
vim.notify = function() end
-- A contest of problem folders tuna knows goes in the same order as one it does not.
recent.record_contest(contest, "Folders")
t.eq("a known contest of folders steps between them as before", at(a, 1), { "B", b })

-- From a runner UI pane (stood in for by a split the board's step out closes), the file opens in
-- the window under it, and an `lcd` lands there rather than on the pane put away.
require("tuna").setup({ cd_command = "lcd" })
vim.cmd("silent cd " .. vim.fn.fnameescape(a))
vim.cmd.edit(vim.fn.fnameescape(a .. "/main.cpp"))
local under = vim.api.nvim_get_current_win()
vim.cmd("split")
package.loaded["tuna.runner_ui"] = { step_out = function() vim.cmd("close") end }
navigate.step(1)
package.loaded["tuna.runner_ui"] = nil
t.eq("from a pane, the window under it opens the problem and takes the lcd", {
    vim.api.nvim_get_current_win() == under,
    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h:t"),
    real(vim.fn.getcwd()),
}, { true, "B", b })
vim.cmd("silent cd " .. vim.fn.fnameescape(contest))

require("tuna").setup({ cd_command = false })
t.eq("and with cd_command = false it stays anywhere", at(a, 1), { "B", a })

-- `:Tuna next scaffold` goes round the problem's own sources, solutions and helpers, in name
-- order and wrapping around. A header is none of them, and from one the step starts where it
-- would stand in that order.
for _, name in ipairs({ "gen.cpp", "brute.cpp", "d.h" }) do
    t.write(a, name, "")
end
local function step(path, offset)
    vim.cmd.edit(vim.fn.fnameescape(path))
    navigate.step_scaffold(offset)
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
end
t.eq("next scaffold goes round the problem's sources in name order, wrapping around", {
    step(a .. "/brute.cpp", 1),
    step(a .. "/gen.cpp", 1),
    step(a .. "/main.cpp", 1),
}, { "gen.cpp", "main.cpp", "brute.cpp" })
t.eq("and prev the other way", step(a .. "/brute.cpp", -1), "main.cpp")
t.eq("a header is passed over, and stepped from where it sorts", { step(a .. "/d.h", 1), step(a .. "/d.h", -1) }, { "gen.cpp", "brute.cpp" })
t.eq("a problem with one source stays on it", step(b .. "/main.cpp", 1), "main.cpp")

-- The commands: each completes the words it takes, and bare `next` steps between problems,
-- the move made most often.
local commands = require("tuna.commands")
t.eq("next, prev and go complete what they go to", {
    commands.complete("", "Tuna next ", 10),
    commands.complete("", "Tuna prev ", 10),
    commands.complete("", "Tuna go ", 8),
}, { { "problem", "scaffold" }, { "problem", "scaffold" }, { "contest", "problem" } })
local function run(...)
    vim.cmd.edit(vim.fn.fnameescape(a .. "/main.cpp"))
    commands.execute({ ... })
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h:t") .. "/" .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
end
t.eq("bare next is the next problem, and each word goes where it says", {
    run("next"),
    run("next", "problem"),
    run("prev", "scaffold"),
}, { "B/main.cpp", "B/main.cpp", "A/gen.cpp" })

-- A solution tuna opens is drawn with the cursor already under `solve(`, not moved there a tick
-- after the file shows.
t.write(b, "sol.cpp", "#include <bits/stdc++.h>\n\nvoid solve() {\n    int n;\n}\n")
vim.cmd.edit(vim.fn.fnameescape(b .. "/sol.cpp"))
require("tuna.utils").place_cursor(require("tuna.config").get_buffer_config(0))
t.eq("the cursor is placed before the file is drawn", vim.api.nvim_win_get_cursor(0)[1], 4)

vim.notify = quiet
t.report()
