-- Conformance test for tuna's floating **surfaces** — every buffer/window the plugin
-- puts in front of the user (the results-UI panes, its viewer, message float and key
-- legend, and every widget: menu, input, form, panels, testcase editor).
--
-- They are all scratch buffers pretending to be a UI, and each one has to hold the same
-- handful of invariants or it grows a red Vim error about something the user never
-- opened:
--
--   * named + `filetype=tuna`  — an unnamed float rewrites the statusline as you move
--     between panes, and `:w` on it aborts with `E32` before any handler runs
--   * `modified` false         — an `acwrite` buffer left modified is an unsaved *file*:
--     `:q` answers `E37`, quitting answers `E162`, naming a scratch buffer
--   * writes handled           — a `nofile` buffer answers `:w` with `E382`, and its
--     `BufWriteCmd` never fires (verified), so a surface that wants `:w` must be
--     `acwrite`
--   * read-only ⇒ inert        — a key that begins a change on an unmodifiable buffer
--     ends in `E21` a keystroke later, from a mode the user never meant to enter
--   * a known zindex layer     — Neovim's default float layer is 50, the same as the
--     results grid, so an unset dialog fights the grid it is drawn over
--   * its own keys still act    — making a surface read-only neutralises the keys that
--     would change it, and one of those (`<C-r>`) is also a real action: matched in the
--     wrong notation it was mapped to `<Nop>` *over* the action, and "run all" silently
--     did nothing on every results UI
--
-- Run:  nvim --headless -u NONE --cmd "set noswapfile" \
--         -c "set rtp+=." -c "luafile tests/surfaces.lua" -c "qa!"

local api = vim.api

local failures, checks = 0, 0
local function ok(what, cond, extra)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. what .. (extra and ("  ->  " .. tostring(extra)) or ""))
    end
end

--- Keys that begin a change. On an unmodifiable buffer each one ends in `E21`.
local CHANGE_KEYS = {
    "i", "I", "a", "A", "o", "O", "c", "C", "s", "S", "r", "R", "x", "X", "d", "D",
    "p", "P", "J", "~", "v", "V", "<C-v>", "gi", "gI", "gp", "gP", "gJ", "g~", "u", "<C-r>",
}
local LAYERS = { [50] = "grid", [60] = "viewer", [70] = "overlay", [80] = "dialog" }

---Every floating window on screen, with the state we care about.
local function floats()
    local out = {}
    for _, win in ipairs(api.nvim_list_wins()) do
        local cfg = api.nvim_win_get_config(win)
        if cfg.relative ~= "" then
            out[#out + 1] = { win = win, buf = api.nvim_win_get_buf(win), zindex = cfg.zindex }
        end
    end
    return out
end

---Which change-starting keys would reach Vim unmapped on a read-only buffer. Compared
---as **terminal codes**: `nvim_buf_get_keymap` hands back what a `<C-r>` mapping really
---is (a raw `\18`), so matching the written form against it finds nothing.
local function live_change_keys(buf)
    local function code(key)
        return api.nvim_replace_termcodes(key, true, false, true)
    end
    local mapped = {}
    for _, m in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
        mapped[code(m.lhs)] = true
    end
    local live = {}
    for _, key in ipairs(CHANGE_KEYS) do
        if not mapped[code(key)] then
            live[#live + 1] = key
        end
    end
    return live
end

---Check one surface's floats against the invariants.
---@param label string what was opened
local function conforms(label)
    local wins = floats()
    ok(label .. ": is on screen", #wins > 0)
    for i, f in ipairs(wins) do
        local where = string.format("%s [float %d/%d]", label, i, #wins)
        local name = api.nvim_buf_get_name(f.buf)
        ok(where .. ": buffer is named", name ~= "", "unnamed")
        ok(where .. ": filetype is tuna", vim.bo[f.buf].filetype == "tuna", vim.bo[f.buf].filetype)
        ok(where .. ": not modified", not vim.bo[f.buf].modified, "an acwrite buffer left modified blocks :q/:qa")
        ok(where .. ": writes are handled", vim.bo[f.buf].buftype == "acwrite", vim.bo[f.buf].buftype .. " -> :w gives E382")
        ok(where .. ": zindex is a known layer", LAYERS[f.zindex] ~= nil, tostring(f.zindex))
        if not vim.bo[f.buf].modifiable then
            local live = live_change_keys(f.buf)
            ok(where .. ": change keys are inert", #live == 0, table.concat(live, " ") .. " -> E21")
        end
    end
end

--------------------------------------------------------------------------------
-- A problem to open the results UI on.
--------------------------------------------------------------------------------

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function write(name, text)
    local f = assert(io.open(dir .. "/" .. name, "w"))
    f:write(text)
    f:close()
end
write("sol.py", "print(input())\n")
write("sol_input0.txt", "1\n")
write("sol_output0.txt", "1\n")

require("tuna").setup({})
vim.cmd("edit " .. dir .. "/sol.py")
vim.bo.filetype = "python"

---Close every float on a layer. Note `M.menu(nil)` and friends are the *resize* path —
---they re-render what is visible rather than closing it — so a surface is dismissed here
---by closing its windows.
local function close_layer(z)
    for _, f in ipairs(floats()) do
        if f.zindex == z and api.nvim_win_is_valid(f.win) then
            api.nvim_win_close(f.win, true)
        end
    end
    vim.wait(200, function()
        return false
    end)
end

local function settle(ms)
    vim.wait(ms or 300, function()
        return false
    end)
end

--------------------------------------------------------------------------------
-- The surfaces, one at a time (each cleans up after itself).
--------------------------------------------------------------------------------

-- A tuna window has to be recognisable the moment it is entered: `BufEnter` fires as the
-- window opens, and plugins that leave tuna's windows alone by filetype read it then
-- (scrollEOF writes the global `scrolloff` from the focused window's height).
local entered_untagged = {}
api.nvim_create_autocmd("BufEnter", {
    callback = function()
        if api.nvim_win_get_config(0).relative ~= "" and vim.bo.filetype ~= "tuna" then
            entered_untagged[#entered_untagged + 1] = api.nvim_buf_get_name(0)
        end
    end,
})

local widgets = require("tuna.widgets")

vim.cmd("Tuna show_ui")
settle(800)
local runner
for _, r in pairs(require("tuna.commands").runners or {}) do
    runner = r
end
local ui = runner and runner.ui
ok("results UI: opened", ui ~= nil and ui.ui_visible)
if ui then
    conforms("results UI panes")

    -- Every key the user configured has to reach its action. Read-only surfaces map the
    -- change-starting keys to `<Nop>`, and a key that is *both* (`<C-r>`: Vim's redo and
    -- the UI's "run all") is only told apart by comparing terminal codes rather than the
    -- written form — get that wrong and the action is silently mapped over.
    local acting = {}
    for _, m in ipairs(api.nvim_buf_get_keymap(ui.windows.tc.bufnr, "n")) do
        if m.callback then
            acting[api.nvim_replace_termcodes(m.lhs, true, false, true)] = true
        end
    end
    for action, keys in pairs(require("tuna.config").current_setup.runner_ui.mappings) do
        for _, key in ipairs(type(keys) == "table" and keys or { keys }) do
            ok(
                "selector: `" .. key .. "` still runs " .. action,
                acting[api.nvim_replace_termcodes(key, true, false, true)],
                "mapped to <Nop> or unmapped"
            )
        end
    end

    ui:show_viewer("so")
    settle()
    conforms("results UI + viewer")
    ui:close_viewer()
    settle()

    ui:show_message("compiler said", "warning: unused variable")
    settle()
    conforms("results UI + message float")
    close_layer(70)

    ui:show_help()
    settle()
    conforms("results UI + key legend")
    close_layer(70)

    ui:delete()
    settle()
    ok("results UI: closes completely", #floats() == 0, #floats() .. " floats left")
end

widgets.menu({ "one", "two" }, "a menu", function() end)
settle(150)
conforms("widgets.menu")
close_layer(80)

widgets.input("type here", "", function() end)
settle(150)
conforms("widgets.input")
close_layer(80)

widgets.form({ { title = "pick", items = { "a", "b" } } }, function() end)
settle(150)
conforms("widgets.form")
close_layer(80)

widgets.panels({ { title = "left", items = { "a", "b" } }, { title = "right", items = { "x" } } }, function() end,
    nil, nil, { "BANNER", "BANNER" })
settle(150)
conforms("widgets.panels")
-- `conforms` cannot demand this of every widget — the chooser form has a row that is
-- typed into — but a board of lists has nothing to type, and a scratch buffer is
-- modifiable until told otherwise. Left that way, `open_float` skips `read_only` and the
-- menu becomes something you can edit, a keystroke away from `E21`.
for i, f in ipairs(floats()) do
    ok(("widgets.panels [float %d]: list is read-only"):format(i), not vim.bo[f.buf].modifiable, "editable menu")
end
close_layer(80)

widgets.editor(api.nvim_get_current_buf(), 0, "1\n", "1\n", function() end)
settle(150)
conforms("widgets.editor")
close_layer(80)

-- A resize rebuilds the editor where the user was: the pane being typed in, the cursor in
-- it, what was typed, and still typing, never going through the editor's own close.
do
    widgets.editor(api.nvim_get_current_buf(), 0, "1\n", "1\n", function() end, api.nvim_get_current_win())
    settle(150)
    for _, f in ipairs(floats()) do
        local title = api.nvim_win_get_config(f.win).title
        if title and vim.inspect(title):find("Output") then
            api.nvim_set_current_win(f.win)
        end
    end
    api.nvim_buf_set_lines(0, 0, -1, false, { "typed", "here" })
    api.nvim_win_set_cursor(0, { 2, 0 })
    -- Resized while typing at the end of the last line: the key after the resize still
    -- lands in insert mode, and the closing `<Esc>` steps back onto the last character.
    _G.tuna_probe = {}
    api.nvim_feedkeys(
        api.nvim_replace_termcodes(
            "A<Cmd>lua require('tuna.widgets').resize_widgets()<CR><Cmd>lua tuna_probe.mode = vim.api.nvim_get_mode().mode<CR><Esc>",
            true, false, true
        ),
        "nx",
        false
    )
    settle(150)
    local title = api.nvim_win_get_config(0).title
    ok("a resize keeps the editor open", #floats() == 2, #floats() .. " floats")
    ok("still typing", tuna_probe.mode == "i", tuna_probe.mode)
    ok("in the pane the user was in", title and vim.inspect(title):find("Output") ~= nil, vim.inspect(title))
    ok("with its cursor and its text", vim.deep_equal({ api.nvim_win_get_cursor(0), api.nvim_buf_get_lines(0, 0, -1, false) },
        { { 2, 3 }, { "typed", "here" } }), vim.inspect(api.nvim_win_get_cursor(0)))
    close_layer(80)
end

-- The editor's two panes are moved between with the plugin-wide pane keys, whatever they
-- are set to, in normal and insert mode; it has no pane keys of its own, and Tab is not one.
do
    require("tuna").setup({ switch_window_keys = { "<A-h>", "<A-j>", "<A-k>", "<A-l>" } })
    widgets.editor(api.nvim_get_current_buf(), 0, "1\n", "1\n", function() end, api.nvim_get_current_win())
    settle(150)
    local function pane()
        local title = api.nvim_win_get_config(0).title
        return title and vim.trim(title[1][1]):match("^%a+") or "?"
    end
    local function keys(k)
        api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "x", false)
    end
    local seen = { pane() }
    keys("<A-l>")
    seen[#seen + 1] = pane()
    keys("<A-h>")
    seen[#seen + 1] = pane()
    keys("i<A-l><Esc>")
    seen[#seen + 1] = pane()
    keys("<Tab>")
    seen[#seen + 1] = pane()
    keys("<C-l>")
    seen[#seen + 1] = pane()
    keys("<Tab>")
    seen[#seen + 1] = pane()
    keys("a<A-h><Esc>")
    seen[#seen + 1] = pane()
    ok("the pane keys move between the editor's panes, typing too, and Tab does not",
        vim.deep_equal(seen, { "Input", "Output", "Input", "Output", "Output", "Output", "Output", "Input" }), vim.inspect(seen))
    close_layer(80)
    require("tuna").setup({})
end

-- A menu can start on a given row (a following preview with it), and a resize keeps the
-- row the cursor is on rather than going back to the top.
widgets.menu({ "one", "two", "three" }, "a menu", function() end, nil, nil, nil, nil, 2)
settle(150)
ok("a menu starts on the row it is given", api.nvim_win_get_cursor(0)[1] == 2, api.nvim_win_get_cursor(0)[1])
api.nvim_win_set_cursor(0, { 3, 0 })
widgets.menu(nil)
settle(150)
ok("and a resize keeps the row the cursor is on", api.nvim_win_get_cursor(0)[1] == 3, api.nvim_win_get_cursor(0)[1])
close_layer(80)
widgets.menu({ "one", "two" }, "a menu", function() end, nil, nil, {
    width = 40,
    content = function(i)
        return { lines = { "row " .. i } }
    end,
}, nil, 2)
settle(150)
local previewed
for _, f in ipairs(floats()) do
    if f.win ~= api.nvim_get_current_win() and f.zindex == 80 then
        previewed = api.nvim_buf_get_lines(f.buf, 0, -1, false)[1]
    end
end
ok("a following preview starts on that row too", previewed == "row 2", previewed)
close_layer(80)

-- With a global statusline a float starts from the bar of the window it opens over: a
-- statusline plugin that renders into each window (lualine) otherwise blanks the one bar
-- whenever a float takes focus.
local code = api.nvim_get_current_win()
local laststatus = vim.o.laststatus
vim.o.laststatus = 3
api.nvim_set_option_value("statusline", "CODE BAR", { scope = "local", win = code })
widgets.menu({ "one" }, "a menu", function() end)
settle(150)
local focused = api.nvim_get_current_win()
local bar = api.nvim_get_option_value("statusline", { win = focused })
ok("laststatus=3: a float starts with the statusline of the window it opened over", focused ~= code and bar == "CODE BAR", bar)
close_layer(80)
vim.o.laststatus = laststatus

ok("every float is tagged as tuna's before it is entered", #entered_untagged == 0, entered_untagged)

-- Otherwise a float draws no statusline of its own: from Neovim 0.12 a float whose
-- 'statusline' is set draws it inside its border unless the statusline is global.
do
    local surface = require("tuna.surface")
    local global_sl, global_ls = vim.o.statusline, vim.o.laststatus
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 80, 20
    vim.o.statusline = "BAR %f"
    local function open()
        local b = api.nvim_create_buf(false, true)
        surface.adopt(b, "check")
        api.nvim_buf_set_lines(b, 0, -1, false, { "one", "two", "three", "four" })
        local w = surface.float(b, { layer = surface.LAYER.dialog, width = 30, height = 4, row = 2, col = 2, border = "single" })
        vim.cmd("redraw!")
        -- Every screen row, as drawn: what matters is what sits between the float's last
        -- line and its bottom border, wherever the grid puts it.
        local drawn = {}
        for r = 1, vim.o.lines do
            local line = ""
            for c = 1, vim.o.columns do
                line = line .. vim.fn.screenstring(r, c)
            end
            drawn[r] = line
        end
        local sl = api.nvim_get_option_value("statusline", { scope = "local", win = w })
        api.nvim_win_close(w, true)
        return sl, drawn, api.nvim_buf_get_name(b)
    end

    vim.o.laststatus = 2
    local sl, drawn, name = open()
    ok("laststatus=2: a float gets no statusline of its own", sl == "", sl)
    local last, named = nil, false
    for r, line in ipairs(drawn) do
        last = last or (line:find("four", 1, true) and r)
        named = named or line:find(name, 1, true) ~= nil
    end
    local below = last and drawn[last + 1] or ""
    ok("and draws no bar inside its border", last and below:find("└", 1, true) and not named, vim.inspect(drawn))

    vim.o.statusline, vim.o.laststatus = global_sl, global_ls
    vim.o.columns, vim.o.lines = columns, lines
end

vim.fn.delete(dir, "rf")
print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then
    vim.cmd("cquit 1")
end
