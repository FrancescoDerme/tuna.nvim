-- lua/tuna/init.lua
local config = require("tuna.config")
local commands = require("tuna.commands")

local M = {}

-- Handle autocomplete logic dynamically based on the commabds module
local function command_complete(arg_lead, cmd_line, cursos_pos)
    local subcommands = commands.get_complete_list()
    local matches = {}

    for _, subcmd in ipairs(subcommands) do
        if subcmd:sub(1, #arg_lead) == arg_lead then
            table.insert(matches, subcmd)
        end
    end

    return matches
end

function M.setup(user_opts)
    -- Parse and merge the configuration
    config.setup(user_opts)

    -- Create user command
    vim.api.nvim_create_user_command("Tuna", function(opts)
        -- opts.fargs contains the arguments passed to the command, e.g. {"run"}
        local args = opts.fargs
        if #args == 0 then
            vim.notify("Tuna: at least one argument required", vim.log.levels.ERROR)
            return
        end

        -- Hand off execution to the router in the commands module
        commands.execute(args)
    end, {
        nargs = "*", -- Accepts any number of arguments
        desc = "Tuna",
        complete = command_complete, -- Attach the complletion function
    })

    -- TODO: setup highlight groups
end

return M
