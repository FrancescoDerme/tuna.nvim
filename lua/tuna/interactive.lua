-- lua/tuna/interactive.lua
--
-- Interactive problems: the solution talks to an *interactor* program over stdio
-- (the solution prints queries, the interactor answers, and so on). There is no
-- fixed expected output — the interactor decides the verdict and exits 0 for
-- accepted, non-zero otherwise.
--
-- `vim.system` only hands back stdout when a process *finishes*, so it can't
-- cross-wire two live processes. We drop to `vim.uv.spawn` and forward bytes
-- between the two pipes by hand:
--
--   solution.stdout ──▶ interactor.stdin
--   interactor.stdout ──▶ solution.stdin
--
-- The interactor receives the testcase input and answer as files (placeholders
-- `$(INPUT)` / `$(ANSWER)`, defaulting to those two appended args), exactly like a
-- testlib interactor. Reuse: `runner.new()` resolves the solution's compile/run
-- commands and working directory.

local uv = vim.uv
local config = require("tuna.config")
local utils = require("tuna.utils")
local runner = require("tuna.runner")
local testcases = require("tuna.testcases")
local tools = require("tuna.tools")

local M = {}

local DEFAULT_ARGS = { "$(INPUT)", "$(ANSWER)" }

---Resolve a command spec (string or `{ exec, args }`) into argv. Only the exec is
---modifier-expanded ($(FNOEXT)/$(ABSDIR)/…); args are kept raw so their per-run
---$(INPUT)/$(ANSWER) placeholders survive to be filled in by `run_one`.
---@param bufnr integer
---@param spec string|{ exec: string, args: string[]? }
---@return { exec: string, args: string[] }?
local function resolve_cmd(bufnr, spec)
    if type(spec) == "string" then
        local exec = utils.buf_eval_string(bufnr, spec)
        return exec and { exec = exec, args = {} } or nil
    elseif type(spec) == "table" and spec.exec then
        local exec = utils.buf_eval_string(bufnr, spec.exec)
        if not exec then
            return nil
        end
        return { exec = exec, args = vim.deepcopy(spec.args or {}) }
    end
    return nil
end

---Write `content` to a fresh temp file and return its path.
---@param content string?
---@return string
local function temp_with(content)
    local path = vim.fn.tempname()
    utils.write_file(path, content or "")
    return path
end

---Run one interactor↔solution session for a single testcase.
---@param sol { exec: string, args: string[] } resolved solution run command
---@param interactor { exec: string, args: string[] } resolved interactor command
---@param rundir string working directory
---@param timeout integer? ms before both processes are killed
---@param input string testcase input (given to the interactor as $(INPUT))
---@param answer string? testcase answer (given to the interactor as $(ANSWER))
---@param on_done fun(correct: boolean?, message: string?) verdict + interactor log
local function run_one(sol, interactor, rundir, timeout, input, answer, on_done)
    local input_file = temp_with(input)
    local answer_file = temp_with(answer or "")
    local files = { INPUT = input_file, OUTPUT = "/dev/null", ANSWER = answer_file }

    local raw = (#interactor.args > 0) and interactor.args or DEFAULT_ARGS
    local int_args = {}
    for i, a in ipairs(raw) do
        int_args[i] = a:gsub("%$%((%u+)%)", function(name)
            return files[name]
        end)
    end

    local sol_in, sol_out = uv.new_pipe(false), uv.new_pipe(false)
    local int_in, int_out, int_err = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)

    local sol_handle, int_handle, timer
    local int_log = {}
    local done = false
    local verdict, int_exited

    local function safe_close(h)
        if h and not h:is_closing() then
            h:close()
        end
    end

    local function finish()
        if done then
            return
        end
        done = true
        if timer then
            timer:stop()
            safe_close(timer)
        end
        -- Kill anything still alive; closing pipes lets the kernel tear down fds.
        if sol_handle and sol_handle:is_active() then
            pcall(function()
                sol_handle:kill("sigkill")
            end)
        end
        if int_handle and int_handle:is_active() then
            pcall(function()
                int_handle:kill("sigkill")
            end)
        end
        for _, p in ipairs({ sol_in, sol_out, int_in, int_out, int_err }) do
            safe_close(p)
        end
        utils.delete_file(input_file)
        utils.delete_file(answer_file)
        local msg = #int_log > 0 and vim.trim(table.concat(int_log)) or nil
        vim.schedule(function()
            on_done(verdict, msg)
        end)
    end

    -- Spawn the solution.
    sol_handle = uv.spawn(sol.exec, {
        args = sol.args,
        cwd = rundir,
        stdio = { sol_in, sol_out, nil },
    }, function(code, signal)
        safe_close(sol_handle)
        sol_handle = nil
        -- A solution that dies before the interactor ruled is a runtime error,
        -- unless the interactor is the one that killed the exchange.
        if not int_exited and not done and (code ~= 0 or (signal and signal ~= 0)) then
            verdict = false
            int_log[#int_log + 1] = "\n[solution exited with code " .. tostring(code) .. "]"
            finish()
        end
    end)
    if not sol_handle then
        for _, p in ipairs({ sol_in, sol_out, int_in, int_out, int_err }) do
            safe_close(p)
        end
        on_done(nil, "could not start solution '" .. tostring(sol.exec) .. "'")
        return
    end

    -- Spawn the interactor.
    int_handle = uv.spawn(interactor.exec, {
        args = int_args,
        cwd = rundir,
        stdio = { int_in, int_out, int_err },
    }, function(code, signal)
        safe_close(int_handle)
        int_handle = nil
        int_exited = true
        -- The interactor is the verdict authority: exit 0 == accepted.
        verdict = (code == 0 and (not signal or signal == 0))
        finish()
    end)
    if not int_handle then
        verdict = nil
        int_log[#int_log + 1] = "could not start interactor '" .. tostring(interactor.exec) .. "'"
        finish()
        return
    end

    -- Cross-wire the pipes. On EOF (data == nil) shut down the other side's stdin
    -- so the peer sees end-of-input instead of blocking forever.
    sol_out:read_start(function(err, data)
        if err or done then
            return
        end
        if data then
            if not int_in:is_closing() then
                int_in:write(data)
            end
        elseif not int_in:is_closing() then
            int_in:shutdown()
        end
    end)
    int_out:read_start(function(err, data)
        if err or done then
            return
        end
        if data then
            if not sol_in:is_closing() then
                sol_in:write(data)
            end
        elseif not sol_in:is_closing() then
            sol_in:shutdown()
        end
    end)
    int_err:read_start(function(err, data)
        if not err and data then
            int_log[#int_log + 1] = data
        end
    end)

    if timeout then
        timer = uv.new_timer()
        timer:start(timeout, 0, function()
            if not done then
                verdict = false
                int_log[#int_log + 1] = "\n[timed out after " .. timeout .. "ms]"
                finish()
            end
        end)
    end
end

---Run interactive judging for a buffer's solution.
---@param bufnr integer? defaults to the current buffer
---@param list string[]? testcase numbers to run, or nil for all
function M.run(bufnr, list)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)

    local r = runner.new(bufnr)
    if not r then
        return
    end
    local cfg = r.config
    local icfg = cfg.interactive or {}
    local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
    tools.save_sources(bufnr, cfg) -- save the solution (interactor is saved in tools.prepare)

    -- Interactor: an explicit config spec wins, otherwise discover a sibling
    -- 'interactor.*' source file (compiled below). The discovered interactor gets
    -- the testcase input/answer appended as $(INPUT)/$(ANSWER) file args.
    local interactor
    if icfg.interactor then
        interactor = resolve_cmd(bufnr, icfg.interactor)
        if not interactor then
            utils.notify("interactive: 'interactive.interactor' command is malformed.")
            return
        end
    else
        local ipath = tools.find(dir, "interactor", cfg)
        if not ipath then
            utils.notify(
                "interactive: no interactor found — create a sibling 'interactor.*' file, "
                    .. "or set 'interactive.interactor'."
            )
            return
        end
        local spec, err = tools.program(ipath, cfg)
        if not spec then
            utils.notify("interactive: interactor " .. err .. ".")
            return
        end
        interactor = spec
        interactor.args = vim.list_extend(interactor.args, { "$(INPUT)", "$(ANSWER)" })
    end

    -- Build the testcase list (default: all; fall back to one empty case).
    local tctbl = testcases.buf_get_testcases(bufnr)
    local nums = {}
    if list then
        for _, s in ipairs(list) do
            local n = tonumber(s)
            if n and tctbl[n] then
                table.insert(nums, n)
            else
                utils.notify("interactive: testcase " .. s .. " doesn't exist.")
            end
        end
    else
        nums = vim.tbl_keys(tctbl)
        table.sort(nums)
    end
    if #nums == 0 then
        nums = { -1 } -- sentinel: run once with empty input
        tctbl[-1] = { input = "", output = nil }
    end

    local timeout = (cfg.maximum_time and cfg.maximum_time > 0) and cfg.maximum_time or nil
    local rundir = r.running_directory
    utils.ensure_directory(rundir)

    local function start()
        local i = 0
        local results = {}
        local function next_case()
            i = i + 1
            if i > #nums then
                local parts = {}
                for _, res in ipairs(results) do
                    parts[#parts + 1] = res
                end
                utils.notify("interactive results:\n" .. table.concat(parts, "\n"), "INFO")
                return
            end
            local n = nums[i]
            local tc = tctbl[n]
            run_one(r.rc, interactor, rundir, timeout, tc.input or "", tc.output, function(correct, message)
                local label = correct == true and "CORRECT" or (correct == false and "WRONG" or "DONE")
                local name = n == -1 and "run" or ("testcase " .. n)
                results[#results + 1] = ("  " .. name .. " -> " .. label .. (message and ("  (" .. message .. ")") or ""))
                next_case()
            end)
        end
        next_case()
    end

    -- Compile the interactor once (no-op for interpreted/prebuilt interactors),
    -- then run the sessions.
    local function prepare_and_start()
        tools.prepare(interactor, function(ok, err)
            if not ok then
                utils.notify("interactive: interactor " .. err)
                return
            end
            start()
        end)
    end

    if r.compile then
        utils.ensure_directory(r.compile_directory)
        vim.system(
            vim.list_extend({ r.cc.exec }, vim.deepcopy(r.cc.args)),
            { cwd = r.compile_directory },
            function(res)
                vim.schedule(function()
                    if res.code ~= 0 then
                        utils.notify("interactive: compilation failed.\n" .. (res.stderr or ""))
                        return
                    end
                    prepare_and_start()
                end)
            end
        )
    else
        prepare_and_start()
    end
end

return M
