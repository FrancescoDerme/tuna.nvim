-- lua/tuna/recent.lua
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
-- such evidence (your template, a library snippet, the `:Tuna temp` scratch) never
-- overwrite it.
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
---@field problem string? the last problem visited inside it

---@type { problem: tuna.RecentProblem?, contest: tuna.RecentContest? }
M.state = {}

local loaded = false
local timer = nil

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
        M.state = decoded
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
        timer = vim.uv.new_timer()
    end
    timer:start(WRITE_DELAY, 0, function()
        vim.schedule(M.flush)
    end)
end

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------

---The `group` recorded beside a problem by `download` (its contest, as the judge
---names it), or nil when there is no sidecar.
---@param dir string problem directory
---@param cfg table
---@return string?
local function sidecar_group(dir, cfg)
    local file = dir .. "/" .. ((cfg.submit or {}).url_store_file or ".tuna.json")
    local content = utils.read_file(file)
    if not content then
        return nil
    end
    local ok, store = pcall(vim.json.decode, content)
    if ok and type(store) == "table" and type(store.group) == "string" and store.group ~= "" then
        return store.group
    end
    return nil
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
    local group = sidecar_group(dir, cfg)
    if not group then
        return nil
    end
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
                return { dir = parent, name = group }
            end
        end
    end
    return nil
end

---Record `file` as the problem most recently worked on.
---@param file string path to a solution file
---@param cfg table? resolved config (looked up from the file's directory if omitted)
function M.record_problem(file, cfg)
    load()
    file = vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
    local dir = vim.fs.dirname(file)
    cfg = cfg or config.load_local_config_and_extend(dir)

    local prev = M.state.problem
    if prev and prev.file == file then
        return -- already the current one; nothing to write
    end

    M.state.problem = {
        file = file,
        dir = dir,
        -- The directory names the problem in the usual one-directory-per-problem
        -- layout ("B"); with the problems as plain files it is the file itself.
        name = vim.fn.fnamemodify(dir, ":t"),
    }

    -- Keep the contest in step: either this problem is inside the one we know, or a
    -- sibling agrees on a contest group. Anything else leaves the contest alone —
    -- opening an unrelated problem is no reason to forget the contest you are in.
    local contest = M.state.contest
    if contest and contest.dir and file:sub(1, #contest.dir + 1) == contest.dir .. "/" then
        contest.problem = file
    else
        local found = infer_contest(dir, cfg)
        if found then
            found.problem = file
            M.state.contest = found
        end
    end
    persist()
end

---Record a contest directory (known for certain: it is the one just downloaded).
---@param dir string
---@param name string? display name (the judge's contest name)
---@param problem string? the problem opened inside it
function M.record_contest(dir, name, problem)
    load()
    dir = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("/$", "")
    M.state.contest = {
        dir = dir,
        name = (name and name ~= "" and name) or vim.fn.fnamemodify(dir, ":t"),
        problem = problem and vim.fs.normalize(vim.fn.fnamemodify(problem, ":p")) or nil,
    }
    persist()
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
    if require("tuna.tools").is_helper(path, cfg) then
        return false
    end
    if sidecar_group(vim.fs.dirname(vim.fs.normalize(path)), cfg) then
        return true
    end
    local ok, tctbl = pcall(require("tuna.testcases").buf_get_testcases, bufnr)
    return ok and next(tctbl) ~= nil
end

---Install the tracking autocmds: remember the problem buffer you are in, and make
---sure the last change reaches disk when Neovim exits.
function M.setup()
    local group = api.nvim_create_augroup("TunaRecent", { clear = true })
    local last_checked -- cheap guard: BufEnter fires a lot, paths repeat

    api.nvim_create_autocmd("BufEnter", {
        group = group,
        callback = function(ev)
            local path = api.nvim_buf_get_name(ev.buf)
            if path == "" or path == last_checked then
                return
            end
            last_checked = path
            if is_problem_buffer(ev.buf, path) then
                M.record_problem(path)
            end
        end,
        desc = "Remember the problem Tuna should return to with `:Tuna last problem`",
    })

    api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = M.flush,
        desc = "Persist Tuna's last problem/contest",
    })
end

--------------------------------------------------------------------------------
-- Opening
--------------------------------------------------------------------------------

---Change Neovim's directory, the way `config.cd_command` asks for (`cd`, `tcd` or
---`lcd`; `false` to leave the directory alone).
---@param dir string
---@param cfg table
local function change_dir(dir, cfg)
    local cmd = cfg.cd_command
    if not cmd then
        return
    end
    if cmd ~= "cd" and cmd ~= "tcd" and cmd ~= "lcd" then
        utils.notify("cd_command must be one of 'cd', 'tcd', 'lcd' or false — got '" .. tostring(cmd) .. "'.", "WARN")
        return
    end
    vim.cmd(cmd .. " " .. vim.fn.fnameescape(dir))
end

---Open `file`, point Neovim's directory at `dir`, and put the cursor where a
---templated solution expects it.
---@param file string?
---@param dir string
---@return table cfg the config resolved at `dir`
local function open_at(file, dir)
    local cfg = config.load_local_config_and_extend(dir)
    change_dir(dir, cfg)
    if file then
        vim.cmd.edit(vim.fn.fnameescape(file))
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

---`:Tuna last problem` — reopen the solution last worked on and cd to its directory.
function M.open_problem()
    load()
    local p = M.state.problem
    if not p then
        utils.notify("last: no problem visited yet — download one, or open a solution with its testcases.", "WARN")
        return
    end
    if not utils.directory_exists(p.dir) then
        utils.notify("last: '" .. pretty(p.dir) .. "' no longer exists.", "WARN")
        return
    end

    local file = p.file
    if not utils.file_exists(file) then
        -- The directory survived but the file was renamed or written in another
        -- language: open whatever solution is in there rather than giving up.
        local cfg = config.load_local_config_and_extend(p.dir)
        file = require("tuna.navigate").solution_in(p.dir, p.file, cfg)
        if not file then
            utils.notify("last: '" .. pretty(p.file) .. "' no longer exists.", "WARN")
            return
        end
    end

    open_at(file, p.dir)
    utils.notify("problem: " .. pretty(file), "INFO")
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
    local navigate = require("tuna.navigate")
    local flat = navigate.solution_in(contest.dir, like, cfg)
    if flat then
        return flat
    end
    -- One directory per problem: the first in name order that holds a solution.
    local names = {}
    for name, typ in vim.fs.dir(contest.dir) do
        if typ == "directory" and name:sub(1, 1) ~= "." then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local file = navigate.solution_in(contest.dir .. "/" .. name, like, cfg)
        if file then
            return file
        end
    end
    return nil
end

---`:Tuna last contest` — cd to the contest last worked on and open a problem in it.
function M.open_contest()
    load()
    local c = M.state.contest
    if not c then
        utils.notify("last: no contest visited yet — get one with `:Tuna download contest`.", "WARN")
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
        utils.notify(("contest %s: no solution file in %s"):format(c.name, pretty(c.dir)), "WARN")
    end
end

return M
