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
--     the current buffer (handy for buffer-agnostic actions like `dashboard`/`download_*`).
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
    -- The action names stay per-verb (a key maps to one thing); only the command they
    -- run gained its subject-first shape.
    add_testcase = "Tuna testcase add",
    edit_testcase = "Tuna testcase edit",
    delete_testcase = "Tuna testcase delete",
    submit = "Tuna submit",
    submit_clear = "Tuna submit clear", -- dismiss a lingering lualine verdict / cancel a submit
    download_testcases = "Tuna download testcases",
    download_problem = "Tuna download problem",
    download_contest = "Tuna download contest",
    clean = "Tuna clean",
    next_problem = "Tuna next", -- step to the next/previous problem of a contest
    prev_problem = "Tuna prev",
    last_problem = "Tuna last problem", -- back to the problem/contest last worked on
    last_contest = "Tuna last contest",
    temp = "Tuna temp", -- scratch solution to write in before the problem exists
    -- A download like the others, except it folds the `:Tuna temp` scratch into the
    -- problem it opens — hence its name and its place in the download group.
    download_sync = "Tuna download sync",
    library = "Tuna lib", -- copy from your snippet library: file, then snippet
    library_snippet = "Tuna lib snippet", -- … or straight from every snippet in it
    library_search = "Tuna lib search", -- … or fuzzily, over names and code, via telescope
}

-- The ready-made preset, enabled with `keymaps.preset = "<leader>t"` (any prefix).
-- Suffixes are grouped by subject, so which-key shows one "Tuna" group with a
-- "testcases" and a "download" subgroup under it:
--
--   <leader>tta  Add                <leader>tr  Run            <leader>tdt  Testcases
--   <leader>tte  Edit               <leader>tu  Show ui        <leader>tdp  Problem
--   <leader>ttd  Delete             <leader>ts  Submit         <leader>tdc  Contest
--   <leader>tn   Next problem       <leader>tm  Dashboard      <leader>tds  Sync
--   <leader>tp   Prev problem       <leader>tw  Temp
--   <leader>tl   Library
--   <leader>tgp  Problem            <leader>tgc Contest
--
-- The labels above are the which-key entries. A key inside a group does not repeat
-- what the group already says (`tt` "Testcases" → `Add`, `td` "Download" → `Problem`,
-- `tg` "Go to" → `Contest`); an ungrouped one keeps its full name, since nothing else
-- supplies the noun. See `M.preset_labels`.
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
        -- The library inserts into the file you are in, so it is buffer-local like the
        -- rest of the editing actions. Only the file→snippet route is bound; the flat
        -- `library_snippet` one is there to map if it suits you better.
        library = "l",
        download_testcases = "dt",
    },
    global = {
        dashboard = "m",
        temp = "w", -- w for write-ahead: the scratch written before the problem exists
        download_sync = "ds",
        download_problem = "dp",
        download_contest = "dc",
        -- "go to": back to where you were working. Global, and deliberately so —
        -- these are what you press right after starting Neovim, with no solution
        -- open yet.
        last_problem = "gp",
        last_contest = "gc",
    },
}

-- Labels for the preset's **grouped** keys, where the group has already said the noun.
-- A which-key group is a word the user reads before the entry — `<leader>tt` is
-- "Testcases", `<leader>td` is "Download", `<leader>tg` is "Go to" — so the derived
-- `Add testcase` / `Download problem` / `Last problem` say it twice. These are used
-- **only** while an action is still on its preset key: move it out of the group with
-- your own `mappings` and it goes back to the full label, which is the one that makes
-- sense standing alone.
M.preset_labels = {
    add_testcase = "Add", -- under "Testcases"
    edit_testcase = "Edit",
    delete_testcase = "Delete",
    download_testcases = "Testcases", -- under "Download"
    download_problem = "Problem",
    download_contest = "Contest",
    download_sync = "Sync",
    last_problem = "Problem", -- under "Go to"
    last_contest = "Contest",
}

---Expand `M.preset` against a prefix, with the user's own tables layered on top so a
---single key can be moved (or dropped, by mapping it to `false`) without giving up
---the preset.
---@param prefix string e.g. "<leader>t"
---@param scope "buffer"|"global"
---@param user table<string, string|string[]|false>
---@return table<string, string|string[]> mapping, table<string, string> labels
local function expand_preset(prefix, scope, user)
    local out, groups = {}, {}
    for action, suffix in pairs(M.preset[scope]) do
        out[action] = prefix .. suffix
        -- A two-character suffix is a group plus a key within it (`ta`, `dp`, `gc`);
        -- a one-character one sits directly under the prefix and has no group.
        if #suffix > 1 then
            groups[action] = prefix .. suffix:sub(1, 1)
        end
    end
    for action, lhs in pairs(user) do
        out[action] = lhs or nil -- `false` removes a preset entry
    end

    local labels = {}
    for action, group in pairs(groups) do
        local lhs = out[action]
        local first = type(lhs) == "table" and lhs[1] or lhs
        -- Only while the key is still inside its group: a moved one needs the full
        -- label back, since nothing is left to supply the noun.
        if type(first) == "string" and first:sub(1, #group) == group and M.preset_labels[action] then
            labels[action] = M.preset_labels[action]
        end
    end
    return out, labels
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
---@param labels table<string, string>? short labels for keys whose which-key group
---  already names the subject (see `M.preset_labels`); the derived name is used for
---  anything not listed
local function set_maps(mapping_tbl, base_opts, labels)
    for action, lhs in pairs(mapping_tbl) do
        local rhs = M.actions[action]
        if rhs and lhs then
            -- Bare, capitalized label (no "Tuna:" prefix) — these live under a
            -- dedicated which-key group, so the "Tuna" context is already implied.
            local label = (labels or {})[action]
            if not label then
                label = action:gsub("_", " ")
                label = label:sub(1, 1):upper() .. label:sub(2)
            end
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
    -- Short labels for the preset's grouped keys, empty when the preset is off (a
    -- hand-written mapping has no group behind it to borrow a noun from).
    local mlabels, glabels = {}, {}
    -- `preset = "<leader>t"` fills both tables with the ready-made set; whatever the
    -- user wrote stays on top of it.
    if type(km.preset) == "string" then
        mappings, mlabels = expand_preset(km.preset, "buffer", mappings)
        global, glabels = expand_preset(km.preset, "global", global)
    end
    if vim.tbl_isempty(mappings) and vim.tbl_isempty(global) then
        return
    end

    -- Always-available maps: set immediately, once.
    if not vim.tbl_isempty(global) then
        warn_unknown(global, "global")
        set_maps(global, {}, glabels)
    end

    -- Buffer-local maps: applied per solution buffer via FileType.
    if not vim.tbl_isempty(mappings) then
        warn_unknown(mappings, "mappings")
        local fts = filetypes(km)
        vim.api.nvim_create_autocmd("FileType", {
            group = vim.api.nvim_create_augroup("TunaKeymaps", { clear = true }),
            pattern = fts,
            callback = function(ev)
                set_maps(mappings, { buffer = ev.buf }, mlabels)
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
                set_maps(mappings, { buffer = buf }, mlabels)
            end
        end
    end
end

return M
