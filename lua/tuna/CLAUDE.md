# lua/tuna

The top-level modules a user reaches tuna through: the menu, the keymaps and the health
check.

## Entry points

- **`menu.lua`**: the `:Tuna` menu, built on `widgets.panels` (not `widgets.menu`) with a
  free-standing banner (no border and `winblend = 100`, so the editor shows between the
  wordmark's letters, which are extmarked `TunaMenuTitle`, whose `blend = 0` keeps them out
  of the blending that would otherwise paint them in the colours underneath): Contests over
  Problems over Pinned in the left column (from `recent.snapshot()`), the commands on the
  right under "catch of the day". Pinned is last because it is the unbounded one: `panels`
  hands a column's rows out smallest list first, so it is the list that scrolls. The three
  are laid out together by `recent_layout`, so statuses line up down the column, and the
  commands offer `pin this problem`/`unpin this problem` for a runnable buffer.
  - A problem's status (`entry_status`) is the judge's verdict from `submit.verdict_for` while
    it is current, else `core.local_verdict`, else nothing: the judge's answer settles a
    problem, so it always wins. A contest's (`contest_status`) counts current judge verdicts
    over `recent.contest_versions`, like `2/5 accepted, 1 rejected`: a problem counts once, by
    the best verdict among its versions (`best_verdict`), so what the contest says cannot
    depend on which version was opened last, as a pick of one file per problem would, and a
    rejected attempt says nothing about a problem another version was accepted on. Local
    verdicts don't count there, because they exist only for problems that were run — unless
    no verdict can reach the contest at all, where it counts what passes locally and says
    `passed`, any version passing a problem. That is
    `submit.reports_verdict`, which is about whether anything reports the outcome _back_ (the
    `browser` provider watches nothing, `watch = false` is not read, `expects_verdict = false`
    is not parsed), not about how the submission is made, which is a browser tab for most
    judges. `0/7 accepted` would be a claim about an answer nobody can hear, and would sit at
    zero for the life of the contest.
  - Statuses are `{ text, highlight? }` segments in the runner UI's words and colours
    (`accepted`/`TunaCorrect`, `rejected`/`TunaWrong`, `partial`/`TunaWarning`, `passed` green
    only when all pass). Counts are their own uncoloured segments, and a zero `accepted` is
    `TunaDone`.
  - `recent_layout(lists, width)` lays both lists out together: names on the left (a
    contest's judge before its name), every status right of the longest name, and the status
    itself in the three parts `status_parts` gives it: the count, the verdict word, and what a
    contest counts besides. The first two get a column each, both filled from the right, so the
    counts stack however long the words beside them are and the words end on one edge however
    long the counts are; `, 1 rejected` trails past both. Aligning count and word together
    moves a count whenever its word changes length, and aligning whole statuses puts a bare
    `accepted` under another row's `rejected`. Byte-range `highlights` come with the rows. The
    sections pass it as `format`, so a narrow column shortens names with an ellipsis
    (`entry_name`: a contest's judge first) and never statuses. `problem_names` tells same-named problems apart by their contest directory (`2263/A`),
    and two attempts in one directory by file. An empty list gets a `—` row whose `<CR>`
    shows `recent`'s explanation.
  - The commands stay short, so each row applies to the buffer: those needing a runnable
    buffer are dropped for others, `run all versions` needs a second solution, `stress test` a
    generator, and a mode is not offered beside the `run` already in it. `interactive` is kept
    with no interactor, as a live session needs none. Scaffold and Download are one row each
    that opens its choices (`choices_of`). Testcases (the runner UI's) and the neighbouring
    problems (keys) have no row. Run runs the resolved
    mode without forcing it and shows whether it is forced; a forced mode adds an entry making
    it automatic, and the checker entry shows automatic (with the file in use) or off.
  - A one-row hint over the commands names `/`, a board key (`panels`' `keys`) running
    `:Tuna find`. Search is a picker of its own rather than a pane of the board: three
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
  `pin` is `b` ("bookmark"), `p` being the previous problem, and `find` is global `f`, as
  `go to`'s keys are, wanted before any solution is open.
- **`health.lua`**: read-only checks for Neovim version, setup, the executables named by
  compile/run commands, Competitive Companion, submit providers and optional plugins.
