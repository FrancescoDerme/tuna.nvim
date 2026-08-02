-- lua/tuna/judges.lua
--
-- Turns Competitive Companion's `task.group` ("Judge - Contest") into a tidy
-- `judge` + `contest` pair used by the download-path modifiers ($(JUDGE)/$(CONTEST))
-- and thus the on-disk folder names.
--
-- A *parser* normalizes one judge's contest names. Built-in parsers ship for
-- Codeforces and AtCoder (ported from the original competitest hack); users add
-- parsers for new judges — or override/disable the built-ins — via
-- `config.judge_parsers`. Resolution order for a given judge:
--
--   config.judge_parsers[judge]   -- user parser (or `false` to disable normalizing)
--   M.builtin[judge]              -- shipped default
--   config.judge_parsers["*"]     -- user catch-all applied to any other judge
--
-- A parser receives a context and returns overrides; nil fields keep the parsed
-- defaults, so a parser only needs to return what it wants to change.

local M = {}

---@class tuna.JudgeContext
---@field judge string    lowercased judge name (the part of `group` before " - ")
---@field contest string  lowercased raw contest name (the part after " - ")
---@field group string    the full original `task.group`
---@field task tuna.CCTask the whole Competitive Companion task

---@alias tuna.JudgeParser fun(ctx: tuna.JudgeContext): { judge: string?, contest: string? }?

---Built-in per-judge normalizers. Keyed by the lowercased judge name.
---@type table<string, tuna.JudgeParser>
M.builtin = {
    codeforces = function(ctx)
        -- **The contest id, not the round name.** Codeforces can be downloaded from the
        -- main site or from a **mirror** (m1/m2/m3.codeforces.com, which carry a live
        -- round), and the two do not describe a contest the same way: the main site
        -- sends `"Codeforces - Codeforces Round 1112 (Div. 2)"`, a mirror sends a bare
        -- `"Codeforces"` with no contest name at all. The id in the URL is the one
        -- thing they agree on — and it needs no network lookup, which the download path
        -- must not be doing mid-contest — so deriving the folder from it files the same
        -- contest in the same place whichever host it came from. That is worth more
        -- than a prettier name that only one of the two sources can produce.
        local url = ctx.task and ctx.task.url or ""
        local gym = url:match("/gym/(%d+)")
        if gym then
            return { contest = "gym " .. gym }
        end
        -- Every other Codeforces shape carries the contest id: a live or archived
        -- contest, a group's or an edu course's contest (both `…/contest/<id>/…`), the
        -- problemset's archive view of one, and acmsguru (whose pseudo-contest is
        -- 99999). The archive views resolve to the same id as the round they came from,
        -- so a problem pulled later lands beside the ones downloaded during it.
        local id = url:match("/contest/(%d+)")
            or url:match("/problemset/problem/(%d+)/")
            or url:match("/problemsets/acmsguru/problem/(%d+)/")
        if id then
            -- Bare, with no "contest" word: `$(CONTEST)` is *already* used in places
            -- that say what it is — the folder sits under `$(JUDGE)`, and the template
            -- header reads `contest: $(JUDGE) $(CONTEST)` — so spelling it again gave
            -- `contest: codeforces contest 2248`. It is also how Codeforces itself
            -- names a contest. Gyms keep their word, since nothing else says "gym".
            return { contest = id }
        end
        -- Anything else keeps the group's own name. There used to be a set of
        -- normalizers here turning "Codeforces Round 1112 (Div. 2)" into `round 1112`,
        -- and they are deliberately gone: with the id available on every real URL they
        -- were unreachable, and they could not be made to agree with the id-based names
        -- because **a round number is not a contest id** — round 1112 is contest 2250,
        -- global round 29 is contest 2119. Calling it `contest 1112` would both misname
        -- the folder and collide with the actual contest 1112.
        return nil
    end,

    atcoder = function(ctx)
        local c = ctx.contest
        local beg = c:match("beginner.-contest%s*(%d+)")
        local round = c:match("contest%s*(%d+)")
        if beg then
            return { contest = "beg round " .. beg }
        elseif round then
            return { contest = "reg round " .. round }
        end
    end,
}

---Parse a task's `group` into a `judge` + `contest`, applying the effective parser.
---@param task tuna.CCTask
---@param judge_parsers table<string, tuna.JudgeParser|false>? user parsers (config.judge_parsers)
---@return string judge, string contest
function M.parse(task, judge_parsers)
    judge_parsers = judge_parsers or {}
    local group = task.group or ""
    local hyphen = group:find(" - ", 1, true)
    local judge, contest
    if hyphen then
        judge = group:sub(1, hyphen - 1):lower()
        contest = group:sub(hyphen + 3):lower()
    else
        -- No "Judge - Contest" shape: the whole group is the judge, and there is no
        -- contest name. This is **not** a dead end — a parser is still run, with an
        -- empty `contest`, because it may know where else to find one (a Codeforces
        -- mirror sends a bare "Codeforces" but still carries the contest in the URL).
        -- Only if nothing supplies one does this fall back to `unknown_contest`.
        judge = group ~= "" and group:lower() or "unknown_judge"
        contest = ""
    end

    -- An explicit user entry wins (a literal `false` disables normalization for that
    -- judge); otherwise the built-in for this judge; otherwise a user "*" catch-all.
    local parser = judge_parsers[judge]
    if parser == nil then
        parser = M.builtin[judge]
    end
    if parser == nil then
        parser = judge_parsers["*"]
    end

    if type(parser) == "function" then
        local ok, res = pcall(parser, { judge = judge, contest = contest, group = group, task = task })
        if not ok then
            require("tuna.utils").notify(
                "judge parser for '" .. judge .. "' errored; using the raw contest name.",
                "WARN"
            )
        elseif type(res) == "table" then
            judge = res.judge or judge
            contest = res.contest or contest
        end
    end
    if contest == "" then
        contest = "unknown_contest"
    end
    return judge, contest
end

return M
