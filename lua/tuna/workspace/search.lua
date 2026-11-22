-- lua/tuna/workspace/search.lua
--
-- `:Tuna find`: every problem and contest under where downloads land, searched by name, contest,
-- tags and the files a problem has, and opened as `:Tuna go` opens one. The sidecars are the
-- source: a `task` entry says a file is a problem's solution, and gives its name and contest
-- whatever the folders are called, and a `tags` entry a file's tags (`tags.lua`). Nothing is
-- kept between searches.

local api = vim.api
local uv = vim.uv
local config = require("tuna.config")
local utils = require("tuna.utils")
local sidecar = require("tuna.problem.sidecar")
local judges = require("tuna.problem.judges")

local M = {}

---@class tuna.SearchFile
---@field name string its name in the problem's folder
---@field tags string[] the tags in its header

---@class tuna.SearchRow
---@field name string what the list shows: a problem's name, or a contest's
---@field text string what a search matches: the name, the contest and the tags
---@field tags string[]? a problem's tags, from every file of it, which a search ranks first
---@field files tuna.SearchFile[]? a problem's files: its solutions, then its helpers and the
---  headers tagged
---@field named table<string, true>? the words naming a problem's files, lowercase: each one's
---  name, its name without the extension and its role (`main2.cpp`, `main2`, `solution`)
---@field path string what picking a problem opens: a solution, else one of its files; a
---  contest's directory
---@field label string? a problem's contest, as the judge names it
---@field contest string? the contest's name, on a contest's row
---@field members tuna.SearchRow[]? a contest's problems, in file order
---@field opens string? the solution entering a contest opens first, as far as is known here

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

---The words of a query, lowercase.
---@param query string
---@return string[]
local function words_of(query)
    return vim.split(vim.trim(query:lower()), "%s+", { trimempty = true })
end

---Whether a typed word starts one of the words of `tag`, in either case: `dp` is in
---`interval DP` and `bin` in `binary search`, but `a` is not in `math`, as a word typed for a
---name would otherwise lift every tag holding its letter.
---@param tag string
---@param words string[] lowercase
---@return boolean
local function tag_matched(tag, words)
    tag = tag:lower()
    for _, word in ipairs(words) do
        local from = 1
        while true do
            local at = tag:find(word, from, true)
            if not at then
                break
            end
            if at == 1 or not tag:sub(at - 1, at - 1):match("%w") then
                return true
            end
            from = at + 1
        end
    end
    return false
end

---The rows for what `walk` found. A problem is what the `task` entries of a folder name, one
---row whatever number of attempts it has (one URL, else one name), listed while a file of it is
---still there: a solution, or a file tagged. Its files and tags are those of its solutions and
---of the folder's helpers and headers, which serve each solution beside them, and picking it
---opens the solution worked on last, else a conventional name, else the first. A contest is a
---`group` naming two problems or more. Recent ones first, then by path.
---@param found { dir: string, names: table<string, true>, content: string }[]
---@param cfg table
---@return tuna.SearchRow[]
local function catalogue(found, cfg)
    local recent = require("tuna.workspace.recent")
    local st = recent.snapshot()
    local place = {}
    for _, list in ipairs({ st.contests or {}, st.problems or {} }) do
        for i, e in ipairs(list) do
            place[e.file or e.dir] = i
        end
    end
    local prefer = {}
    for i, name in ipairs(cfg.tool_names.solution or {}) do
        prefer[name] = prefer[name] or i
    end
    local with_tags = type(cfg.search.tags) == "string" and cfg.search.tags ~= "" and (cfg.search.tag_lines or 0) > 0
    local tools = require("tuna.run.tools")
    -- The role each helper name stands for, so `generator` finds a `gen.cpp`.
    local roles = {}
    for _, role in ipairs(tools.ROLES) do
        for _, name in ipairs(cfg.tool_names[role] or {}) do
            roles[name] = roles[name] or role
        end
    end
    -- What a file is, by its name, asked once per name for the whole walk: folders repeat
    -- the same names (`main.cpp`, `gen`, `1.in`), and the answer goes through Vimscript and,
    -- for a name with no extension, an uncached `vim.filetype.match`.
    local kinds = {}
    ---@return { header: boolean, helper: boolean, source: boolean, stem: string, words: string[] }
    local function kind_of(base)
        local k = kinds[base]
        if not k then
            local stem = vim.fn.fnamemodify(base, ":r")
            local ft = tools.filetype_of(base)
            local header = tools.is_header(base)
            k = {
                header = header,
                helper = tools.is_helper(base, cfg),
                -- A source tuna runs, rather than a build or a testcase.
                source = not header and ft ~= "" and (cfg.run_command or {})[ft] ~= nil,
                stem = stem,
                -- The words naming it (`named`): its name, its stem and its role.
                words = { base:lower(), stem:lower(), not header and (roles[stem] or "solution") or nil },
            }
            kinds[base] = k
        end
        return k
    end

    local rows, groups = {}, {}
    for _, f in ipairs(found) do
        local store = sidecar.decode(f.content) or {}
        local tasks = type(store.task) == "table" and store.task or {}
        local tagged = with_tags and type(store.tags) == "table" and store.tags or {}
        ---The tags of `base`, while it is there.
        local function tags_of(base)
            local list = f.names[base] and type(tagged[base]) == "table" and tagged[base]
            if not list then
                return {}
            end
            return vim.tbl_filter(function(tag)
                return type(tag) == "string"
            end, list)
        end
        ---Whether `a` is opened before `b`, of one problem's solutions.
        local function before(a, b)
            local pa, pb = place[f.dir .. "/" .. a] or math.huge, place[f.dir .. "/" .. b] or math.huge
            if pa ~= pb then
                return pa < pb
            end
            local ra, rb = prefer[kind_of(a).stem] or math.huge, prefer[kind_of(b).stem] or math.huge
            if ra ~= rb then
                return ra < rb
            end
            return a < b
        end

        -- In name order, so a problem's name and contest are the first of its attempts naming
        -- them, whatever order the sidecar's keys come in.
        local bases = vim.tbl_keys(tasks)
        table.sort(bases)
        local problems, keys = {}, {}
        for _, base in ipairs(bases) do
            local task = tasks[base]
            if type(task) == "table" and not recent.ignored(f.dir .. "/" .. base) then
                local key = type(task.url) == "string" and task.url or type(task.name) == "string" and task.name or base
                if not problems[key] then
                    problems[key], keys[#keys + 1] = { solutions = {} }, key
                end
                local p = problems[key]
                table.insert(p.solutions, base)
                for _, field in ipairs({ "name", "group", "url" }) do
                    if p[field] == nil and type(task[field]) == "string" then
                        p[field] = task[field]
                    end
                end
            end
        end
        table.sort(keys)
        -- What serves every solution beside it: the helpers there, and the headers tagged.
        -- In a folder of one problem, a solution with no `task` of its own is an attempt at
        -- it (a `main2.cpp` scaffolded beside the download), as `sidecar.task` reads it.
        local others, loose, keeps = {}, {}, false
        for base in pairs(f.names) do
            if base:byte(1) ~= 46 then -- not a dotfile, the sidecar among them
                local k = kind_of(base)
                local take, tagged_here = false, false
                if k.helper or k.header then
                    tagged_here = tagged[base] ~= nil and #tags_of(base) > 0
                    take = tagged_here or k.source
                elseif k.source and #keys == 1 and tasks[base] == nil then
                    take = true
                end
                if take and not recent.ignored(f.dir .. "/" .. base) then
                    if k.helper or k.header then
                        others[#others + 1] = base
                        keeps = keeps or tagged_here
                    else
                        loose[#loose + 1] = base
                    end
                end
            end
        end
        table.sort(others)

        for _, key in ipairs(keys) do
            local p = problems[key]
            local present = vim.tbl_filter(function(base)
                return f.names[base]
            end, p.solutions)
            vim.list_extend(present, loose)
            table.sort(present)
            local files, all, seen, named = {}, {}, {}, {}
            for _, base in ipairs(vim.list_extend(vim.list_slice(present), others)) do
                local tags = tags_of(base)
                files[#files + 1] = { name = base, tags = tags }
                for _, word in pairs(kind_of(base).words) do
                    named[word] = true
                end
                for _, tag in ipairs(tags) do
                    if not seen[tag] then
                        seen[tag], all[#all + 1] = true, tag
                    end
                end
            end
            -- Listed while a solution of it is there, or a file tagged: an untagged generator
            -- left alone in a folder is not enough to say there is a problem.
            if #present > 0 or keeps then
                table.sort(present, before)
                local name = p.name or p.solutions[1]
                local group = p.group
                local opens = present[1]
                    or vim.iter(files):find(function(e)
                        return #e.tags > 0
                    end).name
                local row = {
                    name = name,
                    text = table.concat({ name, group or "", unpack(all) }, " "),
                    tags = all,
                    files = files,
                    named = named,
                    path = f.dir .. "/" .. opens,
                    label = group and judges.label(group) or nil,
                    url = p.url,
                }
                rows[#rows + 1] = row
                if group then
                    groups[group] = groups[group] or {}
                    table.insert(groups[group], row)
                end
            end
        end
    end

    for group, members in pairs(groups) do
        local urls = {}
        for _, m in ipairs(members) do
            urls[m.url or m.path] = true
        end
        table.sort(members, function(a, b)
            return a.path < b.path
        end)
        local dir = vim.tbl_count(urls) > 1 and contest_dir(vim.tbl_map(function(m)
            return { file = m.path }
        end, members)) or nil
        if dir then
            local opens = members[1]
            for _, m in ipairs(members) do
                if (place[m.path] or math.huge) < (place[opens.path] or math.huge) then
                    opens = m
                end
            end
            rows[#rows + 1] = {
                name = judges.label(group),
                text = group,
                path = dir,
                contest = judges.label(group),
                members = members,
                opens = opens.path,
            }
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
---else those whose name, contest and tags fuzzy-match the words that name none of their files,
---the words in any order. A word names a file when it is the file's name, that name without
---its extension or its role, whole (`main2.cpp`, `gen`, `generator`), never a part of one, as
---`b` would otherwise find every problem with a `brute.cpp`. A row with a file a word names, or
---a tag a word starts a word of, comes first, more such words first, then the best match: a
---tag is written to be searched for, where letters scattered over a name match by chance, and
---`dp` would otherwise rank every name with a d before a p over the problem tagged
---`interval dp`.
---@param rows tuna.SearchRow[]
---@param query string
---@return integer[]
local function rank(rows, query)
    local out = {}
    local words = words_of(query)
    if #words == 0 then
        for i = 1, #rows do
            out[i] = i
        end
        return out
    end
    -- Rows grouped by the words their files leave to fuzzy-match. Nearly every row names no
    -- file and goes in the group of the whole query, so a query is one `matchfuzzy` over most
    -- rows and a few small ones, and a row allocates nothing unless a word names a file of it.
    local whole = table.concat(words, " ")
    local by_rest, rests, left = {}, {}, {}
    for i, r in ipairs(rows) do
        local rest
        if r.named then
            for w, word in ipairs(words) do
                if r.named[word] then
                    rest = rest or vim.list_slice(words, 1, w - 1)
                elseif rest then
                    rest[#rest + 1] = word
                end
            end
        end
        local key = rest and table.concat(rest, " ") or whole
        if not by_rest[key] then
            by_rest[key], rests[#rests + 1], left[key] = {}, key, rest and #rest or #words
        end
        table.insert(by_rest[key], { text = r.text, idx = i })
    end
    local found, hits, fewer, place = {}, {}, {}, {}
    for _, key in ipairs(rests) do
        -- A group every word names a file of is all found, as exact as a match gets.
        local matched = key == "" and by_rest[key] or vim.fn.matchfuzzy(by_rest[key], key, { key = "text" })
        for pos, k in ipairs(matched) do
            local r, n = rows[k.idx], #words - left[key]
            for _, word in ipairs(words) do
                if not (r.named and r.named[word]) then
                    for _, tag in ipairs(r.tags or {}) do
                        if tag_matched(tag, { word }) then
                            n = n + 1
                            break
                        end
                    end
                end
            end
            found[#found + 1], hits[k.idx], fewer[k.idx], place[k.idx] = k.idx, n, left[key], pos
        end
    end
    -- More words lifting a row first, then fewer words left to chance, then the best match.
    table.sort(found, function(a, b)
        if hits[a] ~= hits[b] then
            return hits[a] > hits[b]
        end
        if fewer[a] ~= fewer[b] then
            return fewer[a] < fewer[b]
        end
        if place[a] ~= place[b] then
            return place[a] < place[b]
        end
        return a < b
    end)
    return found
end

---What the panes beside the list show for a row: a problem's files, each followed by its tags,
---over the source picking it opens; a contest's problems, each followed by its tags, over the
---solution entering it opens. A tag the search matches is drawn as text, the others dimmed.
---@param row tuna.SearchRow
---@param words string[] what is typed, lowercase
---@param source fun(path: string): string[] a file's lines
---@param only integer? the one pane wanted
---@return table[]
local function panes_of(row, words, source, only)
    local entries = row.files or vim.tbl_map(function(m)
        return { name = m.name, tags = m.tags }
    end, row.members)
    local lines, marks = {}, {}
    for i, e in ipairs(entries) do
        local line = e.name .. (#e.tags > 0 and ":" or "")
        for j, tag in ipairs(e.tags) do
            line = line .. (j > 1 and ", " or " ") .. tag
            if not tag_matched(tag, words) then
                marks[#marks + 1] = { line = i - 1, col = #line - #tag, end_col = #line, group = "Comment" }
            end
        end
        lines[i] = line
    end
    local list = { title = row.label, lines = lines, highlights = marks }
    if only == 1 then
        return { list }
    end
    local path = row.opens or row.path
    return {
        list,
        { title = vim.fn.fnamemodify(path, ":~"), lines = source(path), filetype = vim.filetype.match({ filename = path }) },
    }
end

---`:Tuna find`: look under where downloads land, and go to what is picked, problems listed
---over contests. The picker opens at once and the rows arrive with the walk, so what is typed
---meanwhile is already the search, and nothing goes from the screen first when it is opened
---from the menu.
---@param bufnr integer
function M.open(bufnr)
    config.load_buffer_config(bufnr) -- refresh: a local config may have changed
    local cfg = config.get_buffer_config(bufnr)
    local roots = { root_of(cfg.downloaded_problems_path), root_of(cfg.downloaded_contests_directory .. "/") }
    local cols, height = utils.get_ui_size()
    local width = math.floor(cols * cfg.popup_ui.width + 0.5)
    local rows, words, sources = {}, {}, {}
    ---A file's lines, read once for the picker.
    local function source(path)
        sources[path] = sources[path] or vim.split(utils.read_file(path) or "", "\n", { plain = true })
        return sources[path]
    end
    local recent = require("tuna.workspace.recent")
    local widgets = require("tuna.ui.widgets")
    local id = widgets.menu(
        {},
        nil,
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
            panes = { { fit = true }, { selectable = true } },
            content = function(idx, only)
                return panes_of(rows[idx], words, source, only)
            end,
        },
        {
            search = function(query)
                words = words_of(query)
                return rank(rows, query)
            end,
            search_title = "find",
            lists = {
                titles = { "problems", "contests" },
                of = function(idx)
                    return rows[idx].contest and 2 or 1
                end,
            },
        }
    )
    walk(roots, cfg, function(found, truncated)
        rows = catalogue(found, cfg)
        local closed = widgets.menu_items(
            id,
            vim.tbl_map(function(r)
                return r.name
            end, rows)
        )
        local function say()
            if truncated then
                utils.notify(("search: stopped after %d entries, so only part was searched."):format(cfg.search.max_entries), "WARN")
            end
            if #rows == 0 then
                utils.notify("search: nothing found, only problems downloaded or submitted with tuna are listed.", "WARN")
            end
        end
        -- No rows close the picker, and what the walk has to say then waits for the insert mode
        -- the picker leaves, or it is gone before it can be read. A picker left open, or one
        -- already dismissed, says it at once.
        if closed then
            widgets.after_insert(say)
        else
            say()
        end
    end)
end

M._test = { root_of = root_of, catalogue = catalogue, rank = rank, panes_of = panes_of }

return M
