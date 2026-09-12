-- tests/submit.lua
--
-- Reading a submit tool's output. Two things are load-bearing here: a failure has to
-- come back as one readable tuna line rather than a dump, and nothing in that line may
-- carry the user's judge credentials — the Rust submitter's panic quotes the whole
-- request URL, `apiKey` and `apiSig` included, and the user may well be screen-sharing.

local t = dofile("tests/harness.lua")
local s = require("tuna.submit")._test

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

-- The dashboard says how a problem went beside its name, for a problem that is not the
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
local verdict_for = require("tuna.submit").verdict_for
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
t.eq("an entry carrying only an mtime is checked against it", verdict_for(vpath), accepted)
write_entry({ mtime = "0.0" })
t.eq("and dropped when the mtime differs", verdict_for(vpath), nil)
-- Only a *final* verdict is a verdict: a submission still running says nothing yet.
write_entry({ state = "pending", text = "Running", hash = vim.fn.sha256(source) })
t.eq("a pending submission is not a verdict", verdict_for(vpath), nil)
t.eq("and neither is a path that is not a file", verdict_for(""), nil)

-- The save before a run writes only a buffer with changes, so an unchanged solution is left
-- untouched on disk.
vim.uv.fs_utime(vpath, 1, 1)
local vbuf = vim.fn.bufadd(vpath)
vim.fn.bufload(vbuf)
require("tuna.tools").save_sources(vbuf, { save_current_file = true })
t.eq("the save before a run leaves an unchanged file alone", mtime_of(vpath), "1.0")
vim.api.nvim_buf_set_lines(vbuf, 0, 0, false, { "// typed" })
require("tuna.tools").save_sources(vbuf, { save_current_file = true })
t.eq("and writes one that has changes", vim.fn.readfile(vpath)[1], "// typed")
vim.api.nvim_buf_delete(vbuf, { force = true })
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

t.report()
