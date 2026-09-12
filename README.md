<div align="center">

![Neovim](https://img.shields.io/badge/NeoVim-0.10+-%2357A143.svg?&style=for-the-badge&logo=neovim)
![Lua](https://img.shields.io/badge/Lua-%232C2D72.svg?style=for-the-badge&logo=lua)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)

<pre>
  ██████████  ███    ███  ███     ███     ██████   
  ██████████  ███    ███  ████    ███    ███  ███  
    ███      ███    ███  ███ ██  ███   ███    ███  
    ███      ███    ███  ███  ██ ███  ████████████ 
   ███      ██████████  ███   █████  ███      ███  
   ███       ████████   ███     ███  ███      ███  
</pre>

</div>

`tuna.nvim` is a competitive programming plugin that handles testcase management,
intregrates with [Competitive companion](https://github.com/jmerle/competitive-companion) to download contests,
supports stress testing, and much more.

## Contents

[Requirements](#requirements) · [Installation](#installation) · [Quick start](#quick-start) ·
[Commands](#commands) · [Features](#features) · [Configuration](#configuration) ·
[Submitting](#submitting) ·
[Coming from competitest.nvim](#coming-from-competitestnvim) ·
[Potential extensions](#potential-extensions)

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

## Quick start

1. **`:Tuna`** opens the menu,
2. **`:Tuna download problem`** begins listening for a problem from Competitive companion,
   press the green plus in your browser to download.
   A solution file is created from your template, the testcases are written beside it,
   Neovim moves into the problem's directory, and the file opens.
3. **`:Tuna run`** compiles, runs the testcases in parallel, and opens the results grid.
   The four panes show output, expected output, input and stderr. This UI can do a lot,
   for example `d` toggles a diff of the two outputs.
4. **`:Tuna submit`** hands the solution to whichever submit tool you have configured,
   reads that tool's output as it runs, and puts the judge's verdict in your statusline.

## Commands

Every command is a subcommand of `:Tuna` with tab-completion.

<table>
<tr>
  <td><code>:Tuna</code> / <code>:Tuna menu</code></td>
  <td>the menu</td>
</tr>
<tr>
  <td><code>:Tuna run [auto|normal|all|stress|interactive] [n…]</code></td>
  <td>run; a mode keyword forces that mode and <code>auto</code> hands it back, numbers limit the run to those testcases</td>
</tr>
<tr>
  <td><code>:Tuna run_no_compile [n…]</code></td>
  <td>run the existing build</td>
</tr>
<tr>
  <td><code>:Tuna show_ui</code></td>
  <td>open the results UI</td>
</tr>
<tr>
  <td><code>:Tuna testcase [add|edit|delete] [n]</code></td>
  <td>manage testcases</td>
</tr>
<tr>
  <td><code>:Tuna testcase split [n] [marker]</code></td>
  <td>lift the testcases inside marker lines into testcases of their own</td>
</tr>
<tr>
  <td><code>:Tuna convert &lt;files|single_file|directory&gt;</code></td>
  <td>rewrite the testcases into another layout</td>
</tr>
<tr>
  <td><code>:Tuna compare &lt;exact|squish|float [tol]|default&gt;</code></td>
  <td>override the comparison for this problem</td>
</tr>
<tr>
  <td><code>:Tuna checker [auto|off|toggle]</code></td>
  <td>judge with the problem's checker when there is one, or compare outputs</td>
</tr>
<tr>
  <td><code>:Tuna download &lt;testcases|problem|contest|sync|persistently|status|stop&gt;</code></td>
  <td>download from Competitive companion</td>
</tr>
<tr>
  <td><code>:Tuna scaffold &lt;checker|generator|brute|interactor&gt; [ext]</code></td>
  <td>drop in a starter file</td>
</tr>
<tr>
  <td><code>:Tuna submit [clear]</code></td>
  <td>submit or dismiss the verdict / cancel a running submit</td>
</tr>
<tr>
  <td><code>:Tuna next</code> / <code>:Tuna prev</code></td>
  <td>go to the problem either side of this one in a contest</td>
</tr>
<tr>
  <td><code>:Tuna last [problem|contest]</code></td>
  <td>go back to what you were working on</td>
</tr>
<tr>
  <td><code>:Tuna temp</code></td>
  <td>drop in a scratch solution for before a contest opens</td>
</tr>
<tr>
  <td><code>:Tuna lib [snippet|search]</code></td>
  <td>insert code from your algorithms library</td>
</tr>
<tr>
  <td><code>:Tuna clean</code></td>
  <td>remove files created and never used</td>
</tr>
<tr>
  <td><code>:checkhealth tuna</code></td>
  <td>check Neovim version, compilers on <code>PATH</code>, the listener port, optional integrations</td>
</tr>
</table>

## Features

### Testcases

Testcases live on disk beside your solution, in whichever layout you already use. Three
storage backends, chosen with `testcases_storage`:

|                   | layout                                                             |
| ----------------- | ------------------------------------------------------------------ |
| `files` (default) | `main_input0.txt` / `main_output0.txt` beside the source           |
| `single_file`     | every testcase in one msgpack file, `main.testcases`               |
| `directory`       | one sub-directory per testcase, `tests/0/input.txt` + `output.txt` |

The file-name formats are yours (`testcases_input_file_format` and friends, with
`$(FNOEXT)`, `$(TCNUM)` and the rest), and where the store is rooted is
`testcases_directory` — relative to the source by default, or an absolute path outside
the source tree entirely. `:Tuna convert <backend>` rewrites an existing set from one
layout to another.

The default `files` format is a **list**, tried in order, and the first that finds
anything wins:

```lua
testcases_input_file_format = { "$(FNOEXT)_input$(TCNUM).txt", "input$(TCNUM).txt", "in.txt" }
```

So a solution finds testcases it did not write — the ones Competitive Companion left
under a shared name, or the ones a second attempt in another language is using — and a
folder with a single `in.txt`/`out.txt` pair works with no configuration at all. A
testcase may have **only an input or only an expected output**: an answer with no input
runs against empty stdin, and an input with no answer runs and reports `DONE` rather
than being judged against nothing.

Add, edit and delete them with `:Tuna testcase add|edit|delete`, or in place in the
results UI (below), which is usually where you want to be. `:Tuna testcase split` breaks
one testcase into several: mark the cases inside it with a line of `-`, and each bracketed
region becomes a testcase of its own that gets a verdict of its own, instead of being
somewhere in a wall of output.

### Running, and the results UI

`:Tuna run` compiles, runs every testcase in parallel — as many at once as you have
cores, by default — and opens the results grid:

```
┌ Run ─────────────────────┬ Output ───────────┬ Expected Output ──┐
│ mode : normal, automatic │ 3                 │ 3                 │
│ judge: squish            │                   │                   │
│ diff : off               │                   │                   │
│ help : ?                 │                   │                   │
├ Testcases ───────────────┼ Errors ───────────┼ Input ────────────┤
│ Compile  DONE            │                   │ 1 2               │
│ TC 0  CORRECT            │                   │                   │
│ TC 1  WRONG              │                   │                   │
└──────────────────────────┴───────────────────┴───────────────────┘
```

Output faces Expected Output across the top, because the comparison is read _across_;
Errors and Input sit under them, and the two editable panes end up as one column down the
right-hand edge. The whole grid is `popup_ui.layout`, a nested `{ weight, pane }` tree, if
you want it arranged differently — or `runner_ui.interface = "split"` for real windows
instead of floats.

Each testcase is a row and the four panes show that run. The compile step is a row too,
so its warnings are somewhere you can read them, and a compile failure pops its errors up
by itself.

| key                             |                                                                       |
| ------------------------------- | --------------------------------------------------------------------- |
| `j` / `k`                       | walk the testcases                                                    |
| `r` / `<C-r>`                   | re-run this one / all of them                                         |
| `s` / `<C-s>`                   | stop this one / all of them                                           |
| `d`                             | toggle the diff                                                       |
| `i` `a` `o` `e`                 | open input / expected / stdout / stderr full-screen                   |
| `n` `x` `u`                     | add a testcase, delete one, undo that                                 |
| `c`                             | split this testcase on its marker lines                               |
| `<C-h>` `<C-j>` `<C-k>` `<C-l>` | move between panes                                                    |
| `q`                             | close                                                                 |
| `?`                             | the full legend, which is the authority — these are just the defaults |

**The Input and Expected Output panes are editable.** They are ordinary buffers with an
accent on their border, so there is no key to learn: move in, type, and `:w`. That writes
the testcase and re-runs it. Nothing reaches disk before `:w`, unwritten edits survive
moving to another row, and closing with one pending asks rather than dropping it. So does
starting a run, in this mode or another: a problem shows one results UI at a time, and
switching modes stops the previous run and puts its UI away.

**The diff is positional.** Vim's own diff may decide a line was deleted and re-pair
everything after it, which for `2 2 0 2` against `2 2 2 5` reports one deletion and then
compares your fourth line with the answer's third. Competitive-programming output is
positional, so tuna walks both sides in lockstep — line _i_ against line _i_, token _i_
against token _i_ — and never re-aligns. Its granularity follows the comparison in force,
so the marks can never contradict the verdict.

Comparison is `output_compare_method`: `"exact"`, `"squish"` (whitespace-insensitive, the
default), `{ "float", tol = 1e-6 }` for problems with a tolerance, or a function of your
own. `:Tuna compare <method>` overrides it for one problem, and remembers.

### Run modes

The same `:Tuna run` does four different things, and which one it does is a property of
the problem rather than a different command to remember. Helper programs are discovered
**by filename**, beside your solution and in the same language, and compiled on demand —
there is no manifest to maintain:

| you write               | `:Tuna run` becomes  | what happens                                                                                                  |
| ----------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------- |
| nothing                 | **normal**           | every testcase, in parallel                                                                                   |
| `gen.cpp` + `brute.cpp` | **stress test**      | generate an input, run both, compare, repeat until they disagree — then save the counterexample as a testcase |
| `interactor.cpp`        | **interactive**      | your solution and the interactor cross-wired, the exchange in the transcript                                  |
| —                       | **run all**          | every sibling solution against the shared testcases, as a solution×testcase matrix                            |
| `checker.cpp`           | _(any of the above)_ | a testlib-style special judge decides correctness instead of string comparison                                |

**Automatic until you force it.** Every helper is found the same way: a file named after it
beside your solution, or the option pointing at one of your own (`checker`,
`stress.generator` and `.reference`, `interactive.interactor`), which is used instead. The
mode, interactive's source and the checker each follow the helpers present until you force
them: `:Tuna run <mode>` forces a mode, `:Tuna run interactive <source>` a source,
`:Tuna checker off` plain comparison, and `auto` hands any of them back. A forced choice
that needs a helper you have since deleted, stress without its reference say, runs the
automatic choice instead, says so, and comes back with the helper. Every run looks the
helpers up again, so adding, deleting or editing one takes effect on the next run, and a
rerun from an open results UI whose mode has lost its helper says so rather than running.

`:Tuna scaffold generator|brute|interactor|checker` drops in a dependency-free starter file
in your language.

**Run all** is for the shape where you have `main.cpp` and `main2.cpp` and want to know
which one is right — including when they are in _different languages_, since each is
compiled and run with its own filetype's commands. **Stress testing** is for the shape
where you know one is right and slow. **Checkers** are for problems with more than one
correct answer; whatever the checker prints about a verdict (`wrong answer: expected 5,
got 3`) shows in the Errors pane of that testcase's row.

**Interactive** lays out the results grid by who plays the other side. With `live` (you)
and `interactor` (your interactor program) the session reads as a **conversation**: beside
the testcase list are three columns, Errors, Output and Live, and whatever one side says
goes on a row of its own in its own column, the other two left blank on that row, so every
reply sits on the line after the message it answers and nothing is repeated between them.
The columns follow the latest line and scroll together. In `live` you type on the last line
of the Live column, which wears the accent of a pane you type into, and `<CR>` sends it.
`feed` replays a stored testcase line by line instead, so it keeps the ordinary Input and
Expected Output panes, editable exactly as in a normal run.

### Downloading problems and contests

With [Competitive Companion](https://github.com/jmerle/competitive-companion) installed,
`:Tuna download problem` (or `contest`, or `testcases` for just the tests) opens a
listener; pressing the green **+** in the browser does the rest. `:Tuna download
persistently` leaves it open for a whole session.

Where things land is a path template, evaluated per problem:

```lua
downloaded_problems_path      = "$(HOME)/cp/$(JUDGE)/$(PROBLEM)/main.$(FEXT)",
downloaded_contests_directory = "$(HOME)/cp/$(JUDGE)/$(CONTEST)",
```

`$(JUDGE)` and `$(CONTEST)` come from tuna's own parsing of what the extension sends, and
you can override it per judge with `judge_parsers` — a function that gets the raw group
and returns what you would rather call it. Codeforces and AtCoder are normalized out of
the box, including Codeforces' **mirror** hosts, whose pages carry no per-problem URL and
no contest name: tuna rewrites the URL to the main site so the link in your header still
works next week, keeps the mirror for submitting while the round is live, and recovers the
problem index from the URL so a mirrored contest still sorts A, B, C.

New files are created from `template_file`, with the problem's own details filled in:

```cpp
// judge:   $(JUDGE)
// contest: $(CONTEST)
// problem: $(PROBLEM)
// submit at: $(URL)
```

That option takes a single path, a per-extension table, or an **ordered list tried until
one exists** — which is what makes a per-judge template practical:

```lua
template_file = { "~/cp/template.$(JUDGE).cpp", "~/cp/template.cpp" },
```

Downloading also moves Neovim into what it wrote (`cd_downloaded_problems`), because
downloading a contest is the moment you start working in it, and everything that is not
tuna — `:e`, a fuzzy finder, `:grep` — reads the cwd.

### Submitting

`:Tuna submit` hands the solution to a submit tool of your choosing and reads its output
as it runs, so the judge's verdict arrives in your statusline:

```lua
submit = {
    command = 'cf submit "$(URL)" "$(LANG)" "$(FABSPATH)"',
    languages = { cpp = "C++", python = "Python 3" },
},
```

The problem's URL comes from the header marker your template wrote, or from the sidecar
the download left beside the file — so a downloaded problem is submittable with no
markers at all, and a hand-made one becomes submittable the moment you paste a URL into
its header.

The verdict (`Running (on test 6)` → `Accepted`) is per problem, stays until you submit
again, survives a restart, and disappears the moment you edit the solution, because it
described the source it was submitted from. A tool that prints nothing tuna recognises is
not treated as a failure: a clean exit clears the indicator and claims nothing, and only a
non-zero exit is reported — with the tool's own error line, credentials redacted out of it.

Judges differ, so `submit.judges.<judge>` overrides any of it per judge — a different
tool, different verdict patterns, or a different provider entirely. The `browser` provider
exists for judges that cannot be submitted to headlessly (AtCoder gates submission behind
a challenge no CLI can solve): it opens the submit page with the task preselected and puts
your source on the clipboard.

### Your algorithm library

`:Tuna lib` copies a piece of your own library into the file you are writing. The library
is **plain source files** — nothing to maintain in a special format — with the parts worth
copying marked in place:

```cpp
// TUNALIB: binary exp start
long long bexp(long long b, long long e, long long m) { ... }
// TUNALIB: binary exp end
```

Everything around the guards (includes, `main`, whatever you tested it with) is ignored.
Only files matching the current buffer's extension are offered, the preview follows your
cursor so you see the code before inserting it, and what is inserted is re-indented to
where the cursor is. `:Tuna lib snippet` lists every snippet at once; `:Tuna lib search`
opens the same catalogue in telescope.

### Getting around

- `:Tuna next` / `:Tuna prev` step between the problems of a contest, preferring the same
  file name you are leaving (`A/main.cpp` → `B/main.cpp`).
- `:Tuna last problem` / `:Tuna last contest` go back to what you were working on, across
  restarts, and move Neovim's directory there with you. The menu lists your recent
  contests and problems, and `<CR>` on one goes there. A contest shows its judge and how
  many of its problems the judge accepted. A problem shows its verdict, or while the judge
  hasn't judged the source as it is now, how its last finished run went (`3/4 PASSED`),
  which is saved beside it and forgotten when you edit. Names too long for the screen are
  shortened, never the verdicts.
- `:Tuna temp` opens a scratch solution for the minutes before a contest starts, when
  there is no problem to download yet, asking which of your templates to start from. An
  existing scratch first asks whether to resume it or restart. `:Tuna download sync` then
  folds what you wrote into the first problem it downloads, header and all.
- `:Tuna clean` removes files you created and never used — templated solutions still
  holding the template, scaffolds you never filled in — and then the directories they
  leave empty. Every deletion is confirmed one at a time, with the file in front of you.

### Statusline

Two optional [lualine](https://github.com/nvim-lualine/lualine.nvim) components: the
download listener while it is waiting, and the current problem's submit verdict.

Every tuna window has the filetype `tuna`. Listing it in lualine's `ignore_focus` keeps
the statusline describing the file underneath (its name, LSP clients and verdict) while a
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

### Odds and ends

- **Default keymaps**, opt-in with one line: `keymaps = { preset = "<leader>t" }` gives
  `<leader>tr` run, `<leader>tu` results, `<leader>ts` submit, `<leader>tn`/`<leader>tp`
  problem navigation, `<leader>tta`/`tte`/`ttd` testcases, `<leader>tdp`/`tdc` downloads,
  `<leader>tgp`/`tgc` back to the last problem/contest, and `<leader>tm` the menu.
  Move or drop any of them without giving up the rest.
- **`:checkhealth tuna`** reports what tuna can see: your Neovim version, whether each
  configured compiler and interpreter is actually on `PATH`, the Competitive Companion
  port, and which optional integrations are installed.
- **Per-directory configuration**: a `.tuna.lua` returning a table anywhere above your
  solution overrides the global setup for everything under it, so one contest can use a
  different template or time limit without touching your config.

## Configuration

Everything is optional. `setup()` takes a table shaped like the defaults, and anything you
leave out keeps its default:

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

### Where settings come from

Three layers, each overriding the one before:

1. the defaults;
2. what you pass to `setup()`;
3. a **`.tuna.lua`** anywhere above the file you are editing, returning a table.

The third is per-directory, found by walking up from the buffer's own path — so a contest
folder can set a different time limit, template or testcase layout for everything under it
without touching your config:

```lua
-- ~/cp/codeforces/1234/.tuna.lua
return {
    maximum_time = 2000,
    testcases_input_file_format = "in$(TCNUM).txt",
}
```

`setup()` **replaces** rather than merges into whatever a previous call left, so re-sourcing
your config with a line deleted actually removes that setting.

### Modifiers

The `$(...)` placeholders that appear in commands, file formats and paths. There are two
sets, and which one applies depends on whether a downloaded problem is involved.

**File modifiers** — available anywhere a path or command is evaluated:

<table>
<tr>
  <td><code>$(FNAME)</code></td>
  <td><code>main.cpp</code></td>
</tr>
<tr>
  <td><code>$(FNOEXT)</code></td>
  <td><code>main</code></td>
</tr>
<tr>
  <td><code>$(FEXT)</code></td>
  <td><code>cpp</code></td>
</tr>
<tr>
  <td><code>$(FABSPATH)</code></td>
  <td><code>/home/you/cp/A/main.cpp</code></td>
</tr>
<tr>
  <td><code>$(ABSDIR)</code></td>
  <td><code>/home/you/cp/A</code></td>
</tr>
<tr>
  <td><code>$(DIRNAME)</code></td>
  <td><code>A</code> — the <em>name</em> of the directory, which for a downloaded problem is the problem</td>
</tr>
<tr>
  <td><code>$(HOME)</code>, <code>$(CWD)</code></td>
  <td>your home directory, the current directory</td>
</tr>
<tr>
  <td><code>$(TCNUM)</code></td>
  <td>the testcase number (testcase file formats only)</td>
</tr>
<tr>
  <td><code>$()</code></td>
  <td>a literal <code>$</code></td>
</tr>
</table>

**Download modifiers** — additionally available in `downloaded_*` paths and in
`template_file`, because they only exist while a problem is being downloaded:

<table>
<tr>
  <td><code>$(PROBLEM)</code></td>
  <td>the problem's name</td>
</tr>
<tr>
  <td><code>$(JUDGE)</code>, <code>$(CONTEST)</code></td>
  <td>as parsed from what the extension sent (see <code>judge_parsers</code>)</td>
</tr>
<tr>
  <td><code>$(GROUP)</code></td>
  <td>the raw, unparsed group</td>
</tr>
<tr>
  <td><code>$(URL)</code></td>
  <td>the problem's address</td>
</tr>
<tr>
  <td><code>$(TIMELIM)</code>, <code>$(MEMLIM)</code></td>
  <td>the judge's limits, in ms and MB</td>
</tr>
<tr>
  <td><code>$(JAVA_MAIN_CLASS)</code>, <code>$(JAVA_TASK_CLASS)</code></td>
  <td>for Java scaffolding</td>
</tr>
<tr>
  <td><code>$(DATE)</code></td>
  <td>now, formatted with <code>date_format</code></td>
</tr>
</table>

Characters that cannot appear in a filename are replaced with `_` in every modifier that
becomes part of a path.

### Compiling and running

| option                  | default                          |                                                                                                                   |
| ----------------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `compile_command`       | gcc / g++ / rustc / javac        | per filetype, `{ exec, args }`; a filetype with no entry is not compiled                                          |
| `run_command`           | `./$(FNOEXT)`, `python3`, `java` | per filetype, `{ exec, args }`                                                                                    |
| `compile_directory`     | `"."`                            | where the compiler runs, relative to the source — or an absolute path, to keep binaries out of the problem folder |
| `running_directory`     | `"."`                            | likewise, for the solution                                                                                        |
| `multiple_testing`      | `-1`                             | testcases at once: `-1` your core count, `0` all of them, `n` exactly n                                           |
| `maximum_time`          | `5000`                           | per-process limit in ms; past it the process is killed and the row reads `TIMEOUT`                                |
| `output_compare_method` | `"squish"`                       | `"exact"`, `"squish"`, `{ "float", tol = 1e-6 }`, or `function(output, expected) -> boolean`                      |
| `checker`               | `nil`                            | a path to a testlib-style checker or `{ exec, args }`, used instead of a `checker.*` file                         |
| `save_current_file`     | `true`                           | write the buffer before running                                                                                   |
| `save_all_files`        | `false`                          | write every buffer before running                                                                                 |

These are argv, not shell lines: `exec` is the program and `args` is a list, so nothing is
word-split or glob-expanded behind your back.

### Testcases

| option                                  | default                                                               |                                                                                                                                           |
| --------------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `testcases_storage`                     | `"files"`                                                             | `"files"`, `"single_file"`, `"directory"`                                                                                                 |
| `testcases_auto_detect`                 | `true`                                                                | if the configured backend finds none, try the others before giving up                                                                     |
| `testcases_directory`                   | `"."`                                                                 | where the store is rooted, relative to the source or absolute                                                                             |
| `testcases_input_file_format`           | `{ "$(FNOEXT)_input$(TCNUM).txt", "input$(TCNUM).txt", "in.txt" }`    | `files` backend; a list is tried in order and the first that finds anything wins, the first entry being what new testcases are written as |
| `testcases_output_file_format`          | `{ "$(FNOEXT)_output$(TCNUM).txt", "output$(TCNUM).txt", "out.txt" }` | as above                                                                                                                                  |
| `testcases_single_file_format`          | `"$(FNOEXT).testcases"`                                               | `single_file` backend                                                                                                                     |
| `testcases_directory_format`            | `"tests/$(TCNUM)"`                                                    | `directory` backend                                                                                                                       |
| `testcases_directory_input` / `_output` | `"input.txt"` / `"output.txt"`                                        | filenames inside each testcase directory                                                                                                  |
| `testcases_split_markers`               | `"-"`                                                                 | the character `:Tuna testcase split` brackets cases with                                                                                  |
| `problem_store_file`                    | `".tuna.json"`                                                        | the per-problem sidecar: the downloaded task, the last submit verdict, the last run's result, and how the problem is run                  |

A format without `$(TCNUM)` names a _single_ testcase, which is what makes a bare
`in.txt` / `out.txt` pair work.

### Downloading

| option                                                | default                       |                                                                                                                           |
| ----------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `companion_port`                                      | `27121`                       | the port Competitive Companion posts to                                                                                   |
| `downloaded_files_extension`                          | `"cpp"`                       | the language new solutions are created in                                                                                 |
| `downloaded_problems_path`                            | `"$(CWD)/$(PROBLEM).$(FEXT)"` | where a single problem is written                                                                                         |
| `downloaded_contests_directory`                       | `"$(CWD)"`                    | the contest's own folder                                                                                                  |
| `downloaded_contests_problems_path`                   | `"$(PROBLEM).$(FEXT)"`        | each problem, relative to that folder                                                                                     |
| `downloaded_problems_prompt_path`                     | `true`                        | ask before writing, with the computed path filled in                                                                      |
| `downloaded_contests_prompt_directory` / `_extension` | `true`                        | likewise for a contest                                                                                                    |
| `open_downloaded_problems` / `_contests`              | `true`                        | open what was written                                                                                                     |
| `cd_downloaded_problems` / `_contests`                | `true`                        | move Neovim into it (`cd_command`)                                                                                        |
| `cd_command`                                          | `"cd"`                        | `"cd"`, `"tcd"`, `"lcd"`, or `false` to never change directory                                                            |
| `replace_downloaded_testcases`                        | `false`                       | overwrite existing testcases instead of appending                                                                         |
| `download_print_message`                              | `true`                        | report what was downloaded                                                                                                |
| `start_downloading_persistently_on_setup`             | `false`                       | open the listener at startup and leave it open                                                                            |
| `judge_parsers`                                       | `{}`                          | `{ [judge] = function(info) -> { judge?, contest? } }`; `false` disables normalizing for that judge, `"*"` is a catch-all |
| `date_format`                                         | `"%c"`                        | for `$(DATE)`                                                                                                             |

Downloading a problem whose target already exists asks before overwriting; downloading a
contest asks **once** for the whole batch, and offers to write only the problems that are
missing — which is what re-downloading a contest you are half-way through should do.

### Templates

| option                        | default |                                                                      |
| ----------------------------- | ------- | -------------------------------------------------------------------- |
| `template_file`               | `false` | a path, a `{ [ext] = path }` table, or a list tried until one exists |
| `evaluate_template_modifiers` | `false` | expand `$(...)` inside the template's _contents_, not just its path  |
| `template_cursor`             | `false` | where to put the cursor in a freshly created solution                |

`template_cursor` takes a line number, a Lua pattern to search for, `{ pattern, offset }`
for _n_ lines below the match, or a function. A pattern that matches nothing leaves the
cursor alone, so one written for C++ is harmless to a Python template.

### Run modes and helper programs

| option                            | default                                                                            |                                                                     |
| --------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `tool_names`                      | `checker`/`check`, `gen`/`generator`, `brute`/`reference`, `interactor`/`interact` | the basenames tuna looks for beside your solution                   |
| `stress.count`                    | `100`                                                                              | iterations per run                                                  |
| `stress.seed_arg`                 | `true`                                                                             | pass the iteration number to the generator as an argument           |
| `stress.saves_per_run`            | `1`                                                                                | stop after saving this many counterexamples                         |
| `stress.max_saved`                | `10`                                                                               | stop once the problem has this many testcases in total              |
| `stress.generator` / `.reference` | `nil`                                                                              | a path or `{ exec, args }`, used instead of the file `tool_names` finds |
| `interactive.interactor`          | `nil`                                                                              | likewise                                                            |
| `scaffold.files`                  | `checker`, `gen`, `brute`, `interactor`                                            | basenames `:Tuna scaffold` creates                                  |
| `scaffold.templates`              | `nil` per kind                                                                     | your own starter files, `{ [ext] = path }`                          |

### Keymaps

Nothing is mapped unless you ask:

```lua
keymaps = {
    preset = "<leader>t",              -- the whole set, under one prefix
    filetypes = { "c", "cpp", "rust", "java", "python" },
    mappings = { run = "<leader><leader>", delete_testcase = false },  -- move one, drop one
    global = {},                       -- always available, not just in a solution
},
```

`mappings` are buffer-local and set for `filetypes`, so they follow you from solution to
solution; `global` are set once. Both layer over `preset` rather than replacing it, so a
single key can be moved — or dropped, by mapping its action to `false` — without giving up
the rest. The preset groups keys by subject, so which-key shows a `t` testcases group, a
`d` downloads group and a `g` "go to" group.

### Appearance and widgets

| option                                | default                                          |                                                                                                                                                              |
| ------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `floating_border`                     | `"rounded"`                                      | passed to `nvim_open_win`                                                                                                                                    |
| `floating_border_highlight`           | `"FloatBorder"`                                  |                                                                                                                                                              |
| `switch_window_keys`                  | `{ "<C-h>", "<C-j>", "<C-k>", "<C-l>" }`         | move between panes, everywhere in the plugin                                                                                                                 |
| `cancel_keys`                         | `{ normal = { "<Esc>", "<C-c>" }, insert = {} }` | how every widget is dismissed; `<Esc>` in insert mode leaves insert by default, so dismissing something you are typing into takes a second, deliberate press |
| `runner_ui.interface`                 | `"popup"`                                        | `"popup"` for floats, `"split"` for real windows                                                                                                             |
| `runner_ui.mappings`                  | see the key table above                          |                                                                                                                                                              |
| `runner_ui.viewer`                    | `0.8` × `0.8`                                    | the full-screen pane view; `open_when_compilation_fails` pops it on a build error                                                                            |
| `runner_ui.editable_border_highlight` | `"TunaEditable"`                                 | the accent on the two editable panes; `false` turns it off                                                                                                   |
| `popup_ui.layout`                     | three columns                                    | a nested `{ weight, pane }` tree over `tc`, `so`, `eo`, `si`, `se`; a pane you leave out is simply not drawn, and stays reachable in the viewer              |
| `split_ui`                            | `"right"`, `0.3`                                 | position and size when `interface = "split"`                                                                                                                 |
| `editor_ui`, `picker_ui`              |                                                  | the standalone testcase editor and picker                                                                                                                    |

Highlight groups: `TunaCorrect`, `TunaWrong`, `TunaWarning`, `TunaRunning`, `TunaDone`,
`TunaEditable`, and `TunaDiffChange` / `TunaDiffText` / `TunaDiffAdd` / `TunaDiffDelete`.
Override any of them with `:hi` after startup — they are re-applied on `ColorScheme`, so
they follow your theme.

### Library, scratch, menu, clean

| option                             | default                                    |                                                                                                                          |
| ---------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| `library.path`                     | `false`                                    | a directory or a list of them; `false` turns `:Tuna lib` off                                                             |
| `library.marker`                   | `"TUNALIB"`                                | the word a guard comment carries                                                                                         |
| `library.depth`                    | `3`                                        | how deep to search below each path                                                                                       |
| `temp.file`                        | `stdpath("cache") .. "/tuna_temp.$(FEXT)"` | where `:Tuna temp` writes its scratch                                                                                    |
| `temp.extension` / `temp.download` | `"cpp"` / `"contest"`                      | the scratch's language, and what `:Tuna download sync` downloads                                                         |
| `menu.header`                      | `nil`                                      | your own banner lines, or `false` for none                                                                               |
| `recent.problems`                  | `5`                                        | how many recent problems `:Tuna last` and the menu remember                                                              |
| `recent.contests`                  | `3`                                        | how many recent contests they remember                                                                                   |
| `clean.min_width` / `max_width`    | `0.5` / `0.7`                              | the confirmation float's size bounds                                                                                     |
| `clean.max_entries`                | `20000`                                    | how much of a tree a scan may walk before reporting itself partial                                                       |
| `clean.skip_dirs`                  | `node_modules`, `target`, `build`, …       | never descended into                                                                                                     |
| `clean.protected_dirs`             | `{}`                                       | never offered for removal (your home directory, its standard sub-directories and the system's own are protected already) |

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

## Coming from competitest.nvim

tuna is a rewrite, not a fork, so a few things are deliberately named or shaped
differently. If you are porting a config:

- **`receive` is `download`.** `:CompetiTest receive <mode>` is `:Tuna download <mode>`,
  and every `received_*` option is `downloaded_*`. The old name describes the plugin's point
  of view (it receives an HTTP POST); the new one describes yours.
- **`convert` takes a target.** With three storage backends instead of two, `auto` cannot
  pick a unique direction, so `:Tuna convert <backend>` is explicit. The _source_ is still
  detected for you.
- **`testcases_use_single_file` is `testcases_storage`**, an enum over the three backends.
- **`editor_ui.popup_width` / `popup_height` are `editor_ui.width` / `height`**, matching
  `picker_ui` and `viewer`, which always used the shorter names.
- **`picker_ui.mappings.focus_next` / `focus_prev` are gone.** The picker is an ordinary
  buffer, so `j`/`k` and the arrow keys already move the selection.
- **Python runs as `python3`**, not `python`.
- **No `nui.nvim`.** Every float, split and prompt is built on Neovim's own APIs, so there
  is one less runtime dependency and the layout is yours to rearrange. Every tuna float
  carries `filetype = "tuna"`, so other plugins (and your own autocommands) can target
  them — lualine's `disabled_filetypes`, for instance.
- **`~` works in paths.** `$(HOME)` still does; so does a leading `~`, in every option that
  becomes a path. And `compile_directory` / `running_directory` are joined onto the source's
  directory only when they are _relative_, so an absolute build directory means what it says.
- **Neovim 0.10+** rather than 0.5+, since tuna is built on `vim.system` and `vim.uv`.

Behaviour differences worth knowing about, rather than renames: testcase discovery falls
back through a list of formats instead of one; a testcase may have only half of itself; the
results diff never re-aligns; `:Tuna run` with no testcases runs the program anyway; and the
results UI's Input and Expected Output panes are editable in place.

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

`tuna.nvim` is a ground-up rewrite of and successor to [competitest.nvim](https://github.com/xeluxee/competitest.nvim), which is no longer mantained. A massive thank you to [xeluxee](https://github.com/xeluxee) and all the contributors to `competitest.nvim` for their great work.
