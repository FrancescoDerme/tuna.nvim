-- lua/tuna/problem/tags.lua
--
-- A solution's tags, written in its header (`// tags: binary search, greedy`), which
-- `:Tuna find` matches as it matches a problem's name. The file is where they are written and
-- the sidecar where they are read: find reads every sidecar and no source, so a buffer's tags
-- are copied into its sidecar's `tags` section whenever it is read or written.

local M = {}

---The tags the first `search.tag_lines` of `lines` name, in order, each once: what the
---`search.tags` pattern captures on each line, split at commas, with a block comment's end
---left out.
---@param lines string[]
---@param cfg table resolved config
---@return string[]
function M.parse(lines, cfg)
    local pattern, out, seen = cfg.search.tags, {}, {}
    if type(pattern) ~= "string" or pattern == "" then
        return out
    end
    for i = 1, math.min(#lines, cfg.search.tag_lines) do
        local cap = lines[i]:match(pattern)
        if type(cap) == "string" then
            cap = cap:gsub("%s*%*/%s*$", "")
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
---no sidecar behind.
---@param bufnr integer
function M.sync(bufnr)
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" or vim.bo[bufnr].buftype ~= "" then
        return
    end
    path = vim.fs.normalize(path)
    local cfg = require("tuna.config").get_buffer_config(bufnr)
    local sidecar = require("tuna.problem.sidecar")
    local tags = M.parse(vim.api.nvim_buf_get_lines(bufnr, 0, cfg.search.tag_lines, false), cfg)
    if not vim.deep_equal(sidecar.get_entry(path, "tags", cfg) or {}, tags) then
        sidecar.set_entry(path, "tags", #tags > 0 and tags or nil, cfg)
    end
end

return M
