-- lua/tuna/compare.lua
--
-- Decides whether a program's output matches the expected output. The runner
-- calls `compare_output`; the method is chosen by the `output_compare_method`
-- config option, which can be a builtin name or a user-supplied function.

local utils = require("tuna.utils")

local M = {}

---@alias tuna.CompareMethod fun(output: string, expected: string, opts: table?): boolean
---@alias tuna.CompareBuiltin "exact" | "squish" | "float"
---A compare method: a builtin name, a `{ [1] = builtin, ... }` table carrying that
---builtin's options (e.g. `{ "float", tol = 1e-6 }`), or a custom function.
---@alias tuna.CompareSpec tuna.CompareBuiltin | tuna.CompareMethod | table

local DEFAULT_FLOAT_TOL = 1e-6

---Split a string into whitespace-separated tokens (empties dropped).
---@param s string
---@return string[]
local function tokens(s)
    return vim.split(s, "%s+", { trimempty = true })
end

---Builtin comparison methods. Each takes `(output, expected, opts)`; `opts` is the
---method table when one was supplied (`exact`/`squish` ignore it).
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

    -- token-wise comparison tolerant of floating-point rounding: numeric tokens
    -- match when within `opts.tol` absolute *or* relative error; any non-numeric
    -- token (or a numeric-vs-text mismatch) must be exactly equal. Token counts
    -- must agree. `tol` defaults to 1e-6.
    float = function(output, expected, opts)
        local tol = (opts and opts.tol) or DEFAULT_FLOAT_TOL
        local ot, et = tokens(output), tokens(expected)
        if #ot ~= #et then
            return false
        end
        for i = 1, #et do
            local a, b = tonumber(ot[i]), tonumber(et[i])
            if a and b then
                local diff = math.abs(a - b)
                if diff > tol and diff > tol * math.abs(b) then
                    return false
                end
            elseif ot[i] ~= et[i] then
                return false
            end
        end
        return true
    end,
}

---A human-readable label for a compare method (for the results-UI status pane).
---@param method tuna.CompareSpec
---@return string
function M.method_name(method)
    if type(method) == "function" then
        return "custom"
    elseif type(method) == "table" then
        local name = method[1] or "?"
        if name == "float" then
            return ("float, tol=%g"):format(method.tol or DEFAULT_FLOAT_TOL)
        end
        return tostring(name)
    end
    return tostring(method)
end

---Compare program output against expected output.
---@param output string program output (stdout)
---@param expected string? expected output, or `nil` when none was provided
---@param method tuna.CompareSpec builtin name, `{ builtin, opts... }` table, or custom fn
---@return boolean? # `true`/`false` if comparable, `nil` when `expected` is absent
function M.compare_output(output, expected, method)
    if expected == nil then
        return nil
    end

    if type(method) == "function" then
        return method(output, expected)
    elseif type(method) == "string" and M.methods[method] then
        return M.methods[method](output, expected)
    elseif type(method) == "table" and M.methods[method[1]] then
        -- `{ "float", tol = 1e-6 }` — builtin name in [1], options in the table.
        return M.methods[method[1]](output, expected, method)
    end

    -- scheduled because comparison may run inside a libuv callback, where direct
    -- calls into the Neovim API (vim.notify) are not allowed
    vim.schedule(function()
        utils.notify("compare_output: unrecognized method '" .. vim.inspect(method) .. "'")
    end)
    return nil
end

return M
