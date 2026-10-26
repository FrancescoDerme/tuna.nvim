# lua/tuna/workspace

The files around problems: starters, the scratch, cleaning, the snippet library, moving between
problems and remembering them. The rules that hold everywhere are in the root `CLAUDE.md`.

## Modules

- **`scaffold.lua`**: starters for every role, `tools.SCAFFOLDS` (the solution and the helper
  roles of `tools.ROLES`), and the one template lookup downloads, `:Tuna scratch`, `clean`
  and `:Tuna scaffold` share. A solution is not a helper role in `tools`: a helper is found
  by name, a solution by being neither a helper nor a header, under any name, several per
  folder; `tool_names.solution` only says which name a helper prefers for its solution
  (`solution_bufnr`) and what a new one is called in a folder with none. Writing a file
  needs no such split, so every role is looked up the same way.
  - `scaffold.templates` is a path, an ordered list or a table by role (`["*"]` for every role
    not listed, `false` an empty file), its paths taking the file modifiers, `$(ROLE)`,
    `$(FEXT)` (the language written) and the download set when the problem is known (a
    download's task, else the sidecar's). One option rather than a folder option beside a path
    option: a folder is a path ending in `$(ROLE).$(FEXT)`. A role table's missing role goes to
    tuna's starter, not to the default folder, so the config reads as the whole list.
    `template` is the first that exists, checked by path (a path naming a modifier it cannot
    fill is skipped), else the shipped `scaffolds/<role>.<ext>`; `templates` every file the
    paths can match, those modifiers read as wildcards in a glob that escapes everything else
    `glob` reads (`$HOME`, `[`, `\`), then the shipped starters in the languages left, listed
    once per session (`shipped`). A template is for the language its extension names (none:
    every language), so a `template.cpp` never lands in a `.py`.
  - `render` fills what it can and leaves every other `$`; with no problem known, the leading
    lines naming one go, and the blank lines under them when none of them is left. The
    shipped folder is found from `scaffold.lua`'s own location (`SHIPPED`), not the
    runtimepath, where another plugin's `scaffolds/` would mix in. Each starter's header
    says it is tuna's and names `scaffold.templates`, which is how a user who configured
    nothing, or a path that does not exist, learns where templates go.
  - A helper is named after the role's first `tool_names`, the name discovery looks for first:
    a separate list of scaffold names could disagree with it and write helpers the run does not
    find. A solution goes through `widgets.input`, offered the name of the solution it is
    written beside (the current file when it is a runnable solution, else the folder's first)
    while it is free, else it with the next free number (`main2.cpp`), in that solution's
    language. A helper's language is the one asked for, else `scaffold.language`, else the
    solution's; one the role has no template in offers the languages it has (a helper is
    compiled and run in its own language, whatever the solution's). A solution's is the one
    asked for, else that solution's, else `downloaded_files_extension`, and with no template it
    starts empty, as a download does. Only a new solution gets `template_cursor`.
  - Every starter that reads a test count reads it as the solution starter does (`int tt = 1;
    cin >> tt;`), on a line marked `comment out for a single test`: the bruteforce, the checker
    (run once per testcase file, looping over its tests) and the interactor, which reads the
    count from the testcase file, the jury's hidden data, and tells it to the solution. The
    generator writes whatever format the problem takes, so it has none. A checker answers by
    its exit code alone, naming only trailing output, and the interactor stops at the first
    game lost, after which it and the solution are no longer in step. The C++ solution and
    bruteforce print with `setprecision(0) << fixed`, marked `raise to 10 for real answers`:
    nearly every problem is an integer one, and there a value that became a double by accident
    (`ceil`, `pow`) still prints as an integer, where a precision of 10 prints `3.0000000000`
    and fails. The two print alike, so a stress test compares like with like. `languages` feeds
    the completion of `:Tuna scaffold <role> <Tab>`. `create` takes `{ open, on_done }`, so a
    caller can chain it, and a role's `tool_names` as the role (`role_of`: `main`, `brute`),
    the names a user sees on the files; completion and the docs keep to the role words.
  - **A run that needs a helper it does not have offers its starter** (`create_missing`): a
    menu naming the files (`Create gen.cpp and brute.cpp` / `Stop`), rather than a warning,
    from stress and the interactor source, on the first run and on a rerun alike. It writes
    them through `create` (the language fallback included), opens the first in the editor
    window and lists the rest, and runs nothing, a starter being where a helper begins. A
    rerun from the board passes `before`, which puts the board away so the file opens in the
    window it was over. Only a helper that is *absent* is offered: `tools.helper` returns a
    note for a configured one that is broken, and a starter beside the solution would not be
    the one used, so that is still reported. A saved forced mode giving way to the automatic
    one is not a run asking for the mode, and offers nothing.
- **`clean.lua`**
  - "Unused" means a file still similar to the template that would produce it: a line-LCS
    ratio (`similarity`, with modifier lines matched as wildcards) at or above a threshold.
    Every file compares against every template of its role (`scaffold.templates`, a helper
    by its `tool_names`, anything else a solution), a modifier only a problem fills matching
    anything, so no sidecar is needed, and the best match wins: which template a file came
    from is recorded nowhere. Globs are cached per scan by pattern. A file that is one of
    its role's templates is never offered, an empty one included; any other empty file is
    always unused.
  - The flow is floats only: a `form` for directory, depth and threshold, then one
    `Delete`/`Keep`/`Stop` menu per file with a preview, sorted by match, at a fixed width,
    each starting on the answer last given (`ui.row`), and the same for directories. A
    pinned file (`scan` marks it) comes after the other files, is titled `pinned, …` and
    starts on `Keep` whatever was answered last, so a run of Deletes cannot carry it along.
  - **Scan cost is bounded**: pruning at traversal (`descend_into`, `clean.skip_directories`,
    dot-directories, judged by the directory's own name at every depth: `vim.fs.dir` hands
    `skip` the path relative to the root), a shared `clean.max_entries` budget reported through
    the `notice` pane, early rejection on the line-count ceiling, and a 1 MiB size guard.
  - **Directory pass**: offers directories left empty apart from disposable files (testcases
    and the sidecar). Directories are evaluated post-order, deepest first. Directories the run
    emptied are evaluated before the general sweep, so the budget can't starve them.
    `protected_directories` covers the scan root, cwd, launch directory, configured roots, home
    and its XDG/standard subdirectories, system directories and `clean.protected_directories`.
  - A folder of testcases kept apart from its solution (a `testcases_directory` such as
    `tests`, a library's shared one, the directory backend's `tests/1`) holds nothing else
    either, so one that a source still on disk stores into is kept (`holds_live_testcases`).
    Only the sources in the directories above it, within the scan, are asked (`stores_in`,
    each by the config a buffer of it would get, `.tuna.lua` included, read only for a
    directory that would otherwise be offered): a store elsewhere is not found.
  - **A build whose source is gone** is offered in the file pass, ahead of everything
    (`orphaned_build`): a file shaped like a build output (`ARTIFACT_EXTS`, one leading dot
    ignored) that is a compiled program by its first bytes (`is_program`: ELF, Mach-O, PE),
    with no source of its stem beside it in a language the scan reads. The bytes decide, not
    the name, as a problem folder holds files without an extension that are no build; nor the
    compile command, which may name no output (`rustc`). Its preview gives its size and age.
    A source deleted takes its builds with it (`builds_of`, by the same name rule and bytes,
    plus a `.dSYM` bundle), unasked: nothing can rebuild them, and left behind they would keep
    its directory from being offered.
  - Every modified buffer is saved first (otherwise an open buffer rewrites a deleted file),
    and buffers of deleted files are wiped.
- **`scratch.lua`**: the scratch is a template minus its leading modifier header
  (`split_template`). A scratch with anything written in it (its loaded buffer, else its file)
  asks `Resume` / `Restart`, previewing what it holds. Restarting, and a missing or blank
  scratch, go to the template question, opened straight from the first menu's choice (which
  fires after that menu has closed) so no frame is drawn without a dialog, a menu with a body
  preview: `template_choices` offers the solution's `scaffold.templates` (a task-only modifier
  read as a glob wildcard, since no problem exists yet), plus an empty file. Dismissing creates
  nothing, and with no template at all the scratch opens empty. `download sync` sets
  `M.pending`; `M.absorb(filepath, cfg, template)` keeps as many header lines as the template
  the problem was written from (returned by `store_downloaded_task`), replaces the body with
  the scratch *buffer* lines, saves, moves the cursor, and deletes the scratch.
- **`recent.lua`**: `stdpath("state")/tuna/recent.json`, written with a debounce and flushed on
  `VimLeavePre`, read once per session. It holds `problems` and `contests`, most recent first
  and capped by `recent.problems`/`recent.contests` (read from `config.current_setup` when
  recording). `push_front` moves a recorded entry to the top and drops entries whose directory
  is gone. `open_problem(i)`/`open_contest(i)` open any of them, 1 by default.
  - **Pinned** problems (`pinned`, `:Tuna pin` through `commands.toggle_pin`, which pins a
    helper's solution and refuses a buffer that is not a runnable solution on disk) are
    kept in the same file, most recently pinned first, with **no cap**: a pin is put aside
    on purpose, and the menu scrolls a long list, so there is no `recent` option for it.
    One whose solution is gone is dropped by `snapshot` (`prune_pinned`), and `is_pinned`
    answers false for it meanwhile, so deleting a problem by any means unpins it;
    `clean` also unpins what it deletes. `open_pinned(i)` opens one the way
    `open_problem` does (`open_remembered`).
  - `plugin/tuna.lua`'s `BufEnter` hands a file buffer to `track`, which records it only when
    it looks like a problem (runnable, not a support file, with testcases or a sidecar
    beside it); its `VimLeavePre` flushes only a session that loaded `recent`.
  - Nothing under `recent.ignored_directories` is ever recorded (`ignored`, checked in
    `record_problem` and `record_contest`, which every way in goes through, and first in
    `track`), so a snippet library can be tested with tuna. What was remembered there before is
    forgotten wherever the history is read (`forget_ignored`, in `snapshot`, `open_problem` and
    `open_contest`), or adding the option would leave it offered. It is a list of paths rather
    than a rule about `library.path`, because a library may hold real solutions (unguarded
    files are offered whole). Pinning is not affected.
  - Recording a problem inside a remembered contest moves that contest to the top with the
    problem as its `problem`, even when the problem was already on top. A contest is
    otherwise recorded by downloads, or inferred when a sibling problem shares the sidecar
    `group`. Both store the `judge` and contest `judges.parse` gives, which is how the menu
    names a contest.
  - `change_dir` honours `cd_command` (`cd`/`tcd`/`lcd`/`false`). `snapshot()` returns the
    loaded state for the menu. `contest_problems` lists a contest's solutions in both
    layouts (plain files in the contest directory, and one per problem directory).
- **`navigate.lua`**: the next or previous sibling problem directory in name order.
  `solution_in` prefers the same file name, then the same extension, then any runnable file that
  is not a support file (`tools.is_support`). The ends of a contest warn instead of wrapping.
  Neovim's directory comes along (`recent.change_dir`, with the new problem's `cd_command`) only
  when it was the problem left or a folder inside it (`working_in`, by real path): working in a
  problem, `:e` and a file finder would point at the one left, while a contest's folder, where
  `:Tuna last contest` puts you, is kept. `recent` is required lazily, as it requires
  `navigate`.
- **`library.lua`**: snippets are regions between `library.marker` guard comments in plain
  source files; files without guards are offered whole. Only files with the current buffer's
  extension are shown, dotfiles and dot-directories left out at every depth, and `library.path`
  goes through `expand_home`/`normalize_path`. Snippets are inserted dedented and re-indented to
  the cursor line. A snippet's **notes** are the lines right under its start guard that begin
  with the guard's own comment leader (what precedes the marker on its line), up to the first
  that does not, so a blank line ends them in any language; from the line starting `Complexity:`
  to their end they are its complexity, so a complexity a formatter wrapped stays whole. They
  are kept out of `lines`, never inserted, and `first` is the code's first line. `:Tuna lib` is
  one picker, a `widgets.menu` with a `search` and its panes `beside` (`open`): the `catalogue`
  is read once when it opens, so an unclosed guard warns once, and `rank` orders a search:
  `matchfuzzy` over `name file` (case-insensitive for a lowercase query, words in any order),
  then the entries whose whitespace-free, lowercased notes contain the whitespace-free query,
  then those whose body does. Fuzzy matching stops at names, because nearly anything typed is
  scattered somewhere in a body. The list holds names alone, so it stays narrow beside the
  panes; the code pane's title names the file. Beside it, Notes, Complexity and the code: the
  complexity has a pane of its own, without its label, because at the end of the notes it would
  move from entry to entry and long notes would push it out of view. Notes and Complexity are
  `fit` panes, as tall as the longest of theirs in the library, so they do not jump between
  entries. The picker's size is `library.width`/`height`, defaulting to the runner UI's
  `popup_ui` share: options of its own, since `popup_ui` names the runner UI. Don't add a
  file-then-snippet route or a telescope picker beside it: the search covers a file (its name
  finds its snippets), and telescope's preview cannot be entered to read the code. Arguments
  after `:Tuna lib` are ignored, so a mapping written with `snippet` or `search` still opens it.
