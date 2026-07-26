-- lua/tuna/navigate.lua
--
-- Contest navigation: `:Tuna next` / `:Tuna prev` step from one problem of a contest
-- to the next, without leaving the editor to find the file. A contest downloaded by
-- `receive contest` is a directory of problem directories, so "the next problem" is
-- simply the next sibling directory in name order, and the file to open in it is the
-- solution beside its testcases.
--
-- The solution is picked to match what is currently open: the same file name first
-- (a contest of `A/main.cpp`, `B/main.cpp`, … keeps you on `main.cpp`), then the same
-- extension, then any runnable non-helper source. That way a problem solved in a
-- different language is still reachable, while `checker.cpp` and friends never are.

local utils = require("tuna.utils")
local config = require("tuna.config")
local tools = require("tuna.tools")

local M = {}

---The sibling directories of `dir`, in name order, and the index of `dir` among them.
---@param dir string absolute problem directory
---@return string[] names, integer? index
local function siblings(dir)
    local parent = vim.fs.dirname(dir)
    local self_name = vim.fn.fnamemodify(dir, ":t")
    local names = {}
    for name, typ in vim.fs.dir(parent) do
        -- Dot-directories are never problems (a `.git` in a contest folder, say).
        if typ == "directory" and name:sub(1, 1) ~= "." then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    for i, name in ipairs(names) do
        if name == self_name then
            return names, i
        end
    end
    return names, nil
end

---The solution file to open inside `dir`, preferring the one that matches the file
---being left (same name, then same extension), so stepping through a contest keeps
---opening the same kind of file.
---@param dir string
---@param like string? path of the current solution
---@param cfg table
---@return string? path
local function solution_in(dir, like, cfg)
    local want_name = like and vim.fn.fnamemodify(like, ":t")
    local want_ext = like and vim.fn.fnamemodify(like, ":e")

    local by_name, by_ext, any
    for _, path in ipairs(vim.fn.globpath(dir, "*", false, true)) do
        if vim.fn.isdirectory(path) == 0 and not tools.is_helper(path, cfg) then
            local ft = vim.filetype.match({ filename = path }) or ""
            if ft ~= "" and (cfg.run_command or {})[ft] then
                local name = vim.fn.fnamemodify(path, ":t")
                if name == want_name then
                    by_name = by_name or path
                elseif vim.fn.fnamemodify(path, ":e") == want_ext then
                    by_ext = by_ext or path
                else
                    any = any or path
                end
            end
        end
    end
    return by_name or by_ext or any
end

---Step `offset` problems from the current one.
---@param offset integer -1 (previous) or +1 (next)
---@param bufnr integer? defaults to the current buffer
function M.go(offset, bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" then
        utils.notify("navigate: this buffer has no file, so there is no contest to walk.", "WARN")
        return
    end
    path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)

    local dir = vim.fs.dirname(path)
    local names, index = siblings(dir)
    if not index then
        utils.notify("navigate: '" .. vim.fn.fnamemodify(dir, ":t") .. "' is not inside a contest directory.", "WARN")
        return
    end

    local target_idx = index + offset
    local target = names[target_idx]
    if not target then
        utils.notify(
            ("navigate: already at the %s problem (%d of %d)."):format(
                offset < 0 and "first" or "last",
                index,
                #names
            ),
            "WARN"
        )
        return
    end

    local target_dir = vim.fs.dirname(dir) .. "/" .. target
    local file = solution_in(target_dir, path, cfg)
    if not file then
        utils.notify("navigate: no solution file in '" .. target .. "'.", "WARN")
        return
    end

    vim.cmd.edit(vim.fn.fnameescape(file))
    utils.place_cursor(cfg)
    utils.notify(("problem %d/%d: %s"):format(target_idx, #names, target), "INFO")
end

---`:Tuna next`
---@param bufnr integer?
function M.next(bufnr)
    M.go(1, bufnr)
end

---`:Tuna prev`
---@param bufnr integer?
function M.prev(bufnr)
    M.go(-1, bufnr)
end

return M
