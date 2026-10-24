# tests

The test suite. The rules that hold everywhere are in the root `CLAUDE.md`.

## Testing

- Run `tests/run.sh` (all files, one headless nvim each, non-zero exit on failure) or
  `tests/run.sh runner`. Keep it passing: it ships with the plugin. Each file gets a throwaway
  `XDG_STATE_HOME` (tests open problems, which tuna records into `recent.json` on exit) and
  the plugin on the runtimepath by absolute path (a test may change directory), with
  `plugin/tuna.lua` sourced by hand, since `-u NONE` sources no plugin files. Each file prints
  `N checks, M failures` through `tests/harness.lua` (`ok`/`eq`/`has`/`report`).
- Files:
  - `surfaces.lua`: conformance of every surface to the `surface.lua` contract, every float
    tagged before it is entered and its title centred, no float drawing a statusline of its own
    unless the statusline is global (read off the screen), every `runner_ui.mappings` key still
    resolving to an action, a menu's starting row and preview, a menu's search (opened typing,
    narrowing the list before `<CR>` reads it, `j` typed and `<Down>` moving, the pane walk,
    typing again only where it was left typing, completion turned off in it and in `input`,
    nvim-cmp told whether loaded already or loading on the prompt's `InsertEnter`, a resize
    keeping the search, nothing found choosing nothing), a menu's panes beside its list (the
    size given, centred as the runner UI's grid, a fitted pane's height and its absence when
    nothing fills it, the pane keys moving by position, a resize keeping focus in a pane,
    closing one pane, or a notice, closing the menu, a readout pane passed over up, down and
    across and left by the pane keys, the user's cursorline on the list always and on a pane
    only while it is read), and the editor rebuilt by a resize in the pane, cursor and insert
    mode it was in, and saving with `:w`/`:wq` and asking before an unsaved edit is closed away;
  - `menu.lua`: the contest summary over both layouts, counting current judge verdicts only, a
    problem's judge verdict beating its local one and either lapsing with an edit, which rows a
    local verdict counts, statuses in the runner UI's words and colours with counts uncoloured
    and stacked in a column of their own while every verdict ends on one edge, counted or not,
    names giving way to a narrow width (a contest's judge first), and `panels` stacking,
    scrolling, moving focus and squeezing a `format` column before the others, the real menu's
    titles and free-standing banner, and its Pinned list (every pin, scrolling within the
    editor, under the other two) with the pin/unpin command;
  - `recent.lua`: both histories (default and configured sizes, move to top, a problem
    bringing its contest back, contests named by the judge and contest recorded with them,
    dropping deleted directories, reading the state file back, opening any entry, what is
    written, nothing under `ignored_directories` remembered, at any depth, through `~`, as a
    contest or on entering it, while a directory merely sharing its name as a prefix is, and
    what was remembered there before forgotten by `:Tuna last problem`, `last contest` and the
    menu each) and the pins (most recent first, uncapped, toggling, a deleted solution
    unpinned, `:Tuna pin` refusing a non-solution and pinning a helper's solution);
  - `library.lua`: the files listed for a language (no dotfiles at any depth, `~` in
    `library.path`), guarded snippets, what the picker lists and how a search orders it (names
    and files fuzzily in either case and word order, then code however it is spaced), an
    unclosed guard warned about once, a snippet's notes (in its comment syntax, kept out of its
    code, ended by a blank line, the complexity from `Complexity:` to their end however it was
    wrapped), notes searched between names and code, and the picker's panes and size (options of
    its own, the runner UI's by default);
  - `modes.lua`: the helper and run-setting rule end to end: availability (files, configured
    paths and commands, missing ones), automatic choices, forcing and `auto`, forced settings
    giving way and coming back, old sidecar entries, runners refreshing the checker per run,
    run-all honouring `checker off`, the Run pane's settings rows and which of them read as
    forced, `:Tuna compare` reaching an open board without taking its runner away, a
    `.tuna.lua` holding a function keeping its runner from run to run until its text changes,
    numbers on a stress run tuna picked refused while a typed `stress` takes one as its count,
    `:Tuna run all 1` running that testcase alone, `:Tuna checker`'s and `:Tuna compare`'s
    words (`off`/`auto`, bare reporting and changing nothing, no `toggle`, no `default`:
    choosing the configured method, or a float of its tolerance, keeps no override; a method of
    the user's own offered, kept and judged with by its name, and unknown where it is not
    defined) and the menu's Checker entry switching and Compare entry cycling back to the
    configured method, old or nonsense sidecar values reading as automatic, a configured
    command with no arguments getting its role's, stress/interactor reruns offering the starter
    of a helper gone (Stop writing nothing, Create putting the board away and opening it in the
    editor), and a folder's solutions found whatever its name holds (a comma);
  - `scaffold.lua`: the shipped starters, names from `tool_names` (and found by discovery), the
    user's templates over the shipped one for their own language only, adding a language by
    adding a file, every shape of `scaffold.templates` (a role's list in order, a path naming
    the problem skipped without one, `["*"]`, `false`, a template only for its language), a
    template's text filled where it can be and its problem header dropped without one, a role
    named by its `tool_names` (in completion too), a template path holding what `glob` would
    expand matched as written, a new solution's name, header, default name and language (from
    the folder's solution when the current file is none), `scaffold.language` and a language
    asked for by name over it, the languages offered when one has no starter, an existing file
    asked about, a run that needs helpers offering their starters (Create writing and opening
    them, Stop writing nothing, a broken configured helper only reported), `clean` recognising
    an untouched scaffold, and completion of roles and languages;
  - `scratch.lua`: the templates a scratch can start from, when a scratch is resumed, the
    resume/restart and template menus, and absorbing keeping the header of the template actually
    used;
  - `navigate.lua`: the next and previous problem opened, Neovim's directory moving along only
    from the problem left or a folder inside it (by real path), staying in the contest's folder
    and with `cd_command = false`, and from a runner UI pane the window under it opening the
    problem and taking an `lcd`;
  - `download.lua`: the listener's boundary, a request handled while its sender is still
    connected, and what is stored (an empty answer kept, no file refused, a typed `~` path,
    the solution's template filled in, tuna's starter with none configured, a scratch folded
    in under the header of the template used);
  - `startup.lua`: what a session that never uses tuna pays and that it works without `setup()`:
    `tuna` alone loaded at startup with `:Tuna` and the highlight groups defined, a verdict
    restored for the first file read (before anything loads `config`), entering or writing any
    other file loading only what deciding whether it is a problem takes, and `setup()` adding
    only the keymaps;
  - `testcases.lua`, `compare.lua`, `judges.lua`, `clean.lua`, `submit.lua`: unit tests of pure
    rules (`compare.lua` also: an unknown method reported once, diff marks following the verdict
    and marking a token or character missing where it is missing, a checker that did not build
    giving no verdict and no notification; `submit.lua` also: an edit hiding a shown verdict and
    keeping it stored, and a write of the source submitted bringing it back; `clean.lua` also:
    the templates a file is compared with, a judge's matched without a sidecar and the best
    match deciding, tuna's starter recognised, a template never offered, an empty one included,
    and a pinned file named, starting on Keep, and unpinned when deleted);
  - `runner.lua`: all four run modes with `vim.system` stubbed, covering what each child is
    handed, bare rows, save/answer semantics, a board listed before any run accenting its
    editable panes, a row added after a run settling and judged by its next save, disk drift and
    restore, path resolution, the swapfile contract, interactive grids and the conversation
    model (its columns unwrapped and scroll-bound on a session's row only, a board listed before
    any run included), and the run gate (`settle_runners`), the local verdict a finished normal,
    run-all and feed run saves, live's typing keys starting a session, the build step showing
    one named pane per source it compiles (and none for a helper with nothing to compile, nor a
    name when the solution is alone) without a buffer more than a board's six, its grid's own
    vocabulary, a key for every source by its role and titles naming it, the legend's sections
    for stress and live interactive and its build-row line (and none of that for a plain run),
    panes renamed, un-accented and wrapped for it and back again for a testcase row, and what
    the stress search trusts (a bruteforce that crashed or ran past its own budget saving
    nothing, one that printed nothing saving an empty answer, the row the search is shown on,
    when it is listed and that it stays last and numbered past every testcase while the board is
    edited, a helper that failed reported on that row and on the Compile row rather than in a
    float, the search running beside the testcases on disk rather than after them, every run
    searching from a seed of its own and the Run pane showing the one being tried, a checker
    that did not build or gives no verdict stopping it and a restart judging with the checker as
    it is now, a failed build finishing it and spawning nothing behind it, in every mode that
    builds a solution of its own), a stop in every mode (nothing started after it, the rows it
    had not reached `NOT RUN`, a stopped session `KILLED`, the board idle), `<C-r>` building the
    solution again and running after a stop, reusing a build (the files its stamp reads: headers
    beside it and through `-I` and `-Idir`, none of the compiler's own, an include cycle; a flag
    changing it; a file touched or an edit undone being no change; a reused row reading `CACHED`
    with its compiler's words; a missing program or a failed build never reused by another run;
    run-all and the helpers going by the same rule; a helper's build answered within its run
    without its sources read, a failure included; Rust never reused across runs), headers never
    taken for a solution or a helper (a run from one running the solution beside it, run-all,
    `solution_in`, a contest's problems, `:Tuna pin` and, in `menu.lua`, the command list), the
    ending vocabulary, and run-all's headers counting judged rows only, using real UI windows,
    in both interfaces where the grid changes (focus, the selector's row and line numbers,
    titles and a bad grid said once as the board re-tiles, the pane keys moving from the cursor,
    the selector's cursorline always and a pane's or the zoom's only while focused, a row
    reading `EDITED` for what is typed and not for a pane's own filling, the cursorline kept in
    diff mode, what a diff paints (only the disagreeing tokens on a line that disagrees, a cell
    where a line ends short, a line the other lacks coloured whole), `:w` from a read-only pane,
    a file opened from the board opening where the board was opened over and the board put away,
    and a zoom key doing nothing in a zoom). `testcases.lua` also covers the `single_file`
    rewrite keeping untouched testcases, a conversion through every backend keeping an answer
    stored empty and leaving no layout behind (the store's root kept), which testcase a command
    without a number acts on, and sharing a folder's testcases (offered for a solution with none
    when exactly one other has some, never for several sets, a format or `testcases_directory`
    carrying the file's name, or a name without a number; renamed as they were, an empty answer
    kept; the question asked once a session, naming every rename, and the run going ahead after
    every answer).
- Modules expose file-local helpers to tests through `M._test` (`download`, `submit`, `clean`,
  `interactive`, `scratch`, `menu`, `runner_ui`, `navigate`), and `tools` a way to forget the
  session's builds, for a test whose stubbed compiler answers differently for a source that has
  not changed. They are not public interface.
- **Mutation-check new tests**: break the rule each test describes and confirm it fails, and
  confirm a harmless edit doesn't.
- The suite doesn't cover real processes, verdicts coming back, or most UI interaction. Verify
  those with headless scripts against real processes, kept in the session scratchpad.
