-- lua/tuna/runner.lua
local config = require("tuna.config")
local utils = require("tuna.utils")

local M = {}

-- Create a "Runner" class instance for a specific buffer
local Runner = {}
Runner.__index = Runner

function M.new(bufnr)
    -- Default to current buffer
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    local self = setmetatable({}, Runner)
    self.bufnr = bufnr
    self.filetype = vim.bo[bufnr].filetype

    -- Extract file details
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    self.modifiers = {
        FNAME = vim.fn.fnamemodify(filepath, ":t"),
        FNOEXT = vim.fn.fnamemodify(filepath, ":t:r"),
        FEXT = vim.fn.fnamemodify(filepath, ":e"),
        FABSPATH = filepath,
        ABSDIR = vim.fn.fnamemodify(filepath, ":p:h"),
    }

    local all_opts = config.options
    local raw_cc = (all_opts.compile_command or {})[self.filetype]
    local raw_rc = (all_opts.run_command or {})[self.filetype]
    self.compile_dir = all_opts.compile_directory or "."
    self.run_dir = all_opts.running_directory or "."

    -- Format the compile command (if applicable to the programming language)
    if raw_cc then
        self.compile_cmd = {
            exec = utils.apply_modifiers(raw_cc.exec, self.modifiers),
            args = {},
        }

        for i, arg in ipairs(raw_cc.args or {}) do
            self.compile_cmd.args[i] = utils.apply_modifiers(arg, self.modifiers)
        end
    end

    -- Format the run command
    if raw_rc then
        self.run_cmd = {
            exec = utils.apply_modifiers(raw_rc.exec, self.modifiers),
            args = {},
        }
        for i, arg in ipairs(raw_rc.args or {}) do
            self.run_cmd.args[i] = utils.apply_modifiers(arg, self.modifiers)
        end
    end

    return self
end

-- Spawn an async process and capture its output
function Runner:spawn_process(cmd, cwd, stdin_data, on_exit)
    if not cmd then
        vim.notify("Tuna: no command confgiured for filetype " .. self.filepath, vim.log.levels.ERROR)
        return
    end

    -- Create libuv pipes for non-blocking I/O
    local stdin = assert(vim.uv.new_pipe(false), "Tuna: failed to create stdin pipe")
    local stdout = assert(vim.uv.new_pipe(false), "Tuna: failed to create stdout pipe")
    local stderr = assert(vim.uv.new_pipe(false), "Tuna: failed to create stderr pipe")

    local output_data, error_data = {}, {}
    local handle

    -- Spawn the process asynchronously
    handle = vim.uv.spawn(cmd.exec, {
        args = cmd.args,
        cwd = cwd,
        stdio = { stdin, stdout, stderr },
    }, function(code, signal)
        assert(handle, "Tuna: handle is unexpectedly nil in callback")

        stdin:close()
        stdout:close()
        stderr:close()
        handle:close()

        vim.schedule(function()
            local out_str = table.concat(output_data, "")
            local err_str = table.concat(error_data, "")
            on_exit(code, out_str, err_str)
        end)
    end)

    if not handle then
        vim.notify("Tuna: failed to spawn process " .. cmd.exec, vim.log.levels.ERROR)
        stdin:close()
        stdout:close()
        stderr:close()
        return
    end

    -- If there is input data (like a testcase input), write it to stdin
    if stdin_data then
        stdin:write(stdin_data)
    end

    -- Close stdin so the program knows it reached EOF
    stdin:shutdown()

    -- Start reading standard output
    vim.uv.read_start(stdout, function(err, data)
        assert(not err, err)
        if data then
            table.insert(output_data, data)
        end
    end)

    -- Start reading standard error
    vim.uv.read_start(stderr, function(err, data)
        assert(not err, err)
        if data then
            table.insert(error_data, data)
        end
    end)
end

-- Compile
function Runner:compile(on_success)
    -- If it's an interpreted language, skip to success
    if not self.compile_cmd then
        on_success()
        return
    end

    vim.notify("Tuna: compiling " .. self.modifiers.FNAME .. "...", vim.log.levels.INFO)

    local cwd = vim.fn.expand("%:p:h") .. "/" .. self.compile_dir

    self:spawn_process(self.compile_cmd, cwd, nil, function(code, out, err)
        if code == 0 then
            -- Compilation succeeded, trigger the next step
            on_success()
        else
            -- Compilation failed, print the compiler errors
            vim.notify("Tuna: compilation failed!\n" .. err, vim.log.levels.ERROR)
        end
    end)
end

-- Run
function Runner:run()
    -- Wrap the execution logic in a callback and pass it to compile()
    self:compile(function()
        vim.notify("Tuna: running " .. self.modifiers.FNOEXT .. "...", vim.log.levels.INFO)

        local cwd = vim.fn.expand("%:p:h") .. "/" .. self.run_dir

        self:spawn_process(self.run_cmd, cwd, "Dummy test input\n", function(code, out, err)
            if code == 0 then
                vim.notify("Tuna SUCCESS!\nOutput:\n" .. (out == "" and "<empty>" or out), vim.log.levels.INFO)
            else
                vim.notify("Tuna FAILED with code " .. code .. "\nError:\n" .. err, vim.log.levels.ERROR)
            end
        end)
    end)
end

return M
