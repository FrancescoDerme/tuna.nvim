-- lua/tuna/runner_ui/popup.lua
--
-- The "popup" interface: the runner UI as a grid of floating windows over the pane buffers
-- the UI owns, laid out by a recursive layout engine.
--
-- A layout is a list of `{ ratio, child }` pairs, where `child` is either a
-- window name (a leaf: "tc"/"so"/"eo"/"si"/"se") or a nested layout. Levels
-- alternate direction: the top level splits horizontally (columns), the next
-- vertically (rows), and so on. `rec_compute_layout` walks that tree and assigns
-- each leaf a rectangle; we then open one bordered float per leaf.

local api = vim.api
local utils = require("tuna.utils")
local surface = require("tuna.surface")

local M = {}

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

---Put a pane where the layout says, or take its window away when the layout leaves it out.
---The buffer stays either way: its content is still collected and still reachable in the
---viewer, drawn or not.
---@param w table the `windows` entry
---@param name string pane name
---@param config table
---@param s table? the rectangle's size, nil when the layout omits the pane
---@param p table? its position
local function draw_pane(w, name, config, s, p)
    if not (s and p) then
        if w.winid and api.nvim_win_is_valid(w.winid) then
            api.nvim_win_close(w.winid, true)
        end
        w.winid = nil
        return
    end
    if not api.nvim_buf_is_valid(w.bufnr) then
        -- Nothing to draw: the buffer was wiped out from under the UI (`:%bwipeout` is a
        -- thing people type), and a window cannot be opened onto one that is gone.
        w.winid = nil
        return
    end
    if w.winid and api.nvim_win_is_valid(w.winid) then
        -- Moved rather than reopened: a window that stays keeps its view and its options. The
        -- title is set again, since the row on screen can rename a pane.
        api.nvim_win_set_config(w.winid, {
            relative = "editor",
            width = math.max(1, s.width),
            height = math.max(1, s.height),
            col = p.col,
            row = p.row,
        })
        pcall(api.nvim_win_set_config, w.winid, { title = w.title, title_pos = "center" })
        return
    end
    w.winid = surface.float(w.bufnr, {
        layer = surface.LAYER.grid,
        width = s.width,
        height = s.height,
        -- A bordered float's row/col anchor its whole footprint, border included, which is
        -- what the computed rectangles are, so they are passed through unshifted.
        col = p.col,
        row = p.row,
        border = config.floating_border,
        border_highlight = config.floating_border_highlight,
        title = w.title,
    })
    local selector = name == "tc"
    local ui = config.runner_ui
    -- Spelled out rather than with `and`/`or`: a selector option set to `false` would
    -- fall through to the detail panes' value.
    if selector then
        vim.wo[w.winid].number, vim.wo[w.winid].relativenumber = ui.selector_show_nu, ui.selector_show_rnu
    else
        vim.wo[w.winid].number, vim.wo[w.winid].relativenumber = ui.show_nu, ui.show_rnu
    end
    vim.wo[w.winid].spell = false
    vim.wo[w.winid].cursorline = selector
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

---Place a window for every pane `layout` names over its buffer, and none for the others.
---Windows already open are moved rather than reopened, keeping their view.
---@param windows table<string, { bufnr: integer, winid: integer?, title: string }>
---@param config table
---@param _ integer? the window the runner was launched from (unused: the grid is anchored to the editor)
---@param status_rows integer content rows of the "Run" pane
---@param layout table the validated grid
function M.relayout(windows, config, _, status_rows, layout)
    local sizes, positions = compute_layout(config, status_rows, layout)
    for name, w in pairs(windows) do
        draw_pane(w, name, config, sizes[name], positions[name])
    end
end

-- The pure geometry, for the test suite.
M._test = { compute_layout = compute_layout }

return M
