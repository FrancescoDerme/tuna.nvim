-- lua/tuna/diff.lua
--
-- The comparison the results UI draws between your output and the expected one.
--
-- Vim's own `:diffthis` (what competitest used) computes an *edit script*: it is
-- free to decide that a line was inserted or deleted and to re-align everything
-- after it. That is the right model for source code, and the wrong one for a
-- program's output. Given
--
--     yours     expected
--     2         2
--     2         2
--     0         2
--     2         5
--
-- a line diff reports "line 3 deleted" and then pairs your line 4 with expected
-- line 3 — so the two genuinely wrong values are shown as one deletion plus a
-- coincidence, and everything below drifts out of step with the answer sheet.
--
-- Competitive-programming output is *positional*: the i-th line of your output
-- answers the i-th line of the expected output, and inside a line the i-th token
-- answers the i-th token. So this module never re-aligns. It walks both sides in
-- lockstep and reports, per line, which tokens (or characters) disagree, plus the
-- lines one side has and the other does not. A wrong value is marked exactly where
-- it is, and the lines after it are judged on their own merits.
--
-- What counts as "disagree" follows the compare method actually in effect, so the
-- highlighting can never contradict the verdict: under `squish` whitespace is not a
-- difference, under `{ "float", tol }` a value within tolerance is not a difference,
-- and only under `exact` does the comparison descend to characters.

local M = {}

-- Highlight groups, created in `init.lua` linked to the editor's own diff groups.
M.CHANGE = "TunaDiffChange" -- a line whose counterpart disagrees
M.TEXT = "TunaDiffText" -- the token/characters that actually disagree
M.ADD = "TunaDiffAdd" -- a line yours has and the expected output does not
M.DELETE = "TunaDiffDelete" -- a line the expected output has and yours does not

local DEFAULT_FLOAT_TOL = 1e-6

---@class tuna.DiffMark
---@field hl string line highlight (`CHANGE`/`ADD`/`DELETE`)
---@field spans { [1]: integer, [2]: integer }[] byte ranges `[start, end)`, 0-based

---@class tuna.DiffResult
---@field out table<integer, tuna.DiffMark> marks for the output pane, by 1-based line
---@field exp table<integer, tuna.DiffMark> marks for the expected pane, by 1-based line
---@field first integer? first line carrying a mark on either side

---@private
---How finely to compare, given the compare method in effect. Characters only for
---`exact` — every other method judges tokens, so highlighting characters would flag
---spacing the verdict itself ignores. A custom function can't be introspected, so it
---gets the token view (the useful default; it is a reading aid, not the verdict).
---@param method tuna.CompareSpec
---@return "chars" | "tokens" granularity
---@return number? tol float tolerance, when the method has one
local function granularity(method)
    local name = type(method) == "table" and method[1] or method
    if name == "exact" then
        return "chars"
    elseif name == "float" then
        return "tokens", (type(method) == "table" and method.tol) or DEFAULT_FLOAT_TOL
    end
    return "tokens"
end

---@private
---Walk `col` back to the start of a UTF-8 character, so a span never cuts one in
---half (extmarks are byte-addressed, and a mid-character column renders wrongly).
---@param s string
---@param col integer 0-based byte column
---@return integer
local function utf8_floor(s, col)
    while col > 0 and s:byte(col + 1) and s:byte(col + 1) >= 0x80 and s:byte(col + 1) < 0xC0 do
        col = col - 1
    end
    return col
end

---@private
---The one span of each line that differs: everything between the common prefix and
---the common suffix. Two outputs that differ in one character mark one character.
---@param a string
---@param b string
---@return { [1]: integer, [2]: integer }[] spans_a
---@return { [1]: integer, [2]: integer }[] spans_b
local function char_spans(a, b)
    local p = 0
    while p < #a and p < #b and a:byte(p + 1) == b:byte(p + 1) do
        p = p + 1
    end
    local s = 0
    while s < #a - p and s < #b - p and a:byte(#a - s) == b:byte(#b - s) do
        s = s + 1
    end
    local pa, pb = utf8_floor(a, p), utf8_floor(b, p)
    -- The suffix boundary is a character start by construction (it follows a byte
    -- both strings share), but the prefix may have been walked back, so keep the
    -- span non-empty and ordered.
    local ea, eb = math.max(#a - s, pa), math.max(#b - s, pb)
    return { { pa, ea } }, { { pb, eb } }
end

---@private
---The whitespace-separated tokens of a line, with their byte positions.
---@param line string
---@return { text: string, s: integer, e: integer }[] tokens, `[s, e)` 0-based
local function tokens_of(line)
    local out, init = {}, 1
    while true do
        local s, e = line:find("%S+", init)
        if not s then
            return out
        end
        out[#out + 1] = { text = line:sub(s, e), s = s - 1, e = e }
        init = e + 1
    end
end

---@private
---Whether two tokens count as equal, under a float tolerance when one applies.
---@param a string
---@param b string
---@param tol number?
---@return boolean
local function tokens_equal(a, b, tol)
    if a == b then
        return true
    end
    if not tol then
        return false
    end
    local x, y = tonumber(a), tonumber(b)
    if not (x and y) then
        return false
    end
    local d = math.abs(x - y)
    return d <= tol or d <= tol * math.abs(y)
end

---@private
---Compare one line against its counterpart, positionally. Returns the byte spans to
---highlight on each side, or nil/nil when the two lines agree.
---@param a string the output line
---@param b string the expected line
---@param mode "chars" | "tokens"
---@param tol number?
---@return { [1]: integer, [2]: integer }[]? spans_a
---@return { [1]: integer, [2]: integer }[]? spans_b
local function line_spans(a, b, mode, tol)
    if a == b then
        return nil, nil
    end
    if mode == "chars" then
        return char_spans(a, b)
    end

    local ta, tb = tokens_of(a), tokens_of(b)
    local sa, sb = {}, {}
    for i = 1, math.max(#ta, #tb) do
        local x, y = ta[i], tb[i]
        if x and y then
            if not tokens_equal(x.text, y.text, tol) then
                sa[#sa + 1] = { x.s, x.e }
                sb[#sb + 1] = { y.s, y.e }
            end
        elseif x then -- a token too many on this line
            sa[#sa + 1] = { x.s, x.e }
        else -- a token missing from this line
            sb[#sb + 1] = { y.s, y.e }
        end
    end
    if #sa == 0 and #sb == 0 then
        -- Same tokens in the same places: the lines differ only in spacing, which
        -- the method in effect does not care about. Not a difference.
        return nil, nil
    end
    return sa, sb
end

---@private
---Drop the trailing empty lines a final newline leaves behind. Only for the methods
---that ignore them — under `exact` a missing trailing newline really is a mismatch.
---@param lines string[]
local function trim_trailing_blanks(lines)
    while #lines > 0 and lines[#lines]:match("^%s*$") do
        lines[#lines] = nil
    end
end

---Compare an output against the expected output, positionally.
---@param output string?
---@param expected string?
---@param method tuna.CompareSpec the compare method in effect for this runner
---@return tuna.DiffResult
function M.compute(output, expected, method)
    local mode, tol = granularity(method)
    local ol = vim.split(output or "", "\n", { plain = true })
    local el = vim.split(expected or "", "\n", { plain = true })
    if mode ~= "chars" then
        trim_trailing_blanks(ol)
        trim_trailing_blanks(el)
    end

    ---@type tuna.DiffResult
    local res = { out = {}, exp = {}, first = nil }
    for i = 1, math.max(#ol, #el) do
        local a, b = ol[i], el[i]
        if a and b then
            local sa, sb = line_spans(a, b, mode, tol)
            if sa then
                res.out[i] = { hl = M.CHANGE, spans = sa }
                res.exp[i] = { hl = M.CHANGE, spans = sb }
            end
        elseif a then
            res.out[i] = { hl = M.ADD, spans = {} }
        else
            res.exp[i] = { hl = M.DELETE, spans = {} }
        end
        if not res.first and (res.out[i] or res.exp[i]) then
            res.first = i
        end
    end
    return res
end

return M
