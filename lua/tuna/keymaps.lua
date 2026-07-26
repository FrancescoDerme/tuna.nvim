-- lua/tuna/keymaps.lua
--
-- Opt-in default keymaps. Rather than hand-writing `vim.keymap.set(...)` in an
-- ftplugin (or scattered through a config), a user maps an **action** to a key in
-- `config.keymaps` — or takes the whole ready-made set with
-- `keymaps.preset = "<leader>t"` (see `M.preset`) and adjusts individual keys on top
-- of it. This module sets them as `<cmd>Tuna …<cr>` maps. Two scopes:
--
--   * `keymaps.mappings` — buffer-local maps set on the configured solution
--     filetypes via a `FileType` autocmd, so they follow the user from one problem
--     to the next (what an ftplugin used to give).
--   * `keymaps.global`   — always-available maps set once at setup, regardless of
--     the current buffer (handy for buffer-agnostic actions like `dashboard`/`receive_*`).
--
-- Nothing is mapped unless the user opts in (both tables empty by default).

local M = {}

-- Action name -> the Ex command a mapping runs (wrapped as `<cmd>… <cr>`). Keep
-- these aligned with the :Tuna subcommand surface in commands.lua.
M.actions = {
    dashboard = "Tuna", -- bare :Tuna opens the dashboard
    run = "Tuna run",
    run_all = "Tuna run all",
    run_stress = "Tuna run stress",
    run_interactive = "Tuna run interactive",
    show_ui = "Tuna show_ui",
    add_testcase = "Tuna add_testcase",
    edit_testcase = "Tuna edit_testcase",
    delete_testcase = "Tuna delete_testcase",
    submit = "Tuna submit",
    submit_clear = "Tuna submit clear", -- dismiss a lingering lualine verdict / cancel a submit
    receive_testcases = "Tuna receive testcases",
    receive_problem = "Tuna receive problem",
    receive_contest = "Tuna receive contest",
    clean = "Tuna clean",
    next_problem = "Tuna next", -- step to the next/previous problem of a contest
    prev_problem = "Tuna prev",
    temp = "Tuna temp", -- scratch solution to write in before the problem exists
    temp_sync = "Tuna temp sync",
}

-- The ready-made preset, enabled with `keymaps.preset = "<leader>t"` (any prefix).
-- Suffixes are grouped by subject, so which-key shows one "Tuna" group with a
-- "testcases" and a "download" subgroup under it:
--
--   <leader>tta  add testcase       <leader>tr  run            <leader>tdt  testcases
--   <leader>tte  edit testcase      <leader>tu  show ui        <leader>tdp  problem
--   <leader>ttd  delete testcase    <leader>ts  submit         <leader>tdc  contest
--   <leader>tn   next problem       <leader>tm  dashboard      <leader>tds  temp sync
--   <leader>tp   previous problem   <leader>tw  temp scratch
--
-- No group prefix is itself a mapping, so none of them costs a `timeoutlen` wait.
-- `:Tuna clean` is deliberately absent: it is run once in a while, not during a
-- contest, and the dashboard is where it belongs (the `clean` action is still there
-- for anyone who wants to map it).
--
-- `buffer` maps are set on solution filetypes only; `global` ones are always there,
-- because they are what you reach for when no solution is open yet.
M.preset = {
    buffer = {
        add_testcase = "ta",
        edit_testcase = "te",
        delete_testcase = "td",
        run = "r",
        show_ui = "u",
        submit = "s",
        next_problem = "n",
        prev_problem = "p",
        receive_testcases = "dt",
    },
    global = {
        dashboard = "m",
        temp = "w", -- w for write-ahead: the scratch written before the problem exists
        temp_sync = "ds",
        receive_problem = "dp",
        receive_contest = "dc",
    },
}

---Expand `M.preset` against a prefix, with the user's own tables layered on top so a
---single key can be moved (or dropped, by mapping it to `false`) without giving up
---the preset.
---@param prefix string e.g. "<leader>t"
---@param scope "buffer"|"global"
---@param user table<string, string|string[]|false>
---@return table<string, string|string[]>
local function expand_preset(prefix, scope, user)
    local out = {}
    for action, suffix in pairs(M.preset[scope]) do
        out[action] = prefix .. suffix
    end
    for action, lhs in pairs(user) do
        out[action] = lhs or nil -- `false` removes a preset entry
    end
    return out
end

---The configured solution filetypes, with a sane fallback.
---@param km table the resolved `config.keymaps` table
---@return string[]
local function filetypes(km)
    return km.filetypes or { "c", "cpp", "rust", "java", "python" }
end

---Set the action->lhs maps in `mapping_tbl`, merging `base_opts` into each
---`vim.keymap.set` call (e.g. `{ buffer = n }` for buffer-local, `{}` for global).
---Unknown actions are skipped here (they're reported once in `setup`).
---@param mapping_tbl table<string, string|string[]>
---@param base_opts table
local function set_maps(mapping_tbl, base_opts)
    for action, lhs in pairs(mapping_tbl) do
        local rhs = M.actions[action]
        if rhs and lhs then
            -- Bare, capitalized label (no "Tuna:" prefix) — these live under a
            -- dedicated which-key group, so the "Tuna" context is already implied.
            local label = action:gsub("_", " ")
            label = label:sub(1, 1):upper() .. label:sub(2)
            for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
                local opts = vim.tbl_extend("force", base_opts, {
                    silent = true,
                    desc = label,
                })
                vim.keymap.set("n", key, "<cmd>" .. rhs .. "<cr>", opts)
            end
        end
    end
end

---Warn once for any action name in `mapping_tbl` this module doesn't know.
---@param mapping_tbl table
---@param scope string label for the message ("mappings" | "global")
local function warn_unknown(mapping_tbl, scope)
    for action in pairs(mapping_tbl) do
        if not M.actions[action] then
            require("tuna.utils").notify(
                ("keymaps: unknown action '%s' in %s (see keymaps.lua M.actions)."):format(action, scope),
                "WARN"
            )
        end
    end
end

---Install the opt-in keymaps: set the always-available `global` maps once, and
---register a `FileType` autocmd that applies the buffer-local `mappings` on the
---solution filetypes (also covering already-open buffers, for a lazy-loaded setup).
function M.setup()
    local km = require("tuna.config").current_setup.keymaps
    if type(km) ~= "table" then
        return
    end
    local mappings = type(km.mappings) == "table" and km.mappings or {}
    local global = type(km.global) == "table" and km.global or {}
    -- `preset = "<leader>t"` fills both tables with the ready-made set; whatever the
    -- user wrote stays on top of it.
    if type(km.preset) == "string" then
        mappings = expand_preset(km.preset, "buffer", mappings)
        global = expand_preset(km.preset, "global", global)
    end
    if vim.tbl_isempty(mappings) and vim.tbl_isempty(global) then
        return
    end

    -- Always-available maps: set immediately, once.
    if not vim.tbl_isempty(global) then
        warn_unknown(global, "global")
        set_maps(global, {})
    end

    -- Buffer-local maps: applied per solution buffer via FileType.
    if not vim.tbl_isempty(mappings) then
        warn_unknown(mappings, "mappings")
        local fts = filetypes(km)
        vim.api.nvim_create_autocmd("FileType", {
            group = vim.api.nvim_create_augroup("TunaKeymaps", { clear = true }),
            pattern = fts,
            callback = function(ev)
                set_maps(mappings, { buffer = ev.buf })
            end,
            desc = "Set Tuna's opt-in solution keymaps",
        })

        -- setup() may run after solution buffers are already open (lazy-loaded
        -- plugin); map those too so keymaps aren't missing until the next FileType.
        local want = {}
        for _, ft in ipairs(fts) do
            want[ft] = true
        end
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) and want[vim.bo[buf].filetype] then
                set_maps(mappings, { buffer = buf })
            end
        end
    end
end

return M
