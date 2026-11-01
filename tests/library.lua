-- tests/library.lua
--
-- `:Tuna lib`: which files the library holds for a language (dotfiles and dot-directories
-- left out at every depth, `~` in `library.path` read as the home directory), the guarded
-- snippets inside a file, what the picker lists and how a search orders it (names and
-- files fuzzily, then code, spacing ignored), snippets of one name numbered, and a file
-- with an unclosed guard warned about once however often its preview is drawn.

local t = dofile("tests/harness.lua")
require("tuna").setup({})
local library = require("tuna.workspace.library")
local widgets = require("tuna.ui.widgets")

local root = t.tempdir()
for _, sub in ipairs({ "graphs", "graphs/.cache", ".git" }) do
    vim.fn.mkdir(root .. "/" .. sub, "p")
end
t.write(root, "fenwick.cpp", "// TUNALIB: add start\nvoid add() {}\n// TUNALIB: add end\n")
t.write(root .. "/graphs", "dsu.cpp", "// TUNALIB: dsu start\nint p[10];\n")
t.write(root .. "/graphs", ".scratch.cpp", "")
t.write(root .. "/graphs/.cache", "old.cpp", "")
t.write(root .. "/.git", "hook.cpp", "")
t.write(root, "notes.py", "")

-- `library.path` with a leading `~`, read against a home directory of the test's own.
local real_home = vim.uv.os_homedir
vim.uv.os_homedir = function()
    return vim.fs.dirname(root)
end
local cfg = vim.tbl_deep_extend("force", require("tuna.config").current_setup, {
    library = { path = "~/" .. vim.fn.fnamemodify(root, ":t") },
})
local files = vim.tbl_map(function(f)
    return f.rel
end, library.files(cfg, "cpp"))
vim.uv.os_homedir = real_home
t.eq("the library is read from ~ and lists its files of the language, no dotfiles at any depth", files, {
    "fenwick.cpp",
    "graphs/dsu.cpp",
})

local snips = library.parse({ "x", "// TUNALIB: add start", "void add() {}", "// TUNALIB: add end" }, "TUNALIB")
t.eq("a guarded region is a snippet", { snips[1].name, snips[1].lines, snips[1].first }, { "add", { "void add() {}" }, 3 })
local _, warning = library.parse({ "// TUNALIB: dsu start", "int p[10];" }, "TUNALIB")
t.has("an unclosed guard is reported", warning, "unclosed 'dsu' guard")

-- The comment block right under a start guard is the snippet's notes, in its own comment
-- syntax, ending at the first line that is not one; from `Complexity:` on, its complexity.
do
    local noted = library.parse({
        "    // TUNALIB: spf start",
        "    // Smallest prime factor of every number up to n",
        "    //",
        "    // Complexity: O(n log log n) to build,",
        "    // O(log n) per factorization",
        "    vector<int> spf;",
        "    // a comment in the code",
        "    // TUNALIB: spf end",
    }, "TUNALIB")[1]
    t.eq("the notes are read without their leader, an empty one kept, and are not code", {
        noted.notes,
        noted.lines,
        noted.first,
    }, {
        { "Smallest prime factor of every number up to n", "" },
        { "    vector<int> spf;", "    // a comment in the code" },
        6,
    })
    t.eq("the complexity runs from its line to the notes' end, however it was wrapped, unlabelled", noted.complexity, {
        "O(n log log n) to build,",
        "O(log n) per factorization",
    })
    local cut = library.parse({ "# TUNALIB: gcd start", "", "# not a note", "def gcd(): pass", "# TUNALIB: gcd end" }, "TUNALIB")[1]
    t.eq("a blank line ends them, in any language", { cut.notes, cut.complexity, cut.lines[2] }, { {}, {}, "# not a note" })
    local plain = library.parse({ "// TUNALIB: x start", "// Complexities: none", "int x;", "// TUNALIB: x end" }, "TUNALIB")[1]
    t.eq("only `Complexity:` starts the complexity", { plain.notes, plain.complexity }, { { "Complexities: none" }, {} })
end

-- What the picker lists, and what a search keeps of it, in order.
do
    local lib = t.tempdir()
    t.write(lib, "fenwick.cpp", table.concat({
        "// TUNALIB: fenwick start",
        "// Point update, range query",
        "struct Fenwick { int bit[10]; };",
        "// TUNALIB: fenwick end",
        "// TUNALIB: Fenwick 2D start",
        "int grid[10][10]; // range query",
        "// TUNALIB: Fenwick 2D end",
    }, "\n"))
    t.write(lib, "dsu.cpp", "// TUNALIB: dsu start\nint parent[10];\nint find(int x) { return parent [x] == x ? x : parent[x] = find(parent[x]); }\n// TUNALIB: dsu end\n")
    t.write(lib, "bexp.cpp", "// faster than a dsu\nlong long bexp(long long b, long long e) { return 1; }\n")
    local lcfg = vim.tbl_deep_extend("force", require("tuna.config").current_setup, { library = { path = lib } })
    local all = library._test.catalogue(lcfg, "cpp")
    local function found(query)
        return vim.tbl_map(function(i)
            return all[i].name
        end, library._test.rank(all, query))
    end
    t.eq("every snippet is listed by name, and a file with no guards whole", found(""), {
        "Fenwick 2D",
        "bexp.cpp",
        "dsu",
        "fenwick",
    })
    t.eq("a search matches names fuzzily, in either case", found("fnwk 2d"), { "Fenwick 2D" })
    t.eq("its words match in any order", found("2D FEN"), { "Fenwick 2D" })
    t.eq("and a file name finds what is in it", found("dsu.cpp"), { "dsu" })
    t.eq("code is matched after names, however it is spaced", found("parent[x] ==x"), { "dsu" })
    t.eq("a name match ranks above a code match", found("dsu"), { "dsu", "bexp.cpp" })
    t.eq("notes are matched after names and before code", found("range query"), { "fenwick", "Fenwick 2D" })
    t.eq("nothing found is an empty list", found("zzz"), {})
end

-- The picker reads every file once: a file with an unclosed guard warns once, however
-- often its preview is drawn and however the list is searched.
do
    require("tuna").setup({ library = { path = root } })
    t.write(root, "main.cpp", "")
    vim.cmd("edit " .. root .. "/main.cpp")
    local real_menu = widgets.menu
    widgets.menu = function(items, _, _, _, _, preview, opts)
        for _, q in ipairs({ "", "d", "ds", "dsu" }) do
            for _, i in ipairs(opts.search(q)) do
                preview.content(i)
            end
        end
        t.eq("the picker lists the snippets, and the files with none whole", #items, 3)
    end
    local quiet = vim.notify
    local said = t.capture_notifications()
    library.open()
    vim.notify, widgets.menu = quiet, real_menu
    t.eq("moving over a file with an unclosed guard warns once", #vim.tbl_filter(function(m)
        return m:find("unclosed") ~= nil
    end, said), 1)
end

-- The picker shows each entry's notes, complexity and code, beside the list, the complexity
-- in a pane of its own without its label; the two panes fit the longest there are.
do
    local lib = t.tempdir()
    t.write(lib, "sieve.cpp", "// TUNALIB: sieve start\n// Primes up to n\n// Complexity: O(n log log n)\nint p[10];\n// TUNALIB: sieve end\n")
    t.write(lib, "bexp.cpp", "long long bexp();\n")
    require("tuna").setup({ library = { path = lib, width = 0.5, height = 0.6 } })
    local work = t.tempdir()
    t.write(work, "main.cpp", "")
    vim.cmd("edit " .. work .. "/main.cpp")
    local real_menu, got = widgets.menu, nil
    widgets.menu = function(items, _, _, _, _, preview)
        got = { items = items, preview = preview }
    end
    library.open()
    widgets.menu = real_menu
    local pv = got.preview
    local cols, rows = require("tuna.utils").get_ui_size()
    t.eq("the picker is the size its options give it", pv.beside, {
        width = math.floor(cols * 0.5 + 0.5),
        height = math.floor(rows * 0.6 + 0.5),
    })
    -- Unset, the runner UI's, the other board tuna draws over the editor, however it is set.
    require("tuna").setup({ library = { path = lib }, popup_ui = { width = 0.7, height = 0.5 } })
    widgets.menu = function(_, _, _, _, _, preview)
        got = { preview = preview }
    end
    library.open()
    widgets.menu = real_menu
    t.eq("unset, it is the runner UI's size", got.preview.beside, {
        width = math.floor(cols * 0.7 + 0.5),
        height = math.floor(rows * 0.5 + 0.5),
    })
    t.eq("beside the list, notes and complexity that fit over the code", {
        vim.tbl_map(function(p)
            return { p.title, p.fit, p.wrap }
        end, pv.panes),
    }, { { { "notes", true, true }, { "complexity", true, true }, {} } })
    t.eq("and only the code is selected from", vim.tbl_map(function(p)
        return p.selectable == true
    end, pv.panes), { false, false, true })
    local sieve = pv.content(2)
    t.eq("an entry's notes, its complexity without the label, and its code", {
        sieve[1].lines,
        sieve[2].lines,
        sieve[3].lines,
    }, { { "Primes up to n" }, { "O(n log log n)" }, { "int p[10];" } })
    t.eq("and a whole file has neither", { pv.content(1)[1].lines, pv.content(1)[2].lines }, { {}, {} })
end

-- Snippets of one exact name are numbered in file and line order, a dimmed tag at the end of the
-- row and not in it, which goes wherever a search moves the snippet. A name of its own has none.
do
    local lib = t.tempdir()
    local function twin(body)
        return "// TUNALIB: twin start\n" .. body .. "\n// TUNALIB: twin end\n"
    end
    local many = {}
    for i = 1, 12 do
        many[i] = twin("int b" .. i .. ";")
    end
    t.write(lib, "a.cpp", twin("int a;"))
    t.write(lib, "b.cpp", table.concat(many))
    t.write(lib, "c.cpp", "// TUNALIB: Twin start\nint c;\n// TUNALIB: Twin end\n// TUNALIB: zone start\nint d;\n// TUNALIB: zone end\n")
    local lcfg = vim.tbl_deep_extend("force", require("tuna.config").current_setup, { library = { path = lib } })
    local all = library._test.catalogue(lcfg, "cpp")
    t.eq("a name of its own has no number, and names differing in case are two names", { all[1].name, all[1].version, all[#all].name, all[#all].version }, { "Twin", nil, "zone", nil })
    local order = {}
    for i = 2, #all - 1 do
        order[#order + 1] = ("%d %s"):format(all[i].version, vim.trim(all[i].lines[1]))
    end
    t.eq("the rest are numbered by file, then by line", { order[1], order[2], order[3], order[13] }, { "1 int a;", "2 int b1;", "3 int b2;", "13 int b12;" })
    local sorted = true
    for i = 2, #order do
        sorted = sorted and tonumber(order[i]:match("^%d+")) == i and order[i]:match("b(%d+)") == tostring(i - 1)
    end
    t.ok("in that order all the way down", sorted)

    local columns = vim.o.columns
    vim.o.columns = 200
    t.write(lib, "d.cpp", ("// TUNALIB: %s start\nint e;\n// TUNALIB: %s end\n"):rep(2):format(("x"):rep(30), ("x"):rep(30), ("x"):rep(30), ("x"):rep(30)))
    require("tuna").setup({ library = { path = lib, width = 1 } })
    local work = t.tempdir()
    t.write(work, "main.cpp", "")
    vim.cmd("edit " .. work .. "/main.cpp")
    library.open()
    local function pane(title)
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            local got = vim.api.nvim_win_get_config(win).title
            if got and vim.trim(got[1][1]) == title then
                return win
            end
        end
    end
    local list = pane("library")
    local buf = vim.api.nvim_win_get_buf(list)
    ---The list as drawn: each row's text, and its tag beside it in the tag's colour.
    local function rows()
        local out = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local ns = vim.api.nvim_get_namespaces().tuna_menu
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
            local chunk = m[4].virt_text[#m[4].virt_text]
            out[m[2] + 1] = ("%s + %s %s %s"):format(out[m[2] + 1], chunk[1], chunk[2], m[4].virt_text_pos)
        end
        return out
    end
    t.eq("a row holds the name, with the number dimmed after it", { rows()[1], rows()[2], rows()[3], rows()[4] }, {
        "Twin",
        "twin + (1) Comment eol",
        "twin + (2) Comment eol",
        "twin + (3) Comment eol",
    })
    t.eq("the list is wide enough for the number too", vim.api.nvim_win_get_width(list), 30 + 1 + 3 + 2)
    local search = vim.api.nvim_win_get_buf(pane("search"))
    vim.api.nvim_buf_set_lines(search, 0, -1, false, { "b.cpp" })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = search })
    t.eq("a search keeps each snippet's own number", { rows()[1], rows()[2] }, { "twin + (2) Comment eol", "twin + (3) Comment eol" })
    vim.api.nvim_buf_set_lines(search, 0, -1, false, { "zone" })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = search })
    t.eq("and a row taken over by a name of its own has none", rows(), { "zone" })
    vim.api.nvim_win_close(list, true)
    vim.o.columns = columns

    local untagged = { "plain", "plainer", "plainest" }
    widgets.menu(untagged, "No tags", function() end)
    t.eq("a menu after it has no tags of its own", vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(pane("No tags")), vim.api.nvim_get_namespaces().tuna_menu, 0, -1, {}), {})
    vim.api.nvim_win_close(pane("No tags"), true)
    widgets.menu({ ("y"):rep(30) }, "Tagged", function() end, nil, nil, nil, { tags = { "(12)" } })
    t.eq("and a menu with no search is as wide as its tags make it", vim.api.nvim_win_get_width(pane("Tagged")), 30 + 1 + 4 + 4)
    vim.api.nvim_win_close(pane("Tagged"), true)

    -- A tag follows its label until the two no longer fit, and then stays at the edge over
    -- the label, whose last cells fade towards it.
    local function drawn(label)
        widgets.menu({ label, "short" }, "Long", function() end, nil, nil, nil, { tags = { "(1)", "(2)" } })
        local list_win = pane("Long")
        local width, marks = vim.api.nvim_win_get_width(list_win), { fades = {} }
        local ns = vim.api.nvim_get_namespaces().tuna_menu
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(list_win), ns, 0, -1, { details = true })) do
            if m[4].virt_text then
                marks[m[2] + 1] = m[4].virt_text_pos
            elseif m[2] == 0 then
                marks.fades[#marks.fades + 1] = { m[3], m[4].end_col, m[4].hl_group }
            end
        end
        vim.api.nvim_win_close(list_win, true)
        return marks, width
    end
    local marks, width = drawn(("n"):rep(400))
    t.eq("a label that does not fit has its tag at the edge, a short one after it", { marks[1], marks[2] }, { "right_align", "eol" })
    local edge = width - 3 - 1
    t.eq("and fades over the cells before it, the last the faintest", marks.fades, {
        { edge - 6, edge - 5, "TunaFade1" },
        { edge - 5, edge - 4, "TunaFade2" },
        { edge - 4, edge - 3, "TunaFade3" },
        { edge - 3, edge - 2, "TunaFade4" },
        { edge - 2, edge - 1, "TunaFade5" },
        { edge - 1, edge, "TunaFade6" },
    })
    local accented = drawn(("é"):rep(400))
    t.eq("a character of two bytes fades whole", accented.fades[6], { (edge - 1) * 2, edge * 2, "TunaFade6" })
    local wide = drawn(("字"):rep(400))
    t.ok("and a cell count never lands inside a wide one", wide.fades[#wide.fades][2] % 3 == 0, wide.fades)
    -- Scrolled sideways the tag stays where it is, so the cells that fade are other ones.
    do
        widgets.menu({ ("n"):rep(400), "short" }, "Long", function() end, nil, nil, nil, { tags = { "(1)", "(2)" } })
        local list_win = pane("Long")
        local list_buf = vim.api.nvim_win_get_buf(list_win)
        vim.api.nvim_win_call(list_win, function()
            vim.fn.winrestview({ leftcol = 20 })
        end)
        vim.api.nvim_exec_autocmds("WinScrolled", { buffer = list_buf })
        local ns = vim.api.nvim_get_namespaces().tuna_menu
        local last
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(list_buf, ns, 0, -1, { details = true })) do
            if m[4].hl_group then
                last = m[3]
            end
        end
        t.eq("the fade follows a list scrolled sideways", last, 20 + edge - 1)
        vim.api.nvim_win_close(list_win, true)

        -- One cell too long, a little scrolling brings the end of the label into view.
        widgets.menu({ ("n"):rep(width - 3) }, "Long", function() end, nil, nil, nil, { tags = { "(1)" } })
        list_win = pane("Long")
        list_buf = vim.api.nvim_win_get_buf(list_win)
        vim.api.nvim_win_call(list_win, function()
            vim.fn.winrestview({ leftcol = 2 })
        end)
        vim.api.nvim_exec_autocmds("WinScrolled", { buffer = list_buf })
        local after = vim.api.nvim_buf_get_extmarks(list_buf, ns, 0, -1, { details = true })
        t.eq("and a label scrolled until it fits has its tag after it again, unfaded", { #after, after[1][4].virt_text_pos }, { 1, "eol" })
        vim.api.nvim_win_close(list_win, true)
    end
    -- Setting a highlight group redraws every window, so nothing does while nothing changes.
    do
        local real_set, sets = vim.api.nvim_set_hl, 0
        vim.api.nvim_set_hl = function(ns_id, name, val)
            sets = sets + (name:find("^TunaFade") and 1 or 0)
            return real_set(ns_id, name, val)
        end
        widgets.menu({ ("n"):rep(400), "short" }, "Long", function() end, nil, nil, nil, {
            tags = { "(1)", "(2)" },
            search = function(q)
                return q == "" and { 1, 2 } or { 2 }
            end,
        })
        local typed = vim.api.nvim_win_get_buf(pane("search"))
        local long_win = pane("Long")
        local long_buf = vim.api.nvim_win_get_buf(long_win)
        local ns = vim.api.nvim_get_namespaces().tuna_menu
        local real_mark, marked = vim.api.nvim_buf_set_extmark, 0
        vim.api.nvim_buf_set_extmark = function(...)
            marked = marked + 1
            return real_mark(...)
        end
        vim.api.nvim_exec_autocmds("WinScrolled", { buffer = long_buf })
        vim.api.nvim_buf_set_extmark = real_mark
        t.eq("a scroll that is not sideways draws nothing again", marked, 0)
        local calls, real_fades = 0, require("tuna").setup_fades
        require("tuna").setup_fades = function()
            calls = calls + 1
            return real_fades()
        end
        vim.api.nvim_buf_set_lines(typed, 0, -1, false, { "s" })
        vim.api.nvim_exec_autocmds("TextChangedI", { buffer = typed })
        t.eq("rows with nothing to fade read no colours", calls, 0)
        require("tuna").setup_fades = real_fades
        vim.api.nvim_set_hl = real_set
        t.eq("and a menu drawn on unchanged colours sets none", sets, 0)
        vim.api.nvim_win_close(long_win, true)
    end
    t.eq("a label that fits exactly keeps its tag after it", drawn(("n"):rep(width - 4))[1], "eol")
    t.eq("one cell more does not", drawn(("n"):rep(width - 3))[1], "right_align")
    -- A search draws the rows again, at the width the list still has.
    widgets.menu({ ("n"):rep(400), "short" }, "Long", function() end, nil, nil, nil, {
        tags = { "(1)", "(2)" },
        search = function(q)
            return q == "" and { 1, 2 } or { 1 }
        end,
    })
    local typed = vim.api.nvim_win_get_buf(pane("search"))
    vim.api.nvim_buf_set_lines(typed, 0, -1, false, { "n" })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = typed })
    local list_buf = vim.api.nvim_win_get_buf(pane("Long"))
    local found = vim.api.nvim_buf_get_extmarks(list_buf, vim.api.nvim_get_namespaces().tuna_menu, 0, -1, { details = true })
    t.eq("a list a search narrowed keeps its tag at the edge, fading", { #found, found[#found][4].virt_text_pos or found[1][4].virt_text_pos }, { 7, "right_align" })
    vim.api.nvim_win_close(pane("Long"), true)
end

-- A label fades into the float's own background, in the colours of the theme, and with a
-- transparent one there is nothing to mix with, so the name is just cut off.
do
    local function fade_after(normal, float)
        vim.cmd("highlight clear")
        vim.api.nvim_set_hl(0, "Normal", normal)
        vim.api.nvim_set_hl(0, "NormalFloat", float)
        require("tuna").setup_highlight_groups()
        return vim.api.nvim_get_hl(0, { name = "TunaFade1" }), vim.api.nvim_get_hl(0, { name = "TunaFade6" })
    end
    local first, last = fade_after({ fg = 0xffffff, bg = 0x000000 }, { bg = 0x000000 })
    t.ok("from close to the text towards the background, and the last still readable", first.fg > 0xc00000 and last.fg < 0x707070 and last.fg > 0x505050, { first.fg, last.fg })
    first = fade_after({ fg = 0xffffff, bg = 0x101010 }, { fg = 0xff0000, bg = 0x000000 })
    t.eq("the float's own colours decide", first.fg % 256, 0)
    first = fade_after({ fg = 0xffffff }, {})
    t.eq("with no background the name keeps its colour, cut off", { first.fg, first.link }, {})
    -- A float's colours are often set just after a colorscheme, with no event to say so.
    fade_after({ fg = 0xffffff, bg = 0x000000 }, { bg = 0x000000 })
    vim.api.nvim_set_hl(0, "NormalFloat", {})
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff })
    widgets.menu({ ("n"):rep(400) }, "Stale", function() end, nil, nil, nil, { tags = { "(1)" } })
    t.eq("a float gone transparent since is honoured as a label fades", vim.api.nvim_get_hl(0, { name = "TunaFade1" }).fg, nil)
    vim.api.nvim_set_hl(0, "TunaFade1", { fg = 0x123456 })
    vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0xffffff, bg = 0x000000 })
    require("tuna").setup_fades()
    t.eq("a group the user gave a colour stays theirs", vim.api.nvim_get_hl(0, { name = "TunaFade1" }).fg, 0x123456)
    vim.api.nvim_set_hl(0, "TunaFade3", { bold = true })
    require("tuna").setup_fades()
    t.eq("as does one with no colour at all", vim.api.nvim_get_hl(0, { name = "TunaFade3" }).bold, true)
    vim.api.nvim_set_hl(0, "NormalFloat", {})
    vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff })
    require("tuna").setup_fades()
    t.eq("on a transparent background too", vim.api.nvim_get_hl(0, { name = "TunaFade3" }).bold, true)
    vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0xffffff, bg = 0x000000 })
    require("tuna").setup_fades()
    t.ok("the others follow", vim.api.nvim_get_hl(0, { name = "TunaFade2" }).fg ~= nil)
    vim.api.nvim_win_close(vim.fn.win_getid(), true)
    vim.cmd("highlight clear")
    require("tuna").setup_highlight_groups()
end

-- A snippet goes in below the cursor at the indentation a line typed there would get, by the
-- buffer's own rules, not the cursor line's: the opening line of a block, and a blank line
-- inside it, have none, while what goes under them belongs a level deeper. Its own nesting is
-- kept, its blank lines stay blank, and one undo takes it all back.
do
    local quiet = vim.notify
    vim.notify = function() end
    local snippet = { name = "read graph", lines = { "    vector<int> g(n);", "", "    for (;;) {", "        read();", "    }" } }
    local function insert_at(lnum, opts)
        vim.cmd("enew!")
        vim.bo.cindent, vim.bo.expandtab, vim.bo.shiftwidth, vim.bo.tabstop = true, true, 4, 4
        for k, v in pairs(opts or {}) do
            vim.bo[k] = v
        end
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "void solve() {", "    ll n;", "", "}" })
        vim.cmd("let &undolevels = &undolevels")
        vim.api.nvim_win_set_cursor(0, { lnum, 0 })
        library.insert(snippet, vim.api.nvim_get_current_buf())
        return vim.api.nvim_buf_get_lines(0, lnum, lnum + #snippet.lines, false)
    end
    local inside = { "    vector<int> g(n);", "", "    for (;;) {", "        read();", "    }" }
    t.eq("from the line opening a block, a level inside it", insert_at(1), inside)
    t.eq("with the cursor on its first line", vim.api.nvim_win_get_cursor(0), { 2, 4 })
    vim.cmd("undo")
    t.eq("which one undo takes back", vim.api.nvim_buf_get_lines(0, 0, -1, false), { "void solve() {", "    ll n;", "", "}" })
    t.eq("from a blank line inside the block, the same", insert_at(3), inside)
    t.eq("from a statement in it, the same", insert_at(2), inside)
    t.eq("written with tabs where the buffer indents with them", insert_at(1, { expandtab = false })[1], "\tvector<int> g(n);")
    t.eq("by `indentexpr` over `cindent`", insert_at(1, { indentexpr = "8" })[1], "        vector<int> g(n);")
    t.eq("evaluated with the cursor on the line it indents", insert_at(1, { indentexpr = "line('.') == 2 ? 6 : 0" })[1], "      vector<int> g(n);")
    t.eq("and with no rule at all, the indentation of the line above", insert_at(3, { cindent = false })[1], "    vector<int> g(n);")
    vim.notify = quiet
end

t.report()
