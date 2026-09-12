-- tests/temp.lua
--
-- `:Tuna temp`: the templates a scratch can start from, when a scratch is resumed rather
-- than started over, the template menu, and folding the scratch into a downloaded problem
-- under the header of the template that problem was actually written from.

local t = dofile("tests/harness.lua")

local tdir = t.tempdir()
t.write(tdir, "template.cpp", "// problem: $(PROBLEM)\n\nint main() {}\n")
t.write(tdir, "template.codeforces.cpp", "// problem: $(PROBLEM)\n// judge: $(JUDGE)\n\n#define CF\n")
t.write(tdir, "template.atcoder.cpp", "// problem: $(PROBLEM)\n\n#define AC\n")
t.write(tdir, "template.py", "# $(PROBLEM)\nprint()\n")
local sdir = t.tempdir()
require("tuna").setup({
    template_file = { tdir .. "/template.$(JUDGE).$(FEXT)", tdir .. "/template.$(FEXT)" },
    temp = { file = sdir .. "/scratch.$(FEXT)", extension = "cpp" },
})
local temp = require("tuna.temp")
local T = temp._test
local cfg = require("tuna.config").current_setup

--------------------------------------------------------------------------------
-- Which templates a scratch can start from
--------------------------------------------------------------------------------

-- No problem exists yet, so `$(JUDGE)` can't be filled in: it matches any judge, and each
-- judge's template is offered on its own, before the general one.
t.eq("every judge's template, then the general one", T.template_choices("cpp", cfg), {
    tdir .. "/template.atcoder.cpp",
    tdir .. "/template.codeforces.cpp",
    tdir .. "/template.cpp",
})
t.eq("only templates in the scratch's language", T.template_choices("py", cfg), { tdir .. "/template.py" })
t.eq("none configured, none offered", T.template_choices("cpp", vim.tbl_extend("force", cfg, { template_file = false })), {})

--------------------------------------------------------------------------------
-- Resumed or started over
--------------------------------------------------------------------------------

local scratch = sdir .. "/scratch.cpp"
t.eq("no scratch, nothing to resume", T.resumable(scratch), false)
t.write(sdir, "scratch.cpp", "  \n\n")
t.eq("an empty scratch is started over", T.resumable(scratch), false)
t.write(sdir, "scratch.cpp", "int x;\n")
t.eq("one with something written in it is resumed", T.resumable(scratch), true)
os.remove(scratch)

--------------------------------------------------------------------------------
-- The template menu
--------------------------------------------------------------------------------

local widgets = require("tuna.widgets")
local real_menu = widgets.menu
local asked
widgets.menu = function(items, _, on_choice, _, on_close, preview)
    asked = { items = items, choose = on_choice, dismiss = on_close, preview = preview }
end
local function lines_of(path)
    return vim.fn.readfile(path)
end

vim.cmd("enew")
temp.start()
t.eq("starting a scratch asks which template", asked and #asked.items, 4)
t.eq("with an empty file as the last choice", asked and asked.items[4], "Empty file")
t.eq("previewing the body the scratch would get", asked and asked.preview.content(2).lines, { "#define CF", "" })
asked.dismiss()
t.eq("dismissing it writes nothing", vim.uv.fs_stat(scratch), nil)

temp.start()
asked.choose(2)
t.eq("the chosen template's body becomes the scratch", lines_of(scratch), { "#define CF" })
t.eq("and it is opened", vim.fn.resolve(vim.api.nvim_buf_get_name(0)), vim.fn.resolve(scratch))

-- An existing scratch asks whether to resume it or restart, showing what it holds.
asked = nil
vim.cmd("enew")
temp.start()
t.eq("an existing scratch asks whether to resume or restart", asked and asked.items, { "Resume", "Restart" })
t.eq("showing what it holds", asked and asked.preview.lines, { "#define CF" })
asked.dismiss()
t.ok("dismissing it opens nothing", vim.fn.resolve(vim.api.nvim_buf_get_name(0)) ~= vim.fn.resolve(scratch))

temp.start()
asked.choose(1)
t.eq(
    "resuming reopens it as it is",
    { vim.fn.resolve(vim.api.nvim_buf_get_name(0)), vim.api.nvim_buf_get_lines(0, 0, -1, false) },
    { vim.fn.resolve(scratch), { "#define CF" } }
)

-- Asked in the same step as the choice, not after a redraw with no dialog on screen.
vim.cmd("enew")
temp.start()
asked.choose(2)
t.eq("restarting goes straight on to the template question", asked and asked.items[#asked.items], "Empty file")
asked.dismiss()
t.eq("dismissing that leaves the scratch as it was", lines_of(scratch), { "#define CF" })

temp.start()
asked.choose(2)
asked.choose(1)
t.eq("choosing a template starts the scratch over from it", lines_of(scratch), { "#define AC" })

-- Emptied by hand, it is started over, and the blank buffer still loaded out of sight is
-- replaced by what the new template writes rather than shown as it was.
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
vim.cmd("silent write")
vim.cmd("enew")
asked = nil
temp.start()
t.eq("an emptied scratch goes straight to the template question", asked and asked.items[#asked.items], "Empty file")
asked.choose(2)
t.eq("and gets the newly chosen template", vim.api.nvim_buf_get_lines(0, 0, -1, false), { "#define CF" })
widgets.menu = real_menu

--------------------------------------------------------------------------------
-- Folding the scratch into a downloaded problem
--------------------------------------------------------------------------------

-- The problem keeps the header of the template it was written from. The per-judge one here
-- has a longer header than the general template, which is the one `absorb` would otherwise
-- guess.
local pdir = t.tempdir()
t.write(pdir, "main.cpp", "// problem: A\n// judge: codeforces\n\n#define CF\n")
vim.cmd("edit " .. pdir .. "/main.cpp")
local problem_buf = vim.api.nvim_get_current_buf()
t.write(sdir, "scratch.cpp", "solve();\n")
local scratch_buf = vim.fn.bufadd(scratch)
vim.fn.bufload(scratch_buf)
temp.pending = { lines = { "solve();" }, row = 1, bufnr = scratch_buf }
vim.api.nvim_set_current_buf(problem_buf)
temp.absorb(pdir .. "/main.cpp", cfg, tdir .. "/template.codeforces.cpp")
t.eq("absorbing keeps the header of the template actually used", lines_of(pdir .. "/main.cpp"), {
    "// problem: A",
    "// judge: codeforces",
    "",
    "solve();",
})
t.eq("and removes the scratch", vim.uv.fs_stat(scratch), nil)

vim.fn.delete(tdir, "rf")
vim.fn.delete(sdir, "rf")
vim.fn.delete(pdir, "rf")
t.report()
