-- lua/tuna/clean.lua
--
-- `:Tuna clean` — remove files that were created but never used: solution files
-- and scaffolding (checker/gen/brute/interactor) that still hold nothing but the
-- template they were generated from. Because such files are *templated* they are
-- not empty, so "unused" can't be detected by emptiness — instead a file counts
-- as unused when its content still matches the template that would produce it
-- (each `$(...)` modifier is treated as a wildcard, so it recognises both the
-- copied-verbatim and the `evaluate_template_modifiers` forms). A file with no
-- applicable template is unused only if it is empty/whitespace.
--
-- Removing files empties directories, so a run finishes by offering those too: any
-- directory left holding nothing but testcases and sidecars is proposed for deletion,
-- deepest first, so a whole tree can collapse in one pass (problems, then the contest
-- holding them, then the directory holding the contests). Places the user works in —
-- the scanned root, the cwd, the directory the command was launched from and the roots
-- configured in `setup()` — are never proposed.
--
-- The whole flow uses tuna's floating widgets (never command-line prompts): one form
-- picks the directory (prefilled with the directories from `setup()`), the recursion
-- depth and the match threshold together — each list ending in a row that is edited
-- in place, so several of them can be customized in a single pass — then one
-- confirmation menu per candidate file, and one per candidate directory.

local api = vim.api
local config = require("tuna.config")
local utils = require("tuna.utils")
local widgets = require("tuna.widgets")

local M = {}

-- Scaffolding role -> the scaffold "kind" whose template it is created from. The
-- `reference` tool role is scaffolded as `brute` (see scaffold.lua).
local ROLE_TO_KIND = {
    checker = "checker",
    generator = "generator",
    reference = "brute",
    interactor = "interactor",
}

-- Config language name -> the file extension solutions of that language use, so a
-- directory scan only reads files that could plausibly be a solution/scaffold.
local LANG_EXT = { c = "c", cpp = "cpp", python = "py", java = "java", rust = "rs" }

--------------------------------------------------------------------------------
-- Template matching
--------------------------------------------------------------------------------

---Escape Lua-pattern magic characters in a literal string.
---@param s string
---@return string
local function escape(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

---Turn a single template line into an anchored Lua pattern: literal text is matched
---verbatim, each `$(...)` modifier becomes a `.-` wildcard (so whatever it expanded
---to — a problem name, a date, or the literal `$(...)` when unevaluated — matches).
---@param tline string
---@return string
local function line_to_pattern(tline)
    local parts, i = {}, 1
    while true do
        local s, e = tline:find("%$%b()", i)
        if not s then
            parts[#parts + 1] = escape(tline:sub(i))
            break
        end
        parts[#parts + 1] = escape(tline:sub(i, s - 1))
        parts[#parts + 1] = ".-"
        i = e + 1
    end
    return "^" .. table.concat(parts) .. "$"
end

---A predicate that tests whether a file line matches a template line. Lines without
---a `$(...)` compare by exact equality (fast path); lines with one become a pattern.
---@param tline string
---@return fun(fline: string): boolean
local function line_matcher(tline)
    if tline:find("%$%b()") then
        local pat = line_to_pattern(tline)
        return function(fline)
            return fline:match(pat) ~= nil
        end
    end
    return function(fline)
        return fline == tline
    end
end

---Similarity of `content` to `tmpl` in `[0,1]`: the length of the longest common
---subsequence of lines (a file line "matches" a template line via `line_matcher`,
---so `$(...)` regions stay wildcards) over the longer of the two, so both edits and
---additions lower the score. An untouched file scores 1.0; heavier edits score less.
---Leading/trailing blank lines are ignored.
---@param content string
---@param tmpl string
---@param min_ratio number? skip the comparison when this score is already unreachable
---@return number
local function similarity(content, tmpl, min_ratio)
    local tlines = vim.split(vim.trim(tmpl), "\n", { plain = true })
    local flines = vim.split(vim.trim(content), "\n", { plain = true })
    local n, m = #tlines, #flines
    if n == 0 then
        return m == 0 and 1 or 0
    end
    -- The LCS can never exceed the shorter file, so the score can never exceed
    -- min(n,m)/max(n,m). When that ceiling is already under the threshold the file
    -- cannot qualify however it is compared — decided on line counts alone, which is
    -- what keeps a scan over many unrelated files from paying for the DP at all.
    if min_ratio and math.min(n, m) / math.max(n, m) < min_ratio then
        return 0
    end
    -- Guard the O(n*m) DP against a pathologically large file.
    if n * m > 4000000 then
        return content == tmpl and 1 or 0
    end
    local matchers = {}
    for i, t in ipairs(tlines) do
        matchers[i] = line_matcher(t)
    end
    local prev = {}
    for j = 0, m do
        prev[j] = 0
    end
    for i = 1, n do
        local cur = { [0] = 0 }
        local mt = matchers[i]
        for j = 1, m do
            if mt(flines[j]) then
                cur[j] = prev[j - 1] + 1
            else
                cur[j] = math.max(prev[j], cur[j - 1])
            end
        end
        prev = cur
    end
    return prev[m] / math.max(n, m)
end

--------------------------------------------------------------------------------
-- Classification
--------------------------------------------------------------------------------

---Map a base filename (no extension) to the scaffold kind it names, from the
---configured `tool_names` and `scaffold.files`.
---@param cfg table
---@return table<string, string>
local function tool_kinds(cfg)
    local map = {}
    for role, kind in pairs(ROLE_TO_KIND) do
        for _, name in ipairs((cfg.tool_names or {})[role] or {}) do
            map[name] = kind
        end
    end
    for kind, base in pairs((cfg.scaffold and cfg.scaffold.files) or {}) do
        map[base] = kind
    end
    return map
end

---The file extensions worth reading during a scan.
---@param cfg table
---@return table<string, boolean>
local function source_exts(cfg)
    local exts = { cpp = true, py = true } -- scaffold built-ins always relevant
    for _, group in ipairs({ cfg.compile_command, cfg.run_command }) do
        for lang in pairs(group or {}) do
            if LANG_EXT[lang] then
                exts[LANG_EXT[lang]] = true
            end
        end
    end
    if type(cfg.template_file) == "table" then
        for ext in pairs(cfg.template_file) do
            exts[ext] = true
        end
    end
    if cfg.downloaded_files_extension then
        exts[cfg.downloaded_files_extension] = true
    end
    return exts
end

---The solution template content that would have produced a file at `full`.
---@param full string absolute file path
---@param ext string its extension
---@param cfg table
---@return string?
---@param cache table<string, string|false> memo of already-read templates
local function solution_template(full, ext, cfg, cache)
    local tf = cfg.template_file
    local path
    if type(tf) == "string" then
        path = utils.eval_string(full, tf) -- fills $(FEXT)/$(FNOEXT)/… from `full`
    elseif type(tf) == "table" then
        path = tf[ext]
    else
        return nil
    end
    if not path then
        return nil
    end
    path = path:gsub("^~", vim.uv.os_homedir())
    -- `full` may *be* the template file itself (e.g. cleaning the folder that holds
    -- `template.cpp`); it would trivially match itself 100%. Don't offer to delete it.
    if vim.fs.normalize(path) == vim.fs.normalize(full) then
        return nil
    end
    -- The same handful of templates back every candidate: read each one once.
    if cache[path] == nil then
        cache[path] = utils.read_file(path) or false
    end
    return cache[path] or nil
end

---Classify a file: return a human-readable "unused" reason, or nil if it looks
---used. A file is unused when its similarity to the template that would produce it
---is at least `threshold` (1.0 = an exact/untouched match; 0.95 = "95% the template",
---so a lightly-edited file still counts). A file with no applicable template is
---unused only when empty.
---@param full string
---@param ext string
---@param base string basename without extension
---@param kinds table<string, string>
---@param cfg table
---@param threshold number similarity in [0,1] at/above which a file counts as unused
---@param cache table<string, any> per-scan memo (templates, keyed by path/kind)
---@return string? reason, number? similarity the score the reason quotes, for ranking
local function classify(full, ext, base, kinds, cfg, threshold, cache)
    -- A file generated from a template is small. Anything enormous is certainly not
    -- one, and reading it is exactly the cost worth avoiding on a big scan.
    local stat = vim.uv.fs_stat(full)
    if stat and stat.size > 1048576 then
        return nil
    end
    local kind = kinds[base]
    local tmpl
    if kind then
        local key = "\0kind:" .. kind .. ":" .. ext
        if cache[key] == nil then
            cache[key] = require("tuna.scaffold").template_for(kind, ext, cfg) or false
        end
        tmpl = cache[key] or nil
    else
        tmpl = solution_template(full, ext, cfg, cache)
    end
    local content = utils.read_file(full)
    if content == nil then
        return nil
    end
    if tmpl then
        local sim = similarity(content, tmpl, threshold)
        if sim >= threshold then
            local what = kind and (kind .. " scaffold") or "solution template"
            return ("%d%% match to %s"):format(math.floor(sim * 100 + 0.5), what), sim
        end
        return nil
    end
    -- No applicable template (e.g. template_file = false): only an empty file is unused.
    -- Nothing was ever written to it, so it ranks with the surest deletions (1.0).
    if vim.trim(content) == "" then
        return "empty file", 1
    end
    return nil
end

--------------------------------------------------------------------------------
-- Directory discovery + scanning
--------------------------------------------------------------------------------

---The base directory a configured path option points into: expand the leading
---context modifiers (`~`, `$(HOME)`, `$(CWD)`), then cut at the first remaining
---`$(...)` (a per-problem modifier like `$(JUDGE)`/`$(PROBLEM)`) and take the
---directory part. E.g. `$(HOME)/cp/problems/$(JUDGE)/…` -> `~/cp/problems`,
---`~/cp/template.$(FEXT)` -> `~/cp`.
---@param path_str any
---@return string?
local function base_dir_of(path_str)
    if type(path_str) ~= "string" or path_str == "" then
        return nil
    end
    local home = vim.uv.os_homedir()
    local s = path_str:gsub("^~", home):gsub("%$%(HOME%)", home):gsub("%$%(CWD%)", vim.fn.getcwd())
    local mod = s:find("%$%b()")
    if mod then
        s = s:sub(1, mod - 1)
    end
    local slash = s:match(".*()/") -- position of the last slash
    if not slash then
        return nil
    end
    s = vim.fs.normalize(s:sub(1, slash - 1))
    return s ~= "" and s or nil
end

---Directories to offer as ready-made clean targets: the working directory first —
---named `cwd (…)` so it is obvious that is what it is — then the roots drawn from the
---setup() config. Returns the paths and the labels to show for them, in step.
---@param cfg table
---@return string[] paths, string[] labels
local function candidate_dirs(cfg)
    local seen, dirs, labels = {}, {}, {}
    local function add(d, label)
        if d and utils.directory_exists(d) and not seen[d] then
            seen[d] = true
            dirs[#dirs + 1] = d
            labels[#labels + 1] = label or d
        end
    end
    local cwd = vim.fs.normalize(vim.fn.getcwd())
    add(cwd, ("cwd (%s)"):format(cwd))
    add(base_dir_of(cfg.downloaded_problems_path))
    add(base_dir_of(cfg.downloaded_contests_directory))
    if type(cfg.template_file) == "string" then
        add(base_dir_of(cfg.template_file))
    elseif type(cfg.template_file) == "table" then
        for _, p in pairs(cfg.template_file) do
            add(base_dir_of(p))
        end
    end
    return dirs, labels
end

---The directory names a scan must not descend into. Dot-directories are always in:
---their files can never be candidates, so walking them is pure cost — and on a big
---tree they are the overwhelming majority of it.
---@param cfg table
---@return table<string, boolean>
local function skip_set(cfg)
    local set = {}
    for _, name in ipairs((cfg.clean or {}).skip_dirs or {}) do
        set[name] = true
    end
    return set
end

---A `vim.fs.dir` `skip` predicate: false stops the walk descending into that
---directory, which is the only place pruning actually saves anything.
---@param skips table<string, boolean>
---@return fun(name: string): boolean
local function descend_into(skips)
    return function(name)
        return not (skips[name] or name:sub(1, 1) == ".")
    end
end

---A shared allowance of filesystem entries for one run, so a scan aimed at a huge
---tree gives up instead of locking the editor.
---@param cfg table
---@return { used: integer, max: integer, truncated: boolean? }
local function entry_budget(cfg)
    return { used = 0, max = (cfg.clean or {}).max_entries or 20000 }
end

---Scan `dir` for unused files, recursing up to `depth` levels (`math.huge` =
---unlimited). A file counts as unused at similarity `threshold`.
---@param dir string
---@param cfg table
---@param depth number recursion depth passed to `vim.fs.dir`
---@param threshold number similarity threshold in [0,1]
---@return { path: string, rel: string, reason: string, sim: number }[] files, boolean truncated
local function scan(dir, cfg, depth, threshold)
    local exts = source_exts(cfg)
    local kinds = tool_kinds(cfg)
    local skips = skip_set(cfg)
    local budget = entry_budget(cfg)
    local cache = {}
    local out = {}
    pcall(function()
        -- `skip` prunes at traversal time, which is the only thing that helps: a
        -- filter applied to yielded entries has already paid to walk them.
        for name, typ in vim.fs.dir(dir, { depth = depth, skip = descend_into(skips) }) do
            budget.used = budget.used + 1
            if budget.used > budget.max then
                budget.truncated = true
                return
            end
            -- Skip dotfiles/dot-directories (e.g. .git) entirely.
            if typ == "file" and not name:match("^%.") and not name:match("/%.") then
                local ext = name:match("%.([^./]+)$") or ""
                local base = (name:match("[^/]+$") or name):gsub("%.[^.]*$", "")
                if exts[ext] or kinds[base] then
                    local full = dir .. "/" .. name
                    local reason, sim = classify(full, ext, base, kinds, cfg, threshold, cache)
                    if reason then
                        out[#out + 1] = { path = full, rel = name, reason = reason, sim = sim or 0 }
                    end
                end
            end
        end
    end)
    -- Most-certainly-unused first: the closer a file still is to its template, the
    -- less of it was ever written, so reviewing in decreasing match order front-loads
    -- the easy deletions and leaves the judgement calls for last. Equal scores fall
    -- back to path order, so the list is stable between runs.
    table.sort(out, function(a, b)
        if a.sim ~= b.sim then
            return a.sim > b.sim
        end
        return a.rel < b.rel
    end)
    return out, budget.truncated == true
end

--------------------------------------------------------------------------------
-- Empty-directory pruning
--------------------------------------------------------------------------------

---Turn a testcase filename format into an anchored Lua pattern: `$(TCNUM)` matches a
---number, every other `$(...)` matches anything (a source name, typically).
---@param fmt string
---@return string
local function fmt_to_pattern(fmt)
    local parts, i = {}, 1
    while true do
        local s, e = fmt:find("%$%b()", i)
        if not s then
            parts[#parts + 1] = escape(fmt:sub(i))
            break
        end
        parts[#parts + 1] = escape(fmt:sub(i, s - 1))
        parts[#parts + 1] = fmt:sub(s, e) == "$(TCNUM)" and "%d+" or ".-"
        i = e + 1
    end
    return "^" .. table.concat(parts) .. "$"
end

---Patterns for the files a directory may still hold and still count as "empty": the
---testcases (every configured storage layout) and the per-problem sidecar. These are
---data *about* a problem, worthless once its solution is gone.
---@param cfg table
---@return string[]
local function disposable_patterns(cfg)
    local pats = {}
    local function add(f)
        if type(f) == "string" then
            pats[#pats + 1] = fmt_to_pattern(f)
        elseif type(f) == "table" then
            for _, x in ipairs(f) do
                add(x)
            end
        end
    end
    add(cfg.testcases_input_file_format)
    add(cfg.testcases_output_file_format)
    add(cfg.testcases_single_file_format)
    add(cfg.testcases_directory_input)
    add(cfg.testcases_directory_output)
    add((cfg.submit or {}).url_store_file or ".tuna.json")
    return pats
end

---@param name string basename
---@param pats string[]
---@return boolean
local function is_disposable(name, pats)
    for _, p in ipairs(pats) do
        if name:match(p) then
            return true
        end
    end
    return false
end

-- Filesystem roots that belong to the system, not to any problem set. An empty one is
-- still not tuna's to remove, and a scan started high enough up will walk into them.
local SYSTEM_DIRS = {
    "/",
    "/bin",
    "/boot",
    "/dev",
    "/etc",
    "/home",
    "/lib",
    "/media",
    "/mnt",
    "/opt",
    "/proc",
    "/root",
    "/run",
    "/sbin",
    "/srv",
    "/sys",
    "/tmp",
    "/usr",
    "/var",
}

-- The standard directories of a user account, used when the desktop's own record of
-- them (`user-dirs.dirs`) is unavailable. macOS names are included too: an entry that
-- doesn't exist on this system simply never matches. Deliberately conservative — these
-- are routinely empty, which is exactly when they would otherwise be proposed.
local HOME_DIRS = {
    "Applications",
    "Desktop",
    "Documents",
    "Downloads",
    "Library",
    "Movies",
    "Music",
    "Pictures",
    "Public",
    "Templates",
    "Videos",
}

---The user's standard directories, taken from the desktop's own record of them
---(`$XDG_CONFIG_HOME/user-dirs.dirs`) so localized names — `Scrivania`, `Bureau` — are
---covered as well, falling back to the conventional English names.
---@param home string
---@return string[]
local function xdg_user_dirs(home)
    local out = {}
    local conf = (vim.env.XDG_CONFIG_HOME or (home .. "/.config")) .. "/user-dirs.dirs"
    for line in (utils.read_file(conf) or ""):gmatch("[^\n]+") do
        -- XDG_DESKTOP_DIR="$HOME/Desktop"
        local path = line:match('^%s*XDG_%u+_DIR%s*=%s*"(.-)"')
        if path then
            out[#out + 1] = (path:gsub("^%$HOME", home):gsub("^~", home))
        end
    end
    for _, name in ipairs(HOME_DIRS) do
        out[#out + 1] = home .. "/" .. name
    end
    return out
end

---Directories that must never be offered for deletion: the directory being scanned,
---the working directory, the directory `:Tuna clean` was launched from, every root
---configured in `setup()`, the home directory with its standard sub-directories, and
---the system's own directories. These are places the user (or the OS) works in, not
---products of a run. Extra paths can be added through `clean.protected_dirs`.
---@param root string the directory being scanned
---@param cfg table
---@param bufnr integer?
---@return table<string, boolean>
local function protected_dirs(root, cfg, bufnr)
    local set = {}
    local function add(d)
        if d and d ~= "" then
            set[vim.fs.normalize(d)] = true
        end
    end
    add(root)
    add(vim.fn.getcwd())
    local home = vim.fs.normalize(vim.env.HOME or vim.fn.expand("~"))
    add(home)
    for _, d in ipairs(xdg_user_dirs(home)) do
        add(d)
    end
    for _, d in ipairs(SYSTEM_DIRS) do
        add(d)
    end
    for _, d in ipairs((cfg.clean or {}).protected_dirs or {}) do
        add(vim.fn.expand(d))
    end
    local name = bufnr and api.nvim_buf_is_valid(bufnr) and api.nvim_buf_get_name(bufnr) or ""
    if name ~= "" then
        add(vim.fs.dirname(name))
    end
    for _, d in ipairs((candidate_dirs(cfg))) do
        add(d)
    end
    return set
end

---Walk `dir` bottom-up, collecting the directories that could be removed: one that
---holds nothing but disposable files and other removable directories. Appending in
---**post-order** puts children before parents, which is the order they must be
---decided in — a parent is only really removable once its children are gone.
---
---Every verdict is memoized in `ctx.decided`, which is what lets a directory be
---evaluated from two different starting points (the targeted pass over what the run
---emptied, and the general sweep) without walking any subtree twice.
---@param dir string
---@param ctx { pats: string[], protected: table<string, boolean>, skips: table<string, boolean>, budget: table, decided: table<string, { removable: boolean, files: integer }> }
---@param out { path: string, files: integer }[] collected, deepest first
---@param depth number levels left to descend
---@return boolean removable whether `dir` itself could go
---@return integer files how many disposable files it holds, all the way down
local function collect_prunable(dir, ctx, out, depth)
    local key = vim.fs.normalize(dir)
    local memo = ctx.decided[key]
    if memo then
        return memo.removable, memo.files
    end
    -- Out of depth or out of allowance: nothing was looked at, so nothing may be
    -- proposed — a directory whose contents are unknown must be assumed to matter.
    -- This is not a verdict, so it is deliberately not memoized.
    if depth < 1 or ctx.budget.used > ctx.budget.max then
        return false, 0
    end
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
        return false, 0
    end
    local removable, files = true, 0
    while true do
        local name, typ = vim.uv.fs_scandir_next(handle)
        if not name then
            break
        end
        ctx.budget.used = ctx.budget.used + 1
        if ctx.budget.used > ctx.budget.max then
            ctx.budget.truncated = true
            return false, 0
        end
        local full = dir .. "/" .. name
        -- Dot-directories are pruned here exactly as in the file scan: they are never
        -- tuna's to remove, and walking them is what made a scan of a home directory
        -- burn its whole allowance before reaching anything relevant.
        if typ == "directory" and not ctx.skips[name] and name:sub(1, 1) ~= "." then
            local ok, n = collect_prunable(full, ctx, out, depth - 1)
            if ok then
                files = files + n -- its count already covers everything below it
            else
                removable = false
            end
        elseif typ == "directory" or not is_disposable(name, ctx.pats) then
            removable = false -- a pruned directory, or something worth keeping
        else
            files = files + 1
        end
    end
    removable = removable and not ctx.protected[key]
    ctx.decided[key] = { removable = removable, files = files }
    if removable then
        out[#out + 1] = { path = dir, files = files }
    end
    return removable, files
end

---Evaluate the directories the run itself emptied, and every directory above them up
---to the scanned root. This runs *before* the general sweep and reuses its budget:
---what a run just emptied is the whole point of the pass, so it must be offered even
---when a huge tree exhausts the allowance long before the sweep could reach it.
---@param root string
---@param emptied table<string, boolean> directories that lost a file this run
---@param ctx table see `collect_prunable`
---@param out { path: string, files: integer }[]
local function collect_emptied(root, emptied, ctx, out)
    local rootdir = vim.fs.normalize(root)
    local dirs = {}
    for d in pairs(emptied) do
        dirs[#dirs + 1] = d
    end
    -- Deepest first, so a parent's evaluation finds its children already decided.
    table.sort(dirs, function(a, b)
        return #a > #b
    end)
    for _, d in ipairs(dirs) do
        -- Up to but not including the root: the root is protected, and evaluating it
        -- would mean walking the whole tree — which is the general sweep's job.
        local cur = vim.fs.normalize(d)
        while cur ~= rootdir and (cur .. "/"):sub(1, #rootdir + 1) == rootdir .. "/" do
            collect_prunable(cur, ctx, out, math.huge)
            local parent = vim.fs.dirname(cur)
            if parent == cur then
                break
            end
            cur = parent
        end
    end
end

--------------------------------------------------------------------------------
-- Flow
--------------------------------------------------------------------------------

---@param n integer
---@return string
local function plural(n)
    return n == 1 and "" or "s"
end

---Write out every modified file buffer. Run once before a clean, because a buffer
---with unsaved changes *undoes* a deletion: unlinking the file succeeds, but the
---still-open buffer writes it straight back on the next `:w` (or on exit), so the run
---would report a file removed that is about to reappear. With nothing left unsaved,
---a deleted file stays deleted and `drop_buffer` can simply wipe its buffer.
---@return integer count how many buffers were written
local function save_all_buffers()
    local saved = 0
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if
            vim.api.nvim_buf_is_valid(b)
            and vim.api.nvim_buf_is_loaded(b)
            and vim.bo[b].modified
            and vim.bo[b].buftype == "" -- a real file, not a terminal/quickfix/scratch
            and vim.api.nvim_buf_get_name(b) ~= ""
        then
            local ok = pcall(vim.api.nvim_buf_call, b, function()
                vim.cmd("silent keepalt write")
            end)
            if ok then
                saved = saved + 1
            end
        end
    end
    return saved
end

---After a file is deleted from disk, drop the buffer still backing it so the user
---isn't left editing a phantom — and, more importantly, so nothing can write the file
---back. This is what makes `:Tuna clean` robust when it deletes the very file it was
---launched from. Everything was saved up front, so there is never unsaved work here.
---@param path string absolute path of the deleted file
local function drop_buffer(path)
    path = vim.fs.normalize(path)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) and vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == path then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
            return
        end
    end
end

---The confirmation title for a single candidate, e.g.
---`[2/7] 100% match to solution template`. The file itself is named by the preview
---pane's title just below, so repeating it here would only crowd the prompt.
---@param files { path: string, rel: string, reason: string, sim: number }[]
---@param i integer
---@return string
local function confirm_title(files, i)
    return ("[%d/%d] %s"):format(i, #files, files[i].reason)
end

---A single width to use for *every* confirmation menu in a pass, so the float doesn't
---jump size as names and contents vary from one item to the next. It fits the longest
---thing shown — a menu title, or a preview-pane title (+2 for its surrounding spaces)
---— then clamps to `clean.min_width`/`clean.max_width` (fractions of the editor
---width); anything longer truncates and the preview scrolls horizontally.
---@param titles string[] the menu titles this pass will show
---@param subtitles string[] the preview-pane titles this pass will show
---@param cfg table
---@return integer
local function menu_width(titles, subtitles, cfg)
    local longest = 0
    for _, t in ipairs(titles) do
        longest = math.max(longest, #t)
    end
    for _, t in ipairs(subtitles) do
        longest = math.max(longest, #t + 2)
    end
    local vim_width = utils.get_ui_size()
    local clean = cfg.clean or {}
    local lo = math.floor(vim_width * (clean.min_width or 0.5))
    local hi = math.floor(vim_width * (clean.max_width or 0.7))
    return math.max(lo, math.min(longest + 4, hi))
end

---@param files { path: string, rel: string, reason: string, sim: number }[]
---@param cfg table
---@return integer
local function confirm_width(files, cfg)
    local titles, subtitles = {}, {}
    for i = 1, #files do
        titles[i], subtitles[i] = confirm_title(files, i), files[i].rel
    end
    return menu_width(titles, subtitles, cfg)
end

---Confirm and delete the candidate files one at a time, via a menu per file.
---@param files { path: string, rel: string, reason: string, sim: number }[]
---@param i integer index into `files`
---@param restore integer? window to refocus after each menu
---@param stats { deleted: integer, dirs: integer, emptied: table<string, boolean>, stopped: boolean? }
---@param ui { width: integer, notice: table? } fixed menu width shared by every file
---  this run, plus an optional notice pane shown above each prompt
---@param done fun() continuation, run once the last file has been decided
local function confirm_each(files, i, restore, stats, ui, done)
    if i > #files then
        return done()
    end
    local f = files[i]
    -- Preview the file to be deleted in a pane below the prompt: scroll it with
    -- <C-d>/<C-u>, or step into it with the pane-switch keys (`switch_window_keys`).
    local preview = {
        title = f.rel,
        lines = vim.split(utils.read_file(f.path) or "", "\n", { plain = true }),
        filetype = vim.filetype.match({ filename = f.path }),
        width = ui.width,
    }
    widgets.menu({ "Delete", "Keep", "Stop" }, confirm_title(files, i), function(idx)
        if idx == 3 then -- Stop
            stats.stopped = true
            return done()
        end
        if idx == 1 then -- Delete
            if utils.delete_file(f.path) then
                stats.deleted = stats.deleted + 1
                -- Remember what this emptied: the directory pass starts from here, so
                -- what the run itself hollowed out is offered even when the general
                -- sweep is too big to finish.
                stats.emptied[vim.fs.normalize(vim.fs.dirname(f.path))] = true
                drop_buffer(f.path)
            else
                utils.notify("clean: could not delete " .. f.rel .. ".", "WARN")
            end
        end
        confirm_each(files, i + 1, restore, stats, ui, done) -- idx 2 (Keep) lands here too
    end, restore, nil, preview, ui.notice)
end

---Wipe the buffers backing anything inside a directory that is about to be removed,
---so nothing is left that could write a file back into it (see `drop_buffer`).
---@param dir string
local function drop_buffers_under(dir)
    local prefix = vim.fs.normalize(dir) .. "/"
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) then
            local name = vim.api.nvim_buf_get_name(b)
            if name ~= "" and vim.fs.normalize(name):sub(1, #prefix) == prefix then
                pcall(vim.api.nvim_buf_delete, b, { force = true })
            end
        end
    end
end

---Everything still inside a directory, as relative paths, to preview what removing it
---would take with it. Bounded, since the pane only shows so much anyway.
---@param dir string
---@return string[]
local function dir_listing(dir)
    local out = {}
    pcall(function()
        for name, typ in vim.fs.dir(dir, { depth = 8 }) do
            out[#out + 1] = typ == "directory" and (name .. "/") or name
            if #out >= 200 then
                return
            end
        end
    end)
    table.sort(out)
    if #out == 0 then
        out[1] = "(empty)"
    end
    return out
end

---@param d { path: string, files: integer }
---@return string
local function prune_reason(d)
    if d.files == 0 then
        return "empty directory"
    end
    return ("only testcases/metadata left (%d file%s)"):format(d.files, plural(d.files))
end

---Confirm and remove the removable directories one at a time, deepest first.
---Keeping one takes its ancestors out of the running: they still hold it, so they are
---no longer empty. Deleting one leaves its ancestors as candidates, which is what
---makes a whole tree collapse in a single pass — problems, then their contest, then
---the directory holding the contests.
---@param dirs { path: string, rel: string, files: integer, skip: boolean? }[]
---@param i integer
---@param restore integer?
---@param stats { deleted: integer, dirs: integer, stopped: boolean? }
---@param ui { width: integer, notice: table? }
---@param done fun()
local function confirm_dirs(dirs, i, restore, stats, ui, done)
    if i > #dirs then
        return done()
    end
    local d = dirs[i]
    if d.skip then
        return confirm_dirs(dirs, i + 1, restore, stats, ui, done)
    end
    local preview = { title = d.rel .. "/", lines = dir_listing(d.path), width = ui.width }
    local title = ("[%d/%d] %s"):format(i, #dirs, prune_reason(d))
    widgets.menu({ "Delete", "Keep", "Stop" }, title, function(idx)
        if idx == 3 then -- Stop
            stats.stopped = true
            return done()
        end
        if idx == 1 then -- Delete
            drop_buffers_under(d.path)
            if vim.fn.delete(d.path, "rf") == 0 then
                stats.dirs = stats.dirs + 1
            else
                utils.notify("clean: could not delete " .. d.rel .. "/.", "WARN")
            end
        else -- Keep: this directory survives, so nothing above it can be empty
            local kept = d.path .. "/"
            for j = i + 1, #dirs do
                local ancestor = dirs[j].path .. "/"
                if kept:sub(1, #ancestor) == ancestor then
                    dirs[j].skip = true
                end
            end
        end
        confirm_dirs(dirs, i + 1, restore, stats, ui, done)
    end, restore, nil, preview, ui.notice)
end

---Offer to remove the directories left empty — either found that way or emptied by
---the file pass just run.
---@param root string
---@param cfg table
---@param bufnr integer?
---@param restore integer?
---@param stats { deleted: integer, dirs: integer, emptied: table<string, boolean>, stopped: boolean? }
---The pane shown above every confirmation when a scan could not cover its whole tree,
---so the caveat sits in front of the user at the moment of deciding instead of being a
---command-line line they have already scrolled past.
---@param stats { truncated: boolean? }
---@param dir string
---@param cfg table
---@return { title: string, lines: string[] }?
local function truncation_notice(stats, dir, cfg)
    if not stats.truncated then
        return nil
    end
    return {
        title = "Partial scan",
        lines = {
            ("'%s' holds more than %d entries, so only part of it was searched."):format(
                dir,
                (cfg.clean or {}).max_entries or 20000
            ),
            "Scan a narrower directory, or lower the recursion depth, to cover the rest.",
        },
    }
end

---@param depth number how far the file scan reached, so both passes cover the same area
---@param done fun()
local function prune_dirs(root, cfg, bufnr, restore, stats, depth, done)
    if stats.stopped then
        return done()
    end
    local found = {}
    local ctx = {
        pats = disposable_patterns(cfg),
        protected = protected_dirs(root, cfg, bufnr),
        skips = skip_set(cfg),
        budget = entry_budget(cfg),
        decided = {},
    }
    -- What the run emptied first, the general sweep for already-empty directories
    -- second: both share one allowance, and this is the order of decreasing certainty
    -- that the user wants to hear about it.
    collect_emptied(root, stats.emptied or {}, ctx, found)
    collect_prunable(root, ctx, found, depth)
    stats.truncated = stats.truncated or ctx.budget.truncated
    -- Deepest first across both passes, so a directory is always decided before the one
    -- holding it: deleting a parent takes its children with it, and keeping a child
    -- rules its parents out.
    table.sort(found, function(a, b)
        local da, db = select(2, a.path:gsub("/", "")), select(2, b.path:gsub("/", ""))
        if da ~= db then
            return da > db
        end
        return a.path < b.path
    end)
    stats.found = (stats.found or 0) + #found
    if #found == 0 then
        return done()
    end
    local titles, subtitles = {}, {}
    for i, d in ipairs(found) do
        d.rel = d.path:sub(#root + 2) -- path relative to the scanned root
        titles[i], subtitles[i] = ("[%d/%d] %s"):format(i, #found, prune_reason(d)), d.rel .. "/"
    end
    confirm_dirs(found, 1, restore, stats, {
        width = menu_width(titles, subtitles, cfg),
        notice = truncation_notice(stats, root, cfg),
    }, done)
end

-- Recursion-depth choices (default first); the form appends an editable row for any
-- other depth.
local DEPTH_CHOICES = {
    { "Infinite (all subdirectories)", math.huge },
    { "Only this directory", 1 },
}

-- Similarity-threshold choices (default first); the form appends an editable row for
-- any other percentage. A file is unused when its similarity to the template is at
-- least this.
local THRESHOLD_CHOICES = {
    { "Full match (100%)", 1.0 },
    { "95% match", 0.95 },
}

---How a depth reads in a message.
---@param depth number
---@return string
local function depth_label(depth)
    return depth == math.huge and "infinite" or tostring(math.floor(depth))
end

---How a threshold reads in a message.
---@param threshold number
---@return string
local function threshold_label(threshold)
    return ("%d%%"):format(math.floor(threshold * 100 + 0.5))
end

-- Validators for the form's editable rows: each turns the typed text into the value
-- the scan needs, or returns an error that keeps the form open for a correction.

---@param text string
---@return string?, string?
local function validate_dir(text)
    text = vim.trim(text)
    if text == "" then
        return nil, "clean: enter a directory to scan."
    end
    local dir = vim.fs.normalize(vim.fn.expand(text))
    if not utils.directory_exists(dir) then
        return nil, "clean: '" .. dir .. "' is not a directory."
    end
    return dir
end

---@param text string
---@return number?, string?
local function validate_depth(text)
    text = vim.trim(text)
    if text == "" then
        return nil, "clean: enter a recursion depth (a number ≥ 1)."
    end
    local d = tonumber(text)
    if not d or d < 1 then
        return nil, "clean: '" .. text .. "' is not a valid depth (a number ≥ 1)."
    end
    return math.floor(d)
end

---@param text string
---@return number?, string?
local function validate_threshold(text)
    text = vim.trim(text)
    if text == "" then
        return nil, "clean: enter a match threshold (a percent 1-100)."
    end
    local p = tonumber((text:gsub("%%", "")))
    if not p or p <= 0 or p > 100 then
        return nil, "clean: '" .. text .. "' is not a valid percentage (1-100)."
    end
    return p / 100
end

---Scan `dir`, drive the per-file confirmation menus, then offer to remove whatever
---directories that left empty.
---@param dir string
---@param cfg table
---@param restore integer?
---@param depth number recursion depth
---@param threshold number similarity threshold in [0,1]
---@param bufnr integer? the buffer `:Tuna clean` was launched from
local function scan_and_confirm(dir, cfg, restore, depth, threshold, bufnr)
    dir = vim.fs.normalize(vim.fn.expand(dir))
    if not utils.directory_exists(dir) then
        utils.notify("clean: '" .. dir .. "' is not a directory.")
        return
    end
    local stats = { deleted = 0, dirs = 0, emptied = {} }

    local function report()
        if stats.deleted == 0 and stats.dirs == 0 then
            if stats.stopped then
                utils.notify("clean: stopped, nothing removed.", "INFO")
                return
            end
            -- Something was offered and every one of it was kept: that is a different
            -- outcome from having found nothing, and saying otherwise would be wrong.
            if (stats.found or 0) > 0 then
                utils.notify("clean: nothing removed, every candidate was kept.", "INFO")
                return
            end
            -- Finding nothing is a perfectly good outcome — the command is also how one
            -- checks whether there is anything to clean at all — so this is informational.
            -- It still reports the whole search, not just where it started, since a
            -- narrow depth or a strict threshold is the other reason a run comes up empty.
            utils.notify(
                ("clean: no unused files found in %s (depth: %s, match threshold: %s)%s."):format(
                    dir,
                    depth_label(depth),
                    threshold_label(threshold),
                    stats.truncated and ", but only part of it was scanned" or ""
                ),
                "INFO"
            )
            return
        end
        -- "source files" rather than plain "files": removing a directory takes its
        -- testcases and metadata with it, so only the first count is about code.
        local parts = { ("%d source file%s"):format(stats.deleted, plural(stats.deleted)) }
        if stats.dirs > 0 then
            parts[#parts + 1] = ("%d director%s"):format(stats.dirs, stats.dirs == 1 and "y" or "ies")
        end
        utils.notify(
            ("clean: %sremoved %s%s."):format(
                stats.stopped and "stopped, " or "",
                table.concat(parts, " and "),
                stats.truncated and " (only part of the directory was scanned)" or ""
            ),
            "INFO"
        )
    end

    -- Directories are decided after the files, since that is what empties them.
    local function then_dirs()
        prune_dirs(dir, cfg, bufnr, restore, stats, depth, report)
    end

    local files, truncated = scan(dir, cfg, depth, threshold)
    stats.truncated, stats.found = truncated, #files
    if #files == 0 then
        then_dirs() -- nothing to delete, but directories may already be empty
    else
        -- A partial scan is reported as a pane above each prompt (see
        -- `truncation_notice`), not as a command-line message.
        confirm_each(files, 1, restore, stats, {
            width = confirm_width(files, cfg),
            notice = truncation_notice(stats, dir, cfg),
        }, then_dirs)
    end
end

---Entry point for `:Tuna clean`. Choose a directory, recursion depth, and match
---threshold together (one form, all three lists visible), then confirm each unused
---file before deleting it.
---@param bufnr integer? defaults to the current buffer
function M.clean(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    local restore = api.nvim_get_current_win()

    -- Nothing may be left unsaved: an open buffer with pending changes writes a
    -- deleted file back, so a clean would report removals that quietly undo themselves.
    local saved = save_all_buffers()
    if saved > 0 then
        utils.notify(("clean: saved %d modified buffer%s first."):format(saved, plural(saved)), "INFO")
    end

    local dirs, dir_labels = candidate_dirs(cfg)
    local function labels_of(choices)
        local out = {}
        for i, c in ipairs(choices) do
            out[i] = c[1]
        end
        return out
    end

    -- Directory, recursion depth and match threshold are chosen together, all three
    -- lists visible at once (`switch_window_keys` or Tab switch lists, <CR> submits).
    -- Each list ends in an empty `Custom:` row typed into in place, so customizing one
    -- costs no extra prompt and several can be set before submitting.
    widgets.form(
        {
            {
                title = "Directory",
                items = dir_labels,
                custom = { label = "Custom: ", default = "", validate = validate_dir },
            },
            {
                title = "Recursion depth",
                items = labels_of(DEPTH_CHOICES),
                custom = { label = "Custom: ", default = "", validate = validate_depth },
            },
            {
                title = "Match threshold",
                items = labels_of(THRESHOLD_CHOICES),
                custom = { label = "Custom: ", default = "", validate = validate_threshold },
            },
        },
        "Clean",
        function(results)
            -- A section's `custom` is set (and already validated) when its editable
            -- row was the selection; otherwise the choice is the fixed one at `index`.
            local dir = results[1].custom or dirs[results[1].index]
            local depth = results[2].custom or DEPTH_CHOICES[results[2].index][2]
            local threshold = results[3].custom or THRESHOLD_CHOICES[results[3].index][2]
            scan_and_confirm(dir, cfg, restore, depth, threshold, bufnr)
        end,
        restore
    )
end

return M
