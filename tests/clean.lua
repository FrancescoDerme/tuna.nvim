-- tests/clean.lua
--
-- Which template a file on disk was written from, the question `:Tuna clean` has to answer
-- before it can call a file untouched: every template its role's configured paths can match,
-- a modifier only a problem fills (`$(JUDGE)`) matching any text, and the best match decides,
-- since nothing records which one a file came from.

local t = dofile("tests/harness.lua")
local clean = require("tuna.clean")._test
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
t.eq(
    "a template is never compared with itself",
    #clean.templates_of(tmpl .. "/default.cpp", "cpp", "solution", cfg, {}),
    1
)

-- With nothing configured, a solution comes from tuna's own starter, header filled in.
cfg = cfg_with(nil)
local scaffold = require("tuna.scaffold")
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
-- Build artifacts left beside a removed solution
--------------------------------------------------------------------------------

-- The directory pass offers a directory holding nothing but testcases and a sidecar.
-- A compiled binary is neither, so `main` beside a removed `main.cpp` kept the whole
-- problem directory alive and stranded its testcases there — the litter competitest is
-- asked to delete after every run, surfacing here instead as a directory never offered.
--
-- The rule is deliberately not "does this look like a binary": it matches only the
-- leftovers of a solution *this run removed*, so nothing in an untouched directory can
-- be caught by it.
local art = { artifacts = { ["/p"] = { main = true } } }
t.ok("the bare stem of a removed source is an artifact", clean.is_artifact("/p", "main", art))
t.ok("so is its .exe", clean.is_artifact("/p", "main.exe", art))
t.ok("and its .o", clean.is_artifact("/p", "main.o", art))
t.ok("and a Java .class", clean.is_artifact("/p", "main.class", art))
-- macOS leaves a *directory* beside a debug build; it goes with the rest of them.
t.ok("and macOS's .dSYM bundle", clean.is_artifact("/p", "main.dSYM", art))
t.ok("a build written hidden is one too", clean.is_artifact("/p", ".main", art))
t.ok("and so is a hidden one's .o", clean.is_artifact("/p", ".main.o", art))
t.ok("but not a hidden file no solution was removed for", not clean.is_artifact("/p", ".helper", art))

-- Nothing else, in either direction.
t.ok("a source file is not an artifact of itself", not clean.is_artifact("/p", "main.cpp", art))
t.ok("an unknown extension is not one", not clean.is_artifact("/p", "main.md", art))
t.ok("nor is a stem no solution was removed for", not clean.is_artifact("/p", "helper", art))
t.ok("nor anything in another directory", not clean.is_artifact("/other", "main", art))
t.ok("and a run that removed nothing has no artifacts at all", not clean.is_artifact("/p", "main", { artifacts = {} }))

--------------------------------------------------------------------------------
-- Stepping through the confirmations
--------------------------------------------------------------------------------

-- Each prompt starts on the answer last given, so a run of files (or directories) that
-- all get the same answer costs one key each.
do
    local widgets = require("tuna.widgets")
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
    clean.confirm_each(files, 1, nil, { deleted = 0, dirs = 0, emptied = {}, artifacts = {} }, { width = 40 }, function() end)
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

-- A pinned problem says so, and its prompt starts on Keep whatever was answered before,
-- since it was put aside on purpose; deleting it all the same unpins it.
do
    local widgets = require("tuna.widgets")
    local recent = require("tuna.recent")
    local real_menu = widgets.menu
    local pdir = t.tempdir()
    t.write(pdir, "a.cpp", "")
    t.write(pdir, "b.cpp", "")
    local pinned = vim.fs.normalize(pdir .. "/b.cpp")
    recent.toggle_pin(pinned)
    local found = clean.scan(pdir, config.current_setup, 1, 1.0)
    table.sort(found, function(x, y)
        return x.rel < y.rel
    end)
    t.eq("a scan marks the pinned file", vim.tbl_map(function(f)
        return f.pinned
    end, found), { false, true })

    local titles, rows = {}, {}
    widgets.menu = function(_, title, on_choice, _, _, _, _, row)
        titles[#titles + 1], rows[#rows + 1] = title, row or 1
        on_choice(1) -- Delete
    end
    clean.confirm_each(found, 1, nil, { deleted = 0, dirs = 0, emptied = {}, artifacts = {} }, { width = 40 }, function() end)
    widgets.menu = real_menu
    t.eq("its prompt says it is pinned", titles[2], "[2/2] pinned, empty file")
    t.eq("and starts on Keep, though the one before was deleted", rows, { 1, 2 })
    local left = vim.tbl_filter(function(p)
        return p.file == pinned
    end, recent.state.pinned or {})
    t.eq("deleting it unpins it", #left, 0)
    vim.fn.delete(pdir, "rf")
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
