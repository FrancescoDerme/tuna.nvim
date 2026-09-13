# CLAUDE.md

Guidance for agents working in this repository. What the plugin does from a user's point of
view is in `README.md` (mirrored by `doc/tuna.txt`), so read that first. This file covers how
the plugin is built, the invariants that hold it together, the reasoning behind choices that
are easy to undo by accident, and the rules for changing it.

## What it is

tuna.nvim is a competitive-programming plugin for Neovim 0.10+, written in pure Lua with no
required dependencies (toggleterm, lualine and telescope are optional). It is a rewrite of
competitest.nvim, not a port. Everything is reached through one user command,
`:Tuna <subcommand>`: testcase storage and inline editing, compile/run with verdicts in a
floating results UI, run modes (normal, run-all, stress, interactive), checkers, Competitive
Companion downloads, submitting through external tools with the verdict in lualine, a snippet
library, contest navigation, a scratch file, an unused-file cleaner, a menu and
`:checkhealth tuna`.

## Rules

**Code**
- Use current APIs (`vim.system`, `vim.uv`, `vim.fs`). Spawn processes and do I/O
  asynchronously. There is no `plugin/` directory: every module loads on `require`, and
  nothing heavy may run at require time.
- Style: 4-space indentation, LuaCATS annotations (`---@param`), a header comment in each file
  (`-- lua/tuna/x.lua`) saying what the module is for.
- Comments explain the design the code has, and motivating a choice is welcome. They carry no
  history or evidence notes ("verified", "measured", "used to", "then fixed", comparisons
  with competitest) and no considered-and-rejected alternatives. If knowing about an
  alternative would stop a future agent from retrying it, record it here.
- Never cite upstream competitest issue or PR numbers anywhere (docs, comments, tests).
  Describe the problem instead. Linking the competitest project is fine.
- User-facing text (notifications, menu items, prompt titles, health output) joins clauses with
  **commas, never dashes or semicolons**. Send notifications through `utils.notify`.
- **Never ask on the command line** (`vim.fn.confirm`, `input()`). Every question is a
  `widgets` float. Widgets are callback-async, so a caller that must continue passes `on_close`
  and handles dismissal.
- Every buffer or window put in front of the user goes through `surface.lua` (see below).
- libuv callbacks run in a fast event context, where `vim.notify` and most API calls raise.
  Hop to the main loop with `vim.schedule` (`download.notify_soon`).
- Async results land by **row identity and a token**, never by index: rows get rebuilt,
  renumbered and removed while children run.
- A submit failure message must never carry credentials: it goes through `submit.redact`
  (blanks `apiKey`, `apiSig`, `token`, `password`, `cookie`, `session`… by parameter name) and
  is clamped to 160 characters.

**Docs**
- `README.md` and `doc/tuna.txt` are parallel. When user-visible behaviour changes, update
  both, and update this file when the design changes.
- The maintainer edits the README by hand: read it before editing and don't reflow it.
- The vimdoc is `doc/tuna.txt` (`:helptags` only indexes `*.txt`). Lines are at most 78
  columns, tags look like `*tuna-…*`, and `|` is only a link delimiter, so alternatives are
  written `[add/edit/delete]`. Check tags with `:helptags doc`. `doc/tags` is gitignored,
  because plugin managers regenerate it.
- This file is `export-ignore`d (`.gitattributes`). Keep it dry and current: no roadmap and no
  history of how the code got here.

**Git**: don't commit unless asked.

## Repository layout

```
lua/tuna/
  init.lua          setup(), :Tuna command + completion, highlight groups, VimResized, autocmds
  config.lua        defaults, setup layering, per-directory .tuna.lua, per-buffer config cache
  commands.lua      subcommand dispatch and completion; per-buffer runner cache
  utils.lua         notify, modifier engine, filesystem helpers, float geometry, place_cursor
  surface.lua       the contract every UI buffer/window follows
  widgets.lua       input, editor, picker, menu, panels, form floats
  testcases.lua     three storage backends, testcase semantics, split
  sidecar.lua       per-problem .tuna.json
  tools.lua         helper-program discovery/compilation, per-problem run state
  compare.lua       exact/squish/float/custom verdict comparison
  diff.lua          positional diff marks for the results UI
  checker.lua       builtin vs external testlib-style checker
  runner/core.lua   RunnerCore: rows, process execution, UI plumbing, editing contract
  runner/init.lua   normal run mode + runner.new resolver
  runner_ui/init.lua    RunnerUI: the results UI
  runner_ui/layout.lua  pane titles, layout validation
  runner_ui/popup.lua   floating-grid interface
  runner_ui/split.lua   native-split interface
  multi.lua         run-all (every solution version × testcases)
  stress.lua        stress testing
  interactive.lua   interactive problems (live / feed / interactor)
  download.lua      Competitive Companion listener and writer
  judges.lua        judge/contest names from a task
  submit.lua        submit providers, verdict watching, lualine component
  clean.lua         remove unused templated files and emptied directories
  library.lua       snippet library
  navigate.lua      :Tuna next / prev
  recent.lua        :Tuna last problem / contest, cwd changes
  temp.lua          scratch solution, folded into a download by `download sync`
  scaffold.lua      helper-file starters (checker/gen/brute/interactor)
  menu.lua          bare :Tuna menu
  keymaps.lua       opt-in keymaps and preset
  health.lua        :checkhealth tuna
doc/tuna.txt        vimdoc
tests/              test suite (`tests/run.sh`)
tuna.nvim.json      package metadata
```

## Configuration

- Layers: defaults → `setup()` opts (`current_setup`) → the nearest `.tuna.lua` found by
  walking **up** from the buffer's file. `get_buffer_config(bufnr)` resolves and caches per
  buffer.
- `setup()` **rebuilds from `vim.deepcopy(defaults)`** on every call. Rebuilding means a key
  removed from the user's config actually goes away when the config is re-sourced. The copy
  matters too: `tbl_deep_extend` assigns untouched sub-tables by reference, so any later write
  would change the defaults.
- `update_config_table` is plain `tbl_deep_extend`. Non-empty lists replace the default
  wholesale.
- `.tuna.lua` is a plain `dofile` with no trust prompt, on purpose: users write one per contest
  folder, so a prompt per contest costs more than it protects. It runs from `recent.lua`'s
  `BufEnter` too, not only when tuna is invoked.
- `keymaps.setup()` runs on every `setup()`, outside the once-only guard.
- `commands` drops a cached runner whose config no longer `deep_equal`s the buffer's current
  config.
- `commands.target_buffer(bufnr?)` is the buffer every `:Tuna` subcommand acts on (and bare
  `:Tuna`, from `init.lua`): a results pane resolves to the solution it shows, through
  `runner_ui.owner_of`, a registry the UI fills for its pane buffers and clears when it is
  deleted. A pane is not a file, so a command acting on one compiled nothing and kept the
  problem's run state under a name that is not a path. A helper file is *not* resolved here;
  each run does that itself (`tools.solution_bufnr`).

**Modifiers.** There are two sets. The *file* set (`$(FNAME)`, `$(FNOEXT)`, `$(FEXT)`,
`$(FABSPATH)`, `$(ABSDIR)`, `$(DIRNAME)`, `$(HOME)`, `$(CWD)`) resolves from a path via
`utils.eval_string`/`buf_eval_string`. The *download* set (`$(JUDGE)`, `$(CONTEST)`,
`$(PROBLEM)`, `$(URL)`…) exists only while a task is being written, in `download.lua`.
`utils.only_file_modifiers(str)` tells them apart; `temp` and `clean` read `template_file`
without a task and need it.

**Paths.** `utils.expand_home` expands a bare `~` or a `~/` prefix (not `~user`), by
concatenation rather than `gsub`. `utils.normalize_path` joins onto a base only when the path
is relative. Every configured path goes through these: compile/running directories,
`testcases_directory`, download paths, templates, `clean`, `temp`, `scaffold`.

`utils.template_candidates` normalizes `template_file`'s five shapes (`false`, a path, a list,
`{ [ext] = path }`, `{ [ext] = { path, … } }`) into an ordered list; the first that exists wins.

## Testcases (`testcases.lua`)

- One 0-based table shape, `{ [n] = { input, output } }`, shared by three backends: `files`,
  `single_file` and `directory`. The `buf_*` functions dispatch to the configured backend and
  fall back to auto-detection.
- **`files` formats** may each be a list. On load the first format that matches anything wins;
  formats are never merged, so two problems sharing a folder don't mix. `active_parts` picks
  the pair a directory already uses, and both load and write go through it, so a new testcase
  joins the existing naming. A format without `$(TCNUM)` names testcase 0. A testcase may have
  only an input or only an output.
- **Empty versus absent** is a load-bearing rule:
  - *Input*: empty and absent mean the same thing. `as_stored` normalizes inputs on load in all
    three backends.
  - *Answer*: **absent means not judged** (`compare_output` returns `nil`, verdict `DONE`);
    **present but empty means the solution must print nothing**. Only file presence can carry
    the difference, so `write_or_delete` deletes an empty answer unless `keep_empty` is set.
  - `buf_save_testcase` always keeps the input, even an empty one, and keeps an empty answer
    only when passed `expect_empty_output`. `buf_write_testcases` (bulk) keeps plain
    "empty means absent".
  - A `single_file` save or delete rewrites the whole store, so the testcases it is not
    touching go through `keep_stored` and are written back exactly as they were; the bulk
    rule would otherwise drop a stored empty testcase and an expected empty answer.
  - In memory, typed text goes through `core.answer`, which turns `""` into `nil`. `sync_rows`
    takes the disk's answer as it is, so a stored empty answer survives a reload.
- `tc_directory(source_dir, filepath, cfg)` is the only place `testcases_directory` is
  resolved: modifiers evaluated, `~` expanded, used as-is when absolute. An absolute value
  without a per-problem modifier (decided by modifier name, `has_scoping_modifier`) warns once
  per session, because every problem would overwrite the others. The warning is skipped when
  the value comes from a `.tuna.lua`.
- **Split** (`split_testcase`, `buf_split_testcase`): marker lines come in **pairs**, and what a
  pair brackets becomes a testcase. Everything outside the pairs stays in testcase `n`; new
  cases take the lowest free numbers, and no other testcase is renumbered. The split is
  mechanical on purpose: case boundaries depend on the problem's input format and can't be
  inferred. It refuses four things: an odd marker count, an empty pair, an expected output with
  a different case count, and a non-empty expected output with no markers.
  `offer_case_counts` then offers to fix a leading case-count line, read from the *original*
  input. It is a menu, never applied silently, and its `on_settled` fires on every answer so
  the results UI can hold the run until it is answered.

## Sidecar and run state

- **`sidecar.lua`**: `problem_store_file` (`.tuna.json`) beside the source. Keys:
  - `url`/`name`/`group`/`mirror`/`mirror_at`, the downloaded task;
  - `submit = { [basename] = { state, text, url, hash } }`;
  - `run = { [basename] = { mode, source, checker, compare } }`, holding only what was forced
    (older entries' `explicit = false` and `checker = false` still read);
  - `results = { [basename] = { passed, total, hash } }`, the local verdict (see Runners).

  Entries are keyed by **basename** because one folder can hold several problems or several
  attempts. Writers merge. `set_entry(…, nil)` removes an entry and deletes the file once it is
  empty. This is problem state that travels with the folder; machine state belongs in
  `stdpath("state")` (`recent.lua`).
- **`tools.lua`**:
  - **One rule for every helper and every setting**, kept consistent on purpose.
    `helper(role, solution, cfg)` finds any role (checker, generator, reference, interactor):
    the configured option (`checker`, `stress.generator`/`reference`,
    `interactive.interactor`; a string is a helper file, compiled or a prebuilt binary, a
    table an `{ exec, args }` command whose args expand file modifiers but keep
    `$(INPUT)`/`$(OUTPUT)`/`$(ANSWER)`) wins over a sibling file named by `tool_names`, and a
    configured one that doesn't exist returns a note. Nothing is cached: disk decides now.
  - The run settings, mode, interactive source and checker, are each **automatic until
    forced** (`get_mode`/`set_mode`, `get_source`/`set_source`, `checker_setting`/
    `set_checker`, nil or `"auto"` being automatic; the checker can only be forced `"off"`).
    Automatic: `detect_mode` (interactor, then generator + reference, else normal),
    interactor-else-live, the checker when there is one. `resolve_mode`/`resolve_source`/
    `resolve_checker` return the forced choice while what it needs is available, else the
    automatic one plus a note (only stress and the interactor source need helpers). Keywords
    typed now force and run as typed; `auto` clears. Persisted in the sidecar with the compare
    override, loaded lazily, removed when nothing is forced.
  - `prepare` caches builds session-wide, keyed by path + mtime + compile command, and queues
    concurrent callers.
  - Compare methods are stored **by name** (`{ method = "float", tol }`), because a mixed
    array/hash table does not survive JSON. Every field is validated on read.
  - `solution_bufnr` redirects a run started from a helper file to the sibling solution. Loading
    a buffer the user never opened must not leave a swapfile: `swapfile` is turned off *before*
    `bufload`, only for buffers tuna loads itself, and restored with a one-shot `BufWinEnter`
    that reads `vim.go.swapfile`.

## Runners

**`RunnerCore` (`runner/core.lua`)** is the base of every mode (subclassed with `M.extend()`).
- `tcdata` rows. `execute_process(tcindex, cmd, dir, opts, on_done)` spawns via `vim.system`
  with its own timeout timer (TIMEOUT, KILLED, SIG, RET), then judges with `checker.judge`
  unless `opts.judge == false` (the Compile row), setting `judging` while it waits.
- **Stale results are dropped**: `run_id` is bumped per spawn *and* in `reset_row`.
  `finish_process` gets the row object plus the token and bails if either the token changed or
  the row is no longer in `tcdata` (`owns_row`), closing its timer first (the timer is a closure
  local). The judge callback re-checks the token.
- **UI seams** keep `runner_ui` mode-agnostic:
  - `pane_content(tc, name)` returns text, or `core.SKIP` to leave a pane alone;
  - `row_label(tc)`, `status_settings()` (rows with the mode and judge) and `status_tail()`
    (rows after them);
  - `on_ui_shown(ui)` and `owns_pane(name)`;
  - `layout()` supplies a mode-specific grid that replaces the configured one;
  - `pane_titles()`;
  - `on_details_rendered(ui, tc)` runs after the detail panes are drawn, for panes the mode
    draws itself.
- **Editing contract**:
  - `editable_testcases` is a class flag. `row_editable(tc)` is true only for numeric `tcnum`,
    which excludes Compile and run-all headers.
  - Other members: `row_id`, `edit_bufnr`, `rows_for`, `next_tcnum`, `add_testcase_row`,
    `remove_testcase_rows`, `split_testcase`, `run_rows`, `sync_rows(nums, tctbl)`.
  - `idle()` reads `completed`, and structural edits wait for it.
  - `save_testcase(tcnum, input, expected, expect_empty_output)` writes, updates every row
    showing that testcase, clears `bare`, and re-runs, unless the runner is `preloaded`.
- `effective_compare()` returns the per-buffer override, else the config.
- **Local verdicts**: `save_local_verdict(solution, rows)` writes the sidecar's `results` when
  a run finishes: normal `check_complete`, run-all completion and `settle_single`
  (`save_local_verdicts`, each solution over its own case rows), and interactive session ends
  (`save_buffer_verdict` skips a wiped buffer). Stress saves none. Only judged rows count
  (CORRECT passes; WRONG, TIMEOUT, RET, SIG fail), so a run that judged nothing leaves the
  entry alone. The source hash is recorded, and `local_verdict` answers only while it matches.

**Normal runner (`runner/init.lua`)**
- `runner.new(bufnr)` resolves compile/run commands, directories and the checker. Stress,
  interactive and multi reuse it. Every run in every mode calls `RunnerCore:refresh_judge`,
  so a checker added, deleted or switched off, and a comparison overridden since
  (`compare_method`), apply to the next run of a cached runner.
- `build_rows`: row 1 is `Compile` when compiling, and the build gates the testcases. With **no
  testcases** it builds one `bare` testcase 0, labelled `No input`, run on empty stdin with no
  answer (so `DONE`) and editable; saving it creates the testcase. `n` in the UI reuses an
  untouched bare row. An explicit `:Tuna run 5` for a missing testcase reports it and stops
  instead of falling through to a bare run.
- `load_testcases` builds the same rows as `NOT RUN` with `preloaded = true` (`:Tuna show_ui`
  before any run). A preloaded runner has built nothing, so `run_single` compiles first
  (`build_first`) and `run_testcases(nil)` saves sources first.
- `:Tuna show_ui` (`commands.show_results_ui`) opens the mode last run in this session, else
  the one saved for the problem (`tools.resolve_mode`), since after a restart nothing has
  run. Interactive, stress and run-all open the same way when they have no runner yet:
  `M.show(bufnr)` (`M.run(…, { show_only = true })`) lists the rows with
  `RunnerCore:mark_not_run` and keeps the build step on the runner as `build(cont)`. Their
  run keys go through `RunnerCore:built_first`, so the first one builds and then runs, and
  nothing is saved or spawned before it.
- `run_single` **claims the runner** (`completed = false`) until it settles; otherwise edits
  could slip through mid-run.

**Stress (`stress.lua`)**: `StressRunner`.
- Helpers come from `stress_helpers` (`tools.helper` for both roles). A restart resolves them
  again: missing ones are shown in a message and nothing runs, since a rerun keeps its mode.
  `prepare_helpers` compiles them (the cache makes that free), and spawns in the loop are
  `pcall`ed.
- The solution's existing testcases re-run while the generator and brute force compile.
- A counterexample becomes a saved testcase only if its input is new. The search stops at
  `saves_per_run` or `max_saved`.
- `idle()` means the search has stopped. Compile failures show in the UI, not as notifications.

**Interactive (`interactive.lua`)**: one session at a time; the source is remembered per file.
- **feed**: the testcase input is sent a line at a time. It keeps the configured grid with the
  canonical Input/Expected Output panes and is the only editable source (`editable_testcases`
  set per instance). Its no-testcase row is `bare`. `run_single` claims the runner, and every
  path where nothing will run (build failed or didn't start, interactor didn't compile) sets
  `completed = true`.
- **live** and **interactor** are a **conversation**. `layout()` returns the grid
  `interactive.layouts[source]` gives and the option's name with it, so a bad one is reported
  as what it is; `false` there (feed's default) means the configured grid. The shipped
  conversation is selector | Output | Live | Errors (`so`/`si`/`se`), with no Expected Output,
  at ratios `3/3/3/2`: the selector's 3 of 11 is the configured grid's, so it is as wide as in
  every other mode, and `so`/`si` share a ratio and so a width, which works only because the
  *last* column absorbs the grid's rounding (`rec_compute_layout`), hence Errors last.
  - Each row keeps `tc.log`, one entry per rendered row `{ col, text, open }`, blank in the
    other columns. `log_append` continues an open row only while no other column has spoken.
    `log_note` puts tuna's own notes (timeout, exit code, spawn failure) on an Errors row.
    Nothing is echoed between columns, and `tc.stdout` stays the solution's own output.
  - `on_details_rendered` draws the columns with `set_column` (no undo, not modified, skips
    identical content).
  - Columns are `scrollbind` and `nowrap`. All three follow the latest line unless one is being
    read back (cursor in it, not at the bottom), in which case none move. `scrollbind` is
    re-armed after a scroll made from code, or later manual scrolls drift.
  - `run_one_session` hands the cursor to the row it is about to talk to (`ui:goto_row`):
    that row's columns are the conversation, and in live it is the only row whose column is
    typable, so the UI would otherwise sit on Compile with nothing to show and nothing to
    type into.
  - In live, the keys that start typing (`i`/`I`/`a`/`A`/`o`/`O` and `<CR>`) are bound on the
    Live column: while it is typable they are Vim's own (replayed through `feedkeys`), and
    before that they run the session instead of raising `E21` (`start_talking` — a session on
    another row just moves the cursor there). `type_when_live` is then consumed by the render
    that makes the column typable, which puts the cursor at its end and starts insert.
  - In live, the Live column ends in the line being typed, faced by blank lines in the other
    columns, and it is preserved across redraws (`keep_last`). `<CR>` clears it synchronously
    and then calls `live_send`. When the session ends the line is removed, the column becomes
    unmodifiable, and insert mode is left.
  - Only live's Live pane wears the editable accent.
- interactor: `vim.uv.spawn` pipes cross-wire the solution and the interactor; the verdict is
  the interactor's exit code, and it gets `$(INPUT)`/`$(ANSWER)`. Reruns go through
  `with_helpers`, which refreshes the checker and, for the interactor source, resolves and
  prepares the interactor again, reporting a missing one instead of running.
- `M._test` exposes `log_append` and `conversation`.

**Run-all (`multi.lua`)**
- Solutions are every runnable non-helper sibling source, of any language, each with its own
  filetype's commands. The directory is the buffer's parent, or the cwd for a scratch buffer.
- `MultiRunner` is a flattened matrix: solution header rows (`row_label`, live `correct/total`)
  above indented testcase rows.
- All solutions compile first, then everything runs in one shared pool of `multiple_testing`.
  A compile failure is a `CE` row.
- `run_single`/`rerun_solution` settle through `settle_single`. Its `save_testcase` override
  keeps the shared `tctbl` in step. The checker comes from `tools.resolve_checker` against
  `solution` (the buffer's file, else the first solution), so `:Tuna checker off` applies.

**Checker (`checker.lua`)**: `"builtin"` (what `resolve_checker` returns when there is no
checker) delegates to `compare.lua`. An external checker runs
as `checker <input> <output> <answer>` (exit 0 means correct) and is compiled via
`tools.prepare`. Its message (`tc.checker_message`) is appended to the Errors pane by the base
`pane_content`, and `reset_row` clears it.

**Compare / diff**
- `compare_output` returns `true`, `false`, or `nil` when there is no answer. `float` is
  `{ "float", tol }`, token-wise, absolute or relative tolerance.
- `diff.compute` is **positional**: line *i* against line *i*, token against token, never
  re-aligned, because CP output is positional and an edit-script diff pairs the wrong lines.
  Granularity follows the compare method (characters for `exact`, tokens otherwise, `float`
  tolerance applied), so the marks never contradict the verdict. `TunaDiffText` is a red tint
  blended into `Normal`'s background, re-derived on `ColorScheme`.

## Results UI (`runner_ui/`)

**Structure**
- Panes: `st` (the "Run" status, carved from `tc`'s rectangle), `tc` (selector), `so`, `eo`,
  `si`, `se`. `popup.lua` tiles floats and `split.lua` builds native splits, from the same
  recursive `{ ratio, child }` layout; levels alternate between columns and rows.
- `M.owner_of(bufnr)` answers which runner a pane buffer belongs to, from the module-level
  `pane_owner` map filled in `show_ui` and cleared in `delete` (`commands.target_buffer`).
- `layout.resolve` validates a layout (known names, no duplicates, well-formed pairs, `tc`
  present) and falls back to the default with one WARN. A pane the layout omits still gets a
  **buffer** (content kept, viewer can open it) but no window.
- `init_ui(windows, config, winid, status_rows, opts)`; `opts` comes from
  `RunnerUI:layout_opts(idx?)` (`row_layout` + runner `pane_titles`).
- **The grid follows the row on screen.** `row_layout` answers the build step with
  `runner_ui.compile_layout` (selector + Errors, `false` to keep the mode's grid) and every
  other row with the mode's `layout()` or the configured one. The render tick compares it
  with `drawn_layout` and calls `redraw_grid`, which asks the interface to `relayout`: the
  panes keep their buffers (content, keymaps, unwritten edits) and are only moved, opened or
  closed, because rebuilding them would drop all of that and race the rows landing in them.
  `resize_ui` is the same call. While it runs, `relayouting` marks the windows closing and
  opening as the UI's own, so neither `WinClosed` (which means the user closed the UI) nor a
  cursor event (which means a move by hand) is believed; it is cleared a tick later, when
  those events are delivered. `watch_pane_window` re-arms the per-window `WinClosed` after a
  relayout, and `draw_pane`/`build_windows` skip a pane whose buffer was wiped from under the
  UI (`:%bwipeout`).
- Rendering is **coalesced to one per tick** (`render_scheduled`, flags `update_windows` and
  `update_details`).
- **Which row is shown** is the UI's choice until the selector is moved by hand: `user_moved`
  is set only when a `CursorMoved` actually *changes* the selection, which a code-driven move
  never does (those select first, so the event finds nothing to change). `follow_row` is how
  the UI chooses and does nothing once the user has. Three things choose: `show_ui` takes
  `opening_row()` on its scheduled tick, *after* the rows exist (interactive and run-all build
  theirs after opening, so deciding earlier would always land on line 1); every render calls
  `follow_after_compile`, which moves off a Compile row that ended with exit 0 and printed
  nothing (a failed or talkative build is the row that answers the run, and one still running
  must not move under the user); and interactive's `run_one_session` follows the row it is
  talking to, sessions being held one at a time and live's row being the only typable one.
  The cursor and the selection must agree while the choice is the UI's, or the editor's own
  cursor event reads as a move by hand: `show_ui` leaves `update_testcase` on line 1 until the
  tick chooses, and `render_selector` puts the cursor back on the chosen row after a rebuild
  that would otherwise clamp it onto another one.
- `opening_row()`: a run whose build has not finished opens on it (`building`), whatever was
  last looked at, so every run starts the same way; otherwise the runner's `last_row_id`
  (matched by `row_id`), else `initial_row()` — the first testcase, or Compile when it printed
  something. `building` is about the *run*, not the process (`not preloaded and
  exit_code == nil`): asking whether the compiler runs right now leaves a tick between the rows
  being built and the process being spawned, and a UI opened inside it drew the panes of a run
  for a build about to start and redrew them a moment later. For the same reason the mode
  modules `mark_not_run` before `show_ui`, not after.
- `render_selector` lays the rows out in three columns (header, verdict, time) through
  `selector_columns`: 10 wide while the pane holds them, content-sized plus a space when it
  doesn't, and without the time rather than letting the pane cut a number in half. The
  conversation layout gives its selector a 4 share for that reason.
- `status_lines()`: mode, judge (the checker file, else the compare method), the mode's own
  settings (`status_settings`, interactive's source), forced, diff on/off, runner tail,
  `help: ?`. Its row count is fixed per runner. The `forced` row names
  the settings that are the user's choice (`mode`, `judge`, `source`), else `none`, rather
  than appending a word to each value, which the pane is too narrow to hold: `judge` counts
  as forced when the checker is off or the comparison is overridden, never when a checker
  was simply found.

**Inline editing**
- Editable panes are always-modifiable `acwrite` buffers. `:w` from **any** pane saves the row
  the panes show (`pane_tcnum`, the row last *rendered*, not the selected row). A write with no
  change does nothing.
- Unwritten edits live in `ui.pending[tcnum]`. They survive row switches and resizes, override
  `pane_content`, and feed the diff. The row reads `EDITED` (unstyled) instead of its verdict.
- `on_pane_edit` must stay O(1) in testcase size. It reads only Vim's `modified` flag and
  re-renders the selector only when the edited set changes (`edited_sig`). Comparing against
  the stored text (`w.baseline`, `panes_changed`) happens only in `capture_pending` and in the
  120 ms debounce `schedule_settle`, so text typed back to its original stops counting as an
  edit. Pane `modified` flags are then cleared, because a modified `acwrite` buffer blocks
  quitting with E37/E162.
- `capture_pending` runs before anything repoints the panes. `discard_pending` clears `pending`
  and the flags together.
- Keys with no text to author: `n` adds a row, `x` deletes, `u` undoes a delete, `c` splits.
  Structural keys wait for `idle()`. A split reads the unwritten pane text and does not save it
  first, because saving would run the marked-up input. The resulting cases run once the
  case-count question settles.

**Gates** (all menus, all ending in `Keep editing`/`Stop`, which is also what dismissal gives)
- `with_pending_settled(tcnum, what, proceed, after_save)`: re-running with unsaved edits
  asks `Save and <what>` / `Discard and <what>` / `Keep editing`. Saving re-runs what it
  saved, so `proceed` follows a save only with `after_save`. `request_close` uses the same
  `unsaved_items`.
- `commands.settle_results(bufnr, { run, keep }, proceed)` is what every run and `show_ui`
  go through, so switching modes loses nothing and a buffer shows one results UI at a time.
  Before a run it asks about an unwritten edit in any of the buffer's runners (interactive,
  stress and run-all replace the whole runner, `pending` with it), then stops every run of
  the buffer: a live session would wait on its input forever, and stress rebuilds the binary
  the new run executes. Every UI but `keep` is then hidden with `RunnerUI:delete`, which
  keeps `pending` on its runner. `runners_of` only looks in mode modules already loaded.
  The mode modules also stop the runner they replace, for callers that bypass `commands`.
- `with_answer_settled`: `:w` asks only when a **real answer would become empty**:
  `Don't specify output` / `Expect empty output` / `Keep editing`. It asks nothing about empty
  inputs, or about answers already absent or empty. The menu is opened with `vim.schedule`,
  because a float entered inside `BufWriteCmd` loses focus when the write finishes.
- `with_disk_settled` / `disk_drift` compare rows with disk in one read. It excludes `bare`
  rows, unsaved `n` rows and pending rows.
  - **Changed** on disk: reload silently via `sync_rows` and say so once.
  - **Missing**: ask `Restore and re-run` / `Discard` / `Stop`. `restore_missing` writes back
    to the original number if it is free, else the lowest free number, renumbering the row.
  - Every branch renders, and the re-run finds rows by identity (`row_index`).

**Quitting and focus**
- `:q`/`:close`/`:wq`/`:x` in any pane are cancelled in `CmdlineLeave`, by setting
  `v:event.abort` **from Vimscript** (`vim.v.event` is a copy in Lua), and turned into
  `request_close`. `:q!` passes. `:qa`-style commands pass unless an edit would be lost; then
  they ask and re-issue the quit. The viewer is exempt.
- Focus rescue: remember the one hop out of the UI (`escaped_from`/`escaped_to`). When that
  window closes, return to the pane, but only if focus landed on a window that existed before
  the close (`WinClosed` snapshots `nvim_list_wins()`), so a dialog opened by the close keeps
  focus. "Moved on to another window" is decided a tick later, because `WinClosed`/`WinEnter`
  arrive in either order.

**Keys**
- Actions (`run_again` r/R, `run_all_again` <C-r>, `stop` s/S, `stop_all` <C-s>,
  `toggle_diff`, `view_*`, add/delete/undo/split) are bound on **every read-only pane**, in
  both letter cases. Editable panes get only close, pane switching and `?`. Add, delete,
  undo and split are bound in every mode and do nothing where testcases can't be edited;
  left unbound, `n`/`N` would fall through to Vim's search.
- `close` (`<Esc>`, `<C-c>`, `q`, `Q`) is bound on every pane in **normal mode only**.
  `switch_window_keys` (default `<C-hjkl>`, a top-level option shared with widgets) also work
  in insert mode and move by window geometry; `st` is never a focus target.
- `RunnerUI:writable_pane` decides which panes are typed into. The legend (`?`, `show_help`)
  and messages render keys from the config.

**Look**
- Writable panes wear `runner_ui.editable_border_highlight` (default `TunaEditable`, bold
  magenta, the one hue not used for verdicts) on border and title. The title uses the derived
  `TunaEditableBorder`.
- The shipped layouts put `so`/`eo` on one row (the diff reads across) and `eo`/`si` in one
  right-hand column.
- Float geometry: a bordered float's `row`/`col` is its border cell, and `width`/`height`
  exclude the border. Centre on `size + 2` (`overlay_geometry`, `ui_bounds`).
- The viewer and message floats are sized by `runner_ui.viewer`. The legend is sized to the
  UI's footprint.
- Diff view paints extmarks in the `tuna_runner_diff` namespace, with `scrollbind`/`cursorbind`
  instead of filler lines. It is cached by texts and row (`diff_cache`) and follows unsaved pane
  text as you type (debounced). Rows that have never run are not diffed.

## Widgets and surfaces

**`surface.lua`** is the contract every scratch buffer/window follows. Each rule prevents a
specific Vim error about a buffer the user never opened.
- `adopt(buf, kind, opts)`: name `tuna://<kind>/<bufnr>/tuna` (constant last component for
  statuslines), `filetype=tuna` (what statuslines key on to keep describing the file underneath,
  e.g. lualine's `ignore_focus`), `buftype=acwrite` with a write handler (`nofile` gives E382 and
  never fires `BufWriteCmd`), `keep_clean` for prompts (watches `TextChanged*` and `on_lines`).
  Adopt a buffer **before** its window opens: entering fires `BufEnter`, and plugins that
  skip tuna's windows by filetype read it right then (scrollEOF otherwise writes the global
  `scrolloff` from a small float's height).
- `read_only(buf)`: unmodifiable, and `CHANGE_KEYS` mapped to `<Nop>` wherever nothing else
  claims them. Call it **after** binding real keys; claims are compared on terminal codes
  (`<C-R>` equals `<C-r>`).
- `render(buf, content, opts)`: no write when unchanged, `undolevels = -1` around the write,
  `modified` cleared.
- `float(buf, opts)` with `LAYER`: grid 50, viewer 60, overlay 70, dialog 80. Neovim's default
  is 50, so always set a layer. A float starts with the `statusline` of the window it opens
  over: a new window otherwise takes the global value, which lualine leaves blank until its
  next refresh, so the bar would flicker whenever a float takes focus.
- `group(wins, on_close)`: windows that close together, keyed on `WinClosed`.

**`widgets.lua`**
- **Dismissal** is bound only through `map_cancel`, from `config.cancel_keys`
  `{ normal = { "<Esc>", "<C-c>" }, insert = {} }`: Esc cancels from normal mode and only
  leaves insert mode. Per-widget keys extend the lists. `<C-c>` in insert mode can't be mapped.
- `input` opens in **normal** mode, because chained prompts can't reliably start in insert.
- `menu`: optional `on_close`; `preview` (fixed lines or cursor-following `content(idx)`, colour
  via `'syntax'` not `'filetype'`, list capped at `MENU_LIST_SHARE` of the height); `notice`
  pane above the menu, outside the focus cycle; `row` to start the cursor on (a resize keeps
  the row it is on).
- `panels`: lists in columns where `<CR>` acts on the focused list only (the `:Tuna` menu).
  `form`: stacked lists where `<CR>` submits every selection (clean). A `panels` section may
  carry `highlights`, byte-range spans drawn as extmarks in `tuna_panels`. They differ in what
  `<CR>` means, so they stay separate. `panels` has an optional borderless header dropped when space is
  short, lists sized to their own content, and explicitly unmodifiable buffers. A section's
  `column` stacks it with others: a column is as wide as its widest list, its lists share the
  band's rows smallest first (a list given fewer rows than items scrolls, with the user's
  scrolloff), and `switch_window_keys` move by position (`neighbour`: within the stack, or to
  the list level with this one in the next column). Tab/S-Tab walk the lists in order.
  A section's `format(width)` lays it out for a content width (nil: its natural one) in place
  of `items`, again on every build and resize. When the board is too wide, a column made
  only of such sections gives up width first, down to `FIT_MIN`, before the whole board
  scales, so those lists shorten what they show while other lists stay whole.
- `form` custom rows are edited in place, with an inline virtual-text label (left gravity).
  `expr` maps allow editing only on that row, `guard_section` (`on_lines`) repairs other changes,
  and `validate` errors keep the form open.
- Geometry: everything sits inside `utils.float_band()` (one-row margin top and bottom).
  Stacked panes touch (`PANE_STEP = 2`), and heights are allotted notice → list → preview.
  Widgets use zindex 80.
- Widgets are module singletons: `resize_widgets()` rebuilds them (with a `skip_close` guard),
  opening one over an existing instance closes the old windows, and buffers use
  `bufhidden = wipe`.
- List widgets set `cursorline` with local scope, so the global value never leaks.

## Download and judges

**`download.lua`**
- Pipeline: `Listener` (TCP, `companion_port` 27121) → `TasksCollector` (groups by `batch`) →
  `BatchesSerialProcessor` (one batch handler at a time).
- **Nothing in the pipeline may throw.** `validate_task` repairs or rejects every body: only
  `name` is required, a missing `batch` means a single task, and malformed tests are dropped.
  Messages go through `notify_soon`. `process` schedules the handler under `pcall`, and its
  `finished` is idempotent.
- `canonicalize_task`: a Codeforces mirror URL (`m1`/`m2`/`m3`) is rewritten to codeforces.com
  (mirrors have no per-problem pages and drop the contest later), with the mirror kept as
  `mirror`/`mirror_at`. A missing problem index is taken from the URL and prefixed to the name,
  because `$(PROBLEM)` orders the folders.
- Existing targets ask in a float: `Override` / `Stop` for a problem;
  `Override all` / `Write missing only` (only when some are missing) / `Stop` for a contest.
  Every branch, and dismissal, calls `finished`.
- `template_file` is evaluated with download modifiers, plus file modifiers when a target path
  is known. Candidates are tried in order, and a WARN lists the paths when none exists.
  `eval_path` expands `~` on evaluated paths only, not on template content.
- After writing, `cd_downloaded_problems`/`cd_downloaded_contests` (independent of
  `open_downloaded_*`) change directory via `recent.change_dir`. What was written is recorded in
  `recent`.

**`judges.lua`**
- `parse(task, judge_parsers)` splits `group` into judge and contest. The parser is resolved
  as user `judge_parsers[judge]` (or `false`) → `M.builtin[judge]` → user `["*"]`. It is
  `pcall`ed and runs even when the group has no contest half; `unknown_contest` is the last
  resort.
- Codeforces is keyed on the **contest id in the URL** (`gym <id>`, else the bare id from
  `/contest/<id>`, `/problemset/problem/<id>`), so the main site and mirrors land in one folder.
  Don't add round-name normalizers: a round number is not a contest id.
- Path-hostile characters are replaced later, in `eval_download_modifiers`.

## Submit (`submit.lua`)

- `M.context` saves the buffer and resolves the problem's **identity URL** `ctx.url` (a
  `submit.url` function, else the header marker, else the sidecar) and `ctx.submit_url` (the URL
  to submit through, from `submit.url_rewrite`: user function → `builtin_url_rewrite`, or
  `false`). `$(URL)` is the submit URL and `$(PROBLEM_URL)` the identity URL. Only `ctx.url` is
  ever written to the sidecar.
- URL candidates are validated (`is_valid_url`: http(s), no leftover `$(…)`). Invalid ones are
  skipped, and with none valid the submit aborts before any provider runs.
- **Mirror routing** for Codeforces sends through the sidecar's `mirror` only within
  `submit.mirror_ttl` of `mirror_at`. It is a clock because nothing can be probed: Codeforces
  returns an identical challenge page either way, and a network lookup would block the
  synchronous path exactly when the site is struggling. Expired routing is pruned from the
  sidecar with one message.
  - The CLI rewrite yields `…/problem/` without an index, which submitters turn into the
    contest-wide `…/submit/`, the only page a mirror serves.
  - The `browser` provider derives real pages instead (`browser_submit_url`).
- Per-judge config: `judge_of(url)` → `judge_scfg` shallow-merges `submit.judges[judge]` over
  `submit`.
- Providers:
  - `command` expands `submit.command` (string or function) and either watches it
    (`submit.watch`, default true, `run_watch` via `vim.system`) or runs it in a terminal
    (`M.run_terminal` seam; toggleterm if present).
  - `browser` opens the submit page and copies the source to `+`; it exists for judges gated
    behind a Turnstile challenge, such as AtCoder.
- **Watching**
  - Output: strip terminal control sequences, then `scan_verdict` over `submit.verdicts`,
    **preferring the rightmost final verdict over pending** (in-place redraws collapse onto one
    line) and showing a short snippet.
  - Exit with no verdict: `watch_outcome` decides on the exit code alone. Exit 0 clears the
    indicator; it never reports a failure. `expects_verdict = false` only disables parsing.
  - Failures: `failure_reason` checks `OFFLINE_HINTS` first, then `CRASH_HINTS`, then the
    redacted, clamped `meaningful_tail`.
  - Jobs: one per file in `jobs[path]`. A new submit supersedes the old job, and callbacks check
    they still own the slot. `watch_timeout` stops a hung poll; `M.clear` cancels.
- Verdict state is per file (`M.state[path]`) and drives `status`/`status_hl`/`is_submitting`.
  Final verdicts persist in the sidecar with the SHA-256 of the submitted source, not its
  mtime, because a write that changes nothing (a `:w`, the save before a run) must not drop
  one. `restore` (on `BufReadPost`) reloads a verdict only while `still_current` holds (the
  hash matches; an entry carrying only an `mtime` is compared on that), and
  `arm_invalidation` drops shown and stored verdicts on the first edit. `verdict_for(path)`
  reads a verdict without an open buffer (the menu).
- `persist_task` backfills the sidecar's `url`, and `name`/`group` from header markers when
  missing.

## Other modules

- **`clean.lua`**
  - "Unused" means a file still similar to the template that would produce it: a line-LCS
    ratio (`similarity`, with modifier lines matched as wildcards) at or above a threshold.
    Helper files compare against `scaffold.template_for`, solutions against every
    `template_file` candidate (the best match wins), and task-dependent paths resolve through
    the sidecar (`task_of`). A file with no template counts only when empty. The template file
    itself is never offered.
  - The flow is floats only: a `form` for directory, depth and threshold, then one
    `Delete`/`Keep`/`Stop` menu per file with a preview, sorted by match, at a fixed width,
    each starting on the answer last given (`ui.row`), and the same for directories.
  - **Scan cost is bounded**: pruning at traversal (`descend_into`, `clean.skip_dirs`,
    dot-directories), a shared `clean.max_entries` budget reported through the `notice` pane,
    early rejection on the line-count ceiling, and a 1 MiB size guard.
  - **Directory pass**: offers directories left empty apart from disposable files (testcases,
    the sidecar, and `is_artifact` build outputs of a solution *this run* removed). Directories
    are evaluated post-order, deepest first. Directories the run emptied are evaluated before
    the general sweep, so the budget can't starve them. `protected_dirs` covers the scan root,
    cwd, launch directory, configured roots, home and its XDG/standard subdirectories, system
    directories and `clean.protected_dirs`.
  - Every modified buffer is saved first (otherwise an open buffer rewrites a deleted file),
    and buffers of deleted files are wiped.
- **`library.lua`**: snippets are regions between `library.marker` guard comments in plain
  source files; files without guards are offered whole. Only files with the current buffer's
  extension are shown. Snippets are inserted dedented and re-indented to the cursor line.
  `:Tuna lib search` uses telescope when present, fuzzy-matching `name + file` only; a body
  match is appended to the ordinal so it ranks below name matches (fuzzy-matching bodies swamps
  the sorter).
- **`navigate.lua`**: the next or previous sibling problem directory in name order.
  `solution_in` prefers the same file name, then the same extension, then any runnable
  non-helper file. The ends of a contest warn instead of wrapping.
- **`recent.lua`**: `stdpath("state")/tuna/recent.json`, written with a debounce and flushed on
  `VimLeavePre`, read once per session. It holds `problems` and `contests`, most recent first
  and capped by `recent.problems`/`recent.contests` (read from `config.current_setup` when
  recording). `push_front` moves a recorded entry to the top and drops entries whose
  directory is gone. A file holding a single `problem` or `contest` loads as a list of one.
  `open_problem(i)`/`open_contest(i)` open any of them, 1 by default.
  - A `BufEnter` records a buffer only when it looks like a problem (runnable, non-helper,
    with testcases or a sidecar beside it).
  - Recording a problem inside a remembered contest moves that contest to the top with the
    problem as its `problem`, even when the problem was already on top. A contest is
    otherwise recorded by downloads, or inferred when a sibling problem shares the sidecar
    `group`. Both store the `judge` and contest `judges.parse` gives, and `contest_label`
    reads an entry without a judge from its last problem's sidecar (the parsed contest too,
    when the entry is named by the raw group).
  - `change_dir` honours `cd_command` (`cd`/`tcd`/`lcd`/`false`). `snapshot()` returns the
    loaded state for the menu. `contest_problems` lists a contest's solutions in both
    layouts (plain files in the contest directory, and one per problem directory).
- **`temp.lua`**: the scratch is a template minus its leading modifier header
  (`split_template`). A scratch with anything written in it (its loaded buffer, else its file)
  asks `Resume` / `Restart`, previewing what it holds. Restarting, and a missing or blank
  scratch, go to the template question, opened straight from the first menu's choice (which
  fires after that menu has closed) so no frame is drawn without a dialog, a menu with a
  body preview: `template_choices` offers every existing file a `template_file` candidate can
  match, a task-only modifier (`$(JUDGE)`) read as a glob wildcard since no problem exists
  yet, plus an empty file. Dismissing creates nothing, and with no template file at all the
  scratch opens empty. `download sync` sets `M.pending`; `M.absorb(filepath, cfg, template)`
  keeps as many header lines as the template the problem was written from (returned by
  `store_downloaded_task`), replaces the body with the scratch *buffer* lines, saves, moves the
  cursor, and deletes the scratch.
- **`menu.lua`**: the `:Tuna` menu, built on `widgets.panels` (not `widgets.menu`) with a
  free-standing banner (no border and `winblend = 100`, so the editor shows between the
  wordmark's letters, which are extmarked `TunaMenuTitle`, whose `blend = 0` keeps them out
  of the blending that would otherwise paint them in the colours underneath): Contests stacked over Problems in the left column (from
  `recent.snapshot()`), the commands on the right under "Catch of the day".
  - A problem's status (`entry_status`) is the judge's verdict from `submit.verdict_for` while
    it is current, else `core.local_verdict`, else nothing: the judge's answer settles a
    problem, so it always wins. A contest's (`contest_status`) counts current judge verdicts
    over `recent.contest_problems`, like `2/5 ACCEPTED, 1 REJECTED`. Local verdicts don't
    count there, because they exist only for problems that were run.
  - Statuses are `{ text, highlight? }` segments in the results grid's words and colours
    (`ACCEPTED`/`TunaCorrect`, `REJECTED`/`TunaWrong`, `PARTIAL`/`TunaWarning`, `PASSED` green
    only when all pass). Counts are their own uncoloured segments, and a zero `ACCEPTED` is
    `TunaDone`.
  - `recent_layout(lists, width)` lays both lists out together: names on the left (a
    contest's judge before its name), every status right of the longest name, and the status
    itself in the three parts `status_parts` gives it: the count, the verdict word, and what a
    contest counts besides. The first two get a column each, both filled from the right, so the
    counts stack however long the words beside them are and the words end on one edge however
    long the counts are; `, 1 REJECTED` trails past both. Aligning count and word together
    moves a count whenever its word changes length, and aligning whole statuses puts a bare
    `ACCEPTED` under another row's `REJECTED`. Byte-range `highlights` come with the rows. The sections pass it as `format`, so a narrow column
    shortens names with an ellipsis (`entry_name`: a contest's judge first) and never
    statuses.
    `problem_names` tells same-named problems apart by their contest directory (`2263/A`),
    and two attempts in one directory by file. An empty list gets a `—` row whose `<CR>`
    shows `recent`'s explanation.
  - Commands that need a runnable buffer are dropped for other buffers. Run runs the resolved
    mode without forcing it and shows whether it is forced; a forced mode adds an entry making
    it automatic, and the checker entry shows automatic (with the file in use) or off.
  - Modules are required lazily.
- **`keymaps.lua`**: `M.actions` maps actions to `:Tuna` commands. `mappings` are buffer-local
  via a `FileType` autocmd over `keymaps.filetypes`; `global` are global. `setup()` can be
  re-run (it tracks `applied_global` and clears the augroup). `preset` expands under a prefix
  with which-key groups (`tt`, `td`, `tg`); a key keeps its short label only while it stays in
  its group. `clean` is not in the preset.
- **`scaffold.lua`**: starter helper files per language, with overridable file names and
  templates. `template_for` is used by `clean`.
- **`health.lua`**: read-only checks for Neovim version, setup, the executables named by
  compile/run commands, Competitive Companion, submit providers and optional plugins.
- **`init.lua`** also wires `recent.setup()`, `submit.restore` on `BufReadPost`, and a
  `cnoreabbrev` so lowercase `:tuna` works.

## Testing

- Run `tests/run.sh` (all files, one headless nvim each, non-zero exit on failure) or
  `tests/run.sh runner`. Keep it passing: it ships with the plugin. Each file gets a throwaway
  `XDG_STATE_HOME` (tests open problems, which tuna records into `recent.json` on exit) and
  the plugin on the runtimepath by absolute path (a test may change directory). Each file prints
  `N checks, M failures` through `tests/harness.lua` (`ok`/`eq`/`has`/`report`).
- Files:
  - `surfaces.lua`: conformance of every surface to the `surface.lua` contract, every float
    tagged before it is entered, and every `runner_ui.mappings` key still resolving to an
    action;
  - `menu.lua`: the contest summary over both layouts, counting current judge verdicts
    only, a problem's judge verdict beating its local one and either lapsing with an edit,
    which rows a local verdict counts, statuses in the results grid's words and colours with
    counts uncoloured and stacked in a column of their own while every verdict ends on one
    edge, counted or not, names giving way to a narrow
    width (a contest's judge first), and `panels` stacking, scrolling, moving focus and
    squeezing a `format` column before the others, and the real menu's titles and
    free-standing banner;
  - `recent.lua`: both histories (default and configured sizes, move to top, a problem
    bringing its contest back, contests named by their parsed judge and contest or from the
    sidecar when no judge was recorded, dropping deleted directories, loading single-entry files,
    opening any entry, what is written);
  - `modes.lua`: the helper and run-setting rule end to end: availability (files, configured
    paths and commands, missing ones), automatic choices, forcing and `auto`, forced settings
    giving way and coming back, old sidecar entries, runners refreshing the checker per run,
    run-all honouring `checker off`, the Run pane's settings rows and which of them read as
    forced, and stress/interactor reruns reporting a missing helper;
  - `temp.lua`: the templates a scratch can start from, when a scratch is resumed, the
    resume/restart and template menus, and absorbing keeping the header of the template actually used;
  - `testcases.lua`, `compare.lua`, `judges.lua`, `download.lua`, `clean.lua`, `submit.lua`:
    unit tests of pure rules;
  - `runner.lua`: all four run modes with `vim.system` stubbed, covering what each child is
    handed, bare rows, save/answer semantics, disk drift and restore, path resolution, the
    swapfile contract, interactive grids and the conversation model, and the run gate
    (`settle_results`), the local verdict a finished normal, run-all and feed run saves, and
    live's typing keys starting a session, using real UI windows. `testcases.lua` also covers the
    `single_file` rewrite keeping untouched testcases.
- Modules expose file-local helpers to tests through `M._test` (`download`, `submit`, `clean`,
  `interactive`, `temp`, `menu`). They are not public interface.
- **Mutation-check new tests**: break the rule each test describes and confirm it fails, and
  confirm a harmless edit doesn't.
- The suite doesn't cover real processes, verdicts coming back, or most UI interaction. Verify
  those with headless scripts against real processes, kept in the session scratchpad.
