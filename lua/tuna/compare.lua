-- lua/tuna/compare.lua
--
-- Decides whether a program's output matches the expected output. The runner
-- calls `compare_output`; the method is chosen by the `output_compare_method`
-- config option, which can be a builtin name or a user-supplied function.

local utils = require("tuna.utils")

local M = {}

---@alias tuna.CompareMethod fun(output: string, expected: string): boolean
---@alias tuna.CompareBuiltin "exact" | "squish"

---Builtin comparison methods.
---@type table<tuna.CompareBuiltin, tuna.CompareMethod>
M.methods = {
    -- character-for-character equality
    exact = function(output, expected)
        return output == expected
    end,

    -- equality after collapsing runs of whitespace (incl. newlines) to single
    -- spaces and trimming the ends; tolerant of trailing newlines and padding
    squish = function(output, expected)
        local function squish(str)
            str = str:gsub("%s+", " ")
            str = str:gsub("^%s", "")
            str = str:gsub("%s$", "")
            return str
        end
        return squish(output) == squish(expected)
    end,
}

---Compare program output against expected output.
---@param output string program output (stdout)
---@param expected string? expected output, or `nil` when none was provided
---@param method tuna.CompareBuiltin | tuna.CompareMethod builtin name or custom function
---@return boolean? # `true`/`false` if comparable, `nil` when `expected` is absent
function M.compare_output(output, expected, method)
    if expected == nil then
        return nil
    end

    if type(method) == "function" then
        return method(output, expected)
    elseif type(method) == "string" and M.methods[method] then
        return M.methods[method](output, expected)
    end

    -- scheduled because comparison may run inside a libuv callback, where direct
    -- calls into the Neovim API (vim.notify) are not allowed
    vim.schedule(function()
        utils.notify("compare_output: unrecognized method '" .. vim.inspect(method) .. "'")
    end)
    return nil
end

return M
