-- lua/tuna/download.lua
--
-- Competitive Companion integration. This module *is* the listener (it folds in
-- what used to be `http.lua`) plus the pipeline that turns downloaded tasks into
-- files on disk. Three small objects form that pipeline:
--
--   Listener ──tasks──▶ TasksCollector ──batches──▶ BatchesSerialProcessor
--
--   * `Listener` opens a TCP socket Competitive Companion POSTs to. Each POST is
--     one "task" (one problem). It decodes the JSON and hands the task off.
--   * `TasksCollector` groups tasks by their `batch.id`. Companion tags every
--     task in a contest with the same batch id and a `batch.size`; the collector
--     emits a whole batch only once all `size` tasks have arrived. This is how we
--     reliably tell "one problem" from "a contest of N problems".
--   * `BatchesSerialProcessor` runs the per-batch handler one batch at a time.
--     Storing involves user prompts (paths, overwrite confirmations); serializing
--     keeps two contests downloaded back-to-back from interleaving their dialogs.
--
-- Compared to competitest this also exposes `status()`/`is_downloading()` so a
-- lualine component can show, at a glance, whether the listener is live and in
-- what mode — a quality-of-life win over competitest's notify-only status.

local utils = require("tuna.utils")
local config = require("tuna.config")
local testcases = require("tuna.testcases")
local judges = require("tuna.judges")

local M = {}

---A Competitive Companion task (https://github.com/jmerle/competitive-companion).
---Only the fields tuna reads are documented here.
---@class tuna.CCTask
---@field name string
---@field group string judge + contest, e.g. "Codeforces - Round 1000"
---@field url string
---@field tests { input: string, output: string }[]
---@field timeLimit number
---@field memoryLimit number
---@field languages table
---@field batch { id: string, size: integer }

--------------------------------------------------------------------------------
-- Listener: the TCP listener
--------------------------------------------------------------------------------

---@class tuna.Listener
---@field private server uv_tcp_t
local Listener = {}
Listener.__index = Listener

---Start listening on `address:port`, calling `callback` with each decoded task.
---@param address string
---@param port integer
---@param callback fun(task: tuna.CCTask)
---@return tuna.Listener|string # the listener, or an error message string
function Listener.new(address, port, callback)
    local server = vim.uv.new_tcp()
    if not server then
        return "failed to create TCP socket"
    end

    local ok, bind_err = server:bind(address, port)
    if not ok then
        return string.format("cannot bind to %s:%d%s", address, port, bind_err and (": " .. bind_err) or "")
    end

    local listening, listen_err = server:listen(128, function(err)
        if err then
            utils.notify("listener listen error: " .. err)
            return
        end
        local client = vim.uv.new_tcp()
        if not client then
            return
        end
        server:accept(client)

        -- Accumulate chunks until Companion closes its side of the connection
        -- (EOF, signalled by a nil chunk), then decode the request body.
        local chunks = {}
        client:read_start(function(read_err, chunk)
            if read_err then
                client:read_stop()
                client:close()
                return
            end
            if chunk then
                table.insert(chunks, chunk)
                return
            end
            client:read_stop()
            client:close()
            -- The JSON body is the last line, after the blank line ending the
            -- HTTP headers. `vim.json.decode` is safe to call off the main loop.
            local body = string.match(table.concat(chunks), "^.+\r\n(.+)$")
            if body then
                local ok_decode, task = pcall(vim.json.decode, body)
                if ok_decode and type(task) == "table" then
                    callback(task)
                end
            end
        end)
    end)
    if not listening then
        return string.format("cannot listen on %s:%d%s", address, port, listen_err and (": " .. listen_err) or "")
    end

    return setmetatable({ server = server }, Listener)
end

---Stop listening and release the socket.
function Listener:close()
    if self.server:is_active() and not self.server:is_closing() then
        self.server:close()
    end
end

--------------------------------------------------------------------------------
-- TasksCollector: group tasks into batches
--------------------------------------------------------------------------------

---@class tuna.TasksCollector
---@field private batches table<string, { size: integer, tasks: tuna.CCTask[] }>
---@field private callback fun(tasks: tuna.CCTask[])
local TasksCollector = {}
TasksCollector.__index = TasksCollector

---@param callback fun(tasks: tuna.CCTask[]) called once per fully-collected batch
---@return tuna.TasksCollector
function TasksCollector.new(callback)
    return setmetatable({ batches = {}, callback = callback }, TasksCollector)
end

---Add a task; emit its batch when the last task of the batch arrives.
---@param task tuna.CCTask
function TasksCollector:insert(task)
    local id = task.batch.id
    local batch = self.batches[id]
    if not batch then
        batch = { size = task.batch.size, tasks = {} }
        self.batches[id] = batch
    end
    table.insert(batch.tasks, task)
    if #batch.tasks == batch.size then
        self.batches[id] = nil
        self.callback(batch.tasks)
    end
end

--------------------------------------------------------------------------------
-- BatchesSerialProcessor: run one batch handler at a time
--------------------------------------------------------------------------------

---@class tuna.BatchesSerialProcessor
---@field private queue tuna.CCTask[][]
---@field private callback fun(tasks: tuna.CCTask[], finished: fun())
---@field private busy boolean
---@field private stopped boolean
local BatchesSerialProcessor = {}
BatchesSerialProcessor.__index = BatchesSerialProcessor

---@param callback fun(tasks: tuna.CCTask[], finished: fun()) must call `finished()` when done
---@return tuna.BatchesSerialProcessor
function BatchesSerialProcessor.new(callback)
    return setmetatable({ queue = {}, callback = callback, busy = false, stopped = false }, BatchesSerialProcessor)
end

---@param batch tuna.CCTask[]
function BatchesSerialProcessor:enqueue(batch)
    table.insert(self.queue, batch)
    self:process()
end

---@private
function BatchesSerialProcessor:process()
    if self.busy or self.stopped or #self.queue == 0 then
        return
    end
    self.busy = true
    local batch = table.remove(self.queue, 1)
    self.callback(
        batch,
        vim.schedule_wrap(function()
            self.busy = false
            self:process()
        end)
    )
end

function BatchesSerialProcessor:stop()
    self.stopped = true
end

--------------------------------------------------------------------------------
-- Storage: turn tasks into files
--------------------------------------------------------------------------------

---Expand tuna download modifiers (`$(PROBLEM)`, `$(JUDGE)`, ...) in `str`.
---@param str string
---@param task tuna.CCTask
---@param file_extension string
---@param remove_illegal_chars boolean strip characters illegal in filenames
---@param cfg table? resolved config (for `judge_parsers` and `date_format`)
---@return string? # evaluated string, or `nil` on failure
local function eval_download_modifiers(str, task, file_extension, remove_illegal_chars, cfg)
    -- Split "Judge - Contest" and normalise it via the (user-overridable) judge parsers.
    local judge, contest = judges.parse(task, cfg and cfg.judge_parsers)
    local date_format = cfg and cfg.date_format

    local java = (task.languages and task.languages.java) or {}
    ---@type table<string, string>
    local modifiers = {
        [""] = "$",
        HOME = vim.uv.os_homedir(),
        CWD = vim.fn.getcwd(),
        FEXT = file_extension,
        PROBLEM = task.name,
        GROUP = task.group,
        JUDGE = judge,
        CONTEST = contest,
        URL = task.url,
        MEMLIM = tostring(task.memoryLimit),
        TIMELIM = tostring(task.timeLimit),
        JAVA_MAIN_CLASS = java.mainClass or "Main",
        JAVA_TASK_CLASS = java.taskClass or "",
        DATE = tostring(os.date(date_format)),
    }

    if remove_illegal_chars then
        for name, value in pairs(modifiers) do
            -- HOME/CWD are real paths, so their separators must survive.
            if name ~= "HOME" and name ~= "CWD" then
                modifiers[name] = string.gsub(value, '[<>:"/\\|?*]', "_")
            end
        end
    end

    return utils.format_modifiers(str, modifiers)
end

---Evaluate a configured path (a string with modifiers, or a function).
---@param path string|fun(task: tuna.CCTask, file_extension: string): string
---@param task tuna.CCTask
---@param file_extension string
---@param cfg table? resolved config (for `judge_parsers`/`date_format`)
---@return string?
local function eval_path(path, task, file_extension, cfg)
    if type(path) == "function" then
        return path(task, file_extension)
    end
    return eval_download_modifiers(path, task, file_extension, true, cfg)
end

---Convert a task's `tests` list into a 0-indexed testcase table.
---@param task tuna.CCTask
---@return table<integer, { input: string, output: string }>
local function task_to_tctbl(task)
    local tctbl = {}
    for i, tc in ipairs(task.tests or {}) do
        tctbl[i - 1] = tc -- 0-based to match the rest of tuna
    end
    return tctbl
end

---Write a task's testcases beside `filepath` using `cfg`'s storage backend. The
---target file may not be open in a buffer yet, so this drives the pure backend
---writers directly instead of the `buf_*` helpers.
---@param filepath string source file absolute path
---@param tctbl table<integer, { input: string, output: string }>
---@param cfg table resolved configuration for the target directory
local function store_task_testcases(filepath, tctbl, cfg)
    local dir = vim.fn.fnamemodify(filepath, ":h")
    local tcdir = vim.fs.normalize(dir .. "/" .. cfg.testcases_directory) .. "/"
    if cfg.testcases_storage == "single_file" then
        testcases.single_file.write(tcdir .. utils.eval_string(filepath, cfg.testcases_single_file_format), tctbl)
    elseif cfg.testcases_storage == "directory" then
        testcases.directory.write(
            tcdir,
            tctbl,
            filepath,
            cfg.testcases_directory_format,
            cfg.testcases_directory_input,
            cfg.testcases_directory_output
        )
    else
        testcases.files.write(tcdir, tctbl, filepath, cfg.testcases_input_file_format, cfg.testcases_output_file_format)
    end
end

---Create the source file (from a template if configured) and write its testcases.
---Always writes, overwriting any existing file — the caller decides whether to
---proceed when the target already exists (see the floating override prompts in
---`store_single_problem`/`store_contest`).
---@param filepath string source file absolute path
---@param task tuna.CCTask
---@param cfg table resolved configuration for the target directory
local function store_downloaded_task(filepath, task, cfg)
    local file_extension = vim.fn.fnamemodify(filepath, ":e")

    -- Resolve the template: a string is a path with file-format modifiers; a
    -- table maps extension → path.
    local template_file
    if type(cfg.template_file) == "string" then
        template_file = utils.eval_string(filepath, cfg.template_file)
    elseif type(cfg.template_file) == "table" then
        template_file = cfg.template_file[file_extension]
    end
    if template_file then
        template_file = string.gsub(template_file, "^~", vim.uv.os_homedir()) -- expand leading ~
        if not utils.file_exists(template_file) then
            if type(cfg.template_file) == "table" then
                utils.notify('template file "' .. template_file .. "\" doesn't exist.", "WARN")
            end
            template_file = nil
        end
    end

    if template_file then
        if cfg.evaluate_template_modifiers then
            local content = utils.read_file(template_file) or ""
            local evaluated = eval_download_modifiers(content, task, file_extension, false, cfg)
            utils.write_file(filepath, evaluated or "")
        else
            utils.ensure_directory(vim.fn.fnamemodify(filepath, ":h"))
            vim.uv.fs_copyfile(template_file, filepath)
        end
    else
        utils.write_file(filepath, "")
    end

    store_task_testcases(filepath, task_to_tctbl(task), cfg)
    -- Persist the task's URL beside the source so `:Tuna submit` can find it even
    -- when the file carries no header marker.
    require("tuna.submit").write_task_store(vim.fn.fnamemodify(filepath, ":h"), task, cfg)
end

---Store downloaded testcases into an open buffer (the `testcases` download mode).
---@param bufnr integer
---@param tclist { input: string, output: string }[]
---@param replace boolean replace existing testcases instead of asking
---@param finished fun()?
local function store_testcases_into_buffer(bufnr, tclist, replace, finished)
    local tctbl = testcases.buf_get_testcases(bufnr)
    if next(tctbl) ~= nil then
        local choice = 2 -- default to Replace when `replace` is set
        if not replace then
            choice = vim.fn.confirm(
                "Testcases already exist. Keep them alongside the new ones?",
                "&Keep\n&Replace\n&Cancel",
                1
            )
        end
        if choice == 2 then
            testcases.buf_clear(bufnr) -- delete stale files before rewriting
            tctbl = {}
        elseif choice == 0 or choice == 3 then
            if finished then
                finished()
            end
            return
        end
    end

    -- Append the new testcases at the lowest free indices.
    local idx = 0
    for _, tc in ipairs(tclist) do
        while tctbl[idx] do
            idx = idx + 1
        end
        tctbl[idx] = tc
        idx = idx + 1
    end

    testcases.buf_write_testcases(bufnr, tctbl)
    -- The buffer is a problem now (it has testcases), which is what makes it worth
    -- remembering — record it here rather than waiting for the next `BufEnter`.
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path ~= "" then
        require("tuna.recent").record_problem(path)
    end
    if finished then
        finished()
    end
end

---Store one downloaded problem, prompting for its path unless configured not to.
---@param task tuna.CCTask
---@param cfg table
---@param finished fun()?
local function store_single_problem(task, cfg, finished)
    local default_path = eval_path(cfg.downloaded_problems_path, task, cfg.downloaded_files_extension, cfg)
    if not default_path then
        utils.notify("'downloaded_problems_path' evaluation failed for task '" .. task.name .. "'")
        if finished then
            finished()
        end
        return
    end

    local widgets = require("tuna.widgets")
    widgets.input(
        "Problem path",
        default_path,
        cfg.floating_border,
        cfg.floating_border_highlight,
        not cfg.downloaded_problems_prompt_path,
        function(filepath)
            -- Re-resolve config at the chosen directory: a `.tuna.lua` there may
            -- change storage layout, templates, etc.
            local local_cfg = config.load_local_config_and_extend(vim.fn.fnamemodify(filepath, ":h"))

            local function proceed()
                store_downloaded_task(filepath, task, local_cfg)
                -- Recorded even when the problem isn't opened, so `:Tuna last problem`
                -- takes you to what was just downloaded either way.
                require("tuna.recent").record_problem(filepath, local_cfg)
                if local_cfg.open_downloaded_problems then
                    vim.cmd.edit(vim.fn.fnameescape(filepath))
                    utils.place_cursor(local_cfg)
                    require("tuna.temp").absorb(filepath, local_cfg)
                end
                if finished then
                    finished()
                end
            end

            -- A duplicate is resolved in the floating UI (override / stop), not a
            -- command-line prompt. Dismissing (Esc) counts as "stop".
            if utils.file_exists(filepath) then
                widgets.menu(
                    { "Override", "Stop" },
                    -- `:~:.` keeps the title readable: relative to the cwd when the
                    -- problem lives under it, otherwise with `$HOME` as `~`.
                    vim.fn.fnamemodify(filepath, ":~:.") .. " already exists",
                    function(idx)
                        if idx == 1 then
                            proceed()
                        elseif finished then
                            finished()
                        end
                    end,
                    vim.api.nvim_get_current_win(),
                    finished
                )
            else
                proceed()
            end
        end,
        finished
    )
end

---Store a downloaded contest: prompt for the directory, then the file extension,
---then write every problem under it.
---@param tasks tuna.CCTask[]
---@param cfg table
---@param finished fun()?
local function store_contest(tasks, cfg, finished)
    local default_dir = eval_path(cfg.downloaded_contests_directory, tasks[1], cfg.downloaded_files_extension, cfg)
    if not default_dir then
        utils.notify("'downloaded_contests_directory' evaluation failed")
        if finished then
            finished()
        end
        return
    end

    local widgets = require("tuna.widgets")
    widgets.input(
        "Contest directory",
        default_dir,
        cfg.floating_border,
        cfg.floating_border_highlight,
        not cfg.downloaded_contests_prompt_directory,
        function(directory)
            local local_cfg = config.load_local_config_and_extend(directory)
            widgets.input(
                "Files extension",
                local_cfg.downloaded_files_extension,
                local_cfg.floating_border,
                local_cfg.floating_border_highlight,
                not local_cfg.downloaded_contests_prompt_extension,
                function(file_extension)
                    -- Resolve every problem's path up front so we can decide once,
                    -- for the whole contest, whether any already exist.
                    local targets, existing = {}, 0
                    for _, task in ipairs(tasks) do
                        local problem_path = eval_path(local_cfg.downloaded_contests_problems_path, task, file_extension, local_cfg)
                        if problem_path then
                            local filepath = directory .. "/" .. problem_path
                            targets[#targets + 1] = { filepath = filepath, task = task }
                            if utils.file_exists(filepath) then
                                existing = existing + 1
                            end
                        else
                            utils.notify(
                                "'downloaded_contests_problems_path' evaluation failed for task '" .. task.name .. "'"
                            )
                        end
                    end

                    ---@param skip_existing boolean? keep what is already on disk and
                    ---  write only the problems missing from the contest directory
                    local function write_all(skip_existing)
                        local opened = false
                        local first_problem
                        for _, t in ipairs(targets) do
                            if not (skip_existing and utils.file_exists(t.filepath)) then
                                store_downloaded_task(t.filepath, t.task, local_cfg)
                                first_problem = first_problem or t.filepath
                                -- Open the first problem actually written, so a partial
                                -- download lands on something new rather than on a
                                -- problem that was already there.
                                if local_cfg.open_downloaded_contests and not opened then
                                    vim.cmd.edit(vim.fn.fnameescape(t.filepath))
                                    utils.place_cursor(local_cfg)
                                    -- A `:Tuna temp` scratch waiting for this contest
                                    -- folds into the first problem opened.
                                    require("tuna.temp").absorb(t.filepath, local_cfg)
                                    opened = true
                                end
                            end
                        end
                        -- This is the one moment the contest directory is known for
                        -- certain, so record it for `:Tuna last contest` — whether or
                        -- not a problem was opened.
                        local _, contest_name = judges.parse(tasks[1], local_cfg.judge_parsers)
                        require("tuna.recent").record_contest(directory, contest_name, first_problem)
                        if finished then
                            finished()
                        end
                    end

                    -- One prompt for the whole contest: override every problem, write
                    -- only the ones missing, or stop (write none). Dismissing (Esc)
                    -- counts as "stop". The middle option is offered only when there is
                    -- something missing to write — with the contest complete on disk it
                    -- would do nothing.
                    if existing > 0 then
                        local items, actions = { "Override all" }, {
                            function()
                                write_all()
                            end,
                        }
                        if existing < #targets then
                            items[#items + 1] = "Write missing only"
                            actions[#actions + 1] = function()
                                write_all(true)
                            end
                        end
                        items[#items + 1] = "Stop"
                        actions[#actions + 1] = function()
                            if finished then
                                finished()
                            end
                        end
                        widgets.menu(
                            items,
                            ("%s already exists (%d of %d problem%s)"):format(
                                vim.fn.fnamemodify(directory, ":~:."),
                                existing,
                                #targets,
                                #targets == 1 and "" or "s"
                            ),
                            function(idx)
                                actions[idx]()
                            end,
                            vim.api.nvim_get_current_win(),
                            finished
                        )
                    else
                        write_all()
                    end
                end,
                finished
            )
        end,
        finished
    )
end

--------------------------------------------------------------------------------
-- Public download control
--------------------------------------------------------------------------------

---@alias tuna.DownloadMode "testcases" | "problem" | "contest" | "persistently"

---@class tuna.DownloadStatus
---@field mode tuna.DownloadMode
---@field port integer
---@field listener tuna.Listener
---@field processor tuna.BatchesSerialProcessor

---Current download state, or `nil` when not downloading.
---@type tuna.DownloadStatus?
local rs = nil

---Whether the listener is currently active.
---@return boolean
function M.is_downloading()
    return rs ~= nil
end

---The current download mode, or `nil`.
---@return tuna.DownloadMode?
function M.mode()
    return rs and rs.mode or nil
end

---A short status string for a lualine component. Empty when not downloading.
---@return string
function M.status()
    if not rs then
        return ""
    end
    return "🐟 downloading " .. rs.mode
end

---Show the current download status via a notification.
function M.show_status()
    if not rs then
        utils.notify("not downloading.", "INFO")
    else
        utils.notify("downloading " .. rs.mode .. " on port " .. rs.port .. ".", "INFO")
    end
end

---Stop downloading and close the listener.
function M.stop_downloading()
    if rs then
        rs.listener:close()
        rs.processor:stop()
        rs = nil
    end
end

---Build the per-batch handler for a download mode.
---@param mode tuna.DownloadMode
---@param notify_on_download boolean
---@param bufnr integer?
---@param cfg table
---@return fun(tasks: tuna.CCTask[], finished: fun())
local function make_handler(mode, notify_on_download, bufnr, cfg)
    if mode == "testcases" then
        return function(tasks, finished)
            M.stop_downloading()
            if notify_on_download then
                utils.notify("testcases downloaded successfully!", "INFO")
            end
            store_testcases_into_buffer(bufnr, tasks[1].tests, cfg.replace_downloaded_testcases, finished)
        end
    elseif mode == "problem" then
        return function(tasks, finished)
            M.stop_downloading()
            if notify_on_download then
                utils.notify("problem downloaded successfully!", "INFO")
            end
            store_single_problem(tasks[1], cfg, finished)
        end
    elseif mode == "contest" then
        return function(tasks, finished)
            M.stop_downloading()
            if notify_on_download then
                utils.notify("contest (" .. #tasks .. " tasks) downloaded successfully!", "INFO")
            end
            store_contest(tasks, cfg, finished)
        end
    else -- persistently: keep listening, decide per batch what to store
        return function(tasks, finished)
            if notify_on_download then
                local n = #tasks
                utils.notify(
                    (n > 1 and ("contest (" .. n .. " tasks)") or "one task") .. " downloaded successfully!",
                    "INFO"
                )
            end
            if #tasks > 1 then
                store_contest(tasks, cfg, finished)
            else
                local choice = vim.fn.confirm(
                    "Downloaded '" .. tasks[1].name .. "'.\nStore testcases only, or the full problem?",
                    "&Testcases\n&Problem\n&Cancel",
                    1
                )
                if choice == 1 then
                    store_testcases_into_buffer(
                        vim.api.nvim_get_current_buf(),
                        tasks[1].tests,
                        cfg.replace_downloaded_testcases,
                        finished
                    )
                elseif choice == 2 then
                    store_single_problem(tasks[1], cfg, finished)
                else
                    finished()
                end
            end
        end
    end
end

---Start downloading tasks from Competitive Companion.
---@param mode tuna.DownloadMode
---@param port integer port Competitive Companion is configured to POST to
---@param notify_on_start boolean
---@param notify_on_download boolean
---@param bufnr integer? required when `mode == "testcases"`
---@param cfg table current tuna configuration
---@return string? # an error message on failure, otherwise `nil`
function M.start_downloading(mode, port, notify_on_start, notify_on_download, bufnr, cfg)
    if rs then
        return "already downloading; stop it before changing mode"
    end
    if mode == "testcases" and not bufnr then
        return "a buffer is required to download testcases"
    end

    local handler = make_handler(mode, notify_on_download, bufnr, cfg)
    local processor = BatchesSerialProcessor.new(vim.schedule_wrap(handler))
    local collector = TasksCollector.new(function(tasks)
        processor:enqueue(tasks)
    end)
    local listener = Listener.new("127.0.0.1", port, function(task)
        collector:insert(task)
    end)
    if type(listener) == "string" then
        return listener
    end

    rs = { mode = mode, port = port, listener = listener, processor = processor }
    if notify_on_start then
        utils.notify("ready to download " .. mode .. ". Press the green plus button in your browser.", "INFO")
    end
    return nil
end

return M
