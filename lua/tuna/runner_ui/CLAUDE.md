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
- **Six pane buffers, never more**: a buffer nothing shows is a cost with nothing bought. The
  build step, which has no input, answer or output, borrows the four detail buffers for its
  sources (`BUILD_PANES`), keeping their names out of all a user reads or writes there.
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
  `layout()` or the interface's configured grid (`configured_grid`); `titles_for(row)` gives
  every pane's title there, stored on the pane records before the interface places them, taken
  again each re-tile, since the row can rename a pane. `build_assignment` gives each source of
  the build step one of the `BUILD_PANES` buffers in order, and `stack_into` splits the `build`
  cell into them, one above the other, so the grid, the titles (`Errors: gen.cpp`,
  `build_titles`, a pane named after its source only when there is more than one), the text
  (`build_text`) and the zoom keys (`opens`) all come from one placement. The placement joins no
  text, as the render tick asks for the grid each render. The UI fills the build step's panes,
  not `pane_content`: a build is the same in every mode. No "keep the testcase grid" setting for
  the build row: it has no `build` cell, and a detail pane's name would mean two things.
- The render tick compares the grid with `drawn_layout` and calls `redraw_grid`, which lays it
  out again (`lay_out`; a resize is the same call): the panes keep their buffers (content,
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
  `follow_row` is how the UI chooses, a no-op once the user has. Three things choose: `show_ui` takes `opening_row()` on its scheduled tick, *after* the rows
  exist (interactive and run-all build theirs after opening, so deciding earlier lands on line
  1); every render calls `follow_after_compile`, leaving a Compile row that ended with exit 0
  and printed nothing (a failed or talkative build is what answers the run, and one still
  running must not move under the user); and interactive's `run_one_session` follows the row it
  talks to (one session at a time, live's row the only typable one). While the choice is the
  UI's, cursor and selection must agree, or the editor's own cursor event reads as a move by
  hand: `show_ui` selects nothing, `selected_line` on 1, until the tick chooses. The choice
  returns to the UI through `choose_row_again` (`user_moved` off,
  `opening` on) on a run of the whole set that was *asked for* (`commands.run_testcases`, the
  UI's `run_all_again`, not a single row's `built_first`), so every run starts as the first did,
  and in `show_ui`, which reopens on `last_row_id`, kept on the runner.
- `opening_row()`: a run whose build has not finished opens on it (`building`), whatever was
  last looked at; otherwise `last_row_id` (matched by `row_id`), else `initial_row()`, the first
  testcase, or Compile when it printed something. `building` is about the *run*, not the process
  (`not preloaded and exit_code == nil`): between the rows being built and the compiler being
  spawned, a UI opened would otherwise draw the panes of a run and redraw them a tick later. For
  the same reason the modes `mark_not_run` before `show_ui`.
- `render_selector` lays rows out in three columns (header, verdict, time) through
  `selector_columns`: 10 wide while the pane holds them, content-sized plus a space when not,
  and without the time rather than cutting a number in half (the conversation layout's selector
  takes a 4 share).
- `status_lines()`: mode, judge (the checker file, else the compare method), the mode's settings
  (`status_settings`, interactive's source), diff on/off, runner tail, `help: ?`, rows fixed
  per runner. A setting that is the user's choice (`mode`, `judge`, `source`) has a `*` after
  its name, explained in the `?` legend: one column, where a word after the value is what the
  narrow pane cuts off first, and a row naming the forced settings repeated the rows above it
  and said `none` most of the time. `judge` is forced when the checker is off or the comparison
  overridden, never for a checker found.

**Inline editing**
- Editable panes are always-modifiable `acwrite` buffers. `:w` from **any** pane saves the row
  the panes show (`pane_tcnum`, the row last *rendered*, not the selected row); a write with no
  change does nothing. Unwritten edits live in `ui.pending[tcnum]`: they survive row switches
  and resizes, override `pane_content`, feed the diff, and the row reads `EDITED` (unstyled).
- `on_pane_edit` must stay O(1) in testcase size. It reads only Vim's `modified` flag (a change
  leaving it unset raises nothing: `TextChanged` also reports the UI's own filling of a pane the
  first time it is entered after) and re-renders the selector only when the edited set changes
  (`edited_sig`). Comparing with the stored text (`w.baseline`, `panes_changed`) happens only in
  `capture_pending` and the 120 ms debounce `schedule_settle`, so text typed back to its
  original stops counting. Pane `modified` flags are then cleared: a modified `acwrite` buffer
  blocks quitting with E37/E162.
- `capture_pending` runs before anything repoints the panes. `discard_pending` clears `pending`
  and the flags together.
- Keys with no text to author: `n` adds a row, `t` generates one, `x` deletes, `u` restores,
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

**Gates** (all menus, all ending in `Keep editing`/`Stop`, which is also what dismissal gives)
- `with_pending_settled(tcnum, what, proceed, after_save)`: re-running with unsaved edits asks
  `Save and <what>` / `Discard and <what>` / `Keep editing`. Saving re-runs what it saved, so
  `proceed` follows a save only with `after_save`; `request_close` shares `unsaved_items`.
- `commands.settle_runners(bufnr, { run, keep }, proceed)`, which every run and `show_ui` go
  through, keeps one runner UI per buffer and loses nothing on a mode switch: before a run it
  asks about an unwritten edit in any of the buffer's runners (interactive, stress and run-all
  replace the whole runner, `pending` with it) and stops every run of the buffer (a live session
  would wait on its input forever, stress rebuilds the binary the new run executes); every UI
  but `keep` is then hidden by `RunnerUI:delete`, which keeps `pending` on its runner.
  `runners_of`/`all_runners` (every live runner, what a resize redraws) search only loaded mode
  modules; the modes also stop the runner they replace, for callers bypassing `commands`.
- `with_answer_settled`: `:w` asks only when a **real answer would become empty**:
  `Don't specify output` / `Expect empty output` / `Keep editing`. It asks nothing about empty
  inputs, or about answers already absent or empty. The menu is opened with `vim.schedule`,
  because a float entered inside `BufWriteCmd` loses focus when the write finishes.
- `with_disk_settled` / `disk_drift` compare rows with disk in one read. It excludes `bare`
  rows, unsaved `n` rows and pending rows.
  - **Changed** on disk: reload silently via `sync_rows` and say so once.
  - **Added** on disk, a testcase with no row: on a re-run of the set (`<C-r>`), give it one,
    silently and said once, the file being the only copy. Not on a board of the testcases a
    run named (`runner.subset`: `:Tuna run 2 3`, run-all's and interactive's numbers), which
    leaves the others out on purpose.
  - **Missing**: ask `Restore and re-run` / `Discard` / `Stop`. `restore_missing` writes back to
    the original number if it is free, else the lowest free number, renumbering the row,
    which then moves into number order.
  - Every branch renders, and the re-run finds rows by identity (`row_index`).

**Quitting and focus**
- `:q`/`:close`/`:wq`/`:x` in any pane are cancelled in `CmdlineLeave`, by setting
  `v:event.abort` **from Vimscript** (`vim.v.event` is a copy in Lua), and turned into
  `request_close`. `:q!` passes; `:qa`-style commands pass unless an edit would be lost, then
  ask and re-issue the quit. The zoom is exempt.
- Focus rescue: remember the one hop out of the UI (`escaped_from`/`escaped_to`); when that
  window closes, return to the pane, but only if focus landed on a window that existed before
  the close (`WinClosed` snapshots `nvim_list_wins()`), so a dialog it opened keeps focus.
  "Moved on to another window" is decided a tick later: `WinClosed`/`WinEnter` arrive in either
  order.

**Keys**
- Actions (`run_again` r/R, `run_all_again` <C-r>, `stop` s/S, `stop_all` <C-s>, `toggle_diff`,
  `zoom_*`, add/delete/undo/split) are bound on **every read-only pane**, in both letter cases.
  Editable panes get only close, pane switching and `?`. Add, delete, undo and split are bound
  in every mode and do nothing where testcases can't be edited; left unbound, `n`/`N` would fall
  through to Vim's search.
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
- The `zoom_*` keys (`zoom_input`, `zoom_expected`, `zoom_stdout`, `zoom_stderr`) zoom a pane
  (`zoom`, a large float over the grid showing its buffer) until a close key, `:q` or a pane key
  (`unzoom`). The zoom is its pane larger, so a pane key there moves as from the pane, its
  window given the zoom's cursor first (`focus_dir`); the zoom of a pane the grid omits moves
  from the selector, where `unzoom` lands. A zoom key does nothing in a zoom, nor unzooms: an
  editable pane's letters are text, and a key that acted in one zoom and typed in another would
  be learned wrong.
  `ZOOM_ACTIONS` binds them and, with `runner_ui.show_title_keys`, names them in the titles
  (`titled_with_keys`), so the two cannot disagree. They zoom what the row holds
  (`zoom_target`): on a testcase row the pane they name, on the build step the source whose role
  the key stands for (`BUILD_ACTIONS`), the pane its program is about when a testcase runs: the
  solution by errors, the generator and the interactor by input (they write it), the bruteforce
  by the answer, the checker by output (it judges it). No run compiles two sources sharing a key
  (the generator and the interactor never meet), and a key with no such source zooms nothing. No
  new letters: every free one is a motion a list needs (`gg`, `w`, `b`, `v`, `y`). Mapping by
  buffer would have `o` open a generator's compiler errors. With more than one source the legend
  spells the build row's keys out (`legend_build_row`), as there they do not mean what they say.

**Look**
- The selector and the detail panes have their own line-number options
  (`selector_show_nu`/`_rnu`, `show_nu`/`_rnu`), set by a branch in both interfaces: an
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
  Nothing is zoomed unasked: a failed build is read on the build step, whose grid always has an
  Errors pane, and a zoom would cover it and take the row from someone who moved off.
- Diff view (`paint_diff`, namespace `tuna_runner_diff`) marks only what disagrees, and a cell
  put in (inline virtual text, keeping the panes level) where the other side has something this
  one lacks; a line the other side lacks is coloured whole. A disagreeing line has no colour of
  its own: behind the agreeing tokens it hides which disagree, and beside a cursorline it reads
  as a second one. The compared panes are bound with `scrollbind`/`cursorbind` instead of filler
  lines, given the same top line first (line i faces line i), not `:syncbind`, after which Vim
  skips syncing the next scroll in a bound window. It is cached by texts and row (`diff_cache`)
  and follows unsaved pane text as you type (debounced). A row is diffed once it has `stdout`,
  not by a timestamp: a stress counterexample is written by the search rather than spawned, and
  gating on the spawn would leave exactly the rows worth comparing unmarked.
