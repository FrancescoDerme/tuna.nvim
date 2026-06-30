-- lua/tuna/commands.lua
--
-- The `:Tuna <subcommand> [args…]` surface. `execute` dispatches the parsed
-- argument list to a handler; `complete` provides context-aware tab-completion
-- (subcommand names, then per-subcommand argument lists). The heavier handlers
-- (`edit_testcase`, `delete_testcase`, `convert_testcases`, `run_testcases`,
-- `receive`) live as module functions so they're easy to call and test.

local api = vim.api
local config = require("tuna.config")
local utils = require("tuna.utils")
local testcases = require("tuna.testcases")
local runner = require("tuna.runner")

local M = {}

-- Sub-argument completions for subcommands that take a second word.
local subcommand_args = {
    convert = { "files", "single_file", "directory" },
    receive = { "testcases", "problem", "contest", "persistently", "status", "stop" },
}

--------------------------------------------------------------------------------
-- Testcase editing
--------------------------------------------------------------------------------

---Add a new testcase, or edit an existing one (via the editor, picking first if
---no number is given).
---@param add boolean add a fresh testcase instead of editing
---@param tcnum integer? testcase number to edit
function M.edit_testcase(add, tcnum)
    local bufnr = api.nvim_get_current_buf()
    config.load_buffer_config(bufnr) -- refresh: a local config may have changed
    local tctbl = testcases.buf_get_testcases(bufnr)

    if add then
        tcnum = 0
        while tctbl[tcnum] do
            tcnum = tcnum + 1
        end
        tctbl[tcnum] = { input = "", output = "" }
    end

    local function start_editor(n)
        if not tctbl[n] then
            utils.notify("edit_testcase: testcase " .. tostring(n) .. " doesn't exist.")
            return
        end
        local function save(tc)
            testcases.buf_save_testcase(bufnr, n, tc.input, tc.output)
        end
        local widgets = require("tuna.widgets")
        widgets.editor(bufnr, n, tctbl[n].input, tctbl[n].output, save, api.nvim_get_current_win())
    end

    if tcnum then
        start_editor(tcnum)
    else
        require("tuna.widgets").picker(bufnr, tctbl, "Edit a Testcase", start_editor, api.nvim_get_current_win())
    end
end

---Delete a testcase (picking first if no number is given).
---@param tcnum integer?
function M.delete_testcase(tcnum)
    local bufnr = api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)
    local tctbl = testcases.buf_get_testcases(bufnr)

    local function delete(n)
        if not tctbl[n] then
            utils.notify("delete_testcase: testcase " .. tostring(n) .. " doesn't exist.")
            return
        end
        if vim.fn.confirm("Delete Testcase " .. n .. "?", "&Yes\n&No", 2) ~= 1 then
            return
        end
        testcases.buf_delete_testcase(bufnr, n)
    end

    if tcnum then
        delete(tcnum)
    else
        require("tuna.widgets").picker(bufnr, tctbl, "Delete a Testcase", delete, api.nvim_get_current_win())
    end
end

---Convert this buffer's testcases to a different storage backend. Unlike
---competitest's two-way single-file↔files switch, tuna converts to any of the
---three storage modes (see DIFFERENCES.md).
---@param target string "files" | "single_file" | "directory"
function M.convert_testcases(target)
    if not testcases.backends[target] then
        utils.notify("convert: unknown storage '" .. tostring(target) .. "'. Use files | single_file | directory.")
        return
    end
    local bufnr = api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)
    -- buf_get_testcases auto-detects whichever backend currently holds them.
    local tctbl = testcases.buf_get_testcases(bufnr)
    if next(tctbl) == nil then
        utils.notify("convert: there's nothing to convert.")
        return
    end

    -- Clear every backend's on-disk storage, then write to the target one.
    for _, backend in pairs(testcases.backends) do
        backend.buf_clear(bufnr)
    end
    testcases.buf_write_testcases(bufnr, tctbl, target)
    utils.notify("converted testcases to '" .. target .. "' storage.", "INFO")
end

--------------------------------------------------------------------------------
-- Running
--------------------------------------------------------------------------------

---Runners kept per buffer so re-runs and `show_ui` reuse the same state.
---@type table<integer, tuna.TCRunner>
M.runners = {}

---Run testcases (or a subset), and show the results UI.
---@param list string[]? testcase numbers to run, or nil for all
---@param compile boolean compile before running
---@param only_show boolean just (re)open the UI without running
function M.run_testcases(list, compile, only_show)
    local bufnr = api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)
    local tctbl = testcases.buf_get_testcases(bufnr)

    if list then
        local subset = {}
        for _, s in ipairs(list) do
            local n = tonumber(s)
            if not n or not tctbl[n] then
                utils.notify("run: testcase " .. s .. " doesn't exist.")
            else
                subset[n] = tctbl[n]
            end
        end
        tctbl = subset
    end

    if not M.runners[bufnr] then
        local r = runner.new(bufnr)
        if not r then
            return -- runner.new already notified
        end
        M.runners[bufnr] = r
        -- Drop the runner when its buffer unloads.
        api.nvim_create_autocmd("BufUnload", {
            buffer = bufnr,
            callback = function()
                M.runners[bufnr] = nil
            end,
        })
    end

    local r = M.runners[bufnr]
    if not only_show then
        r:kill_all_processes()
        r:run_testcases(tctbl, compile)
    end
    r:show_ui()
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

---Drive the Competitive Companion receiver.
---@param mode string "testcases" | "problem" | "contest" | "persistently" | "status" | "stop"
function M.receive(mode)
    local receive = require("tuna.receive")
    local err
    if mode == "stop" then
        receive.stop_receiving()
    elseif mode == "status" then
        receive.show_status()
    elseif mode == "testcases" then
        local bufnr = api.nvim_get_current_buf()
        config.load_buffer_config(bufnr)
        local cfg = config.get_buffer_config(bufnr)
        err = receive.start_receiving("testcases", cfg.companion_port, cfg.receive_print_message, cfg.receive_print_message, bufnr, cfg)
    elseif mode == "problem" or mode == "contest" or mode == "persistently" then
        local cfg = config.load_local_config_and_extend(vim.fn.getcwd())
        err = receive.start_receiving(mode, cfg.companion_port, cfg.receive_print_message, cfg.receive_print_message, nil, cfg)
    else
        err = "unrecognized mode '" .. tostring(mode) .. "'"
    end
    if err then
        utils.notify("receive: " .. err)
    end
end

--------------------------------------------------------------------------------
-- Dispatch + completion
--------------------------------------------------------------------------------

---Subcommand handlers. Each receives the trailing argument list.
---@type table<string, fun(args: string[])>
M.subcommands = {
    add_testcase = function()
        M.edit_testcase(true)
    end,
    edit_testcase = function(args)
        M.edit_testcase(false, tonumber(args[1]))
    end,
    delete_testcase = function(args)
        M.delete_testcase(tonumber(args[1]))
    end,
    convert = function(args)
        if not args[1] then
            utils.notify("convert: a target storage is required (files | single_file | directory).")
            return
        end
        M.convert_testcases(args[1])
    end,
    run = function(args)
        M.run_testcases(#args > 0 and args or nil, true, false)
    end,
    run_no_compile = function(args)
        M.run_testcases(#args > 0 and args or nil, false, false)
    end,
    show_ui = function()
        M.run_testcases(nil, false, true)
    end,
    receive = function(args)
        if not args[1] then
            utils.notify("receive: a mode is required (testcases | problem | contest | persistently | status | stop).")
            return
        end
        M.receive(args[1])
    end,
    stress = function(args)
        require("tuna.stress").run(api.nvim_get_current_buf(), tonumber(args[1]))
    end,
}

---Dispatch a parsed `:Tuna` argument list (subcommand + its arguments).
---@param args string[] the full fargs list (args[1] is the subcommand)
function M.execute(args)
    local sub = M.subcommands[args[1]]
    if not sub then
        utils.notify("unknown subcommand '" .. tostring(args[1]) .. "'.")
        return
    end
    sub({ unpack(args, 2) })
end

---Tab-completion for `:Tuna`: subcommand names, then per-subcommand arguments.
---@param arg_lead string the word being completed
---@param cmd_line string the whole command line so far
---@param cursor_pos integer cursor byte position in `cmd_line`
---@return string[]
function M.complete(arg_lead, cmd_line, cursor_pos)
    local prefix = cmd_line:sub(1, cursor_pos)
    local ending_space = prefix:sub(-1) == " "
    local words = vim.split(prefix, "%s+", { trimempty = true }) -- words[1] == "Tuna"
    local count = #words

    ---@type string[]
    local candidates
    if count == 1 or (count == 2 and not ending_space) then
        candidates = vim.tbl_keys(M.subcommands)
    elseif count == 2 or (count == 3 and not ending_space) then
        candidates = subcommand_args[words[2]] or {}
    else
        return {}
    end

    table.sort(candidates)
    return vim.tbl_filter(function(c)
        return c:sub(1, #arg_lead) == arg_lead
    end, candidates)
end

return M
