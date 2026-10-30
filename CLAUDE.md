# CLAUDE.md

Guidance for agents working in this repository. What the plugin does from a user's point of
view is in `README.md` (mirrored by `doc/tuna.txt`), so read that first. This file covers what
holds everywhere: the rules for changing the plugin, its layout and its configuration. How each
part is built, the invariants that hold it together and the reasoning behind choices that are
easy to undo by accident are in the guide beside that part's code (see Rules).

## What it is

tuna.nvim is a competitive-programming plugin for Neovim 0.10+, written in pure Lua with no
required dependencies (toggleterm and lualine are optional). It is a rewrite of
competitest.nvim, not a port. Everything is reached through one user command,
`:Tuna <subcommand>`: testcase storage and inline editing, compile/run with verdicts in a
floating runner UI, run modes (normal, run-all, stress, interactive), checkers, Competitive
Companion downloads, submitting through external tools with the verdict in lualine, a snippet
library, contest navigation, a scratch file, an unused-file cleaner, a menu and
`:checkhealth tuna`.

## Rules

**Agent guides**
- This file holds what applies everywhere. Each folder's design is in the `CLAUDE.md` beside
  its code: `lua/tuna/ui`, `lua/tuna/run` (and `run/modes`), `lua/tuna/runner_ui`,
  `lua/tuna/problem`, `lua/tuna/workspace` and `tests`. Claude Code loads a folder's guide, and
  those of the folders above it, when a file there is read, written or edited with its tools,
  or viewed with `cat`, `head`, `tail`, `sed -n`, `grep` or `rg` on that one file with no pipe;
  a search across files or an edit made by a script loads nothing. So read a module with the
  Read tool before changing it, and read the guide of every other folder whose invariants the
  change reaches.
- A design change is recorded in the guide of the folder it belongs to, and a fact lives in
  one guide only. A guide is loaded whole, so keep it as short as its subject allows.

**Code**
- Use current APIs (`vim.system`, `vim.uv`, `vim.fs`). Spawn processes and do I/O
  asynchronously. tuna lazy-loads itself, as `:h lua-plugin-lazy` asks, so no plugin
  manager has to: `plugin/tuna.lua` defines `:Tuna`, the highlight groups and the
  autocmds and loads only `tuna` (the module holding the highlight groups, which
  requires nothing at load time); the command and each autocmd require what they need
  when they run, an autocmd only once its event concerns tuna; and nothing heavy may run
  at require time. `setup()` only configures (`:h lua-plugin-init`): tuna works without
  it, on the defaults. `tests/startup.lua` holds all of this.
- Style: 4-space indentation, LuaCATS annotations (`---@param`), a header comment in each file
  naming its path (`-- lua/tuna/run/core.lua`) and saying what the module is for.
- Comments explain the design the code has, and motivating a choice is welcome. They carry no
  history or evidence notes ("verified", "measured", "used to", "then fixed", comparisons
  with competitest) and no considered-and-rejected alternatives. If knowing about an
  alternative would stop a future agent from retrying it, record it in the guide it concerns.
- Never cite upstream competitest issue or PR numbers anywhere (docs, comments, tests).
  Describe the problem instead. Linking the competitest project is fine.
- User-facing text (notifications, menu items, prompt titles, health output) joins clauses with
  **commas, never dashes or semicolons**. Send notifications through `utils.notify`: they
  start lowercase (it prefixes `Tuna: `) and a sentence ends with a period. Widget titles
  and menu items are sentence case, except a title that starts with a path or a name.
- **Never ask on the command line** (`vim.fn.confirm`, `input()`). Every question is a
  `widgets` float. Widgets are callback-async, so a caller that must continue passes `on_close`
  and handles dismissal.
- Every buffer or window put in front of the user goes through `surface.lua` (see
  `lua/tuna/ui/CLAUDE.md`), and every file tuna opens is opened through `surface.edit`, a
  directory change made after it.
- libuv callbacks run in a fast event context, where `vim.notify` and most API calls raise.
  Hop to the main loop with `vim.schedule` (`download.notify_soon`).
- Async results land by **row identity and a token**, never by index: rows get rebuilt,
  renumbered and removed while children run.
- A submit failure message must never carry credentials: it goes through `submit.redact`
  (blanks `apiKey`, `apiSig`, `token`, `password`, `cookie`, `session`… by parameter name) and
  is clamped to 160 characters.

**Docs**
- Three user docs are kept in step: `README.md` (what a beginner needs: install, quick start,
  the feature tour), `REFERENCE.md` (the reference: `# Commands` and `# Configuration`, whose
  last section, `## Submitting`, is the step-by-step submit setup the README's submit
  feature links to) and `doc/tuna.txt`, which is **the other two in help form and nothing
  more**: the README's sections, then REFERENCE.md's, in their order and their wording, links
  turned into `|tags|` and tables into aligned text. Don't give it per-option entries or
  detail the other two lack: that costs too much readability, and `config.lua` is on disk
  wherever tuna is installed, so the vimdoc points there as REFERENCE.md does. When user-visible
  behaviour changes, update every one it touches; when the design changes, the `CLAUDE.md` it
  belongs to.
- **Useful before complete.** The docs a user starts from (the README, and the vimdoc's
  introduction and feature sections) aim to be useful, not complete: they say what a user
  needs in order to use the plugin well, and leave out behaviour that is intuitive or that
  a user would expect or easily find out by themselves (a key that does what Vim's would,
  a prompt that explains itself, a default that is what anyone would pick). Completeness
  lives in the reference (`REFERENCE.md`, and so the vimdoc's commands and configuration)
  and in `config.lua`'s comments, and even there what a reader would assume goes unsaid. An
  offer a run makes unasked (sharing a folder's testcases, a missing helper's starter) says
  in its float what it will do, so no doc describes it.
- **Options are documented where they are defined.** Every option in `config.defaults` has a
  comment in `config.lua` saying what it does (a block comment may cover a group), and that
  comment is its documentation: no doc lists options. The README's Configuration section is
  a minimal example, `.tuna.lua`, and a link to `REFERENCE.md#configuration`, which keeps
  only what takes more than a line (the setting layers, the modifiers, keymaps and the
  action names `keymaps` takes, the highlight groups, the submit guide) and points to
  `config.lua` for the rest. A new option gets its comment, not a doc entry.
- `REFERENCE.md`'s `# Commands` is an HTML table indexing every command, each linked to a
  `##` section of its own below it (plain headings, `## convert`, so the anchors stay
  `#convert`), where the detail goes; `# Configuration` follows, its `##` headings named so
  they never take a command's anchor (`## Downloading` beside `## download`). A new command
  gets a row and a section, and its entry in the vimdoc's `COMMANDS`.
  The README links the **first** mention of each command to its section
  (`[`:Tuna run`](REFERENCE.md#run)`) and does not repeat the reference.
- The maintainer edits the README and `REFERENCE.md` by hand: read them before editing and
  don't reflow them. The Markdown docs put **one sentence per line**, never hard-wrapped
  (a list item's further sentences indented under it), so a diff shows the sentence that
  changed; code blocks, tables and HTML are left as they are.
- The vimdoc is `doc/tuna.txt` (`:helptags` only indexes `*.txt`). Lines are at most 78
  columns, a `code` span is never split across two lines (it loses its highlighting), tags
  look like `*tuna-…*`, and `|` is only a link delimiter, so alternatives are
  written `[add/edit/delete]`. Check tags with `:helptags doc`. `doc/tags` is gitignored,
  because plugin managers regenerate it.
- The `CLAUDE.md` files are `export-ignore`d (`.gitattributes` names them at any depth). Keep
  them dry and current: no roadmap and no history of how the code got here.

**Git**: don't commit unless asked.

## Repository layout

Each folder under `lua/tuna/` has its guide, `CLAUDE.md`, beside its modules.

```
plugin/tuna.lua       run at startup: :Tuna + completion, the highlight groups applied, autocmds
lua/tuna/
  init.lua            setup() (options and keymaps only), highlight groups, resize, lualine component
  config.lua          defaults, setup layering, per-directory .tuna.lua, per-buffer config cache
  commands.lua        subcommand dispatch and completion; per-buffer runner cache
  utils.lua           notify, modifier engine, filesystem helpers, float geometry, place_cursor
  menu.lua            bare :Tuna menu
  keymaps.lua         opt-in keymaps and preset
  health.lua          :checkhealth tuna
  ui/                 what every float and scratch buffer is built on
    surface.lua         the contract every UI buffer/window follows
    widgets.lua         input, editor, menu, panels, form floats
  run/                the run modes, their helpers and builds, judging
    init.lua            normal run mode + runner.new resolver (`tuna.run`)
    core.lua            RunnerCore: rows, process execution, UI plumbing, editing contract
    tools.lua           helper-program discovery/compilation, per-problem run state
    checker.lua         builtin vs external testlib-style checker
    compare.lua         exact/squish/float and the user's named verdict comparisons
    diff.lua            positional diff marks for the runner UI
    generate.lua        one testcase from the generator, with no stress around it
    modes/              the modes beyond the normal one
      stress.lua          stress testing
      interactive.lua     interactive problems (live / feed / interactor)
      multi.lua           run-all (every solution version × testcases)
  runner_ui/          the runner UI
    init.lua            RunnerUI
    layout.lua          pane titles, layout validation
    popup.lua           floating-grid interface
    split.lua           native-split interface
  problem/            a problem's data
    testcases.lua       three storage backends, testcase semantics, split
    sidecar.lua         per-problem .tuna.json
    download.lua        Competitive Companion listener and writer
    judges.lua          judge/contest names from a task
    submit.lua          submit providers, verdict watching, lualine component
  workspace/          the files around problems
    scaffold.lua        starters for every role (solution and the helpers), the one template lookup
    scratch.lua         scratch solution, folded into a download by `download sync`
    clean.lua           remove unused templated files and emptied directories
    library.lua         snippet library
    navigate.lua        :Tuna next / prev
    recent.lua          :Tuna go problem / contest, pinned problems, cwd changes
    search.lua          :Tuna go search, every problem and contest by their sidecars
scaffolds/            the shipped starters, `<role>.<ext>`
doc/tuna.txt          vimdoc
REFERENCE.md          the reference (commands, configuration) the README links into
tests/                test suite (`tests/run.sh`), with its own guide
tuna.nvim.json        package metadata
```

## Configuration

- Layers: defaults → `setup()` opts (`current_setup`, the defaults until a `setup()`, which
  is optional) → the nearest `.tuna.lua` found by walking **up** from the buffer's file.
  `get_buffer_config(bufnr)` resolves and caches per buffer.
- `setup()` **rebuilds from `vim.deepcopy(defaults)`** on every call. Rebuilding means a key
  removed from the user's config actually goes away when the config is re-sourced. The copy
  matters too: `tbl_deep_extend` assigns untouched sub-tables by reference, so any later write
  would change the defaults.
- `update_config_table` is plain `tbl_deep_extend`. Non-empty lists replace the default
  wholesale.
- `.tuna.lua` is run with no trust prompt, on purpose: users write one per contest
  folder, so a prompt per contest costs more than it protects. It is looked up from
  `recent.lua`'s `BufEnter` too, not only when tuna is invoked, and is **run again only when
  its text changes** (`local_configs`, by a hash of the text, which is what is loaded): run
  again, every function in it would be a new one, a buffer's config would never
  `deep_equal` its cached runner's, and `commands` would build a new runner, and board, on
  every run.
- `keymaps.setup()` runs on every `setup()`: keymaps are opt-in configuration, so a
  session that never calls `setup()` has none.
- `commands` drops a cached runner whose config no longer `deep_equal`s the buffer's current
  config.
- `commands.target_buffer(bufnr?)` is the buffer every `:Tuna` subcommand acts on (and bare
  `:Tuna`, from `init.lua`): a runner UI pane resolves to the solution it shows, through
  `runner_ui.owner_of`, a registry the UI fills for its pane buffers and clears when it is
  deleted. A pane is not a file, so a command acting on one would compile nothing and keep the
  problem's run state under a name that is not a path. A helper file is *not* resolved here;
  each run does that itself (`tools.solution_bufnr`).

**Modifiers.** There are two sets. The *file* set (`$(FNAME)`, `$(FNOEXT)`, `$(FEXT)`,
`$(FABSPATH)`, `$(ABSDIR)`, `$(DIRNAME)`, `$(HOME)`, `$(CWD)`) resolves from a path via
`utils.eval_string`/`buf_eval_string`, and a whole command through `utils.eval_command`. The
*download* set (`$(JUDGE)`, `$(CONTEST)`, `$(PROBLEM)`, `$(URL)`…) exists only for a
downloaded task (`download.task_modifiers`).
Template paths and text also take `$(ROLE)` (`scaffold.lua`). A template's *text* is filled by
`utils.fill_modifiers`, which leaves every `$` it does not know as written (a shell's `$(…)`,
a dollar in a comment), where every configured string goes through the strict
`format_modifiers`.

**Paths.** `utils.expand_home` expands a bare `~` or a `~/` prefix (not `~user`), by
concatenation rather than `gsub`. `utils.normalize_path` joins onto a base only when the path
is relative. Every configured path goes through these: compile/running directories,
`testcases_directory`, download paths, templates, `clean`, `scratch`, `scaffold`,
`recent.ignored_directories`.

## Entry points

- **`menu.lua`**: the `:Tuna` menu, built on `widgets.panels` (not `widgets.menu`) with a
  free-standing banner (no border and `winblend = 100`, so the editor shows between the
  wordmark's letters, which are extmarked `TunaMenuTitle`, whose `blend = 0` keeps them out
  of the blending that would otherwise paint them in the colours underneath): Contests over
  Problems over Pinned in the left column (from `recent.snapshot()`), the commands on the
  right under "Catch of the day". Pinned is last because it is the unbounded one: `panels`
  hands a column's rows out smallest list first, so it is the list that scrolls. The three
  are laid out together by `recent_layout`, so statuses line up down the column, and the
  commands offer `Pin this problem`/`Unpin this problem` for a runnable buffer.
  - A problem's status (`entry_status`) is the judge's verdict from `submit.verdict_for` while
    it is current, else `core.local_verdict`, else nothing: the judge's answer settles a
    problem, so it always wins. A contest's (`contest_status`) counts current judge verdicts
    over `recent.contest_problems`, like `2/5 ACCEPTED, 1 REJECTED`. Local verdicts don't
    count there, because they exist only for problems that were run — unless no verdict can
    reach the contest at all, where it counts what passes locally and says `PASSED`. That is
    `submit.reports_verdict`, which is about whether anything reports the outcome *back* (the
    `browser` provider watches nothing, `watch = false` is not read, `expects_verdict = false`
    is not parsed), not about how the submission is made, which is a browser tab for most
    judges. `0/7 ACCEPTED` would be a claim about an answer nobody can hear, and would sit at
    zero for the life of the contest.
  - Statuses are `{ text, highlight? }` segments in the runner UI's words and colours
    (`ACCEPTED`/`TunaCorrect`, `REJECTED`/`TunaWrong`, `PARTIAL`/`TunaWarning`, `PASSED` green
    only when all pass). Counts are their own uncoloured segments, and a zero `ACCEPTED` is
    `TunaDone`.
  - `recent_layout(lists, width)` lays both lists out together: names on the left (a
    contest's judge before its name), every status right of the longest name, and the status
    itself in the three parts `status_parts` gives it: the count, the verdict word, and what a
    contest counts besides. The first two get a column each, both filled from the right, so the
    counts stack however long the words beside them are and the words end on one edge however
    long the counts are; `, 1 REJECTED` trails past both. Aligning count and word together
    moves a count whenever its word changes length, and aligning whole statuses puts a bare
    `ACCEPTED` under another row's `REJECTED`. Byte-range `highlights` come with the rows. The
    sections pass it as `format`, so a narrow column shortens names with an ellipsis
    (`entry_name`: a contest's judge first) and never statuses. `problem_names` tells same-named problems apart by their contest directory (`2263/A`),
    and two attempts in one directory by file. An empty list gets a `—` row whose `<CR>`
    shows `recent`'s explanation.
  - The commands stay short, so each row applies to the buffer: those needing a runnable
    buffer are dropped for others, `Run all versions` needs a second solution, `Stress test` a
    generator, and a mode is not offered beside the `Run` already in it. `Interactive` is kept
    with no interactor, as a live session needs none. Scaffold and Download are one row each
    that opens its choices (`choices_of`). Testcases (the runner UI's) and the neighbouring
    problems (keys) have no row. Run runs the resolved
    mode without forcing it and shows whether it is forced; a forced mode adds an entry making
    it automatic, and the checker entry shows automatic (with the file in use) or off.
  - A one-row hint over the commands names `/`, a board key (`panels`' `keys`) running
    `:Tuna go search`. Search is a picker of its own rather than a pane of the board: three
    stacked lists sharing `recent_layout`'s columns could not narrow together cheaply.
  - Modules are required lazily.
- **`keymaps.lua`**: `M.actions` maps actions to `:Tuna` commands. `mappings` are buffer-local
  via a `FileType` autocmd over `keymaps.filetypes`; `global` are global. `setup()` can be
  re-run (it tracks `applied_global` and clears the augroup). `preset` expands under a prefix
  with which-key groups (`td`, `tg`); a key keeps its short label only while it stays in
  its group. tuna never names the groups in which-key itself: the
  prefix is the user's choice and may already be a group of theirs, and two names for one
  key are settled by whichever `wk.add` ran last, so the user names them (REFERENCE.md shows
  how). `clean` is not in the preset, nor are the testcase actions: testcases are added,
  edited and deleted on the runner UI, where they are seen, and most come from downloads.
  `pin` is `f` ("flag it for later"), `p` being the previous problem.
- **`health.lua`**: read-only checks for Neovim version, setup, the executables named by
  compile/run commands, Competitive Companion, submit providers and optional plugins.
- **`plugin/tuna.lua`** also wires `submit.restore` on `BufReadPost` and `BufWritePost` (only
  for a file with a sidecar beside it, looked for with a stat, under the default name while
  `setup()` has not loaded `config`, so other files don't load `submit`), `VimResized` (a no-op
  while neither `widgets` nor the runner UI is loaded), and a `cnoreabbrev` so lowercase `:tuna`
  works.

## Testing

Run `tests/run.sh` (or `tests/run.sh runner`) and keep it passing: it ships with the plugin.
How the suite is built, what each file covers and how a new test is checked are in
`tests/CLAUDE.md`.
