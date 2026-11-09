-- lua/tuna/problem/tags.lua
--
-- A file's tags, written in its header (`// tags: binary search, greedy`), which `:Tuna find`
-- matches as it matches a problem's name. The file is where they are written and the sidecar
-- where they are read: find reads every sidecar and no source, so a buffer's tags are copied
-- into its sidecar's `tags` section whenever it is read or written. Any file beside a sidecar
-- counts, a generator's tags being its problem's as much as the solution's.

local utils = require("tuna.utils")

local M = {}

-- What ends a comment on the line it opens, left out of the last tag: C's `*/`, Haskell's `-}`,
-- OCaml's `*)`, Python's docstring quotes, HTML's `-->`, Lua's `]]` and Julia's `=#`.
local CLOSERS = { "%*/", "%-}", "%*%)", '"""', "'''", "%-%->", "%]%]", "=#" }

-- The patterns already said to be broken, so each is said once.
local broken = {}

---The tags the first `search.tag_lines` of `lines` name, in order, each once: what the
---`search.tags` pattern captures on each line, split at commas, with a comment's end left out.
---@param lines string[]
---@param cfg table resolved config
---@return string[]
function M.parse(lines, cfg)
    local pattern, out, seen = cfg.search.tags, {}, {}
    if type(pattern) ~= "string" or pattern == "" then
        return out
    end
    for i = 1, math.min(#lines, cfg.search.tag_lines) do
        local ok, cap = pcall(string.match, lines[i], pattern)
        if not ok then
            if not broken[pattern] then
                broken[pattern] = true
                utils.notify("search.tags is not a valid Lua pattern, so no tags are read.", "WARN")
            end
            return {}
        end
        if type(cap) == "string" then
            for _, closer in ipairs(CLOSERS) do
                cap = cap:gsub("%s*" .. closer .. "%s*$", "")
            end
            for tag in vim.gsplit(cap, ",", { plain = true }) do
                tag = vim.trim(tag)
                if tag ~= "" and not seen[tag] then
                    seen[tag] = true
                    out[#out + 1] = tag
                end
            end
        end
    end
    return out
end

---Copy buffer `bufnr`'s tags into its sidecar, when they are not what it holds. Called only for
---a file with a sidecar beside it, so tags written in a file nothing else is known about leave
---no sidecar behind, and never with tags turned off.
---@param bufnr integer
function M.sync(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" or vim.bo[bufnr].buftype ~= "" then
        return
    end
    local cfg = require("tuna.config").get_buffer_config(bufnr)
    local pattern = cfg.search.tags
    if type(pattern) ~= "string" or pattern == "" or (cfg.search.tag_lines or 0) <= 0 then
        return
    end
    local sidecar = require("tuna.problem.sidecar")
    path = vim.fs.normalize(path)
    local dir, name = vim.fs.dirname(path), vim.fs.basename(path)
    local store = sidecar.read_or_nil(dir, cfg)
    if not store then
        return
    end
    local tags = M.parse(vim.api.nvim_buf_get_lines(bufnr, 0, cfg.search.tag_lines, false), cfg)
    local section = type(store.tags) == "table" and store.tags or {}
    local had = type(section[name]) == "table" and section[name] or {}
    if vim.deep_equal(had, tags) then
        return
    end
    section[name] = #tags > 0 and tags or nil
    store.tags = section
    sidecar.write(dir, cfg, store, name)
end

return M
