# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

`tuna.nvim` is a Neovim plugin for competitive programming, written in Lua. It is a ground-up rewrite/successor to [competitest.nvim](https://github.com/xeluxee/competitest.nvim), which is no longer actively maintained. The plugin integrates with [Competitive Companion](https://github.com/jmerle/competitive-companion) (a browser extension) to download problems/contests, manages testcases on disk, and compiles/runs solutions against them.

## Goals

- Written in idiomatic, modern Lua — prefer current Neovim APIs (`vim.uv`, `vim.system`, etc.) over legacy/deprecated patterns.
- Prioritize speed: async I/O and process spawning wherever possible, minimal startup overhead.
- Don't just port competitest.nvim's design 1:1 — research current Neovim plugin best practices (structure, config patterns, testing, docs) and apply them, improving on the original where it makes sense.
- The author is new to Neovim plugin development — briefly explain unfamiliar Neovim APIs or Lua idioms when introducing them, rather than assuming prior plugin-dev experience.

## Roadmap / current phase

The project proceeds in three phases. Update the checklist below as work progresses so each session starts with accurate status.

1. **Review** — read through the existing README and any code already in this repo before making changes, to understand what's been started and why.
2. **Port** — reimplement competitest.nvim's functionality file-by-file in this repo, modernizing as we go. Modules are listed in **porting order** (bottom-up: each step is testable before the next depends on it). See `DIFFERENCES.md` for decisions that diverge from the original.
   - [x] 1. `utils.lua` — modifier parser (`$()` state machine), file-format modifiers, `vim.uv`/`vim.fs` file I/O, `notify`, `get_ui_size`
   - [x] 2. `config.lua` — full option schema, buffer-config cache, local-config directory walk, per-language arg replacement on extend
   - [x] 3. `compare.lua` — `exact` / `squish` / custom comparison
   - [x] 4. `testcases.lua` — three storage backends (single msgpack file, flat io-file pairs, dir-per-testcase), auto-detect, buffer helpers
   - [x] 5. `widgets.lua` — native (no nui) input prompt, testcase editor + picker; `resize_widgets()` for `VimResized`
   - [x] 6. `receive.lua` — batch-aware pipeline (Receiver → collector → serial processor), receive modifiers, templates, configurable paths, lualine `status()`; **absorbed and removed `http.lua`**
   - [x] 7. `runner.lua` — multi-testcase run via `vim.system`, parallelism, per-process timeout, kill/re-run, compare integration; compile-as-testcase gate; temporary results float pending `runner_ui`
   - [ ] 8. `runner_ui/` (`init.lua` `popup.lua` `split.lua`) — native results UI, recursive layout engine, viewer, diff view
   - [ ] 9. `commands.lua` — full subcommand surface (`add/edit/delete_testcase`, `convert`, `run`, `run_no_compile`, `show_ui`, `receive …`) + completion
   - [ ] 10. `init.lua` — finalize `setup()`, highlight groups, `VimResized` resize autocmd, persistent-receive-on-setup
   - [x] ~~`http.lua`~~ — folded into `receive.lua` and deleted (was not in the original design)
3. **Extend** — once parity with competitest.nvim is reached, add new features beyond what the original plugin had.

_(Phase 1 review complete. Currently entering Phase 2 — update this line as phases progress.)_

## Architecture

All Lua lives under `lua/tuna/`. The entry point is `lua/tuna/init.lua`, which calls `config.setup()` and registers the single `:Tuna <subcommand>` user command.

Module responsibilities:

- **`init.lua`** — plugin setup, registers `:Tuna` command with tab-completion
- **`config.lua`** — layers defaults → user `setup()` opts (`current_setup`) → per-directory local config (`.tuna.lua`, found by walking up the tree from a buffer's file). `get_buffer_config(bufnr)` resolves + caches per-buffer config. `update_config_table` replaces per-language command `args` instead of index-merging them. Full schema covers compile/run, testcase storage (`testcases_storage` enum), receive, and UI options. `config.options` is a compat alias for `current_setup` read by the not-yet-ported runner
- **`commands.lua`** — maps subcommand strings to handler functions (`download_problem`, `download_contest`, `receive`, `receive_testcases`, `stop_receive`, `receive_status`, `run`, `run_no_compile`, `test`, `kill`, `show_ui`, `add_testcase`); keeps `last_runner` so `kill`/`show_ui` act on the latest run
- **`receive.lua`** — owns the Competitive Companion integration end-to-end (absorbed the old `http.lua`). Pipeline `Receiver` (TCP listener, default port `companion_port` 27121) → `TasksCollector` (groups tasks by `batch.id`/`batch.size`) → `BatchesSerialProcessor` (runs one batch handler at a time). `start_receiving(mode, …)` supports modes `testcases`/`problem`/`contest`/`persistently`; storage helpers expand receive modifiers (`$(JUDGE)`, `$(CONTEST)`, `$(PROBLEM)`, …), apply templates, prompt for paths via `widgets.input`, and write source + testcases through the `testcases` backends. Exposes `status()`/`is_receiving()`/`mode()` for the lualine component and `show_status()`/`stop_receiving()`
- **`testcases.lua`** — reads/writes testcases via three interchangeable backends (`files`, `single_file`, `directory`) sharing a 0-based `{ [n] = { input, output } }` table. Pure `load`/`write` per backend; `buf_*` wrappers derive paths from buffer config; module-level `buf_get_testcases`/`buf_write_testcases`/`buf_save_testcase`/`buf_delete_testcase` dispatch to the configured backend with auto-detect fallback; `buf_clear` per backend supports `convert`. `add`/`load_first` are deprecated shims for the not-yet-ported runner/commands
- **`runner.lua`** — `TCRunner` execution engine. `new(bufnr)` resolves/evaluates the compile & run commands; `run_testcases(tctbl, do_compile)` builds `tcdata` (a compile pseudo-testcase at index 1 when compiling, then one entry per testcase) and runs them as `vim.system` processes, up to `multiple_testing` in parallel. Each process has its own timeout timer (labels TIMEOUT vs KILLED/SIG/RET) and result status (CORRECT/WRONG/DONE via `compare`). The compile step gates the rest: testcases run only if it exits 0. `kill_process`/`kill_all_processes`; re-run via `run_testcases(nil)`. UI is decoupled through `update_ui`/`show_ui` hooks that drive `runner.ui` once `runner_ui` (step 8) sets it; until then `display_results()` shows a temporary read-only float
- **`compare.lua`** — output comparison: `compare_output(output, expected, method)` with builtin `exact`/`squish` methods and custom-function support; returns `true`/`false`/`nil`
- **`widgets.lua`** — native floating-window widgets (no nui): `input` single-line prompt, `editor` two-pane testcase editor (`:w`/`:wq` save via `BufWriteCmd`), `picker` testcase chooser. Each is a module-level singleton so `resize_widgets()` can rebuild visible ones on `VimResized`. Config under `editor_ui`/`picker_ui`/`floating_border`
- **`utils.lua`** — `notify`; modifier engine (`format_modifiers` state-machine parser, `file_format_modifiers`, `eval_string`, `buf_eval_string`); filesystem helpers (`file_exists`, `directory_exists`, `ensure_directory`, `read_file`, `write_file`, `delete_file`, `normalize_path`); `get_ui_size`. `apply_modifiers` is a deprecated compat shim for the not-yet-ported `runner.lua`

### Key data flow

1. User runs `:Tuna download_problem` → `receive.start_receiving("problem", …)` opens the TCP listener
2. Competitive Companion POSTs JSON → `Receiver` decodes each task → `TasksCollector` waits for the full batch → `BatchesSerialProcessor` runs the mode's handler → source + testcase files written to disk (and the source opened)
3. User runs `:Tuna run` → `runner.new(bufnr)` builds a `TCRunner` → `commands` loads testcases via `testcases.buf_get_testcases` and calls `runner:run_testcases(tctbl, true)` → compile (if any) then parallel `vim.system` runs, each compared against expected output; results shown in the (temporary) results float

### Command modifiers (template variables)

Used in `compile_command` / `run_command` args: `$(FNAME)`, `$(FNOEXT)`, `$(FEXT)`, `$(FABSPATH)`, `$(ABSDIR)`. Expanded by `utils.eval_string` / `utils.buf_eval_string`.

### Testcase directory layout

The on-disk layout is chosen by `testcases_storage` (`files` | `single_file` | `directory`) and the matching format options — see `testcases.lua` and DIFFERENCES.md. The default `files` mode keeps an input/output pair beside the source (e.g. `sol_input0.txt` / `sol_output0.txt`); `directory` mode uses one sub-directory per testcase (e.g. `tests/0/input.txt` + `output.txt`). The runner loads all testcases via `testcases.buf_get_testcases` and runs them together (parallelised), not just the first.

## Development

This is a pure Lua Neovim plugin — there is no build step, test suite, or package manager. Load it in Neovim via your plugin manager pointing at this repo. Local per-project config can be placed in `tuna.lua` or `.tuna.lua` at the project root.

Optional lualine integration:

```lua
require("lualine").setup({ sections = { lualine_x = { require("tuna").lualine_component } } })
```
