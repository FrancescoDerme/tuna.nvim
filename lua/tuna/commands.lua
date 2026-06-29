-- lua/tuna/commands.lua
local M = {}

local runner = require("tuna.runner")
local testcases = require("tuna.testcases")

M.subcommands = {
    receive = function()
        vim.notify("Tuna: competitive-companion integration is planned", vim.log.levels.INFO)
    end,
    compile = function()
        runner.new():compile()
    end,
    run = function()
        runner.new():run()
    end,
    test = function()
        runner.new():run()
    end,
    add_testcase = function()
        local name = vim.fn.input("Testcase name: ", "sample")
        if name == "" then
            return
        end

        local ok, err = testcases.add(vim.fn.getcwd(), name)
        if ok then
            vim.notify("Tuna: created testcase " .. name, vim.log.levels.INFO)
        else
            vim.notify("Tuna: " .. tostring(err), vim.log.levels.ERROR)
        end
    end,
}

function M.execute(args)
    local subcmd_name = args[1]
    local subcmd_fn = M.subcommands[subcmd_name]

    if subcmd_fn then
        subcmd_fn(unpack(args, 2))
    else
        vim.notify("Tuna: unknown subcommand '" .. tostring(subcmd_name) .. "'", vim.log.levels.ERROR)
    end
end

function M.get_complete_list()
    local keys = {}
    for k, _ in pairs(M.subcommands) do
        table.insert(keys, k)
    end

    table.sort(keys)
    return keys
end

return M
