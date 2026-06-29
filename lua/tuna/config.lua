-- lua/tuna/config.lua
local M = {}

M.defaults = {
    compile_directory = ".",
    running_directory = ".",
    show_output = true,
    auto_open_output = true,
    receive_print_message = true,

    compile_command = {
        cpp = { exec = "g++", args = { "-Wall", "$(FNAME)", "-o", "$(FNOEXT)" } },
        c = { exec = "gcc", args = { "-Wall", "$(FNAME)", "-o", "$(FNOEXT)" } },
    },
    run_command = {
        cpp = { exec = "./$(FNOEXT)" },
        c = { exec = "./$(FNOEXT)" },
        python = { exec = "python3", args = { "$(FNAME)" } },
    },
}

M.options = {}

local function get_local_config()
    local cwd = vim.fn.getcwd()
    local candidates = { cwd .. "/tuna.lua", cwd .. "/.tuna.lua" }

    for _, local_config_path in ipairs(candidates) do
        local stat = vim.uv.fs_stat(local_config_path)
        if stat and stat.type == "file" then
            local ok, local_opts = pcall(dofile, local_config_path)
            if ok and type(local_opts) == "table" then
                vim.notify("Tuna: loaded local config from " .. local_config_path, vim.log.levels.INFO)
                return local_opts
            end

            vim.notify("Tuna: error parsing local config at " .. local_config_path, vim.log.levels.WARN)
            return {}
        end
    end

    return {}
end

function M.setup(user_opts)
    user_opts = user_opts or {}
    local local_opts = get_local_config()
    M.options = vim.tbl_deep_extend("force", M.defaults, user_opts, local_opts)
end

return M
