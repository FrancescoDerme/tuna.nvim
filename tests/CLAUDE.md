# tests

The test suite. The rules that hold everywhere are in the root `CLAUDE.md`.

## Testing

- Run `tests/run.sh` (all files, one headless nvim each, side by side, non-zero exit on
  failure) or `tests/run.sh runner`. Keep it passing: it ships with the plugin. While a change
  is being made, run the files covering it; run the whole suite once the batch is done. Files
  run at the same time, so a file shares nothing on disk with another (`t.tempdir()` is per
  process). Each file gets a throwaway `XDG_STATE_HOME` (tests open problems, which tuna
  records into `recent.json` on exit) and the plugin on the runtimepath by absolute path (a
  test may change directory), with `plugin/tuna.lua` sourced by hand, since `-u NONE` sources
  no plugin files. Each file prints `N checks, M failures` through `tests/harness.lua`
  (`ok`/`eq`/`has`/`report`, and `drain`).
- Files, by the area each covers. Every check is a sentence saying the rule it holds, so
  whether a rule is tested, and where, is a `grep` over `tests/` away; this list only says
  which file an area belongs to.
  - `surfaces.lua`: every surface against the `surface.lua` contract (name, filetype, writes,
    read-only keys, layers, titles, statuslines, footers, virtual text), and the widgets:
    `menu` (preview, panes beside it, search, several lists), `input`, `form`, the testcase
    editor, the key legend, and one widget opened over another.
  - `menu.lua`: the `:Tuna` menu (statuses, `recent_layout`, the banner, the Pinned list, the
    hint, which command rows apply) and `panels`.
  - `recent.lua`: the histories, contest inference, `ignored_directories`, the state file,
    pins and `:Tuna pin`.
  - `library.lua`: listing, guards and the marker, notes and complexity, the picker (ranking,
    panes, size, a menu's `tags`), insertion and its indentation.
  - `modes.lua`: the helper and run-setting rule end to end (availability, automatic choices,
    forcing, sidecar entries, where a helper runs), `:Tuna checker` and `:Tuna compare`, the
    runner cache against `.tuna.lua`, numbers on stress and run-all, starters offered on a
    rerun.
  - `scaffold.lua`: the starters, every shape of `scaffold.templates`, rendering, a new
    solution, languages, `create_missing`, completion.
  - `scratch.lua`: template choices, resume and restart, absorbing, `download sync`'s message.
  - `navigate.lua`: next and previous problem in both layouts, the directory following,
    `next scaffold`, completion, cursor placement.
  - `search.lua`: `:Tuna find`: the walk, what a sidecar lists, tags, the panes, `rank`, what
    it says.
  - `download.lua`: the listener's boundary, what is stored, `sync`, the queue.
  - `startup.lua`: what a session that never uses tuna loads, and that tuna works without
    `setup()`.
  - `testcases.lua`: the split, the three backends, empty against absent, the testcase
    editor's saves, conversion, sharing a folder's testcases, auto-detected storage.
  - `compare.lua`: the compare methods, diff marks, what a checker's verdict may be.
  - `judges.lua`: the judge parsers.
  - `clean.lua`: similarity and classification, pinned files, builds, directories, languages,
    the prompts.
  - `submit.lua`: redaction, failure reasons, verdict scanning, the watch, restoring and
    hiding a verdict, the problem a file is a solution of, `:Tuna go judge`.
  - `runner.lua`: all four run modes with `vim.system` and `uv.spawn` stubbed, on real UI
    windows, in both interfaces where the grid changes: rows, builds and their reuse, stops,
    the stress search, interactive sessions and the conversation, run-all, and the board
    (editing, the gates, the selection, the diff, the zoom, footers, generated testcases).
    The output limit runs real processes (`exec yes`).
- Modules expose file-local helpers to tests through `M._test`, and `tools` a way to forget
  the session's builds, for a test whose stubbed compiler answers differently for a source that
  has not changed. They are not public interface.
- **Wait on a condition, never a clock**: `vim.wait(ms, cond)` returns as soon as `cond`
  holds, while a wait that times out costs its whole `ms` and still lets the test go on, so
  no test sleeps. `t.drain(busy?)` runs ticks until what was scheduled has run, chains of
  callbacks included, and `busy` (a timer the caller knows of) is false: what a sleep "to let
  the render land" was for. In `runner.lua`, `drain(ui)` adds the board's own pending work
  (a render, a re-tiling, the settle pass), and `settled(runner)` waits for the run to be over
  (idle, no row running or being judged), never for words on the rows, which a run can
  legitimately leave blank or `not run`. A test that something does *not* happen relies on
  these to have waited long enough, so mutation-check it.
- **Mutation-check new tests**: break the rule each test describes and confirm it fails, and
  confirm a harmless edit doesn't.
- The suite runs few real processes (the output limit, a watched submit), no verdict coming
  back from a judge, and little UI interaction. Verify those with headless scripts against
  real processes, kept in the session scratchpad.
