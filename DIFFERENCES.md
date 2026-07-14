# Differences from competitest.nvim

This file tracks where `tuna.nvim` intentionally diverges from or improves on
[competitest.nvim](https://github.com/xeluxee/competitest.nvim), the plugin it is
a successor to. It's a living document — we add to it as decisions are made, and
it will seed the "differences / why switch" section of the final README.

Legend: ✅ done · 🚧 in progress · 📌 planned/decided, not yet implemented

---

## UI: native APIs instead of `nui.nvim`

📌 **Decision:** tuna builds its UI on Neovim's native `vim.api` floating windows
and splits. It does **not** depend on `nui.nvim`.

**Why:** competitest.nvim requires `nui.nvim` for every piece of its UI (testcase
editor, picker, input prompt, runner popup/split). As of Neovim 0.12 the core UI
(`ui2`, default float borders, etc.) covers most of what `nui.nvim` was used for,
and the community trend in 2025–2026 is to drop the abstraction layer in favor of
native floats (or, where a toolkit is wanted, `snacks.nvim`). Going native keeps
startup lean and removes a runtime dependency, which matches tuna's goals of
speed and minimal overhead.

**Trade-off:** we reimplement the recursive layout engine and popup/split
plumbing that competitest got for free from `nui.nvim`. The layout logic is small
and ports cleanly.

**Consequence:** tuna targets a more recent Neovim baseline than competitest's
0.5+. Exact minimum TBD when the UI modules land.

**Float filetype:** every tuna widget float (`widgets.open_float`: menu / input /
picker / editor) sets `filetype = "tuna"` on its buffer, mirroring how e.g.
telescope tags its prompt (`TelescopePrompt`). This lets users and other plugins
target tuna floats. It also side-steps a class of third-party bug: plugins that
write the **global** `scrolloff` off the focused window's height (e.g.
`scrollEOF.nvim`'s `vim_resized_cb`) will clobber it to `0` when a *short* float
(tuna's 1-line input prompt → `height/2 = 0`) gains focus. Such plugins honor a
`disabled_filetypes` list, so adding `tuna` to it stops the clobber; the real fix
belongs upstream (those callbacks should skip floating / non-normal windows).

---

## Testcase storage: fully user-customizable layout

✅ **Decision:** the on-disk testcase layout is a user choice, with multiple
options supported out of the box rather than one imposed structure.
(Config keys + all three storage backends implemented and tested; the
`convert` command that exposes them to users is wired up in step 9.)

competitest exposes a single boolean `testcases_use_single_file` to pick between
two storage modes. tuna replaces it with a `testcases_storage` enum offering
**three** modes:

| `testcases_storage` | layout | naming option(s) |
| --- | --- | --- |
| `"files"` (default) | a pair of text files per testcase, beside the source | `testcases_input_file_format`, `testcases_output_file_format` |
| `"single_file"` | one msgpack-encoded file | `testcases_single_file_format` |
| `"directory"` | one sub-directory per testcase | `testcases_directory_format`, `testcases_directory_input`, `testcases_directory_output` |

The `"directory"` mode (e.g. `tests/0/input.txt` + `output.txt`) is new — it
isn't available in competitest at all. `testcases_auto_detect` falls back to the
other modes when the configured one finds nothing. The `convert` command can
move testcases **between any two of the three modes**, including to/from the new
`directory` mode (competitest only converts files ↔ single-file).

**Why:** different users and judges expect different layouts; making it
configurable avoids forcing a migration on anyone coming from either convention.

### Auto-discovery of shared testcases (`files` mode)

competitest names `files`-mode testcases after the source file, so testcases are
only ever found for the exact source that created them — running a *second*
solution (or a differently-named download) against the same testcases finds
nothing. tuna makes `testcases_input_file_format`/`testcases_output_file_format`
accept an **ordered list** of formats (a single string still works). On load they
are tried in order and the **first that discovers any testcase wins**; the first
entry stays canonical for writing. The default,

```lua
testcases_input_file_format  = { "$(FNOEXT)_input$(TCNUM).txt",  "input$(TCNUM).txt"  },
testcases_output_file_format = { "$(FNOEXT)_output$(TCNUM).txt", "output$(TCNUM).txt" },
```

tries the source-named pair first (fully backward compatible), then a shared,
un-prefixed `input<N>.txt`/`output<N>.txt`, then a **numberless** `in.txt`/`out.txt`.
So any solution in a folder — every version in `:Tuna run all`, or a source whose
name differs from the download — picks up the same testcases without configuration.

A format **without** `$(TCNUM)` (like `out.txt`) names a *single* testcase (index 0)
rather than a numbered series, and a testcase may have **only an input or only an
output** — an output with no matching input still runs, with the solution fed empty
stdin. So a bare `main.cpp` + `out.txt` folder is runnable with zero setup.
competitest required numbered `input`/`output` pairs and had no numberless or
output-only form.

**Why first-non-empty (not merged):** a folder that legitimately holds two
problems distinguished by source prefix stops at the prefixed format and never
mixes their testcases together; only when the source-specific search comes up
empty does the shared fallback apply. `files.buf_clear` conversely deletes files
matching **any** configured format, so `convert` still cleans up fallback-named
testcases.

---

## Smaller config differences

📌 Recorded as we port `config.lua`, to mention in the final README:

- **Border highlight via `winhighlight`.** `floating_border` is passed straight
  to `nvim_open_win`. competitest's `floating_border_highlight` is kept (same
  name, same default `FloatBorder`) but implemented natively: every Tuna float
  remaps its `FloatBorder` group through `winhighlight` (`utils.set_border_highlight`)
  instead of nui's `border.highlight`. Native splits have no `FloatBorder`, so the
  option only affects floats.
- **`editor_ui` size keys renamed.** competitest's `editor_ui.popup_width` /
  `popup_height` become `editor_ui.width` / `height` — consistent with
  `picker_ui` and `viewer`, which already use `width`/`height`.
- **Picker navigation is native.** competitest's `picker_ui.mappings.focus_next`
  / `focus_prev` are dropped; the picker is an ordinary buffer, so `j`/`k` and the
  arrow keys move the selection (with `cursorline`). Only `submit`/`close` remain
  configurable.
- **`convert` requires an explicit target.** competitest's `convert auto` inferred
  the direction because there were only two storage modes. With three backends
  (`files`/`single_file`/`directory`) "auto" can't pick a unique target, so
  `:Tuna convert <target>` always takes a target; the *source* is still
  auto-detected.
- **Python default is `python3`.** competitest defaults the Python run command
  to `python`, which is Python 2 on some systems; tuna uses `python3`.
- **Local config search.** Both plugins walk up the directory tree for a local
  config file; tuna uses `vim.fs.find(..., { upward = true })` instead of a
  hand-rolled loop. (Behaviour parity — noted only as an implementation note.)
- **Single-file storage read as raw bytes.** competitest reads its msgpack
  single-file through a helper that rewrites CRLF→LF, which can corrupt the
  binary payload; tuna reads it verbatim (`utils.read_file(path, true)`).

---

## Receive: live listener status for lualine

✅ **Decision:** `receive.lua` exposes `status()`, `is_receiving()` and `mode()`,
and `require("tuna").lualine_component` renders `status()` — an empty string when
idle, or e.g. `🐟 receiving contest` while the listener is live.

**Why:** competitest only offers `show_status()`, a one-shot notification you have
to ask for. With a persistent receive mode it's easy to forget the listener is
running (or to think it is when it isn't). Surfacing the state continuously in the
statusline is a small but real quality-of-life win, and it costs nothing — the
component is just a string read from module state.

---

## User-customizable per-judge parsing (`judges.lua`)

✅ **Done (Workstream 3).** competitest normalized Competitive Companion's
`task.group` ("Judge - Contest") into folder names with a **hardcoded** block that
only knew Codeforces and AtCoder, buried in the receive path — to support another
judge you had to patch the plugin. tuna extracts this into `judges.lua`: a
`judge_parsers` config table of per-judge **parser functions**, with the CF/AtCoder
logic shipped as built-in defaults.

```lua
judge_parsers = {
  -- add a new judge
  codechef = function(ctx) return { contest = ctx.contest:match("starters%s*%d+") } end,
  -- override or disable a built-in (`false` keeps the raw contest name)
  atcoder = false,
  -- catch-all applied to any judge without its own parser
  ["*"] = function(ctx) return { contest = ctx.contest:gsub("%s*%b()", "") } end,
}
```

A parser receives `{ judge, contest, group, task }` (judge/contest already split and
lowercased) and returns `{ judge?, contest? }` overrides — nil fields keep the parsed
values, so a parser only states what it changes. Resolution per judge is **user
parser → built-in → user `["*"]` catch-all**, and a parser is `pcall`-guarded so a
buggy one warns and falls back to the raw contest instead of breaking a receive. The
built-in Codeforces/AtCoder normalizers are unchanged in behaviour from competitest —
they're just now defaults you can replace.

**Why:** contest-naming conventions differ per judge and change over time; making the
rules data (config) rather than code lets users support CodeChef/USACO/etc. and fix
naming without forking the plugin.

---

## Submit integration (`submit.lua`, `:Tuna submit`)

✅ **Done (Workstream 4).** Brand new — competitest has no submit support at all
(the community's PR #87 for it is still open upstream). `:Tuna submit` hands the
current solution to an **external** submit tool through a **provider registry**, so
it's agnostic to which judge/tool/language you use.

```lua
submit = {
  provider = "command",
  command  = 'subwithoutcred "$(URL)" "$(LANG)" "$(FABSPATH)"',
  url          = "submit at:%s*(%S+)",  -- header marker (a template writes it), or a function
  languages    = { cpp = "C++", python = "Python 3", ... },  -- filetype -> submit tool's lang name
  terminal     = "auto",   -- toggleterm if installed, else a native :terminal split
}
```

Design notes:

- **Provider registry** (`M.providers[name]`) leaves a clean seam for future
  first-class providers (e.g. a Kattis provider, per PR #87). The shipped default is
  the `command` provider, which expands a shell command through the modifier engine —
  gaining `$(URL)` and `$(LANG)` on top of the usual `$(FABSPATH)`/`$(FNAME)`/… — and
  runs it in a terminal.
- **URL resolution** is header-marker-first with a sidecar fallback: it scans the
  file header for a configurable marker (e.g. `submit at: <url>`, which a template
  embeds via the existing `$(URL)` receive modifier), and if absent reads a
  per-problem sidecar (`.tuna.json`) that the receive path now writes with the task's
  URL. So both templated and freshly-received problems are submittable with no manual
  URL entry.
- **Terminal** prefers a cached toggleterm (mirroring the common setup) but falls back
  to a native `:terminal` split, so toggleterm is detected-and-used, never required.
- **lualine verdict (watch mode)**, matching the receiver's `status()`/`is_receiving()`.
  With `submit.watch = true` the command runs as a tracked `vim.system` job (no
  terminal); tuna strips ANSI from its stdout, takes the latest `\r`/`\n` status
  segment, and classifies it via the ordered `submit.verdicts` `{ pattern → state }`
  rules into a live `Testing → Accepted / Wrong Answer / …` verdict. State is **kept
  per solution buffer and persists until the next submit** — so the indicator is bound
  to a problem, not a timer — colored by verdict via `submit.verdict_hl`
  (`TunaCorrect`/`TunaWrong`/`TunaWarning`). This turns submit into a full
  no-terminal loop for tools that poll a verdict (e.g. the Rust `submitter`); a run
  that reaches no final verdict surfaces an `error` state + a notification. The
  default (no `watch`) keeps the fire-and-forget terminal with a brief pending flash
  (`status_time`), for submit tools that don't report a verdict.
- **Persists across restarts, invalidated on edit.** A final verdict is written into
  the per-problem sidecar (`.tuna.json`, alongside the URL/name) keyed by file name,
  with the source's mtime. On `BufReadPost` the verdict is restored into lualine —
  unless the file was edited since (mtime mismatch) — and it's dropped the moment you
  edit the buffer (`TextChanged`), because a verdict no longer describes changed
  source. So the indicator is genuinely bound to *this* problem's *submitted* state.

**Why:** submitting is the last manual step in the loop; folding it into the plugin
(configurably, not hardcoded to one tool) removes the last reason to drop back to a
shell, and the provider seam keeps it open to new judges.

---

## Runner UI: native windows, simpler hide/show

✅ **Decision:** the runner results UI (`runner_ui/`) is built on native floats
and splits, sharing competitest's recursive `{ ratio, child }` layout engine but
none of its `nui.nvim` window objects.

Two simplifications fall out of going native:

- **Close-and-rebuild instead of hide-and-restore.** All displayed content lives
  in the runner's `tcdata`, so closing the UI just tears the windows down and
  showing it rebuilds and re-renders. competitest preserved hidden `nui` buffers
  and re-showed them; tuna doesn't need to, which removes a layer of state.
- **Split `relative_to_editor` is approximate.** competitest's `nui.split` could
  anchor a split to the editor edge regardless of the current window; the native
  `nvim_open_win({ split = … })` splits a specific window. tuna splits off the
  runner's window, which coincides with the editor edge in the usual
  single-window competitive-programming layout.

A native gotcha worth recording: a float's `row`/`col` anchor its **content**,
with the border drawn outside, so the popup layout offsets each window by +1 to
make footprints tile exactly. And because the viewer popup *borrows* a detail
pane's buffer, the UI's `:q` handling is keyed on **window id**, not buffer —
otherwise closing the viewer would tear down the whole UI.

**One UI, many run modes (`runner/core.lua`).** Every run mode — normal, stress,
interactive, and later run-all — drives the *same* `runner_ui` through a shared
`RunnerCore` base rather than each mode reimplementing the UI plumbing and the
spawn-and-judge routine. A mode subclasses the base and supplies only its own loop
(parallel lanes / a generation search / interactive sessions); the UI stays
mode-agnostic through two seams — `runner:pane_content(name)` (what each pane shows,
or `SKIP` to leave it alone) and `runner:on_ui_shown(ui)` (augment the built UI, e.g.
interactive making the Input pane editable). This is what lets interactive get a
first-class results UI for a few dozen lines instead of a fourth copy of the runner.

---

## `init.lua`

- **Modern autocmd/highlight APIs.** competitest registered its command,
  completion, `ColorScheme`/`VimResized`/`VimEnter` autocmds, and highlight
  groups through `vim.cmd`/`nvim_command` string blocks (including a Vimscript
  `s:command_completion` function). tuna uses `nvim_create_user_command`,
  `nvim_create_autocmd` under a cleared `Tuna` augroup, and `nvim_set_hl` with
  `default = true` (the API equivalent of `hi! def`). Completion is a Lua
  function in `commands.complete`, not Vimscript.
- **`once = true` VimEnter.** Persistent-receive-on-setup before startup is wired
  with a one-shot `VimEnter` autocmd instead of a self-persisting `autocmd
  VimEnter` line; it fires exactly once and needs no manual cleanup.
- **Lazy requires in callbacks.** The command and completion callbacks
  `require("tuna.commands")` at call time rather than at module load, keeping
  `setup()` startup cost minimal (a project goal) and avoiding load-order cycles.

---

# Phase 3 — extensions beyond competitest

New capabilities tuna adds that competitest never had. (See the Phase 3 roadmap.)

## Helper programs by convention + run modes (`tools.lua`)

✅ **Done.** The stress/checker/interactive extras originally forced a `.tuna.lua`
per problem, spelling out each helper as a command spec — which pushed people toward
**shell** checkers. That's backwards from how competitive programmers actually work
(see ali-ibrahim137's stress-testing article): the generator, brute/reference,
checker and interactor are ordinary **source files in the solution's own language**.

`tools.lua` makes that the default. Helpers are discovered **by filename
convention** beside the solution — `checker.*`, `gen.*`, `brute.*`, `interactor.*`
(aliases and names configurable via `tool_names`) — then compiled and run with the
**same config-driven commands as a solution of that language** (so a Python helper
beside a C++ solution just works). A source checker is compiled **once**, on first
use, and cached (`tools.prepare`), so parallel judges don't recompile or race.
Config specs still override discovery, and a prebuilt binary / shell script still
works — but no `.tuna.lua` is required to stress-test or special-judge.

Because you no longer flip modes by editing config, tuna adds a **per-buffer run
mode**: `:Tuna run [normal|all|stress|interactive]`. A bare `:Tuna run` **auto-detects
the mode from the sibling files** — an `interactor.*` ⇒ interactive, a `gen.*` +
`brute.*` pair ⇒ stress, otherwise normal — so dropping the right helpers next to
the solution is enough. Passing a mode explicitly (or picking one in the `:Tuna`
menu) **pins** it, so later bare `:Tuna run`s repeat it; but if the files that mode
needs are later deleted, tuna falls back to auto-detection rather than failing on a
now-impossible mode. A **checker toggle** (`:Tuna checker [on|off]`, or the menu)
turns special judging off for a buffer without deleting `checker.cpp`. competitest
had a single `:CompetiTest run` and no notion of modes or helper discovery.

## Pluggable checkers (`checker.lua`)

✅ **Done (Workstream 1).** competitest could only decide a verdict by comparing
program output against the expected output (`exact` / `squish` / a custom Lua
function). tuna keeps that as the `"builtin"` checker but adds support for an
**external, testlib-style checker program** — usually a **source file in the
solution's language**, discovered as `checker.*` and compiled automatically:

```lua
checker = "builtin"    -- default: plain comparison, OR a discovered checker.* if present
checker = "~/cp/checkers/wcmp"                       -- an explicit checker binary
checker = "$(ABSDIR)/checker.py"                     -- an explicit checker source file (compiled if needed)
checker = { exec = "$(ABSDIR)/chk", args = { ... } } -- full control over a prebuilt binary
```

With the default `"builtin"`, dropping a `checker.cpp` (or `checker.py`, …) next to
the solution switches that problem to special-judge mode with no config; the
per-buffer checker toggle (`:Tuna checker off`) forces plain comparison back on.
An external checker is invoked as `checker <input> <output> <answer>` (the testlib
convention: jury input, participant output, jury answer); exit code `0` is correct,
anything else is wrong, and its stderr/stdout becomes the verdict message
(`tc.checker_message`). The three files are passed through the `$(INPUT)`,
`$(OUTPUT)`, `$(ANSWER)` placeholders in `args` (defaulted when omitted).

**Why it's the foundation:** stress testing, interactive problems, and
multiple-solution problems all need a verdict that isn't plain string equality, so
the runner now routes every clean exit through `checker.judge` instead of calling
`compare` directly. Because an external checker is a separate async process, the
runner tracks a per-testcase `judging` flag so a run isn't declared complete before
its verdict lands.

### Builtin float-tolerant comparison

competitest's only tolerant option was `squish` (whitespace-insensitive but still an
**exact** textual match), so floating-point problems forced you to write a custom
`output_compare_method` function or a full checker. tuna adds a builtin `"float"`
method selected as a table carrying its options:

```lua
output_compare_method = { "float", tol = 1e-6 }   -- default tol is 1e-6
```

It compares token-wise: a numeric token matches when it is within `tol` **absolute
or relative** error of the expected token, while any non-numeric token (or a
numeric-vs-text mismatch, or a differing token count) must match exactly. So
`YES\n3.1400001` passes against `YES\n3.14` but `NO` never passes against `YES`.
The table form (`{ builtin, opts... }`) is the general shape for any option-bearing
builtin; `exact`/`squish`/custom-function all still work unchanged.

The method can also be switched **at runtime, per buffer**, without touching config
— `:Tuna compare <exact|squish|float [tol]|default>` (e.g. `:Tuna compare float 1e-9`;
`default` clears back to the configured method), and a **Compare** entry in the
bare-`:Tuna` menu that cycles the methods. This mirrors the per-buffer `:Tuna checker`
toggle (state in `tools.lua`, keyed by file path), so a float problem needs neither a
config edit nor a local `tuna.lua`. competitest had no runtime way to change the
comparison method at all.

## Stress testing (`stress.lua`)

✅ **Done (Workstream 2).** Brand new — competitest has no stress testing. `:Tuna
run stress [count]` hunts for a small input on which the current solution disagrees
with a trusted reference. By convention it uses a sibling `gen.*` (generator) and
`brute.*` (reference) — **no config needed**; the `stress` table only overrides:

```lua
stress = {
  generator = nil,    -- override discovery, e.g. { exec = "python3", args = { "$(ABSDIR)/gen.py" } }
  reference = nil,     -- override discovery: a correct-but-slow solution
  count = 100,         -- max generator iterations
  seed_arg = true,     -- append the iteration number as the generator's last arg
  saves_per_run = 1,   -- counterexamples to save per run before stopping
  max_saved = 10,      -- hard cap on the total testcase count stress will grow to
}
```

Each iteration: the generator is run with a reproducible seed (the iteration
number) → its stdout is the input → the solution and the reference both run on it →
their outputs are judged with the **same `checker`** the runner uses (so
multiple-correct-answer problems — and any custom checker — work here too). A wrong
answer, crash, or timeout is **saved as a new testcase** (input + the reference's
answer as expected output).

Unlike a bare "find one and stop", stress opens its **own results UI** — the same
`runner_ui` the normal runner uses — that first re-runs the problem's existing
testcases and then appends each counterexample as it's found. Its status pane shows
the run mode, the verdict source, the live iteration count, and both save
thresholds. The search stops as soon as either threshold is hit: `saves_per_run`
counterexamples saved this run, or `max_saved` total testcases on disk. Inside the
UI you can re-run a single (saved) testcase, restart the whole search, or stop it.
A `StressRunner` implements just enough of the `TCRunner` surface (`tcdata`,
`mode`, `judge_label`, `kill_*`, `run_single`, `run_testcases`, a `status_text`)
for the UI to drive it.

**Reuse, not reinvention:** `stress.lua` calls `runner.new()` to resolve the
solution's compile/run commands, working directories, and checker, then drives the
loop with `vim.system` (using its `timeout` option) and `checker.judge` from
Workstream 1.

**Compile cache (`tools.prepare`).** Helpers (generator/reference/checker/…) are
compiled through a *persistent, session-wide* cache keyed by the source's absolute
path + mtime + exact compile command. So a repeated `:Tuna run stress` recompiles
only what actually changed (usually just the solution) and reuses the unchanged
`gen`/`brute` builds, keeping the edit-and-re-run loop fast. Editing a source, or
changing its compile flags, invalidates the entry and rebuilds.

📌 **README note — recommended C++ setup (precompiled `bits/stdc++.h`).** Tuna
compiles helpers with the *same* command as `:Tuna run` (the per-language
`compile_command`), so a precompiled-header setup is honoured everywhere (normal
run, stress, run-all, checkers). We should recommend, in the README, the
competitive-programming standard of a precompiled `<bits/stdc++.h>`: e.g. a
`~/cp/bits/stdc++.h.gch` built with the *exact* flags used in `compile_command`
(`-std=… -DLOCAL -Wall … -I$(HOME)/cp`), and `#include <bits/stdc++.h>` in the
solution/helpers. Because stress compiles three programs (solution + generator +
reference), the PCH is what keeps that fast — without it each translation unit
re-parses the whole standard library. (Verified: with the PCH, three heavy TUs
compile in ~2.6 s vs ~6.9 s without.)

## Interactive problems (`interactive.lua`)

✅ **Done (Workstream 2).** Brand new — competitest can't run interactive problems
at all, and can only *drive* them with a written interactor. tuna's
`:Tuna run interactive [live|feed|interactor] [n…]` offers **three sources** for the
other side of the conversation, in its own results UI:

- **live** — *you* are the other side. The solution's stdout streams into the Output
  pane; you type into the (editable) Input pane and each `<CR>` line is sent to the
  solution's stdin. No auto-verdict — you read the transcript. This is the common
  case (poke at the solution by hand) that competitest has no answer for.
- **feed** — a pre-written input plays the other side **one line per turn**: each
  time the solution emits a line, the next input line is sent. Judged against the
  expected output if the testcase has one, else DONE.
- **interactor** — a written `interactor.*` program (or `interactive.interactor`) is
  cross-wired to the solution and rules the verdict. Secondary: auto-used only when
  an `interactor.*` sibling exists. The chosen source is remembered per buffer, so a
  bare `:Tuna run` repeats it.

```lua
interactive = { interactor = nil } -- override, e.g. { exec = "python3", args = { "$(ABSDIR)/interactor.py" } }
```

In interactor mode the solution and interactor are spawned and their pipes are
cross-wired — solution stdout → interactor stdin, interactor stdout → solution stdin
— and the interactor's exit code is the verdict (0 = CORRECT). The interactor gets
the testcase input/answer as files via the `$(INPUT)` / `$(ANSWER)` placeholders.

**Native-pipe gotcha worth recording:** `vim.system` only surfaces a child's stdout
once it *exits*, so it can't relay bytes between two live processes. tuna drops to
`vim.uv.spawn` and forwards data between the pipes by hand, shutting down a peer's
stdin on EOF and guarding every write against a pipe that teardown has already
closed. A timeout timer and the interactor-exits-first / solution-crashes-first
orderings are handled explicitly.

## Multiple-answer problems (the external checker)

✅ **Done.** A problem that accepts several valid outputs (e.g. "print two numbers
that sum to 3" → both `1 2` and `2 1`) is handled by the checker. competitest's
custom comparator was `function(output, expected)` — it never saw the **input**, so
it couldn't validate input-dependent answers. tuna's checker is a **testlib-style
external program** that receives the input, participant output, and jury answer
(`checker <input> <output> <answer>`) and decides the verdict — the standard special
judge every judge/testlib user already knows. It's discovered by convention
(`checker.*`) or set via `checker = { exec, args }` / a path, and the same capability
flows through `:Tuna run`, `run stress`, `run interactive`, and `run all`.

## Multiple solution versions (`multi.lua`, `:Tuna run_all`)

✅ **Done.** Keep several attempts side by side (`main.cpp`, `slow.cpp`, …) and
`:Tuna run all` compiles and runs *every* runnable sibling solution — **of any
language** (each file's compile/run commands come from its own filetype, so a C++
and a Python attempt run side by side) — against the shared testcases. Helper files
(`checker.*`, `gen.*`, `brute.*`, `interactor.*`) are excluded so they aren't
mistaken for solutions. competitest only ever ran the current file. (This is distinct
from multiple-*answer* support above — here it's multiple *programs*.)

Results show in the same `runner_ui` as every other mode, laid out as a **flattened
matrix**: a solution header row (name + a live `correct/total`) above its indented
per-testcase rows. Selecting a testcase row shows that exact run in the detail panes;
selecting a solution row shows its per-testcase summary and any compile output. A
solution that fails to compile is a `CE` row (its cases marked `—`), surfaced in the
UI rather than as an error popup — so one broken attempt doesn't abort the batch.

## Scaffolding (`scaffold.lua`, `:Tuna scaffold …`)

✅ **Done.** `:Tuna scaffold <checker|generator|brute|interactor> [ext]` drops a
dependency-free starter (no testlib needed) into the problem directory and opens it,
giving a clean on-ramp to the convention-named helpers that stress testing, special
judging, and interactive problems discover. The file is created in the **solution's
language** by default (or the language named by `[ext]`); built-in templates ship
for C++ and Python, and both the base filenames and the templates — per kind and
**per language** (`{ [ext] = path }`, like `template_file`) — are overridable via
`config.scaffold`. competitest had nothing comparable.

## The `:Tuna` dashboard (`dashboard.lua`)

✅ **Done (evolving, W8).** Bare `:Tuna` (or `:Tuna dashboard`) opens a native chooser
that switches the buffer's **run mode**
(normal / run-all / stress / interactive), toggles the checker, cycles the compare
method, shows the results UI, scaffolds a helper, or cleans unused files — so the
Phase 3 features are discoverable without memorising subcommands, and picking a mode
here is what a later bare `:Tuna run` repeats. In competitest a bare `:CompetiTest`
was an error. This started as an inline "mode-switcher menu" and has been promoted to
its own `dashboard.lua` — the seed of the fuller contest hub (problem navigation,
at-a-glance status) it will grow into.

## Clean unused files (`clean.lua`, `:Tuna clean`)

✅ **Done (W5).** A competitive-programming workflow accretes clutter: every received
or templated problem drops a solution file, and `:Tuna scaffold` drops helper stubs —
many of which are never touched. `:Tuna clean` sweeps them up. The catch competitest
never had to solve is that these files **aren't empty** — they carry a template — so
"unused" is defined as *"content still matches the template that would generate it."*
tuna turns the template into a pattern with each `$(...)` modifier as a wildcard, so
it recognises an untouched file whether the template was copied verbatim (modifiers
left literal) or expanded via `evaluate_template_modifiers`; scaffolds are matched
against their `scaffold` template, solutions against `template_file`, and a
template-less file is unused only when empty. The entire interaction runs through
tuna's **floating widgets, not `vim.ui.input`/`confirm` command-line prompts**: a
single **form** (three stacked lists shown at once — Tab / `<M-j>`/`<M-k>` switch,
`<CR>` submits all) picks the directory (prefilled with the roots derived from the
`received_*`/`template_file` config, plus "Other directory…"), the recursion depth
(infinite by default, or a custom number), *and* the **match threshold** — because
"unused" is measured as a **similarity percentage** to the template (a line-LCS
ratio), the user can erase files that are, say, ≥ 95% the template (full match / 95% /
custom), not only byte-for-byte untouched ones. Then a **per-file confirmation menu**
(Delete / Keep / Stop, showing each file's match %) — with a **read-only preview of
the file rendered beneath the prompt** (scroll with `<C-d>`/`<C-u>`) — guards every
deletion. Form/list navigation uses the plugin-wide pane keys (`switch_window_keys`,
default `<C-hjkl>`). Clean may delete the file it was launched from and stays robust:
the file's buffer is wiped afterwards (kept, if it has unsaved edits). competitest had
no cleanup facility at all.

## Health check (`health.lua`, `:checkhealth tuna`)

✅ **Done (W7).** tuna ships a `lua/tuna/health.lua` so `:checkhealth tuna` gives a
one-shot diagnosis of a setup — the single biggest self-service answer to "why
doesn't it work?" It reports the Neovim version (errors below 0.10, since tuna needs
`vim.system`/`vim.uv`), whether `setup()` ran, which configured compilers/interpreters
are actually on `PATH` (skipping per-problem build outputs like `./$(FNOEXT)` that
don't exist pre-compile), the Competitive Companion listener port + live state, the
submit tool's presence (and, for the browser provider, clipboard availability), and
optional integrations (toggleterm/lualine). It is read-only — it never spawns a
compiler or touches state. competitest had no health check; users diagnosed broken
setups by trial and error.

## Receive duplicate handling in the floating UI

✅ **Done.** When a received problem or contest would overwrite existing files,
competitest asked with a command-line `confirm`. tuna keeps the whole receive flow in
its floating widgets: a duplicate **problem** shows an `Override`/`Stop` menu, and a
**contest** shows a *single* `Override all`/`Stop` menu for the whole batch (resolved
up front by scanning every target path) rather than one prompt per problem — decide
once for the contest. Dismissing either (Esc) counts as "stop" and, via the menu's new
`on_close` hook, still advances the batch processor so a cancellation never wedges it.

<!-- Add new entries above this line as decisions are made. -->
