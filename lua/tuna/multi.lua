-- lua/tuna/multi.lua
--
-- Run *every* solution version in a problem directory against the shared
-- testcases, and report a per-solution pass/total summary (`:Tuna run_all`). This
-- is for when you keep several attempts side by side — `main.cpp`, `brute.cpp`,
-- `slow.cpp` — and want to see at a glance which ones pass.
--
-- The candidate files are the siblings of the current file with the same
-- extension, so they share the current buffer's filetype (hence its compile/run
-- commands). Commands are resolved per file with `utils.eval_string` (no buffer
-- needed), and each verdict goes through the same `checker` as a normal run.

local config = require("tuna.config")
local utils = require("tuna.utils")
local checker = require("tuna.checker")
local testcases = require("tuna.testcases")

local M = {}

---Expand $(FNOEXT)/… in a command against a concrete file path.
---@param filepath string
---@param command { exec: string, args: string[]? }
---@return { exec: string, args: string[] }?
local function eval_command(filepath, command)
    local exec = utils.eval_string(filepath, command.exec)
    if not exec then
        return nil
    end
    local args = {}
    for i, a in ipairs(command.args or {}) do
        args[i] = utils.eval_string(filepath, a)
        if not args[i] then
            return nil
        end
    end
    return { exec = exec, args = args }
end

---Resolve the checker for a specific solution file (mirrors `runner.new`).
---@param filepath string
---@param cfg table
---@return "builtin"|function|{ exec: string, args: string[]? }
local function resolve_checker(filepath, cfg)
    if type(cfg.checker) == "function" then
        return cfg.checker
    elseif type(cfg.checker) == "string" and cfg.checker ~= "builtin" then
        local exec = utils.eval_string(filepath, cfg.checker)
        return exec and { exec = exec } or "builtin"
    elseif type(cfg.checker) == "table" and cfg.checker.exec then
        local exec = utils.eval_string(filepath, cfg.checker.exec)
        return exec and { exec = exec, args = cfg.checker.args } or "builtin"
    end
    return "builtin"
end

---Run every sibling solution version against the testcases.
---@param bufnr integer? defaults to the current buffer
function M.run(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)

    local curpath = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
    local dir = vim.fn.fnamemodify(curpath, ":h")
    local ext = vim.fn.fnamemodify(curpath, ":e")
    local filetype = vim.bo[bufnr].filetype or ""
    if ext == "" then
        utils.notify("run_all: the current file has no extension to match siblings on.")
        return
    end

    local files = vim.fn.globpath(dir, "*." .. ext, false, true)
    table.sort(files)
    if #files == 0 then
        utils.notify("run_all: no '*." .. ext .. "' files found beside this one.")
        return
    end

    local tctbl = testcases.buf_get_testcases(bufnr)
    local nums = vim.tbl_keys(tctbl)
    table.sort(nums)
    if #nums == 0 then
        utils.notify("run_all: no testcases to run.")
        return
    end

    local timeout = (cfg.maximum_time and cfg.maximum_time > 0) and cfg.maximum_time or nil
    local rundir = vim.fs.normalize(dir .. "/" .. cfg.running_directory) .. "/"
    local compdir = vim.fs.normalize(dir .. "/" .. cfg.compile_directory) .. "/"
    utils.ensure_directory(rundir)

    local results = {} -- { { name=…, correct=…, total=… } | { name=…, text=… } }

    local function report()
        local width = 0
        for _, f in ipairs(files) do
            width = math.max(width, #vim.fn.fnamemodify(f, ":t"))
        end
        local lines = {}
        for _, res in ipairs(results) do
            local detail = res.text or string.format("%d/%d", res.correct, res.total)
            lines[#lines + 1] = "  " .. res.name .. string.rep(" ", width - #res.name + 2) .. detail
        end
        utils.notify("run_all results:\n" .. table.concat(lines, "\n"), "INFO")
    end

    local si = 0
    local function next_solution()
        si = si + 1
        if si > #files then
            report()
            return
        end
        local f = files[si]
        local name = vim.fn.fnamemodify(f, ":t")
        local rc = cfg.run_command[filetype] and eval_command(f, cfg.run_command[filetype])
        if not rc then
            results[#results + 1] = { name = name, text = "(no run command)" }
            next_solution()
            return
        end
        local cc = cfg.compile_command[filetype] and eval_command(f, cfg.compile_command[filetype])
        local chk = resolve_checker(f, cfg)

        local function run_cases()
            local correct, total = 0, 0
            local ci = 0
            local function next_case()
                ci = ci + 1
                if ci > #nums then
                    results[#results + 1] = { name = name, correct = correct, total = total }
                    next_solution()
                    return
                end
                local tc = tctbl[nums[ci]]
                vim.system(
                    vim.list_extend({ rc.exec }, vim.deepcopy(rc.args)),
                    { cwd = rundir, stdin = tc.input or "", timeout = timeout },
                    function(res)
                        vim.schedule(function()
                            total = total + 1
                            if res.code ~= 0 then
                                next_case() -- crash / timeout counts as not correct
                                return
                            end
                            local jtc = { stdin = tc.input or "", stdout = res.stdout or "", expected = tc.output }
                            checker.judge(jtc, chk, cfg.output_compare_method, function(ok)
                                if ok == true then
                                    correct = correct + 1
                                end
                                next_case()
                            end)
                        end)
                    end
                )
            end
            next_case()
        end

        if cc then
            utils.ensure_directory(compdir)
            vim.system(vim.list_extend({ cc.exec }, vim.deepcopy(cc.args)), { cwd = compdir }, function(res)
                vim.schedule(function()
                    if res.code ~= 0 then
                        results[#results + 1] = { name = name, text = "(compile error)" }
                        next_solution()
                        return
                    end
                    run_cases()
                end)
            end)
        else
            run_cases()
        end
    end

    utils.notify(string.format("run_all: testing %d solution(s) on %d testcase(s)…", #files, #nums), "INFO")
    next_solution()
end

return M
