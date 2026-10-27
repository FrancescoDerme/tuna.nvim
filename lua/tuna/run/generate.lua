-- lua/tuna/run/generate.lua
--
-- One testcase from the generator, with no stress run around it: an input to read the
-- solution's output on, to time it on, or to edit into a case of one's own. Nothing gives it
-- an answer, so a run of it reads DONE, unless the solution crashes or runs out of time, or a
-- checker judges its output. The generator is the one stress uses, found, built and handed a
-- seed the same way.

local tools = require("tuna.run.tools")
local core = require("tuna.run.core")
local utils = require("tuna.utils")

local M = {}

---A seed of its own for every run: the clock's microseconds, kept to six digits so it reads
---at a glance.
---@return integer
function M.seed()
    return math.floor(vim.uv.hrtime() / 1000) % 1000000
end

---Run the generator of `bufnr`'s solution once and hand `on_input` what it wrote, with the seed
---it was handed (nil when `stress.pass_seed` is off). A generator that is missing offers its
---starter, as a stress run does. One that is broken, does not build or ends badly is said, and
---`on_input` never runs.
---@param bufnr integer the solution
---@param cfg table
---@param on_input fun(input: string, seed: integer?)
function M.input(bufnr, cfg, on_input)
    local spec, note = tools.helper("generator", vim.api.nvim_buf_get_name(bufnr), cfg)
    if not spec then
        if note then
            utils.notify("generate: " .. note .. ".", "WARN")
        else
            require("tuna.workspace.scaffold").create_missing({ "generator" }, bufnr, "Generating a testcase needs a generator")
        end
        return
    end
    tools.prepare(spec, function(built, err)
        if not built then
            utils.notify("generate: the generator did not build.\n" .. (err or ""), "WARN")
            return
        end
        local seed = cfg.stress.pass_seed ~= false and M.seed() or nil
        local argv = vim.list_extend({ spec.exec }, vim.deepcopy(spec.args))
        if seed then
            argv[#argv + 1] = tostring(seed)
        end
        local timeout = core.time_limit(cfg)
        local started, spawn_err = pcall(vim.system, argv, { cwd = spec.cwd, env = tools.RUN_ENV, timeout = timeout }, function(res)
            vim.schedule(function()
                local failed, _, words = core.ending(res, timeout)
                if failed then
                    utils.notify(("generate: the generator %s, so no testcase was written.\n%s"):format(words, res.stderr or ""), "WARN")
                    return
                end
                on_input(res.stdout or "", seed)
            end)
        end)
        if not started then
            utils.notify("generate: could not start the generator, " .. tostring(spawn_err) .. ".", "WARN")
        end
    end)
end

---Say that testcase `n` was written, with the seed that writes it again.
---@param n integer
---@param seed integer?
function M.said(n, seed)
    utils.notify(("testcase %d generated%s."):format(n, seed and (", seed " .. seed) or ""), "INFO")
end

return M
