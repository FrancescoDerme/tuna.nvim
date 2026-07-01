-- lua/tuna/utils.lua
--
-- Foundation module: string-modifier evaluation, filesystem helpers and
-- notifications. Everything else in tuna depends on this, so it avoids
-- depending on any other tuna module.
--
-- A note on `vim.uv`: this is Neovim's binding to libuv, the same async
-- event loop Node.js uses. We prefer it over the older `vim.loop` alias and
-- over blocking Lua `io.*` calls. For simple synchronous file reads/writes the
-- `fs_*` functions are used without a callback, which runs them synchronously.

local M = {}

---Show a tuna notification.
---@param msg string message to display
---@param level? string|integer a `vim.log.levels` value, or its name ("INFO", "WARN", "ERROR", ...); defaults to ERROR
function M.notify(msg, level)
    if type(level) == "string" then
        level = vim.log.levels[level]
    end
    vim.notify("Tuna: " .. msg, level or vim.log.levels.ERROR, { title = "Tuna" })
end

---Remap a floating window's border highlight so the border keeps the configured
---`hl` foreground (the coloured line) but takes the *float's own* background —
---i.e. `NormalFloat`'s bg. This makes the border ring share the interior fill:
---there's no seam between border and content, so the float reads as one solid
---panel whose corners the rounded glyphs sit on. (A terminal cell can't be split,
---so the fill can't literally be rounded; matching the fill is the closest look.)
---The derived group is (re)computed each call so it tracks colourscheme changes.
---Setting `winhighlight` is the API equivalent of competitest's nui
---`border.highlight` option.
---@param winid integer
---@param hl string? highlight group whose foreground is used for the border
function M.set_border_highlight(winid, hl)
    hl = hl or "FloatBorder"
    local border = vim.api.nvim_get_hl(0, { name = hl, link = false })
    local float = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    vim.api.nvim_set_hl(0, "TunaFloatBorder", {
        fg = border.fg,
        bg = float.bg or normal.bg,
        sp = border.sp,
        bold = border.bold,
        italic = border.italic,
    })
    vim.wo[winid].winhighlight = "FloatBorder:TunaFloatBorder"
end

---------------- STRING MODIFIERS ----------------
--
-- A "modifier" is a `$(NAME)` placeholder inside a string that gets replaced
-- with a computed value. They appear in compile/run commands and in testcase
-- file-name formats. `$()` (empty name) is an escape that inserts a literal `$`.

---A modifier replacement: either a literal string, or a function that receives
---the evaluation argument (e.g. a filepath) and returns the replacement string.
---@alias tuna.Modifier string | fun(arg: any?): string
---@alias tuna.Modifiers table<string, tuna.Modifier>

---Replace `$(NAME)` modifiers in `str` using the given `modifiers` table.
---
---Implemented as a small state machine scanning the string once:
---  * `mod_start ==  0` → idle, copying characters through
---  * `mod_start == -1` → just saw a `$`, expecting `(`
---  * `mod_start >   0` → inside `$(...)`, position of the opening `(`
---
---Returns `nil` (after notifying) on a malformed string or an unknown modifier,
---so callers can treat formatting failure as recoverable.
---@param str string string to evaluate
---@param modifiers tuna.Modifiers
---@param argument any? argument passed to function modifiers
---@return string? # evaluated string, or `nil` on failure
function M.format_modifiers(str, modifiers, argument)
    local out = {}
    local mod_start = 0

    for i = 1, #str do
        local c = str:sub(i, i)
        if mod_start == -1 then -- a `$` was just seen, an opening `(` must follow
            if c == "(" then
                mod_start = i
            else
                M.notify("format_modifiers: '$' not followed by '(' in:\n" .. str)
                return nil
            end
        elseif mod_start == 0 then
            if c == "$" then
                mod_start = -1
            else
                table.insert(out, c)
            end
        elseif c == ")" then -- close the current modifier
            local name = str:sub(mod_start + 1, i - 1)
            local replacement = modifiers[name]
            if type(replacement) == "string" then
                table.insert(out, replacement)
            elseif type(replacement) == "function" then
                table.insert(out, replacement(argument))
            else
                M.notify("format_modifiers: unrecognized modifier $(" .. name .. ")")
                return nil
            end
            mod_start = 0
        end
        -- when inside a modifier and c ~= ")", the character is part of the name
    end

    return table.concat(out)
end

---File-format modifiers, evaluated against a file path. `$(TCNUM)` (testcase
---number) is supplied per-call by `eval_string`, not stored here.
---@type tuna.Modifiers
M.file_format_modifiers = {
    [""] = "$", -- $() inserts a literal dollar sign
    HOME = function()
        return vim.uv.os_homedir()
    end,
    FNAME = function(filepath)
        return vim.fn.fnamemodify(filepath, ":t")
    end,
    FNOEXT = function(filepath)
        return vim.fn.fnamemodify(filepath, ":t:r")
    end,
    FEXT = function(filepath)
        return vim.fn.fnamemodify(filepath, ":e")
    end,
    FABSPATH = function(filepath)
        return filepath
    end,
    ABSDIR = function(filepath)
        return vim.fn.fnamemodify(filepath, ":p:h")
    end,
}

---Evaluate a string containing file-format modifiers against a file path.
---@param filepath string absolute path the modifiers are computed from
---@param str string string to evaluate
---@param tcnum? integer|string testcase number for `$(TCNUM)`
---@return string? # evaluated string, or `nil` on failure
function M.eval_string(filepath, str, tcnum)
    -- Merge a fresh per-call TCNUM in rather than mutating the shared table, so
    -- evaluation has no hidden state between calls.
    local modifiers = vim.tbl_extend("force", M.file_format_modifiers, {
        TCNUM = tostring(tcnum or ""),
    })
    return M.format_modifiers(str, modifiers, filepath)
end

---Like `eval_string`, but resolves the file path from a buffer.
---@param bufnr integer buffer number
---@param str string string to evaluate
---@param tcnum? integer|string testcase number for `$(TCNUM)`
---@return string? # evaluated string, or `nil` on failure
function M.buf_eval_string(bufnr, str, tcnum)
    return M.eval_string(vim.api.nvim_buf_get_name(bufnr), str, tcnum)
end

---------------- FILESYSTEM ----------------

---@param path string
---@return boolean
function M.file_exists(path)
    local stat = vim.uv.fs_stat(path)
    return stat ~= nil and stat.type == "file"
end

---@param path string
---@return boolean
function M.directory_exists(path)
    local stat = vim.uv.fs_stat(path)
    return stat ~= nil and stat.type == "directory"
end

---Create `path` (and any missing parents) if it doesn't already exist.
---@param path string
---@return boolean # whether the directory exists after the call
function M.ensure_directory(path)
    if not path or path == "" then
        return false
    end
    if M.directory_exists(path) then
        return true
    end
    -- `mkdir(path, "p")` is the idiomatic "mkdir -p": create parents as needed.
    vim.fn.mkdir(path, "p")
    return M.directory_exists(path)
end

---Read a whole file as a string. By default CRLF is normalized to LF; pass
---`raw = true` for binary content (e.g. msgpack) that must not be transformed.
---@param path string
---@param raw? boolean read bytes verbatim, without CRLF normalization
---@return string? # file contents, or `nil` if the file can't be read
function M.read_file(path, raw)
    local fd = vim.uv.fs_open(path, "r", 438) -- 438 == 0o666
    if not fd then
        return nil
    end
    local stat = vim.uv.fs_fstat(fd)
    local content = stat and vim.uv.fs_read(fd, stat.size, 0) or nil
    vim.uv.fs_close(fd)
    if content and not raw then
        content = content:gsub("\r\n", "\n")
    end
    return content
end

---Write `content` to `path`, creating parent directories as needed.
---@param path string
---@param content string
---@return boolean ok, string? err
function M.write_file(path, content)
    M.ensure_directory(vim.fn.fnamemodify(path, ":h"))
    local fd, open_err = vim.uv.fs_open(path, "w", 420) -- 420 == 0o644
    if not fd then
        return false, open_err
    end
    vim.uv.fs_write(fd, content, 0)
    vim.uv.fs_close(fd)
    return true
end

---Delete a file.
---@param path string
---@return boolean # whether the file was removed
function M.delete_file(path)
    return vim.uv.fs_unlink(path) ~= nil
end

---Resolve `path` to an absolute path. Relative paths are taken against
---`base_dir` (defaulting to the cwd). Absolute paths are returned unchanged.
---@param path string
---@param base_dir? string
---@return string
function M.normalize_path(path, base_dir)
    if type(path) ~= "string" or path == "" then
        return base_dir or "."
    end
    if path:sub(1, 1) == "/" then
        return vim.fs.normalize(path)
    end
    return vim.fs.normalize(vim.fn.fnamemodify((base_dir or ".") .. "/" .. path, ":p"))
end

---------------- UI ----------------

---Usable editor size: columns, and rows excluding the command line and (when
---shown) the global statusline.
---@return integer width, integer height
function M.get_ui_size()
    local height = vim.o.lines - vim.o.cmdheight
    if vim.o.laststatus ~= 0 then
        height = height - 1
    end
    return vim.o.columns, height
end

return M
