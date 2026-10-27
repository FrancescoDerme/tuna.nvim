# lua/tuna/run/modes

The run modes beyond the normal one: stress, interactive and run-all. Each is a `RunnerCore`
subclass, so `lua/tuna/run/CLAUDE.md`, which loads with this guide, holds the rules they share.
The rules that hold everywhere are in the root `CLAUDE.md`.

**Stress (`stress.lua`)**: `StressRunner`.
- Helpers come from `stress_helpers` (`tools.helper` for both roles), resolved again by every
  run: missing ones stop the run (a rerun keeps its mode) and, when they are simply absent,
  are offered as starters (`scaffold.create_missing`, see `lua/tuna/workspace/CLAUDE.md`).
  Every run builds them through `build_helpers` (an unchanged one is reused, and an edited
  one, or one that failed, is built again, rather than the search spawning a binary that
  was never produced). Each step of the search goes through `spawn`, which `pcall`s
  `vim.system` (a missing binary makes it throw), reports a failed start as that step's
  failure, and drops a result that lands after a stop.
- **Two lanes.** The testcases already on disk re-run through the solution as soon as it is
  built (`build_all`'s `on_solution`, while the generator and bruteforce are still
  compiling), and the search starts as soon as all three are built, not when the re-runs
  end: the hunt is what a stress run is for, and it would otherwise wait on testcases that
  have nothing to do with it. Only a stop ends the re-run lane (`stopped`, not
  `aborted`), or a search that found its counterexample on the first seed would leave half of
  them at no verdict, and `idle()` counts the lane (`rerunning`) as well as the search.
- A counterexample becomes a saved testcase only if its input is new. The search stops at
  `saves_per_run` or `max_saved`, counted over rows that stand for a testcase on disk
  (`testcase_count`).
- **The search has a row** (`search_row`), listed by `load_testcases` with the testcases and
  dropped by `finish`, holding the input being tried and both outputs. It is there from the
  moment the board opens, not from the moment generation starts: the hunt is what a stress
  run spends its time on, and it would otherwise appear only as it ended. `mark_not_run`
  leaves it saying what it is for (`NOT RUN` is a testcase's word for having no verdict yet),
  and `run_single` on it does nothing, there being no stored testcase behind it. Its `tcnum`
  is a string (`SEARCH`), so it is not editable, not compared against disk, and skipped by the
  counterexample dedup scan, which would otherwise find the input in it every time. It is
  kept last, a counterexample is inserted above it, and `row_label` gives it the number
  that counterexample would take (`next_num`). Every search rebuilds its rows from disk
  first (`load_testcases`), but the row also exists while the board is idle (listed only, or
  left carrying a helper's failure), where add, restore and split can put rows beside it: the
  base `add_testcase_row` puts them among the testcases, above it, and the override moves
  `next_num` past the number taken, or the board would read one number twice until the next
  run.
- **The generator and the bruteforce are judged on the signal too** (`core.ending`), not
  on the exit code alone: a crash (a sanitizer abort, a segfault) exits 0 and reports the
  signal, so reading the code alone would pass an empty output off as the bruteforce's
  answer, and every input would be a counterexample saved with no answer beside it. Either
  failing stops the search, because every verdict is read off the two of them. A solution that
  crashes or times out on a generated input is a counterexample wearing the same words.
- **A failure is reported where a testcase's is.** `helper_failed` puts the verdict a
  testcase would wear for the same ending (`core.ending` gives it) on the search row and
  what the process said in its Errors pane, and the row then stays (`drop_search_row` keeps
  one carrying a verdict) holding the seed's input, which is what there is to debug. Nothing
  in a runner answers a process with a float: a compile failure of a *helper* is the same,
  said on the Compile row (`refresh_build_row`, FAILED) beside the pane holding what its
  compiler wrote. The floats that remain are about the mode, not a process: a configured
  helper that is broken, found on a rerun.
- **Every run searches from a seed of its own** (`seed_base`, the clock's microseconds, kept
  to six digits for the Run pane): the generator is handed `seed(i)`, the base plus the
  iteration, and the Run pane's `seed` row and a helper's failure name it (the input's number
  instead when `pass_seed` is off and the generator was handed none). A base fixed for every
  run would repeat the same search after one that found nothing, and reproducing a
  counterexample needs no seed, since it is saved as a testcase.
- The bruteforce runs on `stress.bruteforce_time`, not `maximum_time`: it is slow by design,
  and the solution's limit is not a statement about it.
- A counterexample whose bruteforce output is empty is saved with `expect_empty_output`, an
  answer that is empty rather than absent, or the row would come back unjudged.
- **A search with no bruteforce** (`hunt`) looks for an input the solution crashes on, runs
  out of time on or exits with an error on (`core.ending`), and saves it with no answer. Only
  how the run ended counts: a checker would be handed an empty answer and reject every output,
  so it is neither built nor asked (`search_helpers`), while the testcases re-running beside
  the search are judged as ever. It is offered, never assumed: `detect_mode` still wants both
  helpers, and a stress run asked for (typed, from the menu, or a rerun on the board) with only
  the bruteforce missing offers it beside the bruteforce's starter (`offer_helpers`, through
  `create_missing`'s `instead`), so a half-written generator does not turn every `:Tuna run`
  into a search. `stress_helpers` hands back the generator even then. Every run looks the
  bruteforce up again, and one found makes the board a stress run again (`hunt` follows it).
  The Run pane's `brute` row, on every stress board so the rows stay put, says `none`, and the
  legend says what is kept instead.
- `idle()` means the search has stopped, so every path that ends a run has to `finish()`,
  a failed build and a helper that didn't compile included.

**Interactive (`interactive.lua`)**: one session at a time; the source is remembered per file.
- **feed**: the testcase input is sent a line at a time. It keeps the configured grid with the
  canonical Input/Expected Output panes and is the only editable source (`editable_testcases`
  set per instance). Its no-testcase row is `bare`. `run_single` claims the runner, and every
  path where nothing will run settles it: a build that failed through `on_build_failed`, the
  rest by setting `completed = true`.
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
    identical content). The build step is not a conversation and is left to the UI, which
    draws it with one pane per source, as in every other mode.
  - Columns are `scrollbind` and `nowrap` (`on_ui_shown`, when the row laid out,
    `ui.drawn_row`, is a session's: the build step is no conversation, and its panes wrap and
    scroll on their own). All three follow the latest line unless one is being read back
    (cursor in it, not at the bottom), in which case none move. `scrollbind` is re-armed after
    a scroll made from code, or later manual scrolls drift.
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
  the interactor's exit code, and it gets `$(INPUT)`/`$(ANSWER)`. The solution crashing and
  the time running out end the session with `core.ending`'s status instead. Every run goes
  through `with_helpers(cont, whole)`, which refreshes the checker and, for the interactor
  source, resolves and prepares the interactor again, offering its starter when it is absent
  and reporting a broken configured one, instead of running; `whole` (a run of every session)
  builds the solution too.
- Sessions run one at a time (`run_sessions`). `kill_process` ends the one running, marking
  its row `killed` so every source's exit path reads `KILLED`; `kill_all_processes` also sets
  `stopped`, and no session starts after it.

**Run-all (`multi.lua`)**
- Solutions are every runnable sibling source that is not a support file (`tools.is_support`),
  of any language, each with its own filetype's commands. The directory is the buffer's parent,
  or the cwd for a scratch buffer.
- `MultiRunner` is a flattened matrix: solution header rows (`row_label`, live `correct/total`)
  above indented testcase rows. Its testcases are those a normal run from the buffer reads,
  and its rows are the one record of them (`testcase_numbers`): `lay_out` builds the matrix
  for a list of numbers, keeping every row already there, so an add, a delete and a row
  renumbered by a restore leave nothing behind to disagree with the grid. Keep no copy of the
  list beside the rows: renumbering a row leaves it stale, and the next add brings the old
  number back. With no testcases it lists a `bare` testcase 0 under every solution, labelled
  `No input`, as the normal board does, and a testcase added or saved on the board is every
  solution's, written as the buffer's own.
- `opts.list` (`:Tuna run all 2 3`) runs every solution on those testcases alone, a missing
  one reported as normal mode reports it.
- All solutions compile first, then everything runs in one shared pool of `multiple_testing`.
  A compile failure is a `CE` row.
- The pool, `run_single` and `rerun_solution` all settle through `settle`, once nothing runs
  and nothing is queued; a stop empties the queue (`qpos`), so a stopped matrix settles as soon
  as its killed cases are in. A header's `correct/total` counts judged rows only
  (`core.judged`), so a row with no answer, stopped or never run is not a failure. A board
  launched from a buffer that is not a solution reads its testcases through
  `testcases.get_testcases`, by path. The checker comes from `tools.resolve_checker` against
  `solution` (the buffer's file, else the first solution), so `:Tuna checker off` applies.
