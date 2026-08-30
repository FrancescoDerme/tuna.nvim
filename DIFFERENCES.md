# Differences from competitest.nvim

This file tracks where `tuna.nvim` intentionally diverges from or improves on
[competitest.nvim](https://github.com/xeluxee/competitest.nvim), the plugin it is
a successor to. It's a living document — we add to it as decisions are made, and
it will seed the "differences / why switch" section of the final README.

Legend: ✅ done · 🚧 in progress · 📌 planned/decided, not yet implemented

---

## UI: native APIs instead of `nui.nvim`

📌 **Decision:** tuna builds its UI on Neovim's native `vim.api` floating windows
and splits. It does **not** depend on `nui.nvim`.

**Why:** competitest.nvim requires `nui.nvim` for every piece of its UI (testcase
editor, picker, input prompt, runner popup/split). As of Neovim 0.12 the core UI
(`ui2`, default float borders, etc.) covers most of what `nui.nvim` was used for,
and the community trend in 2025–2026 is to drop the abstraction layer in favor of
native floats (or, where a toolkit is wanted, `snacks.nvim`). Going native keeps
startup lean and removes a runtime dependency, which matches tuna's goals of
speed and minimal overhead.

**Trade-off:** we reimplement the recursive layout engine and popup/split
plumbing that competitest got for free from `nui.nvim`. The layout logic is small
and ports cleanly.

**Consequence:** tuna targets a more recent Neovim baseline than competitest's
0.5+. Exact minimum TBD when the UI modules land.

**Float filetype:** every tuna widget float (`widgets.open_float`: menu / input /
picker / editor) sets `filetype = "tuna"` on its buffer, mirroring how e.g.
telescope tags its prompt (`TelescopePrompt`). This lets users and other plugins
target tuna floats. It also side-steps a class of third-party bug: plugins that
write the **global** `scrolloff` off the focused window's height (e.g.
`scrollEOF.nvim`'s `vim_resized_cb`) will clobber it to `0` when a *short* float
(tuna's 1-line input prompt → `height/2 = 0`) gains focus. Such plugins honor a
`disabled_filetypes` list, so adding `tuna` to it stops the clobber; the real fix
belongs upstream (those callbacks should skip floating / non-normal windows).

---

## Testcase storage: fully user-customizable layout

✅ **Decision:** the on-disk testcase layout is a user choice, with multiple
options supported out of the box rather than one imposed structure.
(Config keys + all three storage backends implemented and tested; the
`convert` command that exposes them to users is wired up in step 9.)

competitest exposes a single boolean `testcases_use_single_file` to pick between
two storage modes. tuna replaces it with a `testcases_storage` enum offering
**three** modes:

| `testcases_storage` | layout | naming option(s) |
| --- | --- | --- |
| `"files"` (default) | a pair of text files per testcase, beside the source | `testcases_input_file_format`, `testcases_output_file_format` |
| `"single_file"` | one msgpack-encoded file | `testcases_single_file_format` |
| `"directory"` | one sub-directory per testcase | `testcases_directory_format`, `testcases_directory_input`, `testcases_directory_output` |

The `"directory"` mode (e.g. `tests/0/input.txt` + `output.txt`) is new — it
isn't available in competitest at all. `testcases_auto_detect` falls back to the
other modes when the configured one finds nothing. The `convert` command can
move testcases **between any two of the three modes**, including to/from the new
`directory` mode (competitest only converts files ↔ single-file).

**Why:** different users and judges expect different layouts; making it
configurable avoids forcing a migration on anyone coming from either convention.

### Auto-discovery of shared testcases (`files` mode)

competitest names `files`-mode testcases after the source file, so testcases are
only ever found for the exact source that created them — running a *second*
solution (or a differently-named download) against the same testcases finds
nothing. tuna makes `testcases_input_file_format`/`testcases_output_file_format`
accept an **ordered list** of formats (a single string still works). On load they
are tried in order and the **first that discovers any testcase wins**; the first
entry stays canonical for writing. The default,

```lua
testcases_input_file_format  = { "$(FNOEXT)_input$(TCNUM).txt",  "input$(TCNUM).txt"  },
testcases_output_file_format = { "$(FNOEXT)_output$(TCNUM).txt", "output$(TCNUM).txt" },
```

tries the source-named pair first (fully backward compatible), then a shared,
un-prefixed `input<N>.txt`/`output<N>.txt`, then a **numberless** `in.txt`/`out.txt`.
So any solution in a folder — every version in `:Tuna run all`, or a source whose
name differs from the download — picks up the same testcases without configuration.

A format **without** `$(TCNUM)` (like `out.txt`) names a *single* testcase (index 0)
rather than a numbered series, and a testcase may have **only an input or only an
output** — an output with no matching input still runs, with the solution fed empty
stdin. So a bare `main.cpp` + `out.txt` folder is runnable with zero setup.
competitest required numbered `input`/`output` pairs and had no numberless or
output-only form.

**Why first-non-empty (not merged):** a folder that legitimately holds two
problems distinguished by source prefix stops at the prefixed format and never
mixes their testcases together; only when the source-specific search comes up
empty does the shared fallback apply. `files.buf_clear` conversely deletes files
matching **any** configured format, so `convert` still cleans up fallback-named
testcases.

**Writing follows the format already in use.** Both load and write resolve the format
pair through `files.active_parts` — the first that matches a file already in the
directory, else the canonical first one. Writing always-canonically would split an
existing set: add a testcase in a folder whose testcases are the shared
`input<N>.txt` and it would land as `sol_input3.txt`, after which the
first-format-wins load rule finds *only* that one and every testcase already there
disappears from view. A fresh directory is unaffected and still gets the canonical
name.

### Half a testcase is a testcase

A testcase may carry only an input, only an answer, or an empty one of either, and
tuna treats all four as ordinary.

competitest passed a testcase's input straight to the child's stdin, so one with no
input file crashed the run outright — `bad argument #2 to 'write' (data must be
string or table of strings, got nil)`, then a cascading `attempt to index field
'process' (a nil value)`. tuna defaults it where the row is built, in every run mode,
so nothing but a string can reach `vim.system`: an answer-only testcase runs the
solution against **empty stdin**, which is exactly what an `out.txt`-only folder
needs. `files.active_parts` matches on the output format too, so such a testcase is
discovered in the first place.

The other half of it is that **empty is absent**. `write_or_delete` removes an empty
file rather than writing one, so an empty answer and no answer are the same bytes on
disk; every backend's `load` therefore normalizes an empty input or answer back to
`nil` (`as_stored`), the mirror of the `core.answer` rule the rows already applied.
Without that an `out.txt` that was empty on disk — hand-made, `touch`ed, emptied by
another tool — loaded as `""`, and since `compare_output` judges against an empty
answer instead of returning `nil`, a testcase with nothing to be wrong about read
**WRONG** and quietly became `DONE` again as soon as it was saved through the UI.

---

### `testcases_directory` may be absolute, and takes modifiers

competitest joins `testcases_directory` onto the current file's directory
**unconditionally**, so it can only ever name a place *inside* the problem: an
absolute `/abs/tc` is silently swallowed into `<source dir>/abs/tc`, and the
reported `~/cp/testcases` creates a directory literally named `~` beside the
source. Modifiers aren't expanded there either.

tuna resolves it through one shared `testcases.tc_directory(source_dir, filepath,
cfg)` (used by the buffer layer, `download.lua` and `multi.lua` alike): the value
is evaluated for file modifiers, a leading `~` is expanded, and the result is used
**as-is when it is absolute** and joined onto the source's directory when it is
not. The default `"."` is unchanged, so nothing moves for anyone.

That makes a testcase store outside the source tree expressible:

```lua
testcases_directory = "$(HOME)/cp/testcases/$(DIRNAME)"
```

**`$(DIRNAME)`** (the *name* of the directory the source lives in — for a
downloaded problem, the problem itself) and **`$(CWD)`** are new general file
modifiers added for this; `$(CWD)` previously existed only for download paths.

A per-problem component is what makes such a store work: every backend names its
files after the source (`$(FNOEXT)_input0.txt`, `tests/0`, …), so an absolute path
without one has every problem writing over the last — and, with the shared
`input<N>.txt` fallback above, reading each other's testcases too. Rather than let
that corrupt data quietly, an absolute `testcases_directory` carrying **no**
modifier raises one warning naming the fix. It is suppressed for a value coming
from a directory's own `.tuna.lua`, which is scoped to that tree by construction.

---

## Smaller config differences

📌 Recorded as we port `config.lua`, to mention in the final README:

- **Border highlight via `winhighlight`.** `floating_border` is passed straight
  to `nvim_open_win`. competitest's `floating_border_highlight` is kept (same
  name, same default `FloatBorder`) but implemented natively: every Tuna float
  remaps its `FloatBorder` group through `winhighlight` (`utils.set_border_highlight`)
  instead of nui's `border.highlight`. Native splits have no `FloatBorder`, so the
  option only affects floats.
- **`editor_ui` size keys renamed.** competitest's `editor_ui.popup_width` /
  `popup_height` become `editor_ui.width` / `height` — consistent with
  `picker_ui` and `viewer`, which already use `width`/`height`.
- **Picker navigation is native.** competitest's `picker_ui.mappings.focus_next`
  / `focus_prev` are dropped; the picker is an ordinary buffer, so `j`/`k` and the
  arrow keys move the selection (with `cursorline`). Only `submit`/`close` remain
  configurable.
- **`convert` requires an explicit target.** competitest's `convert auto` inferred
  the direction because there were only two storage modes. With three backends
  (`files`/`single_file`/`directory`) "auto" can't pick a unique target, so
  `:Tuna convert <target>` always takes a target; the *source* is still
  auto-detected.
- **"download", not "receive".** competitest's `:CompetiTest receive <mode>` and its
  `received_*` options are named after the plugin's point of view (it *receives* an
  HTTP POST from the browser extension). tuna names them after the user's:
  `:Tuna download <testcases|problem|contest|sync|persistently|status|stop>`,
  `downloaded_*` options, `download_print_message`,
  `start_downloading_persistently_on_setup`, `temp.download`, and the module
  `download.lua` (`is_downloading()`/`status()` for lualine).
- **Python default is `python3`.** competitest defaults the Python run command
  to `python`, which is Python 2 on some systems; tuna uses `python3`.
- **Local config search.** Both plugins walk up the directory tree for a local
  config file; tuna uses `vim.fs.find(..., { upward = true })` instead of a
  hand-rolled loop. (Behaviour parity — noted only as an implementation note.)
- **Single-file storage read as raw bytes.** competitest reads its msgpack
  single-file through a helper that rewrites CRLF→LF, which can corrupt the
  binary payload; tuna reads it verbatim (`utils.read_file(path, true)`).
- **`~` works in every configured path.** `$(HOME)` is a modifier the plugin
  expands; `~` is shell syntax that never reaches a shell, so left alone it
  survives into the path and becomes a directory literally *named* `~`. tuna
  expands the leading one (`utils.expand_home`) wherever a config option becomes
  a real path — `testcases_directory`, `compile_directory`, `running_directory`,
  the `downloaded_*` paths, `template_file`, `library.path`, `temp.file`, the
  scaffold templates, `clean.protected_dirs`, `submit.log_file` — and only the
  leading one, since `~` is an ordinary character elsewhere in a filename.
  Relatedly, `compile_directory` and `running_directory` are resolved against the
  source's directory only when they are **relative**: joined unconditionally, an
  absolute `/tmp/build` becomes `<source dir>/tmp/build`, which is worse than the
  `~` case for looking as though it had worked.

---

## Per-judge templates from `setup()`

`template_file` is evaluated with the **download** modifiers, so the template a
problem is written from can name the judge it came from:

```lua
template_file = "~/cp/templates/$(JUDGE).cpp"   -- codeforces.cpp, atcoder.cpp, …
```

A judge is a property of the *problem*, not of a directory, so configuring one should
not require a config file in every judge's folder. competitest offers only the
directory-local route — and, until late 2024, did not load it for a downloaded
*problem* at all, which two users hit independently; tuna resolves the local config on
both the problem and the contest path, and always has.

**A per-judge template needs a fallback to be usable**, so `template_file` also takes
an **ordered list**, tried in order with the first that *exists* winning:

```lua
template_file = {
  "~/cp/templates/$(JUDGE).cpp",   -- codeforces.cpp, atcoder.cpp, …
  "~/cp/templates/default.cpp",    -- …and everything else
}
```

Without it, downloading from a judge you have not written a template for gives an
empty file. It is the same "first that works wins" shape as
`testcases_input_file_format`, deliberately — the plugin should not have two spellings
for one idea. The **table** form takes modifiers too, and each of its entries may
itself be such a list (`{ cpp = { "$(JUDGE).cpp", "default.cpp" } }`); it previously
took no modifiers at all while the string form took the file ones, a difference with
nothing behind it. Both modifier sets apply at once, so `$(JUDGE)/$(FNOEXT).$(FEXT)`
works. Configured but none of the candidates existing is a warning naming every path
tried — competitest warns only for the table form, so a wrong single path silently
writes an empty solution.

`template_file` is read in three places and only the download has a task to hand. The
other two do **not** give up:

**`:Tuna temp`** skips the candidates it cannot resolve and opens from the first one
left — which is what the fallback entry is for, so the scratch gets the general
template while the per-judge ones wait for a real problem. It never refuses: with no
usable template it opens **empty**, because the scratch is what was asked for and its
value is somewhere to type now plus `:Tuna download sync` folding it into a problem
later, written from the template that does apply, header and all. (competitest has no
equivalent command.)

**`:Tuna clean`** resolves a task-dependent candidate from the **sidecar beside the
file**, which is where the download recorded the judge — the one piece scanning cannot
otherwise recover. Without it a per-judge template would make every untouched solution
unrecognizable and clean would quietly find nothing but empty files. With a fallback
list several templates can apply and nothing records which one a file came from, so it
compares against all of them and the **best** match decides: a file written from one
matches that one and no other, so the highest score picks it out without having to
know. A file with no sidecar and no task-free candidate is simply not classified —
guessing a judge would be worse than declining to.

### Prompt-free downloads

The same issue's original complaint is that every download asks for a directory and a
filename. All three prompts are switches, so the layout can be decided once in
`setup()` and never asked about again:

```lua
downloaded_problems_prompt_path      = false,
downloaded_contests_prompt_directory = false,
downloaded_contests_prompt_extension = false,
downloaded_problems_path      = "~/cp/$(JUDGE)/$(CONTEST)/$(PROBLEM)/$(PROBLEM).$(FEXT)",
downloaded_contests_directory = "~/cp/$(JUDGE)/$(CONTEST)",
```

They default to `true`, matching competitest. `downloaded_contests_directory` is the
`contest_directory` the issue asks for.

---

## Download: live listener status for lualine

✅ **Decision:** `download.lua` exposes `status()`, `is_downloading()` and `mode()`,
and `require("tuna").lualine_component` renders `status()` — an empty string when
idle, or e.g. `🐟 downloading contest` while the listener is live.

**Why:** competitest only offers `show_status()`, a one-shot notification you have
to ask for. With a persistent download mode it's easy to forget the listener is
running (or to think it is when it isn't). Surfacing the state continuously in the
statusline is a small but real quality-of-life win, and it costs nothing — the
component is just a string read from module state.

---

## User-customizable per-judge parsing (`judges.lua`)

✅ **Done (Workstream 3).** competitest normalized Competitive Companion's
`task.group` ("Judge - Contest") into folder names with a **hardcoded** block that
only knew Codeforces and AtCoder, buried in the download path — to support another
judge you had to patch the plugin. tuna extracts this into `judges.lua`: a
`judge_parsers` config table of per-judge **parser functions**, with the CF/AtCoder
logic shipped as built-in defaults.

```lua
judge_parsers = {
  -- add a new judge
  codechef = function(ctx) return { contest = ctx.contest:match("starters%s*%d+") } end,
  -- override or disable a built-in (`false` keeps the raw contest name)
  atcoder = false,
  -- catch-all applied to any judge without its own parser
  ["*"] = function(ctx) return { contest = ctx.contest:gsub("%s*%b()", "") } end,
}
```

A parser receives `{ judge, contest, group, task }` (judge/contest already split and
lowercased) and returns `{ judge?, contest? }` overrides — nil fields keep the parsed
values, so a parser only states what it changes. Resolution per judge is **user
parser → built-in → user `["*"]` catch-all**, and a parser is `pcall`-guarded so a
buggy one warns and falls back to the raw contest instead of breaking a download. The
built-in Codeforces/AtCoder normalizers are unchanged in behaviour from competitest —
they're just now defaults you can replace.

**Why:** contest-naming conventions differ per judge and change over time; making the
rules data (config) rather than code lets users support CodeChef/USACO/etc. and fix
naming without forking the plugin.

---

## Submit integration (`submit.lua`, `:Tuna submit`)

✅ **Done (Workstream 4).** Brand new — competitest has no submit support at all
(a community pull request for it is still open upstream, and users have asked for
`online-judge-tools/oj` specifically, having been put off by cpbooster's Node
dependency). `:Tuna submit` hands the current solution to an **external** submit tool
through a **provider registry**, so it's agnostic to which judge/tool/language you
use — which is the answer to that request rather than a choice between the two tools:
`oj` is one line of config, and so is anything else.

```lua
submit = {
  command   = "oj submit --no-guess $(PROBLEM_URL) $(FNAME)",
  languages = { cpp = "54", python = "31" },
}
```

**`$(PROBLEM_URL)`, not `$(URL)`, is the one to reach for here**, and the distinction
is why both exist. `$(URL)` is what the submission is routed *through* — for a
Codeforces round downloaded from a mirror it is that mirror's, and it is deliberately
shaped for a submitter that derives its own `…/submit/<index>` from a problem URL, so
it ends in a bare `/problem/`. `oj` is given a problem's address and works out the
submit page itself, so it wants the problem's own identity, which is what
`$(PROBLEM_URL)` always is (verified: the same buffer expands to
`oj submit … https://codeforces.com/contest/2248/problem/A A.cpp` whether or not the
sidecar records a live mirror, while `$(URL)` becomes
`https://m1.codeforces.com/contest/2248/problem/`).

One caveat that is not tuna's to fix: **AtCoder gates submission behind a Cloudflare
Turnstile challenge** that no headless client solves, `oj` included. That is what the
`browser` provider is for — `submit.judges.atcoder = { provider = "browser" }` opens
the preselected submit page and copies the source to the clipboard.

```lua
submit = {
  provider = "command",
  command  = 'subwithoutcred "$(URL)" "$(LANG)" "$(FABSPATH)"',
  url          = "submit at:%s*(%S+)",  -- header marker (a template writes it), or a function
  languages    = { cpp = "C++", python = "Python 3", ... },  -- filetype -> submit tool's lang name
  terminal     = "auto",   -- toggleterm if installed, else a native :terminal split
}
```

Design notes:

- **Provider registry** (`M.providers[name]`) leaves a clean seam for future
  first-class providers (e.g. a Kattis provider). The shipped default is
  the `command` provider, which expands a shell command through the modifier engine —
  gaining `$(URL)` and `$(LANG)` on top of the usual `$(FABSPATH)`/`$(FNAME)`/… — and
  runs it in a terminal.
- **URL resolution** is header-marker-first with a sidecar fallback: it scans the
  file header for a configurable marker (e.g. `submit at: <url>`, which a template
  embeds via the existing `$(URL)` download modifier), and if absent reads a
  per-problem sidecar (`.tuna.json`) that the download path now writes with the task's
  URL. So both templated and freshly-downloaded problems are submittable with no manual
  URL entry.
- **Terminal** prefers a cached toggleterm (mirroring the common setup) but falls back
  to a native `:terminal` split, so toggleterm is detected-and-used, never required.
- **lualine verdict (watch mode)**, matching the listener's `status()`/`is_downloading()`.
  With `submit.watch = true` the command runs as a tracked `vim.system` job (no
  terminal); tuna strips ANSI from its stdout, takes the latest `\r`/`\n` status
  segment, and classifies it via the ordered `submit.verdicts` `{ pattern → state }`
  rules into a live `Testing → Accepted / Wrong Answer / …` verdict. State is **kept
  per solution buffer and persists until the next submit** — so the indicator is bound
  to a problem, not a timer — colored by verdict via `submit.verdict_hl`
  (`TunaCorrect`/`TunaWrong`/`TunaWarning`). This turns submit into a full
  no-terminal loop for tools that poll a verdict (e.g. the Rust `submitter`); a run
  that reaches no final verdict surfaces an `error` state + a notification. The
  default (no `watch`) keeps the fire-and-forget terminal with a brief pending flash
  (`status_time`), for submit tools that don't report a verdict.
- **Persists across restarts, invalidated on edit.** A final verdict is written into
  the per-problem sidecar (`.tuna.json`, alongside the URL/name) keyed by file name,
  with the source's mtime. On `BufReadPost` the verdict is restored into lualine —
  unless the file was edited since (mtime mismatch) — and it's dropped the moment you
  edit the buffer (`TextChanged`), because a verdict no longer describes changed
  source. So the indicator is genuinely bound to *this* problem's *submitted* state.

**Why:** submitting is the last manual step in the loop; folding it into the plugin
(configurably, not hardcoded to one tool) removes the last reason to drop back to a
shell, and the provider seam keeps it open to new judges.

---

## A run with no testcases runs the program

✅ **Decision:** `:Tuna run` on a file with **no testcases at all** runs the solution
once on empty stdin, rather than refusing — as an editable row that becomes the
problem's first testcase as soon as you type into it.

competitest answers "no testcases found" and stops, so using it to simply build and
execute the file you are looking at means first creating a dummy empty testcase by
hand. tuna's runner already models a testcase with no input — an answer-only testcase
runs against empty stdin — so the run with nothing at all is the same shape, and it
costs one process that can go nowhere: the row has **no expected output**, so its
verdict is `DONE` and can never read `CORRECT`. A problem whose testcases failed to
arrive therefore can't be mistaken for one that passed, and the row label says what
happened, so nothing needs notifying.

The row is **testcase 0** — nothing is on disk, so the number is free — and editable
like any other, which is the second half of the idea: the fastest way to write the
first testcase for a problem is to run the thing, read what it printed, and type the
input and the answer you wanted into the panes. `:w` stores it and re-runs, and from
then on it is an ordinary testcase. Until it has something behind it the selector calls
it `No input` rather than `TC 0`, so the label explains why the row is there instead of
claiming a file that doesn't exist; it becomes `TC 0` the moment there is an unwritten
edit or a saved file. Pressing `n` on an untouched bare row reuses it rather than
adding a second empty testcase beside it, which would take number 1 and leave a gap.

It also settles an inconsistency that had nothing to do with the feature: with no
testcases a **compiled** file was built and shown a lone `Compile` row with nothing
saying why the results were empty, while an **interpreted** one only warned — two
different non-answers to the same question, neither of which ran anything.

Making rows editable means the UI can now disagree with the disk, in two directions,
and neither is allowed to happen quietly.

**A save that clears a half.** A `:w` stores what the panes show, and it stores the
testcase **even when both halves are empty** — an empty testcase is a testcase, and
removing one is `x`, which is one key and undoable. So there is nothing to ask about an
empty *input*: for an input, empty and absent are the same thing, since the solution is
fed `""` either way.

The **answer** is the sole exception, and this is where competitest has no answer at
all. An absent answer means the testcase is not judged (the verdict is `DONE`); an
answer that is present and empty means the solution must **print nothing**, and one that
prints something is `WRONG`. Neither is expressible without the other, and only file
presence can tell them apart — which is why the load path keeps an empty answer as it
finds it while normalizing an empty input away.

The panes look identical either way, so a save that would turn a **real** answer into an
empty one asks which was meant: `Don't specify output` / `Expect empty output` / `Keep
editing`. It asks only then. An answer that is already absent, or already empty, is not
changing, so it goes on meaning what it meant — which is what keeps a first save silent
and keeps re-saving a testcase from raising the same question over and over.

That is the whole of it: one question, one shape, one trigger. An earlier version had
three prompt shapes whose choice depended on what happened to be stored, so the same two
empty panes could produce two different dialogs — which is exactly the kind of rule a
user has to reverse-engineer instead of read off the screen.

**A testcase file that changes under an open UI.** The results UI keeps its rows across
a re-run — that is what makes it a results view rather than a fresh load — so anything
touching the testcase files behind its back (another Neovim, `:Tuna clean`, a checkout,
a plain `rm`) leaves rows describing a state that is no longer there. A fresh
`:Tuna run` reloads from disk and the question never arises. Two shapes, and they get
deliberately different answers.

**Changed** is not a question. The file is the truth and the row is a cache of it, so
the row is reloaded before the run — which is exactly what a fresh `:Tuna run` would
have done, while running the stale text would report a verdict for input the user has
already replaced. Either half counts: an answer edited on disk with the input left alone
is the half that decides the verdict. It is said once rather than shown, being an event
rather than a state.

**Missing** is. The testcase is gone and the row is the last place its text exists, so
dropping it is not undoable and the choice is the user's: `Restore and re-run` /
`Discard` / `Stop`. `Discard` only discards — the row being re-run may be the one going
away, so a label promising a re-run could not keep it, and the re-run is one keypress
away once the UI says the truth. Restoring writes each row back to its own number **when
that is still free, and to the lowest free one otherwise**, renumbering the row to match
and saying so — an older row the UI happened to still be holding must never overwrite a
newer testcase that took its number in the meantime. The restore is a rescue, not a
rollback.

Rows that legitimately have no file are neither — the bare row, a row added with `n` and
never saved, one whose edit is still unwritten. Those are testcases being *written*, not
testcases that drifted, and the last of them is excluded for a second reason: reloading
it would throw the edit away.

Not a configuration option. The behaviour it replaces is a refusal, the replacement
can't produce a wrong verdict, and `:Tuna run 5` naming a testcase that doesn't exist
is kept separate: an explicit list that resolves to nothing reports each missing number
and stops, since "run this file" and "run testcase 5" are different questions.

**Why:** a solution file is a program, and running it is worth a keystroke even before
it has testcases — the minutes before a contest opens, a scratch file, a helper being
eyeballed. Requiring a dummy testcase to get there is ceremony for its own sake, and
once the run is on screen the dummy testcase is the row you are already looking at.

---

## Runner UI: native windows, simpler hide/show

✅ **Decision:** the runner results UI (`runner_ui/`) is built on native floats
and splits, sharing competitest's recursive `{ ratio, child }` layout engine but
none of its `nui.nvim` window objects.

Two simplifications fall out of going native:

- **Close-and-rebuild instead of hide-and-restore.** All displayed content lives
  in the runner's `tcdata`, so closing the UI just tears the windows down and
  showing it rebuilds and re-renders. competitest preserved hidden `nui` buffers
  and re-showed them; tuna doesn't need to, which removes a layer of state.
- **Split `relative_to_editor` is approximate.** competitest's `nui.split` could
  anchor a split to the editor edge regardless of the current window; the native
  `nvim_open_win({ split = … })` splits a specific window. tuna splits off the
  runner's window, which coincides with the editor edge in the usual
  single-window competitive-programming layout.

A native gotcha worth recording: a float's `row`/`col` anchor its **content**,
with the border drawn outside, so the popup layout offsets each window by +1 to
make footprints tile exactly. And because the viewer popup *borrows* a detail
pane's buffer, the UI's `:q` handling is keyed on **window id**, not buffer —
otherwise closing the viewer would tear down the whole UI.

**One UI, many run modes (`runner/core.lua`).** Every run mode — normal, stress,
interactive, and later run-all — drives the *same* `runner_ui` through a shared
`RunnerCore` base rather than each mode reimplementing the UI plumbing and the
spawn-and-judge routine. A mode subclasses the base and supplies only its own loop
(parallel lanes / a generation search / interactive sessions); the UI stays
mode-agnostic through two seams — `runner:pane_content(name)` (what each pane shows,
or `SKIP` to leave it alone) and `runner:on_ui_shown(ui)` (augment the built UI, e.g.
interactive making the Input pane editable). This is what lets interactive get a
first-class results UI for a few dozen lines instead of a fourth copy of the runner.

**A layout may leave panes out.** competitest builds the results UI by walking a
fixed set of panes and asking the layout where each one goes, so a layout that omits
one — the Errors pane, say — breaks:
someone arranging `tc | so | eo` over `si` finds they cannot drop `se`. Which panes to
show is exactly the kind of thing a layout option exists to decide.

In tuna a pane always gets a **buffer** and only sometimes a **window**: the buffer is
where the runner's output goes, so an unplaced pane still collects its content and can
still be opened in the viewer (`e` for the errors, and a failing compilation still pops
its stderr up) — it just isn't on screen taking room. `runner_ui/layout.lua` resolves a
configured layout once, shared by both interfaces, and reports which panes it places;
the interfaces open windows for those and skip the rest.

The same resolver validates: unknown pane names, a pane placed twice, malformed
`{ ratio, child }` entries, or a layout without `tc` (the selector owns the cursor and
the keymaps, so it is the one pane that cannot be dropped) fall back to the shipped
default with a single warning naming the problem. A typo in a layout costs the
arrangement, not the results UI.

**The default arrangement pairs panes by what they are for.** Two panes in this UI
can be typed into — Input and Expected Output — and they wear an accent saying so;
two others are read against each other — Output and Expected Output — because the
diff is positional and compares line *i* to line *i*. The shipped layouts satisfy
both: `so`/`eo` share the **top row**, so the comparison is read across rather than
along a diagonal, and `eo`/`si` share the **right column**, so everything editable is
one block at the edge instead of two opposite corners:

```
+-----------+----------+----------+
| Run       | Output   | Expected |  <- accented
| Testcases |          |          |
|           +----------+----------+
|           | Errors   | Input    |  <- accented
+-----------+----------+----------+
```

Stacking the editable pair *horizontally* is not an alternative arrangement, it is a
different trade: putting `si` beside `eo` necessarily pushes `so` off that row and
splits the pair the diff exists to line up. All three shipped layouts
(`popup_ui.layout`, `split_ui.vertical_layout`, `split_ui.horizontal_layout`) use the
same pairing, so the grid doesn't rearrange itself when the interface changes.

**The UI opens on what there is to read.** competitest always parked the cursor on
the first row, which is the compile step. A compilation that printed warnings or
failed is worth landing on — but a silent one leaves four empty panes in front of
someone who opened the UI to see a verdict, one keypress away from the row they
wanted — and the same is true before any run, where `:Tuna show_ui` doubles as a
testcase viewer and the testcase is the whole point of opening it. So `initial_row()`
starts on the first testcase whenever the compile step has no output. The compile row
is kept only when it printed something, or while a run is still in flight — moving the
cursor as results land would take it out from under the user.

**A diff that doesn't re-align (`diff.lua`).** competitest's diff view is Vim's
`:diffthis` over the Output and Expected Output panes, so it computes an *edit
script*: it may decide a line was inserted or deleted and re-pair everything after
it. That is right for source code and wrong for a program's output. With `2 2 0 2`
against `2 2 2 5` it reports line 3 as deleted and then pairs your line 4 with the
answer's line 3 — two wrong values become one deletion plus a coincidence, and the
rest of the output drifts out of step with the answer sheet.

Competitive-programming output is **positional**: the i-th line answers the i-th
line, and inside a line the i-th token answers the i-th token. So tuna computes the
comparison itself, in lockstep, and never re-aligns: it marks the values that
disagree exactly where they are and judges the following lines on their own merits.
The lines one side has and the other does not are marked as such, in place, instead
of shifting anything.

The granularity **follows the compare method in effect**, so the highlighting can
never contradict the verdict: `exact` descends to characters (a stray space is
marked, because it loses the testcase), `squish` and `{ "float", tol }` compare
tokens — spacing is not a difference, and a value within tolerance is not one either.
A custom compare function gets the token view, as a reading aid.

Presentation-wise the two panes stay side by side (this is the choice
users asked to revisit; the pane layout was never the problem, the alignment was). They need none of the
filler lines `:diffthis` inserts, since line *i* faces line *i* by construction — so
they are simply `scrollbind`/`cursorbind`ed together. Toggling the diff on also jumps
both panes to the first disagreement, which with a hundred lines of output is the
reason one opens a diff at all.

Colours: the line-level groups (`TunaDiffChange`, `TunaDiffAdd`, `TunaDiffDelete`)
link to the editor's own diff groups, so a diffed line looks like a diffed line in
whatever colorscheme is loaded. The disagreeing values (`TunaDiffText`) deliberately
do **not** link to `DiffText`: in most themes that is a *neutral* background, and a
neutral background laid over an already-highlighted line reads as *selected* rather
than *wrong*. Instead the text keeps its own colour and the background behind it is
**tinted red** — the `WRONG` red mixed into the editor's own `Normal` background at
roughly a third, so the mark is unmistakably red without a saturated block shouting
louder than the value it points at, and it lands at the same strength on a dark theme
as on a light one. It is re-derived on every `ColorScheme`, so a theme switch retints
it rather than leaving a colour from the old palette.

### Always-editable testcases in the results UI

competitest can only add, edit or delete a testcase from *outside* the results UI,
through a separate editor popup. Users have asked for that to happen inline instead,
and an upstream pull request (closed, unmerged) proposes a `NEW` row plus
`<CR>`/`<C-s>`/`<C-CR>`/`x` bindings.

tuna already listed testcases in the results UI before any run (`:Tuna show_ui`
doubles as a testcase viewer), so the missing half was making that view writable.
It does so **without inventing an editing mode or an editing key**: the Input and
Expected Output panes are plain modifiable buffers, and

```
move into the pane · type · :w
```

saves the testcase and re-runs it. `:w` is a `BufWriteCmd`, so it is the same gesture
that saves any other buffer in Vim — no `<C-s>`, and in particular no `<C-CR>`, which
most terminals cannot even deliver (that proposal's sole reviewer hit exactly that).

Everything else follows from treating the panes as buffers:

- **Nothing reaches disk until `:w`.** Unwritten edits are held per testcase number,
  so switching rows keeps them (the row shows its own pending text when you come
  back, and the diff compares what is on screen), a `VimResized` rebuild keeps them,
  and results landing on a row you are editing cannot overwrite what you typed.
- **One dialog, on close only** — Save / Discard / Keep editing — because closing is
  the one moment an unsaved edit would actually be lost. Routine editing never asks
  anything, which is the request's spirit; silently discarding it would not be.
- **Adding and deleting** get a key each, since a selector row carries no text you
  could author: `n` appends a row and drops you in the Input pane, `x` deletes.
  Deletion is **immediate but undoable** (`u`) rather than confirmed — an undo is
  cheaper to press than a dialog *and* recoverable, which a dialog is not. Both wait
  for a run in flight, as they renumber the rows its lanes are indexing.
- **No phantom `NEW` row.** That proposal's trailing row lives in the testcase list's own
  coordinate space, so `get_testcase_index_by_line` returns the *string* `"NEW"` and
  five call sites have to guard against it. Discoverability instead comes from one
  row in the "Run" pane — a key hint when clean, the unsaved-testcase warning when
  not — and `?` for the full legend, which also documents the eight pre-existing keys
  that had no legend at all.
- **Scope is a runner property, not a special case.** Normal, stress and run-all are
  editable; interactive is not (its Input pane is the channel to the solution). A row
  is editable only if it carries a numeric testcase number, which excludes the
  Compile row and run-all's solution headers without naming them anywhere. In
  run-all's matrix a testcase belongs to every solution, so adding or deleting one
  does so for all of them and a save re-runs each solution's row for it.
- On an editable pane the single-letter mappings are **not** bound (`q` is the letter
  q there), and the pane-switch keys work from insert mode, so a pane you are typing
  in is still leavable.

The UI also now **reopens on the row you were last on** (matched by row identity, so
it survives the rows being rebuilt by a re-run), falling back to the existing
"skip a silent Compile row" rule on a runner's first open.

---

## `init.lua`

- **Modern autocmd/highlight APIs.** competitest registered its command,
  completion, `ColorScheme`/`VimResized`/`VimEnter` autocmds, and highlight
  groups through `vim.cmd`/`nvim_command` string blocks (including a Vimscript
  `s:command_completion` function). tuna uses `nvim_create_user_command`,
  `nvim_create_autocmd` under a cleared `Tuna` augroup, and `nvim_set_hl` with
  `default = true` (the API equivalent of `hi! def`). Completion is a Lua
  function in `commands.complete`, not Vimscript.
- **`once = true` VimEnter.** Persistent-download-on-setup before startup is wired
  with a one-shot `VimEnter` autocmd instead of a self-persisting `autocmd
  VimEnter` line; it fires exactly once and needs no manual cleanup.
- **Lazy requires in callbacks.** The command and completion callbacks
  `require("tuna.commands")` at call time rather than at module load, keeping
  `setup()` startup cost minimal (a project goal) and avoiding load-order cycles.

---

# Phase 3 — extensions beyond competitest

New capabilities tuna adds that competitest never had. (See the Phase 3 roadmap.)

## Helper programs by convention + run modes (`tools.lua`)

✅ **Done.** The stress/checker/interactive extras originally forced a `.tuna.lua`
per problem, spelling out each helper as a command spec — which pushed people toward
**shell** checkers. That's backwards from how competitive programmers actually work
(see ali-ibrahim137's stress-testing article): the generator, brute/reference,
checker and interactor are ordinary **source files in the solution's own language**.

`tools.lua` makes that the default. Helpers are discovered **by filename
convention** beside the solution — `checker.*`, `gen.*`, `brute.*`, `interactor.*`
(aliases and names configurable via `tool_names`) — then compiled and run with the
**same config-driven commands as a solution of that language** (so a Python helper
beside a C++ solution just works). A source checker is compiled **once**, on first
use, and cached (`tools.prepare`), so parallel judges don't recompile or race.
Config specs still override discovery, and a prebuilt binary / shell script still
works — but no `.tuna.lua` is required to stress-test or special-judge.

Because you no longer flip modes by editing config, tuna adds a **per-buffer run
mode**: `:Tuna run [normal|all|stress|interactive]`. A bare `:Tuna run` **auto-detects
the mode from the sibling files** — an `interactor.*` ⇒ interactive, a `gen.*` +
`brute.*` pair ⇒ stress, otherwise normal — so dropping the right helpers next to
the solution is enough. Passing a mode explicitly (or picking one in the `:Tuna`
menu) **pins** it, so later bare `:Tuna run`s repeat it; but if the files that mode
needs are later deleted, tuna falls back to auto-detection rather than failing on a
now-impossible mode. A **checker toggle** (`:Tuna checker [on|off]`, or the menu)
turns special judging off for a buffer without deleting `checker.cpp`. competitest
had a single `:CompetiTest run` and no notion of modes or helper discovery.

### The run state persists per problem

How a problem is run — its compare method (`:Tuna compare float`), the checker
toggle, the pinned mode and the interactive source — is a property of **that
problem**, not of the editor session. So it is stored in the per-problem sidecar
(`sidecar.lua`, `problem_store_file`) and comes back after a restart. The case that
forced it: a float-tolerant problem where you set `:Tuna compare float`, iterate for
an hour, restart Neovim, and silently go back to exact comparison — every testcase
then reads as wrong for reasons that have nothing to do with your solution.

The sidecar was already there (the downloaded task's url/name/group, the last submit
verdict per file), so this adds a `run` section beside them, keyed by file basename
like the verdicts — which also keeps two problems that share a directory (`a.cpp`,
`b.cpp`) apart. It is deliberately not a global registry under `stdpath("state")`:
that would key on absolute paths that go stale the moment a contest folder moves,
would accumulate an entry for every problem ever opened, and would not travel with
the problem. (`recent.lua` uses exactly that state file, correctly — "where was I" is
per machine, not per problem.)

Nothing is written until a setting differs from the defaults, and clearing one back
(`:Tuna compare default`) removes its entry and, when nothing else remains, the file
— so an untouched problem never grows a sidecar. Reads are validated, because the
file is plain JSON a user may edit or copy between problems; and a pinned mode still
degrades to auto-detection when the helper files it needs are gone.

## Pluggable checkers (`checker.lua`)

✅ **Done (Workstream 1).** competitest could only decide a verdict by comparing
program output against the expected output (`exact` / `squish` / a custom Lua
function). tuna keeps that as the `"builtin"` checker but adds support for an
**external, testlib-style checker program** — usually a **source file in the
solution's language**, discovered as `checker.*` and compiled automatically:

```lua
checker = "builtin"    -- default: plain comparison, OR a discovered checker.* if present
checker = "~/cp/checkers/wcmp"                       -- an explicit checker binary
checker = "$(ABSDIR)/checker.py"                     -- an explicit checker source file (compiled if needed)
checker = { exec = "$(ABSDIR)/chk", args = { ... } } -- full control over a prebuilt binary
```

With the default `"builtin"`, dropping a `checker.cpp` (or `checker.py`, …) next to
the solution switches that problem to special-judge mode with no config; the
per-buffer checker toggle (`:Tuna checker off`) forces plain comparison back on.
An external checker is invoked as `checker <input> <output> <answer>` (the testlib
convention: jury input, participant output, jury answer); exit code `0` is correct,
anything else is wrong, and its stderr/stdout becomes the verdict message
(`tc.checker_message`). The three files are passed through the `$(INPUT)`,
`$(OUTPUT)`, `$(ANSWER)` placeholders in `args` (defaulted when omitted).

**Why it's the foundation:** stress testing, interactive problems, and
multiple-solution problems all need a verdict that isn't plain string equality, so
the runner now routes every clean exit through `checker.judge` instead of calling
`compare` directly. Because an external checker is a separate async process, the
runner tracks a per-testcase `judging` flag so a run isn't declared complete before
its verdict lands.

### Builtin float-tolerant comparison

competitest's only tolerant option was `squish` (whitespace-insensitive but still an
**exact** textual match), so floating-point problems forced you to write a custom
`output_compare_method` function or a full checker. tuna adds a builtin `"float"`
method selected as a table carrying its options:

```lua
output_compare_method = { "float", tol = 1e-6 }   -- default tol is 1e-6
```

It compares token-wise: a numeric token matches when it is within `tol` **absolute
or relative** error of the expected token, while any non-numeric token (or a
numeric-vs-text mismatch, or a differing token count) must match exactly. So
`YES\n3.1400001` passes against `YES\n3.14` but `NO` never passes against `YES`.
The table form (`{ builtin, opts... }`) is the general shape for any option-bearing
builtin; `exact`/`squish`/custom-function all still work unchanged.

The method can also be switched **at runtime, per buffer**, without touching config
— `:Tuna compare <exact|squish|float [tol]|default>` (e.g. `:Tuna compare float 1e-9`;
`default` clears back to the configured method), and a **Compare** entry in the
bare-`:Tuna` menu that cycles the methods. This mirrors the per-buffer `:Tuna checker`
toggle (state in `tools.lua`, keyed by file path), so a float problem needs neither a
config edit nor a local `tuna.lua`. competitest had no runtime way to change the
comparison method at all.

## Stress testing (`stress.lua`)

✅ **Done (Workstream 2).** Brand new — competitest has no stress testing. `:Tuna
run stress [count]` hunts for a small input on which the current solution disagrees
with a trusted reference. By convention it uses a sibling `gen.*` (generator) and
`brute.*` (reference) — **no config needed**; the `stress` table only overrides:

```lua
stress = {
  generator = nil,    -- override discovery, e.g. { exec = "python3", args = { "$(ABSDIR)/gen.py" } }
  reference = nil,     -- override discovery: a correct-but-slow solution
  count = 100,         -- max generator iterations
  seed_arg = true,     -- append the iteration number as the generator's last arg
  saves_per_run = 1,   -- counterexamples to save per run before stopping
  max_saved = 10,      -- hard cap on the total testcase count stress will grow to
}
```

Each iteration: the generator is run with a reproducible seed (the iteration
number) → its stdout is the input → the solution and the reference both run on it →
their outputs are judged with the **same `checker`** the runner uses (so
multiple-correct-answer problems — and any custom checker — work here too). A wrong
answer, crash, or timeout is **saved as a new testcase** (input + the reference's
answer as expected output).

Unlike a bare "find one and stop", stress opens its **own results UI** — the same
`runner_ui` the normal runner uses — that first re-runs the problem's existing
testcases and then appends each counterexample as it's found. Its status pane shows
the run mode, the verdict source, the live iteration count, and both save
thresholds. The search stops as soon as either threshold is hit: `saves_per_run`
counterexamples saved this run, or `max_saved` total testcases on disk. Inside the
UI you can re-run a single (saved) testcase, restart the whole search, or stop it.
A `StressRunner` implements just enough of the `TCRunner` surface (`tcdata`,
`mode`, `judge_label`, `kill_*`, `run_single`, `run_testcases`, a `status_text`)
for the UI to drive it.

**Reuse, not reinvention:** `stress.lua` calls `runner.new()` to resolve the
solution's compile/run commands, working directories, and checker, then drives the
loop with `vim.system` (using its `timeout` option) and `checker.judge` from
Workstream 1.

**Compile cache (`tools.prepare`).** Helpers (generator/reference/checker/…) are
compiled through a *persistent, session-wide* cache keyed by the source's absolute
path + mtime + exact compile command. So a repeated `:Tuna run stress` recompiles
only what actually changed (usually just the solution) and reuses the unchanged
`gen`/`brute` builds, keeping the edit-and-re-run loop fast. Editing a source, or
changing its compile flags, invalidates the entry and rebuilds.

📌 **README note — recommended C++ setup (precompiled `bits/stdc++.h`).** Tuna
compiles helpers with the *same* command as `:Tuna run` (the per-language
`compile_command`), so a precompiled-header setup is honoured everywhere (normal
run, stress, run-all, checkers). We should recommend, in the README, the
competitive-programming standard of a precompiled `<bits/stdc++.h>`: e.g. a
`~/cp/bits/stdc++.h.gch` built with the *exact* flags used in `compile_command`
(`-std=… -DLOCAL -Wall … -I$(HOME)/cp`), and `#include <bits/stdc++.h>` in the
solution/helpers. Because stress compiles three programs (solution + generator +
reference), the PCH is what keeps that fast — without it each translation unit
re-parses the whole standard library. (Verified: with the PCH, three heavy TUs
compile in ~2.6 s vs ~6.9 s without.)

## Interactive problems (`interactive.lua`)

✅ **Done (Workstream 2).** Brand new — competitest can't run interactive problems
at all, and can only *drive* them with a written interactor. tuna's
`:Tuna run interactive [live|feed|interactor] [n…]` offers **three sources** for the
other side of the conversation, in its own results UI:

- **live** — *you* are the other side. The solution's stdout streams into the Output
  pane; you type into the (editable) Input pane and each `<CR>` line is sent to the
  solution's stdin. No auto-verdict — you read the transcript. This is the common
  case (poke at the solution by hand) that competitest has no answer for.
- **feed** — a pre-written input plays the other side **one line per turn**: each
  time the solution emits a line, the next input line is sent. Judged against the
  expected output if the testcase has one, else DONE.
- **interactor** — a written `interactor.*` program (or `interactive.interactor`) is
  cross-wired to the solution and rules the verdict. Secondary: auto-used only when
  an `interactor.*` sibling exists. The chosen source is remembered per buffer, so a
  bare `:Tuna run` repeats it.

```lua
interactive = { interactor = nil } -- override, e.g. { exec = "python3", args = { "$(ABSDIR)/interactor.py" } }
```

In interactor mode the solution and interactor are spawned and their pipes are
cross-wired — solution stdout → interactor stdin, interactor stdout → solution stdin
— and the interactor's exit code is the verdict (0 = CORRECT). The interactor gets
the testcase input/answer as files via the `$(INPUT)` / `$(ANSWER)` placeholders.

**Native-pipe gotcha worth recording:** `vim.system` only surfaces a child's stdout
once it *exits*, so it can't relay bytes between two live processes. tuna drops to
`vim.uv.spawn` and forwards data between the pipes by hand, shutting down a peer's
stdin on EOF and guarding every write against a pipe that teardown has already
closed. A timeout timer and the interactor-exits-first / solution-crashes-first
orderings are handled explicitly.

## Multiple-answer problems (the external checker)

✅ **Done.** A problem that accepts several valid outputs (e.g. "print any shortest
path", or "print two numbers that sum to 3" → both `1 2` and `2 1`) is handled by the
checker. competitest's custom comparator was `function(output, expected)` — it never
saw the **input**, so it couldn't validate input-dependent answers; its maintainer
proposed passing the input as a third argument in that thread, and it was never
implemented. tuna's checker is a **testlib-style external program** that receives the
input, participant output, and jury answer (`checker <input> <output> <answer>`) and
decides the verdict — the standard special judge every judge/testlib user already
knows. It's discovered by convention (`checker.*`) or set via
`checker = { exec, args }` / a path, and the same capability flows through
`:Tuna run`, `run stress`, `run interactive`, and `run all`.

That last point is the thread's own conclusion, reached over a month of comments: what
is wanted is something that generates inputs, receives the solution's output, and
validates it *against the input* — which is stress testing driving the same checker.
It works out exactly as they describe. On "print any permutation of `1..n`", with a
sample answer of `1 2 3 4` and a solution printing `4 3 2 1`:

| | plain run | stress, 12 random inputs |
| --- | --- | --- |
| builtin comparison | `WRONG` | 4 "counterexamples", all spurious |
| sibling `checker.cpp` | `CORRECT` | none — `no counterexample found in 12 runs` |

The checker's own message (`ok, a valid permutation of 1..4`) is surfaced in the
results UI. Nothing is configured in either case: the file is found by name.

## Multiple solution versions (`multi.lua`, `:Tuna run_all`)

✅ **Done.** Keep several attempts side by side (`main.cpp`, `slow.cpp`, …) and
`:Tuna run all` compiles and runs *every* runnable sibling solution — **of any
language** (each file's compile/run commands come from its own filetype, so a C++
and a Python attempt run side by side) — against the shared testcases. Helper files
(`checker.*`, `gen.*`, `brute.*`, `interactor.*`) are excluded so they aren't
mistaken for solutions. competitest only ever ran the current file. (This is distinct
from multiple-*answer* support above — here it's multiple *programs*.)

Results show in the same `runner_ui` as every other mode, laid out as a **flattened
matrix**: a solution header row (name + a live `correct/total`) above its indented
per-testcase rows. Selecting a testcase row shows that exact run in the detail panes;
selecting a solution row shows its per-testcase summary and any compile output. A
solution that fails to compile is a `CE` row (its cases marked `—`), surfaced in the
UI rather than as an error popup — so one broken attempt doesn't abort the batch.

## Scaffolding (`scaffold.lua`, `:Tuna scaffold …`)

✅ **Done.** `:Tuna scaffold <checker|generator|brute|interactor> [ext]` drops a
dependency-free starter (no testlib needed) into the problem directory and opens it,
giving a clean on-ramp to the convention-named helpers that stress testing, special
judging, and interactive problems discover. The file is created in the **solution's
language** by default (or the language named by `[ext]`); built-in templates ship
for C++ and Python, and both the base filenames and the templates — per kind and
**per language** (`{ [ext] = path }`, like `template_file`) — are overridable via
`config.scaffold`. competitest had nothing comparable.

## The `:Tuna` dashboard (`dashboard.lua`)

✅ **Done (evolving, W8).** Bare `:Tuna` (or `:Tuna dashboard`) opens a native chooser
that switches the buffer's **run mode**
(normal / run-all / stress / interactive), toggles the checker, cycles the compare
method, shows the results UI, scaffolds a helper, or cleans unused files — so the
Phase 3 features are discoverable without memorising subcommands, and picking a mode
here is what a later bare `:Tuna run` repeats. In competitest a bare `:CompetiTest`
was an error. This started as an inline "mode-switcher menu" and has been promoted to
its own `dashboard.lua` — the seed of the fuller contest hub (problem navigation,
at-a-glance status) it will grow into.

## Clean unused files (`clean.lua`, `:Tuna clean`)

✅ **Done (W5).** A competitive-programming workflow accretes clutter: every downloaded
or templated problem drops a solution file, and `:Tuna scaffold` drops helper stubs —
many of which are never touched. `:Tuna clean` sweeps them up. The catch competitest
never had to solve is that these files **aren't empty** — they carry a template — so
"unused" is defined as *"content still matches the template that would generate it."*
tuna turns the template into a pattern with each `$(...)` modifier as a wildcard, so
it recognises an untouched file whether the template was copied verbatim (modifiers
left literal) or expanded via `evaluate_template_modifiers`; scaffolds are matched
against their `scaffold` template, solutions against `template_file`, and a
template-less file is unused only when empty. The entire interaction runs through
tuna's **floating widgets, not `vim.ui.input`/`confirm` command-line prompts**: a
single **form** (three stacked lists shown at once — Tab / `<M-j>`/`<M-k>` switch,
`<CR>` submits all) picks the directory (prefilled with the roots derived from the
`downloaded_*`/`template_file` config, plus "Other directory…"), the recursion depth
(infinite by default, or a custom number), *and* the **match threshold** — because
"unused" is measured as a **similarity percentage** to the template (a line-LCS
ratio), the user can erase files that are, say, ≥ 95% the template (full match / 95% /
custom), not only byte-for-byte untouched ones. Then a **per-file confirmation menu**
(Delete / Keep / Stop, showing each file's match %) — with a **read-only preview of
the file rendered beneath the prompt** (scroll with `<C-d>`/`<C-u>`) — guards every
deletion. Form/list navigation uses the plugin-wide pane keys (`switch_window_keys`,
default `<C-hjkl>`). Clean may delete the file it was launched from and stays robust:
the file's buffer is wiped afterwards (kept, if it has unsaved edits). competitest had
no cleanup facility at all.

Build artifacts are handled here rather than after every run. Deleting the compiled
binary once the testcases finish is the obvious way to stop a problem directory filling
up with them, and it is wrong for tuna: `:Tuna run_no_compile` exists precisely to reuse
the build, and `r`/`R` in the results UI re-run the existing binary without recompiling
— remove it and they answer `FAILED` (measured). So the binary stays, and `:Tuna clean`
disposes of it along with the problem, treating the build output of a solution it has
*just removed* as disposable in the same way testcases and the sidecar are. Without that
the binary kept the directory alive and left the testcases stranded in it, so the litter
survived the very command meant to remove it.

Keeping binaries out of the problem directory in the first place needs no option either:
point `compile_directory` and `running_directory` at a build directory and name the
output after the problem, which works now that an absolute or `~`-prefixed value is
honoured.


## Health check (`health.lua`, `:checkhealth tuna`)

✅ **Done (W7).** tuna ships a `lua/tuna/health.lua` so `:checkhealth tuna` gives a
one-shot diagnosis of a setup — the single biggest self-service answer to "why
doesn't it work?" It reports the Neovim version (errors below 0.10, since tuna needs
`vim.system`/`vim.uv`), whether `setup()` ran, which configured compilers/interpreters
are actually on `PATH` (skipping per-problem build outputs like `./$(FNOEXT)` that
don't exist pre-compile), the Competitive Companion listener port + live state, the
submit tool's presence (and, for the browser provider, clipboard availability), and
optional integrations (toggleterm/lualine). It is read-only — it never spawns a
compiler or touches state. competitest had no health check; users diagnosed broken
setups by trial and error.

## Download duplicate handling in the floating UI

✅ **Done.** When a downloaded problem or contest would overwrite existing files,
competitest asked with a command-line `confirm`. tuna keeps the whole download flow in
its floating widgets: a duplicate **problem** shows an `Override`/`Stop` menu, and a
**contest** shows a *single* `Override all`/`Stop` menu for the whole batch (resolved
up front by scanning every target path) rather than one prompt per problem — decide
once for the contest. Dismissing either (Esc) counts as "stop" and, via the menu's new
`on_close` hook, still advances the batch processor so a cancellation never wedges it.

## Getting around: contest navigation and `:Tuna last …`

✅ **Done (W6).** competitest could download a contest but had nothing for *moving
around* one: finding the next problem, or getting back to what you were doing after
closing the editor, was `:e` and a file browser. tuna ships both.

`:Tuna next` / `:Tuna prev` (`navigate.lua`) step to the problem either side of the
current one — the sibling directory in name order — opening the file that matches
what you are leaving (same name, then same extension, then any runnable non-helper
source), so a contest is walked without leaving the editor and a problem attempted in
another language is still reachable.

`:Tuna last problem` / `:Tuna last contest` (`recent.lua`) go back to what you were
working on, **and change Neovim's directory to it** (`cd_command`: `cd` by default,
or `tcd`/`lcd`/`false`). The cd is half the feature: coming back to a problem means
working *in* it, so `:e`, a fuzzy finder and `:Tuna run all` from a scratch buffer
should all be pointed at that problem rather than at wherever the editor was started.
The state is persisted under `stdpath("state")`, so this survives a restart — the case
it exists for. It is not limited to what tuna itself opened: any solution buffer whose
directory holds testcases or a downloaded-problem sidecar counts as "the problem you are
on", while a template, a library file or the `:Tuna temp` scratch never does. The
contest is recorded outright when one is downloaded, and otherwise inferred from the
sidecar `group` only when a *sibling* problem agrees on it — without that check "the
parent directory" would call a judge folder a contest.

<!-- Add new entries above this line as decisions are made. -->

