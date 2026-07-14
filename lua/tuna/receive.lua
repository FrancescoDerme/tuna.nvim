-- lua/tuna/receive.lua
--
-- Competitive Companion integration. This module *is* the listener (it folds in
-- what used to be `http.lua`) plus the pipeline that turns received tasks into
-- files on disk. Three small objects form that pipeline:
--
--   Receiver ──tasks──▶ TasksCollector ──batches──▶ BatchesSerialProcessor
--
--   * `Receiver` opens a TCP socket Competitive Companion POSTs to. Each POST is
--     one "task" (one problem). It decodes the JSON and hands the task off.
--   * `TasksCollector` groups tasks by their `batch.id`. Companion tags every
--     task in a contest with the same batch id and a `batch.size`; the collector
--     emits a whole batch only once all `size` tasks have arrived. This is how we
--     reliably tell "one problem" from "a contest of N problems".
--   * `BatchesSerialProcessor` runs the per-batch handler one batch at a time.
--     Storing involves user prompts (paths, overwrite confirmations); serializing
--     keeps two contests received back-to-back from interleaving their dialogs.
--
-- Compared to competitest this also exposes `status()`/`is_receiving()` so a
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
-- Receiver: the TCP listener
--------------------------------------------------------------------------------

---@class tuna.Receiver
---@field private server uv_tcp_t
local Receiver = {}
Receiver.__index = Receiver

---Start listening on `address:port`, calling `callback` with each decoded task.
---@param address string
---@param port integer
---@param callback fun(task: tuna.CCTask)
---@return tuna.Receiver|string # the receiver, or an error message string
function Receiver.new(address, port, callback)
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
            utils.notify("receiver listen error: " .. err)
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

    return setmetatable({ server = server }, Receiver)
end

---Stop listening and release the socket.
function Receiver:close()
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

---@param callback fun(tasks: tuna.CCTask[]) called once per fully-received batch
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

---Expand tuna receive modifiers (`$(PROBLEM)`, `$(JUDGE)`, ...) in `str`.
---@param str string
---@param task tuna.CCTask
---@param file_extension string
---@param remove_illegal_chars boolean strip characters illegal in filenames
---@param cfg table? resolved config (for `judge_parsers` and `date_format`)
---@return string? # evaluated string, or `nil` on failure
local function eval_receive_modifiers(str, task, file_extension, remove_illegal_chars, cfg)
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
    return eval_receive_modifiers(path, task, file_extension, true, cfg)
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
local function store_received_task(filepath, task, cfg)
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
            local evaluated = eval_receive_modifiers(content, task, file_extension, false, cfg)
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

---Store received testcases into an open buffer (the `testcases` receive mode).
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
    if finished then
        finished()
    end
end

---Store one received problem, prompting for its path unless configured not to.
---@param task tuna.CCTask
---@param cfg table
---@param finished fun()?
local function store_single_problem(task, cfg, finished)
    local default_path = eval_path(cfg.received_problems_path, task, cfg.received_files_extension, cfg)
    if not default_path then
        utils.notify("'received_problems_path' evaluation failed for task '" .. task.name .. "'")
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
        not cfg.received_problems_prompt_path,
        function(filepath)
            -- Re-resolve config at the chosen directory: a `.tuna.lua` there may
            -- change storage layout, templates, etc.
            local local_cfg = config.load_local_config_and_extend(vim.fn.fnamemodify(filepath, ":h"))

            local function proceed()
                store_received_task(filepath, task, local_cfg)
                if local_cfg.open_received_problems then
                    vim.cmd.edit(vim.fn.fnameescape(filepath))
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
                    'Already exists: ' .. vim.fn.fnamemodify(filepath, ":t"),
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

---Store a received contest: prompt for the directory, then the file extension,
---then write every problem under it.
---@param tasks tuna.CCTask[]
---@param cfg table
---@param finished fun()?
local function store_contest(tasks, cfg, finished)
    local default_dir = eval_path(cfg.received_contests_directory, tasks[1], cfg.received_files_extension, cfg)
    if not default_dir then
        utils.notify("'received_contests_directory' evaluation failed")
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
        not cfg.received_contests_prompt_directory,
        function(directory)
            local local_cfg = config.load_local_config_and_extend(directory)
            widgets.input(
                "Files extension",
                local_cfg.received_files_extension,
                local_cfg.floating_border,
                local_cfg.floating_border_highlight,
                not local_cfg.received_contests_prompt_extension,
                function(file_extension)
                    -- Resolve every problem's path up front so we can decide once,
                    -- for the whole contest, whether any already exist.
                    local targets, existing = {}, 0
                    for _, task in ipairs(tasks) do
                        local problem_path = eval_path(local_cfg.received_contests_problems_path, task, file_extension, local_cfg)
                        if problem_path then
                            local filepath = directory .. "/" .. problem_path
                            targets[#targets + 1] = { filepath = filepath, task = task }
                            if utils.file_exists(filepath) then
                                existing = existing + 1
                            end
                        else
                            utils.notify(
                                "'received_contests_problems_path' evaluation failed for task '" .. task.name .. "'"
                            )
                        end
                    end

                    local function write_all()
                        local opened = false
                        for _, t in ipairs(targets) do
                            store_received_task(t.filepath, t.task, local_cfg)
                            if local_cfg.open_received_contests and not opened then
                                vim.cmd.edit(vim.fn.fnameescape(t.filepath))
                                opened = true
                            end
                        end
                        if finished then
                            finished()
                        end
                    end

                    -- One prompt for the whole contest: override every problem, or
                    -- stop (write none). Dismissing (Esc) counts as "stop".
                    if existing > 0 then
                        widgets.menu(
                            { "Override all", "Stop" },
                            ("%d of %d problem(s) already exist"):format(existing, #targets),
                            function(idx)
                                if idx == 1 then
                                    write_all()
                                elseif finished then
                                    finished()
                                end
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
-- Public receive control
--------------------------------------------------------------------------------

---@alias tuna.ReceiveMode "testcases" | "problem" | "contest" | "persistently"

---@class tuna.ReceiveStatus
---@field mode tuna.ReceiveMode
---@field port integer
---@field receiver tuna.Receiver
---@field processor tuna.BatchesSerialProcessor

---Current receive state, or `nil` when not receiving.
---@type tuna.ReceiveStatus?
local rs = nil

---Whether the listener is currently active.
---@return boolean
function M.is_receiving()
    return rs ~= nil
end

---The current receive mode, or `nil`.
---@return tuna.ReceiveMode?
function M.mode()
    return rs and rs.mode or nil
end

---A short status string for a lualine component. Empty when not receiving.
---@return string
function M.status()
    if not rs then
        return ""
    end
    return "🐟 receiving " .. rs.mode
end

---Show the current receive status via a notification.
function M.show_status()
    if not rs then
        utils.notify("not receiving.", "INFO")
    else
        utils.notify("receiving " .. rs.mode .. " on port " .. rs.port .. ".", "INFO")
    end
end

---Stop receiving and close the listener.
function M.stop_receiving()
    if rs then
        rs.receiver:close()
        rs.processor:stop()
        rs = nil
    end
end

---Build the per-batch handler for a receive mode.
---@param mode tuna.ReceiveMode
---@param notify_on_receive boolean
---@param bufnr integer?
---@param cfg table
---@return fun(tasks: tuna.CCTask[], finished: fun())
local function make_handler(mode, notify_on_receive, bufnr, cfg)
    if mode == "testcases" then
        return function(tasks, finished)
            M.stop_receiving()
            if notify_on_receive then
                utils.notify("testcases received successfully!", "INFO")
            end
            store_testcases_into_buffer(bufnr, tasks[1].tests, cfg.replace_received_testcases, finished)
        end
    elseif mode == "problem" then
        return function(tasks, finished)
            M.stop_receiving()
            if notify_on_receive then
                utils.notify("problem received successfully!", "INFO")
            end
            store_single_problem(tasks[1], cfg, finished)
        end
    elseif mode == "contest" then
        return function(tasks, finished)
            M.stop_receiving()
            if notify_on_receive then
                utils.notify("contest (" .. #tasks .. " tasks) received successfully!", "INFO")
            end
            store_contest(tasks, cfg, finished)
        end
    else -- persistently: keep listening, decide per batch what to store
        return function(tasks, finished)
            if notify_on_receive then
                local n = #tasks
                utils.notify(
                    (n > 1 and ("contest (" .. n .. " tasks)") or "one task") .. " received successfully!",
                    "INFO"
                )
            end
            if #tasks > 1 then
                store_contest(tasks, cfg, finished)
            else
                local choice = vim.fn.confirm(
                    "Received '" .. tasks[1].name .. "'.\nStore testcases only, or the full problem?",
                    "&Testcases\n&Problem\n&Cancel",
                    1
                )
                if choice == 1 then
                    store_testcases_into_buffer(
                        vim.api.nvim_get_current_buf(),
                        tasks[1].tests,
                        cfg.replace_received_testcases,
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

---Start receiving tasks from Competitive Companion.
---@param mode tuna.ReceiveMode
---@param port integer port Competitive Companion is configured to POST to
---@param notify_on_start boolean
---@param notify_on_receive boolean
---@param bufnr integer? required when `mode == "testcases"`
---@param cfg table current tuna configuration
---@return string? # an error message on failure, otherwise `nil`
function M.start_receiving(mode, port, notify_on_start, notify_on_receive, bufnr, cfg)
    if rs then
        return "already receiving; stop it before changing mode"
    end
    if mode == "testcases" and not bufnr then
        return "a buffer is required to receive testcases"
    end

    local handler = make_handler(mode, notify_on_receive, bufnr, cfg)
    local processor = BatchesSerialProcessor.new(vim.schedule_wrap(handler))
    local collector = TasksCollector.new(function(tasks)
        processor:enqueue(tasks)
    end)
    local receiver = Receiver.new("127.0.0.1", port, function(task)
        collector:insert(task)
    end)
    if type(receiver) == "string" then
        return receiver
    end

    rs = { mode = mode, port = port, receiver = receiver, processor = processor }
    if notify_on_start then
        utils.notify("ready to receive " .. mode .. ". Press the green plus button in your browser.", "INFO")
    end
    return nil
end

return M
