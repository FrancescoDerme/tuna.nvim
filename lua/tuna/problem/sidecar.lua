-- lua/tuna/problem/sidecar.lua
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
--   submit = { [basename] = { state, text, url, hash } } — last verdict per file
--   run    = { [basename] = { mode, source, checker, compare } }
--                         — the per-problem run state of `tools.lua`
--   results = { [basename] = { passed, total, hash } }
--                         — the local verdict of the last finished run (`run/core.lua`)
--
-- The per-file sections are keyed by file *basename* rather than by directory,
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

-- The sections holding one entry per file, keyed by its basename.
local PER_FILE = { "submit", "run", "results" }

---@param cfg table? resolved config (falls back to the current setup, then defaults)
---@return string
local function store_file(cfg)
    if cfg and cfg.problem_store_file then
        return cfg.problem_store_file
    end
    return require("tuna.config").current_setup.problem_store_file or ".tuna.json"
end

---The sidecar's path for a problem directory.
---@param dir string
---@param cfg table?
---@return string
function M.path(dir, cfg)
    return vim.fs.normalize(dir) .. "/" .. store_file(cfg)
end

---Read a directory's sidecar, or `nil` when there is none or it is not a JSON object, for
---callers that need to tell "no sidecar" from "an empty one".
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

---Read a directory's sidecar as a table (empty when absent or unreadable), so a
---writer can merge its own field without clobbering the others.
---@param dir string
---@param cfg table?
---@return table
function M.read(dir, cfg)
    return M.read_or_nil(dir, cfg) or {}
end

---Write a sidecar table back to disk. A sidecar travels with a problem's folder, so there is
---nothing to write for a path that has no folder: a buffer that is not a file (a runner UI pane,
---named `tuna://…`) would otherwise leave a `tuna:/…` tree wherever the editor was started.
---
---The entries of files no longer beside it go (`keep` aside, a buffer not yet written), or
---a new file given a deleted one's name would take its forced run settings. With nothing
---left to say about the problem, the file goes too.
---@param dir string
---@param cfg table?
---@param store table
---@param keep string? the basename being written, kept whether or not its file exists
function M.write(dir, cfg, store, keep)
    dir = vim.fs.normalize(dir)
    if vim.fn.isdirectory(dir) ~= 1 then
        return
    end
    for _, section in ipairs(PER_FILE) do
        local sec = store[section]
        if type(sec) == "table" then
            for name in pairs(sec) do
                if name ~= keep and not utils.file_exists(dir .. "/" .. name) then
                    sec[name] = nil
                end
            end
            store[section] = next(sec) ~= nil and sec or nil
        end
    end
    if next(store) == nil then
        if utils.file_exists(M.path(dir, cfg)) then
            utils.delete_file(M.path(dir, cfg))
        end
        return
    end
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
    local dir, name = vim.fn.fnamemodify(filepath, ":h"), vim.fn.fnamemodify(filepath, ":t")
    local store = M.read(dir, cfg)
    store[section] = type(store[section]) == "table" and store[section] or {}
    store[section][name] = entry
    M.write(dir, cfg, store, name)
end

---Forget everything stored about a file, for one written anew in its place.
---@param filepath string absolute path of the source file
---@param cfg table?
function M.forget(filepath, cfg)
    local dir, name = vim.fn.fnamemodify(filepath, ":h"), vim.fn.fnamemodify(filepath, ":t")
    local store = M.read_or_nil(dir, cfg)
    if not store then
        return
    end
    for _, section in ipairs(PER_FILE) do
        if type(store[section]) == "table" then
            store[section][name] = nil
        end
    end
    M.write(dir, cfg, store)
end

return M
