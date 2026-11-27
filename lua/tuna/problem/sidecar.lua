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
--   task   = { [basename] = { url, name, group, mirror, mirror_at } }
--                         — the problem each file is a solution of (download.lua, submit.lua),
--                           with no `url` for one made by hand
--   submit = { [basename] = { state, text, url, hash } } — last verdict per file
--   run    = { [basename] = { mode, source, checker, compare } }
--                         — the per-problem run state of `tools.lua`
--   results = { [basename] = { passed, total, hash } }
--                         — the local verdict of the last finished run (`run/core.lua`)
--   tags   = { [basename] = { tag, … } } — the tags in the file's header (`tags.lua`)
--
-- The per-file sections are keyed by file *basename* rather than by directory,
-- because a folder may hold several problems (`a.cpp`, `b.cpp`) as easily as one
-- problem's several attempts. Writers merge, so no writer clobbers another's field.
--
-- Its name is the setup's `problem_store_file` everywhere (`M.name`), never a `.tuna.lua`'s:
-- most readers have a path and no buffer (the menu, the run state, the startup autocmd), and
-- a name resolved per directory would have its writers and readers look in different files.

local utils = require("tuna.utils")

local M = {}

-- The sections holding one entry per file, keyed by its basename, that go with their file. A
-- file's `task` outlives it: a solution deleted and written again in a downloaded problem's
-- folder is still that problem's.
local PER_FILE = { "submit", "run", "results", "tags" }

---The sidecar's file name, the setup's `problem_store_file`.
---@return string
function M.name()
    return require("tuna.config").current_setup.problem_store_file or ".tuna.json"
end

---The sidecar's path for a problem directory.
---@param dir string
---@return string
function M.path(dir)
    return vim.fs.normalize(dir) .. "/" .. M.name()
end

---Read a directory's sidecar, or `nil` when there is none or it is not a JSON object, for
---callers that need to tell "no sidecar" from "an empty one".
---@param dir string
---@return table?
function M.read_or_nil(dir)
    local content = utils.read_file(M.path(dir))
    return content and M.decode(content) or nil
end

---A sidecar's text as a table, or `nil` when it is not a JSON object.
---@param content string
---@return table?
function M.decode(content)
    local ok, decoded = pcall(vim.json.decode, content)
    return (ok and type(decoded) == "table") and decoded or nil
end

---Read a directory's sidecar as a table (empty when absent or unreadable), so a
---writer can merge its own field without clobbering the others.
---@param dir string
---@return table
function M.read(dir)
    return M.read_or_nil(dir) or {}
end

---Write a sidecar table back to disk. A sidecar travels with a problem's folder, so there is
---nothing to write for a path that has no folder: a buffer that is not a file (a runner UI pane,
---named `tuna://…`) would otherwise leave a `tuna:/…` tree wherever the editor was started.
---
---The entries of files no longer beside it go (`keep` aside, a buffer not yet written), or
---a new file given a deleted one's name would take its forced run settings. With nothing
---left to say about the problem, the file goes too.
---@param dir string
---@param store table
---@param keep string? the basename being written, kept whether or not its file exists
function M.write(dir, store, keep)
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
        if utils.file_exists(M.path(dir)) then
            utils.delete_file(M.path(dir))
        end
        return
    end
    local ok, encoded = pcall(vim.json.encode, store)
    if ok then
        utils.write_file(M.path(dir), encoded)
    end
end

---Read one file's entry from a per-basename section (`submit`, `run`, …).
---@param filepath string absolute path of the source file
---@param section string
---@return table?
function M.get_entry(filepath, section)
    local store = M.read(vim.fn.fnamemodify(filepath, ":h"))
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
function M.set_entry(filepath, section, entry)
    local dir, name = vim.fn.fnamemodify(filepath, ":h"), vim.fn.fnamemodify(filepath, ":t")
    local store = M.read(dir)
    store[section] = type(store[section]) == "table" and store[section] or {}
    store[section][name] = entry
    M.write(dir, store, name)
end

---What tells a task's problem from another: its URL, else its name, which is all a problem
---made by hand (`:Tuna new`) has. Every reader asking whether two tasks are one problem
---compares this, so a contest of problems with no URL is still several problems.
---@param task table?
---@return string? identity nil for a task naming neither
function M.identity(task)
    if type(task) ~= "table" then
        return nil
    end
    for _, key in ipairs({ "url", "name" }) do
        local value = task[key]
        if type(value) == "string" and value ~= "" then
            return value
        end
    end
    return nil
end

---The problems a sidecar names, each file's task.
---@param store table?
---@return table[]
local function tasks_of(store)
    if not (store and type(store.task) == "table") then
        return {}
    end
    return vim.tbl_filter(function(entry)
        return type(entry) == "table"
    end, vim.tbl_values(store.task))
end

---The problems the sidecar of `dir` names, each file's task.
---@param dir string
---@return table[]
function M.tasks(dir)
    return tasks_of(M.read_or_nil(dir))
end

---The problem `filepath` is a solution of, as downloaded (`url`, `name`, `group`, and the
---`mirror` it came through with `mirror_at`): its own `task` entry, else the folder's one
---problem when every entry there names the same, so a second attempt beside a downloaded
---solution is that problem's. A folder of several problems, a contest's plain files, names none
---for a file it has no entry for.
---@param filepath string absolute path of the source file
---@return table?
function M.task(filepath)
    local store = M.read_or_nil(vim.fn.fnamemodify(filepath, ":h"))
    local own = store and type(store.task) == "table" and store.task[vim.fn.fnamemodify(filepath, ":t")]
    if type(own) == "table" then
        return own
    end
    local only
    for _, entry in ipairs(tasks_of(store)) do
        if only and M.identity(entry) ~= M.identity(only) then
            return nil
        end
        only = entry
    end
    return only
end

---Forget everything stored about a file, for one written anew in its place.
---@param filepath string absolute path of the source file
function M.forget(filepath)
    local dir, name = vim.fn.fnamemodify(filepath, ":h"), vim.fn.fnamemodify(filepath, ":t")
    local store = M.read_or_nil(dir)
    if not store then
        return
    end
    for _, section in ipairs(PER_FILE) do
        if type(store[section]) == "table" then
            store[section][name] = nil
        end
    end
    M.write(dir, store)
end

return M
