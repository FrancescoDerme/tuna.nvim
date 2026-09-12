-- tests/harness.lua
--
-- What every test file in here shares: a way to make an assertion, and one summary
-- line at the end that `run.sh` can read. Nothing clever — the point of these tests is
-- that a failure names the thing that broke, so `ok` takes the claim as a sentence and
-- prints what it actually got.
--
-- Usage:
--   local t = dofile("tests/harness.lua")
--   t.eq("split keeps the rest", result.rest.input, "a\nb\n")
--   t.report()            -- prints "N checks, M failures", exits non-zero on failure

local M = { checks = 0, failures = 0 }

---One assertion.
---@param what string the claim, read as a sentence when it fails
---@param cond any truthy to pass
---@param extra any? what was actually seen
function M.ok(what, cond, extra)
    M.checks = M.checks + 1
    if not cond then
        M.failures = M.failures + 1
        print("FAIL: " .. what .. (extra ~= nil and ("  ->  " .. vim.inspect(extra)) or ""))
    end
end

---`got == want`, deep for tables. Prints both sides on a failure, since "not equal"
---without them is the least useful thing a test can say.
function M.eq(what, got, want)
    local same = vim.deep_equal(got, want)
    M.checks = M.checks + 1
    if not same then
        M.failures = M.failures + 1
        print(("FAIL: %s\n        got:  %s\n        want: %s"):format(what, vim.inspect(got), vim.inspect(want)))
    end
end

---A string containing `needle` (plain, not a pattern).
function M.has(what, got, needle)
    M.ok(what, type(got) == "string" and got:find(needle, 1, true) ~= nil, got)
end

---Swallow the plugin's notifications and hand back the list, so a test can assert on
---what the user would have been told without the messages scrolling through the run.
---@return string[] messages appended to as they arrive
function M.capture_notifications()
    local seen = {}
    vim.notify = function(msg)
        seen[#seen + 1] = tostring(msg)
    end
    return seen
end

---Print the summary and exit non-zero if anything failed.
function M.report()
    print(string.format("\n%d checks, %d failures", M.checks, M.failures))
    if M.failures > 0 then
        vim.cmd("cquit 1")
    end
end

---A throwaway directory, removed by `report`-time cleanup callers do themselves.
function M.tempdir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return dir
end

---Write `text` to `dir/name`.
function M.write(dir, name, text)
    local f = assert(io.open(dir .. "/" .. name, "w"))
    f:write(text)
    f:close()
end

return M
