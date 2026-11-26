-- lua/tuna/runner_ui/split.lua
--
-- The "split" interface: the runner UI as real split windows down one edge of the editor,
-- over the pane buffers the UI owns, laid out from the same recursive `{ ratio, child }`
-- grid the popup interface uses.
--
-- Splits are created with `nvim_open_win(buf, false, { split = dir, win = … })`,
-- the modern API that splits an existing window. We build the outer frame off
-- the editor edge, then recursively subdivide it, fixing each window's size so
-- Neovim's automatic equalisation doesn't undo the ratios.
--
-- Note: `relative_to_editor` splits off the runner's window
-- rather than a true editor-relative anchor; with the usual single-window CP
-- layout these coincide.

local api = vim.api
local utils = require("tuna.utils")

local M = {}

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

---Place a window for every pane `layout` names over its buffer, splitting off the window the
---runner was launched in. Windows are opened anew each time: a split's size and place are
---fixed by the splits around it. An editor too small to hold them makes Vim refuse a split
---(`E36`): the windows opened so far are closed and the error raised again, for the UI to
---draw the board another way, and `equalalways`, switched off while the frame is divided, is
---put back either way.
---@param windows table<string, { bufnr: integer, winid: integer?, title: string }>
---@param config table
---@param init_winid integer the window the runner was launched from
---@param status_rows integer rows of the "Run" pane
---@param layout table the validated grid
function M.relayout(windows, config, init_winid, status_rows, layout)
    local equalalways = vim.o.equalalways
    local ok, err = pcall(M.place, windows, config, init_winid, status_rows, layout)
    vim.o.equalalways = equalalways
    if not ok then
        for _, w in pairs(windows) do
            if w.winid and api.nvim_win_is_valid(w.winid) then
                pcall(api.nvim_win_close, w.winid, true)
            end
            w.winid = nil
        end
        error(err, 0)
    end
end

---The size the frame is laid out in, and whether its top level divides width, as `place` lays
---it out: beside the editor the frame is a column, its top level a stack of rows, and below or
---above it a row of columns. What a `fit` selector is measured against.
---@param config table
---@param init_winid integer? the window the frame opens beside
---@return { width: integer, height: integer, across: boolean }
function M.frame(config, init_winid)
    local position = config.split_ui.position
    local beside = position == "left" or position == "right"
    local width, height
    if config.split_ui.relative_to_editor or not (init_winid and api.nvim_win_is_valid(init_winid)) then
        width, height = utils.get_ui_size()
    else
        width, height = api.nvim_win_get_width(init_winid), api.nvim_win_get_height(init_winid)
    end
    if beside then
        width = math.floor(width * config.split_ui.width + 0.5)
    else
        height = math.floor(height * config.split_ui.height + 0.5)
    end
    return { width = width, height = height, across = not beside }
end

---@private
---`relayout`'s work, which may raise partway.
function M.place(windows, config, init_winid, status_rows, layout)
    for _, w in pairs(windows) do
        if w.winid and api.nvim_win_is_valid(w.winid) then
            api.nvim_win_close(w.winid, true)
        end
        w.winid = nil
    end
    for _, w in pairs(windows) do
        if not (w.bufnr and api.nvim_buf_is_valid(w.bufnr)) then
            return -- the panes were wiped out from under the UI; there is nothing to split
        end
    end
    local vertical = config.split_ui.position == "left" or config.split_ui.position == "right"

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
    total_width = math.floor(total_width * config.split_ui.width + 0.5)
    total_height = math.floor(total_height * config.split_ui.height + 0.5)

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

    -- No equalisation while the frame is divided: `relayout` puts the option back.
    vim.o.equalalways = false
    create_layout(layout, outer, vertical)

    -- Carve a status strip above the Testcases pane only (not the whole frame).
    if windows.tc.winid and api.nvim_win_is_valid(windows.tc.winid) then
        local st = api.nvim_open_win(windows.st.bufnr, false, { split = "above", win = windows.tc.winid })
        windows.st.winid = st
        api.nvim_win_set_height(st, status_rows)
        vim.wo[st].winfixheight = true
    end

    -- Apply selector/detail window options.
    for name, w in pairs(windows) do
        if w.winid and api.nvim_win_is_valid(w.winid) then
            require("tuna.runner_ui.layout").window_options(w.winid, name, config)
            vim.wo[w.winid].winfixbuf = true
        end
    end
end

return M
