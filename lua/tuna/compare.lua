-- lua/tuna/compare.lua
--
-- Decides whether a program's output matches the expected output. The runner
-- calls `compare_output`; the method is chosen by name, by the `output_compare_method`
-- config option or `:Tuna compare`: a builtin one, or one of the user's own in
-- `compare_methods`, which the runner resolves (`RunnerCore:effective_compare`).

local utils = require("tuna.utils")

local M = {}

---@alias tuna.CompareMethod fun(output: string, expected: string, opts: table?): boolean
---@alias tuna.CompareBuiltin "exact" | "squish" | "float"
---A compare method: a name, or a `{ [1] = name, ... }` table carrying that method's
---options (`{ "float", tol = 1e-6 }`), or, once a runner has resolved one of the user's
---own, the function it names (`{ name, fn = function }`).
---@alias tuna.CompareSpec string | table

---The tolerance `float` uses when none is given.
M.DEFAULT_FLOAT_TOL = 1e-6

---Whether two tokens agree under `float`: equal as text, or both numbers within `tol`,
---absolute or relative. The diff marks tokens by this same rule, so they never contradict
---the verdict.
---@param a string
---@param b string
---@param tol number
---@return boolean
function M.float_equal(a, b, tol)
    if a == b then
        return true
    end
    local x, y = tonumber(a), tonumber(b)
    if not (x and y) then
        return false
    end
    local d = math.abs(x - y)
    return d <= tol or d <= tol * math.abs(y)
end

-- Unknown methods already reported, so a run of many testcases says so once.
local warned = {}

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
        local tol = (opts and opts.tol) or M.DEFAULT_FLOAT_TOL
        local ot, et = tokens(output), tokens(expected)
        if #ot ~= #et then
            return false
        end
        for i = 1, #et do
            if not M.float_equal(ot[i], et[i], tol) then
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
    if type(method) == "table" then
        local name = method[1] or "?"
        if name == "float" then
            return ("float, tol=%g"):format(method.tol or M.DEFAULT_FLOAT_TOL)
        end
        return tostring(name)
    end
    return tostring(method)
end

---Compare program output against expected output.
---@param output string program output (stdout)
---@param expected string? expected output, or `nil` when none was provided
---@param method tuna.CompareSpec
---@return boolean? # `true`/`false` if comparable, `nil` when `expected` is absent
function M.compare_output(output, expected, method)
    if expected == nil then
        return nil
    end

    if type(method) == "table" and type(method.fn) == "function" then
        return method.fn(output, expected)
    elseif type(method) == "string" and M.methods[method] then
        return M.methods[method](output, expected)
    elseif type(method) == "table" and M.methods[method[1]] then
        -- `{ "float", tol = 1e-6 }` — builtin name in [1], options in the table.
        return M.methods[method[1]](output, expected, method)
    end

    -- Said once per method, not once per testcase. Scheduled because comparison may run
    -- inside a libuv callback, where the Neovim API cannot be called.
    local key = vim.inspect(method)
    if not warned[key] then
        warned[key] = true
        vim.schedule(function()
            utils.notify("unknown compare method " .. key .. ", so outputs are not judged.")
        end)
    end
    return nil
end

return M
