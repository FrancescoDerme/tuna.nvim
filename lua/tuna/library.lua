-- lua/tuna/library.lua
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
-- Two ways in, because two things happen in practice — you remember *the file*
-- ("it's in fenwick.cpp"), or you remember *the snippet* ("I need the 2D one"):
--
--   * `:Tuna lib`         — pick a file, then a snippet inside it
--   * `:Tuna lib snippet` — pick straight from every snippet in the library
--
-- Both list only files with the current file's extension (a C++ problem gets the C++
-- library), preview the code under the cursor before it is inserted, and paste it
-- below the cursor re-indented to the current line.

local utils = require("tuna.utils")
local config = require("tuna.config")

local M = {}

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
        local dir = vim.fs.normalize(vim.fn.expand(p))
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
            for name, typ in
                vim.fs.dir(root, {
                    depth = lib.depth or 3,
                    skip = function(d)
                        return d:sub(1, 1) ~= "."
                    end,
                })
            do
                if typ == "file" and name:sub(1, 1) ~= "." and name:match("%.([^./]+)$") == ext then
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
---@return { name: string, lines: string[], first: integer }[] snippets, string? warning
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

---The snippets of one library file.
---@param file { path: string, rel: string }
---@param cfg table
---@return { name: string, lines: string[], first: integer }[]
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
---@param snippet { name: string, lines: string[], file: string? }
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

-- How wide the pickers are. Height is left to the menu: it caps the list and gives the
-- rest to the preview, so a library of thirty files still shows a screenful of code.
local PREVIEW_WIDTH = 0.6

---Menu geometry shared by both pickers. `filetype` is the default colouring for every
---row's content, so only a pane showing something *other* than code (the snippet-name
---list) has to say otherwise.
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

---Choose among a file's snippets, then insert.
---@param snips table[]
---@param bufnr integer
---@param restore integer?
---@param label fun(s: table): string
local function choose_snippet(snips, bufnr, restore, label)
    local items = {}
    for i, s in ipairs(snips) do
        items[i] = label(s)
    end
    require("tuna.widgets").menu(
        items,
        "Snippet",
        function(idx)
            M.insert(snips[idx], bufnr)
        end,
        restore,
        nil,
        preview_opts(buffer_ext(bufnr) or "txt", function(idx)
            local s = snips[idx]
            return s and { title = s.file .. ":" .. s.first, lines = s.lines } or { lines = {} }
        end)
    )
end

---`:Tuna lib` — pick a library file, then a snippet inside it.
---@param bufnr integer? defaults to the current buffer
function M.browse(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    local restore = vim.api.nvim_get_current_win()

    local ext = buffer_ext(bufnr)
    if not ext then
        utils.notify("library: this buffer has no file extension, so no library to match it.", "WARN")
        return
    end
    if #roots(cfg) == 0 then
        utils.notify("library: set `library.path` to your snippet directory first.", "WARN")
        return
    end

    local files = M.files(cfg, ext)
    if #files == 0 then
        utils.notify("library: no ." .. ext .. " files in the library.", "WARN")
        return
    end

    local items = {}
    for i, f in ipairs(files) do
        items[i] = f.rel
    end
    require("tuna.widgets").menu(
        items,
        "Library",
        function(idx)
            local file = files[idx]
            local snips = snippets_of(file, cfg)
            if #snips == 0 then
                -- Nothing is marked up, so there is nothing to pick from — but the file is
                -- still a perfectly good thing to copy whole, which is what the library was
                -- before any guards were added to it.
                local content = utils.read_file(file.path) or ""
                choose_snippet(
                    {
                        {
                            name = file.rel,
                            file = file.rel,
                            path = file.path,
                            first = 1,
                            lines = vim.split(content, "\n", { plain = true }),
                        },
                    },
                    bufnr,
                    restore,
                    function(s)
                        return s.name .. "   (whole file — no guards in it)"
                    end
                )
                return
            end
            choose_snippet(snips, bufnr, restore, function(s)
                return s.name
            end)
        end,
        restore,
        nil,
        preview_opts(ext, function(idx)
            local f = files[idx]
            if not f then
                return { lines = {} }
            end
            -- Preview the file's snippet names when it has any, the file itself when not:
            -- the question at this step is "is what I want in here?".
            local snips = snippets_of(f, cfg)
            if #snips == 0 then
                return { title = f.rel, lines = vim.split(utils.read_file(f.path) or "", "\n", { plain = true }) }
            end
            local lines = {}
            for _, s in ipairs(snips) do
                lines[#lines + 1] = ("%s   (%d lines)"):format(s.name, #s.lines)
            end
            return { title = f.rel .. " — snippets", lines = lines, filetype = "text" }
        end)
    )
end

---Everything insertable in the library for `ext`, sorted by name: every guarded
---snippet, and — when `whole_files` is set — every file with no guards as a single
---whole-file entry, so a library that hasn't been marked up yet is still searchable by
---file name.
---@param cfg table
---@param ext string
---@param whole_files boolean? include unguarded files as one entry each
---@return table[] entries
local function catalogue(cfg, ext, whole_files)
    local all = {}
    for _, f in ipairs(M.files(cfg, ext)) do
        local snips = snippets_of(f, cfg)
        if #snips > 0 then
            vim.list_extend(all, snips)
        elseif whole_files then
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
    table.sort(all, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.file < b.file
    end)
    return all
end

---The shared preamble of the flat pickers: resolve the config, the buffer's extension
---and check the library is configured at all.
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

---`:Tuna lib snippet` — pick straight from every snippet in the library.
---@param bufnr integer? defaults to the current buffer
function M.pick(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local restore = vim.api.nvim_get_current_win()
    local cfg, ext = picker_context(bufnr)
    if not cfg then
        return
    end

    local all = catalogue(cfg, ext)
    if #all == 0 then
        utils.notify(
            ("library: no %s: … start/end guards in the .%s files, use ':Tuna lib' to browse them whole."):format(
                (cfg.library or {}).marker or "TUNALIB",
                ext
            ),
            "WARN"
        )
        return
    end

    -- The file is shown after the name, aligned, so the list reads as a snippet index
    -- rather than a list of paths.
    local width = 0
    for _, s in ipairs(all) do
        width = math.max(width, #s.name)
    end
    local items = {}
    for i, s in ipairs(all) do
        items[i] = ("%-" .. width .. "s   %s"):format(s.name, s.file)
    end

    require("tuna.widgets").menu(
        items,
        "Snippets",
        function(idx)
            M.insert(all[idx], bufnr)
        end,
        restore,
        nil,
        preview_opts(ext, function(idx)
            local s = all[idx]
            return s and { title = s.file .. ":" .. s.first, lines = s.lines } or { lines = {} }
        end)
    )
end

---`:Tuna lib search` — the same catalogue in **telescope**, when the user has it.
---
---The reason to reach for telescope here is *typing*: the native pickers are lists you
---move through, while this one narrows as you type, and it matches a snippet's **name,
---its file name and its code** at once (all three go into the entry's `ordinal`). So
---"fenwick 2d" and "sync_with_stdio" both find their way to something, without having
---to remember which file it lives in. Files with no guards are included whole, so the
---search covers a library that has not been marked up yet.
---
---Selecting inserts through the same `M.insert` as the other two routes.
---@param bufnr integer? defaults to the current buffer
function M.search(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local ok, pickers = pcall(require, "telescope.pickers")
    if not ok then
        utils.notify("library: telescope isn't installed — ':Tuna lib' and ':Tuna lib snippet' need nothing.", "WARN")
        return
    end
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local previewers = require("telescope.previewers")
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    local cfg, ext = picker_context(bufnr)
    if not cfg then
        return
    end

    local all = catalogue(cfg, ext, true)
    if #all == 0 then
        utils.notify("library: no ." .. ext .. " files in the library.", "WARN")
        return
    end
    local filetype = vim.filetype.match({ filename = "x." .. ext }) or ext
    -- Whitespace-free lowercase body, so the code tier matches how one types a search:
    -- `bit[idx]+=delta` finds a line written with spaces around the operators.
    for _, s in ipairs(all) do
        s.body = table.concat(s.lines, "\n"):lower():gsub("%s+", "")
    end

    local width = 0
    for _, s in ipairs(all) do
        width = math.max(width, #s.name)
    end

    pickers
        .new({}, {
            prompt_title = "Tuna library (." .. ext .. ")",
            -- Two tiers, rebuilt on every keystroke. Fuzzy matching runs over
            -- `name + file` only: feeding whole file bodies to the matcher does not
            -- work — every entry then carries thousands of characters, the length
            -- penalty swamps the signal, and typing a snippet's own name lands on
            -- something else (measured: "bexp" selected a Fenwick tree). An entry whose
            -- *code* contains what was typed has the prompt appended to its ordinal
            -- instead, which keeps it in the list while its greater length ranks it
            -- below the name matches. So: type a name to get that snippet, type an
            -- identifier to find the code that uses it.
            finder = finders.new_dynamic({
                fn = function(prompt)
                    local needle = (prompt or ""):lower():gsub("%s+", "")
                    local out = {}
                    for _, s in ipairs(all) do
                        out[#out + 1] = {
                            snippet = s,
                            prompt = prompt or "",
                            code_hit = needle ~= "" and s.body:find(needle, 1, true) ~= nil,
                        }
                    end
                    return out
                end,
                entry_maker = function(item)
                    local s = item.snippet
                    -- A whole-file entry is already named after its file, so say
                    -- "(whole file)" instead of repeating the name.
                    local right = s.whole and "(whole file)" or s.file
                    local ordinal = s.name .. " " .. s.file
                    if item.code_hit then
                        ordinal = ordinal .. " " .. item.prompt
                    end
                    return {
                        value = s,
                        display = ("%-" .. width .. "s   %s"):format(s.name, right),
                        ordinal = ordinal,
                    }
                end,
            }),
            sorter = conf.generic_sorter({}),
            previewer = previewers.new_buffer_previewer({
                title = "Snippet",
                define_preview = function(self, entry)
                    vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, entry.value.lines)
                    -- Telescope's own highlighter when it's there (treesitter-aware),
                    -- plain syntax otherwise; either way a preview must not fire
                    -- FileType autocmds on a throwaway buffer.
                    local hok, putils = pcall(require, "telescope.previewers.utils")
                    if hok then
                        pcall(putils.highlighter, self.state.bufnr, filetype)
                    else
                        pcall(function()
                            vim.bo[self.state.bufnr].syntax = filetype
                        end)
                    end
                end,
            }),
            attach_mappings = function(prompt_bufnr)
                actions.select_default:replace(function()
                    local entry = action_state.get_selected_entry()
                    actions.close(prompt_bufnr)
                    if entry then
                        M.insert(entry.value, bufnr)
                    end
                end)
                return true
            end,
        })
        :find()
end

return M
