-- tests/library.lua
--
-- `:Tuna lib`: which files the library holds for a language (dotfiles and dot-directories
-- left out at every depth, `~` in `library.path` read as the home directory), the guarded
-- snippets inside a file, and a file with an unclosed guard warned about once per picker,
-- however often its preview is drawn.

local t = dofile("tests/harness.lua")
require("tuna").setup({})
local library = require("tuna.library")
local widgets = require("tuna.widgets")

local root = t.tempdir()
for _, sub in ipairs({ "graphs", "graphs/.cache", ".git" }) do
    vim.fn.mkdir(root .. "/" .. sub, "p")
end
t.write(root, "fenwick.cpp", "// TUNALIB: add start\nvoid add() {}\n// TUNALIB: add end\n")
t.write(root .. "/graphs", "dsu.cpp", "// TUNALIB: dsu start\nint p[10];\n")
t.write(root .. "/graphs", ".scratch.cpp", "")
t.write(root .. "/graphs/.cache", "old.cpp", "")
t.write(root .. "/.git", "hook.cpp", "")
t.write(root, "notes.py", "")

-- `library.path` with a leading `~`, read against a home directory of the test's own.
local real_home = vim.uv.os_homedir
vim.uv.os_homedir = function()
    return vim.fs.dirname(root)
end
local cfg = vim.tbl_deep_extend("force", require("tuna.config").current_setup, {
    library = { path = "~/" .. vim.fn.fnamemodify(root, ":t") },
})
local files = vim.tbl_map(function(f)
    return f.rel
end, library.files(cfg, "cpp"))
vim.uv.os_homedir = real_home
t.eq("the library is read from ~ and lists its files of the language, no dotfiles at any depth", files, {
    "fenwick.cpp",
    "graphs/dsu.cpp",
})

local snips = library.parse({ "x", "// TUNALIB: add start", "void add() {}", "// TUNALIB: add end" }, "TUNALIB")
t.eq("a guarded region is a snippet", { snips[1].name, snips[1].lines, snips[1].first }, { "add", { "void add() {}" }, 3 })
local _, warning = library.parse({ "// TUNALIB: dsu start", "int p[10];" }, "TUNALIB")
t.has("an unclosed guard is reported", warning, "unclosed 'dsu' guard")

-- The file picker previews the file under the cursor on every move: its unclosed guard is
-- said once all the same.
do
    require("tuna").setup({ library = { path = root } })
    t.write(root, "main.cpp", "")
    vim.cmd("edit " .. root .. "/main.cpp")
    local real_menu = widgets.menu
    widgets.menu = function(items, _, _, _, _, preview)
        for _ = 1, 3 do
            for i = 1, #items do
                preview.content(i)
            end
        end
    end
    local quiet = vim.notify
    local said = t.capture_notifications()
    library.browse()
    vim.notify, widgets.menu = quiet, real_menu
    t.eq("moving over a file with an unclosed guard warns once", #vim.tbl_filter(function(m)
        return m:find("unclosed") ~= nil
    end, said), 1)
end

t.report()
