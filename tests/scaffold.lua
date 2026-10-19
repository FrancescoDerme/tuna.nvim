-- tests/scaffold.lua
--
-- `:Tuna scaffold` and the templates every role is written from: `scaffold.templates` names
-- them by path, list or role, the first that exists winning over tuna's own starter, each
-- for the language its extension names; their text has what can be filled filled; a helper
-- is named after its role's first `tool_names`, so discovery finds it, and a solution after
-- the next free sibling; a helper's language is the one asked for, else `scaffold.language`,
-- else the solution's, and a role with no template in it offers the ones it has.

local t = dofile("tests/harness.lua")

local own = t.tempdir() -- the user's scaffold folder
local function setup(opts)
    require("tuna").setup(vim.tbl_deep_extend("force", { scaffold = { templates = own .. "/$(ROLE).$(FEXT)" } }, opts or {}))
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
for _, role in ipairs(tools.SCAFFOLDS) do
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

dir, buf = problem()
scaffold.create("brute", buf)
t.eq("a role's tool_names name it too", read(dir .. "/brute.cpp"), read(shipped .. "/bruteforce.cpp"))
setup({ tool_names = { generator = { "mkin" } } })
dir, buf = problem()
scaffold.create("mkin", buf)
t.ok("the configured ones included", read(dir .. "/mkin.cpp") ~= nil)
setup()

said = t.capture_notifications()
dir, buf = problem()
scaffold.create("bogus", buf)
t.has("a word that names no role is refused, naming the roles", said[1], "bruteforce")
t.eq("and nothing is written for it", vim.fn.glob(dir .. "/bogus.*"), "")

--------------------------------------------------------------------------------
-- The user's templates
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
-- Offered by a run that needs them
--------------------------------------------------------------------------------

do
    -- A run that needs helpers it does not have offers to write their starters, naming the files,
    -- and runs nothing: a starter is where a helper begins.
    said = t.capture_notifications()
    local dir, buf = problem()
    answer, asked = 1, nil
    require("tuna.stress").run(buf, 1)
    t.eq("stress with no helpers offers to write them", asked, {
        items = { "Create gen.cpp and brute.cpp", "Stop" },
        title = "Stress needs a generator and a bruteforce",
    })
    t.ok("creating writes both", read(dir .. "/gen.cpp") ~= nil and read(dir .. "/brute.cpp") ~= nil)
    t.eq("opens the first to be written", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "gen.cpp")
    t.eq("and lists the other", vim.fn.buflisted(dir .. "/brute.cpp"), 1)
    t.has("saying what to do next", said[#said], "created gen.cpp and brute.cpp, fill them in and run again.")
    t.eq("without running anything", require("tuna.stress").active[buf], nil)

    dir, buf = problem()
    answer = 2
    require("tuna.stress").run(buf, 1)
    t.eq("stopping writes nothing", vim.fn.glob(dir .. "/gen.*") .. vim.fn.glob(dir .. "/brute.*"), "")

    dir, buf = problem()
    answer, asked = 1, nil
    require("tuna.interactive").run(buf, { "interactor" })
    t.eq("the interactor source offers its interactor", asked and asked.items, { "Create interactor.cpp", "Stop" })
    t.eq("and opens it", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "interactor.cpp")

    -- A configured helper that is broken is not something a starter beside the solution fixes: the
    -- run says what is wrong with it, as before.
    setup({ stress = { generator = "nope.cpp" } })
    dir, buf = problem()
    answer, asked = 1, nil
    said = t.capture_notifications()
    require("tuna.stress").run(buf, 1)
    t.eq("a broken configured helper offers nothing", asked, nil)
    t.has("and says what is wrong with it", said[#said], "does not exist")
    setup()
end

--------------------------------------------------------------------------------
-- The shapes `scaffold.templates` takes
--------------------------------------------------------------------------------

do
    local tdir = t.tempdir()
    t.write(tdir, "template.cpp", "// mine\n")
    t.write(tdir, "template.codeforces.cpp", "// mine, for codeforces\n")
    local cfg = function()
        return require("tuna.config").current_setup
    end
    local function from(role, ext, task)
        return scaffold.template(role, ext, cfg(), tdir .. "/p/main." .. ext, task)
    end
    local cf = { name = "A", group = "Codeforces - Round 1", url = "https://codeforces.com/contest/1/problem/A" }

    require("tuna").setup({ scaffold = { templates = { solution = { tdir .. "/template.$(JUDGE).$(FEXT)", tdir .. "/template.$(FEXT)" } } } })
    t.eq("a role's list is tried in order", from("solution", "cpp", cf), tdir .. "/template.codeforces.cpp")
    t.eq("falling back past a template that is not there", from("solution", "cpp", { name = "A", group = "AtCoder - X", url = "" }), tdir .. "/template.cpp")
    t.eq("and past one naming a problem when none is known", from("solution", "cpp"), tdir .. "/template.cpp")
    t.eq("with none existing, tuna's own starter", from("solution", "py"), shipped .. "/solution.py")
    t.eq("as for a role not listed", from("checker", "cpp"), shipped .. "/checker.cpp")

    require("tuna").setup({ scaffold = { templates = { ["*"] = tdir .. "/$(ROLE).$(FEXT)", checker = false } } })
    t.write(tdir, "generator.cpp", "// my generator\n")
    t.eq('["*"] stands for every role not listed', from("generator", "cpp"), tdir .. "/generator.cpp")
    t.eq("and false starts a role empty", from("checker", "cpp"), nil)

    require("tuna").setup({ scaffold = { templates = tdir .. "/template.cpp" } })
    t.eq("a plain path is every role's", from("bruteforce", "cpp"), tdir .. "/template.cpp")
    t.eq("but only in the language its extension names", from("bruteforce", "py"), shipped .. "/bruteforce.py")

    vim.fn.mkdir(tdir .. "/a$b", "p")
    t.write(tdir .. "/a$b", "t.cpp", "// in a$b\n")
    require("tuna").setup({ scaffold = { templates = { solution = tdir .. "/a$()b/t.$(FEXT)" } } })
    t.eq("a path glob would read as a variable is matched as written", scaffold.templates("solution", cfg(), tdir .. "/p/main.cpp", "cpp"), {
        tdir .. "/a$b/t.cpp",
    })

    -- What a template's text becomes: the modifiers it can fill filled, any other `$` as written,
    -- and with no problem known the header lines naming one dropped.
    t.write(tdir, "filled.cpp", "// problem: $(PROBLEM)\n// at: $(URL)\n\n// $(ROLE) $(FNAME), $(date), $5, $(\n")
    local target = tdir .. "/p/main.cpp"
    t.eq(
        "a template's text is filled in where it can be",
        scaffold.render(tdir .. "/filled.cpp", "solution", "cpp", cfg(), target, cf),
        "// problem: A\n// at: https://codeforces.com/contest/1/problem/A\n\n// solution main.cpp, $(date), $5, $(\n"
    )
    t.eq(
        "with no problem known, the header naming one goes, with the blank lines under it",
        scaffold.render(tdir .. "/filled.cpp", "solution", "cpp", cfg(), target),
        "// solution main.cpp, $(date), $5, $(\n"
    )
    t.write(tdir, "partial.cpp", "// $(FNAME)\n// $(PROBLEM)\n\nint main() {}\n")
    t.eq(
        "a header line it can fill stays",
        scaffold.render(tdir .. "/partial.cpp", "solution", "cpp", cfg(), target),
        "// main.cpp\n\nint main() {}\n"
    )
    vim.fn.delete(tdir, "rf")
    setup()
end

--------------------------------------------------------------------------------
-- A new solution
--------------------------------------------------------------------------------

do
    local prompted
    local real_input = widgets.input
    widgets.input = function(title, default, on_submit)
        prompted = { title = title, default = default }
        on_submit(default)
    end
    local dir, buf = problem()
    scaffold.create("solution", buf)
    t.eq("a new solution is offered the next free name", prompted, { title = "New solution", default = "main2.cpp" })
    t.eq("written from the solution's template, with no problem to fill in its header", read(dir .. "/main2.cpp"), table.concat(vim.list_slice(vim.fn.readfile(shipped .. "/solution.cpp"), 3), "\n") .. "\n")
    t.eq("and opened", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "main2.cpp")
    scaffold.create("solution", vim.api.nvim_get_current_buf())
    t.eq("from a numbered one, the next number", prompted.default, "main3.cpp")

    t.write(dir, ".tuna.json", vim.json.encode({ name = "B. Second", group = "Codeforces - Round 9", url = "https://codeforces.com/contest/9/problem/B" }))
    scaffold.create("solution", buf)
    t.eq("a downloaded problem's own details fill the header", vim.list_slice(vim.fn.readfile(dir .. "/main4.cpp"), 1, 2), {
        "// contest: codeforces 9",
        "// problem: B. Second",
    })

    local empty = t.tempdir()
    vim.cmd("enew")
    vim.cmd.cd(empty)
    scaffold.create("solution", vim.api.nvim_get_current_buf())
    t.eq("with no solution to go by, the first of tool_names.solution", prompted.default, "main.cpp")
    vim.cmd.cd("-")

    t.write(dir, "notes.txt", "")
    vim.cmd("edit " .. dir .. "/notes.txt")
    scaffold.create("solution", vim.api.nvim_get_current_buf())
    t.eq("from a file that is no solution, the folder's solution is gone by", prompted.default, "main5.cpp")
    vim.cmd("buffer " .. buf)

    prompted = nil
    scaffold.create("sol", buf)
    t.eq("a solution's tool_names name it too", prompted and prompted.title, "New solution")

    widgets.input = function(_, _, on_submit)
        on_submit("  ")
    end
    dir, buf = problem()
    scaffold.create("solution", buf)
    t.eq("an empty name writes nothing", vim.fn.glob(dir .. "/*.cpp", false, true), { dir .. "/main.cpp" })
    widgets.input = real_input
end

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
t.eq(
    "completion offers the roles",
    complete("", "Tuna scaffold ", 14),
    { "bruteforce", "checker", "generator", "interactor", "solution" }
)
vim.cmd("edit " .. dir .. "/main.cpp")
t.eq("then the languages there are for one", complete("", "Tuna scaffold generator ", 24), { "cpp", "py", "rs" })
t.eq("named by its tool_names too", complete("", "Tuna scaffold gen ", 18), { "cpp", "py", "rs" })

t.report()
