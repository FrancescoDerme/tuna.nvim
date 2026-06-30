-- lua/tuna/checker.lua
--
-- Decides a testcase's verdict. There are two kinds of checker:
--
--   * "builtin"  — plain output comparison via `compare.lua` (the
--     `output_compare_method`: exact / squish / custom function). This is the
--     default and preserves competitest's behaviour.
--   * external   — a testlib-style checker program, invoked as
--     `checker <input> <output> <answer>` (jury input, participant output, jury
--     answer). Exit code 0 means correct; any other code means wrong, and the
--     checker's stderr/stdout becomes the verdict message.
--
-- `judge` is asynchronous (it may spawn a process), so it reports the verdict
-- through a callback. The builtin path calls back synchronously.

local compare = require("tuna.compare")
local utils = require("tuna.utils")

local M = {}

-- Default testlib argument order: <input> <participant output> <jury answer>.
local DEFAULT_ARGS = { "$(INPUT)", "$(OUTPUT)", "$(ANSWER)" }

---Write `content` to a fresh temp file and return its path.
---@param content string?
---@return string path
local function temp_with(content)
    local path = vim.fn.tempname()
    utils.write_file(path, content or "")
    return path
end

---Substitute the per-testcase file placeholders in a checker argument.
---Uses gsub's function form so paths containing `%` are not misinterpreted.
---@param arg string
---@param files table<string, string> { INPUT=…, OUTPUT=…, ANSWER=… }
---@return string
local function expand_placeholders(arg, files)
    for name, path in pairs(files) do
        arg = arg:gsub("%$%(" .. name .. "%)", function()
            return path
        end)
    end
    return arg
end

---Judge a finished testcase.
---@param tc table testcase data; reads `.stdin`, `.stdout`, `.expected`
---@param checker "builtin"|{ exec: string, args: string[]? } resolved checker spec
---@param compare_method tuna.CompareBuiltin|tuna.CompareMethod builtin compare method
---@param callback fun(correct: boolean?, message: string?) verdict (`nil` => uncheckable/DONE)
function M.judge(tc, checker, compare_method, callback)
    -- Builtin: plain comparison. Preserves exact/squish/custom behaviour, and
    -- returns nil (DONE) when there is no expected output (e.g. the compile step).
    if checker == nil or checker == "builtin" then
        callback(compare.compare_output(tc.stdout or "", tc.expected, compare_method))
        return
    end

    -- An external checker needs a jury answer to compare against; without one
    -- (the compile pseudo-testcase, or a case with no expected output) there is
    -- nothing to check, so report uncheckable.
    if tc.expected == nil then
        callback(nil)
        return
    end

    local files = {
        INPUT = temp_with(tc.stdin),
        OUTPUT = temp_with(tc.stdout),
        ANSWER = temp_with(tc.expected),
    }

    local raw_args = (checker.args and #checker.args > 0) and checker.args or DEFAULT_ARGS
    local args = {}
    for i, a in ipairs(raw_args) do
        args[i] = expand_placeholders(a, files)
    end

    local argv = vim.list_extend({ checker.exec }, args)
    local ok, err = pcall(vim.system, argv, { text = true }, function(res)
        vim.schedule(function()
            for _, path in pairs(files) do
                utils.delete_file(path)
            end
            local msg = res.stderr ~= "" and res.stderr or res.stdout
            msg = msg ~= "" and vim.trim(msg) or nil
            callback(res.code == 0, msg)
        end)
    end)

    if not ok then
        for _, path in pairs(files) do
            utils.delete_file(path)
        end
        vim.schedule(function()
            utils.notify("checker '" .. tostring(checker.exec) .. "' failed to start: " .. tostring(err))
        end)
        callback(nil, "checker failed to start")
    end
end

return M
