-- lua/tuna/dashboard.lua
--
-- The `:Tuna` dashboard — the single entry point opened by a bare `:Tuna` (and by
-- `:Tuna dashboard`). Two columns, side by side, in one float:
--
--   * **Recent** — the contest and the problem `:Tuna last …` would return to, each
--     with how it went. `<CR>` goes there.
--   * **Commands** — what tuna can do from the file you are on. `<CR>` runs it.
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
-- dashboard. `dashboard.header` replaces it with lines of your own, or turns it off.
local BANNER = {
    "  ██████████  ███    ███  ███     ███     ██████   ",
    "  ██████████  ███    ███  ████    ███    ███  ███  ",
    "    ███      ███    ███  ███ ██  ███   ███    ███  ",
    "    ███      ███    ███  ███  ██ ███  ████████████ ",
    "   ███      ██████████  ███   █████  ███      ███  ",
    "   ███       ████████   ███     ███  ███      ███  ",
}

---The banner rows to draw, from `config.dashboard.header`: a list of lines of your own,
---`false` for none, or nothing at all for the shipped one.
---@param cfg table
---@return string[]?
local function banner(cfg)
    local h = (cfg.dashboard or {}).header
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

---How a problem's local run went, if it is still known. Results are not persisted —
---they describe a build that may no longer exist, which is why a submit verdict carries
---an mtime and a run does not — so this answers only for a file whose runner is still
---in this session. That is the common case for the problem you are on and never the
---case for one you have not opened, which is exactly the right side to be wrong on.
---@param path string
---@return string? e.g. "4/5 passed"
local function local_results(path)
    if path == "" then
        return nil
    end
    local bufnr = vim.fn.bufnr(path)
    if bufnr == -1 then
        return nil
    end
    local runner = require("tuna.commands").runners[bufnr]
    if not runner or runner.preloaded then
        return nil -- listed, never run: there is no result to report
    end
    local passed, total = 0, 0
    for _, tc in ipairs(runner.tcdata or {}) do
        if type(tc.tcnum) == "number" and tc.status ~= "" and tc.status ~= "NOT RUN" then
            total = total + 1
            if tc.status == "CORRECT" then
                passed = passed + 1
            end
        end
    end
    if total == 0 then
        return nil
    end
    return ("%d/%d passed"):format(passed, total)
end

---What to say about a recent entry, in the order the user asks for it: the judge's
---verdict when there is one, else how the local testcases went, else nothing. A judge
---has the last word because it is the answer that settles the problem; local results
---are the best available guess until it arrives.
---@param path string? the solution file the entry stands for
---@return string status, string highlight-ish kind ("verdict" | "local" | "none")
local function entry_status(path)
    if not path or path == "" then
        return "", "none"
    end
    local verdict = require("tuna.submit").verdict_for(path)
    if verdict then
        return verdict.text, "verdict"
    end
    local results = local_results(path)
    if results then
        return results, "local"
    end
    return "", "none"
end

---The two rows of the Recent column: the contest and the problem `:Tuna last …` opens.
---Both are read from `recent.state`, so the board says exactly what those commands
---would do — including saying nothing when they would refuse.
---@return { label: string, name: string, status: string, open: fun()? }[]
local function recent_entries()
    local recent = require("tuna.recent")
    local st = recent.snapshot() or {}
    local out = {}

    local c = st.contest
    out[#out + 1] = {
        label = "Contest",
        name = c and c.name or "—",
        -- A contest has no verdict of its own; the problem last worked on inside it is
        -- the closest thing to "how this contest is going".
        status = c and select(1, entry_status(c.problem)) or "",
        open = c and function()
            recent.open_contest()
        end or nil,
    }

    local p = st.problem
    out[#out + 1] = {
        label = "Problem",
        name = p and vim.fn.fnamemodify(p.dir, ":t") or "—",
        status = p and select(1, entry_status(p.file)) or "",
        open = p and function()
            recent.open_problem()
        end or nil,
    }
    return out
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
---@param cur integer the buffer the dashboard was opened from
---@return { label: string, run: fun() }[]
local function command_entries(sol, cur)
    local commands = require("tuna.commands")
    local path = api.nvim_buf_get_name(sol)
    local dir = vim.fn.fnamemodify(path, ":p:h")
    local out = {}
    local function add(label, run)
        out[#out + 1] = { label = label, run = run }
    end

    if runnable(sol) then
        local cfg = config.get_buffer_config(sol)
        local mode = tools.resolve_mode(path, dir, cfg)
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
        add("Run  (" .. mode .. ")", switch(mode))
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
        add("Checker: " .. (tools.checker_enabled(path) and "on" or "off"), function()
            commands.set_checker(sol)
        end)
        add("Compare: " .. cmp_label, function()
            commands.cycle_compare(sol)
        end)
        for _, kind in ipairs({ "checker", "generator", "brute", "interactor" }) do
            add("Scaffold " .. kind, function()
                require("tuna.scaffold").create(kind, cur)
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

---Lay the recent entries out as aligned rows: label, name, status. Aligned rather than
---run together because the three read as columns — which entry, which problem, how it
---went — and a ragged middle makes the status hard to find.
---@param entries table[]
---@return string[]
local function recent_rows(entries)
    local lw, nw = 0, 0
    for _, e in ipairs(entries) do
        lw = math.max(lw, api.nvim_strwidth(e.label))
        nw = math.max(nw, api.nvim_strwidth(e.name))
    end
    local rows = {}
    for i, e in ipairs(entries) do
        local row = e.label .. string.rep(" ", lw - api.nvim_strwidth(e.label) + 2) .. e.name
        if e.status ~= "" then
            row = row .. string.rep(" ", nw - api.nvim_strwidth(e.name) + 2) .. e.status
        end
        rows[i] = row
    end
    return rows
end

---Open the dashboard for the current (or given) buffer.
---@param bufnr integer? defaults to the current buffer
function M.open(bufnr)
    local cur = bufnr or api.nvim_get_current_buf()
    config.load_buffer_config(cur)
    -- Act on the solution even when opened from a helper buffer (checker.cpp).
    local sol = tools.solution_bufnr(cur, config.get_buffer_config(cur)) or cur

    local entries = recent_entries()
    local commands = command_entries(sol, cur)
    local labels = {}
    for i, c in ipairs(commands) do
        labels[i] = c.label
    end

    require("tuna.widgets").panels({
        { title = "Recent", items = recent_rows(entries) },
        { title = "Commands", items = labels },
    }, "Tuna", function(section, idx)
        if section == 1 then
            local e = entries[idx]
            if e and e.open then
                e.open()
            elseif e then
                -- Nothing recorded yet. `recent`'s own commands explain what to do about
                -- that, and say it better than a dashboard row can, so defer to them.
                if idx == 1 then
                    require("tuna.recent").open_contest()
                else
                    require("tuna.recent").open_problem()
                end
            end
        else
            local c = commands[idx]
            if c then
                c.run()
            end
        end
    end, api.nvim_get_current_win(), nil, banner(config.get_buffer_config(sol)))
end

return M
