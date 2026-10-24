-- tests/navigate.lua
--
-- `:Tuna next` / `:Tuna prev`: the sibling problem opened, and Neovim's directory brought
-- along only when it was the problem left, or a folder inside it, however that folder's path
-- is spelt; from the contest's folder it stays, and `cd_command = false` keeps it anywhere.

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
    navigate.go(step)
    return { vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h:t"), real(vim.fn.getcwd()) }
end
local quiet = vim.notify
vim.notify = function() end

t.eq("in the problem's folder, next opens the next problem and moves there", at(a, 1), { "B", b })
t.eq("and prev the previous one", at(b, -1), { "A", a })
t.eq("from a folder inside the problem too", at(a .. "/tests", 1), { "B", b })
-- Neovim names a buffer by its real path when it opens one, but a path that reached the
-- buffer otherwise, through a link, is still the folder the directory is in.
local link = vim.fn.tempname()
vim.uv.fs_symlink(contest, link)
vim.cmd("silent cd " .. vim.fn.fnameescape(a))
t.eq("however its path is spelt", navigate._test.working_in(link .. "/A"), true)
t.eq("from the contest's folder the directory stays", at(contest, 1), { "B", contest })

require("tuna").setup({ cd_command = false })
t.eq("and with cd_command = false it stays anywhere", at(a, 1), { "B", a })

vim.notify = quiet
t.report()
