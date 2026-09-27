-- tests/compare.lua
--
-- The verdict layer: which outputs count as matching, and how the method is named in
-- the results UI. Plus `core.answer`, the one rule that decides whether a testcase has
-- an expected output at all.

local t = dofile("tests/harness.lua")
local compare = require("tuna.compare")
local core = require("tuna.runner.core")

--------------------------------------------------------------------------------
-- no expected output at all
--------------------------------------------------------------------------------

-- `nil` is not a verdict of any kind: there is nothing to be right or wrong against,
-- which the runner draws as DONE.
t.eq("no expected output is not a verdict", compare.compare_output("anything\n", nil, "exact"), nil)

-- And that is what an empty answer must become before it is stored, since an empty
-- output file is deleted rather than written. Storing "" made the judge compare the
-- run against an empty answer, so editing an answerless testcase turned DONE into
-- WRONG until the next full re-run reloaded `nil` from disk.
t.eq("an empty answer is stored as none", core.answer(""), nil)
t.eq("a nil answer stays none", core.answer(nil), nil)
t.eq("a real answer is kept", core.answer("5\n"), "5\n")
t.eq('"" is judged, once it is allowed to be stored', compare.compare_output("5\n", "", "exact"), false)

--------------------------------------------------------------------------------
-- exact
--------------------------------------------------------------------------------

t.eq("exact accepts identical text", compare.compare_output("5\n", "5\n", "exact"), true)
t.eq("exact rejects a trailing newline difference", compare.compare_output("5", "5\n", "exact"), false)
t.eq("exact rejects a spacing difference", compare.compare_output("1  2\n", "1 2\n", "exact"), false)

--------------------------------------------------------------------------------
-- squish
--------------------------------------------------------------------------------

t.eq("squish ignores trailing whitespace", compare.compare_output("5\n\n", "5", "squish"), true)
t.eq("squish ignores runs of spaces", compare.compare_output("1   2\n", "1 2\n", "squish"), true)
t.eq("squish ignores line breaks between tokens", compare.compare_output("1\n2\n", "1 2\n", "squish"), true)
t.eq("squish still compares the tokens", compare.compare_output("1 3\n", "1 2\n", "squish"), false)

--------------------------------------------------------------------------------
-- float: token-wise, within an absolute *or* relative tolerance
--------------------------------------------------------------------------------

local float = { "float", tol = 1e-6 }
t.eq("float accepts a difference under the tolerance", compare.compare_output("0.3333333\n", "0.3333334\n", float), true)
t.eq("float rejects one over it", compare.compare_output("0.33\n", "0.3333334\n", float), false)
t.eq("float accepts a relative difference on a large value", compare.compare_output("1e9\n", "1000000000.0001\n", float), true)
t.eq("float compares non-numeric tokens exactly", compare.compare_output("YES 1.0\n", "YES 1.0\n", float), true)
t.eq("and rejects them when they differ", compare.compare_output("NO 1.0\n", "YES 1.0\n", float), false)
t.eq("float rejects a differing token count", compare.compare_output("1.0\n", "1.0 2.0\n", float), false)
t.eq("a looser tolerance accepts more", compare.compare_output("1.0\n", "1.05\n", { "float", tol = 0.1 }), true)

--------------------------------------------------------------------------------
-- a custom function
--------------------------------------------------------------------------------

t.eq("a custom method decides for itself", compare.compare_output("anything", "else", function()
    return true
end), true)

--------------------------------------------------------------------------------
-- how the method is named in the "Run" pane
--------------------------------------------------------------------------------

t.eq("exact names itself", compare.method_name("exact"), "exact")
t.has("float carries its tolerance", compare.method_name(float), "tol")
t.eq("a function is 'custom'", compare.method_name(function() end), "custom")

-- An unknown method judges nothing, and says so once rather than once per testcase.
do
    local quiet = vim.notify
    local said = t.capture_notifications()
    for _ = 1, 3 do
        t.eq("an unknown method judges nothing", compare.compare_output("1", "1", "sideways"), nil)
    end
    vim.wait(50, function()
        return false
    end)
    vim.notify = quiet
    t.eq("and is said once", #said, 1)
end

-- The diff draws what the verdict says: two texts the method judges equal get no marks,
-- though `squish` and `float` read the output as one stream of tokens and the diff walks it
-- line by line.
local diff = require("tuna.diff")
for _, method in ipairs({ "squish", { "float", tol = 1e-6 } }) do
    local name = compare.method_name(method)
    t.eq(name .. ": texts judged equal get no marks", diff.compute("1 2\n", "1\n2\n", method).first, nil)
    t.eq(name .. ": texts judged different are still marked", diff.compute("1 3\n", "1\n2\n", method).first, 1)
end
t.eq("float: a value within tolerance is no difference", diff.compute("0.3000001\n", "0.3\n", { "float", tol = 1e-6 }).first, nil)
local within = diff.compute("0.3000001 5\n", "0.3 6\n", { "float", tol = 1e-6 })
t.eq("and on a line that is wrong, only the value that differs is marked", within.out[1] and within.out[1].spans, { { 10, 11 } })

-- A checker that did not build judges nothing and says so on the row it could not judge, and
-- nowhere else: the build step shows why, beside the other sources.
do
    local quiet = vim.notify
    local said = t.capture_notifications()
    local got
    require("tuna.checker").judge({ stdin = "1", stdout = "1", expected = "1" }, {
        exec = "x",
        args = {},
        cwd = vim.fn.getcwd(),
        role = "checker",
        compile = { exec = "/nonexistent/compiler", args = {} },
        compile_dir = vim.fn.tempname(),
    }, "exact", function(correct, message)
        got = { correct, message }
    end)
    vim.wait(200, function()
        return got ~= nil
    end)
    vim.wait(50, function()
        return false
    end)
    vim.notify = quiet
    t.eq("a checker that did not build gives no verdict, and says why", got, { nil, "checker did not compile" })
    t.eq("without a notification", said, {})
end

t.report()
