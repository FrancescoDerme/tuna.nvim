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

local M = {}

local titles = {
    tc = " Testcases ",
    so = " Output ",
    eo = " Expected Output ",
    si = " Input ",
    se = " Errors ",
}

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
---@return table sizes, table positions
local function compute_layout(config)
    local sizes, positions = {}, {}
    local vim_width, vim_height = utils.get_ui_size()
    local total_width = math.floor(vim_width * config.popup_ui.total_width + 0.5)
    local total_height = math.floor(vim_height * config.popup_ui.total_height + 0.5)
    local col0 = math.floor((vim_width - total_width) / 2 + 0.5)
    local row0 = math.floor((vim_height - total_height) / 2 + 0.5)
    rec_compute_layout(config.popup_ui.layout, false, total_width, total_height, col0, row0, sizes, positions)
    return sizes, positions
end

---Create the floating windows; populates `windows[name] = { bufnr, winid, title }`.
---@param windows table
---@param config table
function M.init_ui(windows, config)
    local sizes, positions = compute_layout(config)
    for name in pairs(titles) do
        local buf = api.nvim_create_buf(false, true)
        vim.bo[buf].filetype = "tuna"
        vim.bo[buf].modifiable = false
        local s, p = sizes[name], positions[name]
        local win = api.nvim_open_win(buf, false, {
            relative = "editor",
            width = math.max(1, s.width),
            height = math.max(1, s.height),
            -- A native float's row/col anchor the *content*; the border is drawn
            -- outside it. Offsetting by +1 makes each window's footprint (border
            -- included) line up exactly with its computed rectangle.
            col = p.col + 1,
            row = p.row + 1,
            border = config.floating_border,
            title = titles[name],
            title_pos = "center",
            style = "minimal",
            zindex = 50,
        })
        require("tuna.utils").set_border_highlight(win, config.floating_border_highlight)
        local selector = name == "tc"
        vim.wo[win].number = selector and config.runner_ui.selector_show_nu or config.runner_ui.show_nu
        vim.wo[win].relativenumber = selector and config.runner_ui.selector_show_rnu or config.runner_ui.show_rnu
        vim.wo[win].wrap = false
        vim.wo[win].spell = false
        vim.wo[win].cursorline = selector
        windows[name] = { bufnr = buf, winid = win, title = titles[name] }
    end
end

return M
