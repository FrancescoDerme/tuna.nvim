-- lua/tuna/submit.lua
--
-- Submit the current solution to an online judge via an external tool. The design
-- is a small **provider registry** (`M.providers[name]`): a provider receives a
-- resolved context and does the submitting. The shipped default is the "command"
-- provider, which expands a configurable shell command through the modifier engine
-- (adding `$(URL)` and `$(LANG)` to the usual `$(FABSPATH)`/`$(FNAME)`/… set) and
-- runs it in a terminal (toggleterm if installed, else a native `:terminal` split).
--
-- The problem URL is found by scanning the file header for a configurable marker
-- (e.g. `submit at: <url>`, embedded by a template at receive time) and, failing
-- that, from a per-problem sidecar (`.tuna.json`) that the receive path writes.

local config = require("tuna.config")
local utils = require("tuna.utils")

local M = {}

--------------------------------------------------------------------------------
-- Per-problem sidecar (written by receive, read as a URL fallback here)
--------------------------------------------------------------------------------

---Absolute path of a directory's task sidecar.
---@param dir string problem directory
---@param cfg table
---@return string
local function store_path(dir, cfg)
    return vim.fs.normalize(dir) .. "/" .. (cfg.submit.url_store_file or ".tuna.json")
end

---Read a directory's sidecar as a table (empty table if absent/unreadable), so
---writers can merge their field without clobbering the others (url/name/group vs
---the per-file submit verdicts).
---@param dir string
---@param cfg table
---@return table
local function read_store(dir, cfg)
    local content = utils.read_file(store_path(dir, cfg))
    if content then
        local ok, decoded = pcall(vim.json.decode, content)
        if ok and type(decoded) == "table" then
            return decoded
        end
    end
    return {}
end

---Write a sidecar table back to disk.
---@param dir string
---@param cfg table
---@param store table
local function write_store(dir, cfg, store)
    local ok, encoded = pcall(vim.json.encode, store)
    if ok then
        utils.write_file(store_path(dir, cfg), encoded)
    end
end

---Persist a received task's metadata (url/name/group) beside its source, so submit
---can recover the URL even when the file has no header marker. Merges into any
---existing sidecar (keeps stored submit verdicts). No-op without a URL.
---@param dir string problem directory
---@param task tuna.CCTask
---@param cfg table
function M.write_task_store(dir, task, cfg)
    if not task.url or task.url == "" then
        return
    end
    local store = read_store(dir, cfg)
    store.url, store.name, store.group = task.url, task.name, task.group
    write_store(dir, cfg, store)
end

---Read a problem directory's task sidecar, or nil if absent/unreadable.
---@param dir string
---@param cfg table
---@return { url: string?, name: string?, group: string?, submit: table? }?
function M.read_task_store(dir, cfg)
    local content = utils.read_file(store_path(dir, cfg))
    if not content then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, content)
    return ok and type(decoded) == "table" and decoded or nil
end

---File modification time as a `"sec.nsec"` string, or nil — used to detect a
---solution being edited after a verdict was recorded (so a stale verdict isn't
---restored across a restart). Nanosecond precision disambiguates same-second edits
---(on filesystems that provide it; otherwise it degrades to second granularity).
---@param path string
---@return string?
local function file_mtime(path)
    local st = vim.uv.fs_stat(path)
    if not st or not st.mtime then
        return nil
    end
    return st.mtime.sec .. "." .. (st.mtime.nsec or 0)
end

---Persist a final verdict for one solution file into its directory's sidecar, keyed
---by file name. `entry.mtime` (captured at submit time) lets a later edit invalidate
---it. Merges so url/name/group and other files' verdicts are preserved.
---@param path string absolute solution path
---@param entry table { state, text, url?, mtime? }
---@param cfg table
local function write_submit_status(path, entry, cfg)
    local dir = vim.fn.fnamemodify(path, ":h")
    local store = read_store(dir, cfg)
    store.submit = type(store.submit) == "table" and store.submit or {}
    store.submit[vim.fn.fnamemodify(path, ":t")] = entry
    write_store(dir, cfg, store)
end

--------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------

---Find the submission URL for a buffer: a `submit.url` function, else the header
---marker pattern scanned over the first `url_scan_lines` lines, else the sidecar.
---@param bufnr integer
---@param filepath string
---@param cfg table resolved buffer config
---@return string?
local function resolve_url(bufnr, filepath, cfg)
    local scfg = cfg.submit
    if type(scfg.url) == "function" then
        return scfg.url({ bufnr = bufnr, filepath = filepath })
    end
    if type(scfg.url) == "string" and scfg.url ~= "" then
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, scfg.url_scan_lines or 10, false)
        for _, line in ipairs(lines) do
            local url = line:match(scfg.url)
            if url then
                return url
            end
        end
    end
    local store = M.read_task_store(vim.fn.fnamemodify(filepath, ":h"), cfg)
    return store and store.url or nil
end

---The submitter's language name for a buffer's filetype (from `submit.languages`).
---@param bufnr integer
---@param scfg table
---@return string?
local function resolve_lang(bufnr, scfg)
    local ft = vim.bo[bufnr].filetype
    return scfg.languages and scfg.languages[ft] or nil
end

---Build the submit context for a buffer, or nil + a reason on failure. Saves the
---buffer first (a submit must use the on-disk file).
---@param bufnr integer
---@return { bufnr: integer, filepath: string, url: string, lang: string?, cfg: table, modifiers: table }?, string?
function M.context(bufnr)
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    if filepath == "" then
        return nil, "the current buffer has no file to submit."
    end
    local cfg = config.get_buffer_config(bufnr)
    local scfg = cfg.submit

    if vim.bo[bufnr].modified then
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent write")
        end)
    end

    local url = resolve_url(bufnr, filepath, cfg)
    if not url then
        return nil,
            "no submission URL found — add a URL marker to the header (see `submit.url`), "
                .. "or receive the problem so its URL is stored in the sidecar."
    end
    local lang = resolve_lang(bufnr, scfg)
    if not lang then
        return nil,
            ("no submit language for filetype '%s' — set `submit.languages.%s`."):format(
                vim.bo[bufnr].filetype,
                vim.bo[bufnr].filetype
            )
    end

    local modifiers = vim.tbl_extend("force", utils.file_format_modifiers, { URL = url, LANG = lang })
    return { bufnr = bufnr, filepath = filepath, url = url, lang = lang, cfg = cfg, modifiers = modifiers }
end

--------------------------------------------------------------------------------
-- Terminal runner (overridable seam `M.run_terminal` — tests replace it)
--------------------------------------------------------------------------------

local cached = {} -- reused terminals: { tt = <toggleterm Terminal>, native = { buf, chan } }

---Run `cmd` in a native `:terminal` split, reusing one shell across submits.
---@param cmd string
---@param scfg table
local function run_native(cmd, scfg)
    local split = scfg.direction == "horizontal" and "botright split" or "botright vsplit"

    if not scfg.reuse_terminal then
        vim.cmd(split)
        vim.cmd.enew()
        vim.fn.termopen({ vim.o.shell, "-c", cmd })
        vim.cmd("startinsert")
        return
    end

    local n = cached.native
    if n and vim.api.nvim_buf_is_valid(n.buf) and n.chan then
        local win
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(w) == n.buf then
                win = w
                break
            end
        end
        if win then
            vim.api.nvim_set_current_win(win)
        else
            vim.cmd(split)
            vim.api.nvim_win_set_buf(0, n.buf)
        end
        pcall(vim.fn.chansend, n.chan, cmd .. "\n")
        vim.cmd("startinsert")
        return
    end

    -- Fresh shell terminal; send the command once the shell has settled.
    vim.cmd(split)
    vim.cmd.enew()
    local chan = vim.fn.termopen(vim.o.shell)
    cached.native = { buf = vim.api.nvim_get_current_buf(), chan = chan }
    vim.defer_fn(function()
        pcall(vim.fn.chansend, chan, cmd .. "\n")
    end, 120)
    vim.cmd("startinsert")
end

---Run `cmd` in a cached toggleterm terminal (mirrors the maintainer's setup).
---@param cmd string
---@param scfg table
---@param tt table the `toggleterm.terminal` module
local function run_toggleterm(cmd, scfg, tt)
    if not cached.tt then
        cached.tt = tt.Terminal:new({
            direction = scfg.direction == "horizontal" and "horizontal" or "vertical",
            close_on_exit = false,
        })
    end
    if not cached.tt.job_id then
        cached.tt:spawn()
    end
    cached.tt:send(cmd)
end

---Run a submit command in a terminal per `scfg.terminal` ("auto"|"toggleterm"|"split").
---Overridable for testing.
---@param cmd string
---@param scfg table
function M.run_terminal(cmd, scfg)
    local want = scfg.terminal or "auto"
    if want ~= "split" then
        local ok, tt = pcall(require, "toggleterm.terminal")
        if ok then
            run_toggleterm(cmd, scfg, tt)
            return
        end
        if want == "toggleterm" then
            utils.notify("submit: toggleterm requested but not installed; using a native terminal.", "WARN")
        end
    end
    run_native(cmd, scfg)
end

--------------------------------------------------------------------------------
-- Per-buffer submit state + lualine status
--------------------------------------------------------------------------------
-- One entry per solution file path holds that problem's last submit verdict,
-- kept until the file is submitted again. lualine reads the *current* buffer's
-- entry, so the indicator follows you from problem to problem and never expires
-- on its own (the terminal path is the exception — it can't learn the verdict,
-- so it clears its "submitting …" after `status_time`).

---@class tuna.SubmitState
---@field state string  "pending"|"accepted"|"rejected"|"partial"|"error"
---@field text string   display text
---@field url string?   submission URL, if parsed
---@field final boolean whether `state` is a terminal verdict
---@field token integer invalidates a pending timeout when superseded

M.state = {} ---@type table<string, tuna.SubmitState>
local token_seq = 0

local FINAL = { accepted = true, rejected = true, partial = true }

---Absolute file-path key for a buffer.
---@param bufnr integer?
---@return string
local function buf_path(bufnr)
    return vim.api.nvim_buf_get_name(bufnr or vim.api.nvim_get_current_buf())
end

local function refresh_status()
    pcall(vim.cmd, "redrawstatus") -- nudge lualine to re-evaluate now
end

---Set (or update) a solution's submit state and refresh lualine. When
---`timeout_ms` > 0 and the state isn't final, it auto-clears after that delay —
---used by the fire-and-forget terminal path, which never learns the verdict.
---@param path string
---@param state string
---@param text string
---@param url string?
---@param timeout_ms integer?
---@return integer? token the state's token (for callers that must detect being
---superseded by a newer submit / a manual clear), or nil if the path was empty.
local function set_state(path, state, text, url, timeout_ms)
    if path == nil or path == "" then
        return nil
    end
    token_seq = token_seq + 1
    local st = { state = state, text = text, url = url, final = FINAL[state] == true, token = token_seq }
    M.state[path] = st
    refresh_status()
    if timeout_ms and timeout_ms > 0 and not st.final then
        vim.defer_fn(function()
            local cur = M.state[path]
            if cur and cur.token == st.token then
                M.state[path] = nil
                refresh_status()
            end
        end, timeout_ms)
    end
    return st.token
end

---Clear a buffer's submit state (manual dismiss).
---@param bufnr integer?
function M.clear(bufnr)
    M.state[buf_path(bufnr)] = nil
    refresh_status()
end

---Arm a one-shot autocmd that clears the buffer's verdict as soon as the file is
---edited — a shown verdict is stale the moment its source changes. Re-arming
---replaces any previous arm (the augroup is per buffer, cleared each time).
---@param bufnr integer
local function arm_invalidation(bufnr)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
        return
    end
    local group = vim.api.nvim_create_augroup("TunaSubmitInvalidate_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = group,
        buffer = bufnr,
        once = true,
        desc = "Invalidate the Tuna submit verdict when the solution is edited",
        callback = function(ev)
            M.clear(ev.buf)
        end,
    })
end

---Whether the current (or given) buffer has a submit status to show (lualine `cond`).
---@param bufnr integer?
---@return boolean
function M.is_submitting(bufnr)
    return M.state[buf_path(bufnr)] ~= nil
end

---Display text for the current (or given) buffer's submit status. Empty when none.
---@param bufnr integer?
---@return string
function M.status(bufnr)
    local st = M.state[buf_path(bufnr)]
    return st and ("🐟 " .. st.text) or ""
end

---Highlight group for the current (or given) buffer's verdict (for a lualine `color`).
---@param bufnr integer?
---@return string?
function M.status_hl(bufnr)
    local st = M.state[buf_path(bufnr)]
    if not st then
        return nil
    end
    return (config.current_setup.submit.verdict_hl or {})[st.state]
end

---Restore a persisted final verdict for a buffer from its sidecar, so the lualine
---indicator survives a restart. Skips if already tracked, if the entry isn't a final
---verdict, or if the file's mtime no longer matches the one recorded at submit time
---(the solution was edited since). Called from the `BufReadPost` autocmd.
---@param bufnr integer
function M.restore(bufnr)
    local path = buf_path(bufnr)
    if path == "" or M.state[path] then
        return
    end
    -- Global config for the sidecar path (cheap on every BufReadPost); the store
    -- file name isn't something a per-dir config realistically changes.
    local store = M.read_task_store(vim.fn.fnamemodify(path, ":h"), config.current_setup)
    local entry = store and type(store.submit) == "table" and store.submit[vim.fn.fnamemodify(path, ":t")]
    if type(entry) ~= "table" or not FINAL[entry.state] then
        return
    end
    if entry.mtime ~= file_mtime(path) then
        return -- edited since the verdict was recorded
    end
    set_state(path, entry.state, entry.text, entry.url)
    arm_invalidation(bufnr)
end

--------------------------------------------------------------------------------
-- Watch mode: run the submit as a tracked job and parse the verdict
--------------------------------------------------------------------------------

---Strip ANSI escape sequences (colors, cursor moves) from a string.
---@param s string
---@return string
local function strip_ansi(s)
    return (s:gsub("\27%[[0-9;]*[A-Za-z]", ""))
end

---Classify a status line into a verdict state via `submit.verdicts`, or nil.
---@param line string
---@param scfg table
---@return string?
local function classify(line, scfg)
    local lower = line:lower()
    for _, rule in ipairs(scfg.verdicts or {}) do
        if lower:find(rule[1]) then
            return rule[2]
        end
    end
    return nil
end

---The latest non-empty "current line" in a stdout blob, accounting for the `\r`
---in-place updates the submitter uses to refresh one status line.
---@param blob string
---@return string?
local function last_segment(blob)
    local seg = nil
    for piece in strip_ansi(blob):gmatch("[^\r\n]+") do
        local trimmed = piece:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            seg = trimmed
        end
    end
    return seg
end

---Run the submit command as a tracked async job, parsing stdout for the judge
---verdict and driving the per-buffer state. No terminal. On a run that never
---reaches a final verdict (login expired, crash, non-reporting tool) it lands in
---an `error` state and notifies with the stderr tail.
---@param ctx table
---@param cmd string expanded shell command
local function run_watch(ctx, cmd)
    local path = ctx.filepath
    local scfg = ctx.cfg.submit
    -- The file was just saved by M.context, so this mtime identifies the exact
    -- source the verdict belongs to; persist it so a later edit invalidates it.
    local submit_mtime = file_mtime(path)
    -- This job "owns" the buffer's state only while its own tokens are the latest;
    -- a manual clear or a newer submit supersedes it, and its exit handler must not
    -- clobber that. `my_token` tracks our last write; `reached_final` records our
    -- own outcome independent of the (mutable) shared state.
    local my_token = set_state(path, "pending", "submitting " .. vim.fn.fnamemodify(path, ":t") .. "…")
    local reached_final = false

    local out_acc, err_acc, url = "", "", nil

    local function on_stdout(data)
        if reached_final then
            return -- we already have a terminal verdict; ignore trailing output
        end
        out_acc = out_acc .. data
        url = out_acc:match("[Ss]ubmission url:%s*(%S+)") or url
        local seg = last_segment(out_acc)
        if seg then
            local state = classify(seg, scfg)
            if state then
                my_token = set_state(path, state, seg, url)
                if FINAL[state] then
                    reached_final = true
                    -- Persist the verdict (survives a restart) and drop it the moment
                    -- the solution is edited.
                    write_submit_status(path, { state = state, text = seg, url = url, mtime = submit_mtime }, ctx.cfg)
                    arm_invalidation(ctx.bufnr)
                end
            end
        end
    end

    vim.system({ vim.o.shell, "-c", cmd }, {
        text = true,
        stdout = function(_, data)
            if data then
                vim.schedule(function()
                    on_stdout(data)
                end)
            end
        end,
        stderr = function(_, data)
            if data then
                err_acc = err_acc .. data
            end
        end,
    }, function(res)
        vim.schedule(function()
            if reached_final then
                return -- this job parsed a verdict; keep it
            end
            -- Only report an error if our pending state is still the one showing
            -- (not cleared or replaced by a newer submit of the same file).
            local st = M.state[path]
            if not (st and st.token == my_token) then
                return
            end
            local tail = strip_ansi(err_acc):gsub("%s+$", "")
            if tail == "" then
                tail = "exited with code " .. tostring(res.code)
            end
            set_state(path, "error", "submit failed", url)
            utils.notify("submit failed — " .. tail, "ERROR")
        end)
    end)
end

--------------------------------------------------------------------------------
-- Providers
--------------------------------------------------------------------------------

---@type table<string, fun(ctx: table)>
M.providers = {}

-- Default provider: expand the configured shell command and either run it in a
-- terminal (fire-and-forget) or, when `submit.watch` is set, as a tracked job whose
-- verdict is shown in lualine. Both drive the per-buffer submit state.
M.providers.command = function(ctx)
    local scfg = ctx.cfg.submit
    local template = scfg.command
    if not template or template == "" then
        utils.notify("submit: set `submit.command` (or choose another `submit.provider`).")
        return
    end
    local cmd = utils.format_modifiers(template, ctx.modifiers, ctx.filepath)
    local name = vim.fn.fnamemodify(ctx.filepath, ":t")

    if scfg.watch then
        run_watch(ctx, cmd)
        return
    end

    M.run_terminal(cmd, scfg)
    utils.notify("submitting " .. name .. " (" .. ctx.lang .. ")…", "INFO")
    -- Terminal path can't learn the verdict, so flash a pending state that clears.
    set_state(ctx.filepath, "pending", "submitting " .. name .. "…", nil, scfg.status_time)
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

---Submit the solution in `bufnr`.
---@param bufnr integer
function M.submit(bufnr)
    local ctx, err = M.context(bufnr)
    if not ctx then
        utils.notify("submit: " .. err)
        return
    end
    local name = ctx.cfg.submit.provider or "command"
    local provider = M.providers[name]
    if not provider then
        utils.notify("submit: unknown provider '" .. tostring(name) .. "'.")
        return
    end
    provider(ctx) -- the provider drives the per-buffer submit state
end

return M
