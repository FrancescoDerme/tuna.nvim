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
  claims them, in Normal and Visual mode alike. Call it **after** binding real keys; claims are
  compared on terminal codes (`<C-R>` equals `<C-r>`). `selectable` leaves Visual mode open on
  what is worth pasting somewhere (the library's code, a source previewed, a runner UI pane
  showing a testcase or a tool's output), where only `SELECTING` keeps its meaning. Everything
  else starts no selection: a list, a line read at a glance (the library's notes and
  complexity, the Run pane, a message, the key legend).
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
  focused, whenever one takes focus and whenever the mode changes in one (`bar_follows`, its
  `WinEnter` and `ModeChanged` made with the first float), so the bar is right the moment it
  shows. lualine's own refresh on those events means to redraw the current window but names
  the option `kind`, not `scope`, so it redraws the tab's windows, which leave out floats: a
  float's bar would otherwise wait for lualine's timer. Operator-pending and Visual mode still
  read `NORMAL` in a float. Operator-pending sets the `statusline` of the float, and of the
  window under it when refreshed by tab, but the bar does not repaint: `:redrawstatus`, with
  `!`, `:redraw!`, `nvim__redraw`, each scheduled or run through `nvim_win_call` from the
  window under it, were tried, none shows it reliably, and some leave a stale mode on the bar.
  Visual mode is lost earlier: lualine reads the mode inside `nvim_win_call` of the file
  window, where Neovim reports Normal for another buffer. With any other `laststatus` a float
  keeps the empty one `style = "minimal"` gives it, because from Neovim 0.12 a float with a
  `statusline` of its own draws it inside its border, showing the pane's `tuna://` name.
- `group(wins, on_close)`: windows that close together, keyed on `WinClosed`.
- `edit(path)`: how tuna opens a file (`:Tuna next`, `:Tuna go`, starters, the scratch,
  downloads). From a runner UI pane or zoom, whose windows are pinned to their buffers (a file
  would land in a float, or the split interface's `winfixbuf` refuse it), the board is put away
  first (`runner_ui.step_out`, which keeps unwritten edits on its runner as a run's hiding
  does), landing in the window it was opened over. The runner UI is consulted only when loaded.
  A caller that also changes directory does so after it, so an `lcd` lands on the window showing
  the file, not on a pane put away.
- `adopt` sets the `tuna` filetype with `Syntax` ignored: searching the runtimepath for a syntax
  file nobody wrote, on every float, is a large part of what a menu of panes takes to open. A
  pane's colours come from `'syntax'`, set by `fill_preview`, which clears them for content with
  no language.
- **Virtual text lies over what is under it** (`hl_mode = "combine"`), wherever tuna draws it
  (a blank pane's note, `note_when_empty`; the form's label; the diff's cell; the library's
  number): its own colour on the line's, so a cursorline runs beneath it, where the default would
  paint its cells alone and stop the cursorline where it ends. The conformance check holds every
  float's to it.
- `no_completion(buf)`: a buffer typed into as a prompt (the search pane, `input`, the form's
  custom row) keeps completion plugins out: blink.cmp's `vim.b.completion = false`, and
  nvim-cmp's `setup.buffer({ enabled = false })`, given when nvim-cmp is loaded, which a lazily
  loaded one is on the prompt's own `InsertEnter`, so the prompt waits for that rather than
  loading it. The runner UI's panes and the testcase editor hold data and are left alone.
- `follow_cursorline(win)`: a reading pane (a preview, a runner UI detail pane or zoom, the
  testcase editor's panes) has the user's `cursorline` only while it is the current window,
  where it marks where they read; a list keeps its line always, since it marks the selection.
  A `panels` list follows too, passing `ignore_user`, as only the current one acts: it has the
  line while current whatever the user's value, and none otherwise. A `form` keeps one in every
  list, since `<CR>` submits each one's selection.
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
  `save and close` / `discard and close` / `keep editing` (also what dismissal gives) only
  when something would be lost. A `<C-s>` there would mean the opposite of the runner
  UI's `stop_all`. A resize rebuilds both panes in the pane, cursor and mode the user was in;
  `skip_close` keeps the panes' `WinClosed` from running the real close (which leaves insert
  mode) while they are replaced. A blank Output pane says what it means, as the runner UI's
  does (`opts.answer_words`, through `surface.note_when_empty`). `opts.settle` stands between a
  save and its callback: `commands.edit_testcase` leaves an answer stored empty or absent as it
  was, and asks about a real one left empty.
- `ask_empty_answer` is that question, here since the runner UI and the editor both ask it:
  `don't specify output` / `expect empty output` / `keep editing`. It opens with `vim.schedule`,
  as a float entered inside `BufWriteCmd` loses focus when the write finishes.
- A save can ask, so a typed `:wq`, `:x` or `:wqa` in the editor is held in `CmdlineLeave`
  (`surface.quit_command`, as in the runner UI), and `ZZ` is mapped, or Vim would close the panes
  before the answer and leave `keep editing` nothing to keep. A `:wq` from a script cannot be
  held: the panes close, and the answer still lands, which `save` guards for.
- `menu`: optional `on_close`; `preview` (fixed lines or cursor-following `content(idx)`, colour
  via `'syntax'` not `'filetype'`, list capped at `MENU_LIST_SHARE` of the height, read-only and
  never left modified, `selectable` for one worth pasting from, byte-range `highlights` drawn in
  `tuna_preview`, a missing title clearing the one before it, and set only then, as a float
  without a border takes no title), or several `panes` stacked,
  `content` then answering one table each: a
  `fit` pane is as tall as the tallest content any item gives it, at most a third of the room,
  and not drawn when none gives it any. It asks every item, as `content(idx, pane)`, so a caller
  whose other panes cost a read answers that pane alone. `beside` puts them right of the search and the list, the
  whole at a given size centred as the runner UI's grid, and there the pane keys move by
  position, up and down a column and across to the pane level with most of the one left, so the
  list leads to the code and the search pane to the notes. A `readout` pane (the library's
  complexity) is passed over in both layouts, as the runner UI passes over its Run pane, and the
  pane keys still lead out of it; `notice` pane above the menu, outside the focus cycle; `row`
  to start the cursor on (a resize keeps the row it is on); `tags`, dimmed text by the item's index,
  virtual text so a row's text stays its label, drawn again whenever the list is, so a tag goes
  with its item, and counted in the list's width. It follows its label, past the line's end;
  where the two do not fit it stays at the window's edge, over the label, whose last cells take
  `TunaFade1` and on (`init.setup_fades`, the float's text mixed into its background, read as
  a label fades since a float's colours may change with no event, and set only on a change,
  as setting a group redraws every window): cut off with the label, the tag
  would be gone where it is needed, and always at the edge it would sit apart from a short
  label. The cells at the edge depend on how far the list is scrolled, so `WinScrolled` draws
  them again, when it was sideways;
  `search(query)`, a one-row pane
  above the list, opened focused and typing, whose text the list is narrowed to (`shown`,
  indices into `items`, which `on_choice` and `content` still get). The list keeps the height of
  the whole, so it does not resize as it narrows. The change events (`TextChangedI`) are not the
  only reader: `refilter` runs again before `<CR>` or a list key reads the list, and a resize
  reads the pane itself, since keys arriving together (`fen<CR>`) run before the event is
  delivered. While typing, only the list keys that type nothing (`<Down>`/`<Up>`) move the list,
  so `j` and `k` can be searched for; the pane keys walk search, list and preview, and arriving
  back in the search pane types again only if it was left typing (`inserting`). Closing any of
  its panes by hand closes the whole menu, as closing the list does. A resize keeps the search,
  the pane focused and whether it was typing. With a search `items` may start empty, for
  `menu_items(id, items)` to fill by the `id` `menu` returned (a later opening's list is left
  alone), narrowed by what was typed meanwhile, and none closing it (it says whether it did). It
  builds the windows again, as list heights and `fit` panes follow the items, keeping where in
  the search line the cursor was (`search_col`), or text typed mid-line would jump to its end. A
  search's every change asks the preview again, the same item's too, for content that follows
  the query, and refills only a pane whose content changed (`drawn`), so one scrolled stays
  where it was. The pane keys catch the search up first (`refilter`), which may rebuild the
  windows and close the one they were headed for. `beside.list_width` keeps
  the list's width from following rows that are not there yet. `search_title` names the search
  pane. `lists` puts the items in several lists stacked under one search (`find`'s problems over
  contests), each item in list `of(idx)`. A list's height follows the items it holds, not those
  shown, so none resizes as a search narrows it: they share the rows smallest first, and one
  holding none is not drawn. A list takes three rows at least, its borders and one item: a stack
  too short for all of them leaves out the lowest first, the selection's last, and a search
  finding first what a list left out, or a search emptied while the top list is out, builds
  the windows again with it. The selection is in one list at a time (`at`), the only one with a
  cursorline, which `<CR>` picks from and the preview shows: nothing typed puts it on the top
  list, a search in the list holding what it found first, and a list entered from another list
  by the pane keys, or by the mouse, takes it. The list keys move within the selection's list
  and go round at its ends, as every list does (`move_cursor`): another list is reached with
  the pane keys, as any other pane is. The pane keys arriving from the search pane or a preview
  go to the list holding the selection, which that pane was acting on or showing.
- `after_insert(fn)` runs `fn` once insert mode is left, on the tick after (`ModeChanged`
  `i*:*`), or now outside it: a typing float closed by code leaves insert mode only once the code
  returns, leaving it clears the command line after the event, and a notice given before is
  gone before it can be read. Headless Neovim draws no screen, so a real terminal shows it.
- `panels`: lists in columns where `<CR>` acts on the focused list only (the `:Tuna` menu).
  `form`: stacked lists where `<CR>` submits every selection (clean). A `panels` section may
  carry `highlights`, byte-range spans drawn as extmarks in `tuna_panels`. They differ in what
  `<CR>` means, so they stay separate. `panels` has an optional borderless header dropped
  when space is short, lists sized to their own content, and explicitly unmodifiable
  buffers. A section's
  `column` stacks it with others: a column is as wide as its widest list, its lists share the
  band's rows smallest first (a list given fewer rows than items scrolls, with the user's
  scrolloff), and `switch_window_keys` move by position (`neighbour`: within the stack, or to
  the list level with this one in the next column). A `hint` section is one centred row in a
  stack, read and not walked to: the pane keys go by `walkable`, the stacks without hints.
  `keys` are the whole board's: each closes it and runs its function.
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
  opening one over an open instance dismisses that one (`replace`: its windows closed and
  its `on_close` run, so a caller that must continue is never left waiting; the editor has
  no `on_close`, its windows are closed), and buffers use `bufhidden = wipe`.
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
