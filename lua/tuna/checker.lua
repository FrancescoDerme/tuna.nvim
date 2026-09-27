-- lua/tuna/checker.lua
--
-- Decides a testcase's verdict. There are two kinds of checker:
--
--   * "builtin"  — plain output comparison via `compare.lua` (the
--     `output_compare_method`: exact / squish / custom function). This is the
--     default.
--   * external   — a testlib-style checker program, invoked as
--     `checker <input> <output> <answer>` (jury input, participant output, jury
--     answer), the arguments `tools.helper` gave its spec. Exit code 0 means correct; any
--     other code means wrong, and the checker's stderr/stdout becomes the verdict message.
--     It is compiled once, through `tools.prepare`, which the build step has already done:
--     a checker that did not build, or cannot start, says so on the row it could not judge
--     and nowhere else, since the build step shows why beside the other sources.
--
-- `judge` is asynchronous (it may spawn a process), so it reports the verdict
-- through a callback. The builtin path calls back synchronously.

local compare = require("tuna.compare")
local utils = require("tuna.utils")
local tools = require("tuna.tools")

local M = {}

---Judge a finished testcase.
---@param tc table testcase data; reads `.stdin`, `.stdout`, `.expected`
---@param checker "builtin"|tuna.HelperSpec resolved checker spec
---@param compare_method tuna.CompareSpec builtin compare method
---@param callback fun(correct: boolean?, message: string?) verdict (`nil` => uncheckable/DONE)
function M.judge(tc, checker, compare_method, callback)
    -- Builtin: plain comparison. Preserves exact/squish/custom behaviour, and
    -- returns nil (DONE) when there is no expected output (e.g. the compile step).
    if checker == nil or checker == "builtin" then
        callback(compare.compare_output(tc.stdout or "", tc.expected, compare_method))
        return
    end
    ---@cast checker tuna.HelperSpec

    -- The compile pseudo-testcase has no output to judge — report uncheckable.
    -- (A *real* testcase with no expected output is still judged: a checker often
    -- validates the participant output against the input alone, so there's no need
    -- to write an example answer when a checker is in use.)
    if tc.compile then
        callback(nil)
        return
    end

    -- Compile the checker if it is a source file (cached across testcases), then run
    -- it against this testcase's three temp files.
    tools.prepare(checker, function(ready)
        if not ready then
            callback(nil, "checker did not compile")
            return
        end

        local files = {
            INPUT = utils.temp_file(tc.stdin),
            OUTPUT = utils.temp_file(tc.stdout),
            ANSWER = utils.temp_file(tc.expected),
        }
        local argv = vim.list_extend({ checker.exec }, tools.expand_args(checker.args, files))
        local ok, err = pcall(vim.system, argv, { text = true, cwd = checker.cwd }, function(res)
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
            callback(nil, "checker could not start: " .. tostring(err))
        end
    end)
end

return M
