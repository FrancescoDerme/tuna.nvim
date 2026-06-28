-- lua/tuna/config.lua
local M = {}

-- Default configuration
M.defaults = {
    compile_directory = ".",
    running_directory = ".",
    -- TODO: add other defaults
    receive_print_message = true,
}

-- Active configuration after setup() is called
M.options = {}

-- Search for and load a local project config
local function get_local_config()
    local cwd = vim.fn.getcwd()
    local local_config_path = cwd .. "/tuna.lua"

    local stat = vim.uv.fs_stat(local_config_path)

    if stat and stat.type == "file" then
        local ok, local_opts = pcall(dofile, local_config_path)
        if ok and type(local_opts) == "table" then
            vim.notify("Tuna: loaded local config from .tuna.lua", vim.log.levels.INFO)
            return local_opts
        else
            vim.notify("Tuna: error parsing .tuna.lua, make sure it returns a table", vim.log.levels.WARN)
        end
    end

    return {}
end

-- Merge user options with the defaults
function M.setup(user_opts)
    user_opts = user_opts or {}
    local local_opts = get_local_config()

    -- Merge the three configurations: defaults <- global user config <- local project config
    -- "force" means user_opts will overwrite M.defaults when the keys match
    M.options = vim.tbl_deep_extend("force", M.defaults, user_opts, local_opts)
end

return M
