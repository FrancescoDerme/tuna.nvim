# lua/tuna/runner_ui

The runner UI every run mode draws its rows on. The rules that hold everywhere are in the root
`CLAUDE.md`.

## Runner UI

**Structure**
- Panes: `st` (the "Run" status, carved from `tc`'s rectangle), `tc` (selector), and the
  detail panes, each named for the content it shows on a testcase row (competitest's
  vocabulary): `si` standard input, `so` standard output, `se` standard error, `eo` expected
  output. The UI creates the six buffers (adopted through `surface`, with `write_panes` as
  their `:w`) and an interface only places windows onto them: `relayout(windows, config,
  init_winid, status_rows, grid)` is its whole API. `popup.lua` tiles floats, moving the
  windows that stay, and `split.lua` opens native splits anew each time, both from the same
  recursive `{ ratio, child }` grid; levels alternate between columns and rows.
- **Six pane buffers, never more.** A board is these six and makes no other: a buffer
  nothing shows is a cost with nothing bought. The build step, which has no input, answer or
  output, borrows the four detail buffers for its sources (`BUILD_PANES`) instead of having
  its own, and keeps their names out of everything a user reads or writes on that row (see
  the grid and the zoom keys below).
- `M.owner_of(bufnr)` answers which runner a pane buffer belongs to, from the module-level
  `pane_owner` map filled in `show_ui` and cleared in `delete` (`commands.target_buffer`).
- `layout.resolve` validates a layout (known names, no duplicates, well-formed pairs, the names
  its kind requires) and falls back to the default with a WARN. The UI checks each grid once
  per board (`checked_grid`, by option name), so a re-tile never repeats the warning, and the
  interfaces are handed a grid already checked. Two kinds, two vocabularies that do not mix
  (`layout.kinds`): a testcase row's grid (`run`) places `tc` and the detail panes; the build
  step's (`build`) places `tc` and one `build` cell, and nothing else, since the detail panes'
  names would say stdout or stdin there. A pane the layout omits still gets a
  **buffer** (content kept, it can still be zoomed) but no window, so its `winid` is nil: every
  window call goes through `w.winid and api.nvim_win_is_valid(w.winid)`, never the second
  half alone. Which panes are omitted changes with the row on screen, so any pane can be
  windowless at any moment (the build step draws only its own sources).
- **The grid follows the row on screen.** `grid(row)` answers the build step with
  `runner_ui.compile_layout` (checked as a `build` grid) and every other row with the mode's
  `layout()` or the interface's configured one (`configured_grid`); `titles_for(row)` gives
  every pane's title on that row, which `lay_out` stores on the pane records before the
  interface places them. `build_assignment` gives each source of the build step one of the
  `BUILD_PANES` buffers, in order, and `stack_into` splits the grid's `build` cell into them,
  one above the other (one source takes the cell whole), so the answers that have to agree — the
  grid, the titles (`Errors: gen.cpp`, `build_titles`), what is drawn into each pane
  (`build_text`) and which key zooms it (`opens`) — all come from one placement. The placement
  joins no text, because the render tick asks for the grid on every render; the text is joined
  only where the panes are drawn. A pane is named after its source only when there is more than
  one, and the build step's panes are filled by the UI rather than by `pane_content`: a build is
  the same thing in every mode. There is no "keep the testcase grid" setting for the build row:
  that grid has no `build` cell, so it would bring back a detail pane's name meaning two things.
  The render tick compares it with `drawn_layout` and calls `redraw_grid`, which lays the grid
  out again (`lay_out`): the panes keep their buffers (content, keymaps, unwritten edits) and
  only their windows are moved, opened or closed, because rebuilding them would drop all of that
  and race the rows landing in them. A resize is the same call. Focus stays on the pane it was
  in, else the selector: the split interface closes the window you are in on every re-tile, and
  a pane the new grid leaves out loses its window. Titles are taken again on every re-tile,
  because the row on screen can rename a pane. What depends on the kind of row (wrapping, the
  accent, the zoom keys, `on_ui_shown`) reads `drawn_row`, the row laid out, never the
  selection: `show_ui` lays the grid out for the row it opens on a tick before it selects it,
  and nothing re-tiles then, the grid being the same. While it runs, `relayouting` marks the
  windows closing and opening as the UI's own, so neither `WinClosed` (which means the user
  closed the UI) nor a cursor event (which means a move by hand) is believed; it is cleared a
  tick later, when those events are delivered. `watch_pane_window` re-arms the per-window
  `WinClosed` after a relayout, and both interfaces skip a pane whose buffer was wiped from
  under the UI (`:%bwipeout`).
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
  The choice comes back to the UI in two places, both through `choose_row_again` (`user_moved`
  off, `opening` on): a run of the whole set that was *asked for* — `commands.run_testcases`
  and the UI's `run_all_again`, not the `built_first` paths a single row's re-run takes — so
  every run starts the way the first did; and `show_ui`, since what opening chooses is
  `last_row_id`, the row the user was on, kept on the runner.
- `opening_row()`: a run whose build has not finished opens on it (`building`), whatever was
  last looked at, so every run starts the same way; otherwise the runner's `last_row_id`
  (matched by `row_id`), else `initial_row()` — the first testcase, or Compile when it printed
  something. `building` is about the *run*, not the process (`not preloaded and
  exit_code == nil`): asking whether the compiler runs right now leaves a tick between the rows
  being built and the process being spawned, and a UI opened inside it would draw the panes of
  a run for a build about to start and redraw them a moment later. For the same reason the mode
  modules `mark_not_run` before `show_ui`, not after.
- `render_selector` lays the rows out in three columns (header, verdict, time) through
  `selector_columns`: 10 wide while the pane holds them, content-sized plus a space when it
  doesn't, and without the time rather than letting the pane cut a number in half. The
  conversation layout gives its selector a 4 share for that reason.
- `status_lines()`: mode, judge (the checker file, else the compare method), the mode's own
  settings (`status_settings`, interactive's source), forced, diff on/off, runner tail, `help:
  ?`. Its row count is fixed per runner. The `forced` row names the settings that are the
  user's choice (`mode`, `judge`, `source`), else `none`, rather than appending a word to each
  value, which the pane is too narrow to hold: `judge` counts as forced when the checker is off
  or the comparison is overridden, never when a checker was simply found.

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
- `commands.settle_runners(bufnr, { run, keep }, proceed)` is what every run and `show_ui` go
  through, so switching modes loses nothing and a buffer shows one runner UI at a time. Before
  a run it asks about an unwritten edit in any of the buffer's runners (interactive, stress and
  run-all replace the whole runner, `pending` with it), then stops every run of the buffer: a
  live session would wait on its input forever, and stress rebuilds the binary the new run
  executes. Every UI but `keep` is then hidden with `RunnerUI:delete`, which keeps `pending` on
  its runner. `runners_of` and `all_runners` (every live runner, what a resize redraws) only
  look in mode modules already loaded. The mode modules also stop the runner they replace, for
  callers that bypass `commands`.
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
  they ask and re-issue the quit. The zoom is exempt.
- Focus rescue: remember the one hop out of the UI (`escaped_from`/`escaped_to`). When that
  window closes, return to the pane, but only if focus landed on a window that existed before
  the close (`WinClosed` snapshots `nvim_list_wins()`), so a dialog opened by the close keeps
  focus. "Moved on to another window" is decided a tick later, because `WinClosed`/`WinEnter`
  arrive in either order.

**Keys**
- Actions (`run_again` r/R, `run_all_again` <C-r>, `stop` s/S, `stop_all` <C-s>,
  `toggle_diff`, `zoom_*`, add/delete/undo/split) are bound on **every read-only pane**, in
  both letter cases. Editable panes get only close, pane switching and `?`. Add, delete,
  undo and split are bound in every mode and do nothing where testcases can't be edited;
  left unbound, `n`/`N` would fall through to Vim's search.
- `close` (`<Esc>`, `<C-c>`, `q`, `Q`) is bound on every pane in **normal mode only**.
  `switch_window_keys` (default `<C-hjkl>`, a top-level option shared with widgets) also work
  in insert mode and move by window geometry; `st` is never a focus target.
- `RunnerUI:writable_pane` decides which panes are typed into. The legend (`?`, `show_help`)
  and messages render keys from the config.
- The `zoom_*` keys (`zoom_input`, `zoom_expected`, `zoom_stdout`, `zoom_stderr`) zoom a pane
  (`zoom`): a large float over the grid showing its buffer, until a close key, `:q` or a pane
  key (`unzoom`). A zoom key does nothing in a zoom, nor unzooms the pane it zoomed: an editable
  pane's letters are text, so its zoom cannot take them, and a key that acted in one zoom and
  typed in another would be learned wrong. They are bound from `ZOOM_ACTIONS`, pane to action,
  and `runner_ui.show_title_keys` (on by default) names them in the titles from the same maps
  (`titled_with_keys`), so the two cannot disagree. They zoom what the row actually holds,
  through `zoom_target`: on a testcase row the pane they name; on the build step the source
  whose role the key stands for (`BUILD_ACTIONS`), which is the pane that source's program is
  about when a testcase runs: the solution by errors, the generator and the interactor by input
  (they write it), the bruteforce by the answer, the checker by output (it judges it). No run
  compiles two sources that share a key (the generator and the interactor never meet), so every
  build pane has a key of its own, and a key with no such source in this run zooms nothing. No
  new letters: every free one is a motion a list needs (`gg`, `w`, `b`, `v`, `y`). The panes are
  the detail buffers underneath, so mapping the keys by buffer would have `o` open a generator's
  compiler errors. The legend spells the build row's keys out when it has more than one source
  (`legend_build_row`), since there they do not mean what they say.

**Look**
- The selector and the detail panes each have their line-number options
  (`selector_show_nu`/`_rnu`, `show_nu`/`_rnu`), set by a branch in both interfaces: an
  `and`/`or` would let the selector's `false` fall through to the panes' value.
- Writable panes wear `runner_ui.editable_border_highlight` (default `TunaEditable`, bold
  magenta, the one hue not used for verdicts) on border and title. The title uses the derived
  `TunaEditableBorder`. `accent_editable_panes` takes the accent off as well as putting it
  on, because a pane the re-tiling leaves open keeps the colour it had: nothing on the build
  step is typed into, whatever its panes are on a testcase row.
- **Text wraps, data does not** (`text_panes`, set by `lay_out` on every pane after the
  interface places it, and on the zoom for the pane it shows): the Errors pane on a testcase
  row and every pane on the build step hold text to read, compiler and sanitizer output, and
  wrap at word boundaries with their indent kept (`linebreak`, `breakindent`). Output,
  Expected Output and Input keep their lines whole: the diff pairs them line by line, and an
  input's long line is data. It follows the row, not the buffer, since the build step borrows
  the detail panes' buffers; a mode that owns panes may set them again (`on_ui_shown`).
- The shipped layouts put `so`/`eo` on one row (the diff reads across) and `eo`/`si` in one
  right-hand column.
- Float geometry: a bordered float's `row`/`col` is its border cell, and `width`/`height`
  exclude the border. Centre on `size + 2` (`overlay_geometry`, `ui_bounds`).
- The zoom and message floats are sized by `runner_ui.zoom`. The legend is sized to the
  UI's footprint. Nothing is zoomed unasked: a failed build is read on the build step, whose
  own grid always has an Errors pane, so zooming it would cover the same text and take the row
  away from someone who had moved off it.
- Diff view paints extmarks in the `tuna_runner_diff` namespace, with `scrollbind`/`cursorbind`
  instead of filler lines. It is cached by texts and row (`diff_cache`) and follows unsaved
  pane text as you type (debounced). A row nothing has answered on yet is not diffed, which is
  decided on the row having `stdout`, not on a timestamp: a stress counterexample is written by
  the search that found it rather than spawned like a testcase, and gating on the spawn would
  leave exactly the rows worth comparing unmarked.
