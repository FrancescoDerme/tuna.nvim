-- lua/tuna/widgets.lua
--
-- Interactive floating-window widgets, built on Neovim's native window API
-- instead of nui.nvim (see DIFFERENCES.md). The widgets exposed:
--
--   * `input`  — a single-line prompt (used by download to confirm paths)
--   * `editor` — side-by-side input/output buffers for editing a testcase
--   * `picker` — a list to choose a testcase from
--   * `menu`   — a single-choice chooser (dashboard, confirmations; optional
--                read-only preview pane beneath it)
--   * `form`   — several single-choice lists visible at once (clean's directory,
--                depth and match-threshold choosers)
--
-- Each widget is a module-level singleton holding the state of the one instance
-- that can be visible at a time. This mirrors competitest's design and, more
-- importantly, lets `resize_widgets()` rebuild whatever is open after a
-- `VimResized` event by re-invoking the same function with a `nil` first arg.
--
-- Every widget is dismissed through `map_cancel`, which is the single place cancel
-- keys are bound (see the dismissal contract there): the same keypress means the same
-- thing whether the widget in front of you is a download path prompt, a testcase
-- editor or a clean confirmation.
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
local surface = require("tuna.surface")
local config = require("tuna.config")

local M = {}

---Open a floating window over the editor.
---@param bufnr integer buffer to display
---@param enter boolean whether to move the cursor into the new window
---@param opts table { width, height, row, col, border, border_highlight, title }
---@return integer winid
local function open_float(bufnr, enter, opts)
    -- A widget is a dialog: always the thing the user is being asked to act on, so it is
    -- drawn above every layer the runner UI uses — including 50, Neovim's default for a
    -- float and the grid's own, where the two would fight and a pane would appear to
    -- vanish behind the dialog.
    local winid = surface.float(bufnr, {
        layer = surface.LAYER.dialog,
        width = opts.width,
        height = opts.height,
        row = opts.row,
        col = opts.col,
        border = opts.border,
        border_highlight = opts.border_highlight,
        title = opts.title,
        enter = enter,
        -- A scrollable *content* pane (clean's file preview, the library's snippet
        -- preview) is read like a normal buffer rather than navigated as a list, so it
        -- keeps the user's own scrolloff.
        keep_scrolloff = opts.keep_scrolloff,
    })
    -- Everything Vim has to be told about a scratch surface — the name, the `tuna`
    -- filetype other plugins target, and a `:w` that answers instead of erroring — comes
    -- from one place, so a widget added later cannot be born missing a piece of it. A
    -- buffer the user *types* into keeps `modified` clear as they go (`keep_clean`):
    -- there is nothing to save in a prompt, and an `acwrite` buffer left modified is one
    -- Vim refuses to quit past.
    surface.adopt(bufnr, opts.kind or "widget", { keep_clean = vim.bo[bufnr].modifiable })
    -- A list is read by moving through it, never edited, so the keys that would try are
    -- made inert here rather than left to raise `E21` a keystroke later. Run before the
    -- widget binds its own keys, which simply take precedence.
    if not vim.bo[bufnr].modifiable then
        surface.read_only(bufnr)
    end
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

---A mapping spec is written as a single key or a list of them; this is the one place
---that difference is smoothed out.
---@param spec string|string[]|nil
---@return string[]
local function to_list(spec)
    if type(spec) == "string" then
        return { spec }
    end
    return spec or {}
end

---Bind every key of a mapping spec.
---@param spec string|string[]|nil
---@param mode string|string[] keymap mode(s)
---@param bufnr integer buffer the mapping is local to
---@param fn function callback invoked on key press
local function map_keys(spec, mode, bufnr, fn)
    for _, lhs in ipairs(to_list(spec)) do
        vim.keymap.set(mode, lhs, fn, { buffer = bufnr, noremap = true, nowait = true })
    end
end

--------------------------------------------------------------------------------
-- Dismissal contract
--------------------------------------------------------------------------------

-- Every widget in this file is cancelled the same way — prompt, picker, menu, chooser
-- form and testcase editor alike — so the habit learned on one carries to all of them:
--
--   * `<Esc>` **from normal mode cancels.** No widget is exempt: an editor holding a
--     half-written testcase closes on the same key as a menu.
--   * By default `<Esc>` **while inserting only leaves insert mode**, which is what the
--     key means everywhere else in vim. Cancelling something being typed into therefore
--     takes a second, deliberate press — the reason a stray Esc in a download path
--     prompt no longer throws away a whole download.
--   * Both lists are `config.cancel_keys`, so a user who prefers Esc to cancel straight
--     from insert mode says so once (`cancel_keys.insert = { "<Esc>" }`) and every
--     widget follows. Nothing is filtered out behind their back; the two-press default
--     is a default, not a rule.
--   * A widget adds keys of its own on top (`q`/`Q` on the choosers, `<C-q>` while
--     editing a testcase) — its own list extends the shared one rather than replacing
--     it, which is what keeps the widgets consistent with each other.
--
-- Worth knowing when configuring: `<C-c>` cancels from normal mode, but listing it
-- under `insert` does nothing — Neovim handles `i_CTRL-C` itself and never runs a
-- mapping for it (verified). `<Esc>` is the key to use there.
--
-- `map_cancel` is the only place cancel keys are bound, so a widget added later cannot
-- quietly grow its own dismissal behaviour.

---Bind a widget's cancel keys: the shared `config.cancel_keys` plus whatever the
---widget itself contributes, per mode.
---@param bufs integer|integer[] buffer(s) the widget is made of
---@param cancel fun() the widget's teardown
---@param opts { normal: string|string[]|nil, insert: string|string[]|nil }? the
---  widget's own keys, added to the shared ones
local function map_cancel(bufs, cancel, opts)
    opts = opts or {}
    if type(bufs) == "number" then
        bufs = { bufs }
    end
    local shared = (config.current_setup or config.defaults or {}).cancel_keys or {}
    local normal = vim.list_extend(vim.list_extend({}, to_list(shared.normal)), to_list(opts.normal))
    local insert = vim.list_extend(vim.list_extend({}, to_list(shared.insert)), to_list(opts.insert))
    for _, b in ipairs(bufs) do
        map_keys(normal, "n", b, cancel)
        map_keys(insert, "i", b, cancel)
    end
end

--------------------------------------------------------------------------------
-- Content panes
--------------------------------------------------------------------------------

-- How much of the editor a chooser's list may take when it comes with a preview, and
-- the fewest rows it keeps whatever happens. Beyond that the list scrolls, so a long
-- one (a snippet library of thirty files) doesn't squeeze the pane it exists to feed.
local MENU_LIST_SHARE, MENU_MIN_ROWS = 0.3, 5

-- Rows between one stacked pane's content and the next one's: its bottom border and
-- the next one's top border, and nothing else. Panes therefore *touch*, the way the
-- runner UI tiles its grid — a gap would leave a stripe of the buffer underneath
-- showing between two floats, and a line of code cutting through a dialog is both ugly
-- and hard to read past.
local PANE_STEP = 2

---Put content into a read-only preview pane: the lines, the syntax colouring and the
---border title. The single place that knows how such a pane is filled, so a fixed
---preview and one that follows the cursor behave identically (the cursor-following
---form used to lose the colouring, because only its per-row table was consulted).
---
---Colouring goes through 'syntax', never 'filetype': a throwaway preview must not fire
---FileType autocmds, which would attach an LSP and run ftplugins on it.
---@param bufnr integer preview buffer
---@param winid integer? preview window (for the title)
---@param data { title: string?, lines: string[]?, filetype: string? } what to show
---@param defaults { title: string?, filetype: string? }? fallbacks for what `data` omits
local function fill_preview(bufnr, winid, data, defaults)
    defaults = defaults or {}
    if not api.nvim_buf_is_valid(bufnr) then
        return
    end
    vim.bo[bufnr].modifiable = true
    api.nvim_buf_set_lines(bufnr, 0, -1, false, data.lines or {})
    vim.bo[bufnr].modifiable = false

    local ft = data.filetype or defaults.filetype
    if ft then
        pcall(function()
            vim.bo[bufnr].syntax = ft
        end)
    end

    local title = data.title or defaults.title
    if winid and api.nvim_win_is_valid(winid) then
        api.nvim_win_set_config(winid, { title = title and (" " .. title .. " ") or nil })
        pcall(api.nvim_win_set_cursor, winid, { 1, 0 }) -- new content, read from the top
    end
end

---Move the cursor by `delta` rows in a single-column chooser, wrapping around.
---@param winid integer
---@param count integer number of selectable rows
---@param delta integer -1 (previous) or +1 (next)
local function move_cursor(winid, count, delta)
    -- Clamp to what the buffer actually holds: a widget whose rows are being repaired
    -- (the form's edit guard) can briefly hold fewer lines than it has choices.
    count = math.min(count, api.nvim_buf_line_count(api.nvim_win_get_buf(winid)))
    if count <= 0 then
        return
    end
    local row = api.nvim_win_get_cursor(winid)[1]
    row = (row - 1 + delta) % count + 1
    pcall(api.nvim_win_set_cursor, winid, { row, 0 })
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

    local vim_width = utils.get_ui_size()
    local band_row, band_h = utils.float_band()
    local width = math.floor(vim_width * 0.5)

    input.bufnr = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(input.bufnr, 0, -1, false, { input.default_text })

    input.winid = open_float(input.bufnr, true, {
        width = width,
        height = 1,
        row = band_row + math.max(0, math.floor((band_h - 3) / 2)), -- one content row plus its border
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
    map_cancel(input.bufnr, function()
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
    local band_row, band_h = utils.float_band()
    local width = math.floor(ui.width * vim_width)
    local height = math.max(1, math.min(math.floor(ui.height * vim_height), band_h - 2))
    -- Centred on the *footprint*: a bordered float's `row` is where its border is
    -- drawn, so the two border rows count towards the height being centred (see the
    -- menu). Clamped, so a tall `editor_ui.height` can't push the frame off-screen.
    local row = band_row + math.max(0, math.floor((band_h - height - 2) / 2))

    ---Create one editable pane.
    ---@param title string
    ---@param col integer
    ---@param lines string[]
    ---@return integer bufnr, integer winid
    local function make_pane(title, col, lines)
        local b = api.nvim_create_buf(false, true)
        -- `acwrite` makes `:w` route through our BufWriteCmd autocmd instead of
        -- trying (and failing) to write the scratch buffer to disk. (The name `:w`
        -- also needs, or it aborts with E32 before BufWriteCmd fires, is given by
        -- `open_float` below — see `utils.name_float_buffer`.)
        vim.bo[b].buftype = "acwrite"
        vim.bo[b].filetype = "tuna"
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
        end
    end

    bind(ui.normal_mode_mappings, "n")
    bind(ui.insert_mode_mappings, "i")
    -- Cancelling goes through the shared contract, on top of the editor's own keys
    -- (`q`/`Q`, and `<C-q>` while inserting). Discarding a testcase being written is
    -- the costliest cancellation in the plugin, which is exactly what the two-press
    -- default protects: the first `<Esc>` only leaves insert mode.
    map_cancel({ editor.input_buf, editor.output_buf }, close, {
        normal = ui.normal_mode_mappings.cancel,
        insert = ui.insert_mode_mappings.cancel,
    })

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

    local band_row, band_h = utils.float_band()
    local picker_h = math.max(1, math.min(math.floor(vim_height * cfg.picker_ui.height), band_h - 2))
    picker.winid = open_float(picker.menu_buf, true, {
        width = math.floor(vim_width * cfg.picker_ui.width),
        height = picker_h,
        row = band_row + math.max(0, math.floor((band_h - picker_h - 2) / 2)),
        col = math.floor((vim_width - math.floor(vim_width * cfg.picker_ui.width)) / 2),
        border = cfg.floating_border,
        border_highlight = cfg.floating_border_highlight,
        title = picker.title,
    })
    -- Highlight the active row; cursor movement (j/k, arrows) is native. setlocal, so
    -- it doesn't leak cursorline's global default off this float (see the menu note).
    api.nvim_set_option_value("cursorline", true, { scope = "local", win = picker.winid })
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
    map_cancel(picker.menu_buf, function()
        close(nil)
    end, { normal = cfg.picker_ui.mappings.close })
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
---@field on_close fun()?
---@field skip_close boolean swallow the next WinClosed (used by resize)
---@field restore_winid integer?
---@field winid integer?
---@field menu_buf integer?
---@field preview { title: string?, lines: string[], filetype: string?, width: integer? }?
---@field preview_win integer?
---@field preview_buf integer?
---@field notice { title: string?, lines: string[] }?
---@field notice_win integer?
---@field notice_buf integer?
local menu = { ui_visible = false }

---Open a generic single-choice menu (drives the `:Tuna` dashboard). `on_choice`
---receives the 1-based index of the picked item. An optional `preview` renders a
---read-only pane *under* the menu (used by `:Tuna clean` to show the file about to
---be deleted): scroll it with `<C-d>`/`<C-u>`, or step into it with the pane-switch
---keys (`switch_window_keys`) and back. Pass `preview.width` to pin the whole float
---to a fixed width so a sequence of menus doesn't jump size between items.
---@param items string[]? menu labels, or `nil` to re-render after a resize
---@param title string? floating window title
---@param on_choice fun(idx: integer)? called with the chosen index
---@param restore_winid integer? window to refocus once the menu closes
---@param on_close fun()? called when the menu is dismissed without a choice (Esc /
---  window closed) — so a caller that must always continue (e.g. download's batch
---  processor) isn't left hanging on a cancellation
---@param preview { title: string?, lines: string[]?, filetype: string?, width: integer?, height: integer?, content: (fun(idx: integer): { title: string?, lines: string[], filetype: string? })? }?
---  content pane; with `content` it follows the highlighted row (pin `width`/`height`)
---@param notice { title: string?, lines: string[] }? a read-only pane *above* the menu,
---  for something the user needs to know before choosing (e.g. that a scan was partial)
function M.menu(items, title, on_choice, restore_winid, on_close, preview, notice)
    if items == nil then -- resize
        if not menu.ui_visible then
            return
        end
        -- A resize closes and rebuilds the windows; keep that self-inflicted
        -- WinClosed from being mistaken for a user cancellation (firing on_close).
        menu.skip_close = true
        close_win(menu.winid)
        close_win(menu.preview_win)
        close_win(menu.notice_win)
    else
        if #items == 0 then
            return
        end
        menu.items = items
        menu.title = title and (" " .. title .. " ") or " Tuna "
        menu.on_choice = on_choice
        menu.on_close = on_close
        menu.restore_winid = restore_winid
        menu.preview = preview
        menu.notice = notice
    end

    local cfg = config.get_buffer_config(api.nvim_get_current_buf())
    local vim_width = utils.get_ui_size()
    local pv = menu.preview

    -- A `preview.content(idx)` callback makes the pane follow the highlighted row
    -- instead of showing one fixed thing: what a chooser of *things to look at* needs
    -- (the snippet library shows the code under the cursor before it is inserted).
    -- Such a preview should pin `width`/`height`, or the float resizes on every j/k.
    local function preview_data(idx)
        if pv and pv.content then
            local ok, data = pcall(pv.content, idx)
            return (ok and type(data) == "table") and data or { lines = {} }
        end
        return pv
    end
    local shown = preview_data(1)
    -- The user's cursorline, captured before opening any of our floats, so the
    -- preview (read like a normal buffer) can honour it.
    local user_cursorline = api.nvim_get_option_value("cursorline", { scope = "global" })

    local width
    if pv and pv.width then
        -- A caller-fixed width keeps a *sequence* of previews the same size — e.g.
        -- `:Tuna clean` steps through files whose names and contents vary in length,
        -- and a float that resized on every step would be distracting.
        width = math.min(math.max(pv.width, 24), vim_width - 4)
    else
        width = #menu.title
        for _, l in ipairs(menu.items) do
            width = math.max(width, #l)
        end
        if pv then
            width = math.max(width, #(shown.title or "") + 4)
            for _, l in ipairs(shown.lines) do
                width = math.max(width, #l)
            end
        end
        width = math.min(math.max(width + 4, 24), vim_width - 4)
    end
    local col = math.floor((vim_width - width) / 2)

    -- Lay out the notice (if any) above the menu and the preview below it, centring
    -- the whole group vertically. Each pane costs 2 rows of border and the panes touch
    -- (see `PANE_STEP`), so the group reads as one panel.
    local nt = menu.notice
    local menu_row, menu_h, pv_h, pv_row, nt_h, nt_row

    -- Heights are handed out in order of who cannot give way: the notice (what the user
    -- must read), then the list (what they act on), then the preview (what fills the
    -- rest) — each bounded by what the previous ones left, so the stack always fits,
    -- down to a 12-row editor.
    local band_row, band_h = utils.float_band()
    local budget = band_h
    if nt then
        -- The notice wraps, so its height is counted in *screen* rows, not lines.
        nt_h = 0
        for _, l in ipairs(nt.lines) do
            nt_h = nt_h + math.max(1, math.ceil(#l / math.max(1, width)))
        end
        nt_h = math.max(1, math.min(nt_h, 6, budget - 6)) -- never at the cost of the list
        budget = budget - (nt_h + PANE_STEP)
    end

    -- With a preview, a long list is capped and scrolls instead of squeezing the pane
    -- it exists to feed: a 30-file library would otherwise leave two lines of code
    -- visible. Without one, the list is as tall as it needs to be.
    local pv_min = pv and (1 + PANE_STEP) or 0
    local list_max = pv and math.max(MENU_MIN_ROWS, math.floor(band_h * MENU_LIST_SHARE)) or (band_h - 2)
    menu_h = math.max(1, math.min(#menu.items, list_max, budget - 2 - pv_min))

    if nt or pv then
        local used = menu_h + 2
        if pv then
            -- Fixed `height` for a pane that must not resize between items; a
            -- cursor-following one with no height given takes all the room left, since
            -- its content changes with every keypress and a jumping float is worse than
            -- an over-tall one. Otherwise the pane is as tall as its content.
            local avail = math.max(1, budget - used - PANE_STEP)
            pv_h = math.max(1, math.min(pv.height or (pv.content and avail) or #shown.lines, avail))
        end
        local total = (nt and (nt_h + PANE_STEP) or 0) + used + (pv and (pv_h + PANE_STEP) or 0)
        -- A bordered float's `row` is the top of its *footprint* — the border is drawn
        -- there, content one row below — so a stack of `total` rows starting at `first`
        -- ends exactly at `first + total - 1`, and no offset is wanted. (Adding one
        -- pushed the bottom border onto the statusline.)
        local first = band_row + math.max(0, math.floor((band_h - total) / 2))
        nt_row = nt and first or nil
        menu_row = first + (nt and (nt_h + PANE_STEP) or 0)
        pv_row = pv and (menu_row + menu_h + PANE_STEP) or nil
    else
        menu_row = band_row + math.max(0, math.floor((band_h - menu_h - 2) / 2))
    end

    if nt then
        -- A read-only pane for something the user must know before choosing. It is
        -- deliberately outside the focus cycle: it carries no action, and putting it
        -- in the way of the menu would slow every confirmation down.
        menu.notice_buf = api.nvim_create_buf(false, true)
        api.nvim_buf_set_lines(menu.notice_buf, 0, -1, false, nt.lines)
        vim.bo[menu.notice_buf].modifiable = false
        menu.notice_win = open_float(menu.notice_buf, false, {
            width = width,
            height = nt_h,
            row = nt_row,
            col = col,
            border = cfg.floating_border,
            border_highlight = cfg.floating_border_highlight,
            title = nt.title and (" " .. nt.title .. " ") or nil,
        })
        vim.wo[menu.notice_win].wrap = true
        api.nvim_set_option_value("cursorline", false, { scope = "local", win = menu.notice_win })
    else
        menu.notice_win, menu.notice_buf = nil, nil
    end

    menu.menu_buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(menu.menu_buf, 0, -1, false, menu.items)
    vim.bo[menu.menu_buf].modifiable = false
    vim.bo[menu.menu_buf].filetype = "tuna"

    menu.winid = open_float(menu.menu_buf, true, {
        width = width,
        height = menu_h,
        row = menu_row,
        col = col,
        border = cfg.floating_border,
        border_highlight = cfg.floating_border_highlight,
        title = menu.title,
        -- A list that fits is pinned at scrolloff 0, so its first and last rows stay
        -- reachable; one that has to scroll is read like any other buffer, so the
        -- user's own scrolloff applies.
        keep_scrolloff = menu_h < #menu.items,
    })
    -- setlocal (scope="local"), not `vim.wo[...] =`: on the *current* window the
    -- latter also writes cursorline's global default, leaking a UI choice into the
    -- user's editor. scope="local" keeps it to this float.
    api.nvim_set_option_value("cursorline", true, { scope = "local", win = menu.winid })

    if pv then
        menu.preview_buf = api.nvim_create_buf(false, true)
        menu.preview_win = open_float(menu.preview_buf, false, {
            width = width,
            height = pv_h,
            row = pv_row,
            col = col,
            border = cfg.floating_border,
            border_highlight = cfg.floating_border_highlight,
            keep_scrolloff = true, -- a file preview, read like a buffer; honour user scrolloff
        })
        vim.wo[menu.preview_win].wrap = false
        -- The preview is read like a normal buffer, so honour the user's cursorline
        -- (style="minimal" forces it off, so restore their setting explicitly).
        api.nvim_set_option_value("cursorline", user_cursorline, { scope = "local", win = menu.preview_win })
        fill_preview(menu.preview_buf, menu.preview_win, shown, pv)

        if pv.content then
            -- Follow the selection. Only the border title is reconfigured (not the
            -- geometry), so the float doesn't repaint as the cursor moves.
            menu.preview_idx = 1
            api.nvim_create_autocmd("CursorMoved", {
                buffer = menu.menu_buf,
                callback = function()
                    if not menu.ui_visible or not api.nvim_win_is_valid(menu.winid) then
                        return
                    end
                    local idx = api.nvim_win_get_cursor(menu.winid)[1]
                    if idx == menu.preview_idx then
                        return
                    end
                    menu.preview_idx = idx
                    fill_preview(menu.preview_buf, menu.preview_win, preview_data(idx), pv)
                end,
            })
        end
    else
        menu.preview_win, menu.preview_buf = nil, nil
    end
    menu.ui_visible = true

    ---@param idx integer? chosen index, or nil if cancelled
    local function close(idx)
        if not menu.ui_visible then
            return
        end
        menu.ui_visible = false
        close_win(menu.winid)
        close_win(menu.preview_win)
        close_win(menu.notice_win)
        if menu.restore_winid and api.nvim_win_is_valid(menu.restore_winid) then
            api.nvim_set_current_win(menu.restore_winid)
        end
        if idx and menu.on_choice then
            menu.on_choice(idx)
        elseif not idx and menu.on_close then
            menu.on_close()
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
    map_cancel(menu.menu_buf, function()
        close(nil)
    end, { normal = cfg.picker_ui.mappings.close })

    if pv then
        -- Scroll the preview without leaving the menu.
        local function scroll(key)
            if menu.preview_win and api.nvim_win_is_valid(menu.preview_win) then
                api.nvim_win_call(menu.preview_win, function()
                    vim.cmd("normal! " .. api.nvim_replace_termcodes(key, true, false, true))
                end)
            end
        end
        map_keys("<C-d>", "n", menu.menu_buf, function()
            scroll("<C-d>")
        end)
        map_keys("<C-u>", "n", menu.menu_buf, function()
            scroll("<C-u>")
        end)

        -- Move focus between the menu and the preview with the plugin-wide
        -- pane-navigation keys (`switch_window_keys`, given as { left, down, up,
        -- right }; default <C-hjkl>) plus <Tab>/<S-Tab>. The menu sits above the
        -- preview, so down/right descends into the preview and up/left climbs back;
        -- with focus in the preview, j/k and <C-d>/<C-u> scroll it natively, and the
        -- menu's own submit/close keys still act on the highlighted menu row.
        local function focus(win)
            if win and api.nvim_win_is_valid(win) then
                api.nvim_set_current_win(win)
            end
        end
        local sw = cfg.switch_window_keys or {}
        local to_preview, to_menu = { "<Tab>" }, { "<S-Tab>" }
        for _, k in ipairs({ sw[2], sw[4] }) do
            to_preview[#to_preview + 1] = k
        end
        for _, k in ipairs({ sw[3], sw[1] }) do
            to_menu[#to_menu + 1] = k
        end
        for _, b in ipairs({ menu.menu_buf, menu.preview_buf }) do
            map_keys(to_preview, "n", b, function()
                focus(menu.preview_win)
            end)
            map_keys(to_menu, "n", b, function()
                focus(menu.winid)
            end)
        end

        -- Submit/close from the preview too, acting on the highlighted menu row.
        map_keys(cfg.picker_ui.mappings.submit, "n", menu.preview_buf, function()
            close(api.nvim_win_get_cursor(menu.winid)[1])
        end)
        map_cancel(menu.preview_buf, function()
            close(nil)
        end, { normal = cfg.picker_ui.mappings.close })
    end

    api.nvim_create_autocmd("WinClosed", {
        buffer = menu.menu_buf,
        callback = function()
            if menu.skip_close then
                menu.skip_close = false
                return
            end
            close(nil)
        end,
    })
end

--------------------------------------------------------------------------------
-- Multi-choice form (several single-choice lists visible at once)
--------------------------------------------------------------------------------

---@class tuna.FormCustom
---@field label string inline virtual-text prefix shown before the editable value
---@field default string initial text of the editable row
---@field validate fun(text: string): any?, string? returns the parsed value, or nil + an error

---@class tuna.FormWidget
---@field ui_visible boolean
---@field sections { title: string, items: string[], custom: tuna.FormCustom?, sel: integer, text: string? }[]
---@field title string?
---@field on_submit fun(results: { index: integer, custom: any? }[])?
---@field on_close fun()?
---@field skip_close boolean swallow WinClosed events during a resize/teardown
---@field restore_winid integer?
---@field focused integer index of the focused section
---@field wins integer[]
---@field bufs integer[]
local form = { ui_visible = false }

local form_ns = api.nvim_create_namespace("tuna_form")

-- Normal-mode keys that start an edit. On the editable row they act natively; on a
-- fixed choice they do nothing, so the list can't be typed over. (`o`/`O` would add a
-- row, so they are inert everywhere.) `guard_section` is the backstop for anything
-- not listed here.
local FORM_EDIT_KEYS = { "i", "I", "a", "A", "c", "C", "s", "S", "R", "x", "X", "d", "D", "p", "P", "r", "~", "J" }

---The number of selectable rows in a section (its fixed items plus, if any, the
---editable custom row that always sits last).
---@param s table
---@return integer
local function form_rows(s)
    return #s.items + (s.custom and 1 or 0)
end

---Draw the inline label in front of a section's editable row. Uses a fixed extmark id
---so it updates in place, and is re-applied after any repair that rewrites the buffer.
---@param i integer section index
local function form_label(i)
    local s, b = form.sections[i], form.bufs[i]
    if not (s.custom and b and api.nvim_buf_is_valid(b)) then
        return
    end
    pcall(api.nvim_buf_set_extmark, b, form_ns, #s.items, 0, {
        id = 1,
        virt_text = { { s.custom.label, "Comment" } },
        virt_text_pos = "inline",
        -- Pin the label to the start of the line: with the default right gravity the
        -- mark is pushed along by text inserted at column 0, so what was typed would
        -- appear to the *left* of the label instead of after it.
        right_gravity = false,
    })
end

---Keep a section's buffer matching its model: the fixed choices are restored verbatim
---and the row count is pinned, so only the custom row's text is ever really editable.
---The label is virtual text, so it is outside the buffer and can't be edited at all.
---@param i integer section index
local function guard_section(i)
    local s, b, w = form.sections[i], form.bufs[i], form.wins[i]
    if not (s.custom and b and api.nvim_buf_is_valid(b)) then
        return
    end
    local n = #s.items
    local lines = api.nvim_buf_get_lines(b, 0, -1, false)
    local intact = #lines == n + 1
    if intact then
        for j = 1, n do
            if lines[j] ~= s.items[j] then
                intact = false
                break
            end
        end
    end
    if intact then
        s.text = lines[n + 1] -- a valid state: remember what was typed
        return
    end
    -- Something outside the custom row changed (a deleted line, a paste, an undo):
    -- rebuild from the model, keeping the typed text when it survived intact.
    if #lines == n + 1 then
        s.text = lines[n + 1]
    end
    local desired = vim.list_slice(s.items, 1, n)
    desired[n + 1] = s.text or s.custom.default
    local cur = api.nvim_win_is_valid(w) and api.nvim_win_get_cursor(w) or { n + 1, 0 }
    api.nvim_buf_set_lines(b, 0, -1, false, desired)
    form_label(i)
    if api.nvim_win_is_valid(w) then
        local r = math.min(cur[1], n + 1)
        pcall(api.nvim_win_set_cursor, w, { r, math.min(cur[2], #desired[r]) })
    end
end

---Open a vertical stack of single-choice lists, all visible at once. Move within a
---list with `j`/`k` (arrows), switch lists with the plugin-wide pane-navigation keys
---(`switch_window_keys`, default `<C-hjkl>`) or `<Tab>`/`<S-Tab>`,
---`<CR>` submits every list's current selection, Esc cancels. Unlike a chain of
---`menu`s, the user sees and sets all choices together. The focused section is the
---active window (cursor + cursorline), like every other multi-pane tuna float.
---
---A section may end with a `custom` row that is **edited in place**: its label is
---inline virtual text (outside the buffer, so it can't be touched) and the row holds
---just the value. Any normal edit key works on it while the fixed choices above stay
---read-only. `<CR>` in insert mode only leaves insert — it does not submit — so
---several sections can be customized in one pass. On submit each selected custom row
---is `validate`d; a failure keeps the form open, reports the error and parks the
---cursor on the offending row, so nothing typed is lost.
---@param sections { title: string, items: string[], custom: tuna.FormCustom? }[]? sections, or `nil` to resize
---@param title string? overall form title (unused chrome for now; kept for parity)
---@param on_submit fun(results: { index: integer, custom: any? }[])? one result per
---  section: the chosen 1-based row, plus the validated value when that row is the
---  custom one
---@param restore_winid integer? window to refocus once the form closes
---@param on_close fun()? called when the form is dismissed without submitting
function M.form(sections, title, on_submit, restore_winid, on_close)
    if sections == nil then -- resize: keep each section's selection and typed text
        if not form.ui_visible then
            return
        end
        for i, w in ipairs(form.wins) do
            if api.nvim_win_is_valid(w) then
                form.sections[i].sel = api.nvim_win_get_cursor(w)[1]
            end
            guard_section(i) -- refreshes `text` from the buffer
        end
        form.skip_close = true
        for _, w in ipairs(form.wins) do
            close_win(w)
        end
    else
        if #sections == 0 then
            return
        end
        form.sections = {}
        for _, s in ipairs(sections) do
            form.sections[#form.sections + 1] = {
                title = s.title,
                items = s.items,
                custom = s.custom,
                sel = 1,
                text = s.custom and s.custom.default or nil,
            }
        end
        form.title = title
        form.on_submit = on_submit
        form.on_close = on_close
        form.restore_winid = restore_winid
        form.focused = 1
    end

    local cfg = config.get_buffer_config(api.nvim_get_current_buf())
    local vim_width = utils.get_ui_size()

    -- Width = the widest item or section title across the whole form. A custom row
    -- also has to fit its inline label plus the text typed into it.
    local width = 0
    for _, s in ipairs(form.sections) do
        width = math.max(width, #s.title + 4)
        for _, it in ipairs(s.items) do
            width = math.max(width, #it)
        end
        if s.custom then
            width = math.max(width, #s.custom.label + #(s.text or s.custom.default) + 8)
        end
    end
    width = math.min(math.max(width + 2, 20), vim_width - 4)

    -- Per-section heights, then vertically centre the whole stack. Each section costs
    -- its rows plus a 2-line border, and consecutive sections touch (see `PANE_STEP`).
    local n = #form.sections
    local band_row, band_h = utils.float_band()
    local per_cap = math.max(1, math.floor((band_h - PANE_STEP * n) / n))
    local heights, total = {}, 0
    for i, s in ipairs(form.sections) do
        heights[i] = math.max(1, math.min(form_rows(s), per_cap))
        total = total + heights[i] + PANE_STEP
    end
    -- `total` includes every section's border, and a float's `row` is the top of its
    -- footprint (see the menu), so the stack fits exactly in `total` rows from here.
    local row = band_row + math.max(0, math.floor((band_h - total) / 2))
    local col = math.floor((vim_width - width) / 2)

    form.skip_close = false -- fresh windows: a real close should count again
    form.wins, form.bufs = {}, {}
    for i, s in ipairs(form.sections) do
        local b = api.nvim_create_buf(false, true)
        local lines = vim.list_slice(s.items, 1, #s.items)
        if s.custom then
            lines[#lines + 1] = s.text or s.custom.default
        end
        api.nvim_buf_set_lines(b, 0, -1, false, lines)
        -- Only a section with a custom row is writable at all; `guard_section` then
        -- confines the writing to that one row.
        vim.bo[b].modifiable = s.custom ~= nil
        vim.bo[b].filetype = "tuna"
        local w = open_float(b, i == form.focused, {
            width = width,
            height = heights[i],
            row = row,
            col = col,
            border = cfg.floating_border,
            border_highlight = cfg.floating_border_highlight,
            title = " " .. s.title .. " ",
        })
        -- setlocal, so the focused (current) section doesn't leak cursorline's global
        -- default off this float (see the menu note).
        api.nvim_set_option_value("cursorline", true, { scope = "local", win = w })
        api.nvim_win_set_cursor(w, { math.min(s.sel, form_rows(s)), 0 })
        form.wins[i] = w
        form.bufs[i] = b
        form_label(i)
        row = row + heights[i] + PANE_STEP -- next section's border starts where this one ends
    end
    form.ui_visible = true

    ---Tear all section windows down and restore focus.
    local function teardown()
        form.ui_visible = false
        form.skip_close = true
        for _, w in ipairs(form.wins) do
            close_win(w)
        end
        form.skip_close = false
        if form.restore_winid and api.nvim_win_is_valid(form.restore_winid) then
            api.nvim_set_current_win(form.restore_winid)
        end
    end

    local function submit()
        if not form.ui_visible then
            return
        end
        if api.nvim_get_mode().mode:sub(1, 1) == "i" then
            vim.cmd("stopinsert")
        end
        local results = {}
        for i, w in ipairs(form.wins) do
            local s = form.sections[i]
            local idx = api.nvim_win_is_valid(w) and api.nvim_win_get_cursor(w)[1] or s.sel
            results[i] = { index = idx }
            if s.custom and idx == #s.items + 1 then
                guard_section(i) -- pick up the latest typed text
                local value, err = s.custom.validate(s.text or "")
                if err then
                    -- Keep everything on screen and park on the offending row, so a
                    -- typo costs a correction rather than the whole form.
                    utils.notify(err, "WARN")
                    if api.nvim_win_is_valid(w) then
                        form.focused = i
                        api.nvim_set_current_win(w)
                        pcall(api.nvim_win_set_cursor, w, { idx, #(s.text or "") })
                    end
                    return
                end
                results[i].custom = value
            end
        end
        teardown()
        if form.on_submit then
            form.on_submit(results)
        end
    end

    local function cancel()
        if not form.ui_visible then
            return
        end
        teardown()
        if form.on_close then
            form.on_close()
        end
    end

    ---Move section focus by `delta`, wrapping. Focus is shown by the active window
    ---(cursor + cursorline), so this only moves the cursor — no per-switch window
    ---reconfig, which would repaint every float's border on each keypress.
    local function refocus(delta)
        form.focused = (form.focused - 1 + delta) % n + 1
        if api.nvim_win_is_valid(form.wins[form.focused]) then
            api.nvim_set_current_win(form.wins[form.focused])
        end
    end

    ---Switching panes mid-edit, so the pane keys work in insert mode as they do
    ---everywhere else in the plugin. Insert mode carries over only when the section
    ---landed on is sitting on its editable row — otherwise typing would go into a
    ---read-only choice — and the landing row is never moved, so a switch can't quietly
    ---change what another section has selected.
    local function refocus_insert(delta)
        refocus(delta)
        local s, w = form.sections[form.focused], form.wins[form.focused]
        local on_custom = s.custom
            and api.nvim_win_is_valid(w)
            and api.nvim_win_get_cursor(w)[1] == #s.items + 1
        if not on_custom then
            vim.cmd("stopinsert")
        end
    end

    -- Switch lists with the plugin-wide pane-navigation keys (`switch_window_keys`,
    -- also used to move between result panes; default <C-hjkl>), given as
    -- { left, down, up, right }: down/right go to the next list, up/left to the
    -- previous. Tab/S-Tab are always accepted as a portable fallback.
    local sw = cfg.switch_window_keys or {}
    local next_keys, prev_keys = { "<Tab>" }, { "<S-Tab>" }
    for _, k in ipairs({ sw[2], sw[4] }) do
        next_keys[#next_keys + 1] = k
    end
    for _, k in ipairs({ sw[3], sw[1] }) do
        prev_keys[#prev_keys + 1] = k
    end

    for i, b in ipairs(form.bufs) do
        local s = form.sections[i]
        map_keys({ "j", "<down>" }, "n", b, function()
            move_cursor(form.wins[i], form_rows(s), 1)
        end)
        map_keys({ "k", "<up>" }, "n", b, function()
            move_cursor(form.wins[i], form_rows(s), -1)
        end)
        map_keys(next_keys, "n", b, function()
            refocus(1)
        end)
        map_keys(prev_keys, "n", b, function()
            refocus(-1)
        end)
        map_keys("<CR>", "n", b, submit)
        -- `q`/`Q` on top of the shared cancel keys; a section being typed into keeps
        -- `<Esc>` for leaving insert mode, so cancelling from there takes a second one.
        map_cancel(b, cancel, { normal = { "q", "Q" } })

        if s.custom then
            local edit_row = #s.items + 1
            -- An edit key acts natively on the custom row and is inert on the fixed
            -- choices above it. These are `expr` maps returning the key itself, so an
            -- operator such as `c`/`d` still waits for its motion as usual; re-feeding
            -- the key instead would race with the pending input.
            for _, key in ipairs(FORM_EDIT_KEYS) do
                vim.keymap.set("n", key, function()
                    return api.nvim_win_get_cursor(form.wins[i])[1] == edit_row and key or ""
                end, { buffer = b, expr = true, noremap = true, nowait = true })
            end
            map_keys({ "o", "O" }, "n", b, function() end) -- would add a row: always inert
            -- <CR> submits from insert mode too, as it would in any other prompt; it
            -- must be mapped either way, since inserting a line break here would split
            -- the row. Other sections keep whatever was typed into them, so setting
            -- several custom values before submitting still works.
            map_keys("<CR>", "i", b, submit)
            -- The pane keys keep working while typing, like the rest of the plugin's UI.
            map_keys(next_keys, "i", b, function()
                refocus_insert(1)
            end)
            map_keys(prev_keys, "i", b, function()
                refocus_insert(-1)
            end)
            -- `nvim_buf_attach` sees *every* change, including ones no mapping can
            -- intercept (`:1d`, a paste, an undo), which `TextChanged` alone misses.
            -- The repair is scheduled because the buffer is locked during the callback.
            api.nvim_buf_attach(b, false, {
                on_lines = function()
                    if not (form.ui_visible and api.nvim_buf_is_valid(b)) then
                        return true -- detach
                    end
                    vim.schedule(function()
                        if form.ui_visible and form.bufs[i] == b then
                            guard_section(i)
                        end
                    end)
                end,
            })
        end

        api.nvim_create_autocmd("WinClosed", {
            buffer = b,
            callback = function()
                if form.skip_close then
                    return
                end
                cancel()
            end,
        })
    end
end

--------------------------------------------------------------------------------

---Rebuild whichever widgets are currently visible. Called from the `VimResized`
---autocmd so floats stay centred and proportional after the UI changes size.
function M.resize_widgets()
    M.editor(nil)
    M.picker(nil)
    M.input(nil)
    M.menu(nil)
    M.form(nil)
end

return M
