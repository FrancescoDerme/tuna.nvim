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
        local c = ctx.contest
        local edu = c:match("educational.-codeforces.-round%s*(%d+)")
        local global = c:match("codeforces.-global.-round%s*(%d+)")
        local round = c:match("codeforces.-round%s*(%d+)")
        local specific = c:match("^(%a+.-round%s*%d+)")
        if edu then
            return { contest = "edu round " .. edu }
        elseif global then
            return { contest = "global round " .. global }
        elseif round then
            return { contest = "round " .. round }
        elseif specific then
            return { contest = specific }
        end
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
    if not hyphen then
        -- No "Judge - Contest" shape; use the whole group (lowercased) as the judge.
        return (group ~= "" and group:lower()) or "unknown_judge", "unknown_contest"
    end

    local judge = group:sub(1, hyphen - 1):lower()
    local contest = group:sub(hyphen + 3):lower()

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
    return judge, contest
end

return M
