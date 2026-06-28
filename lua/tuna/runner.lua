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
    self.opts = config.options -- TODO: only get relevant options

    -- Extract file details
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    self.modifiers = {
        FNAME = vim.fn.fnamemodify(filepath, ":t"),
        FNOEXT = vim.fn.fnamemodify(filepath, ":t:r"),
        FEXT = vim.fn.fnamemodify(filepath, ":e"),
        FABSPATH = filepath,
        ABSDIR = vim.fn.fnamemodify(filepath, ":p:h"),
    }

    -- Format the compile command (if applicable to the programming language)
    local raw_cc = self.opts.compile_command[self.filetype]
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
end

return M
