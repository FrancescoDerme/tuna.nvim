-- lua/tuna/init.lua
local config = require("tuna.config")
local commands = require("tuna.commands")
local receive = require("tuna.receive")

local M = {}

function M.setup(user_opts)
    config.setup(user_opts)

    vim.api.nvim_create_user_command("Tuna", function(opts)
        if #opts.fargs == 0 then
            vim.notify("Tuna: at least one argument required", vim.log.levels.INFO)
            return
        end
        commands.execute(opts.fargs)
    end, {
        nargs = "*",
        desc = "Tuna",
        complete = commands.complete,
    })
end

---lualine component: shows the receive listener's state, or nothing when idle.
function M.lualine_component()
    return receive.status()
end

return M
