# tuna.nvim

```
  ██████████  ███    ███  ███     ███     ██████   
  ██████████  ███    ███  ████    ███    ███  ███  
    ███      ███    ███  ███ ██  ███   ███    ███  
    ███      ███    ███  ███  ██ ███  ████████████ 
   ███      ██████████  ███   █████  ███      ███  
   ███       ████████   ███     ███  ███      ███  
```

<div align="center">

**Competitive programming in Neovim.** Download a problem, run it against its
testcases, stress-test it against a brute force, submit it — without leaving the editor.

![Neovim](https://img.shields.io/badge/NeoVim-0.10+-%2357A143.svg?&style=for-the-badge&logo=neovim)
![Lua](https://img.shields.io/badge/Lua-%232C2D72.svg?style=for-the-badge&logo=lua)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)

</div>

---

`tuna.nvim` is a ground-up rewrite of and successor to
[competitest.nvim](https://github.com/xeluxee/competitest.nvim), which is no longer
actively maintained. It keeps what that plugin got right — testcase management,
[Competitive Companion](https://github.com/jmerle/competitive-companion) integration, a
results UI — and rebuilds it on modern Neovim APIs (`vim.system`, `vim.uv`, native
floats, no `nui.nvim` dependency), then goes well past it: stress testing, interactive
problems, special judges, multiple solution versions, submission, a snippet library, and
a dashboard to tie them together.

If you are coming from competitest, [`DIFFERENCES.md`](DIFFERENCES.md) records every
place tuna deliberately does something else, and why.

## Requirements

- **Neovim 0.10+** (tuna uses `vim.system()` and `vim.uv`)
- A compiler or interpreter for the languages you use — nothing is bundled
- Optional: the [Competitive Companion](https://github.com/jmerle/competitive-companion)
  browser extension, to download problems and contests
- Optional: [toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim) for the submit
  terminal, [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) for the download
  and verdict indicators, [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
  for `:Tuna lib search`

No plugin is required. Every optional integration is detected at runtime and its feature
falls back to something native when it is absent.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "FrancescoDerme/tuna.nvim",
    -- `setup()` registers `:Tuna`, so a lazy-load key or `cmd = "Tuna"` works too.
    opts = {},
}
```

Or, with any manager:

```lua
require("tuna").setup({})
```

`setup()` is what registers the `:Tuna` command, the highlight groups and the autocommands,
so it has to run. Called with no arguments it uses the defaults, which are chosen to work
for C/C++/Rust/Java/Python out of the box.

## Quick start

```vim
:Tuna
```

Bare `:Tuna` opens the dashboard: on the left, the contest and problem you were last
working on, each with how it went; on the right, everything tuna can do from the file you
are in. Both columns are lists — `j`/`k` to move, `<CR>` to act, `<C-h>`/`<C-l>` (or Tab)
to switch between them.

The loop it exists to serve:

1. **`:Tuna download problem`** — then press the green **+** in Competitive Companion.
   The solution file is created from your template, the testcases are written beside it,
   Neovim moves into the problem's directory, and the file opens. (Set `template_cursor`
   and it opens with the cursor already where you start typing, rather than on the
   template's header.)
2. **`:Tuna run`** — compiles, runs the testcases in parallel (as many at once as you
   have cores, by default), and opens the results grid. `j`/`k` walks the testcases, the
   four panes show output, expected output, input and stderr, and `d` toggles a
   positional diff of the two that disagree.
3. Wrong answer? Edit the **Input** or **Expected Output** pane in place and `:w` — it
   saves the testcase and re-runs it. `n` adds a testcase, `x` deletes one, `u` undoes
   that.
4. **`:Tuna submit`** — hands the solution to whichever submit tool you have configured,
   reads that tool's output as it runs, and puts the judge's verdict in your statusline
   (`Running (on test 6)` → `Accepted`) instead of a terminal you have to go and look at.
   The verdict stays there until you submit again, survives a restart, and disappears the
   moment you edit the solution.

Nothing above needs a testcase to exist first: `:Tuna run` on a file with none simply
builds it and runs it on empty input, as an editable row you can type the first testcase
straight into.

## Acknowledgements

A massive thank you to [xeluxee](https://github.com/xeluxee) and all the contributors to
`competitest.nvim` for the great work this is built on the shoulders of.
