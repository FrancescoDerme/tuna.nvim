-- tests/download.lua
--
-- The boundary the Competitive Companion listener sits behind. Whatever arrives on the
-- port is untrusted — an old or patched extension, a third-party sender, a stray
-- browser request — and the pipeline used to index it directly, so a task without a
-- `batch` took the listener down inside a libuv callback and left the queue wedged.
-- Nothing here may throw; a bad task is repaired or dropped.

local t = dofile("tests/harness.lua")
local d = require("tuna.download")._test

--------------------------------------------------------------------------------
-- validate_task: repair what has an unambiguous reading, reject what does not
--------------------------------------------------------------------------------

-- The name is the one thing there is nothing sensible to invent for: it is what
-- `$(PROBLEM)` names the file and the folder after.
t.ok("a task with no name is rejected", d.validate_task({ url = "x" }) == nil)
t.ok("a non-table body is rejected", d.validate_task("not json") == nil)
t.ok("nil is rejected", d.validate_task(nil) == nil)
t.ok("an empty name is rejected", d.validate_task({ name = "" }) == nil)
local _, why = d.validate_task({ url = "x" })
t.has("and the reason says what is missing", why, "name")

-- Everything else has one reading when it is absent, so it is repaired rather than
-- refused: a contest half-downloaded is worse than a problem with an empty field.
local ok1 = d.validate_task({ name = "A. Problem" })
t.ok("a task with only a name survives", ok1 ~= nil)
t.eq("a missing url becomes empty", ok1.url, "")
t.eq("a missing group becomes empty", ok1.group, "")
t.eq("missing tests become none", ok1.tests, {})
t.eq("a missing batch becomes one task on its own", ok1.batch.size, 1)
t.ok("with an id of its own", type(ok1.batch.id) == "string" and ok1.batch.id ~= "")

-- Two tasks arriving without a batch must not be taken for one batch of two.
local a, b = d.validate_task({ name = "A" }), d.validate_task({ name = "B" })
t.ok("two batchless tasks get different ids", a.batch.id ~= b.batch.id, { a.batch.id, b.batch.id })

local ok2 = d.validate_task({
    name = "A",
    tests = {
        { input = "1\n", output = "2\n" },
        "not a testcase",
        { input = 42 },
        {},
    },
})
t.eq("entries not shaped like a testcase are dropped", #ok2.tests, 3)
t.eq("a real testcase is kept", ok2.tests[1], { input = "1\n", output = "2\n" })
-- Written out unchecked, a non-string became the literal string "nil" in the file.
t.eq("a non-string field becomes empty, not the word nil", ok2.tests[2], { input = "", output = "" })

local ok3 = d.validate_task({ name = "A", batch = { id = "b", size = "3" } })
t.eq("a numeric string size is accepted", ok3.batch.size, 3)
t.eq("a nonsense size falls back to one", d.validate_task({ name = "A", batch = { size = 0 } }).batch.size, 1)
t.eq("so does a non-numeric one", d.validate_task({ name = "A", batch = { size = {} } }).batch.size, 1)

--------------------------------------------------------------------------------
-- canonicalize_task: a mirror is not a second address for the same pages
--------------------------------------------------------------------------------

-- A mirror has no per-problem URLs at all and drops the contest once the round ends,
-- so a mirror URL written into the source header and the sidecar is dead on arrival.
local m = d.canonicalize_task({
    name = "You Delete, I Delete",
    group = "Codeforces",
    url = "https://m1.codeforces.com/contest/2248/problem/A",
    tests = {},
})
t.eq("a mirror URL is rewritten to the main site", m.url, "https://codeforces.com/contest/2248/problem/A")
t.eq("and the mirror is kept, for routing a submission back through it", m.mirror, "m1")
-- Competitive Companion reads the name off the page, and a mirror's page does not put
-- the index in front of the title, so a contest downloaded from one sorted by title.
t.eq("the problem index is taken from the URL", m.name, "A. You Delete, I Delete")

local main = d.canonicalize_task({
    name = "A. You Delete, I Delete",
    group = "Codeforces - Round 1112",
    url = "https://codeforces.com/contest/2248/problem/A",
    tests = {},
})
t.eq("a main-site URL is left alone", main.url, "https://codeforces.com/contest/2248/problem/A")
t.eq("an index already there does not collect a second copy", main.name, "A. You Delete, I Delete")
t.eq("and no mirror is recorded", main.mirror, nil)

local other = d.canonicalize_task({
    name = "Sample Problem",
    group = "AtCoder - ABC 400",
    url = "https://atcoder.jp/contests/abc400/tasks/abc400_a",
    tests = {},
})
t.eq("a non-Codeforces task keeps its URL", other.url, "https://atcoder.jp/contests/abc400/tasks/abc400_a")
t.eq("and its name", other.name, "Sample Problem")

--------------------------------------------------------------------------------
-- Modifier evaluation: which set applies where
--------------------------------------------------------------------------------

-- `template_file` may name the problem it is for (`~/cp/templates/$(JUDGE).cpp`), so
-- on the download path the *file* modifiers and the *download* ones are both in play
-- at once. Passing a target file is what turns the file set on.
local eval = d.eval_download_modifiers
local task = {
    name = "A. Example",
    group = "Codeforces - Round 1112",
    url = "https://codeforces.com/contest/2248/problem/A",
}

t.eq(
    "the download modifiers resolve",
    eval("$(JUDGE)/$(CONTEST)/$(PROBLEM)", task, "cpp", false, nil),
    "codeforces/2248/A. Example"
)

-- Without a file there is nothing to compute `$(FNOEXT)` from, and an unresolvable
-- modifier is a failure rather than an empty string — unchanged, and what every
-- existing caller (`eval_path`) relies on.
t.eq("a file modifier alone is unresolvable", eval("$(FNOEXT).cpp", task, "cpp", false, nil), nil)

-- With one, both sets apply, and a path may mix them.
t.eq(
    "a target file brings the file modifiers in",
    eval("$(JUDGE)/$(FNOEXT).$(FEXT)", task, "cpp", false, nil, "/tmp/probs/sol.cpp"),
    "codeforces/sol.cpp"
)
t.eq(
    "including the ones only a path can answer",
    eval("$(DIRNAME)", task, "cpp", false, nil, "/tmp/probs/sol.cpp"),
    "probs"
)

-- The illegal-character pass is for path *components*, so it must not reach the file
-- modifiers (real paths, whose separators have to survive) — it runs before they are
-- folded in, and no caller asks for both anyway.
t.eq(
    "illegal characters are still stripped from a name",
    eval("$(PROBLEM)", { name = "A/B: C", group = "Codeforces - X", url = "" }, "cpp", true, nil),
    "A_B_ C"
)

--------------------------------------------------------------------------------
-- Which template paths a task-less caller can resolve
--------------------------------------------------------------------------------

-- `:Tuna temp` and `:Tuna clean` read `template_file` with no task to hand. They ask
-- this rather than evaluating and reporting a failure, so a per-judge template makes
-- them step aside quietly instead of nagging.
local u = require("tuna.utils")
t.ok("a plain path needs nothing", u.only_file_modifiers("~/cp/t.cpp"))
t.ok("nor do the file modifiers", u.only_file_modifiers("~/cp/t.$(FEXT)"))
t.ok("$(HOME) and $(CWD) are in the file set", u.only_file_modifiers("$(HOME)/$(CWD)/$(DIRNAME)"))
t.ok("$() is a literal dollar, not a modifier", u.only_file_modifiers("$()cp/t.cpp"))
t.ok("$(JUDGE) needs a task", not u.only_file_modifiers("~/cp/$(JUDGE).cpp"))
t.ok("so does $(PROBLEM)", not u.only_file_modifiers("~/cp/$(PROBLEM).cpp"))
t.ok("one task modifier among file ones is enough", not u.only_file_modifiers("$(HOME)/$(CONTEST)/t.$(FEXT)"))


--------------------------------------------------------------------------------
-- `~` in a configured path
--------------------------------------------------------------------------------

-- `$(HOME)` is a modifier the engine expands; `~` is shell syntax that never reaches a
-- shell, so left alone it survives into the path and a download writes into a directory
-- literally *named* `~`. `eval_path` is where a configured download path becomes a real
-- one, so it is where the leading `~` is expanded — and only there, since
-- `eval_download_modifiers` also evaluates template *content*, where a leading `~` is
-- text rather than a path.
local home = vim.uv.os_homedir()
local ptask = { group = "Codeforces - Round 1", url = "https://codeforces.com/contest/1/problem/A", name = "A. Alpha" }
local pcfg = require("tuna.config").current_setup
t.eq(
    "a leading ~ becomes the home directory",
    d.eval_path("~/cp/$(PROBLEM).$(FEXT)", ptask, "cpp", pcfg),
    home .. "/cp/A. Alpha.cpp"
)
t.eq(
    "$(HOME) still works, and agrees with it",
    d.eval_path("$(HOME)/cp/$(PROBLEM).$(FEXT)", ptask, "cpp", pcfg),
    home .. "/cp/A. Alpha.cpp"
)
-- Only the leading one: `~` is an ordinary character anywhere else in a filename.
t.eq(
    "a ~ elsewhere in the path is left alone",
    d.eval_path("/tmp/a~b/$(PROBLEM).$(FEXT)", ptask, "cpp", pcfg),
    "/tmp/a~b/A. Alpha.cpp"
)
-- A path option may also be a function, and it gets the same treatment.
t.eq("a path function's result is expanded too", d.eval_path(function()
    return "~/cp/x.cpp"
end, ptask, "cpp", pcfg), home .. "/cp/x.cpp")

t.report()
