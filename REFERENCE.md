# Commands

Every command is a subcommand of `:Tuna` with tab-completion.

<table>
<tr>
  <td><a href="#menu"><code>:Tuna</code> / <code>:Tuna menu</code></a></td>
  <td>the menu</td>
</tr>
<tr>
  <td><a href="#run"><code>:Tuna run [auto|normal|all|stress|interactive] [n…]</code></a></td>
  <td>run, a mode keyword forces that mode and <code>auto</code> lets tuna figure out the mode by itself</td>
</tr>
<tr>
  <td><a href="#run_no_compile"><code>:Tuna run_no_compile [n…]</code></a></td>
  <td>run the existing build</td>
</tr>
<tr>
  <td><a href="#show_ui"><code>:Tuna show_ui</code></a></td>
  <td>open the runner UI</td>
</tr>
<tr>
  <td><a href="#testcase"><code>:Tuna testcase [add|edit|delete] [n]</code></a></td>
  <td>manage testcases</td>
</tr>
<tr>
  <td><a href="#testcase-split"><code>:Tuna testcase split [n] [marker]</code></a></td>
  <td>lift the testcases inside marker lines into testcases of their own</td>
</tr>
<tr>
  <td><a href="#convert"><code>:Tuna convert &lt;files|single_file|directory&gt;</code></a></td>
  <td>rewrite the testcases into another layout</td>
</tr>
<tr>
  <td><a href="#compare"><code>:Tuna compare [exact|squish|float [tol]|default]</code></a></td>
  <td>override the comparison for this problem</td>
</tr>
<tr>
  <td><a href="#checker"><code>:Tuna checker [auto|off]</code></a></td>
  <td>judge with a custom checker or with the default one</td>
</tr>
<tr>
  <td><a href="#download"><code>:Tuna download &lt;testcases|problem|contest|sync|persistently|status|stop&gt;</code></a></td>
  <td>download from Competitive companion</td>
</tr>
<tr>
  <td><a href="#scaffold"><code>:Tuna scaffold &lt;checker|generator|bruteforce|interactor&gt; [ext]</code></a></td>
  <td>drop in a starter file</td>
</tr>
<tr>
  <td><a href="#submit"><code>:Tuna submit [clear]</code></a></td>
  <td>submit or cancel a running submit and dismiss the verdict</td>
</tr>
<tr>
  <td><a href="#next-and-prev"><code>:Tuna next</code> / <code>:Tuna prev</code></a></td>
  <td>go to the problem either side of this one in a contest</td>
</tr>
<tr>
  <td><a href="#last"><code>:Tuna last [problem|contest]</code></a></td>
  <td>go back to what you were working on</td>
</tr>
<tr>
  <td><a href="#pin"><code>:Tuna pin</code></a></td>
  <td>pin this problem to solve later, or unpin it</td>
</tr>
<tr>
  <td><a href="#scratch"><code>:Tuna scratch</code></a></td>
  <td>drop in a scratch solution for before a contest opens</td>
</tr>
<tr>
  <td><a href="#lib"><code>:Tuna lib [snippet|search]</code></a></td>
  <td>insert code from your algorithms library</td>
</tr>
<tr>
  <td><a href="#clean"><code>:Tuna clean</code></a></td>
  <td>remove files created and never used</td>
</tr>
<tr>
  <td><a href="#checkhealth"><code>:checkhealth tuna</code></a></td>
  <td>check Neovim version, compilers on <code>PATH</code>, the listener port, and optional integrations</td>
</tr>
</table>

## menu

`:Tuna`, or `:Tuna menu`, opens the menu. On the left are your recent contests, your recent
problems and your pinned problems, each with how it went. On the right is what tuna can do
from the file you are on. `<CR>` acts on the list you are in, and `<C-h>`/`<C-j>`/`<C-k>`/
`<C-l>` move between the lists.

## run

```
:Tuna run [auto|normal|all|stress|interactive] [n…]
```

Compiles the solution, runs the testcases in parallel (as many at once as you have cores,
`multiple_testing`) and opens the runner UI.

Without a mode keyword tuna picks the mode itself: `interactive` when an interactor sits
beside the solution, `stress` when a generator and a bruteforce do, `normal` otherwise. A
keyword forces that mode for the problem, and it is remembered across restarts until
`auto` hands the choice back.

- `normal` runs the testcases.
- `all` runs every solution in the folder against every testcase.
- `stress` hunts for an input where your solution and the bruteforce disagree, and saves it
  as a testcase. A number after it is how many inputs to try: `:Tuna run stress 500`.
- `interactive` lets your solution talk to something over stdin and stdout. A word after it
  picks the other side: `live` (you type), `feed` (the testcase input, a line at a time) or
  `interactor` (an interactor program).

In normal mode, trailing numbers run only those testcases: `:Tuna run 2 3`.

## run_no_compile

```
:Tuna run_no_compile [n…]
```

Runs the existing build without compiling first. Numbers limit the run as in `:Tuna run`.

## show_ui

Re-opens the runner UI in the mode the problem is set to. Before any run it lists the
testcases without running them, so it doubles as a viewer.

## testcase

```
:Tuna testcase [add|edit|delete] [n]
```

- `add` opens the testcase editor on a new testcase.
- `edit` opens it on testcase `n`. Bare `:Tuna testcase` and `:Tuna testcase n` do the same.
- `delete` removes testcase `n`, after asking.

Without a number, `edit` and `delete` act on the only testcase when there is one, and ask
which when there are several. The editor shows the input and the expected output side by
side: `<C-s>` saves and closes, `q` closes without saving.

## testcase split

```
:Tuna testcase split [n] [marker]
```

Breaks one testcase into several. Mark the cases inside it with a line of `-` (the
`testcases_split_markers` character, or the marker you type), in the input and the expected
output alike. Markers come in pairs: one opens a case, the next closes it, and what a pair
brackets becomes a testcase of its own, with a verdict of its own. Everything outside every
pair stays in the testcase you split.

The split is deliberately mechanical: where a case ends depends on the problem's input
format, so the boundaries are yours to place. It refuses, leaving the testcase untouched,
when a pair is left open, when a pair brackets nothing, when the expected output brackets a
different number of cases, or when a non-empty expected output has no markers at all. If
the input starts with a case count, tuna then offers to fix it.

## convert

```
:Tuna convert <files|single_file|directory>
```

Rewrites the problem's testcases from one storage layout into another. The layout they are
in now is detected for you, and its files are removed once the testcases are rewritten.

The storage backends, chosen with `testcases_storage`:

|                   | layout                                                             |
| ----------------- | ------------------------------------------------------------------ |
| `files` (default) | `main_input0.txt` / `main_output0.txt` beside the source           |
| `single_file`     | every testcase in one msgpack file, `main.testcases`               |
| `directory`       | one sub-directory per testcase, `tests/0/input.txt` + `output.txt` |

## compare

```
:Tuna compare [exact|squish|float [tol]|default]
```

Overrides how the output is compared with the expected output, for this problem only. It is
remembered across restarts.

- `exact` compares character for character.
- `squish` ignores how the output is spaced: runs of whitespace and line breaks count as one
  space, and leading and trailing whitespace is dropped.
- `float` compares token by token, accepting numbers within an absolute or relative error of
  `tol` (`1e-6` when not given).
- `default` goes back to `output_compare_method` from your config.

Without an argument it changes nothing and says which method is in use.

## checker

```
:Tuna checker [auto|off]
```

- `auto`, the default, judges with the problem's checker when there is one: a `checker.*`
  file beside the solution, or the `checker` option. It runs as
  `checker <input> <output> <answer>`, testlib's order, and exit code 0 means correct.
- `off` ignores the checker and compares the outputs (see [compare](#compare)).

The choice is remembered for the problem. Without an argument it changes nothing and says
which of the two is set, and which checker that finds.

## download

```
:Tuna download <testcases|problem|contest|sync|persistently|status|stop>
```

Opens a listener for [Competitive Companion](https://github.com/jmerle/competitive-companion).
Press the green plus in your browser and tuna does the rest.

- `problem` writes a solution file from your template and its testcases.
- `contest` does the same for every problem of a contest, each in its own place.
- `testcases` adds only the testcases, to the solution you are in.
- `sync` downloads like `contest` (or `problem`, see `scratch.download`) and folds your
  [`:Tuna scratch`](#scratch) file into the first problem it writes.
- `persistently` keeps the listener open for the whole session.
- `status` says whether the listener is open, and `stop` closes it.

Where everything lands is set by `downloaded_problems_path` and
`downloaded_contests_directory`. A problem that already exists is asked about before it is
overwritten, and a contest asks once for the whole batch, offering to write only the
problems that are missing.

## scaffold

```
:Tuna scaffold <checker|generator|bruteforce|interactor> [ext]
```

Drops a starter for a helper program beside the solution, named so that a run finds it
(`gen.cpp`), in your solution's language, in `ext` when given, or in `scaffold.language`.
tuna ships `cpp` and `py` starters, and a file called `<role>.<ext>` in your
`scaffold.directory` is used instead, so replacing a starter or adding a language is
dropping a file there.

## submit

```
:Tuna submit [clear]
```

Hands the solution to the submit tool you configured, reads its output as it runs, and puts
the judge's verdict in your statusline. `clear` dismisses the verdict, and cancels a
submission still being watched. Setting it up is described in the README's
[Submitting](README.md#submitting) section.

## next and prev

`:Tuna next` and `:Tuna prev` open the problem either side of this one in its contest,
preferring the file name you are leaving (`A/main.cpp` to `B/main.cpp`). At either end of
the contest they say so rather than wrapping around.

## last

```
:Tuna last [problem|contest]
```

Goes back to the problem, or the contest, you were last working on, across restarts, and
moves Neovim's directory there with you. Bare `:Tuna last` means the problem.

## pin

`:Tuna pin` puts the problem you are on aside to solve later, and running it again takes it
back. Pinned problems wait in the [menu](#menu), most recently pinned first. A pin stays
until you unpin it or delete the solution.

## scratch

`:Tuna scratch` opens a scratch solution for the minutes before a contest starts, when there is
no problem to download yet, asking which of your templates to start from. An existing
scratch first asks whether to resume it or restart. [`:Tuna download sync`](#download) then
folds what you wrote into the first problem it downloads.

## lib

```
:Tuna lib [snippet|search]
```

Copies a piece of your own library into the file you are writing. The library is plain
source files under `library.path`, with the parts worth copying marked in place:

```cpp
// TUNALIB: binary exp start
long long bexp(long long b, long long e, long long m) { ... }
// TUNALIB: binary exp end
```

Bare `:Tuna lib` picks a file, then a snippet in it. `snippet` lists every snippet at once,
and `search` opens the same catalogue in telescope. Only files with the current file's
extension are offered, and what is inserted is re-indented to where the cursor is.

## clean

`:Tuna clean` removes files you created and never used, such as templated solutions still
holding the template and scaffolds you never filled in, and then the directories they leave
empty. You choose where to look, how deep, and how close to its template a file must still
be. Every deletion is confirmed one at a time, with the file in front of you, and a pinned
problem is named as pinned.

## checkhealth

`:checkhealth tuna` reports what tuna can see: your Neovim version, whether each configured
compiler and interpreter is on `PATH`, the Competitive Companion port, your submit setup and
the optional plugins.

# Configuration

## Where settings come from

Settings come from three layers, each overriding the one before:

1. the defaults;
2. what you pass to `setup()`;
3. a `.tuna.lua` anywhere above the file you are editing, returning a table, so a contest
   folder can set a different time limit, template or testcase layout for everything under it
   without touching your config.

Every option, with its default and what it does, is commented in
[`lua/tuna/config.lua`](lua/tuna/config.lua) and documented in `:h tuna-configuration`. The
sections below cover what takes more than a line.

## Modifiers

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
  <td>for Java solution templates</td>
</tr>
<tr>
  <td><code>$(DATE)</code></td>
  <td>now, formatted with <code>date_format</code></td>
</tr>
</table>

Characters that cannot appear in a filename are replaced with `_` in every modifier that
becomes part of a path.

## Compiling and running

`compile_command` and `run_command` are argv, not shell lines: `exec` is the program and
`args` is a list, so nothing is word-split or glob-expanded behind your back.

## Testcases

A `testcases_*_file_format` without `$(TCNUM)` names a _single_ testcase, which is what
makes a bare `in.txt` / `out.txt` pair work.

## Downloading

Downloading a problem whose target already exists asks before overwriting; downloading a
contest asks **once** for the whole batch, and offers to write only the problems that are
missing — which is what re-downloading a contest you are half-way through should do.

## Templates

`template_cursor` takes a line number, a Lua pattern to search for, `{ pattern, offset }`
for _n_ lines below the match, or a function. A pattern that matches nothing leaves the
cursor alone, so one written for C++ is harmless to a Python template.

## Keymaps

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

The actions, each running the `:Tuna` command it is named after: `menu`, `run`, `run_all`,
`run_stress`, `run_interactive`, `show_ui`, `add_testcase`, `edit_testcase`,
`delete_testcase`, `submit`, `submit_clear`, `download_testcases`, `download_problem`,
`download_contest`, `download_sync`, `clean`, `pin`, `next_problem`, `prev_problem`,
`last_problem`, `last_contest`, `scratch`, `library`, `library_snippet` and `library_search`.

## Appearance and widgets

`runner_ui.mappings` names its actions `run_again`, `run_all_again`, `stop`, `stop_all`,
`toggle_diff`, `view_input`, `view_expected`, `view_stdout`, `view_stderr`, `add_testcase`,
`delete_testcase`, `undo_delete`, `split_testcase`, `close` and `help`, each taking a key
or a list of them.

Highlight groups: `TunaCorrect`, `TunaWrong`, `TunaWarning`, `TunaRunning`, `TunaDone`,
`TunaEditable`, `TunaMenuTitle` (the menu's banner letters; the banner has no background of
its own, so what is behind it shows between them), and `TunaDiffChange` / `TunaDiffText` /
`TunaDiffAdd` / `TunaDiffDelete`.
Override any of them with `:hi` after startup — they are re-applied on `ColorScheme`, so
they follow your theme.
