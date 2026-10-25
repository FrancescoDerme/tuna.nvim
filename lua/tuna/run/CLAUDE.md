# lua/tuna/run

The runners every run mode is built on, the helpers they find and build, the run settings and
judging. The modes themselves are in `modes/`, whose guide adds to this one. The rules that
hold everywhere are in the root `CLAUDE.md`.

## Helpers, run settings and builds (`tools.lua`)

- **One rule for every helper and every setting**, kept consistent on purpose.
  `helper(role, solution, cfg)` finds any role (checker, generator, bruteforce,
  interactor): the configured option (`checker`, `stress.generator`/`bruteforce`,
  `interactive.interactor`; a string is a helper file, compiled or a prebuilt binary, a
  table an `{ exec, args }` command whose args expand file modifiers but keep
  `$(INPUT)`/`$(OUTPUT)`/`$(ANSWER)`) wins over a sibling file named by `tool_names`, and a
  configured one that doesn't exist returns a note. Nothing is cached: disk decides now.
  A spec carries its role's run arguments (`ROLE_ARGS`: a checker's
  `$(INPUT) $(OUTPUT) $(ANSWER)`, an interactor's `$(INPUT) $(ANSWER)`), a configured
  command given no `args` included, so no caller keeps a default of its own;
  `expand_args(args, files)` fills them per spawn. A compiled helper runs, and its program
  is looked for, in `running_directory` (`program`'s `cwd`), as the solution's is, in every
  mode. The roles are `ROLES` (and, with the solution, `SCAFFOLDS`); their file names live
  only in the config's `tool_names`.
- The run settings, mode, interactive source and checker, are each **automatic until
  forced** (`get_mode`/`set_mode`, `get_source`/`set_source`, `checker_setting`/
  `set_checker`, nil or `"auto"` being automatic; the checker can only be forced `"off"`).
  Automatic: `detect_mode` (interactor, then generator + bruteforce, else normal),
  interactor-else-live, the checker when there is one. `resolve_mode`/`resolve_source`/
  `resolve_checker` return the forced choice while what it needs is available, else the
  automatic one plus a note (only stress and the interactor source need helpers). Keywords
  typed now force and run as typed; `auto` clears. The commands spell every one of them
  the same way: a setting changes only when its new value is named (a keyword forces,
  `auto` hands back, no keyword switches), and a **bare** setting command changes nothing
  and says how it is set (`show_checker`, `show_compare`, the same sentence a change
  ends with). `:Tuna checker` is `off`/`auto`; `:Tuna compare` takes a
  method, and every method simply becomes the problem's: there is no word for handing
  back, and the configured `output_compare_method` is just one of the methods. Choosing it
  keeps no override (`set_compare`, compared by `compare.method_name`), so a later change
  to the config still reaches the problem. Switching and cycling with one keypress belong to
  the menu's "Checker:" and "Compare:" entries, which show the state they move from.
  Persisted in the sidecar with the compare override, loaded lazily, removed when nothing is
  forced.
- **A build is reused while what it was made from is unchanged**, for the session only, in
  every mode and for every source (the solution, the helpers, each of run-all's solutions).
  - `build_stamp` is the compile command plus every file the build reads with the SHA-256
    of its contents: the source and each header it includes, found beside the file
    including it or in the command's `-I`/`-iquote`/`-isystem`/`-idirafter` directories,
    followed recursively, the compiler's own search path not followed. Contents, not
    mtimes: a save that leaves the text as built (an edit a formatter undid) is no change,
    and the scan reads the files anyway. The stamp is taken before the compiler starts, so
    an edit made while it runs is a change.
  - Only the languages whose `#include` lines the scan reads have a stamp
    (`FOLLOWED_LANGUAGES`: C, C++, Objective-C, CUDA). Any other language may build from
    files tuna can't see (a Rust `mod`, a Java class in a file of its own), so it has none
    and is built by every run: correctness over speed.
  - A new run reuses a *successful* build whose stamp matches and whose program still
    exists (`still_good`; `program_exists` checks a run command naming a path). A failure
    is built again by the next run.
  - Within the run that built it, a helper's build is answered as it is, failed or not,
    without reading anything (`prepare` matches the `spec`, which every run resolves anew):
    the checker is prepared once per testcase, and stamping a testlib checker costs
    milliseconds each time.
  - `prepare` does this for helpers and queues concurrent callers. A build made by its
    caller (`build_solution`, run-all's `compile_solution`) goes through `reuse_build`,
    which returns the reusable build or how to remember the one about to be made.
    `prepare` reports `(ok, err, output)`: the compiler's words on a build that
    *succeeded* too, since a helper that only warned still has something to say on its
    pane.
  - Not done, on purpose: hashing the preprocessor's output (`-E` ignores a precompiled
    header, so it costs a large part of the build it would skip, and building from the
    `.ii` is slower than from the source with the PCH; it is also per-compiler), trusting a
    binary on disk across sessions (it may come from other flags), and a
    `run_no_compile`-style command or flag (it runs a binary for code that is not on screen,
    and only ever fitted the normal mode).
- Compare methods are stored **by name** (`{ method = "float", tol }`), because a mixed
  array/hash table does not survive JSON. Every field is validated on read. That is also
  why a user's own method has a name (`compare_methods`) rather than being a function
  given straight to `output_compare_method`: a name can be typed, completed
  (`compare_names`), kept for a problem and shown, and `RunnerCore:effective_compare` takes
  the problem's override, else the config's, and resolves it to `{ name, fn }` when judging
  (`compare.resolve`), which `compare_output` runs. A bare function is no method, and a
  built-in's name always means the built-in: `float` parses a tolerance no function could
  take, so a user's method could take over `exact` and `squish` and never `float`; one named
  so is reported once and never used.
- **A support file is never a solution**: `is_support` is a helper (by name, `is_helper`)
  or a header (by extension, `is_header`: `h`, `hpp`, `hh`, `hxx`, `h++`, `inl`, `ipp`,
  `tpp`, any case). Neovim gives a header its language's filetype, so having a
  `run_command` does not tell one from a solution. A folder's solutions are listed in one
  place, `solutions_in` (`solution_bufnr`, run-all, `navigate.solution_in`,
  `contest_problems`, sharing testcases), which reads the directory with `vim.fs.dir`
  rather than a glob, since `globpath` takes a comma in a problem's name for a path
  separator; `find`, a helper by role, reads it the same way, once for all the role's
  names, and `utils.subdirectories` lists a contest's problem folders. A file's language
  (`filetype_of`) is matched once per extension for the session, against a stand-in name:
  listing solutions asks it of every file in every problem folder the menu summarises, and
  `vim.filetype.match` walks Neovim's whole table each time. A name without an extension
  is matched whole. A single file is asked directly (`recent`'s `BufEnter`, the menu's
  command list, `:Tuna pin`), and `find` never takes a header for a helper. Only C-family
  headers are known: a module file of another language beside a solution (a Rust `mod`, a
  Python import) still reads as one, since competitive solutions in those languages are
  single files.
- `solution_bufnr` redirects a run started from a support file to the sibling solution. Loading
  a buffer the user never opened must not leave a swapfile: `swapfile` is turned off *before*
  `bufload`, only for buffers tuna loads itself, and restored with a one-shot `BufWinEnter`
  that reads `vim.go.swapfile`.

## Runners

**`RunnerCore` (`run/core.lua`)** is the base of every mode (subclassed with `M.extend()`).
- `tcdata` rows. `execute_process(tcindex, cmd, dir, opts, on_done)` spawns via `vim.system`
  with its own timeout timer (TIMEOUT, KILLED, SIG, RET), then judges with `checker.judge`
  unless `opts.judge == false` (the Compile row), setting `judging` while it waits. Every
  program tuna runs (testcases, the checker, the stress search's steps, a session's solution and
  interactor) gets `tools.RUN_ENV` on top of the editor's environment:
  `GLIBCXX_DEBUG_MESSAGE_LENGTH=0`, since libstdc++'s debug mode wraps its reports at 78 columns
  and a narrower pane would wrap each of its lines again, leaving a word alone on a row.
  `vim.system`'s `env` adds to the environment, `uv.spawn`'s replaces it, so interactive mode's
  spawns take `tools.spawn_env()`, the whole of it.
- **Stale results are dropped**: `run_id` is bumped per spawn *and* in `reset_row`.
  `finish_process` gets the row object plus the token and bails if either the token changed or
  the row is no longer in `tcdata` (`owns_row`), closing its timer first (the timer is a closure
  local). The judge callback re-checks the token.
- **UI seams** keep `tuna.runner_ui` mode-agnostic:
  - `pane_content(tc, name)` returns text, or `core.SKIP` to leave a pane alone;
  - `row_label(tc)`, `status_settings()` (rows with the mode and judge) and `status_tail()`
    (rows after them);
  - `on_ui_shown(ui)` and `owns_pane(name)`;
  - `layout()` supplies a mode-specific grid that replaces the configured one;
  - `pane_titles()`;
  - `on_details_rendered(ui, tc)` runs after the detail panes are drawn, for panes the mode
    draws itself;
  - `legend_rows()` returns `{ title, rows }`, a section of the `?` legend of the mode's own
    (stress: the search row and what the run keys do to the search; interactive: the source
    playing the other side and what decides the verdict).
- **Editing contract**:
  - `editable_testcases` is a class flag. `row_editable(tc)` is true only for numeric `tcnum`,
    which excludes Compile and run-all headers.
  - Other members: `row_id`, `edit_bufnr`, `rows_for`, `next_tcnum`, `add_testcase_row`,
    `remove_testcase_rows`, `split_testcase`, `run_rows`, `sync_rows(nums, tctbl)`.
  - `idle()` reads `completed`, and structural edits wait for it.
  - `save_testcase(tcnum, input, expected, expect_empty_output)` writes, updates every row
    showing that testcase, clears `bare`, and re-runs, unless the runner is `preloaded`.
- **One build, for every mode.** `build_solution` spawns the compiler for the Compile row
  through `execute_process`, with the runner's own commands in normal mode and those of the
  normal runner a mode holds (`r`) otherwise, so a build reads the same everywhere: the same
  verdicts, the same timing, the same answer when a helper beside it failed. A build reused
  (see `tools.lua`) reads `CACHED` on the row, with the words its compiler said then.
  `build_all` starts it and the mode's helpers (`build_helpers`) **at once**, each being its
  own program with its own compiler: queued one behind another they are most of what a run
  waits for, and the cursor is held on the build step until the last of them lands. Its
  `on_solution` is for what needs only the solution (stress starts the testcases already on
  disk there). A failure stops at `on_build_failed`, the one thing that differs per mode, since
  what "nothing will run" means is its own (normal ends its lanes, stress `finish()`es its
  search, interactive sets `completed`). `defer_build` keeps that build on the runner for a UI
  opened with its rows only listed, and `M.compile_row()` is the row itself.
- **The build step is every source the run compiles.** The solution is the Compile row itself;
  each helper the mode needs is a step in `self.builds`, declared up front with `plan_builds`
  (a pane appearing halfway through would re-tile the row under someone reading it) and
  compiled through `build_helper`, which puts the compiler's words on it. A spec with nothing
  to compile (a prebuilt binary, an interpreted helper) has no compiler to quote and gets no
  step. `build_judge` builds the checker there too, without anything waiting for it, so a
  checker that failed says so beside the others rather than on the first verdict.
  `build_sources(tc)` is what the UI draws, in pane order, each with the `role` its spec
  carries (`tools.helper` stamps it, the solution is `solution`), which is what keys its pane;
  `build_spoke`/`build_pending` answer whether the step had anything to say and whether it is
  over, which is what decides if the cursor may be handed to the first testcase. Run-all has no
  build step: each solution's build is a row of its own.
- `M.time_limit(cfg)` and `M.parallelism(cfg, jobs)` are how every mode reads `maximum_time`
  and `multiple_testing`.
- **One vocabulary for a verdict**: `M.verdict(correct)` is what a judged row wears
  (`CORRECT`, `WRONG`, `DONE` with no answer), in every mode.
- `M.register(registry, bufnr, runner)` is how every mode keeps its runner by buffer: one
  `BufUnload` watcher per registry and buffer, however often the buffer is run.
- **One vocabulary for an ending**: `M.ending(how, timeout)` gives the status, colour and
  words for a process that did not exit cleanly (`TIMEOUT`, `KILLED`, `SIG n`, `RET n`,
  `vim.system`'s own timeout kill, code 124 and SIGTERM, reading as a timeout), for a testcase
  (`finish_process`), an interactive session and a stress helper alike.
- **Stopping**: `kill_process(idx)` ends one row and the run goes on; `kill_all_processes`
  stops the run, in every mode: it sets `stopped`, which every mode's lanes read before
  starting anything, kills what runs, marks the rows still waiting (`status == ""`)
  `NOT RUN`, and the run then settles as idle. Every start of a run clears `stopped`: the
  UI's `<C-r>` and `:Tuna run` stop first and then run.
- **A run of the whole set builds what changed**, in every mode, the solution included:
  `run_testcases` is the first run and `<C-r>` alike (the stress and interactive `M.run` end in
  it). A listed runner's first such run goes through `claim_listed`, which saves the sources
  and drops the build it kept, since the run builds anyway; a single row's run key goes through
  `built_first`, which builds first.
- **Local verdicts**: `save_local_verdict(solution, rows)` writes the sidecar's `results` when
  a run finishes: normal `check_complete`, run-all's `settle` (`save_local_verdicts`, each
  solution over its own case rows), and interactive session ends (`save_buffer_verdict` skips a
  wiped buffer). Stress saves none. Only judged rows count (`M.judged`, which run-all's header
  counts use too) (CORRECT passes; WRONG, TIMEOUT, RET, SIG fail), so a run that judged nothing
  leaves the entry alone. The source hash is recorded, and `local_verdict` answers only while
  it matches.

**Normal runner (`run/init.lua`)**
- `runner.new(bufnr)` resolves compile/run commands, directories and the checker. Stress,
  interactive and multi reuse it. Every run in every mode calls `RunnerCore:refresh_judge`,
  so a checker added, deleted or switched off, and a comparison overridden since
  (`compare_method`), apply to the next run of a cached runner. `:Tuna checker` and
  `:Tuna compare` also set them on the buffer's runners at once (`runners_of`), so an open
  board's judge row says what the next run will use, and never drop a runner, whose board
  no later run could then find to hide.
- `build_rows`: row 1 is `Compile` when compiling, and the build gates the testcases. With **no
  testcases** it builds one `bare` testcase 0, labelled `No input`, run on empty stdin with no
  answer (so `DONE`) and editable; saving it creates the testcase. `n` in the UI reuses an
  untouched bare row. An explicit `:Tuna run 5` for a missing testcase reports it and stops
  instead of falling through to a bare run.
- **Trailing numbers always name testcases** (normal, interactive, run-all). Stress runs
  none by number, and its count follows only a typed `stress`: `commands.run_mode` refuses
  numbers on a stress run it resolved itself, or `:Tuna run 5` would mean testcase 5 or five
  inputs depending on the files beside the solution, and after a typed `stress` it refuses
  anything but one number rather than dropping it unseen.
- `load_testcases` builds the same rows as `NOT RUN` with `preloaded = true` (`:Tuna show_ui`
  before any run) and keeps the build (`defer_build`), so `run_single` builds first through
  `built_first` as in every mode, and `run_testcases(nil)` claims it (`claim_listed`). The
  Compile row's own run key is the build.
- `:Tuna show_ui` (`commands.show_runner_ui`) opens the mode last run in this session, else
  the one saved for the problem (`tools.resolve_mode`), since after a restart nothing has
  run. Interactive, stress and run-all open the same way when they have no runner yet:
  `M.show(bufnr)` (`M.run(…, { show_only = true })`) lists the rows with
  `RunnerCore:mark_not_run` and keeps the build on the runner (`defer_build`). Their
  run keys go through `RunnerCore:built_first`, so the first one builds and then runs, and
  nothing is saved or spawned before it.
- `run_single` **claims the runner** (`completed = false`) until it settles; otherwise edits
  could slip through mid-run. From an idle runner it closes the lanes first (`next_tc` past
  the last row): a row added after a run (`n`, `u`, a split) would otherwise read as one a
  lane has still to start, and `check_complete` would never settle the run.

**Checker (`checker.lua`)**: `"builtin"` (what `resolve_checker` returns when there is no
checker) delegates to `compare.lua`. An external checker runs
as `checker <input> <output> <answer>` (exit 0 means correct) and is compiled via
`tools.prepare`. Its message (`tc.checker_message`) is appended to the Errors pane by the base
`pane_content`, and `reset_row` clears it. A checker that did not build or cannot start gives
no verdict, and says so on the row alone, never in a notification: the build step already
shows why, beside the other sources, and a notification per testcase would repeat it. Stress
builds the checker with its generator and bruteforce (`search_helpers`) and stops on an input
the checker gives no verdict on, since searching on would end in "no counterexample found".

**Compare / diff**
- `compare_output` returns `true`, `false`, or `nil` when there is no answer. `float` is
  `{ "float", tol }`, token-wise, absolute or relative tolerance (`float_equal`, which the
  diff uses too). An unknown method judges nothing and is reported once per session.
- `diff.compute` is **positional**: line *i* against line *i*, token against token, never
  re-aligned, because CP output is positional and an edit-script diff pairs the wrong lines. It
  marks spans, never a whole disagreeing line, with an empty span where the shorter of two lines
  ends or a character is missing (`CHANGE` names no highlight group; a line one side lacks,
  `ADD`/`DELETE`, is coloured whole). Granularity follows the compare method (characters for
  `exact`, tokens otherwise, `float` tolerance applied), so the marks never contradict the
  verdict, and texts the method judges equal get no marks at all: `squish` and `float` read one
  stream of tokens, where line breaks elsewhere are no difference, while the diff walks lines.
  `TunaDiffText` is a red tint blended into `Normal`'s background, re-derived on `ColorScheme`.
