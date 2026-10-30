-- lua/tuna/workspace/search.lua
--
-- `:Tuna go search`: every problem and contest under where downloads land, searched by name
-- and opened as `:Tuna go` opens one. The sidecars are the source: a `task` entry says a file
-- is a problem's solution, and gives its name and contest whatever the folders are called.
-- Nothing is kept between searches, so nothing here can go stale.

local api = vim.api
local uv = vim.uv
local config = require("tuna.config")
local utils = require("tuna.utils")
local sidecar = require("tuna.problem.sidecar")

local M = {}

---@class tuna.SearchRow
---@field name string what the list shows
---@field text string what a search matches
---@field path string the solution, or a contest's directory
---@field contest string? the contest's name, on a contest's row
---@field problems string[]? a contest's problem names, in file order

---The directory a download path starts in: what comes before the first modifier that
---changes from one problem to the next, as `$(HOME)` and `$(CWD)` do not.
---@param path string a download path option
---@return string
local function root_of(path)
    local mods = utils.file_format_modifiers
    local filled = utils.fill_modifiers(path, { HOME = mods.HOME, CWD = mods.CWD })
    local dir = (filled:match("^(.-)%$%(") or filled):match("^(.*)/")
    return utils.normalize_path(utils.expand_home(dir and dir ~= "" and dir or "."), uv.cwd())
end

---Read `path` off the main loop.
---@param path string
---@param cb fun(content: string?)
local function read_async(path, cb)
    uv.fs_open(path, "r", 438, function(_, fd)
        if not fd then
            return cb(nil)
        end
        uv.fs_fstat(fd, function(_, stat)
            uv.fs_read(fd, stat and stat.size or 0, 0, function(_, content)
                uv.fs_close(fd, function()
                    cb(content)
                end)
            end)
        end)
    end)
end

---Find the sidecars under `roots` off the main loop, and call `done` on it with each one's
---text, directory and the names beside it (a `task` entry outlives its file). Symlinks are not
---followed, and dot-directories and `clean.skip_directories` not descended into.
---@param roots string[]
---@param cfg table
---@param done fun(found: { dir: string, names: table<string, true>, content: string }[], truncated: boolean)
local function walk(roots, cfg, done)
    local skips = {}
    for _, name in ipairs(cfg.clean.skip_directories or {}) do
        skips[name] = true
    end
    local found, seen, used, pending, truncated = {}, {}, 0, 0, false

    local function settle()
        pending = pending - 1
        if pending == 0 then
            vim.schedule(function()
                done(found, truncated)
            end)
        end
    end

    local function visit(dir)
        if seen[dir] then
            return
        end
        seen[dir] = true
        pending = pending + 1
        uv.fs_scandir(dir, function(_, handle)
            local names = {}
            while handle do
                local name, typ = uv.fs_scandir_next(handle)
                if not name then
                    break
                end
                used = used + 1
                if typ == "directory" then
                    if used > cfg.search.max_entries then
                        truncated = true
                    elseif name:sub(1, 1) ~= "." and not skips[name] then
                        visit(dir .. "/" .. name)
                    end
                else
                    names[name] = true
                end
            end
            if names[cfg.problem_store_file] then
                pending = pending + 1
                read_async(dir .. "/" .. cfg.problem_store_file, function(content)
                    if content then
                        found[#found + 1] = { dir = dir, names = names, content = content }
                    end
                    settle()
                end)
            end
            settle()
        end)
    end

    for _, root in ipairs(roots) do
        visit(root)
    end
end

---A contest's directory: the folder holding its problems as files, else the one holding its
---problems' folders. Nil when they are scattered, as no one folder is the contest then.
---@param problems { file: string }[]
---@return string?
local function contest_dir(problems)
    for _, up in ipairs({ ":h", ":h:h" }) do
        local dir = vim.fn.fnamemodify(problems[1].file, up)
        local shared = vim.iter(problems):all(function(p)
            return vim.fn.fnamemodify(p.file, up) == dir
        end)
        if shared then
            return dir
        end
    end
    return nil
end

---The rows for what `walk` found: a problem for each `task` entry whose file is still there,
---and a contest for each `group` naming two problems or more, recent ones first, then by path.
---@param found { dir: string, names: table<string, true>, content: string }[]
---@return tuna.SearchRow[]
local function catalogue(found)
    local recent = require("tuna.workspace.recent")
    local rows, groups = {}, {}
    for _, f in ipairs(found) do
        local store = sidecar.decode(f.content)
        local tasks = store and type(store.task) == "table" and store.task or {}
        for base, task in pairs(tasks) do
            local file = f.dir .. "/" .. base
            if f.names[base] and type(task) == "table" and not recent.ignored(file) then
                local name = type(task.name) == "string" and task.name or base
                local group = type(task.group) == "string" and task.group or nil
                rows[#rows + 1] = {
                    name = group and (name .. "  " .. group) or name,
                    text = name .. " " .. (group or ""),
                    path = file,
                }
                if group then
                    groups[group] = groups[group] or {}
                    table.insert(groups[group], { file = file, name = name, url = task.url })
                end
            end
        end
    end

    for group, problems in pairs(groups) do
        local urls = {}
        for _, p in ipairs(problems) do
            urls[p.url or p.file] = true
        end
        table.sort(problems, function(a, b)
            return a.file < b.file
        end)
        local dir = vim.tbl_count(urls) > 1 and contest_dir(problems) or nil
        if dir then
            rows[#rows + 1] = {
                name = group,
                text = group,
                path = dir,
                contest = group,
                problems = vim.tbl_map(function(p)
                    return p.name
                end, problems),
            }
        end
    end

    local st = recent.snapshot()
    local place = {}
    for _, list in ipairs({ st.contests or {}, st.problems or {} }) do
        for i, e in ipairs(list) do
            place[e.file or e.dir] = i
        end
    end
    table.sort(rows, function(a, b)
        local pa, pb = place[a.path] or math.huge, place[b.path] or math.huge
        if pa ~= pb then
            return pa < pb
        end
        return a.path < b.path
    end)
    return rows
end

---The rows a search shows, in order, as indices into `rows`: all of them with nothing typed,
---else those whose name and contest fuzzy-match, best first, the words in any order.
---@param rows tuna.SearchRow[]
---@param query string
---@return integer[]
local function rank(rows, query)
    local out = {}
    local typed = vim.trim(query:lower())
    if typed == "" then
        for i = 1, #rows do
            out[i] = i
        end
        return out
    end
    local keyed = {}
    for i, r in ipairs(rows) do
        keyed[i] = { text = r.text, idx = i }
    end
    return vim.tbl_map(function(k)
        return k.idx
    end, vim.fn.matchfuzzy(keyed, typed, { key = "text" }))
end

---What the pane beside the list shows for a row: a problem's source, or a contest's problems.
---@param row tuna.SearchRow
---@return table
local function pane_of(row)
    if row.contest then
        return { title = vim.fn.fnamemodify(row.path, ":~"), lines = row.problems }
    end
    return {
        title = vim.fn.fnamemodify(row.path, ":~"),
        lines = vim.split(utils.read_file(row.path) or "", "\n"),
        filetype = vim.filetype.match({ filename = row.path }),
    }
end

---`:Tuna go search`: look under where downloads land, and go to what is picked. The picker
---opens at once and the rows arrive with the walk, so what is typed meanwhile is already the
---search, and nothing goes from the screen first when it is opened from the menu.
---@param bufnr integer
function M.open(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    local roots = { root_of(cfg.downloaded_problems_path), root_of(cfg.downloaded_contests_directory .. "/") }
    local cols, height = utils.get_ui_size()
    local width = math.floor(cols * cfg.popup_ui.width + 0.5)
    local rows = {}
    local recent = require("tuna.workspace.recent")
    local widgets = require("tuna.ui.widgets")
    local id = widgets.menu(
        {},
        "Go to",
        function(idx)
            local row = rows[idx]
            if row.contest then
                recent.enter_contest({ dir = row.path, name = row.contest })
            else
                recent.open_solution(row.path)
            end
        end,
        api.nvim_get_current_win(),
        nil,
        {
            beside = {
                width = width,
                height = math.floor(height * cfg.popup_ui.height + 0.5),
                list_width = math.floor(width * 0.4),
            },
            selectable = true,
            content = function(idx)
                return pane_of(rows[idx])
            end,
        },
        nil,
        nil,
        function(query)
            return rank(rows, query)
        end
    )
    walk(roots, cfg, function(found, truncated)
        if truncated then
            utils.notify(("search: stopped after %d entries, so only part was searched."):format(cfg.search.max_entries), "WARN")
        end
        rows = catalogue(found)
        if #rows == 0 then
            utils.notify("search: nothing found, only problems downloaded or submitted with tuna are listed.", "WARN")
        end
        widgets.menu_items(
            id,
            vim.tbl_map(function(r)
                return r.name
            end, rows)
        )
    end)
end

M._test = { root_of = root_of, catalogue = catalogue, rank = rank }

return M
