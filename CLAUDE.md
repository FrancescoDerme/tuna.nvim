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
   - [ ] 5. `widgets.lua` — native (no nui) input prompt, then testcase editor + picker
   - [ ] 6. `receive.lua` — batch-aware pipeline (Receiver → collector → serial processor), receive modifiers, templates, configurable paths; **absorbs and removes `http.lua`**
   - [ ] 7. `runner.lua` — multi-testcase run via `vim.system`, parallelism, per-process timeout, kill/re-run, compare integration
   - [ ] 8. `runner_ui/` (`init.lua` `popup.lua` `split.lua`) — native results UI, recursive layout engine, viewer, diff view
   - [ ] 9. `commands.lua` — full subcommand surface (`add/edit/delete_testcase`, `convert`, `run`, `run_no_compile`, `show_ui`, `receive …`) + completion
   - [ ] 10. `init.lua` — finalize `setup()`, highlight groups, `VimResized` resize autocmd, persistent-receive-on-setup
   - [ ] ~~`http.lua`~~ — to be folded into `receive.lua` and deleted (was not in the original design)
3. **Extend** — once parity with competitest.nvim is reached, add new features beyond what the original plugin had.

_(Phase 1 review complete. Currently entering Phase 2 — update this line as phases progress.)_

## Architecture

All Lua lives under `lua/tuna/`. The entry point is `lua/tuna/init.lua`, which calls `config.setup()` and registers the single `:Tuna <subcommand>` user command.

Module responsibilities:

- **`init.lua`** — plugin setup, registers `:Tuna` command with tab-completion
- **`config.lua`** — layers defaults → user `setup()` opts (`current_setup`) → per-directory local config (`.tuna.lua`, found by walking up the tree from a buffer's file). `get_buffer_config(bufnr)` resolves + caches per-buffer config. `update_config_table` replaces per-language command `args` instead of index-merging them. Full schema covers compile/run, testcase storage (`testcases_storage` enum), receive, and UI options. `config.options` is a compat alias for `current_setup` read by the not-yet-ported runner
- **`commands.lua`** — maps subcommand strings to handler functions (`download_problem`, `download_contest`, `test`, `add_testcase`)
- **`http.lua`** — TCP server via `vim.uv` that listens for Competitive Companion payloads (default port 4242, host 127.0.0.1). Parses raw HTTP, decodes JSON, then delegates to `receive`. Exposes `status()` for the optional lualine component
- **`receive.lua`** — parses Competitive Companion JSON payloads (`build_import_plan`, `parse_payload`, `import_payload`). Handles both single-problem and contest modes. Creates directory structure and writes source file + testcase files to disk
- **`testcases.lua`** — reads/writes testcases via three interchangeable backends (`files`, `single_file`, `directory`) sharing a 0-based `{ [n] = { input, output } }` table. Pure `load`/`write` per backend; `buf_*` wrappers derive paths from buffer config; module-level `buf_get_testcases`/`buf_write_testcases`/`buf_save_testcase`/`buf_delete_testcase` dispatch to the configured backend with auto-detect fallback; `buf_clear` per backend supports `convert`. `add`/`load_first` are deprecated shims for the not-yet-ported runner/commands
- **`runner.lua`** — `Runner` object that optionally compiles then runs the current buffer's file, feeding `stdin` from the loaded testcase and comparing stdout against expected output. Uses `vim.uv.spawn` for async process execution. Opens a floating output window (`tuna://output`)
- **`compare.lua`** — output comparison: `compare_output(output, expected, method)` with builtin `exact`/`squish` methods and custom-function support; returns `true`/`false`/`nil`
- **`utils.lua`** — `notify`; modifier engine (`format_modifiers` state-machine parser, `file_format_modifiers`, `eval_string`, `buf_eval_string`); filesystem helpers (`file_exists`, `directory_exists`, `ensure_directory`, `read_file`, `write_file`, `delete_file`, `normalize_path`); `get_ui_size`. `apply_modifiers` is a deprecated compat shim for the not-yet-ported `runner.lua`

### Key data flow

1. User runs `:Tuna download_problem` → `http.start_server()` starts TCP listener
2. Competitive Companion POSTs JSON → `http` parses it → `receive.import_payload()` creates dirs + files on disk
3. User runs `:Tuna test` → `runner.new()` builds a `Runner` for the current buffer → `runner:run()` calls `runner:compile()` then spawns the run process with `testcases.load_first()` as stdin

### Command modifiers (template variables)

Used in `compile_command` / `run_command` args: `$(FNAME)`, `$(FNOEXT)`, `$(FEXT)`, `$(FABSPATH)`, `$(ABSDIR)`. Expanded by `utils.apply_modifiers`.

### Testcase directory layout

```
<project_root>/
  tests/
    <name>/
      input.txt
      output.txt
```

`runner.lua` currently only feeds the first testcase (`load_first`) to a single run. Running all testcases is a planned feature.

## Development

This is a pure Lua Neovim plugin — there is no build step, test suite, or package manager. Load it in Neovim via your plugin manager pointing at this repo. Local per-project config can be placed in `tuna.lua` or `.tuna.lua` at the project root.

Optional lualine integration:

```lua
require("lualine").setup({ sections = { lualine_x = { require("tuna").lualine_component } } })
```
