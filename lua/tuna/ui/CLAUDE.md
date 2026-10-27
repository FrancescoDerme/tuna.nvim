# lua/tuna/ui

What every float and scratch buffer is built on: the surface contract and the widgets. The
rules that hold everywhere are in the root `CLAUDE.md`.

## Widgets and surfaces

**`surface.lua`** is the contract every scratch buffer/window follows. Each rule prevents a
specific Vim error about a buffer the user never opened.
- `adopt(buf, kind, opts)`: name `tuna://<kind>/<bufnr>/tuna` (constant last component for
  statuslines, set by `adopt` itself), `filetype=tuna` (what statuslines key on to keep
  describing the file underneath, e.g. lualine's `ignore_focus`), `buftype=acwrite` with a
  write handler (`nofile` gives E382 and never fires `BufWriteCmd`), `keep_clean` for prompts
  (watches `TextChanged*` and `on_lines`).
  Adopt a buffer **before** its window opens: entering fires `BufEnter`, and plugins that
  skip tuna's windows by filetype read it right then (lualine's `ignore_focus` would otherwise
  describe the float instead of the file underneath).
- `read_only(buf)`: unmodifiable, and `CHANGE_KEYS` mapped to `<Nop>` wherever nothing else
  claims them. Call it **after** binding real keys; claims are compared on terminal codes
  (`<C-R>` equals `<C-r>`).
- `render(buf, content, opts)`: no write when unchanged, `undolevels = -1` around the write,
  `modified` cleared.
- `float(buf, opts)` with `LAYER`: grid 50, zoom 60, overlay 70, dialog 80. Neovim's default is
  50, so always set a layer. Every title is centred (`title_pos`), one given after the window
  opens too (`fill_preview`), where Neovim would put it on the left; the conformance check holds
  every float to it. With `laststatus=3`, and only then, a float starts with the `statusline` of
  the window it opens over: a new window otherwise takes the global value, which a statusline
  plugin may leave blank until its next refresh, so the one bar would flicker whenever a float
  takes focus. lualine is the exception: it draws the bar from a queue of refreshes served on a
  timer, so a copy shows a moment past (the COMMAND of the `:Tuna` that opened the float) and a
  float taking focus shows the bar it holds until the queue is served. With lualine loaded
  nothing is copied, and lualine is told to refresh with `force = true` as a float opens
  focused and whenever one takes focus (`bar_follows`, its `WinEnter` made with the first
  float), so the bar is right the moment it shows. With any other `laststatus` a float keeps
  the empty one `style = "minimal"` gives it, because from Neovim 0.12 a float with a
  `statusline` of its own draws it inside its border, showing the pane's `tuna://` name.
- `group(wins, on_close)`: windows that close together, keyed on `WinClosed`.
- `edit(path)`: how tuna opens a file (`:Tuna next`, `:Tuna go`, starters, the scratch,
  downloads). From a runner UI pane or zoom, whose windows are pinned to their buffers (a file
  would land in a float, or the split interface's `winfixbuf` refuse it), the board is put away
  first (`runner_ui.step_out`, which keeps unwritten edits on its runner as a run's hiding
  does), landing in the window it was opened over. The runner UI is consulted only when loaded.
  A caller that also changes directory does so after it, so an `lcd` lands on the window showing
  the file, not on a pane put away.
- `no_completion(buf)`: a buffer typed into as a prompt (the search pane, `input`, the form's
  custom row) keeps completion plugins out: blink.cmp's `vim.b.completion = false`, and
  nvim-cmp's `setup.buffer({ enabled = false })`, given when nvim-cmp is loaded, which a lazily
  loaded one is on the prompt's own `InsertEnter`, so the prompt waits for that rather than
  loading it. The runner UI's panes and the testcase editor hold data and are left alone.
- `follow_cursorline(win)`: a reading pane (a preview, a runner UI detail pane or zoom, the
  testcase editor's panes) has the user's `cursorline` only while it is the current window,
  where it marks where they read; a list keeps its line always, since it marks the selection.
  One `WinEnter`/`WinLeave` pair serves every followed window. The user's value is read from the
  option's global scope, so tuna sets `cursorline` with local scope only, never through
  `vim.wo`, which would also write the global value of the window it is set in and carry it into
  windows split from it.
- **Footers** (`follow_overflow`, private: `float` runs it for every float tuna opens, so no
  caller opts in): a float has no scrollbar, so a pane cut off would read as complete; its
  footer counts the lines out of sight (`↑ n` above the first on show, `↓ n` below the last,
  on the right, nothing when all of it shows), above as well as below because the interactive
  columns follow their latest line. The buffer is watched with `nvim_buf_attach` (`on_lines`), which sees
  every change whoever makes it (a `render`, interactive's own column writer, a preview
  following the cursor, a list narrowed by a search, typing), where hooking each writer would
  miss the next one written; the refresh is scheduled, since `on_lines` runs inside the change,
  and a buffer no followed float shows is let go. `WinScrolled` covers scrolling and resizing,
  refreshing every followed float rather than those `v:event` names, a handful of comparisons.
  A headless editor has no UI and raises no `WinScrolled`, so a test raises it itself. The
  footer is compared with the window's own, since re-tiling the grid configures every float
  anew, and wears the border's colour (`set_border_highlight` maps `FloatFooter` with
  `FloatBorder`), the editable panes' accent included. A window that is not a float (the split
  interface) is left alone.

**`widgets.lua`**
- **Dismissal** is bound only through `map_cancel`, from `config.cancel_keys`
  `{ normal = { "<Esc>", "<C-c>" }, insert = {} }`: Esc cancels from normal mode and only
  leaves insert mode. Per-widget keys extend the lists. `<C-c>` in insert mode can't be mapped.
- `input(title, default, on_submit, on_close)` opens in **normal** mode, because chained
  prompts can't reliably start in insert. Like every widget it takes its border from the
  config; a caller that may skip the question (download's `prompt_*` options) decides that
  itself (`ask` in `download.lua`).
- `editor`: its two panes are moved between with `switch_window_keys` (left to Input, right
  to Output, in insert mode too), like every other UI with panes: there is no
  editor-only pane key, so one setting moves focus everywhere. It saves and closes the way
  the runner UI does, with no keys of its own for it: `:w` saves (`BufWriteCmd`), `:wq`
  and `:x` save and close, and `q` or `cancel_keys` go through `request_close`, which
  compares the panes with what was last saved (`editor.saved`) and asks
  `Save and close` / `Discard and close` / `Keep editing` (also what dismissal gives) only
  when something would be lost. A `<C-s>` there would mean the opposite of the runner
  UI's `stop_all`. A resize rebuilds both panes in the pane, cursor and mode the user was in;
  `skip_close` keeps the panes' `WinClosed` from running the real close (which leaves insert
  mode) while they are replaced.
- `menu`: optional `on_close`; `preview` (fixed lines or cursor-following `content(idx)`, colour
  via `'syntax'` not `'filetype'`, list capped at `MENU_LIST_SHARE` of the height, read-only and
  never left modified), or several `panes` stacked, `content` then answering one table each: a
  `fit` pane is as tall as the tallest content any item gives it, at most a third of the room,
  and not drawn when none gives it any. `beside` puts them right of the search and the list, the
  whole at a given size centred as the runner UI's grid, and there the pane keys move by
  position, up and down a column and across to the pane level with most of the one left, so the
  list leads to the code and the search pane to the notes. A `readout` pane (the library's
  complexity) is passed over in both layouts, as the runner UI passes over its Run pane, and the
  pane keys still lead out of it; `notice` pane above the menu, outside the focus cycle; `row`
  to start the cursor on (a resize keeps the row it is on); `search(query)`, a one-row pane
  above the list, opened focused and typing, whose text the list is narrowed to (`shown`,
  indices into `items`, which `on_choice` and `content` still get). The list keeps the height of
  the whole, so it does not resize as it narrows. The change events (`TextChangedI`) are not the
  only reader: `refilter` runs again before `<CR>` or a list key reads the list, and a resize
  reads the pane itself, since keys arriving together (`fen<CR>`) run before the event is
  delivered. While typing, only the list keys that type nothing (`<Down>`/`<Up>`) move the list,
  so `j` and `k` can be searched for; the pane keys walk search, list and preview, and arriving
  back in the search pane types again only if it was left typing (`inserting`), as an editable
  runner UI pane keeps the mode it was left in. Closing any of its panes by hand closes the
  whole menu, as closing the list does. A resize keeps the search, the pane focused and whether
  it was typing.
- `panels`: lists in columns where `<CR>` acts on the focused list only (the `:Tuna` menu).
  `form`: stacked lists where `<CR>` submits every selection (clean). A `panels` section may
  carry `highlights`, byte-range spans drawn as extmarks in `tuna_panels`. They differ in what
  `<CR>` means, so they stay separate. `panels` has an optional borderless header dropped
  when space is short, lists sized to their own content, and explicitly unmodifiable
  buffers. A section's
  `column` stacks it with others: a column is as wide as its widest list, its lists share the
  band's rows smallest first (a list given fewer rows than items scrolls, with the user's
  scrolloff), and `switch_window_keys` move by position (`neighbour`: within the stack, or to
  the list level with this one in the next column).
  A section's `format(width)` lays it out for a content width (nil: its natural one) in place
  of `items`, again on every build and resize. When the board is too wide, a column made
  only of such sections gives up width first, down to `FIT_MIN`, before the whole board
  scales, so those lists shorten what they show while other lists stay whole.
- `form` custom rows are edited in place, with an inline virtual-text label (left gravity).
  `expr` maps allow editing only on that row, `guard_section` (`on_lines`) repairs other
  changes, and `validate` errors keep the form open.
- Geometry: everything sits inside `utils.float_band()` (one-row margin top and bottom).
  Stacked panes touch (`PANE_STEP = 2`), and heights are allotted notice → list → preview.
  Widgets use zindex 80.
- **Sizes come in two kinds.** A board, something worked in (the runner UI, the library, the
  testcase editor, the zoom), is a share of the editor with an option, `width`/`height` for
  the whole of it, borders included, the editor's two panes together. A question fits its
  content and has no option. A menu whose preview varies, from row to row or question to
  question (the scratch's templates, `clean`'s files), pins one width for all of it
  (`sequence_width`: the widest of its names and its previews' titles and lines, between half
  and seven tenths of the editor), or it would resize at every step. `input` is half the
  editor, room for a path, whatever its title.
- Widgets are module singletons: `resize_widgets()` rebuilds them (with a `skip_close` guard),
  opening one over an existing instance closes the old windows, and buffers use
  `bufhidden = wipe`.
- `open_float` sets what every widget float needs: `cursorline` with local scope (so the global
  value never leaks), `wrap`, `keep_scrolloff`. `step_keys` turns `switch_window_keys` into the
  next/previous keys of stacked panes (the form's sections; a menu's stacked panes walk the same
  way). **Panes move only with `switch_window_keys`, lists only with
  `picker_ui.mappings.focus_next`/`focus_prev`, and Tab means nothing**, in every widget and in
  the runner UI alike: one setting per kind of move. Every list moves through
  `widgets.move_cursor` (a count steps that many, the ends wrap), the menus, the form's
  sections, the `:Tuna` menu's lists and the runner UI's selector (bound on `tc` only, so
  `j`/`k` in a detail pane still scroll it). `close` adds to `cancel_keys` rather than repeating
  them.
