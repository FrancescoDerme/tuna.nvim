-- lua/tuna/runner_ui/layout.lua
--
-- What the two interface modules (`popup`, `split`) agree on: the set of panes
-- that exist, their titles, and what makes a `{ ratio, child }` layout usable.
--
-- A layout names the panes it wants. Leaving one out is a legitimate choice — not
-- everyone wants the Errors pane taking a quarter of the screen — so an omitted
-- pane must simply not be drawn, never break the grid around it (competitest
-- issue #85). The pane's *buffer* still exists either way, so its content is kept
-- and stays reachable in the viewer; only the window is skipped.
--
-- `tc` is the one exception: the selector is where the cursor lives and where the
-- keymaps are bound, so a layout without it isn't a layout. `st` is not placed
-- either — it is carved out of `tc`'s rectangle by the interface.

local utils = require("tuna.utils")

local M = {}

---Every pane the UI knows, and the title on its border.
M.titles = {
    st = " Run ",
    tc = " Testcases ",
    so = " Output ",
    eo = " Expected Output ",
    si = " Input ",
    se = " Errors ",
}

---The panes a layout may place. `st` is derived from `tc`, so it isn't one of them.
M.placeable = { tc = true, so = true, eo = true, si = true, se = true }

---@private
---Collect a layout's leaf names in order, or report the first structural problem.
---@param layout any
---@param acc string[]
---@return string[]? leaves, string? err
local function collect(layout, acc)
    if type(layout) == "string" then
        if not M.placeable[layout] then
            return nil, ("unknown pane '%s'"):format(layout)
        end
        if vim.tbl_contains(acc, layout) then
            return nil, ("pane '%s' appears twice"):format(layout)
        end
        acc[#acc + 1] = layout
        return acc
    end
    if type(layout) ~= "table" or #layout == 0 then
        return nil, "expected a list of { ratio, pane-or-layout } pairs"
    end
    for _, entry in ipairs(layout) do
        if type(entry) ~= "table" or type(entry[1]) ~= "number" or entry[2] == nil then
            return nil, "expected a list of { ratio, pane-or-layout } pairs"
        end
        local ok, err = collect(entry[2], acc)
        if not ok then
            return nil, err
        end
    end
    return acc
end

---Validate a layout and report which panes it places. A layout that can't be used
---is reported once and replaced by the shipped default for that option, so a typo
---costs the user their arrangement — not their results UI.
---@param layout table the configured layout
---@param option string the option's name, for the warning (e.g. "popup_ui.layout")
---@param fallback table the default layout for that option
---@return table layout the layout to lay out
---@return table<string, boolean> placed the panes it places
function M.resolve(layout, option, fallback)
    -- The top level is always a list, even for a single pane (`{ { 1, "tc" } }`):
    -- the split interface descends by index, so a bare name there has nothing to
    -- descend into.
    local leaves, err
    if type(layout) ~= "table" then
        err = "expected a list of { ratio, pane-or-layout } pairs"
    else
        leaves, err = collect(layout, {})
    end
    if leaves and not vim.tbl_contains(leaves, "tc") then
        err = "no 'tc' pane — the testcase selector cannot be left out"
    end
    if err then
        utils.notify(("%s: %s; using the default layout."):format(option, err), "WARN")
        leaves = collect(fallback, {}) or {}
        layout = fallback
    end

    local placed = {}
    for _, name in ipairs(leaves) do
        placed[name] = true
    end
    return layout, placed
end

return M
