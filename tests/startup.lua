-- tests/startup.lua
--
-- What tuna costs a session that never uses it, and that it works without `setup()`:
-- `plugin/tuna.lua` (sourced by `tests/run.sh`) loads only the module holding the
-- highlight groups, entering a file loads only what deciding whether it is a problem
-- takes, reading one loads `submit` only when a sidecar beside it may hold a verdict
-- (which is then restored), `:Tuna` works on the defaults, and `setup()` loads only the
-- configuration and keymaps.

local t = dofile("tests/harness.lua")

local function loaded()
    local mods = {}
    for name in pairs(package.loaded) do
        if name == "tuna" or name:match("^tuna%.") then
            mods[#mods + 1] = name
        end
    end
    table.sort(mods)
    return mods
end

t.eq("at startup only the module holding the highlight groups is loaded", loaded(), { "tuna" })
t.eq(":Tuna exists without setup()", vim.fn.exists(":Tuna"), 2)
t.ok("and so do the highlight groups", next(vim.api.nvim_get_hl(0, { name = "TunaCorrect" })) ~= nil)

local TRACKING = { "tuna", "tuna.config", "tuna.recent", "tuna.utils" }

-- The first file of a session is read before anything has loaded `config`.
local solved = t.tempdir()
t.write(solved, "main.cpp", "int main() {}\n")
t.write(solved, ".tuna.json", vim.json.encode({
    submit = {
        ["main.cpp"] = { state = "accepted", text = "Accepted", hash = vim.fn.sha256("int main() {}\n") },
    },
}))
vim.cmd.edit(vim.fn.fnameescape(solved .. "/main.cpp"))
local submit = package.loaded["tuna.submit"]
t.ok("the first file read, with a sidecar beside it, has its verdict looked up", submit ~= nil)
local restored = submit and submit.state[vim.fs.normalize(solved .. "/main.cpp")]
t.eq("and restored, without setup()", restored and restored.state, "accepted")

for _, name in ipairs({ "tuna.submit", "tuna.sidecar", "tuna.tools", "tuna.testcases" }) do
    package.loaded[name] = nil
end
local plain = t.tempdir()
t.write(plain, "notes.txt", "nothing to do with tuna\n")
vim.cmd.edit(vim.fn.fnameescape(plain .. "/notes.txt"))
t.eq("entering any other file loads only what deciding whether it is a problem takes", loaded(), TRACKING)

require("tuna").setup({ keymaps = { preset = "<leader>t" } })
t.eq("setup() loads only the keymaps on top of that", loaded(), { "tuna", "tuna.config", "tuna.keymaps", "tuna.recent", "tuna.utils" })

t.has(":Tuna completes its subcommands", table.concat(vim.fn.getcompletion("Tuna ", "cmdline"), " "), "run")

t.report()
