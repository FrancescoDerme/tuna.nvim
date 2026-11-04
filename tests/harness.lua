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

---Run the event loop until what has been scheduled has run. A callback scheduled now runs
---after every one scheduled before it, so each tick runs what the one before it scheduled:
---ticks are run until a chain of them (a render, the re-tiling it starts, a stubbed process's
---exit and what it starts) has ended and `busy`, what the caller knows to be still pending
---(a timer), has said no, ten in a row. A tick costs well under a millisecond, where a sleep
---costs as long as the slowest of these might take.
---@param busy (fun(): boolean)?
function M.drain(busy)
    local calm = 0
    for _ = 1, 1000 do
        local ran = false
        vim.schedule(function()
            ran = true
        end)
        vim.wait(1000, function()
            return ran
        end, 1)
        calm = (busy and busy()) and 0 or calm + 1
        if calm == 10 then
            return
        end
    end
end

---A throwaway directory, removed by `report`-time cleanup callers do themselves.
function M.tempdir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return dir
end

---A stand-in for `vim.system`'s `on_exit`, wrapping the one it was given: what the result says
---was printed goes to the `stdout`/`stderr` callbacks the stand-in was handed, as `vim.system`
---hands it, and is then left off the result, which `vim.system` gives back without the
---streams it was handed callbacks for.
---@param opts table? the options the stand-in was called with
---@param on_exit function?
---@return function?
function M.streamed(opts, on_exit)
    if not on_exit then
        return nil
    end
    return function(res, ...)
        res = vim.deepcopy(res or {})
        for _, name in ipairs({ "stdout", "stderr" }) do
            local feed = opts and opts[name]
            if type(feed) == "function" then
                if res[name] and res[name] ~= "" then
                    feed(nil, res[name])
                end
                feed(nil, nil)
                res[name] = nil
            end
        end
        return on_exit(res, ...)
    end
end

---Write `text` to `dir/name`.
function M.write(dir, name, text)
    local f = assert(io.open(dir .. "/" .. name, "w"))
    f:write(text)
    f:close()
end

return M
