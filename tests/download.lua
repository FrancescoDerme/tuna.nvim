-- tests/download.lua
--
-- The Competitive Companion listener and what it stores. Whatever arrives on the port is
-- untrusted (an old or patched extension, a third-party sender, a stray browser request),
-- and indexed unchecked a task without a `batch` would raise inside a libuv callback and
-- wedge the queue. Nothing here may throw; a bad task is repaired or dropped. A request is
-- handled as soon as its body is complete, and what arrives is stored without disturbing
-- the testcases already there.

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

--------------------------------------------------------------------------------
-- The listener answers a request as soon as its body is complete
--------------------------------------------------------------------------------

local request_body = d.request_body
local head = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 7\r\n\r\n"
t.eq("a body is complete once Content-Length of it has arrived", request_body(head .. '{"a":1}', false), '{"a":1}')
t.eq("and not before", request_body(head .. '{"a"', false), nil)
t.eq("a request without a length is complete when the sender closes", request_body("POST / HTTP/1.1\r\n\r\n{}", true), "{}")
t.eq("and waits until then", request_body("POST / HTTP/1.1\r\n\r\n{}", false), nil)

-- Live: the sender keeps its side open, as a client waiting for a reply does, and the task
-- still arrives at once, with a 200 back.
do
    local got, reply
    local listener = d.Listener.new("127.0.0.1", 27197, function(task)
        got = task.name
    end)
    t.ok("the listener starts", type(listener) == "table", listener)
    local body = vim.json.encode({ name = "A. Waits", tests = {} })
    local client = assert(vim.uv.new_tcp())
    client:connect("127.0.0.1", 27197, function()
        client:read_start(function(_, chunk)
            if chunk then
                reply = (reply or "") .. chunk
            end
        end)
        client:write(("POST / HTTP/1.1\r\nContent-Length: %d\r\n\r\n%s"):format(#body, body))
    end)
    vim.wait(1000, function()
        return got ~= nil and reply ~= nil
    end, 5)
    t.eq("a task arrives while the sender is still connected", got, "A. Waits")
    t.has("and the sender is answered", reply or "", "HTTP/1.1 200 OK")
    client:close()
    if type(listener) == "table" then
        listener:close()
    end
end

--------------------------------------------------------------------------------
-- Storing what arrives
--------------------------------------------------------------------------------

require("tuna").setup({})
local widgets = require("tuna.widgets")
local real_menu, real_input = widgets.menu, widgets.input
widgets.menu = function(_, _, on_choice)
    on_choice(1)
end

-- Kept alongside the new ones, a testcase already there stays exactly as it is stored: its
-- empty answer ("expect no output") is still an empty answer.
do
    local pdir = t.tempdir()
    t.write(pdir, "sol.cpp", "int main(){}\n")
    t.write(pdir, "sol_input0.txt", "1\n")
    t.write(pdir, "sol_output0.txt", "")
    vim.cmd("edit " .. pdir .. "/sol.cpp")
    local done = false
    d.store_testcases_into_buffer(vim.api.nvim_get_current_buf(), { { input = "5\n", output = "10\n" } }, false, function()
        done = true
    end)
    t.ok("keeping them stores the new testcase beside the old", done and vim.fn.filereadable(pdir .. "/sol_input1.txt") == 1)
    t.eq("and the old one's empty answer is still there", vim.fn.filereadable(pdir .. "/sol_output0.txt"), 1)
end

-- A buffer with no file has nowhere to keep testcases: said, and nothing is written.
do
    local cwd = t.tempdir()
    vim.cmd("cd " .. cwd)
    vim.cmd("enew")
    local quiet = vim.notify
    local said = t.capture_notifications()
    local done = false
    d.store_testcases_into_buffer(vim.api.nvim_get_current_buf(), { { input = "5\n", output = "10\n" } }, false, function()
        done = true
    end)
    vim.notify = quiet
    t.eq("testcases for a buffer with no file write nothing", vim.fn.glob(cwd .. "/*"), "")
    t.has("and say so", said[1] or "", "open the solution")
    t.ok("releasing the download queue", done)
end

-- A path typed in the prompt is read like a configured one: `~` is the home directory.
do
    local home, cwd = t.tempdir(), t.tempdir()
    vim.cmd("cd " .. cwd)
    local real_home = vim.uv.os_homedir
    vim.uv.os_homedir = function()
        return home
    end
    widgets.input = function(_, _, _, _, _, on_submit)
        on_submit("~/typed/sol.cpp")
    end
    local cfg = vim.tbl_extend("force", require("tuna.config").current_setup, { open_downloaded_problems = false })
    local done = false
    d.store_single_problem(
        { name = "A. Typed", group = "", url = "", tests = { { input = "1\n", output = "1\n" } }, languages = {}, batch = { id = "t", size = 1 } },
        cfg,
        function()
            done = true
        end
    )
    vim.uv.os_homedir = real_home
    t.ok("a typed ~ path writes the source under the home directory", done and vim.fn.filereadable(home .. "/typed/sol.cpp") == 1)
    t.eq("with its testcases beside it", vim.fn.filereadable(home .. "/typed/sol_input0.txt"), 1)
    t.eq("and no directory called ~", vim.fn.isdirectory(cwd .. "/~"), 0)
end
widgets.menu, widgets.input = real_menu, real_input

t.report()
