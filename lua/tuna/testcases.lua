-- lua/tuna/testcases.lua
--
-- Reads and writes testcases. A "testcase table" (tctbl) maps a 0-based index
-- to `{ input = string?, output = string? }`. Three interchangeable storage
-- backends produce and consume that shape:
--
--   * `files`       — a pair of text files per testcase   (e.g. task_input0.txt)
--   * `single_file` — one msgpack-encoded file
--   * `directory`   — one sub-directory per testcase       (e.g. tests/0/input.txt)
--
-- Pure functions (`load`/`write`) take explicit paths and formats; the
-- `buf_*` wrappers derive those from a buffer's resolved config. The module-level
-- `buf_get_testcases` / `buf_write_testcases` dispatch to the configured backend
-- (with auto-detect fallback) so callers stay backend-agnostic.

local config = require("tuna.config")
local utils = require("tuna.utils")

local M = {
    files = {},
    single_file = {},
    directory = {},
}

---------------- SHARED HELPERS ----------------

---Split a format on the literal `$(TCNUM)` marker and evaluate the file-format
---modifiers in each part. The pieces around `$(TCNUM)` become the constant
---parts of a file/directory name.
---@param filepath string source file path, used to evaluate modifiers
---@param format string format string containing `$(TCNUM)`
---@return string[]? # evaluated parts, or `nil` on a malformed format
local function eval_format_parts(filepath, format)
    local parts = vim.split(format, "$(TCNUM)", { plain = true })
    for i, part in ipairs(parts) do
        local evaluated = utils.eval_string(filepath, part)
        if evaluated == nil then
            return nil
        end
        parts[i] = evaluated
    end
    return parts
end

---Build a concrete name for a testcase by joining `parts` with the number.
---@param parts string[]
---@param tcnum integer
---@return string
local function format_name(parts, tcnum)
    return table.concat(parts, tostring(tcnum))
end

---Normalize a file-format option (string or list of strings) to a list.
---@param fmt string|string[]
---@return string[]
local function normalize_formats(fmt)
    if type(fmt) == "table" then
        return fmt
    end
    return { fmt }
end

---Escape Lua pattern magic characters in `s`.
---@param s string
---@return string
local function escape_pattern(s)
    return (s:gsub("(%W)", "%%%1"))
end

---Build an anchored Lua pattern matching names produced from `parts`, capturing
---the testcase number(s) where `$(TCNUM)` was.
---@param parts string[]
---@return string
local function format_pattern(parts)
    local escaped = {}
    for i, part in ipairs(parts) do
        escaped[i] = escape_pattern(part)
    end
    return "^" .. table.concat(escaped, "(%d+)") .. "$"
end

---Match a name against a pattern, returning the testcase number. When a format
---contains several `$(TCNUM)` the captures must all agree.
---@param name string
---@param pattern string
---@return integer?
local function match_tcnum(name, pattern)
    local caps = { name:match(pattern) }
    if #caps == 0 then
        return nil
    end
    local value = caps[1]
    for _, c in ipairs(caps) do
        if c ~= value then
            return nil
        end
    end
    return tonumber(value)
end

---Build a matcher `fun(name) -> tcnum?` for a format's evaluated `parts`. A format
---with `$(TCNUM)` (≥2 parts) matches numbered names; a **numberless** format (one
---part, e.g. `out.txt`) names a single testcase and maps an exact match to index 0.
---@param parts string[]
---@return fun(name: string): integer?
local function make_matcher(parts)
    if #parts <= 1 then
        local exact = parts[1] or ""
        return function(name)
            return name == exact and 0 or nil
        end
    end
    local pattern = format_pattern(parts)
    return function(name)
        return match_tcnum(name, pattern)
    end
end

---Write `content` to `path`, or delete `path` when `content` is empty/nil.
---@param path string
---@param content string?
local function write_or_delete(path, content)
    if not content or content == "" then
        if utils.file_exists(path) then
            utils.delete_file(path)
        end
    else
        utils.write_file(path, content)
    end
end

---------------- FILES BACKEND (one input/output file per testcase) ----------------

---@param directory string testcase directory (with trailing slash)
---@param filepath string source file path
---@param input_format string
---@param output_format string
---@return table<integer, { input: string?, output: string? }>
---@param input_format string|string[] one format, or an ordered list; the first
---  format that discovers any testcase wins (see config docs for the rationale).
---@param output_format string|string[] paired with `input_format` by index
---Which of the configured format pairs this directory is *actually* using: the first
---one that matches a file already there, else the first configured (canonical) pair.
---
---Both loading and writing go through this, so a testcase added to a folder whose
---testcases are named by a fallback format (the shared, un-prefixed `input<N>.txt` a
---download or another solution wrote) joins that set instead of starting a second,
---source-named one beside it — which, since the first format to match anything wins
---on load, would have hidden every testcase already there.
---@param directory string
---@param filepath string
---@param input_format string|string[]
---@param output_format string|string[]
---@return string[]? in_parts, string[]? out_parts
function M.files.active_parts(directory, filepath, input_format, output_format)
    local in_formats = normalize_formats(input_format)
    local out_formats = normalize_formats(output_format)

    local entries = {}
    if utils.directory_exists(directory) then
        for name, type_ in vim.fs.dir(directory) do
            if type_ == "file" then
                entries[#entries + 1] = name
            end
        end
    end

    local first_in, first_out
    for i, in_fmt in ipairs(in_formats) do
        local in_parts = eval_format_parts(filepath, in_fmt)
        local out_parts = eval_format_parts(filepath, out_formats[i] or out_formats[1])
        if in_parts and out_parts then
            first_in = first_in or in_parts
            first_out = first_out or out_parts
            local match_in = make_matcher(in_parts)
            local match_out = make_matcher(out_parts)
            for _, name in ipairs(entries) do
                if match_in(name) or match_out(name) then
                    return in_parts, out_parts
                end
            end
        end
    end
    return first_in, first_out
end

function M.files.load(directory, filepath, input_format, output_format)
    if not utils.directory_exists(directory) then
        return {}
    end
    local in_parts, out_parts = M.files.active_parts(directory, filepath, input_format, output_format)
    if not (in_parts and out_parts) then
        return {}
    end

    local match_in = make_matcher(in_parts)
    local match_out = make_matcher(out_parts)
    local tctbl = {}
    for name, type_ in vim.fs.dir(directory) do
        if type_ == "file" then
            -- A testcase may have only an input or only an output (an output with no
            -- matching input still runs — the solution is fed empty stdin).
            local tcnum = match_in(name)
            if tcnum then
                tctbl[tcnum] = tctbl[tcnum] or {}
                tctbl[tcnum].input = utils.read_file(directory .. name)
            else
                tcnum = match_out(name)
                if tcnum then
                    tctbl[tcnum] = tctbl[tcnum] or {}
                    tctbl[tcnum].output = utils.read_file(directory .. name)
                end
            end
        end
    end
    return tctbl
end

---@param directory string testcase directory (with trailing slash)
---@param tctbl table<integer, { input: string?, output: string? }>
---@param filepath string source file path
---@param input_format string
---@param output_format string
function M.files.write(directory, tctbl, filepath, input_format, output_format)
    -- Write with the format this directory already uses (the canonical first one when
    -- it holds no testcases yet), so a new testcase joins the set that is there rather
    -- than starting a rival one under another name.
    local in_parts, out_parts = M.files.active_parts(directory, filepath, input_format, output_format)
    if not in_parts or not out_parts then
        return
    end
    for tcnum, tc in pairs(tctbl) do
        write_or_delete(directory .. format_name(in_parts, tcnum), tc.input)
        write_or_delete(directory .. format_name(out_parts, tcnum), tc.output)
    end
end

---------------- SINGLE-FILE BACKEND (one msgpack file) ----------------

---@param path string single file path
---@return table<integer, { input: string?, output: string? }>
function M.single_file.load(path)
    -- raw read: msgpack is binary and must not have CRLF rewritten
    local content = utils.read_file(path, true)
    if not content then
        return {}
    end
    local ok, decoded = pcall(vim.mpack.decode, content)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return {}
end

---@param path string single file path
---@param tctbl table<integer, { input: string?, output: string? }>
function M.single_file.write(path, tctbl)
    -- drop empty inputs/outputs, then drop testcases that became empty
    for tcnum, tc in pairs(tctbl) do
        if tc.input == "" then
            tc.input = nil
        end
        if tc.output == "" then
            tc.output = nil
        end
        if not tc.input and not tc.output then
            tctbl[tcnum] = nil
        end
    end

    if next(tctbl) == nil then
        if utils.file_exists(path) then
            utils.delete_file(path)
        end
    else
        utils.write_file(path, vim.mpack.encode(tctbl))
    end
end

---------------- DIRECTORY BACKEND (one sub-directory per testcase) ----------------

---Resolve the directory format into a scan directory, a name pattern (capturing
---the testcase number) and the constant parts used to rebuild a directory name.
---Assumes the `$(TCNUM)` marker lives in the last path component.
---@param base_dir string testcase base directory (with trailing slash)
---@param filepath string source file path
---@param dir_format string e.g. "tests/$(TCNUM)"
---@return { scan_dir: string, pattern: string }? layout
local function resolve_directory_layout(base_dir, filepath, dir_format)
    local parts = eval_format_parts(filepath, dir_format)
    if not parts or #parts < 2 then
        return nil -- the format must contain $(TCNUM)
    end
    -- Split the prefix part at its last path separator: the leading portion is a
    -- real directory (joined onto base_dir and normalized), the trailing portion
    -- is a literal prefix on each testcase directory's name. Deriving this from
    -- the format string (not the normalized path) preserves the separator that
    -- distinguishes "tests/$(TCNUM)" (dirs named "0") from "tc$(TCNUM)" ("tc0").
    local name_prefix = parts[1]:match("[^/]*$")
    local format_dir = parts[1]:sub(1, #parts[1] - #name_prefix)
    local scan_dir = vim.fs.normalize(base_dir .. format_dir) .. "/"
    local suffix = table.concat(parts, "", 2)
    local pattern = "^" .. escape_pattern(name_prefix) .. "(%d+)" .. escape_pattern(suffix) .. "$"
    return { scan_dir = scan_dir, pattern = pattern }
end

---@param base_dir string testcase base directory (with trailing slash)
---@param filepath string source file path
---@param dir_format string
---@param input_name string input file name inside each testcase directory
---@param output_name string output file name inside each testcase directory
---@return table<integer, { input: string?, output: string? }>
function M.directory.load(base_dir, filepath, dir_format, input_name, output_name)
    local layout = resolve_directory_layout(base_dir, filepath, dir_format)
    if not layout then
        return {}
    end

    local tctbl = {}
    if not utils.directory_exists(layout.scan_dir) then
        return tctbl
    end
    for name, type_ in vim.fs.dir(layout.scan_dir) do
        if type_ == "directory" then
            local tcnum = match_tcnum(name, layout.pattern)
            if tcnum then
                local tcdir = layout.scan_dir .. name .. "/"
                tctbl[tcnum] = {
                    input = utils.read_file(tcdir .. input_name),
                    output = utils.read_file(tcdir .. output_name),
                }
            end
        end
    end
    return tctbl
end

---@param base_dir string testcase base directory (with trailing slash)
---@param tctbl table<integer, { input: string?, output: string? }>
---@param filepath string source file path
---@param dir_format string
---@param input_name string
---@param output_name string
function M.directory.write(base_dir, tctbl, filepath, dir_format, input_name, output_name)
    local parts = eval_format_parts(filepath, dir_format)
    if not parts then
        return
    end
    for tcnum, tc in pairs(tctbl) do
        local tcdir = vim.fs.normalize(base_dir .. format_name(parts, tcnum)) .. "/"
        local empty = (not tc.input or tc.input == "") and (not tc.output or tc.output == "")
        if empty then
            -- remove the testcase's files, and the directory itself if now empty
            write_or_delete(tcdir .. input_name, nil)
            write_or_delete(tcdir .. output_name, nil)
            if utils.directory_exists(tcdir) then
                pcall(vim.uv.fs_rmdir, (tcdir:gsub("/$", "")))
            end
        else
            utils.ensure_directory(tcdir)
            write_or_delete(tcdir .. input_name, tc.input)
            write_or_delete(tcdir .. output_name, tc.output)
        end
    end
end

---------------- BUFFER LAYER ----------------

---@private
---Paths already warned about, so the notice below is shown once per session.
---@type table<string, true>
local warned_shared = {}

---@private
---An absolute `testcases_directory` carrying no modifier is the *same* directory for
---every problem, and every storage backend names its files after the source
---(`$(FNOEXT)_input0.txt`, `tests/0`, …) — so two problems silently overwrite each
---other's testcases there. Say so once, with the fix, rather than letting the data
---go. A value coming from a directory's own `.tuna.lua` already scopes itself to that
---tree, so only a globally configured one is worth flagging.
---@param raw string the configured value
---@param expanded string the same value after modifier/`~` expansion
local function warn_if_shared(raw, expanded)
    if warned_shared[raw] or raw:find("$(", 1, true) or not utils.is_absolute(expanded) then
        return
    end
    if raw ~= (config.current_setup or config.defaults).testcases_directory then
        return -- a local config's value: scoped to its own tree by construction
    end
    warned_shared[raw] = true
    utils.notify(
        "testcases_directory '"
            .. raw
            .. "' is an absolute path with no per-problem component, so every problem stores its "
            .. "testcases there and overwrites the others'. Add a modifier, e.g. '"
            .. raw
            .. "/$(DIRNAME)'.",
        vim.log.levels.WARN
    )
end

---Absolute testcase base directory for a source file (with trailing slash).
---
---`testcases_directory` is evaluated for file modifiers — so `$(DIRNAME)`, `$(HOME)`,
---`$(CWD)`, `$(FNOEXT)`… can build a per-problem path — and the result is used as-is
---when it is absolute, joined onto the source's directory when it is not. competitest
---joined unconditionally, which made an absolute path unreachable and turned
---`~/cp/testcases` into a directory literally named `~` beside the source
---(competitest#78).
---@param source_dir string directory holding the source file
---@param filepath string source file path, which the modifiers are computed from
---@param cfg table resolved configuration
---@return string # absolute directory, with exactly one trailing slash
function M.tc_directory(source_dir, filepath, cfg)
    local raw = cfg.testcases_directory or "."
    local expanded = utils.eval_string(filepath, raw)
    if not expanded then
        utils.notify("testcases_directory: could not evaluate '" .. raw .. "'.", vim.log.levels.WARN)
        expanded = raw
    end
    expanded = vim.fs.normalize(expanded) -- expands a leading `~`
    warn_if_shared(raw, expanded)
    return (utils.normalize_path(expanded, source_dir):gsub("/*$", "")) .. "/"
end

---Absolute testcase base directory for a buffer (with trailing slash).
---@param bufnr integer
---@return string
local function buf_tc_directory(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    return M.tc_directory(vim.fn.fnamemodify(filepath, ":p:h"), filepath, cfg)
end

-- files
function M.files.buf_load(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    return M.files.load(
        buf_tc_directory(bufnr),
        vim.api.nvim_buf_get_name(bufnr),
        cfg.testcases_input_file_format,
        cfg.testcases_output_file_format
    )
end

function M.files.buf_write(bufnr, tctbl)
    local cfg = config.get_buffer_config(bufnr)
    M.files.write(
        buf_tc_directory(bufnr),
        tctbl,
        vim.api.nvim_buf_get_name(bufnr),
        cfg.testcases_input_file_format,
        cfg.testcases_output_file_format
    )
end

-- single_file
local function buf_single_file_path(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    return buf_tc_directory(bufnr) .. utils.buf_eval_string(bufnr, cfg.testcases_single_file_format)
end

function M.single_file.buf_load(bufnr)
    return M.single_file.load(buf_single_file_path(bufnr))
end

function M.single_file.buf_write(bufnr, tctbl)
    M.single_file.write(buf_single_file_path(bufnr), tctbl)
end

-- directory
function M.directory.buf_load(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    return M.directory.load(
        buf_tc_directory(bufnr),
        vim.api.nvim_buf_get_name(bufnr),
        cfg.testcases_directory_format,
        cfg.testcases_directory_input,
        cfg.testcases_directory_output
    )
end

function M.directory.buf_write(bufnr, tctbl)
    local cfg = config.get_buffer_config(bufnr)
    M.directory.write(
        buf_tc_directory(bufnr),
        tctbl,
        vim.api.nvim_buf_get_name(bufnr),
        cfg.testcases_directory_format,
        cfg.testcases_directory_input,
        cfg.testcases_directory_output
    )
end

---Remove every testcase a backend stores for a buffer.
---@param backend { buf_load: fun(b: integer): table, buf_write: fun(b: integer, t: table) }
---@param bufnr integer
local function buf_clear_backend(backend, bufnr)
    local tctbl = backend.buf_load(bufnr)
    for tcnum in pairs(tctbl) do
        tctbl[tcnum] = {} -- empty input/output → deleted on write
    end
    backend.buf_write(bufnr, tctbl)
end

function M.files.buf_clear(bufnr)
    -- Delete every file matching any configured input/output format — not just the
    -- canonical one — so `convert` cleans up testcases that were discovered through a
    -- fallback format (e.g. shared `input0.txt`) too.
    local cfg = config.get_buffer_config(bufnr)
    local directory = buf_tc_directory(bufnr)
    if not utils.directory_exists(directory) then
        return
    end
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    local matchers = {}
    local both = {}
    vim.list_extend(both, normalize_formats(cfg.testcases_input_file_format))
    vim.list_extend(both, normalize_formats(cfg.testcases_output_file_format))
    for _, fmt in ipairs(both) do
        local parts = eval_format_parts(filepath, fmt)
        if parts then
            matchers[#matchers + 1] = make_matcher(parts)
        end
    end
    for name, type_ in vim.fs.dir(directory) do
        if type_ == "file" then
            for _, match in ipairs(matchers) do
                if match(name) then
                    utils.delete_file(directory .. name)
                    break
                end
            end
        end
    end
end
function M.single_file.buf_clear(bufnr)
    M.single_file.buf_write(bufnr, {})
end
function M.directory.buf_clear(bufnr)
    buf_clear_backend(M.directory, bufnr)
end

---------------- DISPATCHER ----------------

---@type table<string, { buf_load: fun(b: integer): table, buf_write: fun(b: integer, t: table), buf_clear: fun(b: integer) }>
M.backends = {
    files = M.files,
    single_file = M.single_file,
    directory = M.directory,
}

---Return the backend for a storage mode, defaulting to `files`.
---@param storage string?
---@return table
function M.backend(storage)
    return M.backends[storage] or M.files
end

---Load all testcases for a buffer using the configured backend, falling back to
---the other backends when auto-detect is on and the primary found nothing.
---@param bufnr integer
---@return table<integer, { input: string?, output: string? }>
function M.buf_get_testcases(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    local primary = M.backend(cfg.testcases_storage)
    local tctbl = primary.buf_load(bufnr)

    if next(tctbl) == nil and cfg.testcases_auto_detect then
        for _, backend in pairs(M.backends) do
            if backend ~= primary then
                tctbl = backend.buf_load(bufnr)
                if next(tctbl) ~= nil then
                    break
                end
            end
        end
    end
    return tctbl
end

---Write a full testcase table for a buffer.
---@param bufnr integer
---@param tctbl table<integer, { input: string?, output: string? }>
---@param storage string? override the configured storage mode
function M.buf_write_testcases(bufnr, tctbl, storage)
    local cfg = config.get_buffer_config(bufnr)
    M.backend(storage or cfg.testcases_storage).buf_write(bufnr, tctbl)
end

---Remove every testcase a buffer stores, using its configured backend.
---@param bufnr integer
function M.buf_clear(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    M.backend(cfg.testcases_storage).buf_clear(bufnr)
end

---Create or replace a single testcase for a buffer.
---@param bufnr integer
---@param tcnum integer
---@param input string?
---@param output string?
function M.buf_save_testcase(bufnr, tcnum, input, output)
    local cfg = config.get_buffer_config(bufnr)
    if cfg.testcases_storage == "single_file" then
        -- single file holds everything, so edit the whole table and rewrite
        local tctbl = M.single_file.buf_load(bufnr)
        tctbl[tcnum] = { input = input, output = output }
        M.single_file.buf_write(bufnr, tctbl)
    else
        M.backend(cfg.testcases_storage).buf_write(bufnr, { [tcnum] = { input = input, output = output } })
    end
end

---Delete a single testcase for a buffer.
---@param bufnr integer
---@param tcnum integer
function M.buf_delete_testcase(bufnr, tcnum)
    local cfg = config.get_buffer_config(bufnr)
    if cfg.testcases_storage == "single_file" then
        local tctbl = M.single_file.buf_load(bufnr)
        tctbl[tcnum] = nil
        M.single_file.buf_write(bufnr, tctbl)
    else
        M.backend(cfg.testcases_storage).buf_write(bufnr, { [tcnum] = {} })
    end
end

---------------- DEPRECATED / COMPAT ----------------
-- Keeps the not-yet-ported `add_testcase` command working. Uses the prototype's
-- ad-hoc `tests/<name>/` layout; removed once that command moves to the backend
-- API above (step 9).

---@deprecated use the backend API
function M.add(project_root, name)
    project_root = project_root or vim.fn.getcwd()
    name = name or "sample"

    local testcase_dir = project_root .. "/tests/" .. name
    if not utils.ensure_directory(testcase_dir) then
        return false, "failed to create testcase directory"
    end

    local input_path = testcase_dir .. "/input.txt"
    local output_path = testcase_dir .. "/output.txt"
    if not utils.file_exists(input_path) then
        utils.write_file(input_path, "")
    end
    if not utils.file_exists(output_path) then
        utils.write_file(output_path, "")
    end

    return true, testcase_dir
end

return M
