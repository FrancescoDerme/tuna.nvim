-- tests/testcases.lua
--
-- The pure half of `testcases.lua`: the marker split (`:Tuna testcase split`), the
-- multitest count detector it offers to fix up afterwards, where a testcase store is
-- rooted, and the `files` backend's round trip.

local t = dofile("tests/harness.lua")
local tc = require("tuna.testcases")

--------------------------------------------------------------------------------
-- split_testcase: markers come in pairs
--------------------------------------------------------------------------------

-- One pair in the middle: what it brackets is lifted, what is outside stays put and is
-- concatenated. Nothing is prepended or stripped — the split is mechanical on purpose.
local r, err = tc.split_testcase("head\n-\nA\n-\ntail\n", "", "-")
t.ok("one pair splits", r ~= nil, err)
t.eq("the rest is prefix + suffix", r.rest.input, "head\ntail\n")
t.eq("one case is lifted", #r.cases, 1)
t.eq("the case is what was bracketed", r.cases[1].input, "A\n")

-- Two pairs, with text between them: two cases, and everything outside every pair —
-- before, between, after — stays as the testcase being split.
r = tc.split_testcase("head\n-\nA\n-\nmiddle\n-\nB\n-\ntail\n", "", "-")
t.eq("two pairs lift two cases", #r.cases, 2)
t.eq("case 1", r.cases[1].input, "A\n")
t.eq("case 2", r.cases[2].input, "B\n")
t.eq("everything outside is kept, in order", r.rest.input, "head\nmiddle\ntail\n")

-- A marker is a line of nothing *but* the marker character, however many of them.
r = tc.split_testcase("head\n----\nA\n-\ntail\n", "", "-")
t.eq("a run of the marker is still one marker", #r.cases, 1)

-- Marked from end to end: no rest is left, so the first case takes the number rather
-- than leaving an empty testcase behind (`buf_split_testcase` decides that; here the
-- partition simply reports no rest).
r = tc.split_testcase("-\nA\n-\n-\nB\n-\n", "", "-")
t.eq("a fully marked input leaves no rest", r.rest.input, "")
t.eq("and lifts every case", #r.cases, 2)

-- Magic characters: the marker goes through `vim.pesc`, so a `.` marker is a `.` and
-- not "any character" (which would make every line a marker).
r = tc.split_testcase("head\n.\nA\n.\ntail\n", "", ".")
t.eq("'.' is a literal marker", r and r.cases[1].input, "A\n")
r = tc.split_testcase("head\n%\nA\n%\ntail\n", "", "%")
t.eq("'%' is a literal marker", r and r.cases[1].input, "A\n")

-- Inputs and answers are bracketed in step, and both are lifted.
r = tc.split_testcase("h\n-\nA\n-\nt\n", "eh\n-\n1\n-\net\n", "-")
t.eq("the answer is split alongside", r.cases[1].output, "1\n")
t.eq("and its rest is kept too", r.rest.output, "eh\net\n")

-- An expected output that is empty to begin with splits fine, each case simply
-- having none. This is the case that used to come back WRONG once saved.
r, err = tc.split_testcase("h\n-\nA\n-\nt\n", "", "-")
t.ok("an answerless testcase splits", r ~= nil, err)
t.eq("and its cases have no answer", r.cases[1].output, "")

--------------------------------------------------------------------------------
-- split_testcase: the four refusals, each leaving the testcase untouched
--------------------------------------------------------------------------------

r, err = tc.split_testcase("head\n-\nA\ntail\n", "", "-")
t.ok("an unclosed pair is refused", r == nil)
t.has("and says markers come in pairs", err, "pairs")

r, err = tc.split_testcase("head\n-\n-\ntail\n", "", "-")
t.ok("an empty pair is refused", r == nil, r)

r, err = tc.split_testcase("-\nA\n-\n-\nB\n-\n", "-\n1\n-\n", "-")
t.ok("an answer bracketing fewer cases is refused", r == nil, r)

r, err = tc.split_testcase("h\n-\nA\n-\nt\n", "some answer\n", "-")
t.ok("a non-empty answer with no markers is refused", r == nil, r)

r, err = tc.split_testcase("no markers here\n", "", "-")
t.ok("an input with no markers is refused", r == nil)
t.has("and names the marker it looked for", err, "'-'")

r, err = tc.split_testcase("h\n-\nA\n-\nt\n", "", "")
t.ok("no marker character is refused", r == nil, err)

--------------------------------------------------------------------------------
-- leading_case_count: is the first line a multitest count?
--------------------------------------------------------------------------------

t.eq("a bare count is read", tc.leading_case_count("3\n1 2\n"), 3)
t.eq("surrounding blanks are allowed", tc.leading_case_count("  7  \nx\n"), 7)
t.eq("zero counts", tc.leading_case_count("0\n"), 0)
t.eq("two numbers are not a count", tc.leading_case_count("3 4\nx\n"), nil)
t.eq("a negative is not a count", tc.leading_case_count("-1\nx\n"), nil)
t.eq("a word is not a count", tc.leading_case_count("abc\n"), nil)
t.eq("empty text has no count", tc.leading_case_count(""), nil)

--------------------------------------------------------------------------------
-- tc_directory: where the store is rooted
--------------------------------------------------------------------------------

local src = "/home/someone/cp/a/main.cpp"
t.eq(
    "the default '.' is the source's own directory",
    tc.tc_directory("/home/someone/cp/a", src, { testcases_directory = "." }),
    "/home/someone/cp/a/"
)
t.eq(
    "a relative path is joined onto it",
    tc.tc_directory("/home/someone/cp/a", src, { testcases_directory = "tests" }),
    "/home/someone/cp/a/tests/"
)
-- competitest joined unconditionally, so an absolute path was unreachable.
t.eq(
    "an absolute path is used as-is",
    tc.tc_directory("/home/someone/cp/a", src, { testcases_directory = "/var/tc/$(DIRNAME)" }),
    "/var/tc/a/"
)
-- ...and `~/cp/testcases` became a directory literally named `~` beside the source.
t.eq(
    "a leading ~ is expanded, not taken literally",
    tc.tc_directory("/home/someone/cp/a", src, { testcases_directory = "~/tc/$(DIRNAME)" }),
    vim.fs.normalize("~") .. "/tc/a/"
)

--------------------------------------------------------------------------------
-- the `files` backend: round trip, fallback names, and the empty-answer rule
--------------------------------------------------------------------------------

local dir = t.tempdir()
local file = dir .. "/main.cpp"
t.write(dir, "main.cpp", "int main(){}\n")
local IN = { "$(FNOEXT)_input$(TCNUM).txt", "input$(TCNUM).txt", "in.txt" }
local OUT = { "$(FNOEXT)_output$(TCNUM).txt", "output$(TCNUM).txt", "out.txt" }

tc.files.write(dir .. "/", { [0] = { input = "2 3\n", output = "5\n" } }, file, IN, OUT)
t.ok("a fresh directory takes the canonical first format", vim.fn.filereadable(dir .. "/main_input0.txt") == 1)
t.eq("what was written loads back", tc.files.load(dir .. "/", file, IN, OUT), { [0] = { input = "2 3\n", output = "5\n" } })

-- An empty answer is the *absence* of one: the file is removed rather than written,
-- which is why a row holding "" disagreed with the disk and came back WRONG.
tc.files.write(dir .. "/", { [0] = { input = "2 3\n", output = "" } }, file, IN, OUT)
t.ok("an empty answer deletes its file", vim.fn.filereadable(dir .. "/main_output0.txt") == 0)
t.eq("and loads back as no answer at all", tc.files.load(dir .. "/", file, IN, OUT)[0].output, nil)

-- A testcase may have only an output: the solution is fed empty stdin.
local shared = t.tempdir()
t.write(shared, "main.cpp", "int main(){}\n")
t.write(shared, "out.txt", "42\n")
local loaded = tc.files.load(shared .. "/", shared .. "/main.cpp", IN, OUT)
t.eq("a numberless out.txt is testcase 0", loaded[0] and loaded[0].output, "42\n")
t.eq("with no input", loaded[0].input, nil)

-- A directory already using a shared, un-prefixed name keeps using it: a new testcase
-- joins that set instead of starting a rival source-named one, which — since the first
-- format to match anything wins on load — would have hidden every testcase there.
local joint = t.tempdir()
t.write(joint, "main.cpp", "int main(){}\n")
t.write(joint, "input0.txt", "a\n")
tc.files.write(joint .. "/", { [1] = { input = "b\n" } }, joint .. "/main.cpp", IN, OUT)
t.ok("a new testcase joins the format already in use", vim.fn.filereadable(joint .. "/input1.txt") == 1)
t.ok("and does not start a source-named set", vim.fn.filereadable(joint .. "/main_input1.txt") == 0)

--------------------------------------------------------------------------------
-- Empty, absent, and the difference between them
--------------------------------------------------------------------------------

-- For an **input** the two are the same thing: the solution is fed `""` either way, so
-- nothing is lost by normalizing, and a load reporting `""` while a save reported `nil`
-- was a discrepancy with no meaning behind it.
local blank = t.tempdir()
t.write(blank, "main.cpp", "int main(){}\n")
t.write(blank, "input0.txt", "")
t.write(blank, "output0.txt", "42\n")
local b = tc.files.load(blank .. "/", blank .. "/main.cpp", IN, OUT)
t.eq("an empty input file loads as no input", b[0].input, nil)
t.eq("and its answer is untouched", b[0].output, "42\n")

-- For an **answer** they are two different things and neither may be normalized away:
-- an absent answer means the testcase is not judged, while one that is present and
-- empty means the solution must print nothing. Only file presence can say which, so
-- what is on disk is loaded as it is.
t.write(blank, "input0.txt", "hi\n")
t.write(blank, "output0.txt", "")
b = tc.files.load(blank .. "/", blank .. "/main.cpp", IN, OUT)
t.eq("the testcase exists", b[0] ~= nil, true)
t.eq("an empty answer file is an empty answer, not a missing one", b[0].output, "")
t.eq("and its input is untouched", b[0].input, "hi\n")
vim.fn.delete(blank .. "/output0.txt")
b = tc.files.load(blank .. "/", blank .. "/main.cpp", IN, OUT)
t.eq("while no answer file at all is no answer", b[0].output, nil)

vim.fn.delete(blank, "rf")

-- Which is why an empty answer file is never written by accident: an empty write removes
-- it unless the caller says the emptiness is meant. `buf_save_testcase` is where that is
-- decided, since it is the "store this testcase" entry point, as against the bulk write.
local kept = t.tempdir()
t.write(kept, "main.cpp", "int main(){}\n")
tc.files.write(kept .. "/", { [0] = { input = "", output = "" } }, kept .. "/main.cpp", IN, OUT)
t.ok("a bulk empty write leaves no input file", vim.fn.filereadable(kept .. "/main_input0.txt") == 0)
t.ok("and no answer file", vim.fn.filereadable(kept .. "/main_output0.txt") == 0)

-- Saving a testcase *stores* it, even with nothing in it: an empty testcase is a
-- testcase, and removing one is `buf_delete_testcase` rather than a side effect of a
-- save. So the input file is written empty rather than removed.
tc.files.write(
    kept .. "/",
    { [0] = { input = "", output = "", keep_empty = { input = true } } },
    kept .. "/main.cpp",
    IN,
    OUT
)
t.ok("saving an empty testcase writes an input file", vim.fn.filereadable(kept .. "/main_input0.txt") == 1)
t.eq("and it is genuinely empty", vim.fn.getfsize(kept .. "/main_input0.txt"), 0)
t.ok("with no answer file, so it is not judged", vim.fn.filereadable(kept .. "/main_output0.txt") == 0)
local kback = tc.files.load(kept .. "/", kept .. "/main.cpp", IN, OUT)
t.eq("the testcase exists on the way back", kback[0] ~= nil, true)
t.eq("with nothing to feed the solution", kback[0].input, nil)
t.eq("and nothing to judge it against", kback[0].output, nil)

-- "Expect empty output": the answer is present and empty, so the solution must print
-- nothing. The one half whose emptiness a save cannot read off what it is given.
tc.files.write(
    kept .. "/",
    { [0] = { input = "5\n", output = "", keep_empty = { input = true, output = true } } },
    kept .. "/main.cpp",
    IN,
    OUT
)
t.ok("keeping the answer writes an answer file", vim.fn.filereadable(kept .. "/main_output0.txt") == 1)
t.eq("and it is genuinely empty", vim.fn.getfsize(kept .. "/main_output0.txt"), 0)
kback = tc.files.load(kept .. "/", kept .. "/main.cpp", IN, OUT)
t.eq("which loads back as an empty answer", kback[0].output, "")
t.eq("beside its input", kback[0].input, "5\n")
-- ...and it is judged, unlike no answer at all: this is the whole point of the
-- distinction, so it is checked where it lands rather than only where it is stored.
local cmp = require("tuna.compare")
t.eq("an empty answer judges a silent solution correct", cmp.compare_output("", kback[0].output, "squish"), true)
t.eq("and a talkative one wrong", cmp.compare_output("hello\n", kback[0].output, "squish"), false)
t.eq("while no answer is no verdict", cmp.compare_output("hello\n", nil, "squish"), nil)
vim.fn.delete(kept, "rf")

-- The buffer-level entry point is where the two are settled, so a caller says only what
-- it means: store this testcase, and whether an empty answer is meant as "print
-- nothing".
local buffed = t.tempdir()
t.write(buffed, "main.cpp", "int main(){}\n")
require("tuna").setup({})
vim.cmd("edit " .. buffed .. "/main.cpp")
vim.bo.filetype = "cpp"
local bb = vim.api.nvim_get_current_buf()
tc.buf_save_testcase(bb, 0, "", "")
t.eq("saving an empty testcase keeps it", tc.buf_get_testcases(bb)[0] ~= nil, true)
t.eq("with no answer", tc.buf_get_testcases(bb)[0].output, nil)
tc.buf_save_testcase(bb, 0, "5\n", "", true)
t.eq("and an expected-empty answer is stored as one", tc.buf_get_testcases(bb)[0].output, "")
tc.buf_delete_testcase(bb, 0)
t.eq("deleting is what removes a testcase", tc.buf_get_testcases(bb)[0], nil)
vim.cmd("silent! bwipeout!")
vim.fn.delete(buffed, "rf")

vim.fn.delete(dir, "rf")
vim.fn.delete(shared, "rf")
vim.fn.delete(joint, "rf")

--------------------------------------------------------------------------------
-- single_file: saving one testcase keeps every other one exactly as stored
--------------------------------------------------------------------------------

-- The store is one file, so a save or a delete rewrites all of it. An empty testcase and
-- an expected empty answer are only kept when they are asked for, and a rewrite must
-- not un-ask for them on behalf of the testcases it wasn't touching.
require("tuna").setup({ testcases_storage = "single_file" })
local sfdir = t.tempdir()
t.write(sfdir, "sol.py", "print()\n")
vim.cmd("edit " .. sfdir .. "/sol.py")
local sfbuf = vim.api.nvim_get_current_buf()
tc.buf_save_testcase(sfbuf, 0, "3\n", "6\n")
tc.buf_save_testcase(sfbuf, 2, "", "", true)
tc.buf_save_testcase(sfbuf, 5, "", nil)
local function sf_stored()
    local s = tc.buf_get_testcases(sfbuf)
    return { s[0] and s[0].output, s[2] ~= nil, s[2] and s[2].output, s[5] ~= nil, s[5] and s[5].output }
end
local before = sf_stored()
t.eq("single_file stores an empty testcase and an expected empty answer", before, { "6\n", true, "", true, nil })
tc.buf_save_testcase(sfbuf, 1, "7\n", "14\n")
t.eq("saving another testcase keeps them as they were", sf_stored(), before)
tc.buf_delete_testcase(sfbuf, 1)
t.eq("and so does deleting one", sf_stored(), before)
vim.cmd("bwipeout!")
vim.fn.delete(sfdir, "rf")
t.report()
