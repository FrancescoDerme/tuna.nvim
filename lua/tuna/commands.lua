-- lua/tuna/commands.lua
local M = {}

local runner = require("tuna.runner")

-- Map subcommands to their handler functions
M.subcommands = {
    receive = function()
        vim.notify("Tuna: starting receive server", vim.log.levels.INFO)
        -- receive.start_server()
    end,
    run = function()
        -- Create a new runner for the current buffer and trigger run()
        local r = runner.new()
        r:run()
    end,
    add_testcase = function()
        vim.notify("Tuna: sdding testcase", vim.log.levels.INFO)
        -- testcases.add()
    end,
}

-- Dispatcher function called by the user command
function M.execute(args)
    local subcmd_name = args[1]
    local subcmd_fn = M.subcommands[subcmd_name]

    if subcmd_fn then
        -- unpack passes any subsequent arguments to the function
        subcmd_fn(unpack(args, 2))
    else
        vim.notify("Tuna: unknown subcommand '" .. tostring(subcmd_name) .. "'", vim.log.levels.ERROR)
    end
end

-- Generate autocompletion items
function M.get_complete_list()
    local keys = {}
    for k, _ in pairs(M.subcommands) do
        table.insert(keys, k)
    end

    table.sort(keys)
    return keys
end

return M
