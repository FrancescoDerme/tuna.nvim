-- lua/tuna/workspace/recent.lua
--
-- `:Tuna last problem` / `:Tuna last contest` — go back to what you were working on.
--
-- Between contests (and between editor sessions) the thing one actually wants is
-- "put me back where I was": the solution file, with Neovim's directory pointing at
-- its problem — so `:e`, a fuzzy finder and `:Tuna run all` all act on that problem
-- rather than on wherever the editor happened to start. That is what these two
-- commands do, which is also why the state has to **survive a restart**: it is kept
-- in a small JSON file under `stdpath("state")`, written debounced (and flushed on
-- exit) so switching buffers doesn't hit the disk on every keystroke.
--
-- What counts as "the problem you were on" is not only what tuna itself opened. A
-- `BufEnter` autocmd records any solution buffer that *looks like a problem* — one
-- whose directory holds testcases or a downloaded-problem sidecar — so opening a file
-- by hand, or stepping to it with `:Tuna next`, counts just the same. Files with no
-- such evidence (your template, a library snippet, the `:Tuna scratch` file) never
-- overwrite it.
--
-- **Pinned** problems are the ones put aside to solve later (`:Tuna pin`): kept in the same
-- file, most recently pinned first, with no limit, until they are unpinned or their
-- solution is deleted.
--
-- The **contest** is recorded outright when one is downloaded (that is the one moment
-- the contest directory is known for certain), and otherwise inferred from the
-- sidecar `group`: a problem's contest directory is its parent when a sibling problem
-- carries the *same* group. Requiring the match is deliberate — "the parent directory"
-- alone would call `~/cp/problems/codeforces` a contest.

local api = vim.api
local utils = require("tuna.utils")
local config = require("tuna.config")

local M = {}

-- Where the state lives. `state` (rather than `data`) is Neovim's directory for
-- exactly this: recoverable, non-essential things remembered between sessions.
local STORE = vim.fs.normalize(vim.fn.stdpath("state") .. "/tuna/recent.json")

-- How long to wait before persisting a change, so a burst of buffer switches costs
-- one write instead of one per switch.
local WRITE_DELAY = 1000

---@class tuna.RecentProblem
---@field file string absolute path of the solution
---@field dir string its directory (what the commands cd into)
---@field name string display name (the problem directory, or the file name)

---@class tuna.RecentContest
---@field dir string absolute contest directory
---@field name string display name (the judge's contest name when known)
---@field judge string? the judge it is on, as `judges.parse` names it
---@field problem string? the last problem visited inside it

---@type { problems: tuna.RecentProblem[]?, contests: tuna.RecentContest[]?, pinned: tuna.RecentProblem[]? }
M.state = {}

local loaded = false
local timer = nil

---How many entries of a kind are remembered, from `recent.problems` or `recent.contests`.
---@param kind "problems"|"contests"
---@return integer
local function capacity(kind)
    local n = (config.current_setup.recent or {})[kind]
    return (type(n) == "number" and n >= 1) and math.floor(n) or 1
end

---Whether `path` (absolute, normalized) lies under one of `recent.ignored_directories`,
---whose files are never remembered.
---@param path string
---@return boolean
local function ignored(path)
    for _, dir in ipairs(config.current_setup.recent.ignored_directories or {}) do
        dir = (vim.fs.normalize(utils.expand_home(dir)):gsub("/$", ""))
        if dir ~= "" and (path == dir or path:sub(1, #dir + 1) == dir .. "/") then
            return true
        end
    end
    return false
end

---Put `entry` at the top of a most-recent-first list, keeping the rest in order but dropping
---its older copy (`same` says which) and any entry whose directory is gone, up to `limit`.
---@param list table[]?
---@param entry table
---@param same fun(e: table): boolean
---@param limit integer
---@return table[]
local function push_front(list, entry, same, limit)
    local kept = { entry }
    for _, e in ipairs(list or {}) do
        if #kept >= limit then
            break
        end
        if type(e) == "table" and e.dir and not same(e) and utils.directory_exists(e.dir) then
            kept[#kept + 1] = e
        end
    end
    return kept
end

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

---Read the state file once per session. A missing or corrupt file is simply an
---empty state — this is a convenience, never something to fail a command over.
local function load()
    if loaded then
        return
    end
    loaded = true
    local content = utils.read_file(STORE)
    if not content or content == "" then
        return
    end
    local ok, decoded = pcall(vim.json.decode, content)
    if ok and type(decoded) == "table" then
        M.state = {
            problems = type(decoded.problems) == "table" and decoded.problems or nil,
            contests = type(decoded.contests) == "table" and decoded.contests or nil,
            pinned = type(decoded.pinned) == "table" and decoded.pinned or nil,
        }
    end
end

---Write the state file now.
function M.flush()
    if timer then
        timer:stop()
        timer:close()
        timer = nil
    end
    if not loaded then
        return
    end
    local ok, encoded = pcall(vim.json.encode, M.state)
    if ok then
        utils.ensure_directory(vim.fs.dirname(STORE))
        utils.write_file(STORE, encoded)
    end
end

---Schedule a write, coalescing a burst of updates into one.
local function persist()
    if timer then
        timer:stop()
    else
        timer = assert(vim.uv.new_timer())
    end
    timer:start(WRITE_DELAY, 0, function()
        vim.schedule(M.flush)
    end)
end

---Drop the pinned problems whose solution is gone, however it went: a pin is a problem to
---come back to, and a deleted one is not there to come back to.
local function prune_pinned()
    local kept = {}
    for _, p in ipairs(M.state.pinned or {}) do
        if type(p) == "table" and type(p.file) == "string" and utils.file_exists(p.file) then
            kept[#kept + 1] = p
        end
    end
    if #kept ~= #(M.state.pinned or {}) then
        M.state.pinned = #kept > 0 and kept or nil
        return true
    end
    return false
end

---Drop the remembered problems and contests under `recent.ignored_directories`: one
---recorded before its directory was ignored would otherwise still be offered.
---@return boolean dropped
local function forget_ignored()
    local dropped = false
    for _, key in ipairs({ "problems", "contests" }) do
        local list = M.state[key]
        if list then
            local kept = {}
            for _, e in ipairs(list) do
                local path = type(e) == "table" and (e.file or e.dir)
                if not (type(path) == "string" and ignored(vim.fs.normalize(path))) then
                    kept[#kept + 1] = e
                end
            end
            if #kept ~= #list then
                M.state[key] = #kept > 0 and kept or nil
                dropped = true
            end
        end
    end
    return dropped
end

---The recent problems and contests, most recent first (the first of each being what
---`:Tuna last problem` and `last contest` return to), and the pinned problems, most recently
---pinned first, hydrated from disk if this session has not read them yet. Exported so the menu
---can *show* what those commands would do without doing it — the state itself is `M.state`,
---but reading that directly would see an empty table until something else happened to load it.
---@return { problems: tuna.RecentProblem[]?, contests: tuna.RecentContest[]?, pinned: tuna.RecentProblem[]? }
function M.snapshot()
    load()
    local pruned = prune_pinned()
    if forget_ignored() or pruned then
        persist()
    end
    return M.state
end

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------

---The task recorded beside a problem by `download` (`url`, `group`, …), or nil when there is
---no sidecar or it names no contest group.
---@param dir string problem directory
---@param cfg table
---@return table?
local function sidecar_task(dir, cfg)
    local store = require("tuna.problem.sidecar").read_or_nil(dir, cfg)
    if store and type(store.group) == "string" and store.group ~= "" then
        return store
    end
    return nil
end

---The `group` recorded beside a problem (its contest, as the judge names it), or nil.
---@param dir string problem directory
---@param cfg table
---@return string?
local function sidecar_group(dir, cfg)
    local task = sidecar_task(dir, cfg)
    return task and task.group
end

-- How many sibling directories to look at when inferring a contest. A contest has
-- a handful of problems; anything past this is not one, and the walk stays bounded
-- even if the problem sits in a directory with thousands of neighbours.
local SIBLING_LIMIT = 40

---Infer the contest a problem belongs to: its parent directory, but only when a
---sibling problem carries the same sidecar `group`. Without that agreement the
---parent is just "some directory holding problems" (a judge folder, say), which is
---not somewhere `:Tuna last contest` should take anyone.
---@param dir string problem directory
---@param cfg table
---@return tuna.RecentContest?
local function infer_contest(dir, cfg)
    local task = sidecar_task(dir, cfg)
    if not task then
        return nil
    end
    local group = task.group
    local parent = vim.fs.dirname(dir)
    local self_name = vim.fn.fnamemodify(dir, ":t")
    local seen = 0
    for name, typ in vim.fs.dir(parent) do
        if typ == "directory" and name ~= self_name and name:sub(1, 1) ~= "." then
            seen = seen + 1
            if seen > SIBLING_LIMIT then
                break
            end
            if sidecar_group(parent .. "/" .. name, cfg) == group then
                -- Named the way a download names it, so both show the same contest.
                local judge, contest = require("tuna.problem.judges").parse(task, cfg.judge_parsers)
                return { dir = parent, name = contest, judge = judge }
            end
        end
    end
    return nil
end

---Record `file` as the problem most recently worked on.
---@param file string path to a solution file
---@param cfg table? resolved config (looked up from the file's directory if omitted)
function M.record_problem(file, cfg)
    file = vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
    if ignored(file) then
        return
    end
    load()
    local dir = vim.fs.dirname(file)
    cfg = cfg or config.load_local_config_and_extend(dir)

    -- The remembered contest this problem is in, if any.
    local contest
    for _, c in ipairs(M.state.contests or {}) do
        if c.dir and file:sub(1, #c.dir + 1) == c.dir .. "/" then
            contest = c
            break
        end
    end
    local problems = M.state.problems or {}
    if problems[1] and problems[1].file == file and (not contest or contest == M.state.contests[1]) then
        return -- already the current one; nothing to write
    end
    M.state.problems = push_front(problems, {
        file = file,
        dir = dir,
        -- The directory names the problem in the usual one-directory-per-problem layout ("B").
        name = vim.fn.fnamemodify(dir, ":t"),
    }, function(p)
        return p.file == file
    end, capacity("problems"))

    -- Keep the contests in step: a problem inside one we know brings it back to the top as
    -- the contest being worked in, and otherwise a sibling agreeing on a contest group adds
    -- one. Anything else leaves them alone: opening an unrelated problem is no reason to
    -- forget a contest.
    contest = contest or infer_contest(dir, cfg)
    if contest then
        contest.problem = file
        M.state.contests = push_front(M.state.contests, contest, function(c)
            return c.dir == contest.dir
        end, capacity("contests"))
    end
    persist()
end

---Record a contest directory (known for certain: it is the one just downloaded).
---@param dir string
---@param name string? display name (the judge's contest name)
---@param problem string? the problem opened inside it
---@param judge string? the judge it is on
function M.record_contest(dir, name, problem, judge)
    dir = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("/$", "")
    if ignored(dir) then
        return
    end
    load()
    local entry = {
        dir = dir,
        name = (name and name ~= "" and name) or vim.fn.fnamemodify(dir, ":t"),
        judge = judge,
        problem = problem and vim.fs.normalize(vim.fn.fnamemodify(problem, ":p")) or nil,
    }
    M.state.contests = push_front(M.state.contests, entry, function(c)
        return c.dir == dir
    end, capacity("contests"))
    persist()
end

--------------------------------------------------------------------------------
-- Pinning
--------------------------------------------------------------------------------

---A solution path in the one form the lists compare by.
---@param file string
---@return string
local function canonical(file)
    return vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
end

---Whether `file` is pinned. A solution that is gone is not, whatever the list still says.
---@param file string
---@return boolean
function M.is_pinned(file)
    load()
    file = canonical(file)
    if not utils.file_exists(file) then
        return false
    end
    for _, p in ipairs(M.state.pinned or {}) do
        if p.file == file then
            return true
        end
    end
    return false
end

---Unpin `file`, doing nothing when it is not pinned.
---@param file string
function M.unpin(file)
    load()
    file = canonical(file)
    local kept = vim.tbl_filter(function(p)
        return p.file ~= file
    end, M.state.pinned or {})
    if #kept ~= #(M.state.pinned or {}) then
        M.state.pinned = #kept > 0 and kept or nil
        persist()
    end
end

---Pin `file`, the most recently pinned first, or unpin it when it is pinned. There is no
---limit: a pin stays until it is taken off or its solution is deleted, since it is a problem
---put aside on purpose, and the menu scrolls a long list.
---@param file string
---@return boolean pinned whether it is pinned now
function M.toggle_pin(file)
    load()
    file = canonical(file)
    if M.is_pinned(file) then
        M.unpin(file)
        return false
    end
    local dir = vim.fs.dirname(file)
    M.state.pinned = vim.list_extend({ { file = file, dir = dir, name = vim.fn.fnamemodify(dir, ":t") } }, M.state.pinned or {})
    persist()
    return true
end

--------------------------------------------------------------------------------
-- Tracking open buffers
--------------------------------------------------------------------------------

---Whether `bufnr` is a solution file worth remembering: a real file in a language
---tuna can run, not a helper, and with evidence of being a *problem* beside it —
---testcases or a downloaded-problem sidecar. Without that last requirement every
---template and library file you opened would become "the last problem".
---@param bufnr integer
---@param path string
---@return boolean
local function is_problem_buffer(bufnr, path)
    if vim.bo[bufnr].buftype ~= "" or not utils.file_exists(path) then
        return false
    end
    -- Fall back to matching the name: `BufEnter` can beat filetype detection, and a
    -- buffer whose language tuna knows shouldn't depend on that race.
    local ft = vim.bo[bufnr].filetype
    if ft == "" then
        ft = vim.filetype.match({ filename = path }) or ""
    end
    if ft == "" then
        return false -- cheap first, so opening a note or a commit message costs nothing
    end
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    if not (cfg.run_command or {})[ft] then
        return false
    end
    if require("tuna.run.tools").is_support(path, cfg) then
        return false
    end
    if sidecar_group(vim.fs.dirname(vim.fs.normalize(path)), cfg) then
        return true
    end
    local ok, tctbl = pcall(require("tuna.problem.testcases").buf_get_testcases, bufnr)
    return ok and next(tctbl) ~= nil
end

local last_checked -- cheap guard: BufEnter fires a lot, paths repeat

---Remember the buffer just entered if it is a problem (`plugin/tuna.lua`'s `BufEnter`,
---which also saves the state on `VimLeavePre` through `flush`).
---@param bufnr integer
function M.track(bufnr)
    local path = api.nvim_buf_get_name(bufnr)
    if path == "" or path == last_checked then
        return
    end
    last_checked = path
    -- Checked first: deciding whether a file is a problem reads the disk.
    if ignored(vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))) then
        return
    end
    if is_problem_buffer(bufnr, path) then
        M.record_problem(path)
    end
end

--------------------------------------------------------------------------------
-- Opening
--------------------------------------------------------------------------------

---Change Neovim's directory, the way `config.cd_command` asks for (`cd`, `tcd` or
---`lcd`; `false` to leave the directory alone). Exported because `download.lua` moves
---into a freshly downloaded contest the same way — one place decides what `cd_command`
---means, so the two cannot drift or validate it differently.
---@param dir string
---@param cfg table
function M.change_dir(dir, cfg)
    local cmd = cfg.cd_command
    if not cmd then
        return
    end
    if cmd ~= "cd" and cmd ~= "tcd" and cmd ~= "lcd" then
        utils.notify("cd_command must be one of 'cd', 'tcd', 'lcd' or false, got '" .. tostring(cmd) .. "'.", "WARN")
        return
    end
    vim.cmd(cmd .. " " .. vim.fn.fnameescape(dir))
end

---Open `file`, point Neovim's directory at `dir`, and put the cursor where a
---templated solution expects it. The directory changes once the file is open, so an `lcd`
---lands on the window showing it rather than on a runner UI pane the file was opened from.
---@param file string?
---@param dir string
---@return table cfg the config resolved at `dir`
local function open_at(file, dir)
    local cfg = config.load_local_config_and_extend(dir)
    if file then
        require("tuna.ui.surface").edit(file)
    end
    M.change_dir(dir, cfg)
    if file then
        utils.place_cursor(cfg)
    end
    return cfg
end

---A path shown to the user, with `$HOME` as `~`. Not cwd-relative like elsewhere in
---tuna: these commands *move* the cwd, so a path relative to either side of that move
---would be the more confusing of the two.
---@param path string
---@return string
local function pretty(path)
    return vim.fn.fnamemodify(path, ":~")
end

---Reopen a remembered problem and cd to its directory.
---@param p tuna.RecentProblem
---@param what string the command, for its messages
local function open_remembered(p, what)
    if not utils.directory_exists(p.dir) then
        utils.notify(what .. ": '" .. pretty(p.dir) .. "' no longer exists.", "WARN")
        return
    end

    local file = p.file
    if not utils.file_exists(file) then
        -- The directory survived but the file was renamed or written in another
        -- language: open whatever solution is in there rather than giving up.
        local cfg = config.load_local_config_and_extend(p.dir)
        local other = require("tuna.workspace.navigate").solution_in(p.dir, p.file, cfg)
        if not other then
            utils.notify(what .. ": '" .. pretty(p.file) .. "' no longer exists.", "WARN")
            return
        end
        file = other
    end

    open_at(file, p.dir)
    utils.notify("problem: " .. pretty(file), "INFO")
end

---`:Tuna last problem` — reopen the solution last worked on and cd to its directory.
---@param index integer? which recent problem, 1 (the default) being the most recent
function M.open_problem(index)
    load()
    if forget_ignored() then
        persist()
    end
    local p = (M.state.problems or {})[index or 1]
    if not p then
        utils.notify("last: no problem visited yet, download one or open a solution with its testcases.", "WARN")
        return
    end
    open_remembered(p, "last")
end

---Reopen a pinned problem and cd to its directory.
---@param index integer? which pinned problem, 1 (the default) being the most recently pinned
function M.open_pinned(index)
    local p = (M.snapshot().pinned or {})[index or 1]
    if not p then
        utils.notify("pin: nothing pinned yet, pin a problem to come back to with `:Tuna pin`.", "WARN")
        return
    end
    open_remembered(p, "pin")
end

---The solution to open when entering a contest directory: the problem last visited
---in it, else the first problem in name order — handling both layouts, one
---directory per problem and the problems as plain files in the contest directory.
---@param contest tuna.RecentContest
---@param cfg table
---@return string? file
local function contest_entry(contest, cfg)
    if contest.problem and utils.file_exists(contest.problem) then
        return contest.problem
    end
    local like = contest.problem
    -- Problems as files directly in the contest directory.
    local navigate = require("tuna.workspace.navigate")
    local flat = navigate.solution_in(contest.dir, like, cfg)
    if flat then
        return flat
    end
    -- One directory per problem: the first in name order that holds a solution.
    for _, name in ipairs(utils.subdirectories(contest.dir)) do
        local file = navigate.solution_in(contest.dir .. "/" .. name, like, cfg)
        if file then
            return file
        end
    end
    return nil
end

---Every problem of a contest, as the solution file it is judged by, in name order: each
---runnable file directly in the contest directory (problems as plain files), then the
---solution in each problem directory, `like` choosing among several there as `:Tuna next`
---does. Helper files and headers are never problems.
---@param dir string contest directory
---@param like string? a solution whose name to prefer inside problem directories
---@param cfg table
---@return string[]
function M.contest_problems(dir, like, cfg)
    local tools = require("tuna.run.tools")
    local navigate = require("tuna.workspace.navigate")
    local files = tools.solutions_in(dir, cfg)
    for _, name in ipairs(utils.subdirectories(dir)) do
        local file = navigate.solution_in(dir .. "/" .. name, like, cfg)
        if file then
            files[#files + 1] = file
        end
    end
    return files
end

---`:Tuna last contest` — cd to the contest last worked on and open a problem in it.
---@param index integer? which recent contest, 1 (the default) being the most recent
function M.open_contest(index)
    load()
    if forget_ignored() then
        persist()
    end
    local c = (M.state.contests or {})[index or 1]
    if not c then
        utils.notify("last: no contest visited yet, get one with `:Tuna download contest`.", "WARN")
        return
    end
    if not utils.directory_exists(c.dir) then
        utils.notify("last: '" .. pretty(c.dir) .. "' no longer exists.", "WARN")
        return
    end

    local cfg = config.load_local_config_and_extend(c.dir)
    local file = contest_entry(c, cfg)
    open_at(file, c.dir)
    if file then
        M.record_problem(file, cfg)
        -- The problem named relative to the contest ("A/main.cpp"): the contest is
        -- already named beside it, so repeating its path adds nothing.
        utils.notify(("contest %s: %s"):format(c.name, file:sub(#c.dir + 2)), "INFO")
    else
        -- The directory is there but holds no solution (yet): the cd still happened,
        -- which is most of what was asked for.
        utils.notify(("contest %s: no solution file in %s."):format(c.name, pretty(c.dir)), "WARN")
    end
end

return M
