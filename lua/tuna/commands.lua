-- lua/tuna/commands.lua
local M = {}

local http = require("tuna.http")
local runner = require("tuna.runner")
local testcases = require("tuna.testcases")

M.subcommands = {
    download_problem = function(port, host)
        local ok, err = http.start_server(port, host, { mode = "problem", download_state = {} })
        if ok then
            vim.notify("Tuna: ready to receive a problem. Press the green plus button in your browser.", vim.log.levels.INFO)
        else
            vim.notify("Tuna: failed to start listener: " .. tostring(err), vim.log.levels.ERROR)
        end
    end,
    download_contest = function(port, host)
        local ok, err = http.start_server(port, host, { mode = "contest", download_state = {} })
        if ok then
            vim.notify("Tuna: ready to receive a contest. Press the green plus button in your browser.", vim.log.levels.INFO)
        else
            vim.notify("Tuna: failed to start listener: " .. tostring(err), vim.log.levels.ERROR)
        end
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
