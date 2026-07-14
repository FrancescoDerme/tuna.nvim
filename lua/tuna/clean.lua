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
-- The whole flow uses tuna's floating widgets (never command-line prompts): a menu
-- to choose a directory (prefilled with the directories from `setup()`, plus an
-- "Other directory…" option that opens an input prompt), then one confirmation
-- menu per candidate file before it is deleted.

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
---@return number
local function similarity(content, tmpl)
    local tlines = vim.split(vim.trim(tmpl), "\n", { plain = true })
    local flines = vim.split(vim.trim(content), "\n", { plain = true })
    local n, m = #tlines, #flines
    if n == 0 then
        return m == 0 and 1 or 0
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
    if cfg.received_files_extension then
        exts[cfg.received_files_extension] = true
    end
    return exts
end

---The solution template content that would have produced a file at `full`.
---@param full string absolute file path
---@param ext string its extension
---@param cfg table
---@return string?
local function solution_template(full, ext, cfg)
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
    return utils.read_file(path)
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
---@return string?
local function classify(full, ext, base, kinds, cfg, threshold)
    local content = utils.read_file(full)
    if content == nil then
        return nil
    end
    local kind = kinds[base]
    local tmpl = kind and require("tuna.scaffold").template_for(kind, ext, cfg)
        or solution_template(full, ext, cfg)
    if tmpl then
        local sim = similarity(content, tmpl)
        if sim >= threshold then
            local what = kind and (kind .. " scaffold") or "solution template"
            return ("%d%% match to %s"):format(math.floor(sim * 100 + 0.5), what)
        end
        return nil
    end
    -- No applicable template (e.g. template_file = false): only an empty file is unused.
    if vim.trim(content) == "" then
        return "empty file"
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

---Directories to offer as prefilled clean targets, drawn from the setup() config.
---@param cfg table
---@return string[]
local function candidate_dirs(cfg)
    local seen, dirs = {}, {}
    local function add(d)
        if d and utils.directory_exists(d) and not seen[d] then
            seen[d] = true
            dirs[#dirs + 1] = d
        end
    end
    add(base_dir_of(cfg.received_problems_path))
    add(base_dir_of(cfg.received_contests_directory))
    if type(cfg.template_file) == "string" then
        add(base_dir_of(cfg.template_file))
    elseif type(cfg.template_file) == "table" then
        for _, p in pairs(cfg.template_file) do
            add(base_dir_of(p))
        end
    end
    add(vim.fs.normalize(vim.fn.getcwd()))
    return dirs
end

---Scan `dir` for unused files, recursing up to `depth` levels (`math.huge` =
---unlimited). A file counts as unused at similarity `threshold`.
---@param dir string
---@param cfg table
---@param depth number recursion depth passed to `vim.fs.dir`
---@param threshold number similarity threshold in [0,1]
---@return { path: string, rel: string, reason: string }[]
local function scan(dir, cfg, depth, threshold)
    local exts = source_exts(cfg)
    local kinds = tool_kinds(cfg)
    local out = {}
    pcall(function()
        for name, typ in vim.fs.dir(dir, { depth = depth }) do
            -- Skip dotfiles/dot-directories (e.g. .git) entirely.
            if typ == "file" and not name:match("^%.") and not name:match("/%.") then
                local ext = name:match("%.([^./]+)$") or ""
                local base = (name:match("[^/]+$") or name):gsub("%.[^.]*$", "")
                if exts[ext] or kinds[base] then
                    local full = dir .. "/" .. name
                    local reason = classify(full, ext, base, kinds, cfg, threshold)
                    if reason then
                        out[#out + 1] = { path = full, rel = name, reason = reason }
                    end
                end
            end
        end
    end)
    table.sort(out, function(a, b)
        return a.rel < b.rel
    end)
    return out
end

--------------------------------------------------------------------------------
-- Flow
--------------------------------------------------------------------------------

---@param n integer
---@return string
local function plural(n)
    return n == 1 and "" or "s"
end

---After a file is deleted from disk, drop any buffer still backing it so the user
---isn't left editing a phantom (this is what makes `:Tuna clean` robust when it
---deletes the very file it was launched from). A buffer with *unsaved* changes is
---kept — its content isn't on disk anymore, so wiping it would lose work; the user
---can `:w` to restore the file or discard it themselves.
---@param path string absolute path of the deleted file
---@return boolean kept whether a modified buffer was left in place
local function drop_buffer(path)
    path = vim.fs.normalize(path)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) and vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == path then
            if vim.bo[b].modified then
                return true
            end
            pcall(vim.api.nvim_buf_delete, b, { force = true })
            return false
        end
    end
    return false
end

---Confirm and delete the candidate files one at a time, via a menu per file.
---@param files { path: string, rel: string, reason: string }[]
---@param i integer index into `files`
---@param restore integer? window to refocus after each menu
---@param stats { deleted: integer }
local function confirm_each(files, i, restore, stats)
    if i > #files then
        utils.notify(("clean: removed %d file%s."):format(stats.deleted, plural(stats.deleted)), "INFO")
        return
    end
    local f = files[i]
    local title = ("[%d/%d] delete %s (%s)?"):format(i, #files, f.rel, f.reason)
    -- Preview the file to be deleted in a pane below the prompt (scroll with C-d/C-u).
    local preview = {
        title = f.rel,
        lines = vim.split(utils.read_file(f.path) or "", "\n", { plain = true }),
        filetype = vim.filetype.match({ filename = f.path }),
    }
    widgets.menu({ "Delete", "Keep", "Stop" }, title, function(idx)
        if idx == 3 then -- Stop
            utils.notify(("clean: stopped — removed %d file%s."):format(stats.deleted, plural(stats.deleted)), "INFO")
            return
        end
        if idx == 1 then -- Delete
            if utils.delete_file(f.path) then
                stats.deleted = stats.deleted + 1
                if drop_buffer(f.path) then
                    utils.notify("clean: deleted " .. f.rel .. " (its buffer has unsaved changes and was kept).", "WARN")
                end
            else
                utils.notify("clean: could not delete " .. f.rel .. ".", "WARN")
            end
        end
        confirm_each(files, i + 1, restore, stats) -- idx 2 (Keep) falls through here too
    end, restore, nil, preview)
end

-- Recursion-depth choices (default first). `custom` defers to a numeric prompt.
local DEPTH_CHOICES = {
    { "Infinite (all subdirectories)", math.huge },
    { "Only this directory", 1 },
    { "Custom…", custom = true },
}

-- Similarity-threshold choices (default first). `custom` defers to a percent prompt.
-- A file is unused when its similarity to the template is at least this.
local THRESHOLD_CHOICES = {
    { "Full match (100%)", 1.0 },
    { "95% match", 0.95 },
    { "Custom…", custom = true },
}

---Scan `dir` and drive the per-file confirmation menus.
---@param dir string
---@param cfg table
---@param restore integer?
---@param depth number recursion depth
---@param threshold number similarity threshold in [0,1]
local function scan_and_confirm(dir, cfg, restore, depth, threshold)
    dir = vim.fs.normalize(vim.fn.expand(dir))
    if not utils.directory_exists(dir) then
        utils.notify("clean: '" .. dir .. "' is not a directory.")
        return
    end
    local files = scan(dir, cfg, depth, threshold)
    if #files == 0 then
        utils.notify("clean: no unused files found in " .. dir .. ".", "INFO")
        return
    end
    confirm_each(files, 1, restore, { deleted = 0 })
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

    local dirs = candidate_dirs(cfg)
    local dir_items = vim.list_extend(vim.deepcopy(dirs), { "Other directory…" })
    local function labels_of(choices)
        local out = {}
        for i, c in ipairs(choices) do
            out[i] = c[1]
        end
        return out
    end

    -- A short helper: open a text prompt (reused for the "Custom…"/"Other" cases).
    local function ask(title, default, cont)
        widgets.input(title, default, cfg.floating_border, cfg.floating_border_highlight, false, cont)
    end

    -- Directory, recursion depth and match threshold are chosen together, all three
    -- lists visible at once (`switch_window_keys` or Tab switch lists, <CR> submits).
    -- Any "Custom…"/"Other directory…" choice defers to a text prompt afterwards.
    widgets.form({
        { title = "Directory", items = dir_items },
        { title = "Recursion depth", items = labels_of(DEPTH_CHOICES) },
        { title = "Match threshold", items = labels_of(THRESHOLD_CHOICES) },
    }, "Clean", function(sels)
        -- Resolve each choice (some open a follow-up prompt), then scan.
        local function resolve_dir(cont)
            if sels[1] == #dir_items then
                ask("Directory to clean", dirs[1] or vim.fs.normalize(vim.fn.getcwd()), cont)
            else
                cont(dirs[sels[1]])
            end
        end
        local function resolve_depth(cont)
            local c = DEPTH_CHOICES[sels[2]]
            if c.custom then
                ask("Recursion depth (a number ≥ 1)", "5", function(txt)
                    local d = tonumber(txt)
                    if not d or d < 1 then
                        utils.notify("clean: '" .. txt .. "' is not a valid depth.")
                        return
                    end
                    cont(math.floor(d))
                end)
            else
                cont(c[2])
            end
        end
        local function resolve_threshold(cont)
            local c = THRESHOLD_CHOICES[sels[3]]
            if c.custom then
                ask("Match threshold (a percent 1-100)", "95", function(txt)
                    local p = tonumber((txt:gsub("%%", "")))
                    if not p or p <= 0 or p > 100 then
                        utils.notify("clean: '" .. txt .. "' is not a valid percentage.")
                        return
                    end
                    cont(p / 100)
                end)
            else
                cont(c[2])
            end
        end

        resolve_dir(function(dir)
            resolve_depth(function(depth)
                resolve_threshold(function(threshold)
                    scan_and_confirm(dir, cfg, restore, depth, threshold)
                end)
            end)
        end)
    end, restore)
end

return M
