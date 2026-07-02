-- lua/tuna/interactive.lua
--
-- Interactive problems: the solution talks to something over stdio, turn by turn.
-- Tuna offers three *sources* for the other side of that conversation:
--
--   * live       — YOU are the other side. The solution's stdout streams into the
--                  Output pane; you type into the (editable) Input pane and each
--                  <CR> line is sent to the solution's stdin. No auto-verdict.
--   * feed       — a pre-written input plays the other side, one line per turn: each
--                  time the solution emits a line, the next input line is sent. If
--                  the testcase has an expected output, the solution's stdout is
--                  judged against it; otherwise DONE.
--   * interactor — a written interactor program (interactor.*) is cross-wired to the
--                  solution and decides the verdict (exit 0 = accepted). Secondary:
--                  used automatically only when an interactor.* sibling exists, or
--                  when asked for explicitly.
--
-- `vim.system` only hands back stdout when a process *finishes*, so it can't cross-
-- wire live processes. We drop to `vim.uv.spawn` and forward bytes between pipes by
-- hand. Reuse: `runner.new()` resolves the solution's compile/run commands, dirs and
-- checker; the results UI is the shared `runner_ui` (this `InteractiveRunner` is a
-- `RunnerCore` subclass, like the normal and stress runners).

local api = vim.api
local uv = vim.uv
local config = require("tuna.config")
local utils = require("tuna.utils")
local runner = require("tuna.runner")
local checker = require("tuna.checker")
local testcases = require("tuna.testcases")
local tools = require("tuna.tools")
local core = require("tuna.runner.core")

local M = {}

-- Live interactive runners keyed by buffer, so `VimResized` can rebuild their UIs
-- and a fresh run can tear the previous one down (mirrors `stress.M.active`).
---@type table<integer, table>
M.active = {}

local SOURCES = { live = true, feed = true, interactor = true }
local DEFAULT_ARGS = { "$(INPUT)", "$(ANSWER)" }

---Write `content` to a fresh temp file and return its path.
---@param content string?
---@return string
local function temp_with(content)
    local path = vim.fn.tempname()
    utils.write_file(path, content or "")
    return path
end

--------------------------------------------------------------------------------
-- InteractiveRunner (a RunnerCore subclass the runner UI drives)
--------------------------------------------------------------------------------

local InteractiveRunner = core.extend()

---One extra "Run" pane row: which side is playing the interactor.
---@return string[][]
function InteractiveRunner:status_tail()
    return { { "source", self.source } }
end

---In `live` mode the Input pane is editable (you type responses into it), so the UI
---must not overwrite it on redraw.
function InteractiveRunner:pane_content(tc, name)
    if name == "so" then
        return tc.stdout
    elseif name == "eo" then
        return tc.expected
    elseif name == "si" then
        if self.source == "live" then
            return core.SKIP
        end
        return tc.stdin
    elseif name == "se" then
        return tc.stderr
    end
    return ""
end

---A single session runs at a time; killing it ends that session.
function InteractiveRunner:kill_all_processes()
    if self.sol_handle and self.sol_handle:is_active() then
        pcall(function()
            self.sol_handle:kill("sigkill")
        end)
    end
    if self.int_handle and self.int_handle:is_active() then
        pcall(function()
            self.int_handle:kill("sigkill")
        end)
    end
end

function InteractiveRunner:kill_process()
    self:kill_all_processes()
end

---Re-running one row restarts its session.
---@param idx integer
function InteractiveRunner:run_single(idx)
    local tc = self.tcdata[idx]
    if not tc or tc.tcnum == "Compile" then
        return
    end
    self:run_one_session(idx, function() end)
end

---Restart every session from the top (the UI's "run all again").
function InteractiveRunner:run_testcases()
    self:run_sessions()
end

---When `live`, make the Input pane editable and map <CR> to "send this line".
---@param ui table the RunnerUI
function InteractiveRunner:on_ui_shown(ui)
    if self.source ~= "live" then
        return
    end
    local w = ui.windows.si
    if not (w and api.nvim_buf_is_valid(w.bufnr)) then
        return
    end
    vim.bo[w.bufnr].modifiable = true
    api.nvim_buf_set_lines(w.bufnr, 0, -1, false, { "" })

    local nl = api.nvim_replace_termcodes("<CR>", true, false, true)
    local function send_line()
        self:live_send(api.nvim_get_current_line())
    end
    vim.keymap.set("i", "<CR>", function()
        send_line()
        -- Insert a real newline afterwards (noremap, so this mapping doesn't recurse)
        -- so the Input pane keeps a log of what you've sent.
        api.nvim_feedkeys(nl, "in", false)
    end, { buffer = w.bufnr })
    vim.keymap.set("n", "<CR>", send_line, { buffer = w.bufnr, nowait = true })
end

---Send one line to the live session's solution and echo it into the transcript.
---@param line string
function InteractiveRunner:live_send(line)
    local tc = self.tcdata[self.active_index]
    if not (tc and self.sol_in and not self.sol_in:is_closing()) then
        return
    end
    self.sol_in:write(line .. "\n")
    tc.stdout = (tc.stdout or "") .. "< " .. line .. "\n"
    self:update_ui(false)
end

--------------------------------------------------------------------------------
-- Sessions
--------------------------------------------------------------------------------

---Spawn the solution with three pipes and forward its output through `cbs`.
---`cbs`: on_stdout(data), on_stderr(data), on_exit(code, signal), on_error(msg),
---optional on_timeout() when `cbs.timed` and `self.timeout` are set.
---@param cbs table
function InteractiveRunner:spawn_solution(cbs)
    local sol_in, sol_out, sol_err = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    self.sol_in = sol_in
    local timer
    local done = false
    local handle

    local function cleanup()
        for _, p in ipairs({ sol_in, sol_out, sol_err }) do
            if p and not p:is_closing() then
                p:close()
            end
        end
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
        end
    end

    handle = uv.spawn(self.r.rc.exec, {
        args = self.r.rc.args,
        cwd = self.rundir,
        stdio = { sol_in, sol_out, sol_err },
    }, function(code, signal)
        if done then
            return
        end
        done = true
        self.sol_handle = nil
        cleanup()
        vim.schedule(function()
            cbs.on_exit(code, signal)
        end)
    end)

    if not handle then
        cleanup()
        vim.schedule(function()
            cbs.on_error("could not start solution '" .. tostring(self.r.rc.exec) .. "'")
        end)
        return
    end
    self.sol_handle = handle

    sol_out:read_start(function(err, data)
        if err or done or not data then
            return
        end
        vim.schedule(function()
            if not done then
                cbs.on_stdout(data)
            end
        end)
    end)
    sol_err:read_start(function(err, data)
        if err or done or not data then
            return
        end
        vim.schedule(function()
            if not done then
                cbs.on_stderr(data)
            end
        end)
    end)

    if self.timeout and cbs.timed then
        timer = uv.new_timer()
        timer:start(self.timeout, 0, function()
            if not done then
                vim.schedule(cbs.on_timeout)
                if handle:is_active() then
                    pcall(function()
                        handle:kill("sigkill")
                    end)
                end
            end
        end)
    end
end

---live: you are the interactor. No timeout (human-paced); kill via the UI.
---@param idx integer
---@param on_done fun()
function InteractiveRunner:run_live(idx, on_done)
    local tc = self.tcdata[idx]
    self.active_index = idx
    tc.status, tc.hlgroup = "LIVE", "TunaRunning"
    tc.stdout, tc.stderr = "", ""
    self:update_ui(true)

    self:spawn_solution({
        on_stdout = function(data)
            tc.stdout = tc.stdout .. data
            self:update_ui(false)
        end,
        on_stderr = function(data)
            tc.stderr = tc.stderr .. data
            self:update_ui(false)
        end,
        on_error = function(msg)
            tc.status, tc.hlgroup, tc.stderr = "FAILED", "TunaWarning", msg
            self.sol_in = nil
            self:update_ui(true)
            on_done()
        end,
        on_exit = function()
            tc.status, tc.hlgroup = "DONE", "TunaDone"
            self.sol_in = nil
            self:update_ui(true)
            on_done()
        end,
    })
end

---feed: the testcase input plays the interactor, one line per turn.
---@param idx integer
---@param on_done fun()
function InteractiveRunner:run_feed(idx, on_done)
    local tc = self.tcdata[idx]
    self.active_index = idx
    tc.status, tc.hlgroup = "RUNNING", "TunaRunning"
    tc.stdout, tc.stderr = "", ""
    self:update_ui(true)

    local lines = vim.split(tc.stdin or "", "\n", { plain = true })
    if #lines > 0 and lines[#lines] == "" then
        table.remove(lines) -- drop the empty part after a trailing newline
    end
    local li = 0
    local timed_out = false
    local function send_next()
        li = li + 1
        if li > #lines then
            if self.sol_in and not self.sol_in:is_closing() then
                self.sol_in:shutdown()
            end
            return
        end
        if self.sol_in and not self.sol_in:is_closing() then
            self.sol_in:write(lines[li] .. "\n")
        end
    end

    self:spawn_solution({
        timed = true,
        on_stdout = function(data)
            tc.stdout = tc.stdout .. data
            self:update_ui(false)
            -- One line per turn: when the solution completes a line of output,
            -- send it the next input line.
            if data:find("\n") then
                send_next()
            end
        end,
        on_stderr = function(data)
            tc.stderr = tc.stderr .. data
            self:update_ui(false)
        end,
        on_timeout = function()
            timed_out = true
        end,
        on_error = function(msg)
            tc.status, tc.hlgroup, tc.stderr = "FAILED", "TunaWarning", msg
            self.sol_in = nil
            self:update_ui(true)
            on_done()
        end,
        on_exit = function(code, signal)
            self.sol_in = nil
            if timed_out then
                tc.status, tc.hlgroup = "TIMEOUT", "TunaWrong"
                self:update_ui(true)
                return on_done()
            elseif signal and signal ~= 0 then
                tc.status, tc.hlgroup = "SIG " .. signal, "TunaWarning"
                self:update_ui(true)
                return on_done()
            elseif code ~= 0 then
                tc.status, tc.hlgroup = "RET " .. code, "TunaWarning"
                self:update_ui(true)
                return on_done()
            elseif tc.expected ~= nil then
                tc.judging = true
                checker.judge(tc, self.checker, self.config.output_compare_method, function(correct, message)
                    tc.judging = false
                    tc.checker_message = message
                    if correct == true then
                        tc.status, tc.hlgroup = "CORRECT", "TunaCorrect"
                    elseif correct == false then
                        tc.status, tc.hlgroup = "WRONG", "TunaWrong"
                    else
                        tc.status, tc.hlgroup = "DONE", "TunaDone"
                    end
                    self:update_ui(true)
                    on_done()
                end)
            else
                tc.status, tc.hlgroup = "DONE", "TunaDone"
                self:update_ui(true)
                on_done()
            end
        end,
    })
    -- Prime: many interactive solutions read a line before printing anything.
    send_next()
end

---interactor: cross-wire the solution and the interactor; the interactor rules.
---The exchange is teed into the transcript (Output pane); the interactor's stderr
---goes to the Errors pane.
---@param idx integer
---@param on_done fun()
function InteractiveRunner:run_interactor(idx, on_done)
    local tc = self.tcdata[idx]
    self.active_index = idx
    tc.status, tc.hlgroup = "RUNNING", "TunaRunning"
    tc.stdout, tc.stderr = "", ""
    self:update_ui(true)

    local input_file = temp_with(tc.stdin or "")
    local answer_file = temp_with(tc.expected or "")
    local files = { INPUT = input_file, OUTPUT = "/dev/null", ANSWER = answer_file }
    local raw = (#self.interactor.args > 0) and self.interactor.args or DEFAULT_ARGS
    local int_args = {}
    for i, a in ipairs(raw) do
        int_args[i] = a:gsub("%$%((%u+)%)", function(name)
            return files[name]
        end)
    end

    local sol_in, sol_out = uv.new_pipe(false), uv.new_pipe(false)
    local int_in, int_out, int_err = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    local sol_handle, int_handle, timer
    local done, verdict, int_exited = false, nil, false

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
        self.sol_handle, self.int_handle = nil, nil
        vim.schedule(function()
            if verdict == true then
                tc.status, tc.hlgroup = "CORRECT", "TunaCorrect"
            elseif verdict == false then
                tc.status, tc.hlgroup = "WRONG", "TunaWrong"
            else
                tc.status, tc.hlgroup = "DONE", "TunaDone"
            end
            self:update_ui(true)
            on_done()
        end)
    end

    sol_handle = uv.spawn(self.r.rc.exec, {
        args = self.r.rc.args,
        cwd = self.rundir,
        stdio = { sol_in, sol_out, nil },
    }, function(code, signal)
        safe_close(sol_handle)
        sol_handle = nil
        if not int_exited and not done and (code ~= 0 or (signal and signal ~= 0)) then
            verdict = false
            tc.stderr = (tc.stderr or "") .. "\n[solution exited with code " .. tostring(code) .. "]"
            finish()
        end
    end)
    if not sol_handle then
        for _, p in ipairs({ sol_in, sol_out, int_in, int_out, int_err }) do
            safe_close(p)
        end
        tc.status, tc.hlgroup, tc.stderr = "FAILED", "TunaWarning", "could not start solution"
        self:update_ui(true)
        return on_done()
    end
    self.sol_handle = sol_handle

    int_handle = uv.spawn(self.interactor.exec, {
        args = int_args,
        cwd = self.rundir,
        stdio = { int_in, int_out, int_err },
    }, function(code, signal)
        safe_close(int_handle)
        int_handle = nil
        int_exited = true
        verdict = (code == 0 and (not signal or signal == 0))
        finish()
    end)
    if not int_handle then
        tc.stderr = "could not start interactor '" .. tostring(self.interactor.exec) .. "'"
        finish()
        return
    end
    self.int_handle = int_handle

    -- Cross-wire, teeing each side of the exchange into the transcript.
    sol_out:read_start(function(err, data)
        if err or done then
            return
        end
        if data then
            if not int_in:is_closing() then
                int_in:write(data)
            end
            vim.schedule(function()
                if not done then
                    tc.stdout = (tc.stdout or "") .. data
                    self:update_ui(false)
                end
            end)
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
            vim.schedule(function()
                if not done then
                    tc.stdout = (tc.stdout or "") .. data
                    self:update_ui(false)
                end
            end)
        elseif not sol_in:is_closing() then
            sol_in:shutdown()
        end
    end)
    int_err:read_start(function(err, data)
        if not err and data then
            vim.schedule(function()
                if not done then
                    tc.stderr = (tc.stderr or "") .. data
                    self:update_ui(false)
                end
            end)
        end
    end)

    if self.timeout then
        timer = uv.new_timer()
        timer:start(self.timeout, 0, function()
            if not done then
                verdict = false
                tc.stderr = (tc.stderr or "") .. "\n[timed out after " .. self.timeout .. "ms]"
                finish()
            end
        end)
    end
end

---Run one session for row `idx`, dispatching on the source.
---@param idx integer
---@param on_done fun()
function InteractiveRunner:run_one_session(idx, on_done)
    if self.source == "interactor" then
        self:run_interactor(idx, on_done)
    elseif self.source == "feed" then
        self:run_feed(idx, on_done)
    else
        self:run_live(idx, on_done)
    end
end

---Run every testcase row's session, one after another.
function InteractiveRunner:run_sessions()
    local order = {}
    for i, tc in ipairs(self.tcdata) do
        if tc.tcnum ~= "Compile" then
            self:reset_row(tc)
            order[#order + 1] = i
        end
    end
    self.completed = false
    local k = 0
    local function step()
        k = k + 1
        if k > #order then
            self.completed = true
            self:update_ui(true)
            return
        end
        self:run_one_session(order[k], step)
    end
    step()
end

---Build the testcase rows (plus the solution Compile row).
function InteractiveRunner:load_rows()
    self.tcdata = {}
    if self.compile_entry then
        table.insert(self.tcdata, self.compile_entry)
    end
    local tctbl = testcases.buf_get_testcases(self.bufnr)
    local nums = {}
    if self.list then
        for _, s in ipairs(self.list) do
            local n = tonumber(s)
            if n and tctbl[n] then
                nums[#nums + 1] = n
            else
                utils.notify("interactive: testcase " .. tostring(s) .. " doesn't exist.")
            end
        end
    else
        nums = vim.tbl_keys(tctbl)
        table.sort(nums)
    end
    if #nums == 0 then
        -- Nothing to feed/replay: a single blank session (you just interact).
        table.insert(self.tcdata, { tcnum = 0, stdin = "", expected = nil, status = "", hlgroup = "TunaRunning" })
    else
        for _, n in ipairs(nums) do
            table.insert(self.tcdata, {
                tcnum = n,
                stdin = tctbl[n].input or "",
                expected = tctbl[n].output,
                status = "",
                hlgroup = "TunaRunning",
            })
        end
    end
end

--------------------------------------------------------------------------------
-- Helpers + entry point
--------------------------------------------------------------------------------

---Resolve a command spec (string or `{ exec, args }`) into argv. Only the exec is
---modifier-expanded; args are kept raw so their per-run $(INPUT)/$(ANSWER)
---placeholders survive.
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

---@param cfg table
---@param dir string
---@return boolean # whether an interactor is configured or discoverable
local function interactor_available(cfg, dir)
    if cfg.interactive and cfg.interactive.interactor then
        return true
    end
    return tools.find(dir, "interactor", cfg) ~= nil
end

---Rebuild any open interactive UIs after a `VimResized`.
function M.resize_all()
    for _, ir in pairs(M.active) do
        ir:resize_ui()
    end
end

---Run interactive judging for a buffer's solution.
---@param bufnr integer? defaults to the current buffer
---@param args string[]? a leading source keyword (live|feed|interactor) then testcase numbers
function M.run(bufnr, args)
    bufnr = bufnr or api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)

    local r = runner.new(bufnr)
    if not r then
        return
    end
    local cfg = r.config
    local dir = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":p:h")
    local path = api.nvim_buf_get_name(bufnr)
    tools.save_sources(bufnr, cfg) -- save the solution (interactor saved in tools.prepare)

    -- Pull a leading source keyword out of the args (the rest are testcase numbers).
    local list = args and vim.deepcopy(args) or nil
    if list and list[1] and SOURCES[list[1]] then
        tools.set_source(path, table.remove(list, 1))
    end
    if list and #list == 0 then
        list = nil
    end
    local source = tools.get_source(path) or (interactor_available(cfg, dir) and "interactor" or "live")

    -- Resolve the interactor only when it's the chosen source.
    local interactor
    if source == "interactor" then
        local icfg = cfg.interactive or {}
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
                        .. "set 'interactive.interactor', or use ':Tuna run interactive live|feed'."
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
    end

    local timeout = (cfg.maximum_time and cfg.maximum_time > 0) and cfg.maximum_time or nil
    local rundir = r.running_directory
    utils.ensure_directory(rundir)

    if M.active[bufnr] then
        M.active[bufnr]:delete_ui()
    end

    local ir = setmetatable({
        config = cfg,
        bufnr = bufnr,
        r = r,
        checker = r.checker,
        source = source,
        interactor = interactor,
        list = list,
        dir = dir,
        rundir = rundir,
        timeout = timeout,
        mode = "interactive",
        compile_entry = r.compile
                and { tcnum = "Compile", stdin = "", expected = nil, status = "", hlgroup = "TunaRunning" }
            or nil,
        tcdata = {},
        completed = false,
    }, InteractiveRunner)
    M.active[bufnr] = ir

    api.nvim_create_autocmd("BufUnload", {
        buffer = bufnr,
        once = true,
        callback = function()
            M.active[bufnr] = nil
        end,
    })

    ir:show_ui()
    ir:load_rows()
    ir:update_ui(true)

    -- Compile the interactor (if any) then run the sessions.
    local function prepare_and_start()
        if source ~= "interactor" then
            ir:run_sessions()
            return
        end
        tools.prepare(interactor, function(ok, err)
            if not ok then
                if ir.ui then
                    ir.ui:show_message(" interactive: interactor failed to compile ", err or "")
                end
                return
            end
            ir:run_sessions()
        end)
    end

    -- Compile the solution once (driving the Compile row), like the other runners.
    if r.compile then
        local ce = ir.compile_entry
        ce.status, ce.hlgroup, ce.start_time = "RUNNING", "TunaRunning", vim.uv.now()
        ir:update_ui(true)
        utils.ensure_directory(r.compile_directory)
        vim.system(vim.list_extend({ r.cc.exec }, vim.deepcopy(r.cc.args)), { cwd = r.compile_directory }, function(res)
            vim.schedule(function()
                ce.time = vim.uv.now() - ce.start_time
                ce.stdout, ce.stderr, ce.exit_code = res.stdout or "", res.stderr or "", res.code
                if res.code ~= 0 then
                    ce.status, ce.hlgroup = "RET " .. tostring(res.code), "TunaWarning"
                    ir:update_ui(true)
                    return
                end
                ce.status, ce.hlgroup = "DONE", "TunaDone"
                ir:update_ui(true)
                prepare_and_start()
            end)
        end)
    else
        prepare_and_start()
    end
end

return M
