-- lua/tuna/stress.lua
--
-- Stress testing: hunt for a small input on which the current solution disagrees
-- with a trusted reference (brute force). For each iteration a generator produces
-- a random input (seeded by the iteration number, so failures are reproducible);
-- the solution and the reference both run on it; their outputs are judged with the
-- same `checker` the runner uses (so checker-based problems with multiple correct
-- answers work too). The first mismatch — or a solution crash/timeout — is saved
-- as a new testcase and the search stops.
--
-- Reuse: `runner.new()` resolves the solution's compile/run commands, working
-- directories, and checker; `checker.judge()` decides each verdict.

local config = require("tuna.config")
local utils = require("tuna.utils")
local runner = require("tuna.runner")
local checker = require("tuna.checker")
local testcases = require("tuna.testcases")

local M = {}

---Resolve a stress command spec (a string, or a `{ exec, args }` table) into an
---argv table, expanding `$(FNOEXT)` etc. against the buffer.
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
        local args = {}
        for i, a in ipairs(spec.args or {}) do
            args[i] = utils.buf_eval_string(bufnr, a)
            if not args[i] then
                return nil
            end
        end
        return { exec = exec, args = args }
    end
    return nil
end

---Run stress testing for a buffer's solution.
---@param bufnr integer? defaults to the current buffer
---@param count_override integer? overrides `stress.count`
function M.run(bufnr, count_override)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)

    -- Reuse the runner to resolve the solution's compile/run commands, dirs, checker.
    local r = runner.new(bufnr)
    if not r then
        return -- runner.new already notified
    end
    local cfg = r.config
    local scfg = cfg.stress or {}

    if not scfg.generator or not scfg.reference then
        utils.notify("stress: configure both 'stress.generator' and 'stress.reference' first.")
        return
    end
    local gen = resolve_cmd(bufnr, scfg.generator)
    local ref = resolve_cmd(bufnr, scfg.reference)
    if not gen then
        utils.notify("stress: 'stress.generator' command is malformed.")
        return
    end
    if not ref then
        utils.notify("stress: 'stress.reference' command is malformed.")
        return
    end

    local count = count_override or scfg.count or 100
    local seed_arg = scfg.seed_arg ~= false
    local timeout = (cfg.maximum_time and cfg.maximum_time > 0) and cfg.maximum_time or nil
    local rundir = r.running_directory
    utils.ensure_directory(rundir)

    -- Save the failing input (with the reference's answer as expected output) as a
    -- new testcase, then report.
    local function save_counterexample(iter, seed, input, expected, reason)
        local tctbl = testcases.buf_get_testcases(bufnr)
        local n = 0
        while tctbl[n] do
            n = n + 1
        end
        testcases.buf_save_testcase(bufnr, n, input, expected or "")
        utils.notify(
            string.format(
                "stress: counterexample on run %d (seed %d) — %s. Saved as testcase %d.",
                iter,
                seed,
                reason,
                n
            ),
            "WARN"
        )
    end

    local loop -- forward declaration (loop iterates asynchronously)

    ---Run one iteration: generator → solution → reference → judge.
    loop = function(i)
        if i > count then
            utils.notify(string.format("stress: no counterexample found in %d runs.", count), "INFO")
            return
        end
        local seed = i

        -- 1. Generator → input.
        local gen_argv = vim.list_extend({ gen.exec }, vim.deepcopy(gen.args))
        if seed_arg then
            table.insert(gen_argv, tostring(seed))
        end
        vim.system(gen_argv, { cwd = rundir, timeout = timeout }, function(gres)
            vim.schedule(function()
                if gres.code ~= 0 then
                    utils.notify("stress: generator failed (seed " .. seed .. ").\n" .. (gres.stderr or ""))
                    return
                end
                local input = gres.stdout or ""

                -- 2. Solution on the generated input.
                vim.system(
                    vim.list_extend({ r.rc.exec }, vim.deepcopy(r.rc.args)),
                    { cwd = rundir, stdin = input, timeout = timeout },
                    function(sres)
                        vim.schedule(function()
                            -- A crash or timeout is itself a counterexample. We still
                            -- need the reference's answer to store as expected output.
                            local sol_failed = sres.code ~= 0
                            local sol_reason = sres.signal and sres.signal ~= 0
                                    and ("runtime error / timeout (signal " .. sres.signal .. ")")
                                or ("non-zero exit " .. tostring(sres.code))

                            -- 3. Reference on the same input.
                            vim.system(
                                vim.list_extend({ ref.exec }, vim.deepcopy(ref.args)),
                                { cwd = rundir, stdin = input, timeout = timeout },
                                function(rres)
                                    vim.schedule(function()
                                        if rres.code ~= 0 then
                                            utils.notify(
                                                "stress: reference failed (seed "
                                                    .. seed
                                                    .. "); aborting.\n"
                                                    .. (rres.stderr or "")
                                            )
                                            return
                                        end
                                        local expected = rres.stdout or ""

                                        if sol_failed then
                                            save_counterexample(i, seed, input, expected, sol_reason)
                                            return
                                        end

                                        -- 4. Judge solution output against the reference.
                                        local tc = { stdin = input, stdout = sres.stdout or "", expected = expected }
                                        checker.judge(tc, r.checker, cfg.output_compare_method, function(correct)
                                            if correct == false then
                                                save_counterexample(i, seed, input, expected, "wrong answer")
                                            else
                                                loop(i + 1)
                                            end
                                        end)
                                    end)
                                end
                            )
                        end)
                    end
                )
            end)
        end)
    end

    -- Compile the solution once (if it needs compiling), then start the loop.
    if r.compile then
        utils.ensure_directory(r.compile_directory)
        vim.system(
            vim.list_extend({ r.cc.exec }, vim.deepcopy(r.cc.args)),
            { cwd = r.compile_directory },
            function(res)
                vim.schedule(function()
                    if res.code ~= 0 then
                        utils.notify("stress: compilation failed.\n" .. (res.stderr or ""))
                        return
                    end
                    utils.notify(string.format("stress: running up to %d iterations…", count), "INFO")
                    loop(1)
                end)
            end
        )
    else
        utils.notify(string.format("stress: running up to %d iterations…", count), "INFO")
        loop(1)
    end
end

return M
