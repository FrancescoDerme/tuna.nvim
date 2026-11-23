-- tests/download.lua
--
-- The Competitive Companion listener and what it stores. Whatever arrives on the port is
-- untrusted (an old or patched extension, a third-party sender, a stray browser request),
-- and indexed unchecked a task without a `batch` would raise inside a libuv callback and
-- wedge the queue. Nothing here may throw; a bad task is repaired or dropped. A request is
-- handled as soon as its body is complete, and what arrives is stored without disturbing
-- the testcases already there.

local t = dofile("tests/harness.lua")
local d = require("tuna.problem.download")._test

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

-- The illegal-character pass is for path *components*, so it must not reach the file
-- modifiers (real paths, whose separators have to survive) — it runs before they are
-- folded in, and no caller asks for both anyway.
t.eq(
    "illegal characters are still stripped from a name",
    eval("$(PROBLEM)", { name = "A/B: C", group = "Codeforces - X", url = "" }, "cpp", true, nil),
    "A_B_ C"
)

--------------------------------------------------------------------------------
-- `~` in a configured path
--------------------------------------------------------------------------------

-- `$(HOME)` is a modifier the engine expands; `~` is shell syntax that never reaches a
-- shell, so left alone it survives into the path and a download writes into a directory
-- literally *named* `~`. `eval_path` is where a configured download path becomes a real
-- one, so it is where the leading `~` is expanded.
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
local widgets = require("tuna.ui.widgets")
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
    widgets.input = function(_, _, on_submit)
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
-- A downloaded problem's template has its `$(…)` filled in, its header naming the problem and
-- the URL a submit reads, and any other `$` left as written.
local function download_into(dir, name)
    widgets.input = function(_, _, on_submit)
        on_submit(dir .. "/" .. name)
    end
    d.store_single_problem(
        { name = "A. Filled", group = "Codeforces - Round", url = "https://codeforces.com/contest/1/problem/A", tests = {}, languages = {}, batch = { id = "f", size = 1 } },
        require("tuna.config").current_setup,
        function() end
    )
    return vim.fn.readfile(dir .. "/" .. name)
end
do
    local dir = t.tempdir()
    t.write(dir, "template.cpp", "// problem: $(PROBLEM)\n// submit at: $(URL)\nint main() { $(date); } // $5\n")
    require("tuna").setup({
        scaffold = { templates = { solution = dir .. "/template.cpp" } },
        open_downloaded_problems = false,
        cd_downloaded_problems = false,
    })
    t.eq("the template's header is filled in, and every other $ left alone", download_into(dir, "A/main.cpp"), {
        "// problem: A. Filled",
        "// submit at: https://codeforces.com/contest/1/problem/A",
        "int main() { $(date); } // $5",
    })
    t.eq("the problem is recorded as the file's own", (require("tuna.problem.sidecar").get_entry(dir .. "/A/main.cpp", "task") or {}).url, "https://codeforces.com/contest/1/problem/A")
    t.eq("a template is for its own language", download_into(dir, "A/main.py")[1], "# contest: codeforces 1")

    require("tuna").setup({ open_downloaded_problems = false, cd_downloaded_problems = false })
    local written = download_into(dir, "B/main.cpp")
    t.eq("with none configured, tuna's own starter is written, filled in", { written[1], written[2] }, {
        "// contest: codeforces 1",
        "// problem: A. Filled",
    })

    -- A scratch folded into the problem keeps the header of the template the problem was
    -- written from: the judge's own here, whose header is longer than the general one's.
    t.write(dir, "t.codeforces.cpp", "// $(PROBLEM)\n// $(JUDGE)\n// $(URL)\n\nint main() {}\n")
    t.write(dir, "t.cpp", "// $(PROBLEM)\n\nint main() {}\n")
    require("tuna").setup({
        scaffold = { templates = { solution = { dir .. "/t.$(JUDGE).$(FEXT)", dir .. "/t.$(FEXT)" } } },
        cd_downloaded_problems = false,
    })
    local scratch = require("tuna.workspace.scratch")
    local sbuf = vim.api.nvim_create_buf(true, false)
    scratch.pending = { lines = { "solve();" }, row = 1, bufnr = sbuf }
    t.eq("a scratch folded in keeps the header of the template used", download_into(dir, "D/main.cpp"), {
        "// A. Filled",
        "// codeforces",
        "// https://codeforces.com/contest/1/problem/A",
        "",
        "solve();",
    })

    require("tuna").setup({
        scaffold = { templates = { solution = false } },
        open_downloaded_problems = false,
        cd_downloaded_problems = false,
    })
    t.eq("and a solution configured false starts empty", download_into(dir, "C/main.cpp"), {})
    require("tuna").setup({})
end
-- `:Tuna download sync` stores what the page pressed on sent: one task is a problem, written
-- where problems go, and several are a contest, each written in the contest's folder.
do
    local dir = t.tempdir()
    require("tuna").setup({
        scaffold = { templates = { solution = false } },
        downloaded_problems_path = dir .. "/single/$(PROBLEM).$(FEXT)",
        downloaded_problems_prompt_path = false,
        downloaded_contests_directory = dir .. "/contest",
        downloaded_contests_prompt_directory = false,
        downloaded_contests_prompt_extension = false,
        open_downloaded_problems = false,
        open_downloaded_contests = false,
        cd_downloaded_problems = false,
        cd_downloaded_contests = false,
    })
    local cfg = require("tuna.config").current_setup
    local said = t.capture_notifications()
    local function task(name, size)
        return { name = name, group = "", url = "", tests = {}, languages = {}, batch = { id = "s" .. size, size = size } }
    end
    local sync = d.make_handler("sync", true, nil, cfg)
    sync({ task("One", 1) }, function() end)
    t.has("one task is said to be a problem", said[#said], "problem downloaded")
    t.eq("and stored as one", vim.fn.filereadable(dir .. "/single/One.cpp"), 1)
    sync({ task("A", 2), task("B", 2) }, function() end)
    t.has("several are said to be a contest", said[#said], "contest downloaded, 2 problems")
    t.eq("and stored as one", { vim.fn.filereadable(dir .. "/contest/A.cpp"), vim.fn.filereadable(dir .. "/contest/B.cpp") }, { 1, 1 })
    t.eq("with nothing written as a single problem", vim.fn.glob(dir .. "/single/*", false, true), { dir .. "/single/One.cpp" })

    -- The scratch a sync armed goes into that sync's download and no other: dismissed at
    -- its prompt, or stopped before anything arrives, it is let go, so a later download is
    -- not overwritten with it.
    local scratch = require("tuna.workspace.scratch")
    scratch.pending = { lines = { "scratch body" }, row = 1, bufnr = vim.api.nvim_create_buf(false, true) }
    widgets.input = function(_, _, _, on_close)
        on_close()
    end
    require("tuna.config").current_setup.downloaded_problems_prompt_path = true
    d.make_handler("sync", false, nil, require("tuna.config").current_setup)({ task("Dismissed", 1) }, function() end)
    t.eq("a sync dismissed at its prompt lets its scratch go", scratch.pending, nil)
    require("tuna").setup({})
end

--------------------------------------------------------------------------------
-- :Tuna new: a problem or contest made by hand, stored as a download is
--------------------------------------------------------------------------------

t.eq("a range of letters is each problem in it", d.problem_names("A-D"), { "A", "B", "C", "D" })
t.eq("a range of numbers is padded to one width, so it sorts in order", d.problem_names("1-10")[1], "01")
t.eq("names are split by commas, a name given twice is one problem", d.problem_names("C. Two Boxes, D. GCD, A-B, B"), { "C. Two Boxes", "D. GCD", "A", "B" })
t.eq("a name that only looks like a range is a name", d.problem_names("B-A, a-C"), { "B-A", "a-C" })
t.eq("a range of numbers is padded to the wider of its ends as typed", { d.problem_names("001-003")[1], d.problem_names("9-10")[1] }, { "001", "09" })
t.eq("and stands for every number in it, however many", #d.problem_names("1-100"), 100)
t.eq("so is no problem at all", d.problem_names(" , "), nil)

do
    local dir = t.tempdir()
    require("tuna").setup({
        scaffold = { templates = { solution = false } },
        downloaded_problems_path = dir .. "/problems/$(JUDGE)/$(PROBLEM)/main.$(FEXT)",
        downloaded_problems_prompt_path = false,
        downloaded_contests_directory = dir .. "/contests/$(JUDGE)/$(CONTEST)",
        downloaded_contests_problems_path = "$(PROBLEM)/main.$(FEXT)",
        downloaded_contests_prompt_directory = false,
        downloaded_contests_prompt_extension = false,
        open_downloaded_problems = false,
        open_downloaded_contests = false,
        cd_downloaded_problems = false,
        cd_downloaded_contests = false,
    })
    local cfg = require("tuna.config").current_setup
    local sidecar = require("tuna.problem.sidecar")
    local recent = require("tuna.workspace.recent")
    local asked = {}
    local function answer(...)
        local queue = { ... }
        asked = {}
        widgets.input = function(title, _, on_submit)
            asked[#asked + 1] = title
            on_submit(table.remove(queue, 1))
        end
    end

    local said = t.capture_notifications()
    answer("", "Onsite", "Swiss Subregional", "A-B")
    require("tuna.problem.download").new("contest", cfg)
    local contest = dir .. "/contests/onsite/swiss subregional"
    t.has("an empty answer is said", said[1] or "", "a contest needs a judge")
    t.eq("and asked again", asked[2], "judge")
    t.eq("a contest made by hand is written where a download goes", { vim.fn.filereadable(contest .. "/A/main.cpp"), vim.fn.filereadable(contest .. "/B/main.cpp") }, { 1, 1 })
    t.eq("each problem recorded by its name and contest", sidecar.get_entry(contest .. "/B/main.cpp", "task", cfg), { name = "B", group = "Onsite - Swiss Subregional" })
    t.eq("and the contest remembered, by its judge and name", {
        recent.snapshot().contests[1].dir,
        recent.snapshot().contests[1].judge,
        recent.snapshot().contests[1].name,
    }, { contest, "onsite", "swiss subregional" })
    t.eq("with no testcases written", vim.fn.glob(contest .. "/A/*_input*"), "")

    -- A contest begun by hand: its problems already there are kept as they are, and known as
    -- the problems named.
    local begun = dir .. "/contests/onsite/begun"
    vim.fn.mkdir(begun .. "/C. Two Boxes", "p")
    t.write(begun .. "/C. Two Boxes", "main.cpp", "mine\n")
    t.write(begun .. "/C. Two Boxes", ".tuna.json", vim.json.encode({ results = { ["main.cpp"] = { passed = 1, total = 1 } } }))
    local offered
    widgets.menu = function(items, _, on_choice)
        offered = items
        on_choice(1)
    end
    answer("onsite", "begun", "C. Two Boxes")
    require("tuna.problem.download").new("contest", cfg)
    t.eq("with every problem there, keeping them is offered first, before overriding", offered, { "keep them all", "override all", "stop" })
    t.eq("keeping a problem leaves its source as it is", vim.fn.readfile(begun .. "/C. Two Boxes/main.cpp"), { "mine" })
    t.eq("and records the problem it is", (sidecar.get_entry(begun .. "/C. Two Boxes/main.cpp", "task", cfg) or {}).name, "C. Two Boxes")
    t.eq("beside what its sidecar held", sidecar.get_entry(begun .. "/C. Two Boxes/main.cpp", "results", cfg), { passed = 1, total = 1 })
    t.eq("and the contest is remembered", recent.snapshot().contests[1].dir, begun)
    answer("onsite", "begun", "C. Two Boxes, D. GCD")
    require("tuna.problem.download").new("contest", cfg)
    t.eq("with some missing, the rest are written", { offered[1], vim.fn.filereadable(begun .. "/D. GCD/main.cpp") }, { "write missing only", 1 })
    t.eq("and the two are one contest", (recent.contest_of(begun .. "/D. GCD/main.cpp", cfg) or {}).dir, begun)
    widgets.menu = function(_, _, on_choice)
        on_choice(1)
    end

    -- A problem made by hand is not where a scratch waiting for a download goes.
    local scratch = require("tuna.workspace.scratch")
    scratch.pending = { lines = { "scratch body" }, row = 1, bufnr = vim.api.nvim_create_buf(false, true) }
    require("tuna.config").current_setup.open_downloaded_problems = true
    answer("Two Boxes", "Practice")
    require("tuna.problem.download").new("problem", cfg)
    local problem = dir .. "/problems/practice/Two Boxes/main.cpp"
    t.eq("a problem made by hand asks its name and judge", asked, { "problem", "judge" })
    t.eq("and is written where a download goes", vim.fn.filereadable(problem), 1)
    t.eq("recorded by its name and judge", sidecar.get_entry(problem, "task", cfg), { name = "Two Boxes", group = "Practice" })
    t.ok("leaving a waiting scratch to its download", scratch.pending ~= nil)
    scratch.pending = nil

    said = t.capture_notifications()
    require("tuna.commands").execute({ "new" })
    t.has("bare :Tuna new says what it makes", said[1] or "", "problem | contest")
    require("tuna").setup({})
end
-- `:Tuna new` takes its turn in the download queue, so its floats and a download's never
-- replace each other, dropping what one of them was asking for.
do
    require("tuna").setup({})
    local cfg = require("tuna.config").current_setup
    local download = require("tuna.problem.download")
    t.eq("a listener opens", download.start_downloading("persistently", 0, false, false, nil, cfg), nil)
    local held, menus = {}, {}
    widgets.input = function(title, _, _, on_close)
        held[#held + 1] = { title = title, close = on_close }
    end
    widgets.menu = function(_, title, on_choice, _, on_close)
        menus[#menus + 1] = { title = title, close = on_close }
    end
    download.new("contest", cfg)
    t.drain()
    t.eq("with a listener open, :Tuna new asks in its turn", held[1] and held[1].title, "judge")
    d.last_queue():enqueue({ d.validate_task({ name = "Sent" }) })
    t.drain()
    t.eq("a download arriving meanwhile waits for it", #menus, 0)
    held[1].close()
    t.drain()
    t.eq("and is stored once it is over", menus[1] and menus[1].title, "downloaded 'Sent'")
    local said = t.capture_notifications()
    download.new("problem", cfg)
    t.drain()
    t.eq("one asked for while a download is stored waits for it, and says so", { #held, said[1] }, { 1, "tuna: new: after the download being stored." })
    menus[1].close()
    t.drain()
    t.eq("asking once it is over", held[2] and held[2].title, "problem")
    held[2].close()
    download.stop_downloading()
    t.drain()

    -- A one-shot download closes its listener before its questions are answered.
    t.eq("a one-shot listener opens", download.start_downloading("problem", 0, false, false, nil, cfg), nil)
    d.last_queue():enqueue({ d.validate_task({ name = "Once" }) })
    t.drain()
    t.eq("its download asks where to store it, the listener closed", { held[3] and held[3].title, download.is_downloading() }, { "problem path", false })
    download.new("contest", cfg)
    t.drain()
    t.eq("a :Tuna new meanwhile waits", #held, 3)
    held[3].close()
    t.drain()
    t.eq("and asks once the download is over", held[4] and held[4].title, "judge")
    held[4].close()
    t.drain()
end
widgets.menu, widgets.input = real_menu, real_input

-- A question of the download's replaced by another menu is a dismissal: the queue is
-- released, so later downloads are not left waiting on a float that is gone.
do
    local dir = t.tempdir()
    t.write(dir, "Held.cpp", "old\n")
    require("tuna").setup({
        downloaded_problems_path = dir .. "/$(PROBLEM).$(FEXT)",
        downloaded_problems_prompt_path = false,
    })
    local released = false
    d.store_single_problem(
        { name = "Held", group = "", url = "", tests = {}, languages = {}, batch = { id = "h", size = 1 } },
        require("tuna.config").current_setup,
        function()
            released = true
        end
    )
    t.eq("an existing problem is asked about, the queue held meanwhile", released, false)
    widgets.menu({ "something else" }, "another question")
    t.eq("another menu taking its place releases the queue", released, true)
    t.eq("and writes nothing", vim.fn.readfile(dir .. "/Held.cpp"), { "old" })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    require("tuna").setup({})
end

t.report()
