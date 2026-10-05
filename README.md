<div align="center">

![Neovim](https://img.shields.io/badge/NeoVim-0.10+-%2357A143.svg?&style=for-the-badge&logo=neovim)
![Lua](https://img.shields.io/badge/Lua-%232C2D72.svg?style=for-the-badge&logo=lua)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)

</div>

https://github.com/user-attachments/assets/7f2523ab-8bc1-46eb-9e54-11b80cae18d1

`tuna.nvim` is a competitive programming plugin that intregrates with [Competitive companion](https://github.com/jmerle/competitive-companion) to download contests, runs your solution against testcases, supports stress testing, and much more.

## Requirements

- **Neovim 0.10+**
- A compiler or interpreter for the languages you use
- Optional: the [Competitive companion](https://github.com/jmerle/competitive-companion)
  browser extension, to download problems and contests
- Optional: [toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim) for the submit
  terminal, [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) for the download
  and verdict indicators, [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
  for searching the library

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
{
    vim.pack.add({ 'https://github.com/FrancescoDerme/tuna.nvim' })

    require("tuna").setup({})
}
```

## Quick start

1. **[`:Tuna`](REFERENCE.md#menu)** opens the menu,
2. **[`:Tuna download problem`](REFERENCE.md#download)** begins listening for a problem from Competitive companion,
   press the green plus in your browser to download.
   A solution file is created from your template, the testcases are written beside it,
   Neovim moves into the problem's directory, and the file opens.
3. **[`:Tuna run`](REFERENCE.md#run)** compiles, runs the testcases in parallel, and opens the runner UI.
   The four panes show output, expected output, input and stderr. This UI can do a lot,
   for example `d` toggles a diff of the two outputs.
4. **[`:Tuna submit`](REFERENCE.md#submit)** hands the solution to whichever submit tool you have configured,
   reads that tool's output as it runs, and puts the judge's verdict in your statusline.
5. **[`:Tuna pin`](REFERENCE.md#pin)**, **[`:Tuna last`](REFERENCE.md#last)**, and **[`:Tuna clean`](REFERENCE.md#clean)** facilitate moving around to upsolve problems and keeping your directory clean.

## Features

You can find a complete list of the commands in [REFERENCE.md](REFERENCE.md), along with a detailed explanation of how each one works. Here we aim to describe the most important features and some basic workflows.

### Testcases

Testcases live on disk beside your solution, in one of three storage formats.

The file-name format in whcih testcases are written and discovered can be set in `testcases_input_file_format`, which accepts modfiers such as `$(FNOEXT)` and `$(TCNUM)`. Where the testcases are stored can be set in `testcases_directory`, it's relative to the source by default, but can be set to an absolute path unreleted to the problem.

The default `files` format is a list, tried in order, and the first that finds
anything wins:

```lua
testcases_input_file_format = { "$(FNOEXT)_input$(TCNUM).txt", "input$(TCNUM).txt", "in.txt" }
```

Add, edit and delete them with [`:Tuna testcase add|edit|delete`](REFERENCE.md#testcase), or in place in the
results UI, which is usually where you want to be. [`:Tuna testcase split`](REFERENCE.md#testcase-split) breaks
one testcase into several: mark the cases inside it with a line of `-`, and each bracketed
region becomes a testcase of its own.

### Running and the runner UI

`:Tuna run` compiles, runs every testcase in parallel (as many at once as you have
cores, by default) and opens the runner UI. You can also open this UI by [`:Tuna show_ui`](REFERENCE.md#show_ui).

<img width="1920" height="1080" alt="runner UI" src="https://github.com/user-attachments/assets/f6f51cc6-52cc-4d59-b5ea-e5047aebca1d" />

The whole grid is defined in `popup_ui.layout` as a nested `{ weight, pane }` tree, you can
arrange it differently or move to `runner_ui.interface = "split"` for real windows
instead of floats.

Each testcase is a row, and the compile step is a row too that shows warnings and errors if there are any, customizable at `runner_ui.compile_layout`.

The runner UI can do a lot, but it aims to stay intuitive by aligning to Neovim's defaults: purple panes are editable and any key behaves on them as it would on a normal buffer. From blue panes you can:

- toggle the diff view with `d`,
- rerun a testcase or all of them with `r` and `<C-r>`,
- add or delete a testcase with `n` and `x`,
- and more.

Each pane opens full-screen with the key in the pane's title, and `<C-hjkl>` move you between panes.

Comparison between Outout and Expected Outout is driven by `output_compare_method`: `"exact"`, `"squish"` (whitespace-insensitive, the
default), `{ "float", tol = 1e-6 }` for problems with a tolerance, or a function of your
own. [`:Tuna compare <method>`](REFERENCE.md#compare) overrides it for one problem, and remembers.

### Run modes and scaffolding

`:Tuna run` can do four different things based on helper programs discovered
by filename beside your solution.

| you write           | `:Tuna run` becomes  | what happens                                                                                                                               |
| ------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| nothing             | normal               | run your solution against every testcase                                                                                                   |
| `gen.*` + `brute.*` | stress test          | generate an input, run your solution and stress, compare the outputs, repeat until they disagree and save the counterexample as a testcase |
| `interactor.*`      | interactive          | run your solution against the interactor                                                                                                   |
| multiple solutions  | run all              | run every solution against the testcases                                                                                                   |
| `checker.*`         | _(any of the above)_ | a special judge decides correctness instead of string comparison                                                                           |

Every helper is found the same way: a file named after it beside your solution (with the names in the table above or those specified in `tool_names`), or one of your own that you point to with its option (`checker`, `stress.generator`, `stress.bruteforce` or `interactive.interactor`), which wins over the file, which can be specified in a `.tuna.lua` file beside the solution.

The run mode, interactive's source and the checker are decided based on the helpers present until you force
them: `:Tuna run <mode>` forces a mode, `:Tuna run interactive <source>` a source,
[`:Tuna checker off`](REFERENCE.md#checker) plain comparison, and `auto` hands any of them back.

[`:Tuna scaffold checker|generator|bruteforce|interactor`](REFERENCE.md#scaffold) drops in a starter
file, named as `tool_names` says, in your solution's language,
or in the one configured at `scaffold.language`. Tuna ships `cpp` and `py` starters in its `scaffolds/` folder, and a file of
the same name in your `scaffold.directory` (by default `tuna/scaffolds` in your Neovim config)
is used instead, so you can customize a starter or add a new language by simply dropping a file there.

Note that the iteractive mode functions with three possible sources: `live` (you),
`interactor` (your interactor program), and `feed` (a stored testcase).

### Downloading and scratch

With [Competitive Companion](https://github.com/jmerle/competitive-companion) installed,
`:Tuna download problem` (or `contest`, or `testcases`) opens a
listener, pressing the green + in the browser does the rest. `:Tuna download
persistently` leaves it open for a whole session.

Where things land is a path template, evaluated per problem:

```lua
downloaded_problems_path      = "$(HOME)/cp/$(JUDGE)/$(PROBLEM)/main.$(FEXT)",
downloaded_contests_directory = "$(HOME)/cp/$(JUDGE)/$(CONTEST)",
```

`$(JUDGE)` and `$(CONTEST)` come from tuna's own parsing of what Competitive Companion sends, and
you can override it per judge with `judge_parsers`. Codeforces and AtCoder are normalized out of
the box, including Codeforces' mirror hosts, whose pages carry no per-problem URL and
no contest name: tuna rewrites the URL to the main site so the link in your header still
works after the mirror contest is over and keeps the mirror for submitting while the round is live.

New files are created from `template_file`, with the problem's own details filled in:

```cpp
// judge:   $(JUDGE)
// contest: $(CONTEST)
// problem: $(PROBLEM)
// submit at: $(URL)
```

The `template_file` option takes a single path, a per-extension table, or an ordered list tried until
one exists, which is what makes a per-judge template practical:

```lua
template_file = { "~/cp/template.$(JUDGE).cpp", "~/cp/template.cpp" },
```

When entering a contest, some judges, like AtCoder, place you in the problems page, from which pressing the green + is convenient. Others, like Codeforces, place you inside the first problem, so going to the problems page to download the contest at the start of the competition would lose precious seconds. To solve this, when dealing with judges of the second type, you can create a scratch file with `:Tuna scratch`. A scratch file also follows your template, and the idea is that you can solve and submit the easiest problem of the contest in it (`tuna`'s submit facilities won't work since you haven't downloaded it via Competitive Companion, nor you will have testcases for `tuna` to run). After having solved this problem, you can download the rest of the contest with `:Tuna download sync`, which will replace the first problem's file with the contents of your scratch.

### Submitting

`:Tuna submit` hands the solution to a submit tool of your choosing and reads its output
as it runs, so the judge's verdict arrives in your statusline:

```lua
submit = {
    command = 'cf submit "$(URL)" "$(LANG)" "$(FABSPATH)"',
    languages = { cpp = "C++", python = "Python 3" },
},
```

A downloaded problem knows the correct URL to submit at, while a hand-made one becomes submittable the moment you paste a URL into
its header.

`submit.judges.<judge>` overrides the submission tool per judge. The `browser` provider
exists for judges for which you dont have a submission tool: it opens the submit page with the task preselected and puts
your source on the clipboard.

For a working setup of a submit tool see [here](https://github.com/FrancescoDerme/dotfiles/blob/master/nvim/.config/nvim/lua/plugins/tuna.lua). Here, a [`subwithoutcred`](https://github.com/FrancescoDerme/dotfiles/blob/master/scripts/.local/bin/subwithoutcred) command was declared as a wrapper around the real tool, which is [`submitter`](https://github.com/EgorKulikov/submitter).

### Getting around

- [`:Tuna next`](REFERENCE.md#next-and-prev) / [`:Tuna prev`](REFERENCE.md#next-and-prev) step between the problems of a contest, preferring the same
  file name you are leaving (`A/main.cpp` → `B/main.cpp`).
- `:Tuna last problem` / `:Tuna last contest` go back to what you were working on, across
  restarts. The menu also provides access to your recent
  contests and problems.
- `:Tuna pin` puts the problem you are on aside to solve later, and pinning it again lets it go.
  The menu also lists pinned problems.

### Cleaning

`:Tuna clean` removes files you created and never used, and then the directories they
leave empty. Every deletion is confirmed one at a time, with the file in front of you.

### Your algorithms library

[`:Tuna lib`](REFERENCE.md#lib) copies a piece of your own library into the file you are writing. The library
is plain source files, with the parts worth copying marked in place:

```cpp
// TUNALIB: binary exp start
long long bexp(long long b, long long e, long long m) { ... }
// TUNALIB: binary exp end
```

Only files matching the current buffer's extension are offered.
`:Tuna lib snippet` lists every snippet at once, `:Tuna lib search`
opens the same catalogue in telescope.

### Keymaps

Keympas make the `tuna` experience much better. You can opt-in to the default keymaps with one line: `keymaps = { preset = "<leader>t" }` gives
`<leader>tr` run, `<leader>tu` runner UI, `<leader>ts` submit, `<leader>tn`/`<leader>tp`
problem navigation, `<leader>tdc`
download a contest and `<leader>tds` sync,
`<leader>tf` pin, `<leader>tl` the library, `<leader>tw` the scratch, `<leader>tm`
the menu, and more.
You can edit or drop any of them without giving up the rest.

### Statusline

Two optional [lualine](https://github.com/nvim-lualine/lualine.nvim) components can make for a better experience: the
download listener while it is waiting, and the current problem's submit verdict.

Every tuna window has the filetype `tuna`. Listing it in lualine's `ignore_focus` keeps
the statusline describing the file underneath while a
tuna window has focus.

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

Everything is optional: `setup()` takes a table shaped like the defaults, and anything you
leave out keeps its default.

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

Settings can also live in a `.tuna.lua` in any folder above the file you are editing. It returns
a table of the same shape, so a contest folder can set its own time limit, template or testcase
layout without touching your config.

Everything else, from the `$(...)` placeholders that paths and commands use to keymap actions and
highlight groups, is in the [reference](REFERENCE.md#configuration), and every option is commented
in [`lua/tuna/config.lua`](lua/tuna/config.lua).

## Submitting

tuna does not talk to judges itself. Owning a judge's protocol means owning its login, its
cookies, its CSRF tokens and its rate limits, and re-owning them every time it changes a
page — once per judge. So `:Tuna submit` drives whichever command-line submitter you
already trust, and concentrates on the part an editor is actually good at: knowing _which_
problem you are on, and putting the verdict where you can see it.

### 1. Point it at your tool

```lua
require("tuna").setup({
    submit = {
        command = 'cf submit "$(URL)" "$(LANG)" "$(FABSPATH)"',
        languages = { cpp = "C++", python = "Python 3", java = "Java" },
    },
})
```

`command` is expanded with the file modifiers plus three of its own:

- **`$(URL)`** — what to submit _through_.
- **`$(PROBLEM_URL)`** — the problem's own address, always, never reshaped for a tool.
- **`$(LANG)`** — `submit.languages[filetype]`, the name _your tool_ uses for the language.

The two URLs exist separately because the address that identifies a problem is not always
the one you submit through. Use `$(URL)` unless your tool needs the literal problem page.

### 2. Make sure it knows which problem

The URL is resolved in three steps, first hit wins:

1. `submit.url` as a **function** `(ctx) -> string`, if you set one;
2. the **header marker** — a Lua pattern scanned over the first `url_scan_lines` (10) lines
   of the file. The default is `"submit at:%s*(%S+)"`, which matches the line a downloaded
   solution's template already carries:
   ```cpp
   // submit at: https://codeforces.com/contest/2250/problem/A
   ```
3. the **sidecar** (`.tuna.json`) the download wrote beside the file.

So a downloaded problem is submittable with no markers at all, and a hand-made one becomes
submittable the moment you paste its URL into the header. Whichever way it resolves, the
first submit backfills the sidecar — including the contest and problem name, if your
template marks them with `submit.group` and `submit.name` — so the verdict can persist.

A URL that still contains an unexpanded `$(...)` is rejected rather than handed to the
tool, which is what stops `:Tuna submit` on a raw template from submitting garbage.

### 3. Decide how the verdict comes back

By default tuna runs the tool as a background job and reads its output (`submit.watch`).
`submit.verdicts` is an ordered list of `{ lua_pattern, state }` rules matched against that
output — the shipped set is the judges' own vocabulary, so most tools need no changes:

```lua
verdicts = {
    { "queued", "pending" }, { "testing", "pending" }, { "compiling", "pending" },
    { "accepted", "accepted" }, { "wrong answer", "rejected" }, { "time limit", "rejected" },
    -- …
},
```

`pending` keeps watching; `accepted`, `rejected` and `partial` are final and stop it. A
final verdict wins over a pending one in the same output, which matters for the submitters
that redraw their status in place rather than printing a line per poll.

What if your tool prints nothing tuna recognises? Then **nothing is claimed**: a clean exit
clears the indicator, and only a non-zero exit is reported as a failure — with the tool's
own error line, its credentials blanked out of it first.

Two cases want the other path, `submit.watch = false`, which runs the tool in a terminal:

- your tool **asks you something** (kattis-cli prompts to confirm unless you pass `-f`) —
  watch mode gives the child no stdin, so a prompt there gets EOF;
- you would simply rather watch it work, in which case `open_terminal` decides whether the
  terminal opens in front of you or stays in the background.

### 4. Different judges, different tools

`submit.judges.<judge>` is a partial override folded over everything above, keyed on the
URL's host:

```lua
submit = {
    command = 'cf submit "$(URL)" "$(LANG)" "$(FABSPATH)"',
    judges = {
        kattis  = { command = "kattis $(FNAME)", watch = false },
        atcoder = { provider = "browser" },
    },
},
```

The **`browser`** provider is the answer for a judge you cannot submit to headlessly at
all — AtCoder gates submission behind a challenge no CLI can solve. It opens the submit
page with the task preselected and puts your source on the system clipboard, so submitting
is paste, solve the challenge, click.

### 5. Read the verdict

With [lualine configured](#statusline), the verdict sits in your statusline, coloured by
`submit.verdict_hl`. It is per problem, so it follows you as you move between them; it
lasts until you submit that problem again; it survives a restart; and it disappears the
moment you edit the solution, because it described the source it was submitted from and no
longer does. `:Tuna submit clear` dismisses it, and cancels a submission still being
watched.

If something goes wrong, `submit.log_file` records each submission's raw output and the
verdict tuna parsed from it, which is the fastest way to work out which pattern your tool
needs.

### Every submit option

All of them live under `submit`, and `submit.judges` overrides them per judge. Each one,
with its default and what it does, is commented in the `submit` block of
[`lua/tuna/config.lua`](lua/tuna/config.lua).

## Potential extensions

Five things tuna does not do, left out of the first release deliberately rather than
overlooked. Each is written down because it is a real gap, and because knowing why
something is missing is worth as much as knowing what is there.

- **File-I/O problems.** The IOI/OI format, where the solution `freopen`s `input.txt` and
  `output.txt` instead of using stdin and stdout. tuna feeds a testcase on stdin and judges
  what comes back on stdout, so such a solution reads nothing and its answer is never
  compared — and there is no workaround, because `run_command` is an argv handed to the OS,
  not a shell line, so `< input.txt > output.txt` cannot be smuggled into it.
- **Debugger integration.** Launching nvim-dap on a _chosen testcase's_ input, with a
  separate unoptimised build. Most of this belongs to nvim-dap rather than here; the part
  only tuna can supply is "debug this row".
- **Hiding results rows by verdict.** Hide correct, hide wrong — so a `run all` matrix, or a
  stress run that saved a dozen counterexamples, can be narrowed to what went wrong.
- **A library that says what a snippet _is_.** A short description and a complexity beside
  each entry, so the catalogue reads as a reference and not only as a paste buffer — and so
  `:Tuna lib search` has something to match on between a name and a whole body.

## Acknowledgements

`tuna.nvim` is a ground-up rewrite of and successor to [`competitest.nvim`](https://github.com/xeluxee/competitest.nvim), which is no longer mantained. A massive thank you to [xeluxee](https://github.com/xeluxee) and all the contributors to `competitest.nvim` for their great work.
