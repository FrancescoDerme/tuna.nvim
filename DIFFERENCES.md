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

## Interactive problems (`interactive.lua`)

✅ **Done (Workstream 2).** Brand new — competitest can't run interactive problems
at all. `:Tuna run interactive [n…]` runs the solution against an **interactor**
that talks to it over stdio. By convention it uses a sibling `interactor.*` — **no
config needed**; `interactive.interactor` only overrides:

```lua
interactive = { interactor = nil } -- override, e.g. { exec = "python3", args = { "$(ABSDIR)/interactor.py" } }
```

For each testcase the solution and the interactor are spawned and their pipes are
cross-wired — solution stdout → interactor stdin, interactor stdout → solution stdin
— and the interactor's exit code is the verdict (0 = CORRECT). The interactor gets
the testcase input/answer as files via the `$(INPUT)` / `$(ANSWER)` placeholders.

**Native-pipe gotcha worth recording:** `vim.system` only surfaces a child's stdout
once it *exits*, so it can't relay bytes between two live processes. tuna drops to
`vim.uv.spawn` and forwards data between the pipes by hand, shutting down a peer's
stdin on EOF and guarding every write against a pipe that teardown has already
closed. A timeout timer and the interactor-exits-first / solution-crashes-first
orderings are handled explicitly.

## Multiple-answer problems & the Lua-function checker

✅ **Done.** A problem that accepts several valid outputs (e.g. "print two numbers
that sum to 3" → both `1 2` and `2 1`) is handled by the checker. competitest's
custom comparator was `function(output, expected)` — it never saw the **input**, so
it couldn't validate input-dependent answers. tuna adds a third `checker` form: a
**Lua function `function(tc)` that receives the whole testcase** (`tc.stdin`,
`tc.stdout`, `tc.expected`) and returns `(ok, message)`. So you get input-aware
special judging in pure Lua, without writing/compiling an external checker — and the
same capability flows through `:Tuna run`, `run stress`, `run interactive`, and
`run all`.

## Multiple solution versions (`multi.lua`, `:Tuna run_all`)

✅ **Done.** Keep several attempts side by side (`main.cpp`, `slow.cpp`, …) and
`:Tuna run all` compiles and runs *every* sibling solution file of the same
extension against the shared testcases, printing a per-solution `correct/total`
summary. Helper files (`checker.*`, `gen.*`, `brute.*`, `interactor.*`) are excluded
so they aren't mistaken for solutions. competitest only ever ran the current file.
(This is distinct from multiple-*answer* support above — here it's multiple
*programs*.)

## Scaffolding (`scaffold.lua`, `:Tuna scaffold …`)

✅ **Done.** `:Tuna scaffold <checker|generator|brute|interactor> [ext]` drops a
dependency-free starter (no testlib needed) into the problem directory and opens it,
giving a clean on-ramp to the convention-named helpers that stress testing, special
judging, and interactive problems discover. The file is created in the **solution's
language** by default (or the language named by `[ext]`); built-in templates ship
for C++ and Python, and both the base filenames and the templates — per kind and
**per language** (`{ [ext] = path }`, like `template_file`) — are overridable via
`config.scaffold`. competitest had nothing comparable.

## Mode-switcher menu (`widgets.menu`)

✅ **Done.** Bare `:Tuna` (or `:Tuna menu`) opens a native chooser that switches the
buffer's **run mode** (normal / run-all / stress / interactive), toggles the checker,
shows the results UI, or scaffolds a helper — so the Phase 3 modes are discoverable
without memorising subcommands, and picking a mode here is what a later bare `:Tuna
run` repeats. In competitest a bare `:CompetiTest` was an error. This is a deliberate
precursor to the fuller `:Tuna` dashboard planned for Workstream 5.

<!-- Add new entries above this line as decisions are made. -->
