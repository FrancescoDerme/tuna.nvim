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
function M.files.load(directory, filepath, input_format, output_format)
    if not utils.directory_exists(directory) then
        return {}
    end
    local in_formats = normalize_formats(input_format)
    local out_formats = normalize_formats(output_format)

    -- Read the directory once, then try each input/output format pair in order.
    local entries = {}
    for name, type_ in vim.fs.dir(directory) do
        if type_ == "file" then
            entries[#entries + 1] = name
        end
    end

    for i, in_fmt in ipairs(in_formats) do
        local in_parts = eval_format_parts(filepath, in_fmt)
        local out_parts = eval_format_parts(filepath, out_formats[i] or out_formats[1])
        if in_parts and out_parts then
            local in_pattern = format_pattern(in_parts)
            local out_pattern = format_pattern(out_parts)
            local tctbl = {}
            local found = false
            for _, name in ipairs(entries) do
                local tcnum = match_tcnum(name, in_pattern)
                if tcnum then
                    tctbl[tcnum] = tctbl[tcnum] or {}
                    tctbl[tcnum].input = utils.read_file(directory .. name)
                    found = true
                else
                    tcnum = match_tcnum(name, out_pattern)
                    if tcnum then
                        tctbl[tcnum] = tctbl[tcnum] or {}
                        tctbl[tcnum].output = utils.read_file(directory .. name)
                        found = true
                    end
                end
            end
            if found then
                return tctbl
            end
        end
    end
    return {}
end

---@param directory string testcase directory (with trailing slash)
---@param tctbl table<integer, { input: string?, output: string? }>
---@param filepath string source file path
---@param input_format string
---@param output_format string
function M.files.write(directory, tctbl, filepath, input_format, output_format)
    -- Always write with the first (canonical) format, even if load matched a later one.
    local in_parts = eval_format_parts(filepath, normalize_formats(input_format)[1])
    local out_parts = eval_format_parts(filepath, normalize_formats(output_format)[1])
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

---Absolute testcase base directory for a buffer (with trailing slash).
---@param bufnr integer
---@return string
local function buf_tc_directory(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    local source_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
    return vim.fs.normalize(source_dir .. "/" .. cfg.testcases_directory) .. "/"
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
    local patterns = {}
    for _, fmt in ipairs(normalize_formats(cfg.testcases_input_file_format)) do
        local parts = eval_format_parts(filepath, fmt)
        if parts then
            patterns[#patterns + 1] = format_pattern(parts)
        end
    end
    for _, fmt in ipairs(normalize_formats(cfg.testcases_output_file_format)) do
        local parts = eval_format_parts(filepath, fmt)
        if parts then
            patterns[#patterns + 1] = format_pattern(parts)
        end
    end
    for name, type_ in vim.fs.dir(directory) do
        if type_ == "file" then
            for _, pat in ipairs(patterns) do
                if match_tcnum(name, pat) then
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
