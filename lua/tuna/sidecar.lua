-- lua/tuna/sidecar.lua
--
-- The per-problem sidecar: a small JSON file (`problem_store_file`, `.tuna.json` by
-- default) written beside a problem's source, holding what tuna knows about that
-- problem and cannot recover from the source itself.
--
-- It is deliberately *problem* state, not machine state: it travels with the folder,
-- it is scoped by construction (no registry of absolute paths to go stale when a
-- contest directory moves), and `clean.lua` already treats it as disposable data
-- about a problem, so it disappears when the problem does. Contrast `recent.lua`,
-- which keeps "where was I" in `stdpath("state")` — that genuinely *is* per-machine.
--
-- Current keys:
--   url / name / group  — the downloaded task's metadata (download.lua, submit.lua)
--   submit = { [basename] = { state, text, url, mtime } } — last verdict per file
--   run    = { [basename] = { mode, explicit, checker, source, compare } }
--                         — the per-problem run state of `tools.lua`
--
-- The two per-file sections are keyed by file *basename* rather than by directory,
-- because a folder may hold several problems (`a.cpp`, `b.cpp`) as easily as one
-- problem's several attempts. Writers merge, so no writer clobbers another's field.
--
-- `cfg` is optional throughout: callers that already resolved a buffer's config pass
-- it, and the rest fall back to the current setup. So a per-directory `.tuna.lua`
-- renaming `problem_store_file` is honoured wherever a resolved config is at hand
-- (submit, download, clean) but not for the lazily-hydrated run state, which only has
-- a path. Renaming the sidecar per directory is not a thing anyone needs to do.

local utils = require("tuna.utils")

local M = {}

---@param cfg table? resolved config (falls back to the current setup, then defaults)
---@return string
local function store_file(cfg)
    if cfg and cfg.problem_store_file then
        return cfg.problem_store_file
    end
    local config = require("tuna.config")
    local setup = config.current_setup or config.defaults
    return setup.problem_store_file or ".tuna.json"
end

---The sidecar's path for a problem directory.
---@param dir string
---@param cfg table?
---@return string
function M.path(dir, cfg)
    return vim.fs.normalize(dir) .. "/" .. store_file(cfg)
end

---Read a directory's sidecar as a table (empty when absent or unreadable), so a
---writer can merge its own field without clobbering the others.
---@param dir string
---@param cfg table?
---@return table
function M.read(dir, cfg)
    local content = utils.read_file(M.path(dir, cfg))
    if content then
        local ok, decoded = pcall(vim.json.decode, content)
        if ok and type(decoded) == "table" then
            return decoded
        end
    end
    return {}
end

---Read a directory's sidecar, or `nil` when there is none — for callers that need to
---tell "no sidecar" from "an empty one".
---@param dir string
---@param cfg table?
---@return table?
function M.read_or_nil(dir, cfg)
    local content = utils.read_file(M.path(dir, cfg))
    if not content then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, content)
    return (ok and type(decoded) == "table") and decoded or nil
end

---Write a sidecar table back to disk.
---@param dir string
---@param cfg table?
---@param store table
function M.write(dir, cfg, store)
    local ok, encoded = pcall(vim.json.encode, store)
    if ok then
        utils.write_file(M.path(dir, cfg), encoded)
    end
end

---Read one file's entry from a per-basename section (`submit`, `run`, …).
---@param filepath string absolute path of the source file
---@param section string
---@param cfg table?
---@return table?
function M.get_entry(filepath, section, cfg)
    local store = M.read(vim.fn.fnamemodify(filepath, ":h"), cfg)
    local sec = store[section]
    if type(sec) ~= "table" then
        return nil
    end
    local entry = sec[vim.fn.fnamemodify(filepath, ":t")]
    return type(entry) == "table" and entry or nil
end

---Merge one file's entry into a per-basename section, leaving every other file's
---entry (and every other section) alone. A `nil` entry removes it, and the section
---goes with it once empty, so an abandoned setting doesn't linger in the file.
---@param filepath string absolute path of the source file
---@param section string
---@param entry table? the entry to store, or nil to remove it
---@param cfg table?
function M.set_entry(filepath, section, entry, cfg)
    local dir = vim.fn.fnamemodify(filepath, ":h")
    local store = M.read(dir, cfg)
    local sec = type(store[section]) == "table" and store[section] or {}
    sec[vim.fn.fnamemodify(filepath, ":t")] = entry
    store[section] = next(sec) ~= nil and sec or nil
    -- Nothing left to say about this problem: don't leave an empty file behind.
    if next(store) == nil then
        if utils.file_exists(M.path(dir, cfg)) then
            utils.delete_file(M.path(dir, cfg))
        end
        return
    end
    M.write(dir, cfg, store)
end

return M
