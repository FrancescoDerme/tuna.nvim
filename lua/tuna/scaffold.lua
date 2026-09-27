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
-- with no template in it but one in other languages offers those instead of stopping. A run
-- that needs a helper it does not have offers to write its starter (`create_missing`).

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

---The name a scaffold of `role` in `ext` is written under: the role's first `tool_names`.
---@param role string
---@param ext string
---@param cfg table
---@return string
local function file_name(role, ext, cfg)
    local names = (cfg.tool_names and cfg.tool_names[role]) or tools.DEFAULT_NAMES[role] or {}
    return (names[1] or role) .. "." .. ext
end

---@class tuna.ScaffoldOpts
---@field open boolean? open what was written (default true)
---@field on_done fun(path: string?)? told the file written or opened, or nil when nothing was

---Write the scaffold of `role` in `ext` beside the solution, asking first when a file of that
---name is already there.
---@param role string
---@param ext string
---@param cfg table
---@param dir string the solution's directory
---@param dirs string[] the template folders
---@param opts tuna.ScaffoldOpts
local function write(role, ext, cfg, dir, dirs, opts)
    local fname = file_name(role, ext, cfg)
    local path = dir .. "/" .. fname
    local function done(written)
        if written and opts.open ~= false then
            vim.cmd.edit(vim.fn.fnameescape(written))
        end
        if opts.on_done then
            opts.on_done(written)
        end
    end
    local function create()
        local template = template_path(role, ext, dirs)
        utils.write_file(path, template and utils.read_file(template) or "")
        if opts.open ~= false then
            utils.notify("scaffold: created " .. fname .. ".", "INFO")
        end
        done(path)
    end
    if not utils.file_exists(path) then
        create()
        return
    end
    widgets.menu({ "Open it", "Overwrite", "Stop" }, '"' .. fname .. '" already exists', function(idx)
        if idx == 1 then
            done(path)
        elseif idx == 2 then
            create()
        else
            done(nil)
        end
    end, vim.api.nvim_get_current_win(), function()
        done(nil)
    end)
end

---The language a scaffold for the solution in `bufnr` is written in when none is asked for:
---`scaffold.language`, else the solution's own.
---@param cfg table
---@param solution string
---@return string
local function default_language(cfg, solution)
    return (cfg.scaffold and cfg.scaffold.language) or vim.fn.fnamemodify(solution, ":e")
end

---Create (or open) the scaffold of `role` beside the solution in `bufnr`.
---@param role string one of `tools.ROLES`
---@param bufnr integer? defaults to the current buffer
---@param ext string? the language to write it in; else `scaffold.language`, else the solution's
---@param opts tuna.ScaffoldOpts?
function M.create(role, bufnr, ext, opts)
    opts = opts or {}
    local function nothing()
        if opts.on_done then
            opts.on_done(nil)
        end
    end
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.tbl_contains(tools.ROLES, role) then
        utils.notify("scaffold: the role is one of " .. table.concat(tools.ROLES, ", ") .. ".")
        return nothing()
    end
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    local solution = vim.api.nvim_buf_get_name(bufnr)
    local dir = vim.fn.fnamemodify(solution, ":p:h")
    ext = ext or default_language(cfg, solution)
    if ext == "" then
        utils.notify("scaffold: no language to write it in, open a solution file or pass an extension.")
        return nothing()
    end

    local dirs = folders(cfg, dir)
    if template_path(role, ext, dirs) then
        write(role, ext, cfg, dir, dirs, opts)
        return
    end
    -- Not in this language. One it does have is still a working helper, since helpers are
    -- compiled and run by their own language, so those are offered rather than refused.
    local others = languages_in(role, dirs)
    if #others == 0 then
        local where = #dirs > 1 and ("add a " .. role .. "." .. ext .. " to " .. dirs[1])
            or "set scaffold.directory and add one there"
        utils.notify(("scaffold: no %s template in any language, %s."):format(role, where), "WARN")
        return nothing()
    end
    local items = {}
    for i, other in ipairs(others) do
        items[i] = "Write it in ." .. other
    end
    items[#items + 1] = "Stop"
    widgets.menu(items, ("No %s template for .%s"):format(role, ext), function(idx)
        if idx and others[idx] then
            write(role, others[idx], cfg, dir, dirs, opts)
        else
            nothing()
        end
    end, vim.api.nvim_get_current_win(), nothing)
end

---Offer to write the starters a run needs and does not have, rather than only saying so: a
---menu naming the files it would create, and Stop. What is created is opened to be written,
---the first file in `opts.win` (else the current window) and the rest in the buffer list: a
---starter is where a helper begins, not one the run could use yet, so nothing runs.
---@param roles string[] the roles missing, in the order they are written
---@param bufnr integer the solution's buffer
---@param title string what the run needs, the menu's title
---@param opts { win: integer?, before: fun()? }? `before` runs once Create is chosen,
---before anything is written (a results board closing, so files open in the editor)
function M.create_missing(roles, bufnr, title, opts)
    opts = opts or {}
    local cfg = config.get_buffer_config(bufnr)
    local ext = default_language(cfg, vim.api.nvim_buf_get_name(bufnr))
    local names = vim.tbl_map(function(role)
        return file_name(role, ext, cfg)
    end, roles)
    local label = "Create " .. table.concat(names, " and ")
    widgets.menu({ label, "Stop" }, title, function(idx)
        if idx ~= 1 then
            return
        end
        if opts.before then
            opts.before()
        end
        local created = {}
        local function step(i)
            if i <= #roles then
                return M.create(roles[i], bufnr, nil, {
                    open = false,
                    on_done = function(path)
                        created[#created + 1] = path
                        step(i + 1)
                    end,
                })
            end
            if #created == 0 then
                return
            end
            if opts.win and vim.api.nvim_win_is_valid(opts.win) then
                vim.api.nvim_set_current_win(opts.win)
            end
            vim.cmd.edit(vim.fn.fnameescape(created[1]))
            for j = 2, #created do
                vim.cmd.badd(vim.fn.fnameescape(created[j]))
            end
            local written = vim.tbl_map(function(path)
                return vim.fn.fnamemodify(path, ":t")
            end, created)
            utils.notify(
                ("created %s, fill %s in and run again."):format(
                    table.concat(written, " and "),
                    #written > 1 and "them" or "it"
                ),
                "INFO"
            )
        end
        step(1)
    end, vim.api.nvim_get_current_win())
end

return M
