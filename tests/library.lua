-- tests/library.lua
--
-- `:Tuna lib`: which files the library holds for a language (dotfiles and dot-directories
-- left out at every depth, `~` in `library.path` read as the home directory), the guarded
-- snippets inside a file, what the picker lists and how a search orders it (names and
-- files fuzzily, then code, spacing ignored), and a file with an unclosed guard warned
-- about once however often its preview is drawn.

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
    widgets.menu = function(items, _, _, _, _, preview, _, _, search)
        for _, q in ipairs({ "", "d", "ds", "dsu" }) do
            for _, i in ipairs(search(q)) do
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
    local defaults = require("tuna.config").defaults
    t.eq(
        "by default the runner UI's",
        { defaults.library.width, defaults.library.height },
        { defaults.popup_ui.total_width, defaults.popup_ui.total_height }
    )
    t.eq("beside the list, notes and complexity that fit over the code", {
        vim.tbl_map(function(p)
            return { p.title, p.fit, p.wrap }
        end, pv.panes),
    }, { { { "Notes", true, true }, { "Complexity", true, true }, {} } })
    local sieve = pv.content(2)
    t.eq("an entry's notes, its complexity without the label, and its code", {
        sieve[1].lines,
        sieve[2].lines,
        sieve[3].lines,
    }, { { "Primes up to n" }, { "O(n log log n)" }, { "int p[10];" } })
    t.eq("and a whole file has neither", { pv.content(1)[1].lines, pv.content(1)[2].lines }, { {}, {} })
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
