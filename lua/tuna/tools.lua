-- lua/tuna/tools.lua
--
-- "Helper programs" are the sibling source files a problem folder grows around a
-- solution: a generator, a brute/reference, a checker, an interactor. The whole
-- point of this module is that these are *ordinary source files in the same
-- language as the solution* (drop a `checker.cpp` next to `sol.cpp`), discovered
-- by filename convention and compiled/run with the very same config-driven
-- commands as a solution. That is what lets you stress-test / special-judge /
-- run interactively with **no `.tuna.lua`** — you switch behaviour by which files
-- exist and which run *mode* the buffer is in.
--
-- Three concerns live here:
--   * discovery   — `find()` locates a helper by role (checker/generator/…)
--   * resolution  — `program()`/`checker_spec()` turn a path into a runnable spec
--                   ({ exec, args, compile?, cwd }) using the buffer config
--   * compilation — `prepare()` compiles a spec once and caches the result, so a
--                   dozen parallel `checker.judge` calls don't recompile (or race)
--
-- It also holds the tiny per-buffer *run state* (active mode + checker toggle),
-- keyed by file path so it survives a buffer being unloaded and reopened.

local utils = require("tuna.utils")

local M = {}

-- Conventional base names per role (extension-agnostic). Overridable via
-- `config.tool_names`. Earlier names win when several match.
M.DEFAULT_NAMES = {
    checker = { "checker", "check" },
    generator = { "gen", "generator" },
    reference = { "brute", "reference" },
    interactor = { "interactor", "interact" },
}

-- Testlib-style checker argument order: <input> <participant output> <jury answer>.
local CHECKER_ARGS = { "$(INPUT)", "$(OUTPUT)", "$(ANSWER)" }

---Neovim's filetype for a path, from its name alone (no buffer needed).
---@param path string
---@return string # filetype, or "" when undetectable
local function filetype_of(path)
    return vim.filetype.match({ filename = path }) or ""
end

---Expand `$(FNAME)/$(FNOEXT)/...` in a command's exec and args against a path.
---Mirrors `runner`'s `eval_command`, but keyed off a concrete file path rather
---than a buffer (so it works for helpers that have no open buffer).
---@param path string
---@param command { exec: string, args: string[]? }
---@return { exec: string, args: string[] }?
local function eval_command(path, command)
    local exec = utils.eval_string(path, command.exec)
    if not exec then
        return nil
    end
    local args = {}
    for i, a in ipairs(command.args or {}) do
        args[i] = utils.eval_string(path, a)
        if not args[i] then
            return nil
        end
    end
    return { exec = exec, args = args }
end

M.filetype_of = filetype_of
M.eval_command = eval_command

--------------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------------

---Find a helper source file for `role` beside the solution.
---A candidate must match one of the role's base names (any extension) *and* have
---a `run_command` configured for its filetype — that filters out compiled
---artefacts (`checker.o`, `checker` binaries) and editor backups.
---@param dir string problem directory to search (non-recursive)
---@param role string "checker" | "generator" | "reference" | "interactor"
---@param cfg table buffer configuration
---@return string? # absolute path, or nil if none found
function M.find(dir, role, cfg)
    local names = (cfg.tool_names and cfg.tool_names[role]) or M.DEFAULT_NAMES[role] or {}
    for _, base in ipairs(names) do
        local hits = vim.fn.globpath(dir, base .. ".*", false, true)
        table.sort(hits)
        for _, path in ipairs(hits) do
            local ft = filetype_of(path)
            if ft ~= "" and cfg.run_command[ft] then
                return path
            end
        end
    end
    return nil
end

---Whether `path` is a helper (checker/generator/reference/interactor) rather than
---a solution, matched by base name against `tool_names`.
---@param path string
---@param cfg table buffer configuration
---@return boolean
function M.is_helper(path, cfg)
    local base = vim.fn.fnamemodify(path, ":t:r")
    local names = cfg.tool_names or M.DEFAULT_NAMES
    for _, list in pairs(names) do
        for _, n in ipairs(list) do
            if base == n then
                return true
            end
        end
    end
    return false
end

---Resolve the buffer a run should target. Normally that's `bufnr` itself, but if
---`bufnr` is a *helper* file (e.g. you're editing `checker.cpp`), redirect to the
---solution beside it so running/stress/etc. still work. The solution is a sibling
---non-helper source of the same extension; when several exist, prefer a
---conventional name (`main`/`sol`/`solution`). The chosen solution is loaded into a
---(possibly hidden) buffer without stealing focus.
---@param bufnr integer
---@param cfg table buffer configuration
---@return integer? # the solution buffer, or nil on failure
---@return string? # error message, or an info note when auto-picked from several
function M.solution_bufnr(bufnr, cfg)
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" or not M.is_helper(path, cfg) then
        return bufnr
    end

    local abspath = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    local dir = vim.fn.fnamemodify(path, ":p:h")
    -- The solution may be a different language than the helper (a Python checker
    -- beside a C++ solution), so consider every runnable source file, not just the
    -- helper's extension.
    local cands = {}
    for _, f in ipairs(vim.fn.globpath(dir, "*", false, true)) do
        local fp = vim.fs.normalize(vim.fn.fnamemodify(f, ":p"))
        local ft = filetype_of(f)
        if
            fp ~= abspath
            and vim.fn.isdirectory(f) == 0
            and ft ~= ""
            and cfg.run_command[ft]
            and not M.is_helper(f, cfg)
        then
            cands[#cands + 1] = f
        end
    end
    table.sort(cands)
    if #cands == 0 then
        return nil, "no solution file found next to '" .. vim.fn.fnamemodify(path, ":t") .. "'."
    end

    local prefer = { main = 1, sol = 2, solution = 3 }
    local best_rank, chosen = math.huge, cands[1]
    for _, f in ipairs(cands) do
        local r = prefer[vim.fn.fnamemodify(f, ":t:r")]
        if r and r < best_rank then
            best_rank, chosen = r, f
        end
    end

    local sb = vim.fn.bufadd(chosen)
    vim.fn.bufload(sb)
    if vim.bo[sb].filetype == "" then
        local ft = vim.filetype.match({ filename = chosen, buf = sb }) or filetype_of(chosen)
        if ft ~= "" then
            vim.bo[sb].filetype = ft
        end
    end
    local note = #cands > 1 and ("running solution '" .. vim.fn.fnamemodify(chosen, ":t") .. "'") or nil
    return sb, note
end

--------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------

---Turn a helper source path into a runnable spec, resolving its compile/run
---commands from the config by the file's own filetype (so a Python helper beside
---a C++ solution still works). `compile` is present only for compiled languages.
---`cwd` is the problem directory, so a relative run exec like `./gen` resolves.
---@param path string
---@param cfg table buffer configuration
---@return { exec: string, args: string[], compile: { exec: string, args: string[] }?, compile_dir: string?, cwd: string }?
---@return string? # error message when resolution fails
function M.program(path, cfg)
    local ft = filetype_of(path)
    local run_cmd = ft ~= "" and cfg.run_command[ft]
    if not run_cmd then
        return nil, "no run command for filetype '" .. ft .. "' (" .. vim.fn.fnamemodify(path, ":t") .. ")"
    end
    local run = eval_command(path, run_cmd)
    if not run then
        return nil, "run command for '" .. ft .. "' is malformed"
    end

    local dir = vim.fn.fnamemodify(path, ":p:h")
    local spec = { exec = run.exec, args = run.args, cwd = dir, source = vim.fn.fnamemodify(path, ":p") }

    if cfg.compile_command[ft] then
        local compile = eval_command(path, cfg.compile_command[ft])
        if not compile then
            return nil, "compile command for '" .. ft .. "' is malformed"
        end
        spec.compile = compile
        spec.compile_dir = vim.fs.normalize(dir .. "/" .. (cfg.compile_directory or ".")) .. "/"
    end
    return spec
end

---Resolve a checker path into a `checker.judge`-ready spec: like `program`, but
---with the testlib `<input> <output> <answer>` placeholders appended so the
---checker is invoked `<exec> <run-args> <input> <output> <answer>`. A path with
---no filetype/run command is treated as an already-runnable binary (`{ exec }`),
---and `checker.judge` supplies the default testlib args itself.
---@param path string
---@param cfg table buffer configuration
---@return table # a checker spec accepted by `checker.judge`
function M.checker_spec(path, cfg)
    local spec, err = M.program(path, cfg)
    if not spec then
        -- Not a known source language: assume a prebuilt, directly-runnable binary.
        local _ = err
        return { exec = path, cwd = vim.fn.fnamemodify(path, ":p:h") }
    end
    spec.args = vim.list_extend(spec.args, vim.deepcopy(CHECKER_ARGS))
    return spec
end

--------------------------------------------------------------------------------
-- Compilation (compile cache, invalidated when the source changes)
--------------------------------------------------------------------------------

---Last-modified time of `path` as a comparable number, or nil if unreadable.
---@param path string?
---@return number?
local function source_mtime(path)
    if not path then
        return nil
    end
    local st = vim.uv.fs_stat(path)
    if not st or not st.mtime then
        return nil
    end
    return st.mtime.sec + (st.mtime.nsec or 0) / 1e9
end

---If `path` is open in a modified buffer, write it to disk. Running a helper must
---pick up unsaved edits — otherwise the rebuild check below sees the stale on-disk
---file and skips the recompile. Must run on the main loop.
---@param path string?
local function flush_source_buffer(path)
    if not path then
        return
    end
    local target = vim.fs.normalize(path)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
            local name = vim.api.nvim_buf_get_name(b)
            if name ~= "" and vim.fs.normalize(name) == target then
                vim.api.nvim_buf_call(b, function()
                    vim.cmd("silent keepalt write")
                end)
                return
            end
        end
    end
end

---Public wrapper: flush an unsaved edit to `path` (used by `run_all` to save
---every candidate solution version before running them).
---@param path string?
function M.flush_buffer(path)
    flush_source_buffer(path)
end

---Persistent compile cache, keyed by absolute source path, so a *fresh* spec for
---the same unchanged source (e.g. `gen.cpp`/`brute.cpp` on a repeated `:Tuna run
---stress`) reuses the previous build instead of recompiling. Invalidated when the
---source's mtime or the exact compile command changes, so editing the source (or
---the compile flags) still rebuilds. This is what keeps the iterate-and-re-run
---loop fast when only the solution changed.
---@type table<string, { mtime: number?, cmdkey: string, compiled: boolean?, error: string?, compiling: boolean?, waiters: (fun(ok: boolean, err: string?))[]? }>
local compile_cache = {}

---A stable key for a compile command (exec + args), so a flag change invalidates.
---@param cmd { exec: string, args: string[]? }
---@return string
local function command_key(cmd)
    return (cmd.exec or "") .. "\0" .. table.concat(cmd.args or {}, "\0")
end

---Ensure a spec produced by `program`/`checker_spec` is compiled, then call `cb`.
---The result is cached (persistently, across specs) keyed by the source path +
---mtime + compile command, so a batch of parallel `judge`s compiles once
---(concurrent callers queue behind the in-flight compile) and repeated runs skip
---recompiling an unchanged source, yet **editing the source or flags and
---re-running recompiles it**. A spec without a `compile` step (interpreted
---language, or a prebuilt binary) is ready immediately.
---@param spec table
---@param cb fun(ok: boolean, err: string?)
function M.prepare(spec, cb)
    -- Flush unsaved edits to the helper source first, so both the rebuild check
    -- and (for interpreted helpers) the run itself see the current code.
    flush_source_buffer(spec.source)

    if not spec.compile then
        cb(true)
        return
    end

    local key = spec.source and vim.fs.normalize(spec.source) or command_key(spec.compile)
    local cmdkey = command_key(spec.compile)
    local entry = compile_cache[key]
    if not entry or entry.cmdkey ~= cmdkey then
        entry = { cmdkey = cmdkey } -- new source, or the compile command changed
        compile_cache[key] = entry
    end

    local mtime = source_mtime(spec.source)
    -- Reuse a cached result only if the source hasn't changed since we built it.
    if entry.mtime == mtime and not entry.compiling then
        if entry.compiled then
            cb(true)
            return
        elseif entry.error then
            cb(false, entry.error)
            return
        end
    end

    entry.waiters = entry.waiters or {}
    table.insert(entry.waiters, cb)
    if entry.compiling then
        return -- a compile is already running; we'll be flushed when it lands
    end
    entry.compiling = true

    utils.ensure_directory(spec.compile_dir)
    local argv = vim.list_extend({ spec.compile.exec }, vim.deepcopy(spec.compile.args or {}))
    vim.system(argv, { cwd = spec.compile_dir }, function(res)
        vim.schedule(function()
            entry.compiling = false
            -- Re-read the mtime: capture what we actually compiled (the file may
            -- have changed again while g++ was running).
            entry.mtime = source_mtime(spec.source)
            if res.code == 0 then
                entry.compiled, entry.error = true, nil
            else
                entry.compiled, entry.error = false, "compilation failed:\n" .. (res.stderr or "")
            end
            local waiters = entry.waiters
            entry.waiters = nil
            for _, w in ipairs(waiters or {}) do
                w(entry.compiled == true, entry.error)
            end
        end)
    end)
end

---Save the buffers a run depends on, honouring `save_current_file` /
---`save_all_files`. Every run mode calls this before compiling/running so a run
---never uses stale, unsaved source. (Helper sources are additionally flushed by
---`prepare`, covering the `save_current_file`-only case.)
---@param bufnr integer the solution buffer
---@param cfg table buffer configuration
function M.save_sources(bufnr, cfg)
    if cfg.save_all_files then
        vim.cmd("silent! wall")
    elseif cfg.save_current_file and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent! write")
        end)
    end
end

--------------------------------------------------------------------------------
-- Per-buffer run state (active mode + checker toggle)
--------------------------------------------------------------------------------

M.MODES = { "normal", "all", "stress", "interactive" }

---Runtime state keyed by a buffer's file path (not bufnr) so it survives the
---buffer being unloaded and reopened during a session. `explicit` records whether
---the user chose the mode by hand (`:Tuna run <mode>` / the menu); until they do,
---the mode is auto-detected from the sibling files present.
---@type table<string, { mode: string, explicit: boolean, checker: boolean, source: string?, compare: tuna.CompareSpec? }>
local state = {}

local DEFAULT_STATE = { mode = "normal", explicit = false, checker = true, source = nil, compare = nil }

---@private
---Whether an entry says anything the defaults don't, so an untouched problem never
---gets a sidecar written for it.
---@param s table
---@return boolean
local function is_default(s)
    return s.mode == DEFAULT_STATE.mode
        and s.explicit == DEFAULT_STATE.explicit
        and s.checker == DEFAULT_STATE.checker
        and s.source == nil
        and s.compare == nil
end

---@private
---A compare spec as something JSON survives. `{ "float", tol = 1e-6 }` has both an
---array part and a hash part, and JSON has no such shape: encoding it turns the
---builtin's name into the *string* key `"1"`, so a decoded spec would no longer
---answer `method[1]` and `compare.lua` would stop recognising it. Store it named
---instead. A custom compare *function* can't be persisted at all (and can't be set
---from `:Tuna compare`), so it is simply dropped.
---@param method tuna.CompareSpec?
---@return string|table|nil
local function encode_compare(method)
    if type(method) == "string" then
        return method
    end
    if type(method) == "table" and type(method[1]) == "string" then
        local out = { method = method[1] }
        for k, v in pairs(method) do
            if k ~= 1 then
                out[k] = v
            end
        end
        return out
    end
    return nil
end

---@private
---@param stored string|table|nil
---@return tuna.CompareSpec?
local function decode_compare(stored)
    if type(stored) == "string" then
        return stored
    end
    if type(stored) == "table" and type(stored.method) == "string" then
        local out = { stored.method }
        for k, v in pairs(stored) do
            if k ~= "method" then
                out[k] = v
            end
        end
        return out
    end
    return nil
end

---@private
---How this problem is run — the compare method, the checker toggle, the chosen mode
---and interactive source — is a property of the *problem*, so it lives in the
---per-problem sidecar and comes back after a restart. (`recent.lua`'s state file is
---for the opposite kind of thing: where *you* were, which is per machine.)
---
---Hydrated lazily on the first access for a path, so there is no session load step
---and no autocmd: any entry point that reads or writes the state gets it.
---@param path string
---@return table
local function state_for(path)
    if not state[path] then
        local s = vim.tbl_extend("force", {}, DEFAULT_STATE)
        if path ~= "" then
            local stored = require("tuna.sidecar").get_entry(path, "run")
            if stored then
                -- Validated on the way in: the sidecar is a plain file a user may edit
                -- (or copy between problems), and a nonsense mode would send a bare
                -- `:Tuna run` somewhere impossible.
                if vim.tbl_contains(M.MODES, stored.mode) then
                    s.mode = stored.mode
                    s.explicit = stored.explicit == true
                end
                if type(stored.checker) == "boolean" then
                    s.checker = stored.checker
                end
                if vim.tbl_contains({ "live", "feed", "interactor" }, stored.source) then
                    s.source = stored.source
                end
                s.compare = decode_compare(stored.compare)
            end
        end
        state[path] = s
    end
    return state[path]
end

---@private
---Write a path's state back to its sidecar. Entries that say nothing beyond the
---defaults are removed rather than stored, so turning a setting off again leaves no
---trace (and `sidecar.set_entry` drops the file entirely once nothing else is in it).
---@param path string
local function persist(path)
    if path == "" then
        return
    end
    local s = state[path]
    if not s or is_default(s) then
        require("tuna.sidecar").set_entry(path, "run", nil)
        return
    end
    require("tuna.sidecar").set_entry(path, "run", {
        mode = s.mode,
        explicit = s.explicit,
        checker = s.checker,
        source = s.source,
        compare = encode_compare(s.compare),
    })
end

---@param path string
---@return string # the raw stored mode (see `resolve_mode` for the effective one)
function M.get_mode(path)
    return state_for(path).mode
end

---Set the buffer's mode as an explicit user choice (so it sticks across runs).
---@param path string
---@param mode string
function M.set_mode(path, mode)
    local s = state_for(path)
    s.mode = mode
    s.explicit = true
    persist(path)
end

---Auto-detect a run mode from the helper files sitting beside the solution:
---an `interactor.*` ⇒ interactive; both a `gen.*` and a `brute.*` ⇒ stress;
---otherwise normal. (A `checker.*` is orthogonal — it's applied within any mode
---via the checker toggle, so it doesn't select a mode.)
---@param dir string problem directory
---@param cfg table buffer config
---@return string
function M.detect_mode(dir, cfg)
    if M.find(dir, "interactor", cfg) then
        return "interactive"
    end
    if M.find(dir, "generator", cfg) and M.find(dir, "reference", cfg) then
        return "stress"
    end
    return "normal"
end

---The mode a bare `:Tuna run` should use. If the user picked a mode explicitly it
---sticks — unless the files that mode needs have since disappeared (e.g. `brute.*`
---was deleted), in which case we fall back to auto-detection so the run doesn't
---fail on a now-impossible mode. Otherwise the mode is auto-detected each time.
---@param path string solution file path
---@param dir string problem directory
---@param cfg table buffer config
---@return string
function M.resolve_mode(path, dir, cfg)
    local s = state_for(path)
    if s.explicit then
        local m = s.mode
        local usable = true
        if m == "stress" then
            usable = M.find(dir, "generator", cfg) ~= nil and M.find(dir, "reference", cfg) ~= nil
        end
        -- interactive stays usable even with no interactor.* — its live/feed sources
        -- need no helper files, so an explicit interactive choice always sticks.
        if usable then
            return m
        end
    end
    return M.detect_mode(dir, cfg)
end

---@param path string
---@return boolean
function M.checker_enabled(path)
    return state_for(path).checker
end

---@param path string
---@param enabled boolean
function M.set_checker(path, enabled)
    state_for(path).checker = enabled
    persist(path)
end

---The buffer's chosen interactive source ("live"|"feed"|"interactor"), or nil when
---unset (the caller then defaults it — interactor if one exists, else live).
---@param path string
---@return string?
function M.get_source(path)
    return state_for(path).source
end

---Remember the interactive source so a later bare `:Tuna run` repeats it.
---@param path string
---@param source string
function M.set_source(path, source)
    state_for(path).source = source
    persist(path)
end

---The buffer's runtime compare-method override (set via `:Tuna compare …`), or nil
---when unset (the caller then uses `config.output_compare_method`).
---@param path string
---@return tuna.CompareSpec?
function M.get_compare(path)
    return state_for(path).compare
end

---Override the compare method for this buffer (nil clears it back to config).
---@param path string
---@param method tuna.CompareSpec?
function M.set_compare(path, method)
    state_for(path).compare = method
    persist(path)
end

return M
