-- lua/tuna/menu.lua
--
-- The `:Tuna` menu — the single entry point opened by a bare `:Tuna` (and by
-- `:Tuna menu`). Two columns, side by side:
--
--   * **Contests** over **Problems** — the recent ones `:Tuna last …` returns to, most
--     recent first, each with how it went. `<CR>` goes there.
--   * **Catch of the day** — what tuna can do from the file you are on. `<CR>` runs it.
--
-- The split is the point. The left column is *where you were*, the right is *what to
-- do*, and both are lists you walk with `j`/`k` and act on with `<CR>` — so the board
-- reads as one thing rather than as a menu with a header. `switch_window_keys` (or Tab)
-- moves between the columns, exactly as they move between the results UI's panes.
--
-- This module stays a presentation layer: every action it offers is an existing entry
-- point (`commands`, `recent`, `scaffold`, `clean`), required lazily to avoid a load
-- cycle. What it adds is the *status* beside a recent entry, which is the one thing no
-- other module answers — see `entry_status`.

local api = vim.api
local config = require("tuna.config")
local tools = require("tuna.tools")

local M = {}

--------------------------------------------------------------------------------
-- The banner
--------------------------------------------------------------------------------

-- A slanted block wordmark, in the spirit of the ASCII title a start screen puts at the
-- top of itself. It is an ornament and is treated as one: `widgets.panels` draws it only
-- when the lists still fit under it, so a small terminal loses the title rather than the
-- menu. `menu.header` replaces it with lines of your own, or turns it off.
local BANNER = {
    "  ██████████  ███    ███  ███     ███     ██████   ",
    "  ██████████  ███    ███  ████    ███    ███  ███  ",
    "    ███      ███    ███  ███ ██  ███   ███    ███  ",
    "    ███      ███    ███  ███  ██ ███  ████████████ ",
    "   ███      ██████████  ███   █████  ███      ███  ",
    "   ███       ████████   ███     ███  ███      ███  ",
}

---The banner rows to draw, from `config.menu.header`: a list of lines of your own,
---`false` for none, or nothing at all for the shipped one.
---@param cfg table
---@return string[]?
local function banner(cfg)
    local h = (cfg.menu or {}).header
    if h == false then
        return nil
    end
    if type(h) == "table" then
        return #h > 0 and h or nil
    end
    return BANNER
end

--------------------------------------------------------------------------------
-- The left column: where you were, and how it went
--------------------------------------------------------------------------------

-- The results grid's verdict words and colours, so a status reads the same here as there.
local VERDICT = {
    accepted = { "ACCEPTED", "TunaCorrect" },
    rejected = { "REJECTED", "TunaWrong" },
    partial = { "PARTIAL", "TunaWarning" },
}

---How a problem went, as `{ text, highlight? }` segments, in the order the user asks for it:
---the judge's verdict while it still describes the source, else the local verdict of its
---last finished run while the source is the one that ran, else nothing. A judge has the
---last word because it is the answer that settles the problem. Only the verdict word is
---coloured, never the count beside it.
---@param path string? the solution file
---@return { [1]: string, [2]: string? }[]
local function entry_status(path)
    if not path or path == "" then
        return {}
    end
    local verdict = require("tuna.submit").verdict_for(path)
    if verdict and VERDICT[verdict.state] then
        return { VERDICT[verdict.state] }
    end
    local passed, total = require("tuna.runner.core").local_verdict(path)
    if passed then
        return { { passed .. "/" .. total .. " " }, { "PASSED", passed == total and "TunaCorrect" or "TunaWrong" } }
    end
    return {}
end

---How many of a contest's problems pass locally, for a judge whose verdicts never reach
---tuna: the same word and the same shape as a problem's own status, since that is what it is
---counting.
---@param files string[]
---@return { [1]: string, [2]: string? }[]
local function local_status(files)
    local passed = 0
    for _, file in ipairs(files) do
        local ran, total = require("tuna.runner.core").local_verdict(file)
        if ran and ran == total then
            passed = passed + 1
        end
    end
    return { { passed .. "/" .. #files .. " " }, { "PASSED", passed > 0 and "TunaCorrect" or "TunaDone" } }
end

---How a contest is going, over every problem in it, as `{ text, highlight? }` segments: how
---many the judge accepted out of all of them, then how many it rejected or accepted in part,
---e.g. `2/5 ACCEPTED, 1 REJECTED`. Only judge verdicts count, a local verdict existing only
---for problems that were run. A count is never coloured, and a word is dimmed at zero.
---Where no verdict can reach tuna at all — nothing reports one back for this judge
---(`submit.reports_verdict`) — it counts what passed locally instead: `0/7 ACCEPTED` would be
---a claim about an answer nobody can hear, and would stay at zero forever.
---@param contest tuna.RecentContest?
---@return { [1]: string, [2]: string? }[]
local function contest_status(contest)
    if not (contest and contest.dir and vim.fn.isdirectory(contest.dir) == 1) then
        return {}
    end
    local cfg = config.load_local_config_and_extend(contest.dir)
    local files = require("tuna.recent").contest_problems(contest.dir, contest.problem, cfg)
    if #files == 0 then
        return {}
    end
    local submit = require("tuna.submit")
    local counts = { accepted = 0, rejected = 0, partial = 0 }
    local answerable = false
    for _, file in ipairs(files) do
        answerable = answerable or submit.reports_verdict(file)
        local verdict = submit.verdict_for(file)
        if verdict and counts[verdict.state] then
            counts[verdict.state] = counts[verdict.state] + 1
        end
    end
    if not answerable then
        return local_status(files)
    end
    local segments = {}
    local function add(count, label, word)
        if #segments > 0 then
            segments[#segments + 1] = { ", " }
        end
        segments[#segments + 1] = { label .. " " }
        segments[#segments + 1] = { word[1], count > 0 and word[2] or "TunaDone" }
    end
    add(counts.accepted, counts.accepted .. "/" .. #files, VERDICT.accepted)
    if counts.rejected > 0 then
        add(counts.rejected, tostring(counts.rejected), VERDICT.rejected)
    end
    if counts.partial > 0 then
        add(counts.partial, tostring(counts.partial), VERDICT.partial)
    end
    return segments
end

---A recent list as `{ name, status, open }` entries, or a single placeholder when it is
---empty, whose `<CR>` gets `recent`'s own explanation of how to fill it.
---@param list table[]
---@param name_of fun(i: integer, item: table): string, string? its name, and a judge to show before it
---@param status_of fun(item: table): table[]
---@param open fun(index: integer?)
---@return table[]
local function entries_of(list, name_of, status_of, open)
    local out = {}
    for i, item in ipairs(list) do
        local name, judge = name_of(i, item)
        out[i] = {
            name = name,
            judge = judge,
            status = status_of(item),
            open = function()
                open(i)
            end,
        }
    end
    if #out == 0 then
        out[1] = {
            name = "—",
            status = {},
            open = function()
                open()
            end,
        }
    end
    return out
end

---The name each recent problem is listed under: its directory, told apart from another of the
---same name by what differs, the contest directory above it (`2263/A` beside `2264/A`) or,
---for two attempts in one directory, the file (`B (brute.cpp)`).
---@param problems tuna.RecentProblem[]
---@return string[]
local function problem_names(problems)
    local function base(p)
        return p.name or vim.fn.fnamemodify(p.dir or "", ":t")
    end
    local dirs_named, in_dir = {}, {}
    for _, p in ipairs(problems) do
        local name, dir = base(p), p.dir or ""
        dirs_named[name] = dirs_named[name] or {}
        dirs_named[name][dir] = true
        in_dir[dir] = (in_dir[dir] or 0) + 1
    end
    local names = {}
    for i, p in ipairs(problems) do
        local name, dir = base(p), p.dir or ""
        if vim.tbl_count(dirs_named[name]) > 1 then
            name = vim.fn.fnamemodify(vim.fs.dirname(dir), ":t") .. "/" .. name
        end
        if in_dir[dir] > 1 then
            name = name .. " (" .. vim.fn.fnamemodify(p.file or "", ":t") .. ")"
        end
        names[i] = name
    end
    return names
end

---The recent contests and the recent problems, most recent first, as `recent` has them, so
---the board says exactly what `:Tuna last` would do.
---@return table[] contests, table[] problems
local function recent_entries()
    local recent = require("tuna.recent")
    local st = recent.snapshot() or {}
    local contests = entries_of(st.contests or {}, function(_, c)
        local cfg = vim.fn.isdirectory(c.dir or "") == 1 and config.load_local_config_and_extend(c.dir)
            or config.current_setup
            or config.defaults
        local judge, name = recent.contest_label(c, cfg)
        return name or vim.fn.fnamemodify(c.dir or "", ":t"), judge
    end, contest_status, recent.open_contest)

    local names = problem_names(st.problems or {})
    local problems = entries_of(st.problems or {}, function(i)
        return names[i]
    end, function(p)
        return entry_status(p.file)
    end, recent.open_problem)
    return contests, problems
end

--------------------------------------------------------------------------------
-- The right column: what tuna can do from here
--------------------------------------------------------------------------------

---Whether this buffer is something tuna can run — the question that decides which half
---of the command list applies. Asked of the config rather than by building a runner,
---which would notify about a buffer the user only wanted a menu for.
---@param bufnr integer
---@return boolean
local function runnable(bufnr)
    local ft = vim.bo[bufnr].filetype
    local cfg = config.get_buffer_config(bufnr)
    return ft ~= "" and (cfg.run_command or {})[ft] ~= nil
end

---The commands offered, in the order they are reached for. The solution-only half is
---dropped for a buffer tuna cannot run: a scratch buffer has no testcases to add and no
---mode to switch, and offering them would be offering an error message.
---@param sol integer the solution buffer (a helper redirects to its sibling)
---@param cur integer the buffer the menu was opened from
---@return { label: string, run: fun() }[]
local function command_entries(sol, cur)
    local commands = require("tuna.commands")
    local path = api.nvim_buf_get_name(sol)
    local out = {}
    local function add(label, run)
        out[#out + 1] = { label = label, run = run }
    end

    if runnable(sol) then
        local cfg = config.get_buffer_config(sol)
        local mode = tools.resolve_mode(path, cfg)
        local forced = tools.get_mode(path)
        local compare = require("tuna.compare")
        local cmp = tools.get_compare(path)
        local cmp_label = cmp and compare.method_name(cmp)
            or ("default, " .. compare.method_name(cfg.output_compare_method))

        local function switch(m)
            return function()
                tools.set_mode(path, m)
                commands.dispatch_mode(m, {}, true, sol)
            end
        end
        add(("Run  (%s, %s)"):format(mode, forced == mode and "forced" or "automatic"), function()
            commands.dispatch_mode(mode, {}, true, sol)
        end)
        if forced then
            add("Make the run mode automatic", function()
                tools.set_mode(path, nil)
                commands.dispatch_mode((tools.resolve_mode(path, cfg)), {}, true, sol)
            end)
        end
        add("Run all versions", switch("all"))
        add("Stress test", switch("stress"))
        add("Interactive", switch("interactive"))
        add("Show results UI", function()
            commands.show_results_ui(sol)
        end)
        add("Submit", function()
            require("tuna.submit").submit(sol)
        end)
        add("Add testcase", function()
            commands.execute({ "testcase", "add" })
        end)
        local checker = tools.resolve_checker(path, cfg)
        local checker_label = tools.checker_setting(path) == "off" and "off"
            or ("automatic, " .. (type(checker) == "table" and vim.fn.fnamemodify(checker.source or checker.exec, ":t") or "none found"))
        add("Checker: " .. checker_label, function()
            commands.set_checker(sol)
        end)
        add("Compare: " .. cmp_label, function()
            commands.cycle_compare(sol)
        end)
        for _, role in ipairs(require("tuna.tools").ROLES) do
            add("Scaffold " .. role, function()
                require("tuna.scaffold").create(role, cur)
            end)
        end
        add("Next problem", function()
            require("tuna.navigate").go(1)
        end)
        add("Previous problem", function()
            require("tuna.navigate").go(-1)
        end)
    end

    -- Always available: nothing here needs a solution to act on.
    add("Download testcases", function()
        commands.execute({ "download", "testcases" })
    end)
    add("Download problem", function()
        commands.execute({ "download", "problem" })
    end)
    add("Download contest", function()
        commands.execute({ "download", "contest" })
    end)
    add("Temp scratch", function()
        require("tuna.temp").start()
    end)
    add("Library", function()
        require("tuna.library").browse(cur)
    end)
    add("Clean unused files", function()
        require("tuna.clean").clean(sol)
    end)
    return out
end

--------------------------------------------------------------------------------

---The display width of a run of segments.
---@param segments table[]
---@return integer
local function segments_width(segments)
    local w = 0
    for _, seg in ipairs(segments) do
        w = w + api.nvim_strwidth(seg[1])
    end
    return w
end

---A status in its three parts: the count that leads it (`2/7 `, `3/4 `, or nothing), the
---verdict word (the first coloured segment), and whatever a contest counts besides
---(`, 1 REJECTED`). The count and the word each get a column of their own, filled from the
---right, so the counts stack however long the words beside them are and the words end on one
---edge however long the counts are.
---@param status table[]
---@return table[] count, table? word, table[] rest
local function status_parts(status)
    local count, word, rest = {}, nil, {}
    for _, seg in ipairs(status) do
        if word then
            rest[#rest + 1] = seg
        elseif seg[2] then
            word = seg
        else
            count[#count + 1] = seg
        end
    end
    return count, word, rest
end

---`text` cut to at most `max` display cells, an ellipsis marking the cut.
---@param text string
---@param max integer
---@return string
local function fit(text, max)
    if api.nvim_strwidth(text) <= max then
        return text
    end
    if max < 1 then
        return ""
    end
    local n = vim.fn.strchars(text)
    local cut
    repeat
        n = n - 1
        cut = vim.fn.strcharpart(text, 0, n)
    until n <= 0 or api.nvim_strwidth(cut) <= max - 1
    return (cut:gsub("%s+$", "")) .. "…"
end

---An entry's name in at most `max` display cells (nil: whole). A contest shows its judge
---before its name, and gives up the judge first when that is too long: the contest is what
---tells two apart.
---@param e table an entry
---@param max integer?
---@return string
local function entry_name(e, max)
    local full = e.judge and (e.judge .. " " .. e.name) or e.name
    if not max or api.nvim_strwidth(full) <= max then
        return full
    end
    if e.judge then
        local room = max - api.nvim_strwidth(e.name) - 1
        if room >= 2 then
            return fit(e.judge, room) .. " " .. e.name
        end
    end
    return fit(e.name, max)
end

---Lay the recent lists out together, in rows at most `width` display cells wide (nil: as wide
---as they need): names on the left, and every status right of the longest name in any of the
---lists, so statuses line up down the whole stack and never sit under another row's name. A
---status is laid out in the columns `status_parts` gives it, what a contest counts besides
---trailing past them. A width too narrow for all that shortens the names, never the statuses.
---@param lists table[][] entry lists
---@param width integer?
---@return { rows: string[], highlights: { row: integer, col: integer, end_col: integer, group: string }[] }[]
local function recent_layout(lists, width)
    -- What each row is made of, and how wide each column has to be for all of them.
    local parts = {}
    local name_w, count_w, word_w, rest_w = 0, 0, 0, 0
    for l, entries in ipairs(lists) do
        parts[l] = {}
        for i, e in ipairs(entries) do
            local count, word, rest = status_parts(e.status)
            parts[l][i] = { entry = e, count = count, word = word, rest = rest }
            name_w = math.max(name_w, api.nvim_strwidth(entry_name(e)))
            count_w = math.max(count_w, segments_width(count))
            word_w = math.max(word_w, word and api.nvim_strwidth(word[1]) or 0)
            rest_w = math.max(rest_w, segments_width(rest))
        end
    end
    local gap = (count_w + word_w + rest_w) > 0 and 2 or 0
    if width then
        name_w = math.max(0, math.min(name_w, width - gap - count_w - word_w - rest_w))
    end

    local out = {}
    for l, list in ipairs(parts) do
        local rows, highlights = {}, {}
        for i, part in ipairs(list) do
            local row = entry_name(part.entry, name_w)
            ---Put a segment on the row, remembering where a coloured one landed.
            ---@param seg { [1]: string, [2]: string? }
            local function put(seg)
                if seg[2] then
                    highlights[#highlights + 1] = { row = i, col = #row, end_col = #row + #seg[1], group = seg[2] }
                end
                row = row .. seg[1]
            end

            if #part.count > 0 or part.word then
                -- Past the longest name, then each column filled from the right.
                row = row .. string.rep(" ", name_w - api.nvim_strwidth(row) + gap + count_w - segments_width(part.count))
                for _, seg in ipairs(part.count) do
                    put(seg)
                end
                if part.word then
                    row = row .. string.rep(" ", word_w - api.nvim_strwidth(part.word[1]))
                    put(part.word)
                    for _, seg in ipairs(part.rest) do
                        put(seg)
                    end
                end
            end
            rows[i] = row
        end
        out[l] = { rows = rows, highlights = highlights }
    end
    return out
end

---Open the menu for the current (or given) buffer.
---@param bufnr integer? defaults to the current buffer
function M.open(bufnr)
    local cur = bufnr or api.nvim_get_current_buf()
    config.load_buffer_config(cur)
    -- Act on the solution even when opened from a helper buffer (checker.cpp).
    local sol = tools.solution_bufnr(cur, config.get_buffer_config(cur)) or cur

    local contests, problems = recent_entries()
    local lists = { contests, problems }
    -- Laid out for whatever width the board gives the column, so a narrow editor shortens
    -- names rather than cutting off verdicts.
    local function format(l)
        return function(width)
            local laid = recent_layout(lists, width)[l]
            return laid.rows, laid.highlights
        end
    end
    local commands = command_entries(sol, cur)
    local labels = {}
    for i, c in ipairs(commands) do
        labels[i] = c.label
    end

    require("tuna.widgets").panels({
        { title = "Contests", format = format(1), column = 1 },
        { title = "Problems", format = format(2), column = 1 },
        { title = "Catch of the day", items = labels, column = 2 },
    }, "Tuna", function(section, idx)
        if lists[section] then
            local e = lists[section][idx]
            if e then
                e.open()
            end
        else
            local c = commands[idx]
            if c then
                c.run()
            end
        end
    end, api.nvim_get_current_win(), nil, banner(config.get_buffer_config(sol)))
end

M._test = {
    contest_status = contest_status,
    entry_status = entry_status,
    problem_names = problem_names,
    recent_layout = recent_layout,
}

return M
