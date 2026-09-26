-- tests/scaffold.lua
--
-- `:Tuna scaffold`: templates are plain files named `<role>.<ext>`, looked up in the user's
-- `scaffold.directory` before the ones shipped with the plugin, each role and language on
-- its own; the file written is named after the role's first `tool_names`, so discovery finds
-- it; the language is the one asked for, else `scaffold.language`, else the solution's; and a
-- role with no template in that language offers the ones it has.

local t = dofile("tests/harness.lua")

local own = t.tempdir() -- the user's scaffold folder
local function setup(opts)
    require("tuna").setup(vim.tbl_deep_extend("force", { scaffold = { directory = own } }, opts or {}))
end
setup()

local scaffold = require("tuna.scaffold")
local tools = require("tuna.tools")
local widgets = require("tuna.widgets")

-- Every question is a menu: answer it from here, and remember what it asked.
local asked, answer
widgets.menu = function(items, title, on_choice)
    asked = { items = items, title = title }
    on_choice(answer)
end
local said = t.capture_notifications()

---A problem directory holding a C++ solution, open in its own buffer.
local function problem()
    local dir = t.tempdir()
    t.write(dir, "main.cpp", "int main() {}\n")
    vim.cmd("edit " .. dir .. "/main.cpp")
    vim.bo.filetype = "cpp"
    return dir, vim.api.nvim_get_current_buf()
end
local function read(path)
    local f = io.open(path)
    if not f then
        return nil
    end
    local s = f:read("*a")
    f:close()
    return s
end
local shipped = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/scaffolds"

--------------------------------------------------------------------------------
-- The shipped templates
--------------------------------------------------------------------------------

local _, buf = problem()
for _, role in ipairs(tools.ROLES) do
    t.eq("every role ships in C++ and Python: " .. role, scaffold.languages(role, buf), { "cpp", "py" })
    for _, ext in ipairs({ "cpp", "py" }) do
        t.ok(("and %s.%s is a template with something in it"):format(role, ext), (read(shipped .. "/" .. role .. "." .. ext) or "") ~= "")
    end
end

--------------------------------------------------------------------------------
-- Names, and the file written
--------------------------------------------------------------------------------

local dir
dir, buf = problem()
scaffold.create("generator", buf)
t.eq("a scaffold is named after the role's first tool name", read(dir .. "/gen.cpp"), read(shipped .. "/generator.cpp"))
t.eq("and opened", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "gen.cpp")

setup({ tool_names = { generator = { "generator" } } })
dir, buf = problem()
scaffold.create("generator", buf)
t.ok("a name changed in tool_names is the name written", read(dir .. "/generator.cpp") ~= nil)
t.ok(
    "so discovery finds what was scaffolded",
    tools.helper("generator", dir .. "/main.cpp", require("tuna.config").get_buffer_config(buf)) ~= nil
)
setup()

said = t.capture_notifications()
dir, buf = problem()
scaffold.create("brute", buf)
t.has("the roles are named as everywhere else, bruteforce and not brute", said[1], "bruteforce")
t.eq("and nothing is written for one that is not a role", vim.fn.glob(dir .. "/brute.*"), "")

--------------------------------------------------------------------------------
-- The user's folder
--------------------------------------------------------------------------------

t.write(own, "generator.cpp", "// my generator\n")
dir, buf = problem()
scaffold.create("generator", buf)
t.eq("a template in the user's folder is used over the shipped one", read(dir .. "/gen.cpp"), "// my generator\n")
scaffold.create("generator", buf, "py")
t.eq("for its own language only: the others still come from the shipped ones", read(dir .. "/gen.py"), read(shipped .. "/generator.py"))

t.write(own, "generator.rs", "// a generator in rust\n")
t.eq("a file is all it takes to add a language", scaffold.languages("generator", buf), { "cpp", "py", "rs" })
scaffold.create("generator", buf, "rs")
t.eq("and scaffold in it", read(dir .. "/gen.rs"), "// a generator in rust\n")

--------------------------------------------------------------------------------
-- The language
--------------------------------------------------------------------------------

setup({ scaffold = { language = "py" } })
dir, buf = problem()
scaffold.create("checker", buf)
t.ok("scaffold.language writes every scaffold in it, whatever the solution is in", read(dir .. "/checker.py") ~= nil)
scaffold.create("interactor", buf, "cpp")
t.ok("while a language asked for by name comes first", read(dir .. "/interactor.cpp") ~= nil)
setup()

-- A language the role has no template in: the ones it does have are offered instead.
dir, buf = problem()
answer = 2
scaffold.create("bruteforce", buf, "java")
t.eq("a language with no template offers the ones there are", asked and asked.items, {
    "Write it in .cpp",
    "Write it in .py",
    "Stop",
})
t.eq("saying which was asked for", asked and asked.title, "No bruteforce template for .java")
t.eq("and writes the one picked", read(dir .. "/brute.py"), read(shipped .. "/bruteforce.py"))
answer, asked = 3, nil
scaffold.create("checker", buf, "java")
t.eq("stopping writes nothing", vim.fn.glob(dir .. "/checker.*"), "")

--------------------------------------------------------------------------------
-- A file already there
--------------------------------------------------------------------------------

dir, buf = problem()
t.write(dir, "gen.cpp", "// written by hand\n")
answer, asked = 3, nil
scaffold.create("generator", buf)
t.eq("an existing file is asked about", asked and asked.items, { "Open it", "Overwrite", "Stop" })
t.eq("and stopping leaves it as it was", read(dir .. "/gen.cpp"), "// written by hand\n")
answer = 2
scaffold.create("generator", buf)
t.eq("overwriting writes the template over it", read(dir .. "/gen.cpp"), "// my generator\n")

--------------------------------------------------------------------------------
-- What else reads the templates
--------------------------------------------------------------------------------

-- `clean` tells an untouched scaffold by the template it was written from, and says which.
local cfg = require("tuna.config").get_buffer_config(buf)
local roles = { gen = "generator" }
local reason = require("tuna.clean")._test.classify(dir .. "/gen.cpp", "cpp", "gen", roles, cfg, 0.9, {})
t.has("clean knows an untouched scaffold for what it is", reason, "match to generator scaffold")

-- Completion offers the roles, then the languages a role has a template in.
local complete = require("tuna.commands").complete
t.eq("completion offers the roles", complete("", "Tuna scaffold ", 14), { "bruteforce", "checker", "generator", "interactor" })
vim.cmd("edit " .. dir .. "/main.cpp")
t.eq("then the languages there are for one", complete("", "Tuna scaffold generator ", 24), { "cpp", "py", "rs" })

t.report()
