-- tests/submit.lua
--
-- Reading a submit tool's output. Two things are load-bearing here: a failure has to
-- come back as one readable tuna line rather than a dump, and nothing in that line may
-- carry the user's judge credentials — the Rust submitter's panic quotes the whole
-- request URL, `apiKey` and `apiSig` included, and the user may well be screen-sharing.

local t = dofile("tests/harness.lua")
local s = require("tuna.problem.submit")._test

--------------------------------------------------------------------------------
-- redact: by parameter name, since a credential is whatever the query calls one
--------------------------------------------------------------------------------

t.has("apiKey is blanked", s.redact("?apiKey=abc123&y=1"), "apiKey=<redacted>")
-- A value stops at `?` as well as `&`: without that the greedy value of the outer
-- parameter swallowed the credential after it and left it in the message.
t.has("even behind an outer parameter", s.redact("url=https://x?apiKey=abc123&y=1"), "apiKey=<redacted>")
t.ok("with the secret gone", not s.redact("url=https://x?apiKey=abc123"):find("abc123"))
t.has("apiSig too", s.redact("apiSig=deadbeef"), "apiSig=<redacted>")
t.has("and a token", s.redact("token=hunter2"), "token=<redacted>")
t.has("the name is matched case-insensitively", s.redact("APIKEY=abc"), "<redacted>")
t.has("an ordinary parameter is left alone", s.redact("contestId=2248"), "contestId=2248")
t.ok("the secret itself is gone", not s.redact("apiKey=s3cret&handle=me"):find("s3cret"))
t.has("while the rest of the line survives", s.redact("apiKey=s3cret&handle=me"), "handle=me")

--------------------------------------------------------------------------------
-- failure_reason: classify before falling back to the tool's own words
--------------------------------------------------------------------------------

-- The real panic, captured by running the submitter with the network down. Before it
-- was classified, all 450 characters of this reached the notification.
local PANIC = table.concat({
    "thread 'main' panicked at src/main.rs:120:10:",
    "called `Result::unwrap()` on an `Err` value: reqwest::Error { kind: Request, ",
    'url: "https://codeforces.com/api/user.info?handles=me&apiKey=abcdef123456&apiSig=99abc/deadbeef", ',
    "source: hyper_util::client::legacy::Error(Connect, ConnectError(\"dns error\", ",
    "Custom { kind: Uncategorized, error: \"failed to lookup address information\" })) }",
    "note: run with `RUST_BACKTRACE=1` to display a backtrace",
}, "\n")

local reason, short = s.failure_reason(PANIC, "", 101)
-- Being offline is the case the user can act on, so it is checked first: a crash
-- *caused* by no network is an offline failure, not a crash.
t.has("an offline panic is reported as no network", reason, "could not reach the judge")
t.eq("and lualine says so", short, "no connection")
t.ok("nothing leaks the apiKey", not reason:find("abcdef123456"), reason)
t.ok("nor the apiSig", not reason:find("deadbeef"), reason)
t.ok("the message is one line", not reason:find("\n"), reason)

-- A tool that named its submission had submitted, so only the verdict was lost.
local lost, lost_short = s.failure_reason(PANIC, "", 101, true)
t.has("offline after the submission is named loses the verdict, not the submission", lost, "submission went through")
t.eq("and lualine says so", lost_short, "verdict unknown")
t.ok("still leaking nothing", not lost:find("abcdef123456"), lost)
t.eq("a tool's own words after the submission are still its own, and no failed submit",
    { s.failure_reason("error: quota reached", "", 1, true) }, { "error: quota reached", "verdict unknown" })
t.eq("nor is a silent exit after it", { s.failure_reason("", "", 1, true) }, { "exited with code 1", "verdict unknown" })

for _, hint in ipairs({ "connection refused", "no route to host", "name resolution failed" }) do
    local r, sh = s.failure_reason("error: " .. hint, "", 1)
    t.has("'" .. hint .. "' is an offline failure", r, "could not reach the judge")
    t.eq("'" .. hint .. "' shows as no connection", sh, "no connection")
end

-- A crash with nothing to say: a dump names an error on every line, so the tail
-- heuristic picked the longest and least readable of them.
local r2, short2 = s.failure_reason("thread 'main' panicked at src/main.rs:9:1:\nindex out of bounds", "", 101)
t.has("a crash with no network cause is reported as a crash", r2, "crashed")
t.has("and points at the log", r2, "log_file")
t.eq("with its own lualine state", short2, "tool crashed")

local r3 = s.failure_reason("Traceback (most recent call last):\n  File \"x.py\", line 1", "", 1)
t.has("a Python traceback counts as a crash", r3, "crashed")

-- A tool with something real to say keeps saying it, including on stdout while
-- exiting 0 — which is how the Rust submitter reports an unsupported judge.
local r4, short4 = s.failure_reason("", "[INFO] reading config\nUnsupported domain: atcoder.jp\n[INFO] save cookie to: /tmp/c", 0)
t.has("a real message survives the routine noise around it", r4, "Unsupported domain")
t.eq("and is an ordinary failure", short4, "submit failed")

local r5 = s.failure_reason("[ERROR] submission failed: you have submitted exactly the same code before\n[INFO] done", "", 1)
t.has("a judge's own alert is surfaced", r5, "same code before")

-- Past a sentence's length, what is being shown is a dump.
local r6 = s.failure_reason("error: " .. string.rep("x", 500), "", 1)
t.ok("a long tail is clamped", vim.fn.strchars(r6) <= 160, vim.fn.strchars(r6))
-- Checked in *bytes*, because none of Vim's character functions can tell a truncated
-- trailing byte from a whole character: `strchars`, `str_utfindex` and a `strcharpart`
-- round trip all count the broken tail as one. With every character two bytes wide, a
-- clamp that cut on a byte boundary would leave an odd number behind.
local multi = s.failure_reason(string.rep("é", 500), "", 1)
local body = multi:gsub("…$", "")
t.ok("a multi-byte tail is clamped by characters", #body == 2 * vim.fn.strchars(body), {
    bytes = #body,
    chars = vim.fn.strchars(body),
})

t.eq("nothing to say at all falls back to the exit code", s.failure_reason("", "", 7), "exited with code 7")

--------------------------------------------------------------------------------
-- scan_verdict: a final verdict wins over a pending one, wherever it sits
--------------------------------------------------------------------------------

local scfg = {
    verdicts = {
        { "accepted", "accepted" },
        { "wrong answer on test (%d+)", "rejected" },
        { "running", "pending" },
        { "testing", "pending" },
    },
}
-- A crossterm submitter redraws in place, so after control-stripping every frame is on
-- one line: a plain last-line scan matched "Testing" and never reached "Accepted".
local state, text = s.scan_verdict("Testing\tRunning on test 3\tAccepted", scfg)
t.eq("a final verdict beats the pending frames before it", state, "accepted")
t.has("and the text is a snippet, not the whole blob", text, "Accepted")
t.ok("which does not carry the earlier frames", not text:lower():find("testing"), text)

t.eq("with no final verdict the latest pending one shows", (s.scan_verdict("Testing\tRunning on test 3", scfg)), "pending")
t.eq("a rejection is final too", (s.scan_verdict("Running\twrong answer on test 6", scfg)), "rejected")
t.eq("nothing recognisable is no verdict", s.scan_verdict("hello", scfg), nil)

-- Terminal control has to go, or a redrawing submitter leaks ^H and escape junk into
-- lualine.
t.eq("OSC and CSI sequences are stripped", s.strip_ansi("\27[38;5;9mAccepted\27[0m\27[?25l"), "Accepted")
t.eq("so are stray control bytes", s.strip_ansi("Acce\bepted"):gsub("%s", ""), "Acceepted")

--------------------------------------------------------------------------------
-- which URLs are usable, and which judge one names
--------------------------------------------------------------------------------

t.eq("a real URL is valid", s.is_valid_url("https://codeforces.com/contest/1/problem/A"), true)
t.eq("http counts", s.is_valid_url("http://example.com/x"), true)
-- Submitting a raw template must fail fast rather than hand garbage to the submitter.
t.eq("an unexpanded modifier is not a URL", s.is_valid_url("$(URL)"), false)
t.eq("nor is one hiding inside a URL", s.is_valid_url("https://codeforces.com/$(PROBLEM)"), false)
t.eq("a bare word is not a URL", s.is_valid_url("codeforces.com"), false)
t.eq("nor is nil", s.is_valid_url(nil), false)

t.eq("codeforces is routed to itself", s.judge_of("https://codeforces.com/contest/1/problem/A"), "codeforces")
t.eq("a mirror routes to codeforces too", s.judge_of("https://m1.codeforces.com/contest/1/submit"), "codeforces")
t.eq("atcoder is its own judge", s.judge_of("https://atcoder.jp/contests/abc400/tasks/abc400_a"), "atcoder")
t.eq("www is not part of the name", s.judge_of("https://www.codechef.com/x"), "codechef")

--------------------------------------------------------------------------------
-- The verdict a problem carries, read without opening it
--------------------------------------------------------------------------------

-- The menu says how a problem went beside its name, for a problem that is not the
-- one you are on and may not be open at all — so the verdict has to be readable from a
-- path. Same source and same staleness rule as `M.restore`: a verdict describes the
-- source it was submitted from, and says nothing about one edited since.
require("tuna").setup({})
local vdir = t.tempdir()
local source = "int main(){}\n"
t.write(vdir, "main.cpp", source)
local vpath = vdir .. "/main.cpp"
local function mtime_of(path)
    local st = vim.uv.fs_stat(path)
    return st.mtime.sec .. "." .. (st.mtime.nsec or 0)
end
local function write_entry(entry)
    entry.state = entry.state or "accepted"
    entry.text = entry.text or "Accepted"
    t.write(vdir, ".tuna.json", vim.json.encode({
        url = "https://codeforces.com/contest/1/problem/A",
        submit = { ["main.cpp"] = entry },
    }))
end
local verdict_for = require("tuna.problem.submit").verdict_for
local accepted = { state = "accepted", text = "Accepted" }

t.eq("no sidecar, no verdict", verdict_for(vpath), nil)
write_entry({ hash = vim.fn.sha256(source) })
t.eq("a recorded verdict is readable from the path alone", verdict_for(vpath), accepted)
-- A verdict belongs to the source that was submitted, not to the moment it was written:
-- a `:w` with nothing changed, or the save before a run, moves the mtime and nothing else.
vim.uv.fs_utime(vpath, 1, 1)
t.eq("a write that changes nothing keeps it", verdict_for(vpath), accepted)
t.write(vdir, "main.cpp", source .. "// edited\n")
t.eq("an edit drops it", verdict_for(vpath), nil)
t.write(vdir, "main.cpp", source)
write_entry({ mtime = mtime_of(vpath) })
t.eq("an entry without the source's hash describes no source, so it is not shown", verdict_for(vpath), nil)
-- Only a *final* verdict is a verdict: a submission still running says nothing yet.
write_entry({ state = "pending", text = "Running", hash = vim.fn.sha256(source) })
t.eq("a pending submission is not a verdict", verdict_for(vpath), nil)
t.eq("and neither is a path that is not a file", verdict_for(""), nil)

-- The save before a run writes only a buffer with changes, so an unchanged solution is left
-- untouched on disk.
vim.uv.fs_utime(vpath, 1, 1)
local vbuf = vim.fn.bufadd(vpath)
vim.fn.bufload(vbuf)
require("tuna.run.tools").save_sources(vbuf, { save_current_file = true })
t.eq("the save before a run leaves an unchanged file alone", mtime_of(vpath), "1.0")
vim.api.nvim_buf_set_lines(vbuf, 0, 0, false, { "// typed" })
require("tuna.run.tools").save_sources(vbuf, { save_current_file = true })
t.eq("and writes one that has changes", vim.fn.readfile(vpath)[1], "// typed")
vim.api.nvim_buf_delete(vbuf, { force = true })

-- An edit hides a shown verdict and keeps the stored one, which counts again, shown with it,
-- once a write takes the source back to the one submitted.
t.write(vdir, "main.cpp", source)
write_entry({ hash = vim.fn.sha256(source) })
local submit = require("tuna.problem.submit")
vim.cmd.edit(vim.fn.fnameescape(vpath))
local sbuf = vim.api.nvim_get_current_buf()
local function shown()
    return submit.state[vim.fs.normalize(vpath)] ~= nil
end
t.eq("a verdict is shown for the source submitted", shown(), true)
vim.api.nvim_buf_set_lines(sbuf, 0, 0, false, { "// typed" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = sbuf })
t.eq("an edit hides it", shown(), false)
t.eq("and keeps it stored", require("tuna.problem.sidecar").get_entry(vpath, "submit") ~= nil, true)
vim.cmd("silent write")
t.eq("a write of other source does not bring it back", { shown(), verdict_for(vpath) }, { false, nil })
vim.api.nvim_buf_set_lines(sbuf, 0, 1, false, {})
vim.cmd("silent write")
t.eq("a write of the source submitted does, shown and counted", { shown(), verdict_for(vpath) }, { true, accepted })
vim.api.nvim_buf_delete(sbuf, { force = true })
vim.fn.delete(vdir, "rf")

--------------------------------------------------------------------------------
-- What silence means, once a watched submit's tool has exited
--------------------------------------------------------------------------------

-- Watch mode is on by default, so this decides what happens for every tool whose verdict
-- wording is not in `submit.verdicts` — which is every tool nobody has written patterns
-- for. Getting it wrong the other way is the worst answer tuna could give: telling you a
-- submission failed when it did not.
t.eq("a clean exit with no verdict is not a failure", s.watch_outcome(0), "clear")
t.eq("a non-zero exit is the tool's own word for one", s.watch_outcome(1), "error")
t.eq("whatever the code", s.watch_outcome(101), "error")

--------------------------------------------------------------------------------
-- The problem a file is a solution of
--------------------------------------------------------------------------------

-- A contest's problems may be files of one folder, so the problem a submit reads is the file's
-- own: each file its own URL and mirror, a second attempt beside a solution that solution's, and
-- a file of a folder of several problems none.
do
    local submit, sidecar = require("tuna.problem.submit"), require("tuna.problem.sidecar")
    local cfg = require("tuna.config").current_setup
    local cf = "https://codeforces.com/contest/7/problem/"
    local round = t.tempdir()
    for _, p in ipairs({ "A", "B", "C" }) do
        t.write(round, p .. ".cpp", "int main() {}\n")
    end
    submit.write_task_store(round .. "/A.cpp", { url = cf .. "A", name = "A", group = "Codeforces - Round 7", mirror = "m1" }, cfg)
    submit.write_task_store(round .. "/B.cpp", { url = cf .. "B", name = "B", group = "Codeforces - Round 7" }, cfg)
    local one = t.tempdir()
    t.write(one, "main.cpp", "int main() {}\n")
    t.write(one, "main2.cpp", "int main() {}\n")
    submit.write_task_store(one .. "/main.cpp", { url = cf .. "D", name = "D", group = "Codeforces - Round 7" }, cfg)
    local function context(path)
        vim.cmd.edit(vim.fn.fnameescape(path))
        vim.bo.filetype = "cpp"
        local ctx, err = submit.context(vim.api.nvim_get_current_buf())
        return ctx and ctx.url or err
    end
    t.eq("each file's problem is its own, and a second attempt takes the folder's one", {
        context(round .. "/A.cpp"),
        context(round .. "/B.cpp"),
        context(round .. "/C.cpp"):match("^no submission URL") ~= nil,
        context(one .. "/main2.cpp"),
    }, { cf .. "A", cf .. "B", true, cf .. "D" })
    t.eq("and a mirror is the file's it was downloaded with", {
        submit.builtin_url_rewrite(cf .. "A", { filepath = round .. "/A.cpp", cfg = cfg }),
        submit.builtin_url_rewrite(cf .. "B", { filepath = round .. "/B.cpp", cfg = cfg }),
    }, { "https://m1.codeforces.com/contest/7/problem/", nil })
    os.remove(round .. "/A.cpp")
    sidecar.set_entry(round .. "/B.cpp", "results", { passed = 1, total = 1 })
    t.eq("a file's problem outlives it, for a solution written again in its place", (sidecar.task(round .. "/A.cpp", cfg) or {}).url, cf .. "A")

    -- A submit records the problem as the file's own, so the file keeps it whatever is added
    -- beside it.
    submit.providers.stub = function() end
    require("tuna").setup({ submit = { provider = "stub" } })
    vim.cmd.edit(vim.fn.fnameescape(one .. "/main2.cpp"))
    vim.bo.filetype = "cpp"
    submit.submit(vim.api.nvim_get_current_buf())
    t.eq("a submit records the problem as the file's own", (sidecar.get_entry(one .. "/main2.cpp", "task") or {}).url, cf .. "D")
    submit.providers.stub = nil
    require("tuna").setup({})
end

t.report()
