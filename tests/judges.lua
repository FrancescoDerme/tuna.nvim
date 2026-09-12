-- tests/judges.lua
--
-- `task.group` ("Judge - Contest") into the `$(JUDGE)`/`$(CONTEST)` a download path is
-- built from, and the built-in Codeforces rule that keys a contest on the id in the URL
-- so the same round lands in the same folder whichever host it was downloaded from.

local t = dofile("tests/harness.lua")
local judges = require("tuna.judges")

local function parse(group, url, parsers)
    local judge, contest = judges.parse({ group = group, url = url }, parsers)
    return { judge = judge, contest = contest }
end

--------------------------------------------------------------------------------
-- Codeforces: the contest id in the URL is what names the contest
--------------------------------------------------------------------------------

t.eq(
    "a live round is keyed on its id",
    parse("Codeforces - Codeforces Round 1112 (Div. 2)", "https://codeforces.com/contest/2250/problem/A"),
    { judge = "codeforces", contest = "2250" }
)
-- A mirror sends a bare "Codeforces" with no contest name at all, so every problem
-- downloaded during a live round used to land under `unknown_contest`.
t.eq(
    "a mirror with no contest name still resolves, via the id",
    parse("Codeforces", "https://m1.codeforces.com/contest/2250/problem/A"),
    { judge = "codeforces", contest = "2250" }
)
t.eq(
    "the archive view resolves to the same contest as the round",
    parse("Codeforces - Codeforces Round 1112 (Div. 2)", "https://codeforces.com/problemset/problem/2250/A"),
    { judge = "codeforces", contest = "2250" }
)
t.eq(
    "a gym keeps the word, since nothing else says gym",
    parse("Codeforces - Gym", "https://codeforces.com/gym/104123/problem/A"),
    { judge = "codeforces", contest = "gym 104123" }
)
t.eq(
    "acmsguru keeps its pseudo-contest",
    parse("Codeforces - acmsguru", "https://codeforces.com/problemsets/acmsguru/problem/99999/112"),
    { judge = "codeforces", contest = "99999" }
)
-- No id anywhere: the group's own name, lowercased, is all there is.
t.eq(
    "with no id the group's name is kept",
    parse("Codeforces - Some Mashup", "https://codeforces.com/"),
    { judge = "codeforces", contest = "some mashup" }
)

--------------------------------------------------------------------------------
-- other judges
--------------------------------------------------------------------------------

local at = parse("AtCoder - AtCoder Beginner Contest 400", "https://atcoder.jp/contests/abc400/tasks/abc400_a")
t.eq("atcoder is recognised", at.judge, "atcoder")
t.ok("and its contest is normalized", at.contest ~= "" and at.contest ~= nil, at)

t.eq(
    "an unknown judge is passed through, lowercased",
    parse("CodeChef - Starters 100", "https://codechef.com/START100/problems/X"),
    { judge = "codechef", contest = "starters 100" }
)
local bare = parse("SomeJudge", "https://example.com/p/1")
t.eq("a group with no contest half still yields the judge", bare.judge, "somejudge")
t.ok("and falls back for the contest", bare.contest ~= nil and bare.contest ~= "", bare)

--------------------------------------------------------------------------------
-- user parsers: override, catch-all, disable, and a broken one
--------------------------------------------------------------------------------

t.eq("a user parser wins over the built-in", parse("Codeforces - X", "https://codeforces.com/contest/2250/problem/A", {
    codeforces = function()
        return { contest = "mine" }
    end,
}), { judge = "codeforces", contest = "mine" })

t.eq("it may rename the judge too", parse("Codeforces - X", "https://codeforces.com/contest/2250/problem/A", {
    codeforces = function()
        return { judge = "cf", contest = "c" }
    end,
}), { judge = "cf", contest = "c" })

t.eq("a nil field keeps what was parsed", parse("CodeChef - Starters 100", "https://codechef.com/x", {
    codechef = function()
        return {}
    end,
}), { judge = "codechef", contest = "starters 100" })

-- `false` disables normalizing: the raw group half is what is used.
t.eq("false disables the built-in", parse("Codeforces - Codeforces Round 1112 (Div. 2)", "https://codeforces.com/contest/2250/problem/A", {
    codeforces = false,
}), { judge = "codeforces", contest = "codeforces round 1112 (div. 2)" })

t.eq("a catch-all applies where no judge parser does", parse("CodeChef - Starters 100", "https://codechef.com/x", {
    ["*"] = function()
        return { contest = "caught" }
    end,
}), { judge = "codechef", contest = "caught" })

-- A parser is user code on the download path, so it must not be able to take a
-- download down: it is pcall-guarded and falls back to the raw contest.
local broke = parse("CodeChef - Starters 100", "https://codechef.com/x", {
    codechef = function()
        error("boom")
    end,
})
t.eq("a broken parser falls back to the raw contest", broke, { judge = "codechef", contest = "starters 100" })

t.report()
