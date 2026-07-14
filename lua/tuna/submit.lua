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

---First capture of a Lua `pattern` over a buffer's first `scan_lines` header lines,
---or nil. Shared by the URL resolver and the sidecar backfill.
---@param bufnr integer
---@param pattern any
---@param scan_lines integer?
---@return string?
local function scan_header(bufnr, pattern, scan_lines)
    if type(pattern) ~= "string" or pattern == "" then
        return nil
    end
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, scan_lines or 10, false)) do
        local cap = line:match(pattern)
        if cap and cap ~= "" then
            return cap
        end
    end
    return nil
end

---Ensure a problem's sidecar records its metadata, creating the sidecar if the
---problem was set up outside the receive flow (e.g. a hand-made file that only has
---the template header markers). Merges — the submit-verdict map is preserved — and
---is cheap when nothing changed. The `url` is synced from the resolved value; the
---`group` (contest) and `name` (problem) are backfilled from the header markers
---**only when the sidecar lacks them**, so a received problem keeps the authoritative
---Competitive Companion values.
---@param ctx table submit context (bufnr/filepath/url/cfg)
local function persist_task(ctx)
    local scfg = ctx.cfg.submit
    local dir = vim.fn.fnamemodify(ctx.filepath, ":h")
    local store = read_store(dir, ctx.cfg)
    local dirty = false

    if ctx.url and ctx.url ~= "" and store.url ~= ctx.url then
        store.url, dirty = ctx.url, true
    end
    if not store.group then
        local g = scan_header(ctx.bufnr, scfg.group, scfg.url_scan_lines)
        if g then
            store.group, dirty = g, true
        end
    end
    if not store.name then
        local n = scan_header(ctx.bufnr, scfg.name, scfg.url_scan_lines)
        if n then
            store.name, dirty = n, true
        end
    end

    if dirty then
        write_store(dir, ctx.cfg, store)
    end
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

---A friendly name for a solution in the submit status, resolved exactly like the URL:
---the `submit.name` header marker (e.g. `// problem: A - Two Together`) if present,
---else the problem name stored in the sidecar, else the file's basename (`main.cpp`).
---@param ctx table submit context (bufnr/filepath/cfg/scfg)
---@return string
local function display_name(ctx)
    local marked = scan_header(ctx.bufnr, ctx.scfg.name, ctx.scfg.url_scan_lines)
    if marked then
        return marked
    end
    local store = M.read_task_store(vim.fn.fnamemodify(ctx.filepath, ":h"), ctx.cfg)
    local nm = store and store.name
    if type(nm) == "string" and nm ~= "" then
        return nm
    end
    return vim.fn.fnamemodify(ctx.filepath, ":t")
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

---Remove a solution's persisted verdict from its directory's sidecar (a no-op if
---absent). Used by edit-invalidation so a stale verdict doesn't linger on disk once
---the source changes; url/name/group and other files' verdicts are preserved.
---@param path string absolute solution path
---@param cfg table
local function clear_submit_status(path, cfg)
    local dir = vim.fn.fnamemodify(path, ":h")
    local store = read_store(dir, cfg)
    local key = vim.fn.fnamemodify(path, ":t")
    if type(store.submit) == "table" and store.submit[key] ~= nil then
        store.submit[key] = nil
        write_store(dir, cfg, store)
    end
end

--------------------------------------------------------------------------------
-- Per-judge routing
--------------------------------------------------------------------------------

---Derive a judge key from a submission URL's host: "https://atcoder.jp/…" →
---"atcoder", "https://codeforces.com/…" → "codeforces", "contest.yandex.com" →
---"yandex". Lowercased; a URL without a host → "".
---@param url string?
---@return string
local function judge_of(url)
    local host = type(url) == "string" and url:match("://([^/]+)") or ""
    host = (host or ""):gsub("^www%.", "")
    local name = host:match("([%w%-]+)%.%w+$") or host
    return name:lower()
end

---The effective `submit` config for a URL: `submit.judges[<judge>]` (a partial
---override table) shallow-merged over the base `submit`, so any field
---(`command`/`verdicts`/`languages`/`watch`/…) can be set per judge with the base as
---fallback. No matching override → the base config unchanged (so the default,
---single-tool setup behaves exactly as before).
---@param scfg table base `submit` config
---@param url string?
---@return table
local function judge_scfg(scfg, url)
    local over = type(scfg.judges) == "table" and scfg.judges[judge_of(url)]
    if type(over) ~= "table" then
        return scfg
    end
    return vim.tbl_extend("force", scfg, over)
end

---Resolve the submit command from an effective config: a string, or a
---`function(ctx) -> string` for fully programmatic dispatch.
---@param ctx table
---@return string?
local function resolve_command(ctx)
    local c = ctx.scfg.command
    if type(c) == "function" then
        return c(ctx)
    end
    return c
end

--------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------

---Whether `url` looks like a real submission URL: an `http(s)://host…` address with
---no leftover `$(…)` template modifier. Guards the common "wrong URL" case — a raw
---template or a problem set up before it was received resolves the marker/sidecar to
---the literal placeholder `$(URL)`, which must never be handed to the submitter.
---@param url any
---@return boolean
local function is_valid_url(url)
    if type(url) ~= "string" or url:find("%$%(") then
        return false -- non-string, or an unexpanded modifier like the template's "$(URL)"
    end
    return url:match("^https?://[^%s/]+") ~= nil
end

---Find the submission URL for a buffer, in priority order: a `submit.url` function,
---else the header marker pattern scanned over the first `url_scan_lines` lines, else
---the sidecar. Each candidate is validated (`is_valid_url`) and an invalid one is
---skipped so a placeholder marker can still fall through to a real sidecar URL.
---@param bufnr integer
---@param filepath string
---@param cfg table resolved buffer config
---@return string? url the first valid candidate, or nil
---@return string? invalid the first rejected candidate (for a precise error), or nil
local function resolve_url(bufnr, filepath, cfg)
    local scfg = cfg.submit
    local candidates = {}
    if type(scfg.url) == "function" then
        candidates[#candidates + 1] = scfg.url({ bufnr = bufnr, filepath = filepath })
    else
        candidates[#candidates + 1] = scan_header(bufnr, scfg.url, scfg.url_scan_lines)
        local store = M.read_task_store(vim.fn.fnamemodify(filepath, ":h"), cfg)
        candidates[#candidates + 1] = store and store.url or nil
    end

    local invalid
    for _, c in ipairs(candidates) do
        if is_valid_url(c) then
            return c, nil
        end
        invalid = invalid or c -- remember the first non-nil-but-invalid candidate
    end
    return nil, invalid
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
---buffer first (a submit must use the on-disk file). `scfg` is the **effective**
---submit config (base with any `submit.judges[<judge>]` override applied), resolved
---once the URL — and thus the judge — is known; the providers use it throughout.
---@param bufnr integer
---@return { bufnr: integer, filepath: string, url: string, lang: string?, cfg: table, scfg: table, modifiers: table }?, string?
function M.context(bufnr)
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    if filepath == "" then
        return nil, "the current buffer has no file to submit."
    end
    local cfg = config.get_buffer_config(bufnr)

    if vim.bo[bufnr].modified then
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent write")
        end)
    end

    local url, invalid = resolve_url(bufnr, filepath, cfg)
    if not url then
        if invalid then
            return nil,
                ("resolved submission URL is not valid (%s), "):format(vim.inspect(invalid))
                    .. "fix the `submit at:` URL in the header or sidecar."
        end
        return nil,
            "no submission URL found, add a URL marker to the header (see `submit.url`), "
                .. "or receive the problem so its URL is stored in the sidecar."
    end
    -- Now that we know the URL (hence the judge), fold in any per-judge override.
    local scfg = judge_scfg(cfg.submit, url)
    local lang = resolve_lang(bufnr, scfg)
    if not lang then
        return nil,
            ("no submit language for filetype '%s', set `submit.languages.%s` (or `submit.judges.%s.languages.%s`)."):format(
                vim.bo[bufnr].filetype,
                vim.bo[bufnr].filetype,
                judge_of(url),
                vim.bo[bufnr].filetype
            )
    end

    local modifiers = vim.tbl_extend("force", utils.file_format_modifiers, { URL = url, LANG = lang })
    return {
        bufnr = bufnr,
        filepath = filepath,
        url = url,
        lang = lang,
        cfg = cfg,
        scfg = scfg,
        modifiers = modifiers,
    }
end

--------------------------------------------------------------------------------
-- Terminal runner (overridable seam `M.run_terminal` — tests replace it)
--------------------------------------------------------------------------------

local cached = {} -- reused terminals: { tt = <toggleterm Terminal>, native = { buf, chan } }

---Start a background native terminal: a hidden `:terminal` buffer hosting a shell,
---no window and no focus (mirrors the backgrounded toggleterm path when
---`submit.open_terminal` is false). Returns `{ buf, chan }` so it can be cached and
---reused. The buffer is reachable with `:b` if you want to inspect the output.
---@return { buf: integer, chan: integer }
local function spawn_native_background()
    local buf = vim.api.nvim_create_buf(true, false)
    local chan
    vim.api.nvim_buf_call(buf, function()
        chan = vim.fn.termopen(vim.o.shell)
    end)
    return { buf = buf, chan = chan }
end

---Run `cmd` in a native `:terminal`, reusing one shell across submits. When
---`submit.open_terminal` is false the shell runs in a hidden buffer (no split, no
---focus); otherwise it opens in a split and focuses it.
---@param cmd string
---@param scfg table
local function run_native(cmd, scfg)
    local background = scfg.open_terminal == false
    local split = scfg.direction == "horizontal" and "botright split" or "botright vsplit"

    if not scfg.reuse_terminal then
        if background then
            local n = spawn_native_background()
            vim.defer_fn(function()
                pcall(vim.fn.chansend, n.chan, cmd .. "\n")
            end, 120)
            return
        end
        vim.cmd(split)
        vim.cmd.enew()
        vim.fn.termopen({ vim.o.shell, "-c", cmd })
        vim.cmd("startinsert")
        return
    end

    local n = cached.native
    if n and vim.api.nvim_buf_is_valid(n.buf) and n.chan then
        if not background then
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
            vim.cmd("startinsert")
        end
        pcall(vim.fn.chansend, n.chan, cmd .. "\n")
        return
    end

    -- Fresh shell terminal; send the command once the shell has settled.
    if background then
        cached.native = spawn_native_background()
        vim.defer_fn(function()
            pcall(vim.fn.chansend, cached.native.chan, cmd .. "\n")
        end, 120)
        return
    end
    vim.cmd(split)
    vim.cmd.enew()
    local chan = vim.fn.termopen(vim.o.shell)
    cached.native = { buf = vim.api.nvim_get_current_buf(), chan = chan }
    vim.defer_fn(function()
        pcall(vim.fn.chansend, chan, cmd .. "\n")
    end, 120)
    vim.cmd("startinsert")
end

---Run `cmd` in a cached toggleterm terminal. `spawn()` starts the job with no
---window, so when `submit.open_terminal` is false the command runs in the background
---without stealing focus — the terminal is there to toggle open manually if you want
---to inspect it. When true, the terminal is opened (and focused) so its output/errors
---are visible immediately. `send(cmd, true)` passes `go_back = true` so toggleterm
---never auto-focuses a backgrounded terminal.
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
    if scfg.open_terminal ~= false then
        cached.tt:open() -- make the terminal visible, so submit output/errors are seen
    end
    cached.tt:send(cmd, scfg.open_terminal == false) -- go_back → don't focus a background term
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
-- One in-flight watch job per solution path (the `vim.system` handle). Its presence
-- is the "already submitting" lock that stops a spammed `<leader>cs` from firing
-- several real submissions at once; it's cleared when the job exits, times out, or is
-- cleared. Only the watch path tracks jobs (the terminal path is fire-and-forget).
local jobs = {} ---@type table<string, vim.SystemObj>
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

---Clear a buffer's submit state (manual dismiss) and cancel any in-flight watch job
---for it — the way to get rid of a lingering indicator after abandoning a submission.
---@param bufnr integer?
function M.clear(bufnr)
    local path = buf_path(bufnr)
    local handle = jobs[path]
    if handle then
        jobs[path] = nil
        pcall(function()
            handle:kill("sigterm") -- stop the tracked poll; the submission already happened
        end)
    end
    M.state[path] = nil
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
            M.clear(ev.buf) -- hide the lualine verdict now …
            -- … and drop the persisted verdict, so it doesn't linger in the sidecar
            -- (or get restored on a later reopen). Global config for the store path.
            clear_submit_status(vim.api.nvim_buf_get_name(ev.buf), config.current_setup)
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

---Resolve a highlight group's foreground to a `#rrggbb` string, or nil.
---@param group string
---@return string?
local function hl_fg(group)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if ok and hl and hl.fg then
        return string.format("#%06x", hl.fg)
    end
    return nil
end

---lualine `color` for the current (or given) buffer's verdict, from `verdict_hl[state]`.
---That value may be a **color table** (e.g. `{ fg = "#ff6c6b" }`, returned as-is so it
---can match your palette exactly) or a **highlight-group name** (its foreground is
---resolved into a foreground-only `{ fg, gui = "bold" }` table — matching the receive
---component's style, so the verdict is coloured without painting a section background).
---@param bufnr integer?
---@return table|string|nil
function M.status_hl(bufnr)
    local st = M.state[buf_path(bufnr)]
    if not st then
        return nil
    end
    local spec = (config.current_setup.submit.verdict_hl or {})[st.state]
    if type(spec) == "table" then
        return spec
    end
    if type(spec) ~= "string" then
        return nil
    end
    local fg = hl_fg(spec)
    return fg and { fg = fg, gui = "bold" } or spec
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

---Strip ANSI/terminal control from a string: OSC and CSI escape sequences (colors,
---cursor moves, private `?25l`-style show/hide, `\27[38;5;…m` 256-colour), any stray
---escape byte, and other C0 control characters (backspace, bell, …). `\t`/`\n`/`\r`
---are kept so line/segment scanning still works. Robust enough for a crossterm-styled
---submitter that redraws its status in place.
---@param s string
---@return string
local function strip_ansi(s)
    s = s:gsub("\27%].-\7", "") -- OSC … BEL
    s = s:gsub("\27%].-\27\\", "") -- OSC … ST
    s = s:gsub("\27%[[0-9;:<=>?]*[ -/]*[@-~]", "") -- CSI (params, intermediates, final)
    s = s:gsub("[\1-\8\11\12\14-\31\127]", "") -- other C0 controls + stray ESC (0x1b)
    return s
end

---Pick the most informative line from a tool's output to show on failure.
---A verbose submit CLI logs a wall of `[INFO]`/`[NETWORK]` progress plus a
---cookie-save on exit, so the *last* line ("[INFO] save cookie to: …") is noise, not
---the reason. It also tends to print a **specific** reason (the judge's own alert,
---e.g. `<judge> says: You can submit … again N seconds later`) followed by a
---**generic** `submission failed`; the specific line is what the user needs. Prefer,
---in order: the judge's own message (`says:`/`alert`), else a line naming the error
---(`[ERROR]`/`[FAILURE]`/error/fail/limit) — but if that is the generic
---"submission failed/error", prepend the nearest preceding specific line — else the
---last line that isn't progress noise, else the last non-empty line. If a specific
---and a generic line are both present they're joined (`reason — submission failed`).
---Searches stderr first, then stdout.
---@param err string raw stderr
---@param out string raw stdout
---@return string
local function meaningful_tail(err, out)
    local function is_generic(low)
        return low:find("submission failed") or low:find("submission error")
    end
    local function pick(blob)
        local lines = {}
        for line in strip_ansi(blob):gmatch("[^\r\n]+") do
            local t = line:gsub("^%s+", ""):gsub("%s+$", "")
            if t ~= "" then
                lines[#lines + 1] = t
            end
        end
        -- the judge's own alert is the real reason — surface it (rightmost wins).
        for i = #lines, 1, -1 do
            local low = lines[i]:lower()
            if low:find("says:") or low:find("alert") then
                return lines[i]
            end
        end
        -- else the last line flagged as an error / failure / limit.
        for i = #lines, 1, -1 do
            local low = lines[i]:lower()
            if
                low:find("%[error%]")
                or low:find("%[failure%]")
                or low:find("error")
                or low:find("fail")
                or low:find("limit")
            then
                -- A bare "submission failed" is generic; pair it with the nearest
                -- preceding specific flagged line if there is one.
                if is_generic(low) then
                    for j = i - 1, 1, -1 do
                        local lj = lines[j]:lower()
                        if
                            not is_generic(lj)
                            and (
                                lj:find("error")
                                or lj:find("fail")
                                or lj:find("limit")
                                or lj:find("says:")
                                or lj:find("alert")
                            )
                        then
                            return lines[j] .. " — " .. lines[i]
                        end
                    end
                end
                return lines[i]
            end
        end
        -- else last line that isn't routine progress/cookie chatter
        for i = #lines, 1, -1 do
            local low = lines[i]:lower()
            if not (low:find("^%[info%]") or low:find("^%[network%]") or low:find("cookie")) then
                return lines[i]
            end
        end
        return lines[#lines]
    end
    return pick(err) or pick(out) or ""
end

---Start index of the last (rightmost) match of Lua pattern `pat` in `hay`, or nil.
---@param hay string
---@param pat string
---@return integer?
local function last_match(hay, pat)
    local last, init = nil, 1
    while true do
        local s, e = hay:find(pat, init)
        if not s then
            break
        end
        last, init = s, math.max(e + 1, s + 1)
    end
    return last
end

---Scan a whole stdout blob for the judge verdict. A crossterm submitter redraws its
---status in place with cursor moves (no `\r`/`\n`), so after stripping control codes
---every frame collapses onto one line — a plain "last line" scan would then see all of
---"Testing … Running … Accepted" at once and match the *first* keyword. Instead we
---prefer a **final** verdict anywhere in the stream (the submission finished) over any
---pending keyword, taking the rightmost (most recent) match of each; only when no final
---verdict is present do we surface the latest pending frame. The display text is a tidy
---snippet from the matched keyword up to the next frame boundary (tab / newline),
---bounded — so lualine shows `Accepted` / `failed on test 6` / `Running (on test 6)`,
---not the whole concatenated blob.
---@param blob string
---@param scfg table
---@return string?, string?
local function scan_verdict(blob, scfg)
    local clean = strip_ansi(blob)
    local lower = clean:lower()

    -- Rightmost match among the rules of a given finality (final first, then pending).
    local function pick(want_final)
        local pos, state
        for _, rule in ipairs(scfg.verdicts or {}) do
            if (FINAL[rule[2]] == true) == want_final then
                local p = last_match(lower, rule[1])
                if p and (not pos or p >= pos) then
                    pos, state = p, rule[2]
                end
            end
        end
        return pos, state
    end

    local pos, state = pick(true)
    if not pos then
        pos, state = pick(false)
    end
    if not pos then
        return nil
    end

    -- Clean snippet: from the keyword to the next frame boundary, trimmed and capped.
    local snippet = (clean:sub(pos):match("^[^\r\n\t]*") or ""):gsub("%s+$", ""):sub(1, 60)
    return state, snippet
end

---Run the submit command as a tracked async job, parsing stdout for the judge
---verdict and driving the per-buffer state. No terminal. On a run that never
---reaches a final verdict (login expired, crash, non-reporting tool) it lands in
---an `error` state and notifies with the stderr tail.
---@param ctx table
---@param cmd string expanded shell command
local function run_watch(ctx, cmd)
    local path = ctx.filepath
    local scfg = ctx.scfg -- effective (per-judge) submit config
    local name = display_name(ctx) -- header/sidecar problem name if known, else the basename

    -- A new submit of the same file **supersedes** any in-flight one: cancel the old
    -- poll and take over lualine/sidecar with this submission. Detaching first
    -- (`jobs[path] = nil`) means the old job's callbacks — its `on_stdout`, exit, and
    -- timeout all gate on `jobs[path] == <their handle>` — see they're no longer the
    -- active job and stand down without touching this one's state.
    local previous = jobs[path]
    if previous then
        jobs[path] = nil
        pcall(function()
            previous:kill("sigterm")
        end)
    end

    -- The file was just saved by M.context, so this mtime identifies the exact
    -- source the verdict belongs to; persist it so a later edit invalidates it.
    local submit_mtime = file_mtime(path)
    -- This job "owns" the buffer's state only while its own tokens are the latest;
    -- a manual clear or a newer submit supersedes it, and its exit handler must not
    -- clobber that. `my_token` tracks our last write; `reached_final` records our
    -- own outcome independent of the (mutable) shared state. `settled` guards the
    -- safety timeout from firing once the job has already ended.
    local my_token = set_state(path, "pending", "submitting " .. name)
    local reached_final = false
    local settled = false

    local out_acc, err_acc, url = "", "", nil
    local handle ---@type vim.SystemObj  (forward-declared so callbacks can gate on it)

    local function on_stdout(data)
        if reached_final or jobs[path] ~= handle then
            return -- terminal verdict already, or superseded/cleared by a newer submit
        end
        out_acc = out_acc .. data
        url = strip_ansi(out_acc):match("[Ss]ubmission url:%s*(%S+)") or url
        if scfg.expects_verdict == false then
            return -- fire-and-forget tool: keep the "submitting …" flash, don't parse verdicts
        end
        local state, seg = scan_verdict(out_acc, scfg)
        -- Only push a state when it actually changed, so live redraw frames don't
        -- churn lualine (and the initial "submitting…" isn't overwritten by itself).
        local cur = M.state[path]
        if state and not (cur and cur.state == state and cur.text == seg) then
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

    handle = vim.system({ vim.o.shell, "-c", cmd }, {
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
            settled = true
            if jobs[path] == handle then
                jobs[path] = nil -- release the "already submitting" lock
            end
            if scfg.log_file and scfg.log_file ~= "" then
                local st = M.state[path]
                local dump = ("== submit %s (exit %s) ==\n-- parsed: %s / %s\n-- stdout (raw) --\n%s\n-- stderr --\n%s\n"):format(
                    os.date("%Y-%m-%d %H:%M:%S"),
                    tostring(res.code),
                    st and st.state or "nil",
                    st and st.text or "nil",
                    out_acc,
                    err_acc
                )
                pcall(vim.fn.writefile, vim.split(dump, "\n", { plain = true }), vim.fn.expand(scfg.log_file))
            end
            if reached_final then
                return -- this job parsed a verdict; keep it
            end
            -- Only report an error if our pending state is still the one showing
            -- (not cleared or replaced by a newer submit of the same file).
            local st = M.state[path]
            if not (st and st.token == my_token) then
                return
            end
            -- Fire-and-forget tool (no verdict stream): a clean exit is a successful
            -- submit — the tool's own output / opened browser is the feedback — so
            -- just clear the "submitting …" flash. Only a non-zero exit is an error.
            if scfg.expects_verdict == false and res.code == 0 then
                M.state[path] = nil
                refresh_status()
                return
            end
            -- Surface the tool's actual error line, not its trailing progress noise
            -- (a verbose CLI ends with lines like "[INFO] save cookie to: …"). Falls
            -- back to stdout for tools that report the reason there (e.g. the Rust
            -- submitter's "Unsupported domain: atcoder.jp").
            local tail = meaningful_tail(err_acc, out_acc)
            if tail == "" then
                tail = "exited with code " .. tostring(res.code)
            end
            set_state(path, "error", "submit failed", url)
            arm_invalidation(ctx.bufnr) -- a failed verdict is stale once the source changes
            utils.notify("submit failed — " .. tail, "ERROR")
        end)
    end)
    jobs[path] = handle

    -- Safety net: if the poll never finishes (the submitter hangs, or the user walks
    -- away), stop watching after `watch_timeout` ms so the "submitting…" indicator
    -- doesn't stick and the file can be resubmitted. The submission itself already
    -- happened; we just stop polling for its verdict. 0 disables.
    local tmo = scfg.watch_timeout or 0
    if tmo > 0 then
        vim.defer_fn(function()
            if settled or reached_final or jobs[path] ~= handle then
                return
            end
            jobs[path] = nil
            pcall(function()
                handle:kill("sigterm")
            end)
            local st = M.state[path]
            if st and st.token == my_token then
                M.state[path] = nil -- clear the stuck indicator (don't show a false failure)
                refresh_status()
            end
            utils.notify("submit: stopped watching " .. name .. " after timeout (no verdict).", "WARN")
        end, tmo)
    end
end

--------------------------------------------------------------------------------
-- Browser handoff
--------------------------------------------------------------------------------

---Turn a problem URL into the page to open for a manual browser submission.
---AtCoder gates submission behind a Cloudflare Turnstile challenge that no headless
---client can solve, so `:Tuna submit` there opens the submit page (task preselected)
---for the user to paste into. For other hosts we just open the given URL.
---@param url string
---@return string
local function browser_submit_url(url)
    local contest, task = url:match("atcoder%.jp/contests/([^/]+)/tasks/([^/?#]+)")
    if contest and task then
        return ("https://atcoder.jp/contests/%s/submit?taskScreenName=%s"):format(contest, task)
    end
    return url
end

---Open `url` in the user's browser. Prefers `vim.ui.open` (Neovim 0.10+), else falls
---back to the platform opener. Returns whether an opener was launched.
---@param url string
---@return boolean
local function open_url(url)
    if vim.ui and vim.ui.open then
        local ok, obj = pcall(vim.ui.open, url)
        if ok and obj then
            return true
        end
    end
    local cmd
    if vim.fn.has("mac") == 1 then
        cmd = { "open", url }
    elseif vim.fn.has("win32") == 1 then
        cmd = { "cmd", "/c", "start", "", url }
    else
        cmd = { "xdg-open", url }
    end
    return (pcall(vim.system, cmd, { detach = true }))
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
    local scfg = ctx.scfg -- effective (per-judge) submit config
    local template = resolve_command(ctx)
    if not template or template == "" then
        utils.notify("submit: set `submit.command` (or choose another `submit.provider`).")
        return
    end
    local cmd = utils.format_modifiers(template, ctx.modifiers, ctx.filepath)
    local name = display_name(ctx) -- header/sidecar problem name if known, else the basename

    if scfg.watch then
        run_watch(ctx, cmd)
        return
    end

    M.run_terminal(cmd, scfg)
    -- Terminal path can't learn the verdict, so flash a pending state that clears.
    -- (No `vim.notify` here — like the watch path, the lualine indicator is enough.)
    set_state(ctx.filepath, "pending", "submitting " .. name, nil, scfg.status_time)
end

-- Browser-handoff provider: for judges that can't be submitted to from a headless
-- client (AtCoder's Cloudflare Turnstile), open the submit page in the browser and
-- copy the source to the system clipboard so the user just pastes and submits.
M.providers.browser = function(ctx)
    local scfg = ctx.scfg
    local name = display_name(ctx)
    local page = browser_submit_url(ctx.url)

    -- The buffer was already saved by M.context; copy its source to the system
    -- clipboard so the manual submit is just a paste.
    pcall(function()
        local src = table.concat(vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false), "\n")
        vim.fn.setreg("+", src)
    end)

    if not open_url(page) then
        utils.notify("submit: could not open a browser for " .. page, "ERROR")
        return
    end
    -- Same lualine text as the terminal/watch paths ("submitting <name>"): the browser
    -- handoff is just a manual variant of the same submit flow (paste + click). Brief
    -- flash that clears after `status_time` (there's no verdict to track here).
    set_state(ctx.filepath, "pending", "submitting " .. name, ctx.url, scfg.status_time)
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
    local name = ctx.scfg.provider or "command" -- per-judge provider override allowed
    local provider = M.providers[name]
    if not provider then
        utils.notify("submit: unknown provider '" .. tostring(name) .. "'.")
        return
    end
    -- Backfill the sidecar (url + contest/name from the header markers for a hand-made
    -- problem), so the verdict can be persisted/restored even when it wasn't received.
    persist_task(ctx)
    provider(ctx) -- the provider drives the per-buffer submit state
end

return M
