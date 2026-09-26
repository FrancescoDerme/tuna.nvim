-- lua/tuna/scaffold.lua
--
-- Drop a starter helper for the stress, checker and interactive run modes beside the
-- solution (`:Tuna scaffold <checker|generator|bruteforce|interactor> [ext]`), then open it.
--
-- Templates are plain files named `<role>.<ext>` (`generator.cpp`), looked up in
-- `scaffold.directory` first and in the `scaffolds/` folder shipped with the plugin second.
-- Overriding one, adding a language and reading the defaults are all a matter of files, and
-- each role and language is looked up on its own, so a template stands for exactly one of
-- each. The file written is named after the first of the role's `tool_names`, the name
-- discovery looks for first, so a scaffold is always found by the run it was made for.
--
-- The language is the one asked for, else `scaffold.language`, else the solution's. A role
-- with no template in it but one in other languages offers those instead of stopping.

local config = require("tuna.config")
local tools = require("tuna.tools")
local utils = require("tuna.utils")
local widgets = require("tuna.widgets")

local M = {}

-- The templates shipped with the plugin, found from this file's own location: through the
-- runtimepath another plugin's `scaffolds/` folder would be mixed in with them.
local SHIPPED = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/scaffolds"

---The folders templates are looked up in, in order: the user's, then the shipped one.
---@param cfg table resolved buffer config
---@param dir string the solution's directory, what a relative `scaffold.directory` is read from
---@return string[]
local function folders(cfg, dir)
    local own = cfg.scaffold and cfg.scaffold.directory
    if type(own) == "string" and own ~= "" then
        return { utils.normalize_path(utils.expand_home(own), dir), SHIPPED }
    end
    return { SHIPPED }
end

---The template for `role` in `ext`: the first folder's `<role>.<ext>`.
---@param role string
---@param ext string
---@param dirs string[]
---@return string? path
local function template_path(role, ext, dirs)
    for _, d in ipairs(dirs) do
        local path = d .. "/" .. role .. "." .. ext
        if utils.file_exists(path) then
            return path
        end
    end
end

---Every language `role` has a template in, across the folders, sorted.
---@param role string
---@param dirs string[]
---@return string[]
local function languages_in(role, dirs)
    local seen, out = {}, {}
    for _, d in ipairs(dirs) do
        if vim.fn.isdirectory(d) == 1 then
            for name, kind in vim.fs.dir(d) do
                local base, ext = name:match("^(.+)%.([^.]+)$")
                if base == role and kind ~= "directory" and not seen[ext] then
                    seen[ext] = true
                    out[#out + 1] = ext
                end
            end
        end
    end
    table.sort(out)
    return out
end

---The languages `role` can be scaffolded in for the solution in `bufnr`.
---@param role string
---@param bufnr integer
---@return string[]
function M.languages(role, bufnr)
    local cfg = config.get_buffer_config(bufnr)
    return languages_in(role, folders(cfg, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")))
end

---The content a scaffold of `role` in `ext` would be written with, or nil when there is no
---such template. `clean` reads it to tell an untouched scaffold from one that was written in.
---@param role string
---@param ext string
---@param cfg table resolved buffer config
---@param dir string the directory the scaffold sits in
---@return string?
function M.template_for(role, ext, cfg, dir)
    local path = template_path(role, ext, folders(cfg, dir))
    return path and utils.read_file(path) or nil
end

---Write the scaffold of `role` in `ext` beside the solution and open it, asking first when a
---file of that name is already there.
---@param role string
---@param ext string
---@param cfg table
---@param dir string the solution's directory
---@param dirs string[] the template folders
local function write(role, ext, cfg, dir, dirs)
    local names = (cfg.tool_names and cfg.tool_names[role]) or tools.DEFAULT_NAMES[role] or {}
    local fname = (names[1] or role) .. "." .. ext
    local path = dir .. "/" .. fname
    local function create()
        utils.write_file(path, utils.read_file(template_path(role, ext, dirs)) or "")
        vim.cmd.edit(vim.fn.fnameescape(path))
        utils.notify("scaffold: created " .. fname .. ".", "INFO")
    end
    if not utils.file_exists(path) then
        create()
        return
    end
    widgets.menu({ "Open it", "Overwrite", "Stop" }, '"' .. fname .. '" already exists', function(idx)
        if idx == 1 then
            vim.cmd.edit(vim.fn.fnameescape(path))
        elseif idx == 2 then
            create()
        end
    end, vim.api.nvim_get_current_win())
end

---Create (or open) the scaffold of `role` beside the solution in `bufnr`.
---@param role string one of `tools.ROLES`
---@param bufnr integer? defaults to the current buffer
---@param ext string? the language to write it in; else `scaffold.language`, else the solution's
function M.create(role, bufnr, ext)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.tbl_contains(tools.ROLES, role) then
        utils.notify("scaffold: the role is one of " .. table.concat(tools.ROLES, ", ") .. ".")
        return
    end
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    local solution = vim.api.nvim_buf_get_name(bufnr)
    local dir = vim.fn.fnamemodify(solution, ":p:h")
    ext = ext or (cfg.scaffold and cfg.scaffold.language) or vim.fn.fnamemodify(solution, ":e")
    if ext == "" then
        utils.notify("scaffold: no language to write it in, open a solution file or pass an extension.")
        return
    end

    local dirs = folders(cfg, dir)
    if template_path(role, ext, dirs) then
        write(role, ext, cfg, dir, dirs)
        return
    end
    -- Not in this language. One it does have is still a working helper, since helpers are
    -- compiled and run by their own language, so those are offered rather than refused.
    local others = languages_in(role, dirs)
    if #others == 0 then
        local where = #dirs > 1 and ("add a " .. role .. "." .. ext .. " to " .. dirs[1])
            or "set scaffold.directory and add one there"
        utils.notify(("scaffold: no %s template in any language, %s."):format(role, where), "WARN")
        return
    end
    local items = {}
    for i, other in ipairs(others) do
        items[i] = "Write it in ." .. other
    end
    items[#items + 1] = "Stop"
    widgets.menu(items, ("No %s template for .%s"):format(role, ext), function(idx)
        if idx and others[idx] then
            write(role, others[idx], cfg, dir, dirs)
        end
    end, vim.api.nvim_get_current_win())
end

return M
