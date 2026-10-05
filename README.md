<div align="center">

![Neovim](https://img.shields.io/badge/NeoVim-0.10+-%2357A143.svg?&style=for-the-badge&logo=neovim)
![Lua](https://img.shields.io/badge/Lua-%232C2D72.svg?style=for-the-badge&logo=lua)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)

</div>

https://github.com/user-attachments/assets/7f2523ab-8bc1-46eb-9e54-11b80cae18d1

tuna.nvim is a competitive programming plugin that integrates with [Competitive Companion](https://github.com/jmerle/competitive-companion) to download contests, runs your solution against testcases, supports stress testing, and much more.

## Requirements

- Neovim 0.10+
- A compiler or interpreter for the languages you use
- Optional: the [Competitive Companion](https://github.com/jmerle/competitive-companion) browser extension, to download problems and contests
- Optional: [toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim) for the submit terminal, [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) for the download and verdict indicators, [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for searching the library

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "FrancescoDerme/tuna.nvim",
    config = function()
        require("tuna").setup({})
    end,
}
```

With [vim.pack](https://neovim.io/doc/user/pack/):

```lua
vim.pack.add({ "https://github.com/FrancescoDerme/tuna.nvim" })
require("tuna").setup({})
```

## Quick start

1. **[`:Tuna`](REFERENCE.md#menu)** opens the menu.
2. **[`:Tuna download problem`](REFERENCE.md#download)** starts listening for a problem from Competitive Companion: press the green plus in your browser to download it.
   A solution file is created from your `template_file` (once you set one), the testcases are written beside it, and the file opens.
3. **[`:Tuna run`](REFERENCE.md#run)** compiles, runs the testcases in parallel, and opens the runner UI.
   The four panes show output, expected output, input and stderr.
   This UI can do a lot, for example `d` toggles a diff of the two outputs.
4. **[`:Tuna submit`](REFERENCE.md#submit)** hands the solution to whichever submit tool you have configured, reads that tool's output as it runs, and puts the judge's verdict in your statusline.
5. **[`:Tuna pin`](REFERENCE.md#pin)** and **[`:Tuna last`](REFERENCE.md#last)** help you move between problems as you upsolve, and **[`:Tuna clean`](REFERENCE.md#clean)** keeps your directories tidy.

## Features

You can find a complete list of the commands in [REFERENCE.md](REFERENCE.md), along with a detailed explanation of how each one works.
Here we aim to describe the most important features along with some basic workflows.

### Testcases

Testcases live on disk beside your solution, as a pair of text files each by default.

The file-name format in which testcases are written and discovered can be set in `testcases_input_file_format`, which accepts modifiers such as `$(FNOEXT)` and `$(TCNUM)`.
It is a list of names: writing a testcase uses the first entry in the list, and discovering one tries the entries in order, the first that finds anything wins:

```lua
testcases_input_file_format = { "$(FNOEXT)_input$(TCNUM).txt", "input$(TCNUM).txt", "in.txt" }
```

Where the testcases are stored can be set in `testcases_directory`: it's relative to the source by default, but can be an absolute path unrelated to the problem.

Add, edit, and delete testcases with [`:Tuna testcase add|edit|delete`](REFERENCE.md#testcase). This can also be done in place in the runner UI, which is usually where you want to be.
[`:Tuna testcase split`](REFERENCE.md#testcase-split) breaks one testcase into several: mark the cases inside it with a line of `-`, and each bracketed region becomes a testcase of its own.

### Running and the runner UI

`:Tuna run` compiles (if necessary), runs every testcase in parallel (as many at once as you have cores, by default) and opens the runner UI.
You can also open the runner UI by [`:Tuna show_ui`](REFERENCE.md#show_ui).

<img width="1920" height="1080" alt="runner UI" src="https://github.com/user-attachments/assets/f6f51cc6-52cc-4d59-b5ea-e5047aebca1d" />

The whole grid is defined in `popup_ui.layout`, you can arrange it differently or move to `runner_ui.interface = "split"` for real windows instead of floats.

Each testcase is a row, and the compile step is a row too that shows warnings and errors if there are any, customizable at `runner_ui.compile_layout`.

The runner UI can do a lot, but it aims to stay intuitive by aligning to Neovim's defaults: the panes with a purple border are editable, and keys behave in them as in any buffer.
From the read-only panes you can:

- toggle the diff view with `d`,
- rerun a testcase or all of them with `r` and `<C-r>`,
- add or delete a testcase with `n` and `x`,
- and more.

Each pane opens full-screen with the key in the pane's title, and `<C-hjkl>` move you between panes, also customizable.

Comparison between Output and Expected Output is driven by `output_compare_method`: `"exact"`, `"squish"` (whitespace-insensitive, the default), `{ "float", tol = 1e-6 }` for problems with a tolerance, or a function of your own.
[`:Tuna compare <method>`](REFERENCE.md#compare) overrides it for one problem.

### Run modes and scaffolding

`:Tuna run` can do four different things based on helper programs discovered by filename beside your solution.

| you write           | `:Tuna run` becomes  | what happens                                                                                                                         |
| ------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| nothing             | normal               | run your solution against every testcase                                                                                             |
| `gen.*` + `brute.*` | stress test          | generate an input, run your solution and the bruteforce, compare the outputs, repeat until they disagree and save the counterexample |
| `interactor.*`      | interactive          | run your solution against the interactor                                                                                             |
| `checker.*`         | _(any of the above)_ | a special judge decides correctness instead of string comparison                                                                     |

Interactive mode is not tied to having an interactor present, in fact it has three sources that can provide the input: `live` (you), `interactor` (your interactor program) and `feed` (a stored testcase).

Every helper is found the same way: a file named after it beside your solution (with the names in the table above or those specified in `tool_names`), or one of your own that you point to with its option (`checker`, `stress.generator`, `stress.bruteforce` or `interactive.interactor`), which can be specified in a `.tuna.lua` file beside the solution.

The run mode, interactive's source and the checker are decided based on the helpers present until you force them: `:Tuna run <mode>` forces a mode, `:Tuna run interactive <source>` a source, [`:Tuna checker off`](REFERENCE.md#checker) plain comparison, and `auto` hands any of them back.

[`:Tuna scaffold checker|generator|bruteforce|interactor`](REFERENCE.md#scaffold) drops in a starter file, named as `tool_names` says, in your solution's language, or in the language configured at `scaffold.language` (for example, you may want to have a `py` bruteforce even if you are coding in `cpp`).
Tuna ships `cpp` and `py` starters in its `scaffolds/` folder, and a file of the same name in your `scaffold.directory` (by default `tuna/scaffolds` in your Neovim config) is used instead, so you can customize a starter or add a new language by simply dropping a file there.

Finally, when several solutions are present in one folder, `:Tuna run all` runs every one of them against the same testcases.

### Downloading and scratch

With [Competitive Companion](https://github.com/jmerle/competitive-companion) installed, `:Tuna download problem` (or `contest`, or `testcases`) opens a listener, pressing the green plus in the browser does the rest.
`:Tuna download persistently` leaves the listener open for a whole session.

Where things land is decided by a path template, evaluated per problem:

```lua
downloaded_problems_path      = "$(HOME)/cp/$(JUDGE)/$(PROBLEM)/main.$(FEXT)",
downloaded_contests_directory = "$(HOME)/cp/$(JUDGE)/$(CONTEST)",
```

`$(JUDGE)` and `$(CONTEST)` come from tuna's own parsing of what Competitive Companion sends, and you can override it per judge with `judge_parsers`.
Codeforces and AtCoder are normalized out of the box, including Codeforces' mirror hosts: tuna rewrites the URL to the main site so links still work after the contest is over and keeps the mirror for submitting while the round is live.

New files are created from `template_file`, with the problem's own details filled in for these placeholders:

```cpp
// judge:   $(JUDGE)
// contest: $(CONTEST)
// problem: $(PROBLEM)
// submit at: $(URL)
```

The `template_file` option takes a single path, a per-extension table, or an ordered list tried until one exists, which is what makes a per-judge template practical:

```lua
template_file = { "~/cp/template.$(JUDGE).cpp", "~/cp/template.cpp" },
```

When entering a contest, some judges, like AtCoder, place you in the problems page, from which pressing the green plus is convenient.
Others, like Codeforces, place you inside the first problem, so going to the problems page to download the contest at the start of the competition would lose precious seconds.
To solve this, when dealing with judges of the second type, you can create a scratch file via `:Tuna scratch`.
A scratch file also follows your template, and you can solve and submit the easiest problem of the contest in it (there are no testcases for tuna to run, and submitting won't work unless you add the problem's URL in a `// submit at:` header line, which defeats the purpose of being fast).
After having solved this problem, you can download the rest of the contest with `:Tuna download sync`, which folds your scratch into the first problem's file.

### Submitting

`:Tuna submit` hands the solution to a submit tool of your choosing and reads its output as it runs, so the judge's verdict arrives in your statusline:

```lua
submit = {
    command = 'cf submit "$(URL)" "$(LANG)" "$(FABSPATH)"',
    languages = { cpp = "C++", python = "Python 3" },
},
```

A downloaded problem knows the correct URL to submit at (even without the header line), while a hand-made one becomes submittable the moment you add a `// submit at:` line with the correct URL into its header.

`submit.judges.<judge>` overrides the submission tool per judge.
The `browser` provider exists for judges for which you don't have a submission tool: it opens the submit page with the task preselected and puts your source on the clipboard.

For a working setup of a submit tool see [here](https://github.com/FrancescoDerme/dotfiles/blob/master/nvim/.config/nvim/lua/plugins/tuna.lua).
In this example, the submission tool is [`submitter`](https://github.com/EgorKulikov/submitter).

A step-by-step guide on setting this up, from pointing tuna at your tool to reading the verdict, is in the [reference](REFERENCE.md#submitting).

### Getting around

- [`:Tuna next`](REFERENCE.md#next-and-prev) / [`:Tuna prev`](REFERENCE.md#next-and-prev) step between the problems of a contest.
- `:Tuna last problem` / `:Tuna last contest` go back to what you were working on.
  The menu also provides access to your recent contests and problems.
- `:Tuna pin` puts the problem you are on aside to solve later, and pinning it again lets it go.
  The menu provides access to your pinned problems.

### Cleaning

`:Tuna clean` removes files you created and never used (or the ones you only slighly modified, with a tolerance the command asks for when you run it), and then the directories they leave empty.
Every deletion is confirmed one at a time, with the file in front of you.

<img width="1920" height="1080" alt="clean" src="https://github.com/user-attachments/assets/de4f558c-9fe4-41e5-a002-70031b36f2d2" />

### Your algorithms library

[`:Tuna lib`](REFERENCE.md#lib) copies a piece of your own library into the file you are writing.
The library is plain source files in the folder `library.path` points at, with the parts worth copying marked in place:

```cpp
// TUNALIB: binary exp start
long long bexp(long long b, long long e, long long m) { ... }
// TUNALIB: binary exp end
```

Only files matching the current buffer's extension are offered.
`:Tuna lib snippet` lists every snippet at once, `:Tuna lib search` opens the same catalogue in telescope.

### Keymaps

Keymaps make the tuna experience much better.
You can opt-in to the default keymaps with one line: `keymaps = { preset = "<leader>t" }` gives `<leader>tr` run, `<leader>tu` runner UI, `<leader>ts` submit, `<leader>tn`/`<leader>tp` problem navigation, `<leader>tdc` download a contest and `<leader>tds` sync, `<leader>tf` pin, `<leader>tl` the library, `<leader>tw` the scratch, `<leader>tm` the menu, and more.
You can edit or drop any of them without giving up the rest.

### Statusline

Two optional [lualine](https://github.com/nvim-lualine/lualine.nvim) components can make for a better experience: the download listener indicator and the current problem's submit verdict.

Every tuna window has the filetype `tuna`.
Listing it in lualine's `ignore_focus` keeps the statusline describing the file underneath while a tuna window has focus.

```lua
require("lualine").setup({
    options = {
        ignore_focus = { "tuna" },
    },
    sections = {
        lualine_x = {
            {
                function() return require("tuna").lualine_component() end,
                cond = function() return require("tuna.download").is_downloading() end,
            },
            {
                function() return require("tuna.submit").status() end,
                cond = function() return require("tuna.submit").is_submitting() end,
                color = function() return require("tuna.submit").status_hl() end,
            },
        },
    },
})
```

## Configuration

Everything is optional: `setup()` takes a table shaped like the defaults, and anything you leave out keeps its default.

```lua
require("tuna").setup({
    compile_command = {
        cpp = { exec = "g++", args = { "-std=c++20", "-O2", "-Wall", "$(FNAME)", "-o", "$(FNOEXT)" } },
    },
    maximum_time = 3000,
    template_file = { "~/cp/template.$(JUDGE).cpp", "~/cp/template.cpp" },
    downloaded_problems_path = "$(HOME)/cp/$(JUDGE)/$(PROBLEM)/main.$(FEXT)",
    keymaps = { preset = "<leader>t" },
})
```

[This](https://github.com/FrancescoDerme/dotfiles/blob/master/nvim/.config/nvim/lua/plugins/tuna.lua) is an example of a complete configuration.

Settings can also live in a `.tuna.lua` in any folder above the file you are editing.
This way a contest can set its own time limit, template or testcase layout without touching your config.

You can find more information on how to customize your configuration in the [reference](REFERENCE.md#configuration), and every option is commented in [`lua/tuna/config.lua`](lua/tuna/config.lua).

## Acknowledgements

tuna.nvim is a ground-up rewrite of and successor to [competitest.nvim](https://github.com/xeluxee/competitest.nvim), which is no longer maintained.
A massive thank you to [xeluxee](https://github.com/xeluxee) and all the contributors to competitest.nvim for their great work.
