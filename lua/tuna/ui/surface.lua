-- lua/tuna/ui/surface.lua
--
-- A **surface** is any buffer this plugin puts in front of the user that is not a file:
-- the runner UI's panes, its zoom, message float and key legend, and every widget
-- (menu, input, form, panels, testcase editor). They differ in what they show and what
-- their keys do; they do not differ in what Vim must be told about them, and a surface
-- missing any piece of that grows a red error about a buffer the user never opened:
--
--  * unnamed  → the statusline rewrites itself as you move between panes, and `:w`
--    aborts with `E32` before any handler can run
--  * `nofile` → `:w` answers `E382`, and a `BufWriteCmd` on it never fires,
--    so a surface that wants `:w` to mean something has to be `acwrite`
--  * `acwrite` left `modified` → Vim counts it as an unsaved *file*: `:q` answers `E37`
--    and quitting answers `E162`, naming a scratch buffer
--  * read-only without inert keys → `i`, `c`, `u`… land in a mode that errors with
--    `E21` a keystroke later, about an edit the user never started
--
-- So the invariants live here, once, and `tests/surfaces.lua` checks that every surface
-- still holds them. What a surface *does* — which keys act, when it closes, what a write
-- saves — stays with the surface: this module is about what Vim is told, not policy.

local api = vim.api

local M = {}

---The layers floats are drawn on. Neovim's default for a float is 50, the same as the
---runner UI's grid, so anything left unset fights the grid it is drawn over.
M.LAYER = {
    grid = 50, -- the runner UI's pane grid
    zoom = 60, -- its zoomed pane, over the grid
    overlay = 70, -- its message float and key legend, over the zoom
    dialog = 80, -- widgets: always the thing being asked about, so always on top
}

--- Keys that begin a change. On a buffer that cannot take one they only ever end in
--- `E21`, sometimes a keystroke later from a mode the user never meant to enter.
--- (`u`/`U`/`<C-r>` belong here too: undo on an unchangeable buffer raises it just the
--- same, and so do the increment/decrement and case/rot13 operators.)
M.CHANGE_KEYS = {
    "i", "I", "a", "A", "o", "O", "c", "C", "s", "S", "r", "R", "x", "X", "d", "D",
    "p", "P", "J", "~", "<Insert>", "gi", "gI", "gp", "gP", "gJ", "g~",
    "u", "U", "<C-r>", "<C-a>", "<C-x>", "&", "gu", "gU", "g?", ">", "<", "=", "!", "gq", "gw",
}

--- The keys that start a selection, for a buffer with nothing worth copying from it.
local VISUAL_KEYS = { "v", "V", "<C-v>" }

--- Of `CHANGE_KEYS`, those that only select in Visual mode: `i`/`a` begin a text object and
--- `o`/`O` go to the selection's other end.
local SELECTING = { i = true, a = true, o = true, O = true }

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
    -- A statusline shows `%:t`, the last path component: left nameless a surface reads
    -- `[No Name]`, and named after itself the name would change as you move between
    -- panes that have nothing to say about themselves. So the last component is always
    -- `tuna`, while the middle keeps the name unique (Vim requires that) and says what
    -- the float is in `:ls`. A buffer that takes a `:w` needs a name regardless: `:w`
    -- aborts with E32 before `BufWriteCmd` without one.
    pcall(api.nvim_buf_set_name, bufnr, ("tuna://%s/%d/tuna"):format(kind, bufnr))
    -- Tagged so users (and other plugins) can target every tuna float at once — e.g.
    -- lualine's `ignore_focus` or `disabled_filetypes`. `FileType` fires for them, and `Syntax`
    -- does not: no syntax file exists to find, and searching the runtimepath for one on
    -- every float of a menu is a large part of what opening it costs.
    local ignored = vim.o.eventignore
    vim.o.eventignore = ignored == "" and "Syntax" or (ignored .. ",Syntax")
    vim.bo[bufnr].filetype = "tuna"
    vim.o.eventignore = ignored
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
        -- as Vim is concerned, so a later quit would answer `E37`/`E162` naming a widget
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
---@param opts { selectable: boolean? }? `selectable`: a buffer worth pasting from, which Visual
---  mode copies from, unlike a list or a line read at a glance
function M.read_only(bufnr, opts)
    if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
        return
    end
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false
    -- Compared as **terminal codes**, not as written: `nvim_buf_get_keymap` hands back
    -- what a key really is (`<C-r>` comes back as a raw `\18`), so matching the written
    -- form against it finds nothing and a surface's own action (the runner UI's
    -- `<C-r>`, run all) would be `<Nop>`ed over.
    local function code(key)
        return api.nvim_replace_termcodes(key, true, true, true)
    end
    local inert = { n = vim.list_slice(M.CHANGE_KEYS), x = M.CHANGE_KEYS }
    if not (opts and opts.selectable) then
        vim.list_extend(inert.n, VISUAL_KEYS)
    end
    for mode, keys in pairs(inert) do
        local taken = {}
        for _, m in ipairs(api.nvim_buf_get_keymap(bufnr, mode)) do
            taken[code(m.lhs)] = true
        end
        for _, key in ipairs(keys) do
            if not (taken[code(key)] or (mode == "x" and SELECTING[key])) then
                vim.keymap.set(mode, key, "<Nop>", { buffer = bufnr, nowait = true })
            end
        end
    end
end

-- The floats whose footer says how much of their buffer is out of sight, the buffers watched for
-- it, those with a refresh due, and the autocmds.
local overflowing, watched, due, overflow_group = {}, {}, {}, nil

---Bring a float's footer up to date: `↑ n` for the lines above the first on show, `↓ n` for
---those below the last, nothing when all of it shows. Compared with the footer the window has,
---not with one kept here, since re-tiling the grid gives every float a new config.
---@param win integer
local function show_overflow(win)
    if not api.nvim_win_is_valid(win) then
        overflowing[win] = nil
        return
    end
    local top, bottom = vim.fn.line("w0", win), vim.fn.line("w$", win)
    local below = api.nvim_buf_line_count(api.nvim_win_get_buf(win)) - bottom
    local parts = {}
    if top > 1 then
        parts[#parts + 1] = "↑ " .. (top - 1)
    end
    if below > 0 then
        parts[#parts + 1] = "↓ " .. below
    end
    local footer = #parts > 0 and (" " .. table.concat(parts, "  ") .. " ") or ""
    local had = api.nvim_win_get_config(win).footer
    if footer ~= (had and had[1] and had[1][1] or "") then
        pcall(api.nvim_win_set_config, win, footer ~= "" and { footer = footer, footer_pos = "right" } or { footer = "" })
    end
end

---The followed floats showing `bufnr`.
---@param bufnr integer
---@return integer[]
local function showing(bufnr)
    local wins = {}
    for win in pairs(overflowing) do
        if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == bufnr then
            wins[#wins + 1] = win
        end
    end
    return wins
end

---Watch `bufnr` for every change made to it, whoever makes it (a render, a writer of its own, a
---preview following the cursor, a list narrowed by a search, typing), and refresh the footers
---of the floats showing it once the change is done: `on_lines` runs inside the change, where a
---window cannot be configured. A buffer no followed float shows any more is let go.
---@param bufnr integer
local function watch(bufnr)
    if watched[bufnr] then
        return
    end
    watched[bufnr] = true
    api.nvim_buf_attach(bufnr, false, {
        on_lines = function(_, buf)
            if due[buf] then
                return
            end
            if #showing(buf) == 0 then
                watched[buf] = nil
                return true
            end
            due[buf] = true
            vim.schedule(function()
                due[buf] = nil
                for _, win in ipairs(showing(buf)) do
                    show_overflow(win)
                end
            end)
        end,
        on_detach = function(_, buf)
            watched[buf] = nil
        end,
    })
end

---Say in a float's bottom border how much of its buffer is out of sight (`↑ 3  ↓ 25`, on the
---right, nothing when it all shows): a float has no scrollbar, so a long output would read as
---complete. `float` does it for every float tuna opens. Kept current as the buffer changes
---(`watch`) and as the window scrolls or resizes (`WinScrolled`).
---@param winid integer
local function follow_overflow(winid)
    overflowing[winid] = true
    watch(api.nvim_win_get_buf(winid))
    show_overflow(winid)
    if overflow_group then
        return
    end
    overflow_group = api.nvim_create_augroup("tuna_overflow", { clear = true })
    -- Every float followed, not only those `v:event` names: a handful, each a comparison.
    api.nvim_create_autocmd("WinScrolled", {
        group = overflow_group,
        callback = function()
            for win in pairs(overflowing) do
                show_overflow(win)
            end
        end,
    })
    api.nvim_create_autocmd("WinClosed", {
        group = overflow_group,
        callback = function(ev)
            overflowing[tonumber(ev.match)] = nil
        end,
    })
end

-- The floats whose bar lualine is told to draw as they take focus or change mode, and the
-- autocmds doing it.
local floats, bar_group = {}, nil

---Have lualine draw the global bar for the current window now rather than from its queue.
local function refresh_bar()
    pcall(require("lualine").refresh, { scope = "window", place = { "statusline" }, force = true })
end

---Redraw lualine's bar whenever `winid` takes focus or changes mode. lualine's own refresh on a
---mode change redraws every window but the floats, so a float's bar would otherwise keep the old
---mode until lualine's timer comes round. The autocmds are made with the first float, so a
---session whose bar is not lualine's has none.
---@param winid integer
local function bar_follows(winid)
    floats[winid] = true
    if bar_group then
        return
    end
    bar_group = api.nvim_create_augroup("tuna_bar", { clear = true })
    api.nvim_create_autocmd({ "WinEnter", "ModeChanged" }, {
        group = bar_group,
        callback = function()
            if floats[api.nvim_get_current_win()] and vim.o.laststatus == 3 then
                refresh_bar()
            end
        end,
    })
    api.nvim_create_autocmd("WinClosed", {
        group = bar_group,
        callback = function(ev)
            floats[tonumber(ev.match)] = nil
        end,
    })
end

---Open a float for a surface. Every one of them wants the same frame — positioned
---against the editor, `style = "minimal"`, a bordered title in the plugin's border
---colour, no wrapping, and a **layer**, since Neovim's default (50) is the runner
---UI's grid's and anything left unset fights it. What differs between surfaces is where they
---sit and what they show, which is what the caller passes.
---@param bufnr integer
---@param opts { layer: integer, width: integer, height: integer, row: integer, col: integer, border: any, border_highlight: string|false|nil, border_group: string?, title: string|table|nil, enter: boolean?, keep_scrolloff: boolean?, wrap: boolean? }
---  `keep_scrolloff` — for a pane *read* like a buffer rather than navigated as a list:
---  a list pins `scrolloff` to 0 so its first and last rows stay reachable, which is
---  wrong for content the user scrolls through.
---@return integer winid
function M.float(bufnr, opts)
    -- With a global statusline (`laststatus=3`) the bar shows the focused window's
    -- 'statusline', which a new window starts from the global value, and a statusline
    -- plugin that renders into each window (lualine) leaves that blank until its next
    -- refresh: the bar would vanish for a moment whenever a float takes focus. Starting
    -- from the bar of the window it opens over keeps it steady. Only then: from Neovim
    -- 0.12 a float with a 'statusline' of its own draws it inside its border whenever the
    -- statusline is not global, and `style = "minimal"` leaves it empty for that reason.
    local over = api.nvim_get_current_win()
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
    follow_overflow(winid)
    pcall(function()
        if vim.o.laststatus ~= 3 then
            return
        end
        -- lualine draws the bar on a timer, from a queue of refreshes, so a float entered shows
        -- whatever bar it already holds for a moment, and a copy of another window's is a copy
        -- of a moment past (the COMMAND of the `:Tuna` that opened it). Told to refresh now as
        -- a float takes focus (`refresh_bar`), it draws the right one at once; any other
        -- statusline keeps the copy.
        if package.loaded["lualine"] then
            bar_follows(winid)
            if api.nvim_get_current_win() == winid then
                refresh_bar()
            end
            return
        end
        local bar = api.nvim_get_option_value("statusline", { win = over })
        api.nvim_set_option_value("statusline", bar, { scope = "local", win = winid })
    end)
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

---Open `path` in a window that can show a file. From inside the runner UI (a pane or its
---zoom), whose windows are tuna's own and pinned to their buffers, the board is put away first,
---landing in the window it was opened over, as a run of another mode puts it away.
---@param path string
function M.edit(path)
    local ui = package.loaded["tuna.runner_ui"]
    if ui then
        ui.step_out()
    end
    vim.cmd.edit(vim.fn.fnameescape(path))
end

---Keep completion plugins out of a buffer typed into as a prompt (a search, a path, a value):
---what they offer, the buffer's words and a language's snippets, is never what is typed there.
---blink.cmp reads `vim.b.completion`; nvim-cmp takes it per buffer once it has loaded, which a
---lazily loaded one does on the `InsertEnter` that is also the prompt's, so it is told then.
---@param bufnr integer
function M.no_completion(bufnr)
    vim.b[bufnr].completion = false
    local function tell_cmp()
        local cmp = package.loaded["cmp"]
        if cmp and api.nvim_buf_is_valid(bufnr) then
            api.nvim_buf_call(bufnr, function()
                cmp.setup.buffer({ enabled = false })
            end)
            return true
        end
    end
    if not tell_cmp() then
        api.nvim_create_autocmd("InsertEnter", { buffer = bufnr, callback = tell_cmp })
    end
end

-- The reading panes whose cursorline follows focus, by window, and the autocmds that do it.
local followed, follow_group = {}, nil

---Give a reading pane (a preview, a runner UI detail pane, the testcase editor's) the user's
---`cursorline` while it is the current window, and none while it is not: there its cursor
---marks nothing the user is doing. A list keeps its line always instead, since it marks the
---selection. The user's value is the option's global one, which tuna never writes.
---@param winid integer
---@param ignore_user boolean? one list of several on a board, where only the current one acts:
---  it has the line while current whatever the user's value, as that marks the selection
function M.follow_cursorline(winid, ignore_user)
    local function show(win, on)
        api.nvim_set_option_value("cursorline", on, { scope = "local", win = win })
    end
    if not ignore_user and not api.nvim_get_option_value("cursorline", { scope = "global" }) then
        followed[winid] = nil
        show(winid, false)
        return
    end
    followed[winid] = true
    show(winid, api.nvim_get_current_win() == winid)
    if not follow_group then
        -- One pair of autocmds for every followed pane: `WinLeave` runs in the window being left.
        follow_group = api.nvim_create_augroup("tuna_cursorline", { clear = true })
        api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
            group = follow_group,
            callback = function(ev)
                local win = api.nvim_get_current_win()
                if followed[win] then
                    show(win, ev.event == "WinEnter")
                end
            end,
        })
        api.nvim_create_autocmd("WinClosed", {
            group = follow_group,
            callback = function(ev)
                followed[tonumber(ev.match)] = nil
            end,
        })
    end
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

---Put content on a surface. Three things this does:
---
---  * **writes nothing when the content is already there**, so re-rendering leaves the
---    buffer's `changedtick` and the cursor of someone reading it alone;
---  * wraps the write in `undolevels = -1`, because a render is not an edit and must not
---    land in the user's undo history, where `u` would walk back through renders before
---    reaching the user's own edits;
---  * clears `modified` afterwards, whatever the surface: the flag's one job is to mean
---    "the user typed here", and an `acwrite` buffer left modified blocks a quit.
---@param bufnr integer
---@param content string|string[]|nil newline-separated text, or lines
---@param opts { modifiable: boolean? }? leave the buffer editable afterwards
---@return string[] lines what the buffer now holds
function M.render(bufnr, content, opts)
    opts = opts or {}
    local lines
    if type(content) == "table" then
        lines = content
    else
        lines = vim.split(content or "", "\n", { plain = true })
    end
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
