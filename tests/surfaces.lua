-- Conformance test for tuna's floating **surfaces** — every buffer/window the plugin
-- puts in front of the user (the runner UI's panes, its zoom, message float and key
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
--     runner UI's grid, so an unset dialog fights the grid it is drawn over
--   * its own keys still act    — making a surface read-only neutralises the keys that
--     would change it, and one of those (`<C-r>`) is also a real action: matched in the
--     wrong notation it was mapped to `<Nop>` *over* the action, and "run all" silently
--     did nothing on every runner UI
--
-- Run:  nvim --headless -u NONE --cmd "set noswapfile" \
--         -c "set rtp+=." -c "luafile tests/surfaces.lua" -c "qa!"

local api = vim.api
local drain = dofile("tests/harness.lua").drain

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
    "p", "P", "J", "~", "gi", "gI", "gp", "gP", "gJ", "g~", "u", "<C-r>", ">", "<", "=", "!", "gq", "gw",
}
local LAYERS = { [50] = "grid", [60] = "zoom", [70] = "overlay", [80] = "dialog" }

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
        return api.nvim_replace_termcodes(key, true, true, true)
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
        local cfg = api.nvim_win_get_config(f.win)
        if cfg.title then
            ok(where .. ": its title is centred", cfg.title_pos == "center", cfg.title_pos)
        end
        if not vim.bo[f.buf].modifiable then
            local live = live_change_keys(f.buf)
            ok(where .. ": change keys are inert", #live == 0, table.concat(live, " ") .. " -> E21")
        end
    end
end

--------------------------------------------------------------------------------
-- A problem to open the runner UI on.
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
    drain()
end

local settle = drain

--------------------------------------------------------------------------------
-- The surfaces, one at a time (each cleans up after itself).
--------------------------------------------------------------------------------

-- A tuna window has to be recognisable the moment it is entered: `BufEnter` fires as the
-- window opens, and plugins that leave tuna's windows alone by filetype read it then
-- (lualine's `ignore_focus`, which keeps the statusline on the file underneath).
local entered_untagged = {}
api.nvim_create_autocmd("BufEnter", {
    callback = function()
        if api.nvim_win_get_config(0).relative ~= "" and vim.bo.filetype ~= "tuna" then
            entered_untagged[#entered_untagged + 1] = api.nvim_buf_get_name(0)
        end
    end,
})

local widgets = require("tuna.ui.widgets")

vim.cmd("Tuna show_ui")
settle()
local runner
for _, r in pairs(require("tuna.commands").runners or {}) do
    runner = r
end
local ui = runner and runner.ui
ok("runner UI: opened", ui ~= nil and ui.ui_visible)
if ui then
    conforms("runner UI panes")

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

    ui:zoom("so")
    settle()
    conforms("runner UI + zoom")
    ui:unzoom()
    settle()

    ui:show_message("compiler said", "warning: unused variable")
    settle()
    conforms("runner UI + message float")
    close_layer(70)

    ui:show_help()
    settle()
    conforms("runner UI + key legend")
    close_layer(70)

    -- Its two columns are one legend: closing either by hand (`:q`, `:close`) takes the other.
    -- Two need the width of both, which the editor here is given for the purpose.
    local narrow = vim.o.columns
    vim.o.columns = 200
    settle()
    ui:show_help()
    settle()
    local function legend()
        return vim.tbl_filter(function(f)
            return f.zindex == 70
        end, floats())
    end
    local columns = #legend()
    api.nvim_set_current_win(legend()[1].win)
    vim.cmd("quit")
    settle()
    ok("closing one column of the legend closes the other", columns == 2 and #legend() == 0, vim.inspect({ columns, #legend() }))
    vim.o.columns = narrow
    settle()
    close_layer(70)

    ui:delete()
    settle()
    ok("runner UI: closes completely", #floats() == 0, #floats() .. " floats left")
end

widgets.menu({ "one", "two" }, "a menu", function() end)
settle()
conforms("widgets.menu")
close_layer(80)

-- Every float says in its border when it is cut off, a preview following the cursor included,
-- which is written as the row changes rather than through `render`.
do
    local long = {}
    for i = 1, 80 do
        long[i] = "line " .. i
    end
    widgets.menu({ "long", "short" }, "a menu", function() end, nil, nil, {
        width = 40,
        content = function(i)
            return { title = "preview", lines = i == 1 and long or { "fits" } }
        end,
    })
    settle()
    local function preview_footer()
        for _, f in ipairs(floats()) do
            local cfg = api.nvim_win_get_config(f.win)
            if f.zindex == 80 and cfg.title and vim.inspect(cfg.title):find("preview") then
                return cfg.footer and cfg.footer[1] and cfg.footer[1][1] or ""
            end
        end
    end
    local cut = preview_footer()
    api.nvim_feedkeys("j", "x", false)
    settle()
    ok("a preview cut off says so in its border, and not once the row it shows fits", (cut or ""):find("↓") ~= nil and preview_footer() == "", vim.inspect({ cut, preview_footer() }))
    close_layer(80)
end

-- A menu whose preview varies takes one width for all of it: what it shows fits, between half
-- and seven tenths of the editor.
do
    local cols = require("tuna.utils").get_ui_size()
    local got = {
        widgets.sequence_width({ "short" }, { { title = "t", lines = { "short" } } }),
        widgets.sequence_width({ "short", string.rep("x", math.floor(cols * 0.6)) }, {}),
        widgets.sequence_width({ "short" }, { { title = "t", lines = { "", string.rep("x", math.floor(cols * 0.6)) } } }),
        widgets.sequence_width({ string.rep("x", cols) }, {}),
    }
    ok("a sequence of previews is as wide as the widest name or preview line, between half and seven tenths of the editor",
        vim.deep_equal(got, { math.floor(cols * 0.5), math.floor(cols * 0.6) + 4, math.floor(cols * 0.6) + 4, math.floor(cols * 0.7) }), vim.inspect(got))
end

widgets.input("type here", "", function() end)
settle()
conforms("widgets.input")
close_layer(80)

widgets.form({ { title = "pick", items = { "a", "b" } } }, function() end)
settle()
conforms("widgets.form")
close_layer(80)

widgets.panels({ { title = "left", items = { "a", "b" } }, { title = "right", items = { "x" } } }, function() end,
    nil, nil, { "BANNER", "BANNER" })
settle()
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
settle()
conforms("widgets.editor")
-- Its size is the two panes together, borders included, as every board's is.
do
    local left, right, panes = math.huge, 0, 0
    for _, f in ipairs(floats()) do
        if f.zindex == 80 then
            local c = api.nvim_win_get_config(f.win)
            left, right, panes = math.min(left, c.col), math.max(right, c.col + c.width + 2), panes + 1
        end
    end
    local cols = require("tuna.utils").get_ui_size()
    ok("the editor's two panes together are editor_ui.width of the editor", panes == 2 and right - left == 2 * math.floor(cols * 0.8 / 2), vim.inspect({ panes, left, right, cols }))
end
close_layer(80)

-- A resize rebuilds the editor where the user was: the pane being typed in, the cursor in
-- it, what was typed, and still typing, never going through the editor's own close.
do
    widgets.editor(api.nvim_get_current_buf(), 0, "1\n", "1\n", function() end, api.nvim_get_current_win())
    settle()
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
            "A<Cmd>lua require('tuna.ui.widgets').resize_widgets()<CR><Cmd>lua tuna_probe.mode = vim.api.nvim_get_mode().mode<CR><Esc>",
            true, false, true
        ),
        "nx",
        false
    )
    settle()
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
    settle()
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

-- The editor saves the Neovim way, `:w`, and `:wq` to save and close, with no key of its
-- own for it, and asks before an edit is thrown away, in the runner UI's words.
do
    local saved, asked, answer
    local real_menu = widgets.menu
    widgets.menu = function(items, title, on_choice)
        asked = { title = title, items = items }
        on_choice(answer)
    end
    local function open()
        saved, asked = nil, nil
        widgets.editor(api.nvim_get_current_buf(), 3, "1\n", "1\n", function(c)
            saved = c
        end, api.nvim_get_current_win())
        settle()
    end
    local function press(k)
        api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "x", false)
        settle()
    end
    local function edit()
        api.nvim_buf_set_lines(0, 0, -1, false, { "2" })
    end

    open()
    press("q")
    ok("an untouched editor closes without asking", asked == nil and #floats() == 0, vim.inspect(asked))
    open()
    edit()
    api.nvim_buf_set_lines(0, 0, -1, false, { "1", "" })
    press("q")
    ok("nor does one whose text was typed back to what was saved", asked == nil and #floats() == 0, vim.inspect(asked))

    open()
    edit()
    answer = 3
    press("q")
    ok("an edit is asked about, in the runner UI's words", vim.deep_equal(asked, {
        title = "Unsaved testcase 3",
        items = { "Save and close", "Discard and close", "Keep editing" },
    }), vim.inspect(asked))
    ok("keeping it keeps the editor", #floats() == 2, #floats() .. " floats")
    answer = 2
    press("q")
    ok("discarding closes without saving", #floats() == 0 and saved == nil, vim.inspect(saved))

    open()
    edit()
    answer = 1
    press("<Esc>")
    ok("saving closes with the edit saved", #floats() == 0 and saved ~= nil and saved.input:match("^2") ~= nil, vim.inspect(saved))

    open()
    edit()
    vim.cmd("write")
    ok(":w saves and keeps the editor open", saved ~= nil and #floats() == 2, vim.inspect(saved))
    asked = nil
    press("q")
    ok("after which closing asks nothing", asked == nil and #floats() == 0, vim.inspect(asked))
    open()
    edit()
    vim.cmd("wq")
    settle()
    ok(":wq saves and closes", saved ~= nil and #floats() == 0, #floats() .. " floats")

    open()
    local own = {}
    for _, mode in ipairs({ "n", "i" }) do
        for _, m in ipairs(api.nvim_buf_get_keymap(0, mode)) do
            own[#own + 1] = mode .. m.lhs
        end
    end
    ok("<C-s> and <C-q> are not the editor's", not vim.tbl_contains(own, "n<C-S>") and not vim.tbl_contains(own, "i<C-S>")
        and not vim.tbl_contains(own, "i<C-Q>"), vim.inspect(own))
    close_layer(80)
    widgets.menu = real_menu
end

-- A menu can start on a given row (a following preview with it), and a resize keeps the
-- row the cursor is on rather than going back to the top.
widgets.menu({ "one", "two", "three" }, "a menu", function() end, nil, nil, nil, nil, 2)
settle()
ok("a menu starts on the row it is given", api.nvim_win_get_cursor(0)[1] == 2, api.nvim_win_get_cursor(0)[1])
api.nvim_win_set_cursor(0, { 3, 0 })
widgets.menu(nil)
settle()
ok("and a resize keeps the row the cursor is on", api.nvim_win_get_cursor(0)[1] == 3, api.nvim_win_get_cursor(0)[1])
close_layer(80)
widgets.menu({ "one", "two" }, "a menu", function() end, nil, nil, {
    width = 40,
    content = function(i)
        return { lines = { "row " .. i } }
    end,
}, nil, 2)
settle()
local previewed
for _, f in ipairs(floats()) do
    if f.win ~= api.nvim_get_current_win() and f.zindex == 80 then
        previewed = api.nvim_buf_get_lines(f.buf, 0, -1, false)[1]
    end
end
ok("a following preview starts on that row too", previewed == "row 2", previewed)
close_layer(80)

-- A pane worth pasting from is selected and copied from like any buffer, what a selection could
-- change stays inert instead of raising `E21`, and a key the surface claims keeps its meaning.
-- A list, and a pane that does not ask for it, starts no selection.
widgets.menu({ "one" }, "a menu", function() end, nil, nil, { title = "preview", lines = { "one two", "three" }, selectable = true })
settle()
for _, f in ipairs(floats()) do
    if api.nvim_buf_get_lines(f.buf, 0, 1, false)[1] == "one two" then
        api.nvim_set_current_win(f.win)
    end
end
local function typed(keys, cursor)
    api.nvim_win_set_cursor(0, cursor or { 1, 0 })
    api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
    return vim.fn.getreg('"')
end
ok("a read-only pane copies a line", typed("yy") == "one two\n", vim.fn.getreg('"'))
ok("and a selection", typed("vey") == "one", vim.fn.getreg('"'))
ok("of lines", typed("Vjy") == "one two\nthree\n", vim.fn.getreg('"'))
ok("of a block", typed("<C-v>jy") == "o\nt", vim.fn.getreg('"'))
ok("by a text object", typed("viwy", { 1, 4 }) == "two", vim.fn.getreg('"'))
ok("from its other end", typed("vlohy", { 1, 4 }) == " tw", vim.fn.getreg('"'))
for _, key in ipairs({ "d", "c", "s", "x", "p", "u", "U", "~", "J", "I", "A", ">", "<", "=", "!", "gq", "gw" }) do
    vim.v.errmsg = ""
    local fine, err = pcall(typed, "Vj" .. key)
    ok("a selection's '" .. key .. "' stays inert", fine and vim.v.errmsg == "" and vim.fn.mode() == "n", err or vim.v.errmsg)
end
ok("and the pane's '>' too", pcall(typed, ">>") and vim.v.errmsg == "", vim.v.errmsg)
close_layer(80)
local function inert_selections(buf)
    local inert = 0
    for _, m in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
        if vim.tbl_contains({ "v", "V", "<C-V>" }, m.lhs) then
            inert = inert + 1
        end
    end
    return inert
end
widgets.menu({ "one" }, "a menu", function() end, nil, nil, { title = "preview", lines = { "two" } })
settle()
for _, f in ipairs(floats()) do
    ok("a list or a pane not worth pasting from starts no selection", inert_selections(f.buf) == 3, inert_selections(f.buf))
end
close_layer(80)
local claimed = api.nvim_create_buf(false, true)
vim.keymap.set("x", "d", "y", { buffer = claimed })
vim.keymap.set("n", "<", "y", { buffer = claimed })
require("tuna.ui.surface").read_only(claimed)
local function claim(mode, lhs)
    for _, m in ipairs(api.nvim_buf_get_keymap(claimed, mode)) do
        if m.lhs == lhs then
            return m.rhs
        end
    end
end
ok("a key a surface claims in Visual mode stays claimed", claim("x", "d") == "y", claim("x", "d"))
ok("and a `<`, which Vim names `<lt>`", claim("n", "<lt>") == "y", claim("n", "<lt>"))
api.nvim_buf_delete(claimed, { force = true })

-- A menu with a search: focused on the search pane and typing, the list narrowed by what is
-- typed, even when the keys come faster than the change events (`et<CR>` in one go), and
-- a choice still named by its index among all the items. While typing j/k type, and
-- <Down>/<Up> move the list. The pane keys walk search, list, preview, and arriving back
-- in the search pane types again. A resize keeps the search, and a search that finds
-- nothing leaves nothing to choose.
do
    local items = { "jam", "ajar", "beta" }
    local chosen
    -- Opened from a key, as a command is, so its start in insert mode is applied.
    function _G.tuna_open_search()
        chosen = nil
        widgets.menu(items, "a search", function(i)
            chosen = i
        end, nil, nil, {
            width = 40,
            content = function(i)
                return { title = items[i], lines = { "about " .. items[i] } }
            end,
        }, nil, nil, function(q)
            local out = {}
            for i, item in ipairs(items) do
                if item:find(q, 1, true) then
                    out[#out + 1] = i
                end
            end
            return out
        end)
    end
    -- One scenario is one key sequence, since `x` ends insert mode when its keys run
    -- out; `<Cmd>` probes along it record what was on screen at that point.
    local function keys(k)
        api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "x", false)
    end
    local function lines_of(title)
        for _, f in ipairs(floats()) do
            local t = api.nvim_win_get_config(f.win).title
            if t and vim.trim(t[1][1]) == title then
                return api.nvim_buf_get_lines(f.buf, 0, -1, false)
            end
        end
    end
    function _G.tuna_note()
        local title = api.nvim_win_get_config(0).title
        tuna_probe[#tuna_probe + 1] = (title and vim.trim(title[1][1]) or "?") .. " " .. api.nvim_get_mode().mode
    end
    local OPEN, NOTE = "<Cmd>lua tuna_open_search()<CR>", "<Cmd>lua tuna_note()<CR>"

    _G.tuna_probe = {}
    keys(OPEN .. NOTE .. "<Esc>")
    ok("a search menu opens on its search pane, typing", tuna_probe[1] == "Search i", tuna_probe[1])
    conforms("widgets.menu with a search")
    close_layer(80)

    keys(OPEN .. "et<CR>")
    ok("what is typed narrows the list before <CR> reads it, and the choice is the item's index", chosen == 3, chosen)

    keys(OPEN .. "j<Down><CR>")
    ok("while typing, j is typed and <Down> moves the list", chosen == 2, chosen)

    _G.tuna_probe = {}
    keys(OPEN .. NOTE .. "<C-j>" .. NOTE .. "<C-j>" .. NOTE .. "<C-k><C-k>" .. NOTE .. "be<Esc>")
    ok("the pane keys walk search, list and preview, and arriving back in the search pane types",
        vim.deep_equal(tuna_probe, { "Search i", "a search n", "jam n", "Search i" }), vim.inspect(tuna_probe))

    widgets.menu(nil)
    settle()
    ok("a resize keeps the search and the list it found", vim.deep_equal({ lines_of("Search"), lines_of("a search") }, { { "be" }, { "beta" } }),
        vim.inspect({ lines_of("Search"), lines_of("a search") }))

    chosen = nil
    keys("Szzz<CR><Esc>")
    ok("nothing found, nothing to choose", chosen == nil and lines_of("No match") ~= nil, vim.inspect({ chosen, #floats() }))
    close_layer(80)
end

-- A preview beside the list: the search and the list on the left, the panes stacked on the
-- right from the same top row, the whole the size it is given, centred as the runner UI's
-- grid is. A `fit` pane is as tall as the tallest content any item gives
-- it, and not drawn when none gives it any. The pane keys move
-- by position, across to the pane level with most of this one, and a resize keeps focus in
-- the pane it was in.
do
    local items = { "jam", "beta" }
    local notes = { jam = {}, beta = { "first", "second" } }
    function _G.tuna_open_beside(with_notes)
        widgets.menu(items, "a library", function() end, nil, nil, {
            beside = { width = 62, height = 17 },
            panes = { { title = "Notes", fit = true, wrap = true }, { title = "Glance", fit = true, readout = true }, {} },
            content = function(i)
                return {
                    { lines = with_notes and notes[items[i]] or {} },
                    { lines = { "O(1)" } },
                    { title = "code of " .. items[i], lines = { "about " .. items[i] } },
                }
            end,
        }, nil, nil, function()
            return { 1, 2 }
        end)
    end
    local function keys(k)
        api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "x", false)
    end
    local function win_of(title)
        for _, f in ipairs(floats()) do
            local t = api.nvim_win_get_config(f.win).title
            if t and vim.trim(t[1][1]) == title then
                return f.win
            end
        end
    end
    function _G.tuna_note()
        local title = api.nvim_win_get_config(0).title
        tuna_probe[#tuna_probe + 1] = (title and vim.trim(title[1][1]) or "?") .. " " .. api.nvim_get_mode().mode
    end

    keys("<Cmd>lua tuna_open_beside(true)<CR><Esc>")
    conforms("widgets.menu with panes beside")
    local search, list, pane, code = win_of("Search"), win_of("a library"), win_of("Notes"), win_of("code of jam")
    local function at(w)
        return api.nvim_win_get_position(w)
    end
    ok(
        "the search and the list on the left, the panes on the right from the same top row",
        at(search)[2] == at(list)[2] and at(pane)[2] > at(list)[2] and at(pane)[1] == at(search)[1] and at(code)[1] > at(pane)[1],
        vim.inspect({ at(search), at(list), at(pane), at(code) })
    )
    ok("a fitted pane is as tall as the tallest content any item gives it", api.nvim_win_get_height(pane) == 2, api.nvim_win_get_height(pane))
    local band_row, band_h = require("tuna.utils").float_band()
    local left, right = at(search)[2], at(pane)[2] + api.nvim_win_get_width(pane) + 2
    local top, bottom = at(search)[1], at(list)[1] + api.nvim_win_get_height(list) + 2
    ok(
        "the whole is the size given, borders included, centred as the runner UI's grid",
        vim.deep_equal(
            { right - left, bottom - top, left, top },
            { 62, 17, math.floor((vim.o.columns - 62) / 2 + 0.5), band_row + math.floor((band_h - 17) / 2 + 0.5) }
        ),
        vim.inspect({ right - left, bottom - top, left, top, vim.o.columns, band_row, band_h })
    )
    close_layer(80)

    _G.tuna_probe = {}
    keys("<Cmd>lua tuna_open_beside(true)<CR><Down><Cmd>lua tuna_note()<CR><C-l><Cmd>lua tuna_note()<CR><C-j><Cmd>lua tuna_note()<CR><C-h><Cmd>lua tuna_note()<CR><C-l><Cmd>lua tuna_note()<CR><C-h><C-k><Cmd>lua tuna_note()<CR><Esc>")
    ok(
        "the pane keys move by position: the search pane to the notes, down to the code, across to the list and back",
        vim.deep_equal(tuna_probe, { "Search i", "Notes n", "code of beta n", "a library n", "code of beta n", "Search i" }),
        vim.inspect(tuna_probe)
    )

    -- A readout is passed over: the notes and the code lead to each other, and the pane keys
    -- still lead out of it.
    _G.tuna_probe = {}
    keys("<C-l><C-j><C-k><Cmd>lua tuna_note()<CR>")
    vim.api.nvim_set_current_win(win_of("Glance"))
    keys("<C-j><Cmd>lua tuna_note()<CR>")
    ok("a readout pane is passed over and left", vim.deep_equal(tuna_probe, { "Notes n", "code of beta n" }), vim.inspect(tuna_probe))

    keys("<C-l><C-j>")
    widgets.menu(nil)
    settle()
    local title = api.nvim_win_get_config(0).title
    ok("a resize keeps focus in the pane it was in", title and vim.trim(title[1][1]) == "code of beta", vim.inspect(title))
    close_layer(80)

    keys("<Cmd>lua tuna_open_beside(false)<CR><Esc>")
    ok("a fitted pane no item gives anything is not drawn", win_of("Notes") == nil and win_of("code of jam") ~= nil)
    _G.tuna_probe = {}
    keys("<C-l><Cmd>lua tuna_note()<CR>")
    ok("and across, a readout level with the search pane is passed over too", tuna_probe[1] == "code of jam n", tuna_probe[1])
    close_layer(80)

    -- The user's cursorline: always on the list, which marks the selection, and on a pane
    -- only while it is the one being read. With it off, no pane has one.
    local user_cursorline = vim.go.cursorline
    for _, on in ipairs({ true, false }) do
        vim.go.cursorline = on
        keys("<Cmd>lua tuna_open_beside(true)<CR><Esc>")
        local function lit()
            return { vim.wo[win_of("a library")].cursorline, vim.wo[win_of("Notes")].cursorline, vim.wo[win_of("code of jam")].cursorline }
        end
        local before = lit()
        keys("<C-j><C-l>")
        local inside = lit()
        ok(
            ("cursorline %s: the list's always, a pane's only while it is read"):format(on and "on" or "off"),
            vim.deep_equal({ before, inside }, { { true, false, false }, { true, false, on } }),
            vim.inspect({ before, inside })
        )
        close_layer(80)
    end
    vim.go.cursorline = user_cursorline

    -- Closing any pane by hand closes the whole menu, as closing its list does, a notice too.
    keys("<Cmd>lua tuna_open_beside(true)<CR><Esc>")
    vim.api.nvim_win_close(win_of("Notes"), true)
    settle()
    ok("closing one of its panes closes the menu", #floats() == 0, #floats())
    widgets.menu({ "one" }, "a menu", function() end, nil, nil, nil, { title = "Know this", lines = { "first" } })
    settle()
    vim.api.nvim_win_close(win_of("Know this"), true)
    settle()
    ok("and so does closing its notice", #floats() == 0, #floats())

    -- The search pane is typed into again only if it was left typing.
    _G.tuna_probe = {}
    keys("<Cmd>lua tuna_open_beside(true)<CR><Esc><C-j><C-k><Cmd>lua tuna_note()<CR>i<C-j><C-k><Cmd>lua tuna_note()<CR><Esc>")
    ok(
        "the search pane is typed into again only if it was left typing",
        vim.deep_equal(tuna_probe, { "Search n", "Search i" }),
        vim.inspect(tuna_probe)
    )
    close_layer(80)

    -- Nothing a completion plugin offers is what a prompt is for: blink.cmp's switch is set,
    -- and nvim-cmp is told for the buffer, whether it is loaded already or loads on the
    -- prompt's own InsertEnter.
    local told = {}
    local fake_cmp = { setup = { buffer = function(c) told[#told + 1] = { vim.api.nvim_get_current_buf(), c.enabled } end } }
    package.loaded["cmp"] = fake_cmp
    keys("<Cmd>lua tuna_open_beside(true)<CR><Esc>")
    local sb = vim.api.nvim_win_get_buf(win_of("Search"))
    ok("a search pane turns completion off", vim.b[sb].completion == false and vim.deep_equal(told, { { sb, false } }), vim.inspect(told))
    close_layer(80)
    package.loaded["cmp"] = nil
    told = {}
    widgets.input("a path", "", function() end)
    settle()
    local ib = vim.api.nvim_get_current_buf()
    package.loaded["cmp"] = fake_cmp -- loaded by the InsertEnter it is told on
    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = ib })
    ok("and a prompt tells nvim-cmp once it loads", vim.deep_equal(told, { { ib, false } }), vim.inspect(told))
    package.loaded["cmp"] = nil
    close_layer(80)
end

-- With a global statusline a float starts from the bar of the window it opens over: a
-- statusline plugin that renders into each window (lualine) otherwise blanks the one bar
-- whenever a float takes focus.
local code = api.nvim_get_current_win()
local laststatus = vim.o.laststatus
vim.o.laststatus = 3
api.nvim_set_option_value("statusline", "CODE BAR", { scope = "local", win = code })
widgets.menu({ "one" }, "a menu", function() end)
settle()
local focused = api.nvim_get_current_win()
local bar = api.nvim_get_option_value("statusline", { win = focused })
ok("laststatus=3: a float starts with the statusline of the window it opened over", focused ~= code and bar == "CODE BAR", bar)
close_layer(80)
-- lualine draws the bar from a queue, so a copy, or the bar a float already holds, would show
-- for a moment as it takes focus: it is told to draw now instead, on opening and on every move
-- into a float, and nothing is copied.
do
    local asked = {}
    package.loaded["lualine"] = {
        refresh = function(opts)
            asked[#asked + 1] = opts.force == true and opts.scope == "window"
        end,
    }
    widgets.form({ { title = "one", items = { "a" } }, { title = "two", items = { "b" } } }, function() end)
    settle()
    local opened = #asked
    local copied = api.nvim_get_option_value("statusline", { win = api.nvim_get_current_win() }) == "CODE BAR"
    api.nvim_feedkeys(api.nvim_replace_termcodes("<C-j>", true, false, true), "x", false)
    settle()
    ok("with lualine, a float taking focus has it draw the bar at once, and copies none",
        opened >= 1 and #asked > opened and not vim.tbl_contains(asked, false) and not copied, vim.inspect({ opened, asked, copied }))
    close_layer(80)
    -- lualine's own refresh on a mode change passes the floats over, so tuna asks for it there too.
    widgets.input("a prompt", "", function() end)
    settle()
    asked = {}
    api.nvim_feedkeys("a" .. api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    settle()
    ok("with lualine, a mode change in a float has it draw the bar at once",
        #asked >= 2 and not vim.tbl_contains(asked, false), vim.inspect(asked))
    close_layer(80)
    package.loaded["lualine"] = nil
end
vim.o.laststatus = laststatus

ok("every float is tagged as tuna's before it is entered", #entered_untagged == 0, entered_untagged)

-- Otherwise a float draws no statusline of its own: from Neovim 0.12 a float whose
-- 'statusline' is set draws it inside its border unless the statusline is global.
do
    local surface = require("tuna.ui.surface")
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
