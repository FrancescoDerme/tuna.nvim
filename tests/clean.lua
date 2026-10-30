-- tests/clean.lua
--
-- Which template a file on disk was written from, the question `:Tuna clean` has to answer
-- before it can call a file untouched: every template its role's configured paths can match,
-- a modifier only a problem fills (`$(JUDGE)`) matching any text, and the best match decides,
-- since nothing records which one a file came from.

local t = dofile("tests/harness.lua")
local clean = require("tuna.workspace.clean")._test
local config = require("tuna.config")

local dir = t.tempdir()
local tmpl = dir .. "/templates"
vim.fn.mkdir(tmpl, "p")
t.write(tmpl, "codeforces.cpp", "// codeforces\nint main(){ cf(); }\n")
t.write(tmpl, "default.cpp", "// default\nint main(){ plain(); }\n")

---A problem directory holding `content` as `sol.cpp`.
local function problem(name, content)
    local pdir = dir .. "/" .. name
    vim.fn.mkdir(pdir, "p")
    t.write(pdir, "sol.cpp", content)
    return pdir .. "/sol.cpp"
end

local FALLBACK = { tmpl .. "/$(JUDGE).cpp", tmpl .. "/default.cpp" }
local function cfg_with(solution)
    require("tuna").setup({ scaffold = { templates = { solution = solution } } })
    return config.get_buffer_config(vim.api.nvim_get_current_buf())
end

local function reason(file, cfg, threshold)
    return (clean.classify(file, "cpp", "sol", {}, cfg, threshold or 1.0, {}))
end

--------------------------------------------------------------------------------
-- Every template a path can match, and the best match
--------------------------------------------------------------------------------

local cfg = cfg_with(FALLBACK)
local cf = problem("cf", "// codeforces\nint main(){ cf(); }\n")
t.has("a file still holding a judge's template is unused", reason(cf, cfg), "100% match to solution template")
t.eq("every judge's template is compared, and the general one", #clean.templates_of(cf, "cpp", "solution", cfg, {}), 2)
local fell_back = problem("fb", "// default\nint main(){ plain(); }\n")
t.has("the one it actually matches decides", reason(fell_back, cfg), "100% match")
local edited = problem("edited", "// codeforces\nint main(){ cf(); solve(); }\n// more\n")
t.eq("an edited file is not offered", reason(edited, cfg), nil)
-- A template is never offered, not even for matching another one closely.
t.write(tmpl, "near.cpp", "// default\nint main(){ plain(); }\n")
cfg = cfg_with({ tmpl .. "/$(JUDGE).cpp", tmpl .. "/near.cpp" })
t.eq("a template is never offered, however close to another it is", reason(tmpl .. "/near.cpp", cfg, 0.5), nil)
t.write(tmpl, "empty.cpp", "")
t.eq("not even an empty one", reason(tmpl .. "/empty.cpp", cfg), nil)
t.has("while a file of the same text elsewhere is", reason(fell_back, cfg), "100% match")

-- With nothing configured, a solution comes from tuna's own starter, header filled in.
cfg = cfg_with(nil)
local scaffold = require("tuna.workspace.scaffold")
local starter = dir .. "/starter/sol.cpp"
local task = { name = "A. Example", group = "Codeforces - Round 1", url = "https://codeforces.com/contest/1/problem/A" }
vim.fn.mkdir(dir .. "/starter", "p")
local from = scaffold.template("solution", "cpp", cfg, starter, task)
t.write(dir .. "/starter", "sol.cpp", scaffold.render(from, "solution", "cpp", cfg, starter, task))
t.has("an untouched starter is unused", reason(starter, cfg), "100% match to solution template")

-- A role that starts empty has no template, so only an empty file is unused.
cfg = cfg_with(false)
t.eq("a role configured false has no template to match", reason(cf, cfg), nil)
local empty = problem("empty", "\n")
t.eq("so only an empty file is unused", reason(empty, cfg), "empty file")

vim.fn.delete(dir, "rf")
require("tuna").setup({})

--------------------------------------------------------------------------------
-- Stepping through the confirmations
--------------------------------------------------------------------------------

-- Each prompt starts on the answer last given, so a run of files (or directories) that
-- all get the same answer costs one key each.
do
    local widgets = require("tuna.ui.widgets")
    local real_menu = widgets.menu
    local rows, answers = {}, {}
    widgets.menu = function(_, _, on_choice, _, _, _, _, row)
        rows[#rows + 1] = row or 1
        on_choice(answers[#rows])
    end

    local fdir = t.tempdir()
    local files = {}
    for _, name in ipairs({ "a.cpp", "b.cpp", "c.cpp" }) do
        t.write(fdir, name, "")
        files[#files + 1] = { path = fdir .. "/" .. name, rel = name, reason = "empty file", sim = 1 }
    end
    answers = { 2, 1, 2 } -- Keep, Delete, Keep
    clean.confirm_each(files, 1, nil, { deleted = 0, builds = 0, dirs = 0, emptied = {} }, { width = 40 }, function() end)
    t.eq("each file prompt starts on the answer to the one before", rows, { 1, 2, 1 })
    t.eq("while doing what each answer says", vim.uv.fs_stat(fdir .. "/b.cpp"), nil)

    rows, answers = {}, { 2, 2 } -- Keep, Keep
    local d1, d2 = t.tempdir(), t.tempdir()
    clean.confirm_dirs({ { path = d1, rel = "d1", files = 0 }, { path = d2, rel = "d2", files = 0 } }, 1, nil, { deleted = 0, dirs = 0 }, { width = 40 }, function() end)
    t.eq("and so does each directory prompt", rows, { 1, 2 })

    widgets.menu = real_menu
    vim.fn.delete(fdir, "rf")
    vim.fn.delete(d1, "rf")
    vim.fn.delete(d2, "rf")
end

-- A pinned problem comes after the rest, says so, and its prompt starts on Keep whatever was
-- answered before, since it was put aside on purpose; deleting it all the same unpins it.
do
    local widgets = require("tuna.ui.widgets")
    local recent = require("tuna.workspace.recent")
    local real_menu = widgets.menu
    local pdir = t.tempdir()
    t.write(pdir, "a.cpp", "")
    t.write(pdir, "b.cpp", "")
    local pinned = vim.fs.normalize(pdir .. "/a.cpp")
    recent.toggle_pin(pinned)
    local found = clean.scan(pdir, config.current_setup, 1, 1.0)
    t.eq("a scan marks the pinned file and offers it last", vim.tbl_map(function(f)
        return { f.rel, f.pinned }
    end, found), { { "b.cpp", false }, { "a.cpp", true } })

    local titles, rows = {}, {}
    widgets.menu = function(_, title, on_choice, _, _, _, _, row)
        titles[#titles + 1], rows[#rows + 1] = title, row or 1
        on_choice(1) -- Delete
    end
    clean.confirm_each(found, 1, nil, { deleted = 0, builds = 0, dirs = 0, emptied = {} }, { width = 40 }, function() end)
    widgets.menu = real_menu
    t.eq("its prompt says it is pinned", titles[2], "[2/2] pinned, empty file")
    t.eq("and starts on Keep, though the one before was deleted", rows, { 1, 2 })
    local left = vim.tbl_filter(function(p)
        return p.file == pinned
    end, recent.state.pinned or {})
    t.eq("deleting it unpins it", #left, 0)
    vim.fn.delete(pdir, "rf")
end

-- A build whose source is gone is offered, first: a compiled program shaped like a build output,
-- hidden or not, with no source of its name beside it. A program with its source, and a file
-- shaped like a build that is no program, are not.
do
    local widgets = require("tuna.ui.widgets")
    local real_menu = widgets.menu
    local pdir = t.tempdir()
    local elf = "\127ELF\2\1\1\0"
    t.write(pdir, "main.cpp", "int main() { return 0; }\n")
    t.write(pdir, ".main", elf)
    t.write(pdir, ".main2", elf)
    t.write(pdir, "old.exe", "MZ\144\0")
    t.write(pdir, ".clangd", "CompileFlags:\n")
    t.write(pdir, "notes", "to do\n")
    t.write(pdir, "input0.txt", "1\n")
    t.write(pdir, ".tuna.json", "{}")
    t.write(pdir, "empty.cpp", "")
    local found = clean.scan(pdir, config.current_setup, 1, 1.0)
    t.eq("a scan offers the builds whose source is gone, ahead of the rest", vim.tbl_map(function(f)
        return { f.rel, f.reason }
    end, found), {
        { ".main2", "build of main2, whose source is gone" },
        { "old.exe", "build of old, whose source is gone" },
        { "empty.cpp", "empty file" },
    })

    local previews, selectable, stats = {}, nil, { deleted = 0, builds = 0, dirs = 0, emptied = {} }
    widgets.menu = function(_, _, on_choice, _, _, preview)
        previews[#previews + 1] = preview.lines[1]
        selectable = preview.selectable
        on_choice(1) -- Delete
    end
    clean.confirm_each({ found[1] }, 1, nil, stats, { width = 40 }, function() end)
    widgets.menu = real_menu
    t.has("its preview says what it is, having no text to show", previews[1], "A compiled program")
    t.eq("and offers nothing to select", selectable, false)
    t.eq("deleted, it counts as a build, its directory emptied", {
        vim.fn.filereadable(pdir .. "/.main2"),
        stats.builds,
        stats.deleted,
        stats.emptied[vim.fs.normalize(pdir)],
    }, { 0, 1, 0, true })
    vim.fn.delete(pdir, "rf")
end

-- A source deleted takes its builds with it, hidden or not and macOS's bundle included, and
-- nothing else of its name.
do
    local widgets = require("tuna.ui.widgets")
    local real_menu = widgets.menu
    local pdir = t.tempdir()
    local elf = "\127ELF\2\1\1\0"
    t.write(pdir, "main.cpp", "")
    t.write(pdir, ".main", elf)
    t.write(pdir, "main.exe", "MZ\144\0")
    vim.fn.mkdir(pdir .. "/main.dSYM/Contents", "p")
    t.write(pdir, "main.out", "42\n")
    t.write(pdir, "main2", elf)
    vim.fn.mkdir(pdir .. "/main", "p")
    local stats = { deleted = 0, builds = 0, dirs = 0, emptied = {} }
    widgets.menu = function(_, _, on_choice)
        on_choice(1) -- Delete
    end
    clean.confirm_each({ { path = pdir .. "/main.cpp", rel = "main.cpp", reason = "empty file", sim = 1 } }, 1, nil, stats, { width = 40 }, function() end)
    widgets.menu = real_menu
    local left = {}
    for name in vim.fs.dir(pdir) do
        left[#left + 1] = name
    end
    table.sort(left)
    t.eq("deleting a source deletes its builds", left, { "main", "main.out", "main2" })
    t.eq("each counted as a build, the bundle with its program", { stats.deleted, stats.builds }, { 1, 2 })
    vim.fn.delete(pdir, "rf")
end

-- A folder holding nothing but testcases is offered when no solution is left to read them,
-- and kept while one is: in its own `testcases_directory`, a library's shared one named by its
-- `.tuna.lua`, and the directory backend's folders.
do
    local widgets = require("tuna.ui.widgets")
    local real_menu = widgets.menu
    local root = t.tempdir()
    for _, sub in ipairs({ "A/tests", "B", "C/tests/1", "lib/shared" }) do
        vim.fn.mkdir(root .. "/" .. sub, "p")
    end
    t.write(root .. "/A", "main.cpp", "int main() {}\n")
    t.write(root .. "/A", ".tuna.lua", 'return { testcases_directory = "tests" }\n')
    t.write(root .. "/A/tests", "main_input0.txt", "1\n")
    t.write(root .. "/B", "main_input0.txt", "1\n")
    t.write(root .. "/B", ".tuna.json", "{}")
    t.write(root .. "/C", "main.cpp", "int main() {}\n")
    t.write(root .. "/C/tests/1", "input.txt", "1\n")
    t.write(root .. "/lib", "dsu.cpp", "struct DSU {};\n")
    t.write(root .. "/lib", ".tuna.lua", ("return { testcases_directory = %q }\n"):format(root .. "/lib/shared"))
    t.write(root .. "/lib/shared", "dsu_input0.txt", "1\n")
    local offered = {}
    widgets.menu = function(_, _, on_choice, _, _, preview)
        offered[#offered + 1] = preview.title
        on_choice(2) -- Keep
    end
    clean.prune_dirs(root, config.current_setup, nil, nil, { deleted = 0, builds = 0, dirs = 0, emptied = {} }, math.huge, function() end)
    widgets.menu = real_menu
    t.eq("only the folder whose solution is gone is offered", offered, { "B/" })
    vim.fn.delete(root, "rf")
end

--------------------------------------------------------------------------------
-- What a scan walks, and how paths are read
--------------------------------------------------------------------------------

-- A directory `clean.skip_directories` names, and every dot-directory, is left alone at every
-- depth, not only at the top of the scan: an empty source file inside one is never offered.
do
    config.setup({ clean = { skip_directories = { "node_modules" } } })
    local root = t.tempdir()
    for _, sub in ipairs({ "contest/A", "contest/A/.git", "contest/node_modules", "node_modules" }) do
        vim.fn.mkdir(root .. "/" .. sub, "p")
    end
    t.write(root .. "/contest/A", "main.cpp", "")
    t.write(root .. "/contest/A/.git", "hook.cpp", "")
    t.write(root .. "/contest/node_modules", "dep.cpp", "")
    t.write(root .. "/node_modules", "top.cpp", "")
    local found = clean.scan(root, config.current_setup, math.huge, 1.0)
    t.eq("a scan offers what is outside skipped directories, at every depth", vim.tbl_map(function(f)
        return f.rel
    end, found), { "contest/A/main.cpp" })
    config.setup({})
end

-- A path typed into the form, or configured, reads `~` as the home directory.
do
    local home = vim.uv.os_homedir()
    t.eq("a configured root reads ~ as home", clean.base_dir_of("~/cp/problems/$(JUDGE)/x.cpp"), home .. "/cp/problems")
    t.eq("as it reads $(HOME)", clean.base_dir_of("$(HOME)/cp/problems/$(JUDGE)/x.cpp"), home .. "/cp/problems")
    local fake = t.tempdir()
    vim.fn.mkdir(fake .. "/cp", "p")
    local real = vim.uv.os_homedir
    vim.uv.os_homedir = function()
        return fake
    end
    t.eq("a typed directory reads ~ as home too", clean.validate_dir("~/cp"), fake .. "/cp")
    vim.uv.os_homedir = real
end

t.report()
