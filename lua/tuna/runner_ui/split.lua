-- lua/tuna/runner_ui/split.lua
--
-- The "split" interface: the runner UI as real split windows down one edge of
-- the editor, laid out by the same recursive `{ ratio, child }` engine the popup
-- interface uses — but realised with native window splits instead of floats.
--
-- Splits are created with `nvim_open_win(buf, false, { split = dir, win = … })`,
-- the modern API that splits an existing window. We build the outer frame off
-- the editor edge, then recursively subdivide it, fixing each window's size so
-- Neovim's automatic equalisation doesn't undo the ratios.
--
-- Note (see DIFFERENCES.md): `relative_to_editor` splits off the runner's window
-- rather than a true editor-relative anchor; with the usual single-window CP
-- layout these coincide.

local api = vim.api
local utils = require("tuna.utils")

local M = {}

local titles = {
    st = " Run ",
    tc = " Testcases ",
    so = " Output ",
    eo = " Expected Output ",
    si = " Input ",
    se = " Errors ",
}

-- config `position` → native split direction
local dir_map = { left = "left", right = "right", top = "above", bottom = "below" }

---Find the first leaf window name within a (sub-)layout.
---@param layout table
---@return string
local function get_first_window(layout)
    if type(layout[1]) == "table" then
        return get_first_window(layout[1])
    elseif type(layout[2]) == "table" then
        return get_first_window(layout[2])
    end
    return layout[2]
end

---Create the windows; populates `windows[name] = { bufnr, winid, title }`.
---@param windows table
---@param config table
---@param init_winid integer window the runner was launched from
---@param status_rows integer? rows of the "Run" pane (default 2)
function M.init_ui(windows, config, init_winid, status_rows)
    local STATUS_HEIGHT = status_rows or 2
    for name in pairs(titles) do
        local buf = api.nvim_create_buf(false, true)
        vim.bo[buf].filetype = "tuna"
        vim.bo[buf].modifiable = false
        windows[name] = { bufnr = buf, winid = nil, title = titles[name] }
    end

    local vertical = config.split_ui.position == "left" or config.split_ui.position == "right"
    local layout = config.split_ui[(vertical and "vertical" or "horizontal") .. "_layout"]

    -- Recursively split `winid` (which already shows the sub-layout's first leaf)
    -- to realise `layout`, fixing sizes as we go.
    local function create_layout(sublayout, winid, vert)
        local dim = vert and "height" or "width"
        local split_dir = vert and "below" or "right"
        local get_dim = api["nvim_win_get_" .. dim]
        local set_dim = api["nvim_win_set_" .. dim]
        local winfix = "winfix" .. dim

        local total = 0
        for _, l in ipairs(sublayout) do
            total = total + l[1]
        end
        local full = get_dim(winid)
        local part = {}
        for i, l in ipairs(sublayout) do
            part[i] = math.floor(full * l[1] / total + 0.5)
            if i ~= #sublayout then
                part[i] = part[i] - 1 -- account for the separator column/row
            end
        end

        vim.wo[winid][winfix] = false
        local ids = { winid }
        for i = 2, #sublayout do
            local fw = get_first_window(sublayout[i])
            local nw = api.nvim_open_win(windows[fw].bufnr, false, { split = split_dir, win = ids[i - 1] })
            windows[fw].winid = nw
            ids[i] = nw
            vim.wo[nw][winfix] = false
            set_dim(ids[i - 1], part[i - 1]) -- size the previous sibling
            vim.wo[ids[i - 1]][winfix] = true -- and pin it
        end
        vim.wo[ids[#sublayout]][winfix] = true

        for i, l in ipairs(sublayout) do
            if type(l[2]) == "table" then
                create_layout(l[2], ids[i], not vert)
            end
        end
    end

    -- Total frame size.
    local total_width = api.nvim_win_get_width(init_winid)
    local total_height = api.nvim_win_get_height(init_winid)
    if config.split_ui.relative_to_editor then
        total_width, total_height = utils.get_ui_size()
    end
    total_width = math.floor(total_width * config.split_ui.total_width + 0.5)
    total_height = math.floor(total_height * config.split_ui.total_height + 0.5)

    -- Outer frame window off the editor edge.
    local fw = get_first_window(layout)
    local outer = api.nvim_open_win(windows[fw].bufnr, false, {
        split = dir_map[config.split_ui.position] or "right",
        win = init_winid,
    })
    if vertical then
        api.nvim_win_set_width(outer, total_width)
        vim.wo[outer].winfixwidth = true
    else
        api.nvim_win_set_height(outer, total_height)
        vim.wo[outer].winfixheight = true
    end

    -- The outer frame is the grid's first window.
    windows[fw].winid = outer

    -- Disable equalisation while we subdivide, then restore it.
    local old_equalalways = vim.o.equalalways
    vim.o.equalalways = false
    create_layout(layout, outer, vertical)

    -- Carve a status strip above the Testcases pane only (not the whole frame).
    if windows.tc.winid and api.nvim_win_is_valid(windows.tc.winid) then
        local st = api.nvim_open_win(windows.st.bufnr, false, { split = "above", win = windows.tc.winid })
        windows.st.winid = st
        api.nvim_win_set_height(st, STATUS_HEIGHT)
        vim.wo[st].winfixheight = true
    end
    vim.o.equalalways = old_equalalways

    -- Apply selector/detail window options.
    for name, w in pairs(windows) do
        if w.winid and api.nvim_win_is_valid(w.winid) then
            local selector = name == "tc"
            vim.wo[w.winid].number = selector and config.runner_ui.selector_show_nu or config.runner_ui.show_nu
            vim.wo[w.winid].relativenumber = selector and config.runner_ui.selector_show_rnu
                or config.runner_ui.show_rnu
            vim.wo[w.winid].wrap = false
            vim.wo[w.winid].spell = false
            vim.wo[w.winid].cursorline = selector
            vim.wo[w.winid].winfixbuf = true
        end
    end
end

return M
