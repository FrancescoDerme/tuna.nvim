-- lua/tuna/tools.lua
--
-- Helper programs, the sibling files a problem folder grows around a solution (a checker, a
-- generator, a bruteforce, an interactor), and how each problem is run.
--
-- Helpers are *ordinary source files*, in any language, found by name beside the solution
-- (`tool_names`) or set in the config, and compiled and run with the same config-driven
-- commands as a solution. So stress testing, special judging and interactive runs need no
-- `.tuna.lua`: what a problem does follows from the files it has and the mode it is run in.
--
--   * finding     — `helper(role, solution, cfg)`, the one rule for every role
--   * compiling   — `prepare(spec, cb)`, reusing a build of this session while its source,
--                   the headers it includes and its command are unchanged (`build_stamp`,
--                   C and C++ only, every other language building on every run), with
--                   concurrent callers queued behind one compile; a solution's build is
--                   reused the same way (`reuse_build`)
--   * run state   — each problem's mode, interactive source, checker and compare override,
--                   automatic until forced, kept in its sidecar

local utils = require("tuna.utils")

local M = {}

---The roles a helper can fill, in the order they are offered (completion, the menu).
M.ROLES = { "checker", "generator", "bruteforce", "interactor" }

---A helper ready to prepare and spawn.
---@class tuna.HelperSpec
---@field exec string
---@field args string[] run arguments, the role's `$(INPUT)`/`$(OUTPUT)`/`$(ANSWER)` among them
---@field cwd string the directory it runs in
---@field role string what it is (`M.ROLES`), which keys its build pane
---@field source string? the file it is built from
---@field compile { exec: string, args: string[] }? its compile command, nil when there is none
---@field compile_dir string?

---Neovim's filetype for a path, from its name alone (no buffer needed).
---@param path string
---@return string # filetype, or "" when undetectable
local function filetype_of(path)
    return vim.filetype.match({ filename = path }) or ""
end

--------------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------------

---Find a helper source file for `role` beside the solution.
---A candidate must match one of the role's base names (any extension) *and* have
---a `run_command` configured for its filetype, and not be a header — that filters out
---compiled artefacts (`checker.o`, `checker` binaries), editor backups and a `checker.h`.
---@param dir string problem directory to search (non-recursive)
---@param role string "checker" | "generator" | "bruteforce" | "interactor"
---@param cfg table buffer configuration
---@return string? # absolute path, or nil if none found
function M.find(dir, role, cfg)
    for _, base in ipairs(cfg.tool_names[role] or {}) do
        local hits = vim.fn.globpath(dir, base .. ".*", false, true)
        table.sort(hits)
        for _, path in ipairs(hits) do
            local ft = filetype_of(path)
            if ft ~= "" and cfg.run_command[ft] and not M.is_header(path) then
                return path
            end
        end
    end
    return nil
end

---Whether `path` is a helper (checker/generator/bruteforce/interactor) rather than
---a solution, matched by base name against `tool_names`.
---@param path string
---@param cfg table buffer configuration
---@return boolean
function M.is_helper(path, cfg)
    local base = vim.fn.fnamemodify(path, ":t:r")
    for _, list in pairs(cfg.tool_names) do
        for _, n in ipairs(list) do
            if base == n then
                return true
            end
        end
    end
    return false
end

-- What a header is called, in the languages that have them. Neovim gives a header its
-- language's filetype (a `.h` is C++), so the extension is the only thing that tells one
-- from a source with a `main` of its own.
local HEADER_EXTENSIONS = { h = true, hh = true, hpp = true, hxx = true, ["h++"] = true, inl = true, ipp = true, tpp = true }

---Whether `path` is a header, code for a solution to include rather than a program.
---@param path string
---@return boolean
function M.is_header(path)
    return HEADER_EXTENSIONS[vim.fn.fnamemodify(path, ":e"):lower()] == true
end

---Whether `path` serves a solution rather than being one: a helper (by name) or a header
---(by extension). None is ever taken for a solution (run-all, `:Tuna next`, a contest's
---problems, the history), and a run started from one runs the solution beside it.
---@param path string
---@param cfg table buffer configuration
---@return boolean
function M.is_support(path, cfg)
    return M.is_helper(path, cfg) or M.is_header(path)
end

---Resolve the buffer a run should target. Normally that's `bufnr` itself, but if
---`bufnr` is a *helper* file (e.g. you're editing `checker.cpp`) or a header, redirect to
---the solution beside it so running/stress/etc. still work. The solution is a sibling
---non-helper source of the same extension; when several exist, prefer a
---conventional name (`main`/`sol`/`solution`). The chosen solution is loaded into a
---(possibly hidden) buffer without stealing focus.
---@param bufnr integer
---@param cfg table buffer configuration
---@return integer? # the solution buffer, or nil on failure
---@return string? # error message, or an info note when auto-picked from several
function M.solution_bufnr(bufnr, cfg)
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" or not M.is_support(path, cfg) then
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
            and not M.is_support(f, cfg)
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
    if not vim.api.nvim_buf_is_loaded(sb) then
        -- Loading it is a side effect of running from a helper file, not something the
        -- user asked for, so it must not leave a swapfile behind for a file they never
        -- opened — a stray `.main.cpp.swp` in the problem directory, and an E325
        -- ATTENTION prompt about it after a crash. `swapfile` is buffer-local and read
        -- when the buffer loads, so it has to be off *before* `bufload`; setting it
        -- afterwards would create the swap and then delete it. Only for a buffer we are
        -- loading ourselves: one the user already has open keeps the swapfile it came
        -- with, since turning the option off on a loaded buffer removes it.
        vim.bo[sb].swapfile = false
        vim.fn.bufload(sb)
        -- If it does become a buffer the user is looking at, it is theirs again and
        -- wants the protection back, at whatever the global default says then — turning
        -- the option back on creates the swap there and then. Read with `vim.go`, not
        -- `vim.o`: for a buffer-local option `vim.o` reports the *current* buffer's
        -- value, which inside this callback is the buffer whose flag was just turned
        -- off, so it would restore false onto itself and do nothing.
        vim.api.nvim_create_autocmd("BufWinEnter", {
            buffer = sb,
            once = true,
            callback = function()
                if vim.api.nvim_buf_is_valid(sb) then
                    vim.bo[sb].swapfile = vim.go.swapfile
                end
            end,
        })
    end
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
---@return { exec: string, args: string[], compile: { exec: string, args: string[] }?, compile_dir: string?, cwd: string, source: string }?
---@return string? # error message when resolution fails
local function program(path, cfg)
    local ft = filetype_of(path)
    local run_cmd = ft ~= "" and cfg.run_command[ft]
    if not run_cmd then
        return nil, "no run command for filetype '" .. ft .. "' (" .. vim.fn.fnamemodify(path, ":t") .. ")"
    end
    local run = utils.eval_command(path, run_cmd)
    if not run then
        return nil, "run command for '" .. ft .. "' is malformed"
    end

    local dir = vim.fn.fnamemodify(path, ":p:h")
    local spec = { exec = run.exec, args = run.args, cwd = dir, source = vim.fn.fnamemodify(path, ":p") }

    if cfg.compile_command[ft] then
        local compile = utils.eval_command(path, cfg.compile_command[ft])
        if not compile then
            return nil, "compile command for '" .. ft .. "' is malformed"
        end
        spec.compile = compile
        spec.compile_dir = utils.normalize_path(cfg.compile_directory or ".", dir) .. "/"
    end
    return spec
end

-- The arguments a role's program is handed after its own run arguments: a testlib checker
-- reads `<input> <output> <answer>`, an interactor `<input> <answer>`. A configured command
-- given no arguments gets these too; one given some has placed them itself.
local ROLE_ARGS = {
    checker = { "$(INPUT)", "$(OUTPUT)", "$(ANSWER)" },
    interactor = { "$(INPUT)", "$(ANSWER)" },
}

-- The option that sets each role's helper in the config, instead of discovering one.
local ROLE_OPTION = {
    checker = { "checker" },
    generator = { "stress", "generator" },
    bruteforce = { "stress", "bruteforce" },
    interactor = { "interactive", "interactor" },
}

-- The placeholders a helper's arguments keep until it is spawned for one testcase.
local RUN_PLACEHOLDERS = { INPUT = true, OUTPUT = true, ANSWER = true }

---Expand the file modifiers in a configured argument against the solution, leaving the
---per-run placeholders for the spawn that fills them.
---@param solution string
---@param arg string
---@return string?
local function eval_helper_arg(solution, arg)
    local kept = arg:gsub("%$%((%u+)%)", function(name)
        if RUN_PLACEHOLDERS[name] then
            return "\1" .. name .. "\2"
        end
    end)
    local out = utils.eval_string(solution, kept)
    return out and (out:gsub("\1(%u+)\2", "$(%1)")) or nil
end

---A runnable spec for a helper file: compiled and run with its language's commands, or run
---as it is when tuna knows no command for its language (a prebuilt binary).
---@param role string
---@param path string
---@param cfg table
---@return tuna.HelperSpec
local function spec_for_file(role, path, cfg)
    local spec, err = program(path, cfg)
    if not spec then
        -- An unknown language is the normal shape of a prebuilt binary. Any other failure
        -- is a known language with a malformed command, which running the file as a
        -- binary won't fix, so it is worth a word.
        if err and not err:match("^no run command") then
            utils.notify(
                role .. ": " .. err .. ", running '" .. vim.fn.fnamemodify(path, ":t") .. "' as a prebuilt binary.",
                "WARN"
            )
        end
        spec = { exec = path, args = {}, cwd = vim.fn.fnamemodify(path, ":p:h") }
    end
    spec.args = vim.list_extend(spec.args, vim.deepcopy(ROLE_ARGS[role] or {}))
    ---@cast spec tuna.HelperSpec
    spec.role = role
    return spec
end

---A spawn's arguments with the per-run placeholders (`$(INPUT)`, `$(OUTPUT)`, `$(ANSWER)`)
---filled in from `files`, name to path. Anything else is left as it is.
---@param args string[]
---@param files table<string, string>
---@return string[]
function M.expand_args(args, files)
    return vim.tbl_map(function(arg)
        return (arg:gsub("%$%((%u+)%)", function(name)
            return files[name]
        end))
    end, args)
end

---The helper filling `role` for a solution, as a spec ready to prepare and spawn, or nil
---when there is none. One rule for every role: a helper set in the config (`checker`,
---`stress.generator`, `stress.bruteforce`, `interactive.interactor`) is used instead of a
---sibling file found through `tool_names`. A string there is a path to a helper file, a
---table an `{ exec, args }` command. Nothing is cached, so what is on disk now decides. The
---spec carries its `role`, which is what the results UI keys its build pane by.
---@param role "checker"|"generator"|"bruteforce"|"interactor"
---@param solution string absolute path of the solution
---@param cfg table resolved configuration
---@return tuna.HelperSpec? spec
---@return string? note why a configured helper can't be used, when it can't
function M.helper(role, solution, cfg)
    local set = cfg ---@type any
    for _, key in ipairs(ROLE_OPTION[role]) do
        set = type(set) == "table" and set[key] or nil
    end
    local dir = vim.fn.fnamemodify(solution, ":p:h")
    if type(set) == "string" then
        local path = utils.eval_string(solution, set)
        path = path and utils.normalize_path(utils.expand_home(path), dir)
        if not (path and utils.file_exists(path)) then
            return nil, ("the configured %s '%s' does not exist"):format(role, set)
        end
        return spec_for_file(role, path, cfg)
    elseif type(set) == "table" and set.exec then
        local exec = utils.eval_string(solution, set.exec)
        if not exec or vim.fn.executable(exec) ~= 1 then
            return nil, ("the configured %s command '%s' can't be run"):format(role, tostring(set.exec))
        end
        local args = {}
        for i, a in ipairs(set.args or {}) do
            args[i] = eval_helper_arg(solution, a)
            if not args[i] then
                return nil, ("the configured %s command has a malformed argument '%s'"):format(role, a)
            end
        end
        if #args == 0 then
            args = vim.deepcopy(ROLE_ARGS[role] or {})
        end
        return { exec = exec, args = args, cwd = dir, role = role }
    elseif set ~= nil then
        return nil, ("the configured %s is neither a path nor an { exec, args } command"):format(role)
    end
    local path = M.find(dir, role, cfg)
    return path and spec_for_file(role, path, cfg) or nil
end

--------------------------------------------------------------------------------
-- Compilation (builds reused while nothing they are made from changes)
--------------------------------------------------------------------------------

-- The compiler flags naming a directory headers are searched in, as `-Idir` or `-I dir`.
local INCLUDE_FLAGS = { "-I", "-iquote", "-isystem", "-idirafter" }

---The directories a compile command searches for headers, from its own flags. The compiler's
---built-in search path (the system and standard library headers) is not among them: those
---change only when the compiler does, and the first run of a session builds anyway.
---@param compile { exec: string, args: string[]? }
---@param cwd string? the directory the compiler runs in, which a relative one is under
---@return string[]
local function include_dirs(compile, cwd)
    local dirs, args = {}, compile.args or {}
    for i, arg in ipairs(args) do
        for _, flag in ipairs(INCLUDE_FLAGS) do
            local dir = arg == flag and args[i + 1] or (arg:sub(1, #flag) == flag and arg:sub(#flag + 1)) or nil
            if dir and dir ~= "" then
                dirs[#dirs + 1] = utils.normalize_path(dir, cwd)
                break
            end
        end
    end
    return dirs
end

---Every file a build of `source` reads that can be found, as `path\0sha256`: the source,
---and each header it includes, followed into the headers they include, looked for beside
---the file including it and in `dirs`. An `#include` switched off by the preprocessor is
---followed too, which can only cost a build that was not needed, never reuse one that is
---stale.
---@param source string
---@param dirs string[]
---@return string[]
local function build_inputs(source, dirs)
    local seen, found = {}, {}
    local function visit(path)
        path = vim.fs.normalize(path)
        if seen[path] then
            return
        end
        seen[path] = true
        local f = io.open(path, "r")
        if not f then
            return
        end
        local text = f:read("*a") or ""
        f:close()
        found[#found + 1] = path .. "\0" .. vim.fn.sha256(text)
        local here = vim.fs.dirname(path)
        for name in ("\n" .. text):gmatch('\n[ \t]*#[ \t]*include[ \t]*["<]([^">\n]+)[">]') do
            for _, dir in ipairs({ here, unpack(dirs) }) do
                local candidate = dir .. "/" .. name
                if vim.uv.fs_stat(candidate) then
                    visit(candidate)
                    break
                end
            end
        end
    end
    visit(source)
    return found
end

-- The languages whose builds tuna can see the whole of, by filetype: what they read besides
-- the source is the headers its `#include` lines name, which `build_inputs` follows. Any
-- other language may build from files tuna knows nothing of (a Rust `mod`, a Java class in
-- a file of its own), so its builds are not reused across runs.
local FOLLOWED_LANGUAGES = { c = true, cpp = true, objc = true, objcpp = true, cuda = true }

---What a build of `source` is made from: the compile command, then every file it reads
---(`build_inputs`) with a hash of its contents. Two builds with the same stamp make the same
---program, so a source is rebuilt when it, a header it includes or its compile flags change,
---and not otherwise. The contents decide, not the modification time: a save that leaves
---the text as it was built (an edit a formatter undid, a `:w` with nothing changed) is no
---change, and the files are read for their includes anyway. Nil when tuna can't see
---everything the build reads (a language it does not follow, a source that can't be read),
---and a build without a stamp is never reused by another run.
---@param source string?
---@param compile { exec: string, args: string[]? }
---@param cwd string? the directory the compiler runs in
---@return string?
function M.build_stamp(source, compile, cwd)
    if not (source and FOLLOWED_LANGUAGES[filetype_of(source)]) then
        return nil
    end
    local inputs = build_inputs(source, include_dirs(compile, cwd))
    if #inputs == 0 then
        return nil
    end
    return table.concat({ compile.exec or "", table.concat(compile.args or {}, "\0"), unpack(inputs) }, "\n")
end

---If `path` is open in a modified buffer, write it to disk. Running a helper must pick up
---unsaved edits, or the rebuild check below sees the stale file and skips the recompile, and
---run-all saves every solution it runs the same way. Must run on the main loop.
---@param path string?
function M.flush_buffer(path)
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

---The builds made this session, by source path: what each was made from (`stamp`) and how
---it went, so a run reuses the build of a source nothing has changed (the solution in every
---mode, `gen.cpp` and `brute.cpp` on every stress run) instead of compiling it again. It
---lives for the session only: the first run after a restart builds, so a binary on disk is
---never trusted to be what the current flags and headers would make. `spec` is the run a
---helper's build was made or reused for: every run resolves its helpers anew, so the same
---spec is the same run.
---@type table<string, { stamp: string?, spec: table?, compiled: boolean?, error: string?, stdout: string?, stderr: string?, compiling: boolean?, waiters: (fun(ok: boolean, err: string?, output: string?))[]? }>
local builds = {}

---@param source string
local function build_entry(source)
    local key = vim.fs.normalize(source)
    builds[key] = builds[key] or {}
    return builds[key]
end

---Whether the program a build made is still there. Only a run command naming a path
---(`./sol`) can be checked; one naming an interpreter (`java Sol`) is taken at its word.
---@param exec string? the run command's program
---@param cwd string? the directory it runs in
---@return boolean
local function program_exists(exec, cwd)
    if not exec or not exec:find("/", 1, true) then
        return true
    end
    return vim.uv.fs_stat(utils.normalize_path(exec, cwd)) ~= nil
end

---A successful build of `source` from this session that is still good: made from the same
---stamp, with its program still there.
---@param entry table?
---@param stamp string?
---@param exec string?
---@param cwd string?
---@return boolean
local function still_good(entry, stamp, exec, cwd)
    return stamp ~= nil and entry ~= nil and entry.compiled == true and entry.stamp == stamp and program_exists(exec, cwd)
end

---For a build made by its caller rather than `prepare` (the solution's, on the Compile row or
---a run-all header): the build of `source` this session can reuse, with what its compiler
---said, or nil and how to remember the one about to be made once it has succeeded. The
---stamp is taken now, before the compiler starts, so an edit made while it runs is a change
---the next run sees. A failure is not remembered: the next run builds again.
---@param source string?
---@param compile { exec: string, args: string[]? }
---@param compile_dir string?
---@param exec string? the run command's program
---@param run_dir string? the directory it runs in
---@return { stdout: string, stderr: string }? reused
---@return fun(stdout: string?, stderr: string?) remember
function M.reuse_build(source, compile, compile_dir, exec, run_dir)
    local stamp = M.build_stamp(source, compile, compile_dir)
    local entry = source and builds[vim.fs.normalize(source)]
    if still_good(entry, stamp, exec, run_dir) then
        ---@cast entry -nil
        return { stdout = entry.stdout or "", stderr = entry.stderr or "" }, function() end
    end
    return nil, function(stdout, stderr)
        if source and stamp then
            local e = build_entry(source)
            e.stamp, e.spec, e.compiled, e.error, e.stdout, e.stderr = stamp, nil, true, nil, stdout, stderr
        end
    end
end

---Ensure a spec produced by `program`/`helper` is compiled, then call `cb`. Within the run
---that built it a build is answered as it is, failed or not, without reading anything again:
---the checker is prepared for every testcase it judges. A new run reuses a successful build
---while its stamp holds (`build_stamp`) and builds again otherwise, a failure included.
---Concurrent callers queue behind the one compile. A spec without a `compile` step
---(interpreted language, or a prebuilt binary) is ready immediately.
---@param spec table
---@param cb fun(ok: boolean, err: string?, output: string?) `output` is what the compiler
---said on a build that succeeded, warnings included, for the pane the build step gives it
function M.prepare(spec, cb)
    -- Flush unsaved edits to the helper source first, so both the rebuild check
    -- and (for interpreted helpers) the run itself see the current code.
    M.flush_buffer(spec.source)

    if not spec.compile then
        cb(true)
        return
    end

    local entry = build_entry(spec.source)
    if entry.compiling then
        table.insert(entry.waiters, cb) -- answered when the compile running lands
        return
    end
    if entry.spec == spec then
        cb(entry.compiled == true, entry.error, entry.stderr)
        return
    end
    local stamp = M.build_stamp(spec.source, spec.compile, spec.compile_dir)
    if still_good(entry, stamp, spec.exec, spec.cwd) then
        entry.spec = spec
        cb(true, nil, entry.stderr)
        return
    end
    entry.stamp, entry.spec, entry.compiled, entry.error, entry.stdout, entry.stderr = stamp, spec, nil, nil, nil, nil
    entry.compiling, entry.waiters = true, { cb }

    utils.ensure_directory(spec.compile_dir)
    local argv = vim.list_extend({ spec.compile.exec }, vim.deepcopy(spec.compile.args or {}))
    local function settle(compiled, error_msg, output)
        entry.compiling = false
        entry.compiled, entry.error, entry.stderr = compiled, error_msg, output
        local waiters = entry.waiters
        entry.waiters = nil
        for _, w in ipairs(waiters or {}) do
            w(compiled, error_msg, output)
        end
    end
    -- pcall'd: a compiler that is not installed makes `vim.system` itself throw, and
    -- every queued caller still has to hear the answer — an exception here left
    -- `compiling` set and the queue waiting forever.
    local ok, spawn_err = pcall(vim.system, argv, { cwd = spec.compile_dir }, function(res)
        vim.schedule(function()
            if res.code == 0 then
                -- Warnings are kept as well as errors: the build step shows what each
                -- source's compiler said, and a helper that built with warnings has
                -- something to say about it.
                settle(true, nil, res.stderr)
            else
                settle(false, "compilation failed:\n" .. (res.stderr or ""))
            end
        end)
    end)
    if not ok then
        settle(false, "could not start '" .. tostring(spec.compile.exec) .. "': " .. tostring(spawn_err))
    end
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
            -- `update`, not `write`: an unchanged file is left untouched on disk.
            vim.cmd("silent! update")
        end)
    end
end

--------------------------------------------------------------------------------
-- Per-problem run settings: each automatic unless forced
--------------------------------------------------------------------------------

M.MODES = { "normal", "all", "stress", "interactive" }
M.SOURCES = { "live", "feed", "interactor" }

---Runtime state keyed by a solution's file path (not bufnr), so it survives the buffer
---being unloaded and reopened. `mode`, `source` and `checker` hold only what the user
---forced; nil is automatic. The checker can only be forced `"off"`, since forcing it on
---would mean the same as automatic.
---@type table<string, { mode: string?, source: string?, checker: "off"?, compare: tuna.CompareSpec? }>
local state = {}

---@private
---Whether an entry says anything the defaults don't, so an untouched problem never
---gets a sidecar written for it.
---@param s table
---@return boolean
local function is_default(s)
    return s.mode == nil and s.source == nil and s.checker == nil and s.compare == nil
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
---How this problem is run — the compare method, the checker setting, the chosen mode
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
        local s = {}
        if path ~= "" then
            local stored = require("tuna.sidecar").get_entry(path, "run")
            if stored then
                -- Validated on the way in: the sidecar is a plain file a user may edit
                -- (or copy between problems), and a nonsense mode would send a bare
                -- `:Tuna run` somewhere impossible.
                if vim.tbl_contains(M.MODES, stored.mode) then
                    s.mode = stored.mode
                end
                if vim.tbl_contains(M.SOURCES, stored.source) then
                    s.source = stored.source
                end
                if stored.checker == "off" then
                    s.checker = "off"
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
        source = s.source,
        checker = s.checker,
        compare = encode_compare(s.compare),
    })
end

---The mode forced for a solution, or nil when its mode is automatic.
---@param path string
---@return string?
function M.get_mode(path)
    return state_for(path).mode
end

---Force a mode, which sticks across runs and restarts, or pass nil to make it automatic.
---@param path string
---@param mode string?
function M.set_mode(path, mode)
    state_for(path).mode = mode
    persist(path)
end

---The mode a problem's helpers point to: an interactor means interactive, a generator
---and a bruteforce mean stress, anything else normal. Run-all is never chosen for you.
---@param solution string absolute path of the solution
---@param cfg table
---@return string
function M.detect_mode(solution, cfg)
    if M.helper("interactor", solution, cfg) then
        return "interactive"
    end
    if M.helper("generator", solution, cfg) and M.helper("bruteforce", solution, cfg) then
        return "stress"
    end
    return "normal"
end

---The mode a run without a mode keyword uses: the forced one while it can run, else the
---automatic one. Of the modes only stress needs helpers to run (interactive can always
---run live), so a forced stress missing its generator or bruteforce gives way, and
---applies again once both are back.
---@param solution string absolute path of the solution
---@param cfg table
---@return string mode
---@return string? note what gave way, when something did
function M.resolve_mode(solution, cfg)
    local auto = M.detect_mode(solution, cfg)
    local forced = state_for(solution).mode
    if forced == "stress" and not (M.helper("generator", solution, cfg) and M.helper("bruteforce", solution, cfg)) then
        return auto, "stress is forced but needs a generator and a bruteforce, running " .. auto .. " until both are back"
    end
    return forced or auto, nil
end

---The interactive source forced for a solution, or nil when it is automatic.
---@param path string
---@return string?
function M.get_source(path)
    return state_for(path).source
end

---Force an interactive source, or pass nil to make it automatic.
---@param path string
---@param source string?
function M.set_source(path, source)
    state_for(path).source = source
    persist(path)
end

---The interactive source a run uses: the forced one while it can run, else the
---interactor when there is one, else live. Only `interactor` needs a helper, so a forced
---interactor with none gives way to live, and applies again once one is back.
---@param solution string absolute path of the solution
---@param cfg table
---@return string source
---@return string? note what gave way, when something did
function M.resolve_source(solution, cfg)
    local has_interactor = M.helper("interactor", solution, cfg) ~= nil
    local auto = has_interactor and "interactor" or "live"
    local forced = state_for(solution).source
    if forced == "interactor" and not has_interactor then
        return auto, "the interactor source is forced but there is no interactor, running live until one is back"
    end
    return forced or auto, nil
end

---The checker setting of a solution: `"auto"` (use one when there is one) or `"off"`.
---@param path string
---@return "auto"|"off"
function M.checker_setting(path)
    return state_for(path).checker or "auto"
end

---@param path string
---@param setting "auto"|"off"
function M.set_checker(path, setting)
    state_for(path).checker = setting == "off" and "off" or nil
    persist(path)
end

---The checker a run judges with: the problem's checker while the setting is automatic and
---there is one, else `"builtin"`, plain output comparison.
---@param solution string absolute path of the solution
---@param cfg table
---@return "builtin"|table checker
---@return string? note why a configured checker can't be used
function M.resolve_checker(solution, cfg)
    if state_for(solution).checker == "off" then
        return "builtin", nil
    end
    local spec, note = M.helper("checker", solution, cfg)
    return spec or "builtin", note
end

---The buffer's runtime compare-method override (set via `:Tuna compare …`), or nil
---when unset (the caller then uses `config.output_compare_method`).
---@param path string
---@return tuna.CompareSpec?
function M.get_compare(path)
    return state_for(path).compare
end

---Override the compare method for this problem (nil clears it back to the configured one).
---@param path string
---@param method tuna.CompareSpec?
function M.set_compare(path, method)
    state_for(path).compare = method
    persist(path)
end

M._test = {
    ---Forget every build of the session, for a test whose stubbed compiler answers
    ---differently for a source that has not changed.
    forget_builds = function()
        builds = {}
    end,
}

return M
