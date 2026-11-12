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
-- A name holding a credential's word names one, in every shape a tool writes a pair in.
for _, leak in ipairs({
    "GET /api?access_token=SECRET&x=1",
    "csrf_token=SECRET",
    "api_key=SECRET",
    "REVEL_SESSION=SECRET",
    "X-User-Sha1=SECRET",
    "Cookie: JSESSIONID=SECRET; 39ce7=SECRET",
    "Set-Cookie: 39ce7=SECRET; Path=/",
    "Authorization: Bearer SECRET",
    "authorization: basic SECRET",
    "password: SECRET",
    '{"password":"SECRET","handle":"me"}',
    "password = 'SECRET SECRET'",
    'headers: {"cookie": "a=SECRET; b=SECRET"}',
}) do
    t.ok("no credential is left in: " .. leak:gsub("SECRET", "…"), not s.redact(leak):find("SECRET"), s.redact(leak))
end
t.eq("a header's scheme is kept", s.redact("Authorization: Bearer abc"), "Authorization: Bearer <redacted>")
t.eq("a cookie header goes whole, and only its line", s.redact("Cookie: a=b; c=d\nnext"), "Cookie: <redacted>\nnext")
t.eq("a pair beside a credential keeps its value", s.redact('{"password":"x","handle":"me"}'), '{"password":"<redacted>","handle":"me"}')
t.eq("a sentence after a name loses a word, not its sense", s.redact("invalid token: please log in again"), "invalid token: <redacted> log in again")
t.eq("a URL is no header", s.redact("https://codeforces.com/contest/1/problem/A failed: limit"), "https://codeforces.com/contest/1/problem/A failed: limit")
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
t.has("and the text is a snippet, not the whole blob, in lowercase", text, "accepted")
t.ok("which does not carry the earlier frames", not text:lower():find("testing"), text)

t.eq("with no final verdict the latest pending one shows", (s.scan_verdict("Testing\tRunning on test 3", scfg)), "pending")
t.eq("a rejection is final too", (s.scan_verdict("Running\twrong answer on test 6", scfg)), "rejected")
t.eq("nothing recognisable is no verdict", s.scan_verdict("hello", scfg), nil)
t.eq("a verdict in another alphabet is matched and lowered too", { s.scan_verdict("ПРИНЯТО", { verdicts = { { "принято", "accepted" } } }) }, { "accepted", "принято" })
t.eq("a stray NUL byte is no failure", (s.scan_verdict("Accepted\0", scfg)), "accepted")
t.eq("a rule's capitals in another alphabet still match", (s.scan_verdict("Принято", { verdicts = { { "Принято", "accepted" } } })), "accepted")
t.eq("while a rule stays a pattern", (s.scan_verdict("x1", { verdicts = { { "x%S", "accepted" } } })), "accepted")
t.eq("its classes keeping their meaning", (s.scan_verdict("x ", { verdicts = { { "x%S", "accepted" } } })), nil)
t.eq("the snippet is capped in characters, none cut in half", select(2, s.scan_verdict("ок " .. ("я"):rep(80), { verdicts = { { "ок", "accepted" } } })), "ок " .. ("я"):rep(57))
t.eq("a rule naming its text shows that text, not the snippet", { s.scan_verdict("verdict: OK (12 ms)", { verdicts = { { "ok", "accepted", "accepted" } } }) }, { "accepted", "accepted" })

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
-- a judge whose verdicts are codes
--------------------------------------------------------------------------------

local ATCODER = "https://atcoder.jp/contests/abc388/tasks/abc388_a"
local base = require("tuna.config").defaults.submit
local base_rules = #base.verdicts
local atc = s.judge_scfg(base, ATCODER)
-- What the submitter prints for an AtCoder submission: the URL naming the judge, then each
-- status redrawn in place over the last.
local function atcoder_output(...)
    local out = "Submission url: https://atcoder.jp/contests/abc388/submissions/1\n"
    for _, x in ipairs({ ... }) do
        out = out .. "\27[33m" .. x .. "\27[0m" .. ("\8"):rep(#x) .. (" "):rep(#x) .. ("\8"):rep(#x)
    end
    return out
end
t.eq("atcoder's codes are read for its urls, as words", { s.scan_verdict(atcoder_output("WJ", "Testing 3/20", "AC (100)"), atc) }, { "accepted", "accepted" })
t.eq("a rejection code is final, and reads as the words codeforces prints", { s.scan_verdict(atcoder_output("WJ", "TLE (50pts)"), atc) }, { "rejected", "time limit exceeded" })
t.eq("its waiting code is pending", { s.scan_verdict(atcoder_output("WJ"), atc) }, { "pending", "in queue" })
t.eq("the default words still read its progress", { s.scan_verdict(atcoder_output("WJ", "Testing 3/20"), atc) }, { "pending", "testing 3/20" })
t.eq("a code at the very start of the output is read", (s.scan_verdict("AC\n", atc)), "accepted")
t.eq("a code stands alone, never part of the url or of a word", s.scan_verdict("Submission url: https://atcoder.jp/x\nAlready logged in, you're i.e. accepting", s.judge_scfg({ verdicts = {} }, ATCODER)), nil)
t.eq("other judges never read codes", s.scan_verdict("AC", s.judge_scfg(base, "https://codeforces.com/contest/1/problem/A")), nil)
t.eq("the user's own rules still reach atcoder", (s.scan_verdict("ok", s.judge_scfg({ verdicts = { { "ok", "accepted" } } }, ATCODER))), "accepted")
local own = s.judge_scfg({ verdicts = {}, judges = { atcoder = { verdicts = { { "yes", "accepted" } } } } }, ATCODER)
t.eq("a judge given verdicts of its own reads only those", { (s.scan_verdict("AC", own)), (s.scan_verdict("yes", own)) }, { nil, "accepted" })
t.eq("a judge's other settings leave its codes in", (s.scan_verdict("AC", s.judge_scfg({ verdicts = {}, judges = { atcoder = { watch = true } } }, ATCODER))), "accepted")
t.eq("the base config's rules are left as they were", #base.verdicts, base_rules)

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
local accepted = { state = "accepted", text = "accepted" }

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
        context(round .. "/C.cpp"):match("^no problem URL") ~= nil,
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

    -- `:Tuna go judge` opens what a submit would identify the problem by, and asks nothing
    -- of the file a submit does: no language, and no save.
    local opened, said = {}, {}
    local ui_open, notify = vim.ui.open, vim.notify
    vim.ui.open = function(url)
        opened[#opened + 1] = url
        return {}
    end
    vim.notify = function(msg)
        said[#said + 1] = msg
    end
    local function go_judge(buf)
        opened, said = {}, {}
        vim.api.nvim_set_current_buf(buf)
        require("tuna.commands").execute({ "go", "judge" })
        return opened[1] or said[1]
    end
    local function buffer_of(path)
        vim.cmd.edit(vim.fn.fnameescape(path))
        return vim.api.nvim_get_current_buf()
    end

    local downloaded = buffer_of(round .. "/B.cpp")
    vim.api.nvim_buf_set_lines(downloaded, 0, -1, false, { "unsaved" })
    t.eq("go judge opens a downloaded problem from its sidecar", go_judge(downloaded), cf .. "B")
    t.ok("and leaves the buffer unsaved", vim.bo[downloaded].modified)
    vim.bo[downloaded].modified = false
    local marked = buffer_of(round .. "/C.cpp")
    t.has("with no problem, it says how to get one", go_judge(marked), "go judge: no problem URL")
    vim.api.nvim_buf_set_lines(marked, 0, -1, false, { "// submit at: https://judge.test/p/1" })
    t.eq("a header marker gives it one, as in a submit", go_judge(marked), "https://judge.test/p/1")
    vim.api.nvim_buf_set_lines(marked, 0, -1, false, { "// submit at: $(URL)" })
    t.has("an unfilled marker is not opened", go_judge(marked), "go judge: resolved problem URL is not valid")
    vim.bo[marked].modified = false
    local nameless = vim.api.nvim_create_buf(false, true)
    t.has("a buffer with no file has no problem", go_judge(nameless), "go judge: this buffer has no file")

    -- From a runner pane, the problem is the solution the pane shows.
    local runner_ui = require("tuna.runner_ui")
    local owner_of = runner_ui.owner_of
    runner_ui.owner_of = function(buf)
        return buf == nameless and { bufnr = downloaded } or nil
    end
    t.eq("a runner pane opens its solution's problem", go_judge(nameless), cf .. "B")
    runner_ui.owner_of = owner_of

    vim.ui.open, vim.notify = ui_open, notify
end

-- A verdict shows in lowercase whatever the judge wrote, as it arrives and when it comes back
-- from a sidecar written with the judge's own capitals, while what names a file stays as it is.
do
    local submit = require("tuna.problem.submit")
    local dir = t.tempdir()
    t.write(dir, "Main.cpp", "int main() {}\n")
    local path = vim.fs.normalize(vim.uv.fs_realpath(dir)) .. "/Main.cpp"
    local cfg = require("tuna.config").current_setup
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_set_current_buf(buf)
    s.run_watch({ filepath = path, bufnr = buf, cfg = cfg, scfg = cfg.submit, name = "Main.cpp" }, "sleep 0.05; printf 'Running\\tAccepted'")
    t.has("a file's name keeps its case while it is submitted", submit.status(buf), "submitting Main.cpp")
    vim.wait(3000, function()
        return (submit.state[path] or {}).state == "accepted"
    end, 10)
    t.has("the judge's word arrives in lowercase", submit.status(buf), "accepted")
    submit.clear(buf)
    local hash = vim.fn.sha256("int main() {}\n")
    t.write(dir, ".tuna.json", vim.json.encode({ submit = { ["Main.cpp"] = { state = "rejected", text = "Wrong Answer", hash = hash } } }))
    submit.restore(buf)
    t.has("and one stored in the judge's capitals comes back in lowercase", submit.status(buf), "wrong answer")
    submit.clear(buf)
    t.write(dir, ".tuna.json", vim.json.encode({ submit = { ["Main.cpp"] = { state = "accepted", text = "ПРИНЯТО", hash = hash } } }))
    submit.restore(buf)
    t.has("in any alphabet", submit.status(buf), "принято")
    submit.clear(buf)
    t.write(dir, ".tuna.json", ('{"submit":{"Main.cpp":{"state":"accepted","text":"Accepted\\u0000 x","hash":"%s"}}}'):format(hash))
    t.eq("a NUL stored in one is no failure", submit.verdict_for(path).text, "accepted x")
    t.write(dir, ".tuna.json", vim.json.encode({ submit = { ["Main.cpp"] = { state = "rejected", text = "Wrong Answer", hash = hash } } }))
    t.eq("as it does read from the path alone", submit.verdict_for(path).text, "wrong answer")
    -- An edit made while a submission is watched leaves the watch alone, though an earlier
    -- verdict armed the buffer to drop its own on the first edit.
    submit.clear(buf)
    submit.restore(buf)
    t.has("a stored verdict is shown, armed to go with an edit", submit.status(buf), "wrong answer")
    s.run_watch({ filepath = path, bufnr = buf, cfg = cfg, scfg = cfg.submit }, "sleep 0.3; printf 'Accepted'")
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    t.has("an edit while a new submission is watched does not stop the watch", submit.status(buf), "submitting")
    vim.wait(3000, function()
        return (submit.state[path] or {}).state == "accepted"
    end, 10)
    t.eq("whose verdict still arrives", (submit.state[path] or {}).state, "accepted")
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    t.eq("and goes with the next edit", submit.status(buf), "")

    -- A tool redrawing its status for a long time is read by its latest output alone: the
    -- submission's URL, printed first, is kept, and the verdict at the end is found.
    s.run_watch(
        { filepath = path, bufnr = buf, cfg = cfg, scfg = cfg.submit },
        "printf 'Submission url: https://judge.example/1\\n'; i=0; while [ $i -lt 400 ]; do printf 'Running on test %d                              \\t' $i; i=$((i+1)); done; sleep 0.1; printf 'Wrong answer on test 7'"
    )
    vim.wait(5000, function()
        return (submit.state[path] or {}).state == "rejected"
    end, 10)
    t.eq("a verdict after pages of frames is read", { (submit.state[path] or {}).state, (submit.state[path] or {}).text }, { "rejected", "wrong answer on test 7" })
    t.eq("with the URL from before them", (submit.state[path] or {}).url, "https://judge.example/1")
    submit.clear(buf)

    -- The sidecar travels with the folder and may be edited by hand.
    for _, text in ipairs({ "null", "3" }) do
        t.write(dir, ".tuna.json", ('{"submit":{"Main.cpp":{"state":"accepted","text":%s,"hash":"%s"}}}'):format(text, hash))
        t.eq("an entry with no words is no verdict, " .. text, { pcall(submit.restore, buf) }, { true })
        t.eq("and shows nothing", submit.status(buf), "")
    end
end

t.report()
