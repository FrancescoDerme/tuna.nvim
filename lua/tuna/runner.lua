-- lua/tuna/runner.lua
local config = require("tuna.config")
local testcases = require("tuna.testcases")
local utils = require("tuna.utils")

local M = {}
local Runner = {}
Runner.__index = Runner

local function build_command(spec, filetype, modifiers)
    local entry = spec and spec[filetype]
    if not entry then
        return nil
    end

    local cmd = {
        exec = utils.apply_modifiers(entry.exec, modifiers),
        args = {},
    }

    for _, arg in ipairs(entry.args or {}) do
        table.insert(cmd.args, utils.apply_modifiers(arg, modifiers))
    end

    return cmd
end

function M.new(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()

    local self = setmetatable({}, Runner)
    self.bufnr = bufnr
    self.filetype = vim.bo[bufnr].filetype or ""
    self.filepath = vim.api.nvim_buf_get_name(bufnr)
    self.project_root = vim.fn.getcwd()

    self.modifiers = {
        FNAME = vim.fn.fnamemodify(self.filepath, ":t"),
        FNOEXT = vim.fn.fnamemodify(self.filepath, ":t:r"),
        FEXT = vim.fn.fnamemodify(self.filepath, ":e"),
        FABSPATH = self.filepath,
        ABSDIR = vim.fn.fnamemodify(self.filepath, ":p:h"),
    }

    local all_opts = config.options
    self.compile_dir = utils.normalize_path(all_opts.compile_directory or ".", self.project_root)
    self.run_dir = utils.normalize_path(all_opts.running_directory or ".", self.project_root)
    self.compile_cmd = build_command(all_opts.compile_command, self.filetype, self.modifiers)
    self.run_cmd = build_command(all_opts.run_command, self.filetype, self.modifiers)
    self.output_bufnr = nil
    self.output_winid = nil

    return self
end

function Runner:show_output()
    if self.output_bufnr and vim.api.nvim_buf_is_valid(self.output_bufnr) then
        return self.output_bufnr
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
    vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
    vim.api.nvim_buf_set_option(bufnr, "buflisted", false)
    vim.api.nvim_buf_set_name(bufnr, "tuna://output")

    self.output_bufnr = bufnr

    if config.options.auto_open_output then
        local width = math.max(80, math.floor(vim.o.columns * 0.8))
        local height = math.max(12, math.floor(vim.o.lines * 0.6))
        self.output_winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = width,
            height = height,
            row = 2,
            col = 2,
            style = "minimal",
            border = "rounded",
        })
    end

    return bufnr
end

function Runner:write_output(lines)
    local bufnr = self:show_output()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    if self.output_winid and vim.api.nvim_win_is_valid(self.output_winid) then
        vim.api.nvim_win_set_buf(self.output_winid, bufnr)
    end
end

function Runner:append_output(lines)
    local bufnr = self:show_output()
    local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.list_extend(current, lines)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, current)
end

function Runner:spawn_process(cmd, cwd, stdin_data, on_exit)
    if not cmd then
        vim.notify("Tuna: no command configured for filetype " .. tostring(self.filetype), vim.log.levels.ERROR)
        return
    end

    local stdin = assert(vim.uv.new_pipe(false), "Tuna: failed to create stdin pipe")
    local stdout = assert(vim.uv.new_pipe(false), "Tuna: failed to create stdout pipe")
    local stderr = assert(vim.uv.new_pipe(false), "Tuna: failed to create stderr pipe")

    local output_data, error_data = {}, {}
    local handle

    handle = vim.uv.spawn(cmd.exec, {
        args = cmd.args,
        cwd = cwd,
        stdio = { stdin, stdout, stderr },
    }, function(code)
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

    if stdin_data ~= nil then
        stdin:write(stdin_data)
    end
    stdin:shutdown()

    vim.uv.read_start(stdout, function(err, data)
        assert(not err, err)
        if data then
            table.insert(output_data, data)
        end
    end)

    vim.uv.read_start(stderr, function(err, data)
        assert(not err, err)
        if data then
            table.insert(error_data, data)
        end
    end)
end

function Runner:compile(on_success)
    if not self.compile_cmd then
        on_success = on_success or function() end
        on_success()
        return
    end

    self:write_output({ "[tuna] compiling " .. self.modifiers.FNAME .. "..." })
    vim.notify("Tuna: compiling " .. self.modifiers.FNAME .. "...", vim.log.levels.INFO)

    self:spawn_process(self.compile_cmd, self.compile_dir, nil, function(code, out, err)
        if code == 0 then
            self:append_output({ "[tuna] compilation succeeded" })
            if on_success then
                on_success()
            end
        else
            self:append_output({ "[tuna] compilation failed", err })
            vim.notify("Tuna: compilation failed!\n" .. err, vim.log.levels.ERROR)
        end
    end)
end

function Runner:run()
    local test_case = testcases.load_first(self.project_root)
    local stdin_data = nil
    if test_case and test_case.input then
        stdin_data = test_case.input .. "\n"
    end

    self:compile(function()
        if not self.run_cmd then
            vim.notify("Tuna: no run command configured for filetype " .. tostring(self.filetype), vim.log.levels.ERROR)
            return
        end

        self:write_output({ "[tuna] running " .. self.modifiers.FNOEXT .. "..." })
        vim.notify("Tuna: running " .. self.modifiers.FNOEXT .. "...", vim.log.levels.INFO)

        self:spawn_process(self.run_cmd, self.run_dir, stdin_data, function(code, out, err)
            local output_lines = { "[tuna] process exited with code " .. tostring(code) }
            if out ~= "" then
                table.insert(output_lines, out)
            end
            if err ~= "" then
                table.insert(output_lines, "[stderr]\n" .. err)
            end

            self:append_output(output_lines)

            if code == 0 then
                vim.notify("Tuna SUCCESS!", vim.log.levels.INFO)
            else
                vim.notify("Tuna FAILED with code " .. code, vim.log.levels.ERROR)
            end
        end)
    end)
end

return M
