-- tests/navigate.lua
--
-- `:Tuna next` / `:Tuna prev`: the sibling problem opened, and Neovim's directory brought
-- along only when it was the problem left, or a folder inside it, however that folder's path
-- is spelt; from the contest's folder it stays, and `cd_command = false` keeps it anywhere. From
-- a runner UI pane the problem opens in the window under the board, which takes the `lcd`.

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
-- Neovim names a buffer it opens by its real path, so a link is tried on the comparison
-- itself: a path through one is still the folder the directory is in.
local link = vim.fn.tempname()
vim.uv.fs_symlink(contest, link)
vim.cmd("silent cd " .. vim.fn.fnameescape(a))
t.eq("however its path is spelt", navigate._test.working_in(link .. "/A"), true)
t.eq("from the contest's folder the directory stays", at(contest, 1), { "B", contest })

-- From a runner UI pane (stood in for by a split the board's step out closes), the file opens in
-- the window under it, and an `lcd` lands there rather than on the pane put away.
require("tuna").setup({ cd_command = "lcd" })
vim.cmd("silent cd " .. vim.fn.fnameescape(a))
vim.cmd.edit(vim.fn.fnameescape(a .. "/main.cpp"))
local under = vim.api.nvim_get_current_win()
vim.cmd("split")
package.loaded["tuna.runner_ui"] = { step_out = function() vim.cmd("close") end }
navigate.go(1)
package.loaded["tuna.runner_ui"] = nil
t.eq("from a pane, the window under it opens the problem and takes the lcd", {
    vim.api.nvim_get_current_win() == under,
    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h:t"),
    real(vim.fn.getcwd()),
}, { true, "B", b })
vim.cmd("silent cd " .. vim.fn.fnameescape(contest))

require("tuna").setup({ cd_command = false })
t.eq("and with cd_command = false it stays anywhere", at(a, 1), { "B", a })

vim.notify = quiet
t.report()
