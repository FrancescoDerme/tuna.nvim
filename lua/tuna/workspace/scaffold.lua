-- lua/tuna/workspace/scaffold.lua
--
-- Starter files for every role (`tools.SCAFFOLDS`): the solution a download, `:Tuna scratch`
-- or `:Tuna scaffold solution` writes, and the helpers of the stress, checker and interactive
-- run modes (`:Tuna scaffold <role> [ext]`).
--
-- Every role is looked up the same way. `scaffold.templates` names the template files, by
-- path, ordered list or role, with `$(ROLE)` and `$(FEXT)` among the modifiers, and the first
-- that exists wins over tuna's own starter, `scaffolds/<role>.<ext>`. A template is for the
-- language its extension names. Its text has the modifiers it can fill filled, and with no
-- problem known the header lines naming one are dropped.
--
-- A helper is written under its role's first `tool_names`, the name discovery looks for
-- first, so a scaffold is always found by the run it was made for. A solution is written
-- under a name the user confirms, offered as the next one free beside the solution
-- (`main2.cpp`). A helper's language is the one asked for, else `scaffold.language`, else the
-- solution's, and a role with no template in it offers the languages it has; a solution's is
-- the one asked for, else the solution's, else `downloaded_files_extension`. A run that
-- needs a helper it does not have offers to write its starter (`create_missing`).

local config = require("tuna.config")
local tools = require("tuna.run.tools")
local utils = require("tuna.utils")
local widgets = require("tuna.ui.widgets")

local M = {}

-- The starters shipped with the plugin, found from this file's own location: through the
-- runtimepath another plugin's `scaffolds/` folder would be mixed in with them.
local SHIPPED = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h") .. "/scaffolds"

local by_role

---tuna's own starters for `role`, read once: they change only with the plugin.
---@param role string
---@return string[]
local function shipped(role)
    if not by_role then
        by_role = {}
        for name, kind in vim.fs.dir(SHIPPED) do
            local of = kind == "file" and name:match("^(.+)%.[^.]+$")
            if of then
                by_role[of] = by_role[of] or {}
                table.insert(by_role[of], SHIPPED .. "/" .. name)
            end
        end
        for _, list in pairs(by_role) do
            table.sort(list)
        end
    end
    return by_role[role] or {}
end

---The template paths `scaffold.templates` gives `role`, in order, or false when the role
---starts empty.
---@param cfg table
---@param role string
---@return string[]|false
local function specs(cfg, role)
    local templates = (cfg.scaffold or {}).templates
    local spec = templates
    if type(templates) == "table" and templates[1] == nil then
        spec = templates[role]
        if spec == nil then
            spec = templates["*"]
        end
    end
    if spec == false then
        return false
    end
    if type(spec) == "string" then
        return { spec }
    end
    return type(spec) == "table" and vim.tbl_filter(function(p)
        return type(p) == "string"
    end, spec) or {}
end

---Every path `scaffold.templates` names, for `clean` to offer the folders they are in.
---@param cfg table
---@return string[]
function M.configured_paths(cfg)
    local out = {}
    for _, role in ipairs(tools.SCAFFOLDS) do
        vim.list_extend(out, specs(cfg, role) or {})
    end
    return out
end

---The modifiers a scaffold of `role` written at `target` fills: the file set, `$(ROLE)`,
---`$(FEXT)` (the language written, none when it is nil) and a problem's when one is known.
---@param role string
---@param ext string?
---@param cfg table
---@param target string
---@param task tuna.CCTask?
---@return tuna.Modifiers
local function modifiers(role, ext, cfg, target, task)
    local mods = vim.tbl_extend("force", utils.file_format_modifiers, { ROLE = role })
    if task then
        mods = vim.tbl_extend("force", mods, require("tuna.problem.download").task_modifiers(task, ext, cfg))
    end
    mods.FEXT = ext
    return mods
end

---Whether `str` names a modifier `mods` cannot fill.
---@param str string
---@param mods tuna.Modifiers
---@return boolean
local function names_unknown(str, mods)
    for name in str:gmatch("%$%(([^()]*)%)") do
        if mods[name] == nil then
            return true
        end
    end
    return false
end

---`spec` as a path, relative to the target's directory, or with `wild` as a glob where each
---modifier `mods` cannot fill matches anything. Nil when it names such a modifier and `wild`
---is off: a problem's template is not guessed at when no problem is known.
---@param spec string
---@param mods tuna.Modifiers
---@param target string
---@param wild boolean
---@return string?
local function resolve(spec, mods, target, wild)
    local marked = spec:gsub("%$%(([^()]*)%)", function(name)
        if mods[name] == nil then
            return "\1"
        end
    end)
    local path = (wild or not marked:find("\1")) and utils.format_modifiers(marked, mods, target)
    if not path then
        return nil
    end
    path = utils.normalize_path(utils.expand_home(path), vim.fs.dirname(target))
    -- What `glob` would read as a pattern or expand (`$HOME`) is escaped, the wildcards aside.
    return wild and (path:gsub("[\\%[%]%?%*%$]", "\\%0"):gsub("\1", "*")) or path
end

---Whether a template at `path` is for `ext`: one with no extension is for every language.
---@param path string
---@param ext string?
---@return boolean
local function for_language(path, ext)
    local own = vim.fn.fnamemodify(path, ":e")
    return ext == nil or own == "" or own == ext
end

---The templates a scaffold of `role` at `target` could be written from, in order, each once:
---the files the configured paths name, then tuna's own starters in the languages those leave
---out, in `ext` alone when given. With `wild`, a modifier `mods` cannot fill matches anything.
---@param role string
---@param cfg table
---@param target string
---@param ext string?
---@param task tuna.CCTask?
---@param wild boolean
---@param cache table<string, string[]>? glob results by pattern
---@return string[]
local function find(role, cfg, target, ext, task, wild, cache)
    local list = specs(cfg, role)
    if not list then
        return {}
    end
    cache = cache or {}
    local function glob(pattern)
        if not cache[pattern] then
            cache[pattern] = vim.tbl_filter(function(p)
                return vim.fn.isdirectory(p) == 0
            end, vim.fn.glob(pattern, false, true))
        end
        return cache[pattern]
    end
    local mods = modifiers(role, ext, cfg, target, task)
    local out, seen, langs = {}, {}, {}
    local function add(path)
        if not seen[path] and for_language(path, ext) then
            seen[path] = true
            out[#out + 1] = path
            langs[vim.fn.fnamemodify(path, ":e")] = true
        end
    end
    for _, spec in ipairs(list) do
        local path = resolve(spec, mods, target, wild)
        if path and wild then
            for _, found in ipairs(glob(path)) do
                add(found)
            end
        elseif path and utils.file_exists(path) then
            add(path)
        end
    end
    for _, path in ipairs(shipped(role)) do
        if not langs[vim.fn.fnamemodify(path, ":e")] then
            add(path)
        end
    end
    return out
end

---The template a scaffold of `role` in `ext` at `target` is written from: the first
---configured path that exists, else tuna's own starter. Nil when the role starts empty or
---has no template in `ext`.
---@param role string
---@param ext string
---@param cfg table
---@param target string the file being written
---@param task tuna.CCTask? the problem it is for, when known
---@return string?
function M.template(role, ext, cfg, target, task)
    return find(role, cfg, target, ext, task, false)[1]
end

---Every template a scaffold of `role` at `target` could be written from, a modifier only a
---problem fills matching anything: what `clean` compares a file with, `:Tuna scratch` offers
---and completion lists the languages of.
---@param role string
---@param cfg table
---@param target string
---@param ext string?
---@param cache table<string, string[]>? glob results by pattern, for a scan of many files
---@return string[]
function M.templates(role, cfg, target, ext, cache)
    return find(role, cfg, target, ext, nil, true, cache)
end

---What a scaffold written from `template` holds: its text with the modifiers it can fill
---filled, every other `$` as written. With no problem known, the leading lines naming a
---modifier only a problem fills are dropped, and the blank lines under them when none of
---those lines is left.
---@param template string
---@param role string
---@param ext string
---@param cfg table
---@param target string
---@param task tuna.CCTask?
---@return string
function M.render(template, role, ext, cfg, target, task)
    local mods = modifiers(role, ext, cfg, target, task)
    local text = utils.read_file(template) or ""
    if not task then
        local lines = vim.split(text, "\n", { plain = true })
        local i, dropped = 1, false
        while lines[i] and lines[i]:find("%$%b()") do
            if names_unknown(lines[i], mods) then
                table.remove(lines, i)
                dropped = true
            else
                i = i + 1
            end
        end
        if dropped and i == 1 then
            while lines[2] and lines[1] == "" do
                table.remove(lines, 1)
            end
        end
        text = table.concat(lines, "\n")
    end
    return utils.fill_modifiers(text, mods, target)
end

---The problem a file is a solution of, from its sidecar.
---@param file string
---@param cfg table
---@return tuna.CCTask?
local function task_of(file, cfg)
    local data = require("tuna.problem.sidecar").task(file, cfg)
    return (data and data.url) and { name = data.name or "", group = data.group or "", url = data.url } or nil
end

---The languages `role` can be scaffolded in for the solution in `bufnr`.
---@param role string
---@param bufnr integer
---@return string[]
function M.languages(role, bufnr)
    local cfg = config.get_buffer_config(bufnr)
    local target = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h") .. "/" .. role
    local seen, out = {}, {}
    for _, path in ipairs(M.templates(role, cfg, target)) do
        local ext = vim.fn.fnamemodify(path, ":e")
        if ext ~= "" and not seen[ext] then
            seen[ext] = true
            out[#out + 1] = ext
        end
    end
    table.sort(out)
    return out
end

---The name a helper of `role` in `ext` is written under: the role's first `tool_names`.
---@param role string
---@param ext string
---@param cfg table
---@return string
local function file_name(role, ext, cfg)
    local names = cfg.tool_names[role] or {}
    return (names[1] or role) .. "." .. ext
end

---The name a new solution in `dir` is offered under: `solution`'s while it is free, else
---that name with the next free number (`main2.cpp`, `main3.cpp`). With no solution to go
---by, the first of `tool_names.solution`.
---@param dir string
---@param solution string?
---@param ext string
---@param cfg table
---@return string
local function solution_name(dir, solution, ext, cfg)
    local stem = solution and vim.fn.fnamemodify(solution, ":t:r") or (cfg.tool_names.solution or {})[1] or "main"
    if not utils.file_exists(dir .. "/" .. stem .. "." .. ext) then
        return stem .. "." .. ext
    end
    local base = stem:gsub("%d+$", "")
    base = base ~= "" and base or stem
    local n = 2
    while utils.file_exists(("%s/%s%d.%s"):format(dir, base, n, ext)) do
        n = n + 1
    end
    return ("%s%d.%s"):format(base, n, ext)
end

---@class tuna.ScaffoldOpts
---@field open boolean? open what was written (default true)
---@field on_done fun(path: string?)? told the file written or opened, or nil when nothing was

---Write the scaffold of `role` in `ext` at `path`, asking first when a file is already there.
---@param role string
---@param ext string
---@param path string
---@param cfg table
---@param task tuna.CCTask? the problem the folder was downloaded for
---@param opts tuna.ScaffoldOpts
local function write(role, ext, path, cfg, task, opts)
    local fname = vim.fn.fnamemodify(path, ":t")
    local function done(written)
        if written and opts.open ~= false then
            require("tuna.ui.surface").edit(written)
            if role == "solution" then
                utils.place_cursor(cfg)
            end
        end
        if opts.on_done then
            opts.on_done(written)
        end
    end
    local function create()
        local template = M.template(role, ext, cfg, path, task)
        utils.write_file(path, template and M.render(template, role, ext, cfg, path, task) or "")
        -- A file written anew starts with nothing stored about it, whatever one of its name left.
        require("tuna.problem.sidecar").forget(path, cfg)
        require("tuna.run.tools").forget(path)
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

---The language a helper is written in when none is asked for: `scaffold.language`, else
---the current file's.
---@param cfg table
---@param current string the current buffer's file
---@return string
local function default_language(cfg, current)
    return (cfg.scaffold and cfg.scaffold.language) or vim.fn.fnamemodify(current, ":e")
end

---The role `word` names: a role, else the role whose `tool_names` hold it (`main`, `brute`),
---the names a user sees on the files being natural to type too.
---@param word string
---@param cfg table
---@return string?
function M.role_of(word, cfg)
    if vim.tbl_contains(tools.SCAFFOLDS, word) then
        return word
    end
    for _, role in ipairs(tools.SCAFFOLDS) do
        if vim.tbl_contains(cfg.tool_names[role] or {}, word) then
            return role
        end
    end
end

---Create (or open) the scaffold of `role` beside the solution in `bufnr`.
---@param role string one of `tools.SCAFFOLDS`, or a name of one (`role_of`)
---@param bufnr integer? defaults to the current buffer
---@param ext string? the language to write it in, else the role's default
---@param opts tuna.ScaffoldOpts?
function M.create(role, bufnr, ext, opts)
    opts = opts or {}
    local function nothing()
        if opts.on_done then
            opts.on_done(nil)
        end
    end
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    role = M.role_of(role, cfg)
    if not role then
        utils.notify("scaffold: the role is one of " .. table.concat(tools.SCAFFOLDS, ", ") .. ".")
        return nothing()
    end
    local current = vim.api.nvim_buf_get_name(bufnr)
    local dir = vim.fn.fnamemodify(current, ":p:h")

    -- A new solution is written beside this file, else the folder's solution, and in its
    -- language; it starts empty in a language with no template, as a downloaded one does.
    local solution
    if role == "solution" then
        solution = current ~= ""
                and cfg.run_command[vim.bo[bufnr].filetype]
                and not tools.is_support(current, cfg)
                and current
            or tools.solutions_in(dir, cfg)[1]
        ext = ext or (solution and vim.fn.fnamemodify(solution, ":e")) or cfg.downloaded_files_extension
    else
        ext = ext or default_language(cfg, current)
    end
    -- The problem of the solution it is written beside, else of the file it is written from.
    local task = task_of(solution or current, cfg)
    if not ext or ext == "" then
        utils.notify("scaffold: no language to write it in, open a solution file or pass an extension.")
        return nothing()
    end

    if role == "solution" then
        widgets.input("New solution", solution_name(dir, solution, ext, cfg), function(name)
            if vim.trim(name) == "" then
                return nothing()
            end
            write(role, ext, utils.normalize_path(utils.expand_home(vim.trim(name)), dir), cfg, task, opts)
        end, nothing)
        return
    end
    local path = dir .. "/" .. file_name(role, ext, cfg)
    if specs(cfg, role) == false or M.template(role, ext, cfg, path, task) then
        write(role, ext, path, cfg, task, opts)
        return
    end
    -- Not in this language. One it does have is still a working helper, since helpers are
    -- compiled and run by their own language, so those are offered rather than refused.
    local others = M.languages(role, bufnr)
    if #others == 0 then
        utils.notify(
            ("scaffold: no %s template in any language, add one to scaffold.templates."):format(role),
            "WARN"
        )
        return nothing()
    end
    local items = {}
    for i, other in ipairs(others) do
        items[i] = "Write it in ." .. other
    end
    items[#items + 1] = "Stop"
    widgets.menu(items, ("No %s template for .%s"):format(role, ext), function(idx)
        if idx and others[idx] then
            write(role, others[idx], dir .. "/" .. file_name(role, others[idx], cfg), cfg, task, opts)
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
---@param opts { win: integer?, before: fun()?, instead: { label: string, choose: fun() }? }?
---`before` runs once Create is chosen, before anything is written (a runner UI closing, so files
---open in the editor); `instead` is a way on without them, offered between Create and Stop
function M.create_missing(roles, bufnr, title, opts)
    opts = opts or {}
    local cfg = config.get_buffer_config(bufnr)
    local ext = default_language(cfg, vim.api.nvim_buf_get_name(bufnr))
    local names = vim.tbl_map(function(role)
        return file_name(role, ext, cfg)
    end, roles)
    local items = { "Create " .. table.concat(names, " and ") }
    if opts.instead then
        items[#items + 1] = opts.instead.label
    end
    items[#items + 1] = "Stop"
    widgets.menu(items, title, function(idx)
        if opts.instead and idx == 2 then
            return opts.instead.choose()
        end
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
            require("tuna.ui.surface").edit(created[1])
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
