-- lua/tuna/workspace/library.lua
--
-- `:Tuna lib` — pull a piece of your own algorithm library into the file you are
-- writing. A competitive programmer keeps a folder of reference implementations and
-- copies from it constantly; doing that by hand means leaving the problem, finding the
-- file, remembering which part of it matters, and pasting it at the right indentation.
--
-- The library is just source files, so nothing has to be maintained in a special
-- format: the pieces worth copying are marked in place with a pair of comments,
--
--     // TUNALIB: binary exp start
--     ll bexp(ll n, ll m) { … }
--     // TUNALIB: binary exp end
--
-- and everything around them (the includes, the `main`, the scratch code they were
-- tested with) is ignored. The marker word is `library.marker`, and the guards are
-- recognized anywhere in a line, so the comment syntax of any language works.
--
-- One picker holds the whole library: every snippet, and every file with no guards in it
-- whole, listed by name beside its file. Typing narrows it, matching what you remember
-- of a snippet, its name, its file ("it's in fenwick.cpp") or a piece of its code
-- ("the one with `parent[`"), and the code under the cursor is previewed in a pane that
-- can be entered and read like a buffer before it is inserted. Only files with the
-- current file's extension are listed (a C++ problem gets the C++ library), and a snippet
-- is pasted below the cursor re-indented to the current line.

local utils = require("tuna.utils")
local config = require("tuna.config")

local M = {}

---One insertable piece of the library: a guarded snippet, or a whole file with no guards.
---@class tuna.Snippet
---@field name string
---@field lines string[]
---@field first integer the line of its file it starts on
---@field file string? its file, relative to the library root
---@field path string? its file's absolute path
---@field whole boolean? a whole file rather than a guarded snippet
---@field body string? its code, lowercased with whitespace removed, for searching

--------------------------------------------------------------------------------
-- Scanning
--------------------------------------------------------------------------------

---The configured library directories, expanded.
---@param cfg table
---@return string[]
local function roots(cfg)
    local spec = (cfg.library or {}).path
    if not spec then
        return {}
    end
    local out = {}
    for _, p in ipairs(type(spec) == "table" and spec or { spec }) do
        local dir = utils.normalize_path(utils.expand_home(p))
        if utils.directory_exists(dir) then
            out[#out + 1] = dir
        end
    end
    return out
end

---Every library file with extension `ext`, as { path, rel } sorted by `rel`.
---@param cfg table
---@param ext string
---@return { path: string, rel: string }[]
function M.files(cfg, ext)
    local lib = cfg.library or {}
    local out = {}
    for _, root in ipairs(roots(cfg)) do
        local ok = pcall(function()
            -- Dot-directories and dotfiles are never library code, at any depth: `vim.fs.dir`
            -- hands `skip` and the loop paths relative to the root, so each is judged by its
            -- own name.
            local function visible(rel)
                return vim.fs.basename(rel):sub(1, 1) ~= "."
            end
            for name, typ in vim.fs.dir(root, { depth = lib.depth or 3, skip = visible }) do
                if typ == "file" and visible(name) and name:match("%.([^./]+)$") == ext then
                    out[#out + 1] = { path = root .. "/" .. name, rel = name }
                end
            end
        end)
        if not ok then
            utils.notify("library: could not read '" .. root .. "'.", "WARN")
        end
    end
    table.sort(out, function(a, b)
        return a.rel < b.rel
    end)
    return out
end

---Parse the guarded snippets out of a file's lines.
---
---A guard is any line containing `<marker>: <name> start` / `<marker>: <name> end`, so
---it works whatever the language's comment syntax is. The guard lines themselves are
---not part of the snippet. An unclosed guard is reported rather than silently swallowed
---— a typo'd `end` would otherwise make a snippet mysteriously reach to end of file.
---@param lines string[]
---@param marker string
---@return tuna.Snippet[] snippets, string? warning
function M.parse(lines, marker)
    local open_pat = marker .. ":%s*(.-)%s+start%s*$"
    local close_pat = marker .. ":%s*(.-)%s+end%s*$"
    local out, current, unclosed = {}, nil, nil
    for i, line in ipairs(lines) do
        local trimmed = vim.trim(line)
        local opened = trimmed:match(open_pat)
        local closed = trimmed:match(close_pat)
        if closed and current and current.name == closed then
            out[#out + 1] = current
            current = nil
        elseif opened then
            if current then
                unclosed = current.name -- a new guard before the previous one closed
            end
            current = { name = opened, lines = {}, first = i + 1 }
        elseif current then
            current.lines[#current.lines + 1] = line
        end
    end
    if current then
        unclosed = current.name
    end
    return out, unclosed and ("unclosed '" .. unclosed .. "' guard") or nil
end

---The snippets of one library file, warning about an unclosed guard in it. The picker reads
---every file once, when it opens, so the warning comes once however often it is searched.
---@param file { path: string, rel: string }
---@param cfg table
---@return tuna.Snippet[]
local function snippets_of(file, cfg)
    local content = utils.read_file(file.path)
    if not content then
        return {}
    end
    local snips, warning = M.parse(vim.split(content, "\n", { plain = true }), (cfg.library or {}).marker or "TUNALIB")
    if warning then
        utils.notify(("library: %s in %s."):format(warning, file.rel), "WARN")
    end
    for _, s in ipairs(snips) do
        s.file = file.rel
        s.path = file.path
    end
    return snips
end

--------------------------------------------------------------------------------
-- Insertion
--------------------------------------------------------------------------------

---Strip the snippet's own indentation and re-apply the current line's, so a helper
---stored at top level lands correctly inside a function (and vice versa). Blank lines
---stay blank rather than collecting trailing whitespace.
---@param lines string[]
---@param indent string
---@return string[]
local function reindent(lines, indent)
    local base
    for _, l in ipairs(lines) do
        if vim.trim(l) ~= "" then
            local lead = l:match("^[ \t]*")
            if not base or #lead < #base then
                base = lead
            end
        end
    end
    base = base or ""
    local out = {}
    for i, l in ipairs(lines) do
        if vim.trim(l) == "" then
            out[i] = ""
        else
            out[i] = indent .. (l:sub(1, #base) == base and l:sub(#base + 1) or vim.trim(l))
        end
    end
    return out
end

---Insert a snippet below the cursor and leave the cursor on its first line.
---@param snippet tuna.Snippet
---@param bufnr integer
function M.insert(snippet, bufnr)
    local win = vim.fn.bufwinid(bufnr)
    local row = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or vim.api.nvim_buf_line_count(bufnr)
    local current = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    local indent = current:match("^[ \t]*") or ""

    -- Trim blank lines at either end: where the snippet sits is the caller's business.
    local lines = vim.deepcopy(snippet.lines)
    while lines[1] and vim.trim(lines[1]) == "" do
        table.remove(lines, 1)
    end
    while lines[#lines] and vim.trim(lines[#lines]) == "" do
        table.remove(lines)
    end
    if #lines == 0 then
        utils.notify("library: '" .. snippet.name .. "' is empty.", "WARN")
        return
    end

    vim.api.nvim_buf_set_lines(bufnr, row, row, false, reindent(lines, indent))
    if win ~= -1 then
        pcall(vim.api.nvim_win_set_cursor, win, { row + 1, #indent })
    end
    utils.notify(
        ("library: inserted '%s'%s (%d line%s)."):format(
            snippet.name,
            snippet.file and (" from " .. snippet.file) or "",
            #lines,
            #lines == 1 and "" or "s"
        ),
        "INFO"
    )
end

--------------------------------------------------------------------------------
-- Pickers
--------------------------------------------------------------------------------

-- How wide the picker is. Height is left to the menu: it caps the list and gives the
-- rest to the preview, so a library of thirty files still shows a screenful of code.
local PREVIEW_WIDTH = 0.6

---The picker's preview: as wide as `PREVIEW_WIDTH` of the editor, coloured as the
---language of `ext`.
---@param ext string extension whose language colours the preview
---@param content fun(idx: integer): table
---@return table preview
local function preview_opts(ext, content)
    local w = utils.get_ui_size()
    return {
        width = math.floor(w * PREVIEW_WIDTH),
        filetype = vim.filetype.match({ filename = "x." .. ext }) or ext,
        content = content,
    }
end

---The current file's extension — the library is language-specific, so a C++ problem
---never offers Python snippets.
---@param bufnr integer
---@return string?
local function buffer_ext(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    local ext = name ~= "" and vim.fn.fnamemodify(name, ":e") or ""
    return ext ~= "" and ext or nil
end

---Resolve the config and the buffer's extension, and check the library is configured.
---@param bufnr integer
---@return table? cfg, string? ext
local function picker_context(bufnr)
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    local ext = buffer_ext(bufnr)
    if not ext then
        utils.notify("library: this buffer has no file extension, so no library to match it.", "WARN")
        return nil
    end
    if #roots(cfg) == 0 then
        utils.notify("library: set `library.path` to your snippet directory first.", "WARN")
        return nil
    end
    return cfg, ext
end

---Everything insertable in the library for `ext`, sorted by name: every guarded snippet,
---and every file with no guards as a single whole-file entry, so a library that hasn't
---been marked up yet can still be picked from. Each entry carries its `body` for the
---search.
---@param cfg table
---@param ext string
---@return tuna.Snippet[]
local function catalogue(cfg, ext)
    local all = {}
    for _, f in ipairs(M.files(cfg, ext)) do
        local snips = snippets_of(f, cfg)
        if #snips > 0 then
            vim.list_extend(all, snips)
        else
            all[#all + 1] = {
                name = f.rel,
                file = f.rel,
                path = f.path,
                first = 1,
                whole = true,
                lines = vim.split(utils.read_file(f.path) or "", "\n", { plain = true }),
            }
        end
    end
    -- Lowercase and without whitespace, so a search for code matches however it was
    -- spaced: `bit[idx]+=delta` finds a line written with spaces around the operators.
    for _, e in ipairs(all) do
        e.body = table.concat(e.lines, "\n"):lower():gsub("%s+", "")
    end
    table.sort(all, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.file < b.file
    end)
    return all
end

---The entries a search shows, in order, as indices into `all`. Nothing typed shows them
---all. Otherwise the entries whose name and file fuzzy-match come first, best match
---first, the words typed matched in any order; then the entries whose code contains what
---was typed. Fuzzy matching stops at the name and file: a body is thousands of characters,
---in which nearly anything typed is scattered somewhere, so it would match every entry.
---@param all tuna.Snippet[]
---@param query string
---@return integer[]
local function rank(all, query)
    local out = {}
    local needle = query:lower():gsub("%s+", "")
    if needle == "" then
        for i = 1, #all do
            out[i] = i
        end
        return out
    end
    local keyed = {}
    for i, e in ipairs(all) do
        keyed[i] = { text = e.name .. " " .. e.file, idx = i }
    end
    local named = {}
    for _, k in ipairs(vim.fn.matchfuzzy(keyed, vim.trim(query:lower()), { key = "text" })) do
        out[#out + 1] = k.idx
        named[k.idx] = true
    end
    for i, e in ipairs(all) do
        if not named[i] and e.body:find(needle, 1, true) then
            out[#out + 1] = i
        end
    end
    return out
end

---`:Tuna lib` — search the library and insert what is picked.
---@param bufnr integer? defaults to the current buffer
function M.open(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local restore = vim.api.nvim_get_current_win()
    local cfg, ext = picker_context(bufnr)
    if not (cfg and ext) then
        return
    end

    local all = catalogue(cfg, ext)
    if #all == 0 then
        utils.notify("library: no ." .. ext .. " files in the library.", "WARN")
        return
    end

    -- The file is shown after the name, aligned, so the list reads as a snippet index
    -- rather than a list of paths. A whole-file entry is already named after its file.
    local width = 0
    for _, e in ipairs(all) do
        width = math.max(width, #e.name)
    end
    local items = {}
    for i, e in ipairs(all) do
        items[i] = ("%-" .. width .. "s   %s"):format(e.name, e.whole and "(whole file)" or e.file)
    end

    require("tuna.ui.widgets").menu(
        items,
        "Library",
        function(idx)
            M.insert(all[idx], bufnr)
        end,
        restore,
        nil,
        preview_opts(ext, function(idx)
            local e = all[idx]
            return { title = e.whole and e.file or (e.file .. ":" .. e.first), lines = e.lines }
        end),
        nil,
        nil,
        function(query)
            return rank(all, query)
        end
    )
end

M._test = { rank = rank, catalogue = catalogue }

return M
