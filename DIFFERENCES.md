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

## Pluggable checkers (`checker.lua`)

✅ **Done (Workstream 1).** competitest could only decide a verdict by comparing
program output against the expected output (`exact` / `squish` / a custom Lua
function). tuna keeps that as the `"builtin"` checker but adds support for an
**external, testlib-style checker program** via the new `checker` option:

```lua
checker = "builtin"                                  -- default: output comparison
checker = "~/cp/checkers/wcmp"                       -- a checker binary
checker = { exec = "$(ABSDIR)/chk", args = { ... } } -- full control
```

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
stress [count]` hunts for a small input on which the current solution disagrees with
a trusted reference:

```lua
stress = {
  generator = { exec = "$(ABSDIR)/gen", args = {} }, -- prints a random test to stdout
  reference = { exec = "$(ABSDIR)/brute", args = {} }, -- a correct-but-slow solution
  count = 100,       -- max iterations
  seed_arg = true,   -- append the iteration number as the generator's last arg
}
```

Each iteration: the generator is run with a reproducible seed (the iteration
number) → its stdout is the input → the solution and the reference both run on it →
their outputs are judged with the **same `checker`** the runner uses (so
multiple-correct-answer problems work). The first wrong answer, crash, or timeout is
**saved as a new testcase** (input + the reference's answer as expected output) and
the search stops; otherwise it reports no counterexample found.

**Reuse, not reinvention:** `stress.lua` calls `runner.new()` to resolve the
solution's compile/run commands, working directories, and checker, then drives the
loop with `vim.system` (using its `timeout` option) and `checker.judge` from
Workstream 1.

## Interactive problems (`interactive.lua`)

✅ **Done (Workstream 2).** Brand new — competitest can't run interactive problems
at all. `:Tuna interactive [n…]` runs the solution against an **interactor** that
talks to it over stdio:

```lua
interactive = { interactor = { exec = "$(ABSDIR)/interactor", args = {} } }
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
same capability flows through `:Tuna run`, `stress`, `interactive`, and `run_all`.

## Multiple solution versions (`multi.lua`, `:Tuna run_all`)

✅ **Done.** Keep several attempts side by side (`main.cpp`, `brute.cpp`, …) and
`:Tuna run_all` compiles and runs *every* sibling file of the same extension against
the shared testcases, printing a per-solution `correct/total` summary. competitest
only ever ran the current file. (This is distinct from multiple-*answer* support
above — here it's multiple *programs*.)

## Scaffolding (`scaffold.lua`, `:Tuna scaffold …`)

✅ **Done.** `:Tuna scaffold <checker|generator|brute>` drops a dependency-free C++
starter (no testlib needed) into the problem directory and opens it, giving a clean
on-ramp to writing the checker/generator that stress testing and special judging
need. Filenames and template sources are overridable via `config.scaffold`.
competitest had nothing comparable.

## Mode-switcher menu (`widgets.menu`)

✅ **Done.** Bare `:Tuna` (or `:Tuna menu`) opens a native chooser listing the run/
test/scaffold actions (Run, Run-all, Stress, Interactive, Scaffold…) so the Phase 3
modes are discoverable without memorising subcommands. In competitest a bare
`:CompetiTest` was an error. This is a deliberate precursor to the fuller `:Tuna`
dashboard planned for Workstream 5.

<!-- Add new entries above this line as decisions are made. -->
