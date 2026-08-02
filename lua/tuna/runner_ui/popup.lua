-- lua/tuna/runner_ui/popup.lua
--
-- The "popup" interface: the runner UI as a grid of floating windows laid out by
-- a recursive layout engine driven by `popup_ui.layout`.
--
-- A layout is a list of `{ ratio, child }` pairs, where `child` is either a
-- window name (a leaf: "tc"/"so"/"eo"/"si"/"se") or a nested layout. Levels
-- alternate direction: the top level splits horizontally (columns), the next
-- vertically (rows), and so on. `rec_compute_layout` walks that tree and assigns
-- each leaf a rectangle; we then open one bordered float per leaf.

local api = vim.api
local utils = require("tuna.utils")
local layout_util = require("tuna.runner_ui.layout")
local surface = require("tuna.surface")

local M = {}

local titles = layout_util.titles

---Assign rectangles to leaves by recursively subdividing `width`×`height`.
---@param layout table|string a sub-layout, or a leaf window name
---@param vertical boolean divide along height (rows) when true, width (cols) otherwise
---@param width integer
---@param height integer
---@param col integer
---@param row integer
---@param sizes table accumulates `{ [name] = { width, height } }`
---@param positions table accumulates `{ [name] = { col, row } }`
local function rec_compute_layout(layout, vertical, width, height, col, row, sizes, positions)
    if type(layout) == "string" then
        -- leaf: content is the rectangle minus the 1-cell border on each side
        sizes[layout] = { width = width - 2, height = height - 2 }
        positions[layout] = { col = col, row = row }
        return
    end

    local total = 0
    for _, l in ipairs(layout) do
        total = total + l[1]
    end

    local consumed = 0
    local dimension = vertical and height or width
    for i, l in ipairs(layout) do
        local size = math.floor(dimension * l[1] / total + 0.5)
        if i == #layout then
            size = dimension - consumed -- last child soaks up the rounding remainder
        end
        if vertical then
            rec_compute_layout(l[2], not vertical, width, size, col, row + consumed, sizes, positions)
        else
            rec_compute_layout(l[2], not vertical, size, height, col + consumed, row, sizes, positions)
        end
        consumed = consumed + size
    end
end

---@param config table
---@param status_rows integer content rows of the "Run" pane (border added here)
---@param layout table the (validated) layout to lay out
---@return table sizes, table positions
local function compute_layout(config, status_rows, layout)
    local STATUS_HEIGHT = status_rows + 2 -- content rows plus top & bottom border
    local sizes, positions = {}, {}
    local vim_width, vim_height = utils.get_ui_size()
    -- Everything is laid out inside the float band: a row is kept clear above the grid
    -- and below it, so the frame never sits against the statusline (see `float_band`).
    local band_row, band_h = utils.float_band()
    local total_width = math.floor(vim_width * config.popup_ui.total_width + 0.5)
    local total_height = math.min(math.floor(vim_height * config.popup_ui.total_height + 0.5), band_h)
    local col0 = math.floor((vim_width - total_width) / 2 + 0.5)
    local row0 = band_row + math.floor((band_h - total_height) / 2 + 0.5)

    -- Lay the whole grid out first, then carve the status strip out of the top of
    -- the Testcases pane only (so it sits above "tc" and not the other panes).
    rec_compute_layout(layout, false, total_width, total_height, col0, row0, sizes, positions)

    local tc_pos, tc_size = positions.tc, sizes.tc
    if tc_pos and tc_size then
        -- st occupies the top STATUS_HEIGHT rows of tc's rectangle (matching width);
        -- tc shrinks and moves down by STATUS_HEIGHT.
        sizes.st = { width = tc_size.width, height = STATUS_HEIGHT - 2 }
        positions.st = { col = tc_pos.col, row = tc_pos.row }
        positions.tc = { col = tc_pos.col, row = tc_pos.row + STATUS_HEIGHT }
        sizes.tc = { width = tc_size.width, height = tc_size.height - STATUS_HEIGHT }
    end
    return sizes, positions
end

---Create the floating windows; populates `windows[name] = { bufnr, winid, title }`.
---@param windows table
---@param config table
---@param _init_winid integer? unused (popup anchors to the editor)
---@param status_rows integer? content rows of the "Run" pane (default 2)
function M.init_ui(windows, config, _init_winid, status_rows)
    local defaults = require("tuna.config").defaults.popup_ui.layout
    local layout = layout_util.resolve(config.popup_ui.layout, "popup_ui.layout", defaults)
    local sizes, positions = compute_layout(config, status_rows or 2, layout)

    for name in pairs(titles) do
        local buf = api.nvim_create_buf(false, true)
        -- Named, tagged, and answering `:w` instead of erroring — the shared surface
        -- contract, so a pane cannot be born missing a piece of it. What a write *does*
        -- here is the runner's business, added on top in `show_ui`.
        require("tuna.surface").adopt(buf, "runner")
        vim.bo[buf].modifiable = false

        -- A pane the layout doesn't place gets a buffer but no window: its content is
        -- still collected (and still openable in the viewer), it just isn't drawn.
        local win
        local s, p = sizes[name], positions[name]
        if s and p then
            win = surface.float(buf, {
                layer = surface.LAYER.grid,
                width = s.width,
                height = s.height,
                -- A bordered float's row/col anchor its whole footprint: the border is
                -- drawn *at* that row/col and the content one cell in. The computed
                -- rectangles already include the border, so they are passed through
                -- unshifted — offsetting by +1 pushed the grid a row down and a column
                -- right, which on a full-height layout means over the statusline.
                col = p.col,
                row = p.row,
                border = config.floating_border,
                border_highlight = config.floating_border_highlight,
                title = titles[name],
            })
            local selector = name == "tc"
            vim.wo[win].number = selector and config.runner_ui.selector_show_nu or config.runner_ui.show_nu
            vim.wo[win].relativenumber = selector and config.runner_ui.selector_show_rnu
                or config.runner_ui.show_rnu
            vim.wo[win].spell = false
            vim.wo[win].cursorline = selector
        end
        windows[name] = { bufnr = buf, winid = win, title = titles[name] }
    end
end

return M
