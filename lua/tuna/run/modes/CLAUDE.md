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
  `tools.system` (a missing binary makes `vim.system` throw), reports a failed start as that
  step's failure, and drops a result that lands after a stop.
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
  leaves it saying what it is for (`not run` is a testcase's word for having no verdict yet),
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
  said on the compile row (`refresh_build_row`, failed) beside the pane holding what its
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

**Interactive (`interactive.lua`)**: the source is remembered per file.
- **A session is its row's** (`tc.session`: the solution's stdin `sol_in`, its processes `sol`
  and `int`, `running`). Its callbacks write to the row only while it is still the row's
  (`mine`), so a row talked to again from the start leaves the session it replaced nothing to
  write over; its end still calls `on_done`. Every session started lets the row's old one go
  first (`drop_session`, in `run_one_session`): one a row's run key started while the others ran
  in turn would otherwise be replaced unkilled, out of reach of every stop. Live
  sessions run side by side, each on its row; feed and interactor run one after another.
- A session started on its own (a row's run key, `n`, a typing key on a row with none) holds
  the runner until it ends (`claim`/`release`), and the runner is idle once none holds it and no
  run of every session is going (`sequence`). That run is a token of its own: a run started
  after it replaces it, so the session it let go, ending later, does not carry the old run on
  beside the new one. Where nothing will run (a failed build, no interactor) `settle_all`.
- **feed**: the testcase input is sent a line at a time. It keeps the configured grid with the
  canonical Input/Expected Output panes and is the only editable source (`editable_testcases`
  set per instance). Its no-testcase row is `bare`. A session that ended cleanly is judged
  as a testcase is in every mode (`checker.judge`), answer or not: a comparison has nothing
  to say without one, and a checker of its own still reads the output. `run_single` claims the runner, and every
  path where nothing will run settles it through `settle_all`: a build that failed
  (`on_build_failed`), an interactor gone.
- **live** plays no testcase (nothing it is handed reaches the session), so its board is the
  build and one session, `live_row`, whatever is on disk: a row per testcase would be the same
  conversation held once each. A session row's `tcnum` is its name (`live 1`), like the build
  step's, so nothing numbers, edits or compares it with disk. `n` is another session with the
  same build, beside any still talking (`add_row`, which `RunnerUI:add_testcase` asks first;
  `new_row_words` names it in the legend), the rows standing for sessions as a normal board's
  stand for testcases. It waits for a build under way, whose program is still being written. A run of every session starts them all at once, the board following
  the first. Typed numbers are dropped with a note. Nothing judges
  a live session (`judges()` is false), so no checker is planned or built and the Run pane
  leaves out the judge and diff rows.
- **live** and **interactor** are a **conversation**. `layout()` returns the grid
  `interactive.layouts[source]` gives and the option's name with it, so a bad one is reported
  as what it is; `false` there (feed's default) means the configured grid. The shipped
  conversation is selector | Output | Live | Errors (`so`/`si`/`se`), with no Expected Output:
  a `fit` selector (see `lua/tuna/runner_ui/CLAUDE.md`) and the three columns at `1/1/1`, so
  they are as wide as each other, `so`/`si` exactly, Errors give or take the cell the last
  column absorbs from the grid's rounding (`rec_compute_layout`).
  - Each row keeps `tc.log`, one entry per rendered row `{ col, text, open }`, blank in the
    other columns. `log_append` continues an open row only while no other column has spoken.
    `log_note` puts tuna's own notes (timeout, exit code, spawn failure) on an Errors row.
    Nothing is echoed between columns, and `tc.stdout` stays the solution's own output.
  - `on_details_rendered` draws the columns (no undo, not modified). A conversation only grows,
    so a redraw of the row drawn last (`self.drawn`: the row, its log table, how many rows and
    whether the last was open, each buffer's `changedtick`) writes only the rows from the last
    open one down, at the cost of what is new. Anything else (another row, a trimmed log, a
    column changed by something else: typing, the build step borrowing the buffers) draws it
    whole through `set_column`, which still writes from the first line that differs, so
    Neovim repaints only what changed. The build step is not a conversation and is left to the
    UI, which draws it with one pane per source, as in every other mode.
  - Columns are `scrollbind` with `smoothscroll` off (`on_ui_shown`, when the row laid out,
    `ui.drawn_row`, is a session's: the build step is no conversation, and its panes wrap and
    scroll on their own). Output and Live are `nowrap`; Errors wraps as the UI wraps it on any
    testcase row, and `fill_rows` puts blank `virt_lines` under the Output and Live rows facing
    an Errors line that wraps, as many as the screen rows it takes past one
    (`nvim_win_text_height`), so every row is as tall in each column and a top line means the
    same rows in all three. Hard-wrapping the text instead would break what is yanked, searched
    and zoomed. Fillers are measured again from the first row written, and all of them when the
    Errors column's width changes (`on_ui_shown` forgets it). All three follow the latest line
    unless one is being read back (cursor in it, not at the bottom), in which case none move;
    following counts screen rows (`bottom_topline`), the rows being of different heights.
    `scrollbind` is re-armed after a scroll made from code, or later manual scrolls drift.
  - `run_one_session` starts the session and then hands the cursor to its row
    (`ui:follow_row`, which never leaves a build step still going or one that spoke): that
    row's columns are the conversation, and in live it is the only row whose column is
    typable, so the UI would otherwise sit on compile with nothing to show and nothing to type
    into.
  - **Insert mode is asked for by a run, never by showing a board.** Every run of a live session
    sets `type_into` to the session it starts, as it is asked for, before any build: a run of
    every session (`run_testcases`, from `:Tuna run` and `<C-r>`) its first, `run_single` (`r`,
    `n`, a typing key on a row with none) its own. Asked once the build ends instead, it would
    survive the board being put away meanwhile, and a later `:Tuna show_ui` would type. A typing
    key on a row already talking whose column is not typable yet asks for typing and runs
    nothing, as another session would drop the one that just began. The render that shows that row talking consumes it, putting the cursor at the end of
    its column in insert mode. `hand_over` lets it go when it can no longer be honoured as asked:
    the cursor is not in the board (`runner_ui.owner_of`), or the session talks while the board
    shows another row (a build that spoke holds it), since moving there by hand later would
    throw you into insert mode unasked; `on_ui_hidden` lets it go with the board. A board opened
    by `:Tuna show_ui` or shown again asks nothing: you may be back to read, stop or switch.
    It is a row, so it never carries over to another one.
  - In live, the keys that start typing (`i`/`I`/`a`/`A`/`o`/`O` and `<CR>`) are bound on the
    Live column: while it is typable they are Vim's own (replayed through `feedkeys`), and
    before that they start a session on the row on screen (`start_talking`, through
    `run_single`, with the build there is) instead of raising `E21`, and are typed into once it
    talks. `<CR>` and `live_send` talk to the session of the row on screen
    (`self.drawn.tc`). While the column is read-only the board's other keys are bound there
    too (`pane_keys` names the ones it keeps), so `n` works on it as on every read-only pane.
  - In live, the Live column ends in the line being typed, faced by blank lines in the other
    columns, and it is preserved across redraws (`keep_last`). `<CR>` leaves the line where it
    is, opens a new one under it with the cursor on it, and calls `live_send`: the redraw then
    finds the sent row already in place, where clearing it would show the line gone for a
    frame. When the session ends the line is removed, the column becomes unmodifiable, and
    insert mode is left. Completion plugins are kept out of the column
    (`surface.no_completion`): what is typed there is sent, and a menu would stand between a
    reply and `<CR>`.
  - Only live's Live pane wears the editable accent.
- interactor: `vim.uv.spawn` pipes cross-wire the solution and the interactor; the verdict is
  the interactor's exit code, and it gets `$(INPUT)`/`$(ANSWER)`. The solution crashing and
  the time running out end the session with `core.ending`'s status instead. Every run goes
  through `with_helpers(cont, whole)`, which refreshes the checker and, for the interactor
  source, resolves and prepares the interactor again, offering its starter when it is absent
  and reporting a broken configured one, instead of running; `whole` (a run of every session)
  builds the solution too.
- **A session is bounded as its pipes are read** (`within`, in the fast context, before
  anything is scheduled): past `maximum_output`, the solution's two streams in live and feed,
  everything the two sides print in interactor, it is killed and reads `ole`, the chunk over the
  line dropped and a note put in the Errors column (feed's Errors pane). Scheduled first, a
  program printing in a loop would fill the queue faster than it empties. What was read before
  a session ended is still its output: `done` (the process gone, the fast context's to read)
  never drops a queued chunk, `settled` (its end handled, on the main loop, after them) does, and
  the interactor's limit ends the session from the main loop for the same reason, its exit
  callbacks leaving the ending to it. Read the other way, a program that prints and exits loses
  the end of its output. `tc.log` keeps at most `SHOWN_ROWS + TRIM_ROWS`
  rows, trimmed back to the latest `SHOWN_ROWS` in one batch (`log.dropped` counts the rest,
  on a note above them), since every row kept is a line in each column, and a batch costs one
  whole redraw where trimming row by row would make every redraw whole. Live and
  interactor collect `tc.stdout` in pieces joined when the session ends, nothing reading it
  before (their panes are the log); feed shows it as it streams, so it is joined once a tick.
- `kill_process(idx)` ends the session of the row on the cursor, else, where sessions run one
  after another, the one running (`active_index`), marking its row `killed` so every source's
  exit path reads `killed`; a live session is stopped on its own row only.
  `kill_all_processes` ends every session and sets `stopped`, and no session starts after it.

**Run-all (`multi.lua`)**
- Solutions are every runnable sibling source that is not a support file (`tools.is_support`),
  of any language, each with its own filetype's commands. The directory is the buffer's parent,
  or the cwd for a scratch buffer.
- `MultiRunner` is a flattened matrix: solution header rows (`row_label`, live `correct/total`)
  above indented testcase rows. A header has no input and no answer, so its grid leaves Input
  and Expected Output out (`blank_panes`), and those two are shown only where they can be typed
  into. Its `so` buffer lists the solution's verdicts there, so it is `verdicts`, zoomed by
  `zoom_verdicts` (`p`), not `output` by `o` (`pane_titles`, `zoom_actions`). Its testcases
  are those a normal run from the buffer reads, and its rows are the one record of them
  (`testcase_numbers`): `lay_out` builds the matrix
  for a list of numbers, keeping every row already there, so an add, a delete and a row
  renumbered by a restore leave nothing behind to disagree with the grid. Keep no copy of the
  list beside the rows: renumbering a row leaves it stale, and the next add brings the old
  number back. With no testcases it lists a `bare` testcase 0 under every solution, labelled
  `no input`, as the normal board does, and a testcase added or saved on the board is every
  solution's, written as the buffer's own.
- `opts.list` (`:Tuna run all 2 3`) runs every solution on those testcases alone, a missing
  one reported as normal mode reports it.
- All solutions compile first, then everything runs in one shared pool of `multiple_testing`.
  A compile failure is a `ce` row.
- The pool, `run_single` and `rerun_solution` all settle through `settle`, once nothing runs
  and nothing is queued, which it reads off the rows too (`running`, `judging`) and off
  `rerunning`, a solution's re-run from its build to its last case: several re-runs can be
  in flight at once, and the first to end must not settle the board under the others; a stop empties the queue (`qpos`), so a stopped matrix settles as soon
  as its killed cases are in. A header's `correct/total` counts judged rows only
  (`core.judged`), so a row with no answer, stopped or never run is not a failure. A board
  launched from a buffer that is not a solution reads its testcases through
  `testcases.get_testcases`, by path. The checker comes from `tools.resolve_checker` against
  `solution` (the buffer's file, else the first solution), so `:Tuna checker off` applies.
