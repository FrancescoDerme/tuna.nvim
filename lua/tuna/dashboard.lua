-- lua/tuna/dashboard.lua
--
-- The `:Tuna` dashboard — the single entry point opened by a bare `:Tuna` (and by
-- `:Tuna dashboard`). It is a native floating chooser (via `widgets.menu`) for the
-- per-buffer run workflow: switch the buffer's run mode (normal / run-all / stress /
-- interactive — what a later bare `:Tuna run` repeats), toggle the checker, cycle the
-- compare method, show the results UI, scaffold a helper, or clean unused files.
--
-- This supersedes the old "mode-switcher menu"; the dashboard will grow into the
-- Workstream-5 contest hub. The per-mode actions live on `commands` (required lazily
-- to avoid a load-order cycle), so this module stays a thin presentation layer.

local api = vim.api
local config = require("tuna.config")
local tools = require("tuna.tools")

local M = {}

---Open the dashboard for the current (or given) buffer. Selecting a mode sets it as
---the buffer's active mode (so a later bare `:Tuna run` repeats it) and runs it now;
---the checker entry toggles special-judge use; the compare entry cycles the method;
---scaffold entries drop in a helper; clean removes unused files.
---@param bufnr integer? defaults to the current buffer
function M.open(bufnr)
    local commands = require("tuna.commands")
    local cur = bufnr or api.nvim_get_current_buf()
    config.load_buffer_config(cur)
    -- Operate on the solution even when opened from a helper buffer (checker.cpp).
    local sol = tools.solution_bufnr(cur, config.get_buffer_config(cur)) or cur
    local path = api.nvim_buf_get_name(sol)
    local dir = vim.fn.fnamemodify(path, ":p:h")
    -- Show the mode a bare `:Tuna run` would actually use (explicit or detected).
    local mode = tools.resolve_mode(path, dir, config.get_buffer_config(sol))
    local checker_on = tools.checker_enabled(path)
    local cmp_override = tools.get_compare(path)
    local cmp_label = cmp_override and require("tuna.compare").method_name(cmp_override)
        or ("default (" .. require("tuna.compare").method_name(
            config.get_buffer_config(sol).output_compare_method
        ) .. ")")

    local function switch(m)
        return function()
            tools.set_mode(path, m)
            commands.dispatch_mode(m, {}, true, sol)
        end
    end

    local actions = {
        { "Run (mode: " .. mode .. ")", switch(mode) },
        { "Mode → normal", switch("normal") },
        { "Mode → run all versions", switch("all") },
        { "Mode → stress test", switch("stress") },
        { "Mode → interactive", switch("interactive") },
        { "Checker: " .. (checker_on and "on (click to disable)" or "off (click to enable)"), function()
            commands.set_checker(sol)
        end },
        { "Compare: " .. cmp_label .. " (click to cycle)", function()
            commands.cycle_compare(sol)
        end },
        { "Show results UI", function() commands.show_results_ui(sol) end },
        { "Scaffold: checker", function() require("tuna.scaffold").create("checker", cur) end },
        { "Scaffold: generator", function() require("tuna.scaffold").create("generator", cur) end },
        { "Scaffold: brute", function() require("tuna.scaffold").create("brute", cur) end },
        { "Scaffold: interactor", function() require("tuna.scaffold").create("interactor", cur) end },
        { "Clean unused files…", function() require("tuna.clean").clean(sol) end },
    }
    local labels = {}
    for i, a in ipairs(actions) do
        labels[i] = a[1]
    end
    require("tuna.widgets").menu(labels, "Tuna", function(idx)
        actions[idx][2]()
    end, api.nvim_get_current_win())
end

return M
