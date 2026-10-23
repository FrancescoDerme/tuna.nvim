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
-- recognized anywhere in a line, so the comment syntax of any language works. The comment
-- block right under a start guard is the snippet's notes: what it does and how it is
-- called, and from a line starting `Complexity:` to the block's end, its complexity.
-- They are read in the picker and never inserted.
--
-- One picker holds the whole library: every snippet, and every file with no guards in it
-- whole, listed by name. Typing narrows it, matching what you remember
-- of a snippet, its name, its file ("it's in fenwick.cpp"), its notes ("range query") or a
-- piece of its code ("the one with `parent[`"), and the notes, complexity and code under
-- the cursor are shown beside the list, in panes that can be entered and read like a buffer
-- before it is inserted. Only files with the current file's extension are listed (a C++ problem
-- gets the C++ library), and a snippet is pasted below the cursor re-indented to the
-- current line.

local utils = require("tuna.utils")
local config = require("tuna.config")

local M = {}

---One insertable piece of the library: a guarded snippet, or a whole file with no guards.
---@class tuna.Snippet
---@field name string
---@field lines string[] its code, without its notes
---@field first integer the line of its file its code starts on
---@field notes string[] the comment block under its start guard, without the comment leader
---  and without its complexity
---@field complexity string[] the notes from the line starting `Complexity:` to their end, the
---  label left out
---@field file string? its file, relative to the library root
---@field path string? its file's absolute path
---@field whole boolean? a whole file rather than a guarded snippet
---@field body string? its code, lowercased with whitespace removed, for searching
---@field said string? its notes and complexity, the same way

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

---Split a snippet's notes at the line starting `Complexity:`, which with every line after it
---is its complexity, without the label: a complexity a formatter wrapped onto several lines is
---still whole, and the picker's pane that shows it is titled with the label already.
---@param snippet table
local function split_complexity(snippet)
    snippet.complexity = {}
    for i, note in ipairs(snippet.notes) do
        if note:find("^Complexity:") then
            snippet.complexity = vim.list_slice(snippet.notes, i)
            snippet.complexity[1] = note:gsub("^Complexity:%s*", "")
            snippet.notes = vim.list_slice(snippet.notes, 1, i - 1)
            return
        end
    end
end

---Parse the guarded snippets out of a file's lines.
---
---A guard is any line containing `<marker>: <name> start` / `<marker>: <name> end`, so
---it works whatever the language's comment syntax is. The guard lines themselves are
---not part of the snippet. An unclosed guard is reported rather than silently swallowed
---— a typo'd `end` would otherwise make a snippet mysteriously reach to end of file.
---
---The lines right under a start guard that begin with the guard's own comment leader (what
---comes before the marker on its line, `//`, `#`, `--`) are the snippet's notes, up to the
---first line that is not one: a blank line ends them.
---@param lines string[]
---@param marker string
---@return tuna.Snippet[] snippets, string? warning
function M.parse(lines, marker)
    local open_pat = "^(.-)" .. marker .. ":%s*(.-)%s+start%s*$"
    local close_pat = marker .. ":%s*(.-)%s+end%s*$"
    local out, current, unclosed = {}, nil, nil
    -- The comment leader of the open guard while its notes are being read, nil once they end.
    local leader
    for i, line in ipairs(lines) do
        local trimmed = vim.trim(line)
        local lead, opened = trimmed:match(open_pat)
        local closed = trimmed:match(close_pat)
        if closed and current and current.name == closed then
            split_complexity(current)
            out[#out + 1] = current
            current = nil
        elseif opened then
            if current then
                unclosed = current.name -- a new guard before the previous one closed
            end
            current = { name = opened, lines = {}, first = i + 1, notes = {} }
            leader = vim.trim(lead)
            leader = leader ~= "" and leader or nil
        elseif current then
            if leader and trimmed:sub(1, #leader) == leader then
                current.notes[#current.notes + 1] = (trimmed:sub(#leader + 1):gsub("^ ", ""))
                current.first = i + 1
            else
                leader = nil
                current.lines[#current.lines + 1] = line
            end
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

---What the picker's panes show for `e`: its notes, its complexity and its code.
---@param e tuna.Snippet
---@return table[]
local function panes_of(e)
    return {
        { lines = e.notes },
        { lines = e.complexity },
        { title = e.whole and e.file or (e.file .. ":" .. e.first), lines = e.lines },
    }
end

---The picker's panes beside the list: the notes, the complexity and the code, coloured as the
---language of `ext`, each following the entry under the cursor. The complexity has a pane of
---its own, so it is in the same place for every entry and long notes never push it out of
---view. The notes and complexity panes are as tall as the longest of theirs in the library,
---so they do not jump from entry to entry, and neither is drawn when nothing in the library
---has one. The picker's size is `library.width`/`height`.
---@param ext string extension whose language colours the code
---@param all tuna.Snippet[]
---@param cfg table
---@return table preview
local function preview_opts(ext, all, cfg)
    local cols, rows = utils.get_ui_size()
    return {
        beside = {
            width = math.floor(cols * cfg.library.width + 0.5),
            height = math.floor(rows * cfg.library.height + 0.5),
        },
        panes = {
            { title = "Notes", fit = true, wrap = true },
            { title = "Complexity", fit = true, wrap = true, readout = true },
            { filetype = vim.filetype.match({ filename = "x." .. ext }) or ext },
        },
        content = function(idx)
            return panes_of(all[idx])
        end,
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
                notes = {},
                complexity = {},
                lines = vim.split(utils.read_file(f.path) or "", "\n", { plain = true }),
            }
        end
    end
    -- Lowercase and without whitespace, so a search for code matches however it was
    -- spaced: `bit[idx]+=delta` finds a line written with spaces around the operators, and
    -- `range query` notes wrapped between the two words.
    local function key(lines)
        return (table.concat(lines, "\n"):lower():gsub("%s+", ""))
    end
    for _, e in ipairs(all) do
        e.body = key(e.lines)
        e.said = key(vim.list_extend(vim.list_extend({}, e.notes), e.complexity))
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
---first, the words typed matched in any order; then the entries whose notes contain what
---was typed; then those whose code does. Fuzzy matching stops at the name and file: a
---body is thousands of characters, in which nearly anything typed is scattered somewhere,
---so it would match every entry.
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
    local taken = {}
    for _, k in ipairs(vim.fn.matchfuzzy(keyed, vim.trim(query:lower()), { key = "text" })) do
        out[#out + 1] = k.idx
        taken[k.idx] = true
    end
    for _, field in ipairs({ "said", "body" }) do
        for i, e in ipairs(all) do
            if not taken[i] and e[field]:find(needle, 1, true) then
                out[#out + 1] = i
                taken[i] = true
            end
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

    -- Listed by name alone, so the list stays narrow beside the panes: the code pane's title
    -- names the file, a whole-file entry is named after its file, and a search still matches
    -- file names.
    local items = vim.tbl_map(function(e)
        return e.name
    end, all)

    require("tuna.ui.widgets").menu(
        items,
        "Library",
        function(idx)
            M.insert(all[idx], bufnr)
        end,
        restore,
        nil,
        preview_opts(ext, all, cfg),
        nil,
        nil,
        function(query)
            return rank(all, query)
        end
    )
end

M._test = { rank = rank, catalogue = catalogue }

return M
