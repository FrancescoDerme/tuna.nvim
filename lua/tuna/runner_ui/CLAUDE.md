# lua/tuna/runner_ui

The runner UI every run mode draws its rows on. The rules that hold everywhere are in the root
`CLAUDE.md`.

## Runner UI

**Structure**
- Panes: `st` (the "Run" status, carved from `tc`'s rectangle), `tc` (selector), and the detail
  panes, named for what they show on a testcase row (competitest's vocabulary): `si` standard
  input, `so` standard output, `se` standard error, `eo` expected output. The UI creates the six
  buffers (adopted through `surface`, `write_panes` as their `:w`); an interface only places
  windows onto them, `relayout(windows, config, init_winid, status_rows, grid)` being its whole
  API: `popup.lua` tiles floats, moving the windows that stay, `split.lua` opens native splits
  anew, both from one recursive `{ ratio, child }` grid, levels alternating columns and rows.
  Splits need room Vim may refuse (`E36`), where floats tile any size: `split.relayout` then
  closes what it opened, puts `equalalways` back and raises, and `lay_out` draws the board as
  floats from there on, said once.
- **Six pane buffers, never more**: a buffer nothing shows is a cost with nothing bought. The
  build step, which has no input, answer or output, borrows the four detail buffers for its
  sources (`BUILD_PANES`), keeping their names out of all a user reads or writes there.
- **A pane is a role, a buffer a slot.** A pane is what a row shows (Input, Output, `errors:
  gen.cpp`), a buffer is what holds it, named by its code name (`si`, `eo`, `so`, `se`), which
  is the role it has on a testcase row. Keep the two apart in this guide and in comments: the
  `si` buffer is the Input pane on a testcase row and a source's errors on the build step, so
  "Input is read-only" says something no user sees.
- `M.owner_of(bufnr)` answers which runner a pane buffer belongs to, from the module-level
  `pane_owner` map filled in `show_ui` and cleared in `delete` (`commands.target_buffer`).
- `layout.resolve` validates a layout (known names, no duplicates, well-formed pairs, the names
  its kind requires) and falls back to the default with a WARN, once per board (`checked_grid`,
  by option name), so a re-tile never repeats it; the interfaces get a grid already checked. Two
  kinds whose vocabularies do not mix (`layout.kinds`): a testcase row's grid (`run`) places
  `tc` and the detail panes, the build step's (`build`) `tc` and one `build` cell, since the
  detail panes' names would say stdout or stdin there. A pane the grid omits keeps its
  **buffer** (content kept, still zoomable, the zoom being the one way to read it) but no window
  (`winid` nil), and which ones changes with the row on screen, so every window call goes
  through `w.winid and api.nvim_win_is_valid(w.winid)`, never the second half alone.
- **The grid follows the row on screen.** `grid(row)` answers the build step with
  `runner_ui.compile_layout` (checked as a `build` grid) and other rows with the mode's
  `layout()` or the interface's configured grid (`configured_grid`), without the panes the row
  has nothing to show in (the mode's `blank_panes(row)`, run-all's solution headers leaving out
  Input and Expected Output), `leave_out` giving their room to the panes beside them by their
  share, never to the selector, whose width and the Run pane's stay put; `titles_for(row)`
  gives every pane's title there, stored on the pane records before the interface places them,
  taken again each re-tile, since the row can rename a pane.
- **A `fit` selector** (`{ "fit", "tc" }`, every shipped grid's) is made a ratio by `fitted`
  before anything else reads the grid (`leave_out` and `stack_into` do arithmetic on shares):
  `fit_grid` gives it the ratio that lays it out at a size in cells, against the frame the
  interface reports (`frame`: popup and split each lay out from their own options), its width
  where its level divides width and its height where it divides height (a side split, whose
  top level is rows). The height is the Run pane's rows and the list's, counted when the board
  opens (`fit_rows`, forgotten when it is put away): a row added later (`n`, a counterexample)
  scrolls the list rather than re-tile the board under a run. The width is what the selector could *ever*
  need on the board, never what it shows now: the widest Run pane row, else both selector
  columns at `SELECTOR_WIDE` and a `999.999 s` time, plus its line numbers and borders, capped
  at half the board. Measured from labels, verdicts or times on screen, the board would re-tile
  mid-run as they change length (a stress search row gaining a digit), and a label longer than
  its column is cut by `selector_columns` whatever the pane's width. A Run pane row that counts
  (stress's `iter`, `seed`) is padded to its widest for the run, for the same reason. The
  margin is the window's own once it exists and the line-number formula before, which agree
  because no pane has a sign, fold or status column (`layout.window_options`): a split takes
  those from the user's settings, and the two disagreeing would re-tile the board as it opens.
  `layout.resolve` refuses `fit` on any pane but `tc`.
- `build_assignment` gives each source of
  the build step one of the `BUILD_PANES` buffers in order, and `stack_into` splits the `build`
  cell into them, one above the other, so the grid, the titles (`errors: gen.cpp`,
  `build_titles`, a pane named after its source only when there is more than one), the text
  (`build_text`) and the zoom keys (`opens`) all come from one placement. The placement joins no
  text, as the render tick asks for the grid each render. The UI fills the build step's panes,
  not `pane_content`: a build is the same in every mode. No "keep the testcase grid" setting for
  the build row: it has no `build` cell, and a detail pane's name would mean two things.
- The render tick compares the grid and the titles with `drawn_layout` and `drawn_titles` (a
  grid already without Input and Expected Output is the same on a run-all header and a
  testcase row, whose `so` titles differ) and calls `redraw_grid`, which lays it out again
  (`lay_out`; a resize is the same call): the panes keep their buffers (content,
  keymaps, unwritten edits) and only windows move, open or close, since rebuilding would drop
  all of that and race the rows landing in them. Focus stays on its pane, else the selector: the
  split interface closes the window you are in on every re-tile, and the new grid may leave the
  pane out. What depends on the kind of row (wrapping, the accent, the zoom keys, `on_ui_shown`)
  reads `drawn_row`, the row laid out, never the selection: `show_ui` lays out for the row it
  opens on a tick before selecting it, and the grid being the same, nothing re-tiles then.
  `relayouting` marks the windows closing and opening as the UI's own, so neither `WinClosed`
  (the user closing the UI) nor a cursor event (a move by hand) is believed, until a tick later
  when they are delivered. `watch_pane_window` re-arms the per-window `WinClosed`, and both
  interfaces skip a pane whose buffer was wiped (`:%bwipeout`).
- Rendering is **coalesced to one per tick** (`render_scheduled`, flags `update_windows` and
  `update_details`).
- **The selection is a row, not a line** (`selected_row`, read through `current_row`): it stays
  on its row when rows are added, removed or renumbered around it, so nothing that moves rows
  has to remember it. A row gone (deleted, or the rows built anew by a run) leaves it the row
  now on `selected_line`, the line the selector last drew it on. A delete of the selected row
  picks its neighbour first (the testcase after it, else the row before it): in run-all every
  solution above loses a row too, and the line would land in the next solution. A row the
  board puts there for the user (added, restored) is `RunnerCore:row_for`, in run-all the one
  under the solution the user is on.
- **The cursor is put in one place**, `render_selector`, on the selected row: whenever that row
  is drawn on another line than `selected_line` (rows moved around it, or code chose another),
  and always while the choice is the UI's, where Vim would clamp the cursor of a shorter list
  onto another row. `goto_row` only selects, and the cursor follows once the selector holds
  the row. A move by hand is a `CursorMoved` that leaves `selected_line`, which the handler
  sets at once, or a move back before the render would read as none. It is the line that is
  compared, not the row: an event between rows moving and the render finds the cursor on its
  old line, and that is no move.
- **Which row is shown** is the UI's choice until the selector is moved by hand (`user_moved`).
  `follow_row` is how the UI chooses, a no-op once the user has, and in every mode it never
  leaves a build step still going or one that had something to say (`build_pending`,
  `build_spoke`): that is what answers the run, and a warning landing a moment later would
  arrive on a row nobody is looking at. Three things choose: `show_ui` takes `opening_row()` on
  its scheduled tick, *after* the rows exist; every render calls `follow_after_compile`, leaving
  a compile row that ended with exit 0 and printed nothing for the row last looked at, else the
  first testcase; and interactive's `run_one_session` follows the row it talks to (its columns
  are the conversation, and only a talking row's Live column is typable). Picking a row is about
  what is shown and nothing else: no mode changes the editor's mode on it, since a board opened
  or shown again may be there to be read.
- **Every mode starts its run before its board opens** (`RunnerCore:open_on`, from `commands`
  for the normal runner and from each mode's `M.run`): what the run settles as it starts (a
  build it reuses, a live session it starts) is settled when the board picks its row and lays
  its grid out, so it never lays out the build step only to leave it a tick later. Nothing a
  run does as it starts needs the board: the entry points check the helpers it needs before
  making a runner. While the choice is the
  UI's, cursor and selection must agree, or the editor's own cursor event reads as a move by
  hand: `show_ui` selects nothing, `selected_line` on 1, until the tick chooses. The choice
  returns to the UI through `choose_row_again` (`user_moved` off,
  `opening` on) on a run of the whole set that was *asked for* (`commands.run_testcases`, the
  UI's `run_all_again`, not a single row's `built_first`), so every run starts as the first did,
  and in `show_ui`, which reopens on `last_row_id`, kept on the runner.
- `opening_row()`: a run whose build has not finished opens on it (`building`), whatever was
  last looked at; otherwise `last_row` (`last_row_id`, matched by `row_id`), else
  `initial_row()`, the first testcase, or compile when it printed something. `building` is about
  the *run*, not the process (`not preloaded`, and the compile row unfinished or a helper beside
  it still compiling, `build_pending`): between the rows being built and the compiler being
  spawned, a UI opened would otherwise draw the panes of a run and redraw them a tick later, and
  a solution whose build was reused is over at once while its helpers are not. For the same
  reason the modes `mark_not_run` before `show_ui`.
- `render_selector` lays rows out in three columns (header, verdict, time) through
  `selector_columns`: 10 wide while the pane holds them, content-sized plus a space when not,
  and without the time rather than cutting a number in half (a grid giving it a small share).
- `status_lines()`: mode, what judges (`checker` with its file, else `compare` with the method),
  the mode's settings (`status_settings`, interactive's source), diff on/off, runner tail,
  the judge and diff rows left out where the mode judges nothing (`judges()`, live),
  `help: ?`, rows fixed per runner. The judging row is named after the command that sets what it
  shows, not `judge`, which everywhere else in tuna is the online judge; one row rather than
  two, since with a checker the comparison decides nothing and the pane is narrow. A setting
  that is the user's choice (`mode`, `compare`, `source`) has a `*` after its name, explained in
  the `?` legend: one column, where a word after the value is what the narrow pane cuts off
  first, and a row naming the forced settings repeated the rows above it and said `none` most of
  the time. `compare` is forced when the checker is off or the method overridden; `checker`
  never is, a checker being only ever found.

**Inline editing**
- Editable panes are always-modifiable `acwrite` buffers. `:w` from **any** pane saves the row
  the panes show (`pane_tcnum`, the row last *rendered*, not the selected row); a write with no
  change does nothing. Unwritten edits live in `ui.pending[tcnum]`: they survive row switches
  and resizes, override `pane_content`, feed the diff, and the row reads `edited` (unstyled).
- `on_pane_edit` must stay O(1) in testcase size. It reads only Vim's `modified` flag (a change
  leaving it unset raises nothing: `TextChanged` also reports the UI's own filling of a pane the
  first time it is entered after) and re-renders the selector only when the edited set changes
  (`edited_sig`). Comparing with the stored text (`w.baseline`, `panes_changed`) happens only in
  `capture_pending` and the 120 ms debounce `schedule_settle`, so text typed back to its
  original stops counting. Pane `modified` flags are then cleared: a modified `acwrite` buffer
  blocks quitting with E37/E162.
- `capture_pending` runs before anything repoints the panes. `discard_pending` clears `pending`
  and the flags together.
- Keys with no text to author: `n` adds a row (a mode's own first, `add_row`: live's sessions),
  `t` generates one, `x` deletes, `u` restores,
  `c` splits; structural keys wait for `idle()`. Generating takes `t`, not `g`: `gg` and `G`
  walk the list, and every key takes both cases. A split reads the unwritten pane text without saving it
  (that would run the marked-up input); the cases run once the case-count question settles.
- **The board lists what is on disk, as a load would.** A row added, restored, split off or
  renumbered goes into number order (`RunnerCore:sort_testcase_rows`).
- `u` (`restore_testcase`) restores the testcase deleted last, whatever was done since (a
  stack on the runner, newest first), and is named for that, as it is not Vim's undo of the
  last action. It and `restore_missing` write a testcase back through
  `RunnerCore:free_number`: its own number while that is free, else the lowest free one. `n`
  takes the lowest free number, the one just deleted included, and a restore over it would
  overwrite what was saved there since.

**Gates** (all menus, all ending in `keep editing`/`stop`, which is also what dismissal gives)
- `with_pending_settled(tcnum, what, proceed, after_save)`: re-running with unsaved edits asks
  `save and <what>` / `discard and <what>` / `keep editing`, `what` being `run` for a row that has
  not. A single row added and never saved (`fresh`) gets no Discard, having nothing behind it to
  act on. Saving runs what it saved, so `proceed` follows a save only with `after_save`, for an
  action wider than the rows saved (`<C-r>`, a run replacing the runner), whose save starts no
  run (`hold_run`) or those rows would run twice, or when no run can start (`preloaded`, a busy
  runner), where the save alone would do nothing it promised; `request_close` shares
  `unsaved_items`.
- `save_all_pending(done)` is every save but a plain `:w`: each row goes through
  `with_answer_settled` in turn, so an answer stored empty stays so and a real one left empty is
  asked about, and `done` (close, run, carry on quitting) follows the last. `keep editing` ends
  the chain there, which is why `:wq`, `:wqa` and `save and close` wait on it. The rows are
  saved held and run together (`run_rows`) after the last, or at a `keep editing`: a save runs
  its row only on an idle runner, so saved one at a time only the first would run.
- `commands.settle_runners(bufnr, { run, keep }, proceed)`, which every run and `show_ui` go
  through, keeps one runner UI per buffer and loses nothing on a mode switch: before a run it
  asks about an unwritten edit in any of the buffer's runners (interactive, stress and run-all
  replace the whole runner, `pending` with it) and stops every run of the buffer (a live session
  would wait on its input forever, stress rebuilds the binary the new run executes); every UI
  but `keep` is then hidden by `RunnerUI:delete`, which keeps `pending` on its runner.
  `runners_of`/`all_runners` (every live runner, what a resize redraws) search only loaded mode
  modules; the modes also stop the runner they replace, for callers bypassing `commands`.
- `with_answer_settled`: a save asks only when a **real answer would become empty**, through
  `widgets.ask_empty_answer`. It asks nothing about empty inputs, or about answers already absent
  or empty.
- `with_disk_settled` / `disk_drift` compare rows with disk in one read. It excludes `bare`
  rows, unsaved `n` rows and pending rows.
  - **Changed** on disk: reload silently via `sync_rows` and say so once.
  - **Added** on disk, a testcase with no row: on a re-run of the set (`<C-r>`), give it one,
    silently and said once, the file being the only copy. Not on a board of the testcases a
    run named (`runner.subset`: `:Tuna run 2 3`, run-all's and interactive's numbers), which
    leaves the others out on purpose.
  - **Missing**: ask `restore and re-run` / `discard` / `stop`. `restore_missing` writes back to
    the original number if it is free, else the lowest free number, renumbering the row,
    which then moves into number order.
  - Every branch renders, and the re-run finds rows by identity (`row_index`).

**Quitting and focus**
- `surface.quit_command` is what is read here, so a search spelling a quit and a line left with
  `<Esc>` are no commands. `!` discards an edit only on a command that does not write.
- `:q`/`:close`/`:wq`/`:x` in any pane are cancelled in `CmdlineLeave`, by setting
  `v:event.abort` **from Vimscript** (`vim.v.event` is a copy in Lua), and turned into
  `request_close`. `:q!` passes; `:qa`-style commands pass unless an edit would be lost, then
  ask and re-issue the quit. The zoom is exempt.
- `:wa` (`surface.write_all_command`), typed anywhere while the board shows, saves every row in
  `pending` through `save_all_pending`, not only the row the panes show, which is all Vim's own
  write reaches. It captures first, which clears the panes' flags, so the command itself writes
  only the user's files, natively, and the row on screen is saved once.
- Focus rescue: remember the one hop out of the UI (`escaped_from`/`escaped_to`); when that
  window closes, return to the pane, but only if focus landed on a window that existed before
  the close (`WinClosed` snapshots `nvim_list_wins()`), so a dialog it opened keeps focus.
  "Moved on to another window" is decided a tick later: `WinClosed`/`WinEnter` arrive in either
  order.

**Keys**
- **A pane typed into is a Vim buffer, a read-only pane the board's.** Actions (`run_again`
  r/R, `run_all_again` <C-r>, `stop` s/S, `stop_all` <C-s>, `toggle_diff`, `zoom_*`,
  add/delete/undo/split) are bound on **every read-only pane**, in both letter cases, with
  `surface.read_only`'s guards. Editable panes get only close, pane switching, `?` and the
  search's `n`/`N` guard (below). Add,
  delete, undo and split are bound in every mode and do nothing where testcases can't be
  edited; left unbound, `n`/`N` would fall through to Vim's search.
- The `si` and `eo` buffers are read-only on some rows (the build step's borrowed sources, any
  row `row_editable` refuses), so their keys **follow the buffer** (`follow_typed_panes`, after
  every details render, not as the board opens, when they are new and read-only only until the
  first render): the actions and guards while it is read-only, taken off once it can be typed
  into, last bound first, the key each one covered put back (`board_keys`). A pane the mode
  types into itself (`owns_pane`, live's Live column) is followed the same way in every mode,
  less the keys the mode binds there (`pane_keys`, the ones that start typing), so `n` starts a
  session on it while it is read-only and is a letter once it is typed into.
- **The board searches apart from the files around it** (`follow_search`, module-level, one
  search for every board): Vim's one last pattern and `hlsearch` are swapped for the board's on
  entering a pane or the zoom (`pane_owner`) and back on leaving, scheduled from `WinEnter`/
  `BufEnter`, as autocmds put `v:hlsearch` back when they end. An empty pattern is put unlit,
  and the editable panes' `n`/`N` do nothing with it: Vim would fall back on the last
  substitute pattern, the solution's. Everything else on the editable panes stays Vim's. The
  guard answers with Vim's own `n`, so a user's mapping of it (`nzzzv`, hlslens) does not reach
  those panes, a cost accepted for now: binding it only while the board has no search, and
  taking it off once one is made, would give the mapping back.
- `close` (`<Esc>`, `<C-c>`, `q`, `Q`) is bound on every pane in **normal mode only**.
  `switch_window_keys` (default `<C-hjkl>`, a top-level option shared with widgets) also work in
  insert mode and move from the cursor, as Vim's own window moves do (`focus_dir`): the pane
  level with the cursor in that direction, else the nearest, so right from the selector's first
  rows is Output; `st` is never a focus target. From insert mode typing carries on into a pane
  whose buffer is modifiable (Input to Expected Output) and stops in one that is not: the buffer
  decides, not `writable_pane`, since on the build step those panes hold a compiler's words, and
  it is the buffer the key leaves the cursor in, moved or not: the zoom of a pane the grid omits
  lands on the selector even with no pane that way.
- `RunnerUI:writable_pane` decides which panes are typed into. The legend (`?`, `show_help`) and
  messages render keys from the config.
- The `zoom_*` keys (`zoom_input`, `zoom_expected`, `zoom_stdout`, `zoom_stderr`, run-all's
  `zoom_verdicts`) zoom a pane
  (`zoom`, a large float over the grid showing its buffer) until a close key, `:q` or a pane key
  (`unzoom`). The zoom is its pane larger, so a pane key there moves as from the pane, its
  window given the zoom's cursor first (`focus_dir`); the zoom of a pane the grid omits moves
  from the selector, where `unzoom` lands. A zoom key does nothing in a zoom, nor unzooms: an
  editable pane's letters are text, and a key that acted in one zoom and typed in another would
  be learned wrong.
  The keys and, with `runner_ui.show_title_keys`, the titles (`titled_with_keys`) both read
  `zoom_opens(row)`, the pane each action zooms on the row, so the two cannot disagree. A key
  acts on the row selected, as every board key does. On a testcase row a key zooms the pane it
  names (`ZOOM_ACTIONS`). A pane holding something else
  on a row is named and keyed for it by the mode (`pane_titles(row)`, `zoom_actions(row)`): a
  run-all header's `so` lists its verdicts, `verdicts (p)`, as `o` would promise an output. A
  pane the row leaves out (`blank_panes`) zooms nothing. On the build step a key zooms the
  source whose role it stands for (`BUILD_ACTIONS`), the pane its program is about when a
  testcase runs: the solution by errors, the generator and the interactor by input (they write
  it), the bruteforce by the answer, the checker by output (it judges it). No run compiles two
  sources sharing a key (the generator and the interactor never meet), and a key with no such
  source zooms nothing. The build step takes no letters of its own, as nearly every free one is
  a motion a list needs (`gg`, `w`, `b`, `v`, `y`); `p` (paste, inert on a read-only pane) is
  the verdicts' key. Mapping by buffer would have `o` open a generator's compiler errors. With
  more than one source the legend spells the build row's keys out (`legend_build_row`), as
  there they do not mean what they say.

**Look**
- The Run pane shows no line numbers: it is a read-out of named rows, where a number says
  nothing. The selector and the detail panes have their own line-number options
  (`selector_show_nu`/`_rnu`, `show_nu`/`_rnu`), set by a branch (`layout.window_options`): an
  `and`/`or` would let the selector's `false` fall through to the panes' value.
- Writable panes wear `runner_ui.editable_border_highlight` (default `TunaEditable`, bold
  magenta, the one hue not used for verdicts) on border and title, the title in the derived
  `TunaEditableBorder`. `accented(name)` decides it, for the grid (`accent_editable_panes`) and
  for the zoom, which is the same pane larger. `accent_editable_panes` takes the accent off as
  well as on: a pane the re-tiling leaves open keeps its colour, and nothing on the build step
  is typed into.
- **Text wraps, data does not** (`text_panes`, set by `lay_out` and on the zoom): the Errors
  pane on a testcase row and every build step pane hold text to read and wrap at word
  boundaries, indent kept (`linebreak`, `breakindent`); Output, Expected Output and Input keep
  their lines whole, the diff pairing them line by line, an input's long line being data. It
  follows the row, as the build step borrows the detail buffers; a mode owning panes may reset
  them (`on_ui_shown`).
- The selector always shows its cursorline, the row selected; the other panes and the zoom
  follow the user's while focused (`surface.follow_cursorline`), both set in `lay_out`.
- The shipped layouts put `so`/`eo` on one row (the diff reads across) and `eo`/`si` in one
  right-hand column. A bordered float's `row`/`col` is its border cell and `width`/`height`
  exclude the border: centre on `size + 2` (`overlay_geometry`, `ui_bounds`).
- The zoom and message floats are sized by `runner_ui.zoom`, the legend to the UI's footprint.
  Every part of the legend is a titled box, stacked when they share a column, so no heading
  sits among its rows, where a lowercase one would read as one more row. Short of rows they
  are shared from the tallest down, and the pane keys go by position, as on the board.
  Nothing is zoomed unasked: a failed build is read on the build step, whose grid always has an
  Errors pane, and a zoom would cover it and take the row from someone who moved off.
- Diff view (`paint_diff`, namespace `tuna_runner_diff`) marks only what disagrees, and a cell
  put in (inline virtual text, keeping the panes level) where the output has less than the
  answer, which nothing else there would show. Not where the answer has less: the output marks
  that, and a cell on the line being typed sits at the cursor. A line the other side lacks is
  coloured whole, red as every other disagreement (`TunaDiffAdd` and `TunaDiffDelete` link to
  `TunaDiffText`): beside verdicts where green means correct, `DiffAdd` reads as right. A
  disagreeing line has no colour of
  its own: behind the agreeing tokens it hides which disagree, and beside a cursorline it reads
  as a second one. The compared panes are bound with `scrollbind`/`cursorbind` instead of filler
  lines, given the same top line first (line i faces line i), not `:syncbind`, after which Vim
  skips syncing the next scroll in a bound window. It is cached by texts and row (`diff_cache`)
  and follows unsaved pane text as you type (debounced). A row is diffed once it has `stdout`,
  not by a timestamp: a stress counterexample is written by the search rather than spawned, and
  gating on the spawn would leave exactly the rows worth comparing unmarked. An empty pane is
  compared only where the answer is stored empty (`tc.expected == ""`), so the marks follow the
  verdict there; no answer is not judged, and an answer cleared and unsaved is `:w`'s question.
- **The Output and Errors panes show the first `SHOWN` bytes** of what a program said (`shown_part`),
  cut at a line's end under a line saying how much is left out, as up to `maximum_output` may be
  kept and a pane of millions of lines makes every redraw, search and diff slow. Judging reads
  the whole. Input and Expected Output are never cut: they are the testcase's files, saved from
  their panes. The diff compares what the Output pane shows of the output and as many lines of
  the answer, no longer (`w.cut`), or every answer line past the cut would be marked as missing. Only `si` and `eo` keep a
  `baseline`, the one thing an edit is measured against.
- `mark_empty_answer` has a blank Expected Output pane say what it means
  (`testcases.empty_answer_words` through `surface.note_when_empty`), a blank pane alone not
  telling an answer stored empty from none. It runs on every render of the details and on every
  edit, so the words go as the first character is typed rather than with the debounce, and come
  back on an undo. A real answer cleared and unsaved says nothing, being `:w`'s question.
