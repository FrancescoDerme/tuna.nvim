-- lua/tuna/workspace/navigate.lua
--
-- Contest navigation: `:Tuna next` / `:Tuna prev` step from one problem of a contest
-- to the next, without leaving the editor to find the file. A contest downloaded by
-- `:Tuna download contest` is a directory of problem directories, so "the next
-- problem" is simply the next sibling directory in name order, and the file to open
-- in it is the solution beside its testcases.
--
-- The solution is picked to match what is currently open: the same file name first
-- (a contest of `A/main.cpp`, `B/main.cpp`, … keeps you on `main.cpp`), then the same
-- extension, then any runnable non-helper source. That way a problem solved in a
-- different language is still reachable, while `checker.cpp` and friends never are.
--
-- Neovim's directory comes along when it was the problem being left, or a folder inside it,
-- as `:Tuna go problem` leaves it: working *in* a problem, `:e` and a file finder would
-- otherwise keep pointing at the one left behind. From the contest's folder, or anywhere
-- else, it stays, so a contest opened to be worked from as a whole stays that way.
--
-- `:Tuna next scaffold` / `:Tuna prev scaffold` step within the problem instead, round its
-- own files: the solutions and the helpers beside them.

local utils = require("tuna.utils")
local config = require("tuna.config")
local tools = require("tuna.run.tools")

local M = {}

---The sibling directories of `dir`, in name order, and the index of `dir` among them.
---@param dir string absolute problem directory
---@return string[] names, integer? index
local function siblings(dir)
    local self_name = vim.fn.fnamemodify(dir, ":t")
    -- Dot-directories are never problems (a `.git` in a contest folder, say).
    local names = utils.subdirectories(vim.fs.dirname(dir))
    for i, name in ipairs(names) do
        if name == self_name then
            return names, i
        end
    end
    return names, nil
end

---The solution file to open inside `dir`, preferring the one that matches the file
---being left (same name, then same extension), so stepping through a contest keeps
---opening the same kind of file. Exported because `recent.lua` picks a problem to
---land on the same way when it re-enters a contest.
---@param dir string
---@param like string? path of the current solution
---@param cfg table
---@return string? path
function M.solution_in(dir, like, cfg)
    local want_name = like and vim.fn.fnamemodify(like, ":t")
    local want_ext = like and vim.fn.fnamemodify(like, ":e")

    local by_name, by_ext, any
    for _, path in ipairs(tools.solutions_in(dir, cfg)) do
        local name = vim.fn.fnamemodify(path, ":t")
        if name == want_name then
            by_name = by_name or path
        elseif vim.fn.fnamemodify(path, ":e") == want_ext then
            by_ext = by_ext or path
        else
            any = any or path
        end
    end
    return by_name or by_ext or any
end

---Whether Neovim's directory is `dir` or a folder inside it, each read as its real path, so
---a symlink, a `~` or a trailing slash does not make one folder look like two.
---@param dir string
---@return boolean
local function working_in(dir)
    local here, there = vim.uv.fs_realpath(vim.fn.getcwd()), vim.uv.fs_realpath(dir)
    return here ~= nil and there ~= nil and (here == there or vim.startswith(here, there .. "/"))
end

---Step `offset` problems from the current one.
---@param offset integer -1 (previous) or +1 (next)
---@param bufnr integer? defaults to the current buffer
function M.step(offset, bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" then
        utils.notify("this buffer has no file, so there is no contest to walk.", "WARN")
        return
    end
    path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)

    local dir = vim.fs.dirname(path)
    local names, index = siblings(dir)
    if not index then
        utils.notify("'" .. vim.fn.fnamemodify(dir, ":t") .. "' is not inside a contest directory.", "WARN")
        return
    end

    local target_idx = index + offset
    local target = names[target_idx]
    if not target then
        -- Said the way arriving at a problem is ("problem 3/7: C"), from the one you are on.
        utils.notify(("problem %d/%d is the %s one."):format(index, #names, offset < 0 and "first" or "last"), "WARN")
        return
    end

    local target_dir = vim.fs.dirname(dir) .. "/" .. target
    local file = M.solution_in(target_dir, path, cfg)
    if not file then
        utils.notify("no solution file in '" .. target .. "'.", "WARN")
        return
    end

    -- Decided where the user is, and done once the file is open, in the window showing it
    -- (an `lcd` set from a runner UI pane would go with the pane).
    local follow = working_in(dir)
    require("tuna.ui.surface").edit(file)
    if follow then
        require("tuna.workspace.recent").change_dir(target_dir, config.load_local_config_and_extend(target_dir))
    end
    utils.place_cursor(cfg)
    utils.notify(("problem %d/%d: %s"):format(target_idx, #names, target), "INFO")
end

---Step `offset` source files within the problem: its solutions and helpers, in name order,
---wrapping around, since a problem's files are a handful to go round rather than a line with
---ends. From a file that is none of them (a header, a testcase) the step starts where it would
---stand in that order.
---@param offset integer -1 (previous) or +1 (next)
---@param bufnr integer? defaults to the current buffer
function M.step_scaffold(offset, bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" then
        utils.notify("this buffer has no file, so there is no problem to walk.", "WARN")
        return
    end
    path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    config.load_buffer_config(bufnr)
    local files = tools.sources_in(vim.fs.dirname(path), config.get_buffer_config(bufnr))
    if not vim.tbl_contains(files, path) then
        files[#files + 1] = path
        table.sort(files)
    end
    local index = 1
    while files[index] ~= path do
        index = index + 1
    end
    local target = files[(index - 1 + offset) % #files + 1]
    if target == path then
        utils.notify("no other source file beside '" .. vim.fn.fnamemodify(path, ":t") .. "'.", "WARN")
        return
    end
    require("tuna.ui.surface").edit(target)
end

---`:Tuna next`, and `:Tuna next scaffold`
---@param bufnr integer?
---@param scaffold boolean? the next source file of the problem rather than the next problem
function M.next(bufnr, scaffold)
    (scaffold and M.step_scaffold or M.step)(1, bufnr)
end

---`:Tuna prev`, and `:Tuna prev scaffold`
---@param bufnr integer?
---@param scaffold boolean?
function M.prev(bufnr, scaffold)
    (scaffold and M.step_scaffold or M.step)(-1, bufnr)
end

M._test = { working_in = working_in }

return M
