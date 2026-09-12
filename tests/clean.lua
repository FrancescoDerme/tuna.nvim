-- tests/clean.lua
--
-- Which template a file on disk was written from — the question `:Tuna clean` has to
-- answer before it can call a file untouched, and the one that gets hard as soon as a
-- template path names the problem it is for (`~/cp/templates/$(JUDGE).cpp`).
--
-- Two rules:
--   * a task-dependent candidate is resolved from the **sidecar** beside the file,
--     which is where the download recorded the judge. Without that, a per-judge
--     template would make every untouched solution unrecognizable and clean would
--     quietly find nothing but empty files;
--   * with a fallback list more than one template can apply, and nothing records which
--     one a file came from, so the **best** match decides.

local t = dofile("tests/harness.lua")
local clean = require("tuna.clean")._test
local config = require("tuna.config")

local dir = t.tempdir()
local tmpl = dir .. "/templates"
vim.fn.mkdir(tmpl, "p")
t.write(tmpl, "codeforces.cpp", "// codeforces\nint main(){ cf(); }\n")
t.write(tmpl, "default.cpp", "// default\nint main(){ plain(); }\n")

---A problem directory holding `content`, with `group` in its sidecar when given.
local function problem(name, content, group)
    local pdir = dir .. "/" .. name
    vim.fn.mkdir(pdir, "p")
    t.write(pdir, "sol.cpp", content)
    if group then
        t.write(pdir, ".tuna.json", vim.json.encode({
            url = "https://codeforces.com/contest/2248/problem/A",
            name = "A. Example",
            group = group,
        }))
    end
    return pdir .. "/sol.cpp"
end

local FALLBACK = { tmpl .. "/$(JUDGE).cpp", tmpl .. "/default.cpp" }
local function cfg_with(template_file)
    require("tuna").setup({ template_file = template_file })
    return config.get_buffer_config(vim.api.nvim_get_current_buf())
end

local function reason(file, cfg, threshold)
    return (clean.classify(file, "cpp", "sol", {}, cfg, threshold or 1.0, {}))
end

--------------------------------------------------------------------------------
-- The judge comes from the sidecar
--------------------------------------------------------------------------------

local cf = problem("cf", "// codeforces\nint main(){ cf(); }\n", "Codeforces - Round 1112")
local cfg = cfg_with(FALLBACK)
t.has("a file still holding its judge's template is unused", reason(cf, cfg), "100% match")

-- The same file with no sidecar: nothing says which judge it came from, so the
-- per-judge candidate cannot be resolved. It must not be guessed at — and the general
-- fallback, which resolves without a task, is genuinely not what this file holds.
local orphan = problem("orphan", "// codeforces\nint main(){ cf(); }\n", nil)
t.eq("with no sidecar the judge template is not resolvable", reason(orphan, cfg), nil)
t.eq("and nothing was resolved for it at all", #clean.solution_templates(orphan, "cpp", cfg, {}), 1)

--------------------------------------------------------------------------------
-- With a fallback list, the best match decides
--------------------------------------------------------------------------------

-- Written from the *fallback*, in a problem whose judge has its own template. Both
-- candidates resolve, and only the comparison tells them apart.
local fell_back = problem("fb", "// default\nint main(){ plain(); }\n", "Codeforces - Round 1112")
t.eq("both candidates resolve", #clean.solution_templates(fell_back, "cpp", cfg, {}), 2)
t.has("the one it actually matches decides", reason(fell_back, cfg), "100% match")

-- A file that has been worked on matches neither.
local edited = problem("edited", "// codeforces\nint main(){ cf(); solve(); }\n// more\n", "Codeforces - Round 1112")
t.eq("an edited file is not offered", reason(edited, cfg), nil)

--------------------------------------------------------------------------------
-- The shapes `template_file` can take
--------------------------------------------------------------------------------

local u = require("tuna.utils")
t.eq("false configures nothing", u.template_candidates(false, "cpp"), {})
t.eq("a string is one candidate", u.template_candidates("a.cpp", "cpp"), { "a.cpp" })
t.eq("a list is the candidates, in order", u.template_candidates({ "a.cpp", "b.cpp" }, "cpp"), { "a.cpp", "b.cpp" })
t.eq("an ext map picks the extension", u.template_candidates({ cpp = "a.cpp", py = "a.py" }, "py"), { "a.py" })
t.eq("an unlisted extension has none", u.template_candidates({ cpp = "a.cpp" }, "rs"), {})
t.eq(
    "an ext map may hold a list of its own",
    u.template_candidates({ cpp = { "a.cpp", "b.cpp" } }, "cpp"),
    { "a.cpp", "b.cpp" }
)

-- A plain path is still just a path: the old single-template setup is untouched.
local plain = problem("plain", "// default\nint main(){ plain(); }\n", nil)
t.has("a single configured template still works", reason(plain, cfg_with(tmpl .. "/default.cpp")), "100% match")

vim.fn.delete(dir, "rf")

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

t.report()
