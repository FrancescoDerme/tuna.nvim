---A **surface** is any buffer this plugin puts in front of the user that is not a file:
---the results-UI panes, its viewer, message float and key legend, and every widget
---(menu, picker, input, form, testcase editor). They differ in what they show and what
---their keys do; they do not differ in what Vim must be told about them, and every time
---one of them was built by hand it ended up missing a piece of that and growing a red
---error about a buffer the user never opened:
---
---  * unnamed  → the statusline rewrites itself as you move between panes, and `:w`
---    aborts with `E32` before any handler can run
---  * `nofile` → `:w` answers `E382`, and a `BufWriteCmd` on it never fires (verified),
---    so a surface that wants `:w` to mean something has to be `acwrite`
---  * `acwrite` left `modified` → Vim counts it as an unsaved *file*: `:q` answers `E37`
---    and quitting answers `E162`, naming a scratch buffer
---  * read-only without inert keys → `i`, `c`, `u`… land in a mode that errors with
---    `E21` a keystroke later, about an edit the user never started
---
---So the invariants live here, once, and `tests/surfaces.lua` checks that every surface
---still holds them. What a surface *does* — which keys act, when it closes, what a write
---saves — stays with the surface: this module is about what Vim is told, not policy.
local api = vim.api

local M = {}

---The layers floats are drawn on. Neovim's default for a float is 50, the same as the
---results grid, so anything left unset fights the grid it is drawn over.
M.LAYER = {
    grid = 50, -- the results-UI pane grid
    viewer = 60, -- its viewer, over the grid
    overlay = 70, -- its message float and key legend, over the viewer
    dialog = 80, -- widgets: always the thing being asked about, so always on top
}

--- Keys that begin a change. On a buffer that cannot take one they only ever end in
--- `E21`, sometimes a keystroke later from a mode the user never meant to enter.
--- (`u`/`U`/`<C-r>` belong here too: undo on an unchangeable buffer raises it just the
--- same, and so do the increment/decrement and case/rot13 operators.)
M.CHANGE_KEYS = {
    "i", "I", "a", "A", "o", "O", "c", "C", "s", "S", "r", "R", "x", "X", "d", "D",
    "p", "P", "J", "~", "v", "V", "<C-v>", "<Insert>", "gi", "gI", "gp", "gP", "gJ", "g~",
    "u", "U", "<C-r>", "<C-a>", "<C-x>", "&", "gu", "gU", "g?",
}

---Tell Vim what this buffer is: a named, tagged scratch buffer whose writes are ours to
---handle. Call it once, as soon as the buffer exists.
---@param bufnr integer
---@param kind string what to call it in `:ls` (`runner`, `widget`, `help`, …)
---@param opts { on_write: fun()?, keep_clean: boolean? }?
---  `on_write` — what `:w` does here (nothing by default, which is still better than
---  `E382`); `keep_clean` — for a surface the user types into that has nothing to save,
---  keep `modified` false as they type, so the prompt they are filling in cannot end up
---  blocking a quit.
function M.adopt(bufnr, kind, opts)
    opts = opts or {}
    if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
        return
    end
    require("tuna.utils").name_float_buffer(bufnr, kind)
    -- Tagged so users (and other plugins) can target every tuna float at once — e.g.
    -- lualine's `disabled_filetypes`, or scrollEOF's.
    vim.bo[bufnr].filetype = "tuna"
    vim.bo[bufnr].buftype = "acwrite"
    api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        callback = opts.on_write or function() end,
    })
    if opts.keep_clean then
        local function clean()
            if api.nvim_buf_is_valid(bufnr) then
                vim.bo[bufnr].modified = false
            end
        end
        api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = bufnr, callback = clean })
        -- `TextChanged` alone is not enough, for the same reason the chooser form needs
        -- an `on_lines` repair at all: a write that happens *after* it has fired — the
        -- form restoring its fixed rows behind a paste, a `:1d`, an undo — leaves
        -- `modified` set with nothing left to clear it. That is an unsaved *file* as far
        -- as Vim is concerned, so a later quit answered `E37`/`E162` naming a widget
        -- buffer the user never opened. `on_lines` sees every change; the clearing is
        -- scheduled because a buffer option cannot be set from inside the callback.
        api.nvim_buf_attach(bufnr, false, {
            on_lines = function()
                if not api.nvim_buf_is_valid(bufnr) then
                    return true -- detach
                end
                vim.schedule(clean)
            end,
        })
        clean()
    end
    vim.bo[bufnr].modified = false
end

---Make a buffer that cannot be changed *say* so, by neutralising the keys that would
---try. Bound only where nothing is mapped yet, so a surface's real actions keep their
---meanings — which is why this is called **after** those are bound.
---@param bufnr integer
function M.read_only(bufnr)
    if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
        return
    end
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false
    -- Compared as **terminal codes**, not as written: `nvim_buf_get_keymap` hands back
    -- what a key really is (`<C-r>` comes back as a raw `\18`), so matching the written
    -- form against it finds nothing and a surface's own action gets `<Nop>`ed over —
    -- which is exactly what silently killed the results UI's "run all" key.
    local function code(key)
        return api.nvim_replace_termcodes(key, true, false, true)
    end
    local taken = {}
    for _, m in ipairs(api.nvim_buf_get_keymap(bufnr, "n")) do
        taken[code(m.lhs)] = true
    end
    for _, key in ipairs(M.CHANGE_KEYS) do
        if not taken[code(key)] then
            vim.keymap.set("n", key, "<Nop>", { buffer = bufnr, nowait = true })
        end
    end
end

---Open a float for a surface. Every one of them wants the same frame — positioned
---against the editor, `style = "minimal"`, a bordered title in the plugin's border
---colour, no wrapping, and a **layer**, since Neovim's default (50) is the results
---grid's and anything left unset fights it. What differs between surfaces is where they
---sit and what they show, which is what the caller passes.
---@param bufnr integer
---@param opts { layer: integer, width: integer, height: integer, row: integer, col: integer, border: any, border_highlight: string|false|nil, border_group: string?, title: string|table|nil, enter: boolean?, keep_scrolloff: boolean?, wrap: boolean? }
---  `keep_scrolloff` — for a pane *read* like a buffer rather than navigated as a list:
---  a list pins `scrolloff` to 0 so its first and last rows stay reachable, which is
---  wrong for content the user scrolls through.
---@return integer winid
function M.float(bufnr, opts)
    local winid = api.nvim_open_win(bufnr, opts.enter == true, {
        relative = "editor",
        width = math.max(1, opts.width),
        height = math.max(1, opts.height),
        row = opts.row,
        col = opts.col,
        border = opts.border,
        title = opts.title,
        title_pos = opts.title and "center" or nil,
        style = "minimal",
        zindex = opts.layer,
    })
    require("tuna.utils").set_border_highlight(winid, opts.border_highlight, opts.border_group)
    vim.wo[winid].wrap = opts.wrap == true
    if not opts.keep_scrolloff then
        -- `scrolloff`/`sidescrolloff` are global-local, so this only affects this window:
        -- a large global value (999, to keep normal buffers centred) otherwise refuses to
        -- let the cursor reach a list's first and last rows.
        vim.wo[winid].scrolloff = 0
        vim.wo[winid].sidescrolloff = 0
    end
    return winid
end

---Treat several windows as one surface: whichever way any of them is closed — a key, a
---`:q`, a `:close`, anything else — the rest go with it. Keyed on `WinClosed` because a
---mapping cannot cover `:q`, which never passes through one; deferred because windows
---must not be closed from inside a close; and guarded against re-entry, or closing the
---second window would trigger the handler that is closing it.
---@param wins integer[] the windows that belong together
---@param on_close fun()? what to do instead of just closing the rest
function M.group(wins, on_close)
    local closing = false
    local function close_all()
        if closing then
            return
        end
        closing = true
        if on_close then
            on_close()
            return
        end
        for _, win in ipairs(wins) do
            if api.nvim_win_is_valid(win) then
                api.nvim_win_close(win, true)
            end
        end
    end
    for _, win in ipairs(wins) do
        api.nvim_create_autocmd("WinClosed", {
            pattern = tostring(win),
            once = true,
            callback = function()
                vim.schedule(close_all)
            end,
        })
    end
    return close_all
end

---Whether a buffer already holds exactly these lines.
---@param bufnr integer
---@param lines string[]
---@return boolean
function M.same_lines(bufnr, lines)
    local cur = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if #cur ~= #lines then
        return false
    end
    for i = 1, #cur do
        if cur[i] ~= lines[i] then
            return false
        end
    end
    return true
end

---Put content on a surface. Three things this does that hand-written renders forgot:
---
---  * **writes nothing when the content is already there**, so re-rendering leaves the
---    buffer's `changedtick` and the cursor of someone reading it alone;
---  * wraps the write in `undolevels = -1`, because a render is not an edit and must not
---    land in the user's undo history — with a dozen of them behind you, `u` walked back
---    through *our* writes before reaching yours and looked like it had failed;
---  * clears `modified` afterwards, whatever the surface: the flag's one job is to mean
---    "the user typed here", and an `acwrite` buffer left modified blocks a quit.
---@param bufnr integer
---@param content string|string[]|nil newline-separated text, or lines
---@param opts { modifiable: boolean? }? leave the buffer editable afterwards
---@return string[] lines what the buffer now holds
function M.render(bufnr, content, opts)
    opts = opts or {}
    local lines = type(content) == "table" and content or vim.split(content or "", "\n", { plain = true })
    if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
        return lines
    end
    vim.bo[bufnr].modifiable = true
    if not M.same_lines(bufnr, lines) then
        local undolevels = vim.bo[bufnr].undolevels
        vim.bo[bufnr].undolevels = -1
        api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].undolevels = undolevels
    end
    vim.bo[bufnr].modifiable = opts.modifiable == true
    vim.bo[bufnr].modified = false
    return lines
end

return M
