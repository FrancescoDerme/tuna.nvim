-- lua/tuna/widgets.lua
--
-- Interactive floating-window widgets, built on Neovim's native window API
-- instead of nui.nvim (see DIFFERENCES.md). Three widgets are exposed:
--
--   * `input`  — a single-line prompt (used by receive to confirm paths)
--   * `editor` — side-by-side input/output buffers for editing a testcase
--   * `picker` — a list to choose a testcase from
--
-- Each widget is a module-level singleton holding the state of the one instance
-- that can be visible at a time. This mirrors competitest's design and, more
-- importantly, lets `resize_widgets()` rebuild whatever is open after a
-- `VimResized` event by re-invoking the same function with a `nil` first arg.
--
-- A few native APIs used throughout, briefly:
--   * `nvim_create_buf(listed, scratch)` — make a buffer to back a window.
--   * `nvim_open_win(buf, enter, cfg)`   — open a floating window; `cfg.relative
--     = "editor"` positions it with `row`/`col` against the whole UI, and
--     `border`/`title` draw the frame natively (no nui needed).
--   * `vim.keymap.set(mode, lhs, fn, { buffer = b })` — a buffer-local mapping.
--   * `nvim_create_autocmd(event, { buffer = b, callback = fn })` — react to
--     buffer events such as `:w` (`BufWriteCmd`) or the window closing.

local api = vim.api
local utils = require("tuna.utils")
local config = require("tuna.config")

local M = {}

---Open a floating window over the editor.
---@param bufnr integer buffer to display
---@param enter boolean whether to move the cursor into the new window
---@param opts table { width, height, row, col, border, border_highlight, title }
---@return integer winid
local function open_float(bufnr, enter, opts)
    local winid = api.nvim_open_win(bufnr, enter, {
        relative = "editor",
        width = opts.width,
        height = opts.height,
        row = opts.row,
        col = opts.col,
        border = opts.border,
        title = opts.title,
        title_pos = opts.title and "center" or nil,
        style = "minimal",
    })
    require("tuna.utils").set_border_highlight(winid, opts.border_highlight)
    -- Tag this plugin's floats with a "tuna" filetype so users (and other plugins) can target
    -- them. For example add "tuna" to scrollEOF.nvim's "disabled_filetypes" so it doesn't
    -- write the *global* "scrolloff" off a transient float's height
    vim.bo[bufnr].filetype = "tuna"
    -- These floats are short, navigable lists (menu/picker/editor). A large global
    -- `scrolloff` (e.g. 999, to keep normal buffers centred) fights list navigation
    -- by refusing to let the cursor reach the top/bottom rows, so pin it off here —
    -- `scrolloff`/`sidescrolloff` are global-local, so this only affects this window.
    vim.wo[winid].scrolloff = 0
    vim.wo[winid].sidescrolloff = 0
    return winid
end

---Close a window if it is still valid. Closing an already-closed window throws,
---so callers that can race (autocmds, resize) go through this guard.
---@param winid integer?
local function close_win(winid)
    if winid and api.nvim_win_is_valid(winid) then
        api.nvim_win_close(winid, true)
    end
end

---Normalise a mapping spec (a string or list of strings) and bind every key.
---@param spec string|string[]|nil
---@param mode string|string[] keymap mode(s)
---@param bufnr integer buffer the mapping is local to
---@param fn function callback invoked on key press
local function map_keys(spec, mode, bufnr, fn)
    if type(spec) == "string" then
        spec = { spec }
    end
    for _, lhs in ipairs(spec or {}) do
        vim.keymap.set(mode, lhs, fn, { buffer = bufnr, noremap = true, nowait = true })
    end
end

---Move the cursor by `delta` rows in a single-column chooser, wrapping around.
---@param winid integer
---@param count integer number of selectable rows
---@param delta integer -1 (previous) or +1 (next)
local function move_cursor(winid, count, delta)
    if count <= 0 then
        return
    end
    local row = api.nvim_win_get_cursor(winid)[1]
    row = (row - 1 + delta) % count + 1
    api.nvim_win_set_cursor(winid, { row, 0 })
end

---Read a whole buffer as a single newline-joined string.
---@param bufnr integer
---@return string
local function get_buf_text(bufnr)
    return table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

--------------------------------------------------------------------------------
-- Single-line input prompt
--------------------------------------------------------------------------------

---@class tuna.InputWidget
---@field ui_visible boolean
---@field title string
---@field default_text string
---@field border string
---@field on_submit fun(text: string)
---@field on_close fun()?
---@field skip_on_close boolean swallow the next close callback (used by resize)
---@field winid integer?
---@field bufnr integer?
local input = { ui_visible = false }

---Open a single-line input popup.
---@param title string|nil popup title, or `nil` to re-render after a resize
---@param default_text string initial text
---@param border string border style passed to `nvim_open_win`
---@param border_highlight string? highlight group for the border (remaps `FloatBorder`)
---@param callback_only boolean if true, skip the UI and call `on_submit(default_text)` directly
---@param on_submit fun(text: string) called with the entered text on `<CR>`
---@param on_close fun()? called when the prompt is cancelled
function M.input(title, default_text, border, border_highlight, callback_only, on_submit, on_close)
    if title == nil then -- resize: rebuild with the current text
        if not input.ui_visible then
            return
        end
        input.skip_on_close = true
        input.default_text = api.nvim_buf_get_lines(input.bufnr, 0, -1, false)[1] or ""
        close_win(input.winid)
    else
        if callback_only then -- caller wants no prompt: use the default verbatim
            on_submit(default_text)
            return
        end
        input.title = title
        input.default_text = default_text
        input.border = border
        input.border_highlight = border_highlight
        input.on_submit = on_submit
        input.on_close = on_close
    end

    local vim_width, vim_height = utils.get_ui_size()
    local width = math.floor(vim_width * 0.5)

    input.bufnr = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(input.bufnr, 0, -1, false, { input.default_text })

    input.winid = open_float(input.bufnr, true, {
        width = width,
        height = 1,
        row = math.floor((vim_height - 1) / 2),
        col = math.floor((vim_width - width) / 2),
        border = input.border,
        border_highlight = input.border_highlight,
        title = " " .. input.title .. " ",
    })
    input.ui_visible = true

    ---Tear the prompt down. `submit` decides which callback (if any) fires.
    ---@param submit boolean
    local function finish(submit)
        if not input.ui_visible then
            return
        end
        input.ui_visible = false
        if api.nvim_get_mode().mode:sub(1, 1) == "i" then
            vim.cmd("stopinsert")
        end
        local text = api.nvim_buf_get_lines(input.bufnr, 0, -1, false)[1] or ""
        close_win(input.winid)
        if submit then
            input.on_submit(text)
        elseif input.on_close then
            input.on_close()
        end
    end

    map_keys("<CR>", { "n", "i" }, input.bufnr, function()
        finish(true)
    end)
    map_keys({ "<Esc>", "<C-c>" }, { "n", "i" }, input.bufnr, function()
        finish(false)
    end)

    -- A resize closes the window itself; `skip_on_close` keeps that from being
    -- mistaken for a cancellation and firing `on_close`.
    api.nvim_create_autocmd("WinClosed", {
        buffer = input.bufnr,
        once = true,
        callback = function()
            if input.skip_on_close then
                input.skip_on_close = false
                return
            end
            finish(false)
        end,
    })

    -- Start in insert mode at the end of the line for an immediate type-over.
    vim.cmd("startinsert!")
end

--------------------------------------------------------------------------------
-- Testcase editor (input + output, side by side)
--------------------------------------------------------------------------------

---@class tuna.EditorWidget
---@field ui_visible boolean
---@field bufnr integer source buffer the testcase belongs to
---@field tcnum string testcase number, formatted for titles
---@field callback fun(testcase: { input: string, output: string })?
---@field restore_winid integer?
---@field input_buf integer?
---@field input_win integer?
---@field output_buf integer?
---@field output_win integer?
local editor = { ui_visible = false }

---Open the two-pane testcase editor.
---@param bufnr integer|nil source buffer, or `nil` to re-render after a resize
---@param tcnum integer? testcase number (title only)
---@param input_content string? initial input pane content
---@param output_content string? initial output pane content
---@param callback fun(testcase: { input: string, output: string })? receives the edited content on save
---@param restore_winid integer? window to refocus once the editor closes
function M.editor(bufnr, tcnum, input_content, output_content, callback, restore_winid)
    local input_lines, output_lines
    if bufnr == nil then -- resize: keep the current, possibly-unsaved content
        if not editor.ui_visible then
            return
        end
        input_lines = api.nvim_buf_get_lines(editor.input_buf, 0, -1, false)
        output_lines = api.nvim_buf_get_lines(editor.output_buf, 0, -1, false)
        close_win(editor.input_win)
        close_win(editor.output_win)
    else
        editor.bufnr = bufnr
        editor.tcnum = tcnum and (tostring(tcnum) .. " ") or ""
        editor.callback = callback
        editor.restore_winid = restore_winid
        input_lines = vim.split(input_content or "", "\n", { plain = true })
        output_lines = vim.split(output_content or "", "\n", { plain = true })
    end

    local cfg = config.get_buffer_config(editor.bufnr)
    local ui = cfg.editor_ui
    local vim_width, vim_height = utils.get_ui_size()
    local width = math.floor(ui.width * vim_width)
    local height = math.floor(ui.height * vim_height)
    local row = math.floor((vim_height - height) / 2)

    ---Create one editable pane.
    ---@param title string
    ---@param col integer
    ---@param lines string[]
    ---@return integer bufnr, integer winid
    local function make_pane(title, col, lines)
        local b = api.nvim_create_buf(false, true)
        -- `acwrite` makes `:w` route through our BufWriteCmd autocmd instead of
        -- trying (and failing) to write the scratch buffer to disk. The buffer
        -- still needs a name, or `:w` aborts with E32 before BufWriteCmd fires.
        vim.bo[b].buftype = "acwrite"
        vim.bo[b].filetype = "tuna"
        api.nvim_buf_set_name(b, "tuna://testcase/" .. title:lower() .. "/" .. b)
        api.nvim_buf_set_lines(b, 0, -1, false, lines)
        vim.bo[b].modified = false
        local w = open_float(b, false, {
            width = width,
            height = height,
            row = row,
            col = col,
            border = cfg.floating_border,
            border_highlight = cfg.floating_border_highlight,
            title = " " .. title .. " " .. editor.tcnum,
        })
        vim.wo[w].number = ui.show_nu
        vim.wo[w].relativenumber = ui.show_rnu
        return b, w
    end

    -- Place the two panes symmetrically about the editor's vertical centre.
    editor.input_buf, editor.input_win = make_pane("Input", math.floor(vim_width / 2) - width - 1, input_lines)
    editor.output_buf, editor.output_win = make_pane("Output", math.floor(vim_width / 2) + 1, output_lines)
    api.nvim_set_current_win(editor.input_win)
    editor.ui_visible = true

    ---Send the edited content back through the callback and clear modified flags.
    local function save()
        if editor.callback then
            editor.callback({
                input = get_buf_text(editor.input_buf),
                output = get_buf_text(editor.output_buf),
            })
        end
        vim.bo[editor.input_buf].modified = false
        vim.bo[editor.output_buf].modified = false
    end

    ---Close both panes and restore focus. Guarded so the WinClosed autocmd that
    ---fires while we close the first pane doesn't recurse.
    local function close()
        if not editor.ui_visible then
            return
        end
        editor.ui_visible = false
        if api.nvim_get_mode().mode:sub(1, 1) == "i" then
            vim.cmd("stopinsert")
        end
        close_win(editor.input_win)
        close_win(editor.output_win)
        if editor.restore_winid and api.nvim_win_is_valid(editor.restore_winid) then
            api.nvim_set_current_win(editor.restore_winid)
        end
    end

    ---Bind the configured mappings on both panes for one mode.
    ---@param maps table switch_window / save_and_close / cancel specs
    ---@param mode string "n" or "i"
    local function bind(maps, mode)
        map_keys(maps.switch_window, mode, editor.input_buf, function()
            api.nvim_set_current_win(editor.output_win)
        end)
        map_keys(maps.switch_window, mode, editor.output_buf, function()
            api.nvim_set_current_win(editor.input_win)
        end)
        for _, b in ipairs({ editor.input_buf, editor.output_buf }) do
            map_keys(maps.save_and_close, mode, b, function()
                save()
                close()
            end)
            map_keys(maps.cancel, mode, b, close)
        end
    end

    bind(ui.normal_mode_mappings, "n")
    bind(ui.insert_mode_mappings, "i")

    for _, b in ipairs({ editor.input_buf, editor.output_buf }) do
        -- `:w` / `:wq` save the testcase; closing either window tears down both.
        api.nvim_create_autocmd("BufWriteCmd", { buffer = b, callback = save })
        api.nvim_create_autocmd("WinClosed", { buffer = b, callback = close })
    end
end

--------------------------------------------------------------------------------
-- Testcase picker
--------------------------------------------------------------------------------

---@class tuna.PickerWidget
---@field ui_visible boolean
---@field bufnr integer source buffer
---@field tcnums integer[] testcase numbers, in display order
---@field title string
---@field callback fun(tcnum: integer)?
---@field restore_winid integer?
---@field winid integer?
---@field menu_buf integer?
local picker = { ui_visible = false }

---Open a list to pick a testcase from.
---@param bufnr integer|nil source buffer, or `nil` to re-render after a resize
---@param tctbl table<integer, table> testcase table (`{ [n] = { input, output } }`)
---@param title string? floating window title
---@param callback fun(tcnum: integer)? receives the chosen testcase number
---@param restore_winid integer? window to refocus once the picker closes
function M.picker(bufnr, tctbl, title, callback, restore_winid)
    if bufnr == nil then -- resize
        if not picker.ui_visible then
            return
        end
        close_win(picker.winid)
    else
        if next(tctbl) == nil then
            utils.notify("there's no testcase to pick from.", "WARN")
            return
        end
        picker.bufnr = bufnr
        picker.tcnums = vim.tbl_keys(tctbl)
        table.sort(picker.tcnums)
        picker.title = title and (" " .. title .. " ") or " Testcase Picker "
        picker.callback = callback
        picker.restore_winid = restore_winid
    end

    local cfg = config.get_buffer_config(picker.bufnr)
    local vim_width, vim_height = utils.get_ui_size()

    local lines = {}
    for _, tcnum in ipairs(picker.tcnums) do
        table.insert(lines, "Testcase " .. tcnum)
    end

    picker.menu_buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(picker.menu_buf, 0, -1, false, lines)
    vim.bo[picker.menu_buf].modifiable = false
    vim.bo[picker.menu_buf].filetype = "tuna"

    picker.winid = open_float(picker.menu_buf, true, {
        width = math.floor(vim_width * cfg.picker_ui.width),
        height = math.floor(vim_height * cfg.picker_ui.height),
        row = math.floor((vim_height - math.floor(vim_height * cfg.picker_ui.height)) / 2),
        col = math.floor((vim_width - math.floor(vim_width * cfg.picker_ui.width)) / 2),
        border = cfg.floating_border,
        border_highlight = cfg.floating_border_highlight,
        title = picker.title,
    })
    -- Highlight the active row; cursor movement (j/k, arrows) is native.
    vim.wo[picker.winid].cursorline = true
    picker.ui_visible = true

    ---@param tcnum integer? chosen testcase, or nil if cancelled
    local function close(tcnum)
        if not picker.ui_visible then
            return
        end
        picker.ui_visible = false
        close_win(picker.winid)
        if picker.restore_winid and api.nvim_win_is_valid(picker.restore_winid) then
            api.nvim_set_current_win(picker.restore_winid)
        end
        if tcnum and picker.callback then
            picker.callback(tcnum)
        end
    end

    map_keys(cfg.picker_ui.mappings.focus_next, "n", picker.menu_buf, function()
        move_cursor(picker.winid, #picker.tcnums, 1)
    end)
    map_keys(cfg.picker_ui.mappings.focus_prev, "n", picker.menu_buf, function()
        move_cursor(picker.winid, #picker.tcnums, -1)
    end)
    map_keys(cfg.picker_ui.mappings.submit, "n", picker.menu_buf, function()
        local row = api.nvim_win_get_cursor(picker.winid)[1]
        close(picker.tcnums[row])
    end)
    map_keys(cfg.picker_ui.mappings.close, "n", picker.menu_buf, function()
        close(nil)
    end)
    api.nvim_create_autocmd("WinClosed", {
        buffer = picker.menu_buf,
        callback = function()
            close(nil)
        end,
    })
end

--------------------------------------------------------------------------------

---@class tuna.MenuWidget
---@field ui_visible boolean
---@field items string[]
---@field title string
---@field on_choice fun(idx: integer)?
---@field restore_winid integer?
---@field winid integer?
---@field menu_buf integer?
local menu = { ui_visible = false }

---Open a generic single-choice menu (used by the mode switcher). `on_choice`
---receives the 1-based index of the picked item.
---@param items string[]? menu labels, or `nil` to re-render after a resize
---@param title string? floating window title
---@param on_choice fun(idx: integer)? called with the chosen index
---@param restore_winid integer? window to refocus once the menu closes
function M.menu(items, title, on_choice, restore_winid)
    if items == nil then -- resize
        if not menu.ui_visible then
            return
        end
        close_win(menu.winid)
    else
        if #items == 0 then
            return
        end
        menu.items = items
        menu.title = title and (" " .. title .. " ") or " Tuna "
        menu.on_choice = on_choice
        menu.restore_winid = restore_winid
    end

    local cfg = config.get_buffer_config(api.nvim_get_current_buf())
    local vim_width, vim_height = utils.get_ui_size()
    local width = #menu.title
    for _, l in ipairs(menu.items) do
        width = math.max(width, #l)
    end
    width = math.min(math.max(width + 4, 24), vim_width - 4)
    local height = math.min(#menu.items, vim_height - 4)

    menu.menu_buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(menu.menu_buf, 0, -1, false, menu.items)
    vim.bo[menu.menu_buf].modifiable = false
    vim.bo[menu.menu_buf].filetype = "tuna"

    menu.winid = open_float(menu.menu_buf, true, {
        width = width,
        height = height,
        row = math.floor((vim_height - height) / 2),
        col = math.floor((vim_width - width) / 2),
        border = cfg.floating_border,
        border_highlight = cfg.floating_border_highlight,
        title = menu.title,
    })
    vim.wo[menu.winid].cursorline = true
    menu.ui_visible = true

    ---@param idx integer? chosen index, or nil if cancelled
    local function close(idx)
        if not menu.ui_visible then
            return
        end
        menu.ui_visible = false
        close_win(menu.winid)
        if menu.restore_winid and api.nvim_win_is_valid(menu.restore_winid) then
            api.nvim_set_current_win(menu.restore_winid)
        end
        if idx and menu.on_choice then
            menu.on_choice(idx)
        end
    end

    map_keys(cfg.picker_ui.mappings.focus_next, "n", menu.menu_buf, function()
        move_cursor(menu.winid, #menu.items, 1)
    end)
    map_keys(cfg.picker_ui.mappings.focus_prev, "n", menu.menu_buf, function()
        move_cursor(menu.winid, #menu.items, -1)
    end)
    map_keys(cfg.picker_ui.mappings.submit, "n", menu.menu_buf, function()
        close(api.nvim_win_get_cursor(menu.winid)[1])
    end)
    map_keys(cfg.picker_ui.mappings.close, "n", menu.menu_buf, function()
        close(nil)
    end)
    api.nvim_create_autocmd("WinClosed", {
        buffer = menu.menu_buf,
        callback = function()
            close(nil)
        end,
    })
end

--------------------------------------------------------------------------------

---Rebuild whichever widgets are currently visible. Called from the `VimResized`
---autocmd so floats stay centred and proportional after the UI changes size.
function M.resize_widgets()
    M.editor(nil)
    M.picker(nil)
    M.input(nil)
    M.menu(nil)
end

return M
