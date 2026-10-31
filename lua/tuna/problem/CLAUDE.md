# lua/tuna/problem

A problem's data: its testcases, its sidecar, the task it was downloaded from and its
submissions. The rules that hold everywhere are in the root `CLAUDE.md`.

## Testcases (`testcases.lua`)

- One 0-based table shape, `{ [n] = { input, output } }`, shared by three backends: `files`,
  `single_file` and `directory`. The `buf_*` functions dispatch to the configured backend and
  fall back to auto-detection. Every backend reads and writes by the solution's path and
  config (`path_load`/`path_write`), and its `buf_*` forms are those for a buffer's file:
  `get_testcases(filepath, cfg)` and `write_testcases(filepath, cfg, tctbl)` are for a
  solution with no buffer (run-all started elsewhere, a problem being downloaded).
- **`files` formats** may each be a list. On load the first format that matches anything wins;
  formats are never merged, so two problems sharing a folder don't mix. `active_parts` picks
  the pair a directory already uses, and both load and write go through it, so a new testcase
  joins the existing naming. A format without `$(TCNUM)` names testcase 0. A testcase may have
  only an input or only an output.
- **Empty versus absent** is a load-bearing rule:
  - *Input*: empty and absent mean the same thing. `as_stored` normalizes inputs on load in all
    three backends.
  - *Answer*: **absent means not judged** (`compare_output` returns `nil`, verdict `DONE`);
    **present but empty means the solution must print nothing**. Only file presence can carry
    the difference, so `write_or_delete` deletes an empty answer unless `keep_empty` is set.
  - `buf_save_testcase` always keeps the input, even an empty one, and keeps an empty answer
    only when passed `expect_empty_output`. `buf_write_testcases` (bulk) keeps plain
    "empty means absent".
  - A `single_file` save or delete rewrites the whole store, so the testcases it is not
    touching go through `keep_stored` and are written back exactly as they were; the bulk
    rule would otherwise drop a stored empty testcase and an expected empty answer.
  - A blank pane cannot show the difference, so `empty_answer_words` gives what it says, in the
    runner UI and the testcase editor alike. An empty answer file made by hand is one too.
  - In memory, typed text goes through `core.answer`, which turns `""` into `nil`. `sync_rows`
    takes the disk's answer as it is, so a stored empty answer survives a reload.
- `tc_directory(source_dir, filepath, cfg)` is the only place `testcases_directory` is
  resolved: modifiers evaluated, `~` expanded, used as-is when absolute. An absolute value
  without a per-problem modifier (decided by modifier name, `has_scoping_modifier`) warns once
  per session, because every problem would overwrite the others. The warning is skipped when
  the value comes from a `.tuna.lua`.
- `buf_convert(bufnr, target)` (`:Tuna convert`) moves the testcases from the backend holding
  them to `target`, clearing every backend first, and writes them through `keep_stored`,
  exactly as they were: the bulk rule would turn an answer stored empty into none. The
  `directory` backend, removing a testcase, also removes the directories its format made
  for it once empty (`tests/0`, then `tests`), stopping at the store's root
  (`testcases_directory`), which is the user's.
- **Sharing** (`share_plan`, `share`): unqualified names (`input0.txt`) belong to the whole
  folder, since every solution's format list falls through to them, so they are the only way
  two solutions share testcases, and only right when the folder is one problem. Before every
  `:Tuna run` (`commands.dispatch_mode`, which the menu's Run entries also go through) a
  solution with no testcases is asked through `commands.offer_sharing` whether to rename the
  testcases of the one other solution there that has some, to the first `files` format pair
  that evaluates to the same names for both (`testcases_directory` included). It is never
  offered when several solutions have testcases (a contest's folder, where the shared names
  would be read by every problem's new solutions), when no format is shared, or to a name
  without a number, which holds testcase 0 alone. The menu's title says what sharing does and
  its preview names every rename; every answer runs, and a decline is remembered for the
  session, by path. Sharing is a rename on disk, not a link: a folder-level rule that read a
  sibling's testcases, or a sidecar link from one solution to another, would be state the user
  cannot see in the file names.
- `:Tuna testcase edit`/`delete`/`split` without a number go through
  `commands.choose_testcase`: the only testcase when there is one, a `widgets.menu` of them in
  order when there are several, a message when there are none. Delete still confirms.
- **Split** (`split_testcase`, `buf_split_testcase`): marker lines come in **pairs**, and what a
  pair brackets becomes a testcase. Everything outside the pairs stays in testcase `n`; new
  cases take the lowest free numbers, and no other testcase is renumbered. The split is
  mechanical on purpose: case boundaries depend on the problem's input format and can't be
  inferred. It refuses four things: an odd marker count, an empty pair, an expected output with
  a different case count, and a non-empty expected output with no markers.
  `offer_case_counts` then offers to fix a leading case-count line, read from the *original*
  input. It is a menu, never applied silently, and its `on_settled` fires on every answer so
  the runner UI can hold the run until it is answered.

## Sidecar (`sidecar.lua`)

- `problem_store_file` (`.tuna.json`) beside the source. Keys:
  - `task = { [basename] = { url, name, group, mirror, mirror_at } }`, the problem each file is
    a solution of, as downloaded (`submit.write_task_store`) or backfilled by a submit;
  - `submit = { [basename] = { state, text, url, hash } }`;
  - `run = { [basename] = { mode, source, checker, compare } }`, holding only what was forced,
    each value validated on read;
  - `results = { [basename] = { passed, total, hash } }`, the local verdict (see
    `lua/tuna/run/CLAUDE.md`).

  Entries are keyed by **basename** because one folder can hold several problems or several
  attempts. Writers merge. `set_entry(…, nil)` removes an entry and deletes the file once it is
  empty. Every write drops the entries of files no longer beside it (but the one being written,
  which may be a buffer not yet on disk), or a new file given a deleted one's name would take
  its forced run settings, which no hash guards as one does a verdict. `forget` clears a file
  written anew in a deleted one's place (`scaffold`, with `tools.forget` for the session's
  copy), as no write may have come between. This is problem state that travels with the
  folder; machine state belongs in `stdpath("state")` (`recent.lua`).
- **A file's problem** is read through `task(file)`, by every reader (submit's URL, name and
  mirror, scaffold's modifiers, `recent`): its own entry, else the folder's one problem when
  every entry names the same (a second attempt beside a downloaded solution), else none, as in
  a folder of a contest's problems, which is why it is kept per file: one folder-level task
  would name whichever problem was written last. `task` is not pruned with its file: a
  solution written again in its place is still that problem's.

## Download and judges

**`download.lua`**
- The option names keep competitest's shape (`downloaded_problems_path`,
  `downloaded_contests_directory`, `downloaded_contests_problems_path`) on purpose: a path
  is a file location tuna builds, folders included, and a directory a folder. Renaming
  them to `_file` was weighed and left, so don't retry it.
- Pipeline: `Listener` (TCP, `companion_port` 27121) → `TasksCollector` (groups by `batch`) →
  `BatchesSerialProcessor` (one batch handler at a time).
- The listener handles a request, and answers it `200`, the moment its body is complete
  (`request_body`: `Content-Length` of it has arrived, or the sender closed without one),
  not when the sender gives up waiting for a reply and closes the connection.
- What arrives is stored without touching what is there: testcases kept alongside new ones
  are left as they are stored (only the new ones are saved, through `buf_save_testcase`), so
  an empty answer survives, and a buffer with no file is refused rather than written into
  the cwd. A path typed or edited in the problem-path or contest-directory prompt goes through
  `expand_home`/`normalize_path` like a configured one, or a `~/…` path would put the source
  in a directory called `~` and its testcases in the real home.
- **Nothing in the pipeline may throw.** `validate_task` repairs or rejects every body: only
  `name` is required, a missing `batch` means a single task, and malformed tests are dropped.
  Messages go through `notify_soon`. `process` schedules the handler under `pcall`, and its
  `finished` is idempotent.
- `canonicalize_task`: a Codeforces mirror URL (`m1`/`m2`/`m3`) is rewritten to codeforces.com
  (mirrors have no per-problem pages and drop the contest later), with the mirror kept as
  `mirror`/`mirror_at`. A missing problem index is taken from the URL and prefixed to the name,
  because `$(PROBLEM)` orders the folders.
- Existing targets ask in a float: `Override` / `Stop` for a problem;
  `Override all` / `Write missing only` (only when some are missing) / `Stop` for a contest.
  Every branch, and dismissal, calls `finished`.
- The source is written from the solution's template (`scaffold.template`/`render`, with the
  task), and `store_downloaded_task` returns which one, for `scratch.absorb`. No warning when
  a configured template is missing: what is written then is tuna's starter, whose header
  says where templates are set. `eval_path` expands `~` on evaluated paths.
- After writing, `cd_downloaded_problems`/`cd_downloaded_contests` (independent of
  `open_downloaded_*`) change directory via `recent.change_dir`. What was written is recorded in
  `recent`.

**`judges.lua`**
- `parse(task, judge_parsers)` splits `group` into judge and contest. The parser is resolved
  as user `judge_parsers[judge]` (or `false`) → `M.builtin[judge]` → user `["*"]`. It is
  `pcall`ed and runs even when the group has no contest half; `unknown_contest` is the last
  resort.
- Codeforces is keyed on the **contest id in the URL** (`gym <id>`, else the bare id from
  `/contest/<id>`, `/problemset/problem/<id>`), so the main site and mirrors land in one folder.
  Don't add round-name normalizers: a round number is not a contest id.
- Path-hostile characters are replaced later, in `task_modifiers`, for download paths only
  (`eval_path`): a template's text and paths keep them.
- `label(group)` is the group to show: the contest half when it names the judge anywhere (a
  plain substring, in any case), so nothing says the judge twice, else the whole group.
  It is for display alone: `group` stays what is stored and compared.

## Submit (`submit.lua`)

- `M.context` saves the buffer and resolves the problem's **identity URL** `ctx.url` (a
  `submit.url` function, else the header marker, else the sidecar) and `ctx.submit_url` (the URL
  to submit through, from `submit.url_rewrite`: user function → `builtin_url_rewrite`, or
  `false`). `$(URL)` is the submit URL and `$(PROBLEM_URL)` the identity URL. Only `ctx.url` is
  ever written to the sidecar.
- URL candidates are validated (`is_valid_url`: http(s), no leftover `$(…)`). Invalid ones are
  skipped, and with none valid the submit aborts before any provider runs.
- `open_problem` (`:Tuna go judge`) opens that identity URL. It goes straight to
  `resolve_url` rather than `M.context`, which saves the buffer and demands a language.
- **Mirror routing** for Codeforces sends through the sidecar's `mirror` only within
  `submit.mirror_ttl_seconds` of `mirror_at`. It is a clock because nothing can be probed:
  Codeforces returns an identical challenge page either way, and a network lookup would block the
  synchronous path exactly when the site is struggling. Expired routing is pruned from the
  sidecar with one message.
  - The CLI rewrite yields `…/problem/` without an index, which submitters turn into the
    contest-wide `…/submit/`, the only page a mirror serves.
  - The `browser` provider derives real pages instead (`browser_submit_url`).
- Per-judge config: `judge_of(url)` → `judge_scfg` shallow-merges `submit.judges[judge]` over
  `submit`.
- Providers:
  - `command` expands `submit.command` (string or function) and either watches it
    (`submit.watch`, default true, `run_watch` via `vim.system`) or runs it in a terminal
    (`M.run_terminal` seam; toggleterm if present, else a terminal job through
    `open_terminal`: `jobstart` with `term` on 0.11, `termopen` on 0.10).
  - `browser` opens the submit page and copies the source to `+`; it exists for judges gated
    behind a Turnstile challenge, such as AtCoder.
- **Watching**
  - Output: strip terminal control sequences, then `scan_verdict` over `submit.verdicts`,
    **preferring the rightmost final verdict over pending** (in-place redraws collapse onto one
    line) and showing a short snippet.
  - Exit with no verdict: `watch_outcome` decides on the exit code alone. Exit 0 clears the
    indicator; it never reports a failure. `expects_verdict = false` only disables parsing.
  - Failures: `failure_reason` checks `OFFLINE_HINTS` first, then `CRASH_HINTS`, then the
    redacted, clamped `meaningful_tail`. A tool that printed its submission URL had submitted,
    so a failure after that is a verdict lost, not a submission. Before that the two can't be
    told apart: a tool like `submitter` on Codeforces waits on a browser submission tuna can't
    see.
  - Jobs: one per file in `jobs[path]`. A new submit supersedes the old job, and callbacks check
    they still own the slot. `watch_timeout` stops a hung poll; `M.clear` cancels.
- Verdict state is per file (`M.state[path]`) and drives `status`/`status_hl`/`is_submitting`.
  Final verdicts persist in the sidecar with the SHA-256 of the submitted source, not its mtime,
  because a write that changes nothing (a `:w`, the save before a run) must not drop one.
  `utils.file_hash` keeps each hash for the session with the file's size, mtime and inode, and
  hashes again only when one of them changes: the menu asks for every remembered problem's hash
  each time it opens. `restore` (on `BufReadPost` and `BufWritePost`) shows a stored verdict
  only while `still_current` holds (the hash matches, and an entry without one describes no
  source), and `arm_invalidation` hides the shown one on the first edit and keeps it stored: it
  counts only while the hash matches anyway, so a write that takes the source back to the one
  submitted brings it back, and it is never deleted there: Vim reports more than edits, and
  deleting on such a report would lose the verdict of a source that never changed.
  `verdict_for(path)` reads a verdict without an open buffer (the menu).
- `persist_task` records the submitted file's problem as its own (`url`, and `name`/`group` from
  header markers when missing), taking the folder's when it has none.
