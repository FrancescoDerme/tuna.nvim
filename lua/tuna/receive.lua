local utils = require("tuna.utils")

local M = {}

local function get_workspace_root()
    if vim.uv and vim.uv.cwd then
        local ok, cwd = pcall(vim.uv.cwd)
        if ok and cwd then
            return cwd
        end
    end

    return vim.fn.getcwd()
end

local function sanitize_name(name)
    if type(name) ~= "string" then
        return "problem"
    end

    local cleaned = name:gsub("[^%w%.%-_ ]+", "-")
    cleaned = cleaned:gsub("%s+", "-")
    cleaned = cleaned:gsub("-+", "-")
    cleaned = cleaned:gsub("^%-+", "")
    cleaned = cleaned:gsub("%-+$", "")
    cleaned = cleaned:lower()

    if cleaned == "" then
        return "problem"
    end

    return cleaned
end

local function write_file(path, content)
    local fh = io.open(path, "w")
    if not fh then
        return false
    end
    fh:write(content or "")
    fh:close()
    return true
end

local function infer_language(problem)
    if type(problem.language) == "string" and problem.language ~= "" then
        return problem.language:lower()
    end

    if type(problem.languages) == "table" then
        for lang, enabled in pairs(problem.languages) do
            if enabled then
                return tostring(lang):lower()
            end
        end
    end

    return "cpp"
end

local function build_source_path(problem_dir, problem, language)
    local source_name = sanitize_name(problem.source_name or problem.name or problem.title or "main")
    local extension = ".txt"

    if language == "python" then
        extension = ".py"
    elseif language == "cpp" then
        extension = ".cpp"
    elseif language == "c" then
        extension = ".c"
    end

    return problem_dir .. "/" .. source_name .. extension
end

local function get_problem_tests(payload, problem)
    if type(problem.tests) == "table" then
        return problem.tests
    end

    if type(payload.tests) == "table" then
        return payload.tests
    end

    return {}
end

local function ensure_problem_dir(root_dir, problem_name)
    local candidate = root_dir .. "/" .. sanitize_name(problem_name)
    local index = 1

    while utils.directory_exists(candidate) do
        candidate = root_dir .. "/" .. sanitize_name(problem_name) .. "-" .. index
        index = index + 1
    end

    utils.ensure_directory(candidate)
    return candidate
end

local function prompt_confirmation(message)
    if vim.ui and vim.ui.confirm then
        local ok, choice = pcall(vim.ui.confirm, message, { "Yes", "No" }, 1, { title = "Tuna" })
        if ok and choice then
            return choice == 1
        end
    end

    local choice = vim.fn.confirm(message, "&Yes\n&No", 1)
    return choice == 1
end

local function create_problem_assets(root_dir, payload, problem)
    local language = infer_language(problem)
    local source_path = build_source_path(root_dir, problem, language)
    local source_content = problem.source or problem.template or payload.source or ""

    if source_content == "" then
        source_content = "# TODO: add solution\n"
    end

    write_file(source_path, source_content)

    local tests_dir = root_dir .. "/tests"
    utils.ensure_directory(tests_dir)

    local tests = get_problem_tests(payload, problem)
    local idx = 1
    for _, testcase in ipairs(tests) do
        local testcase_dir = tests_dir .. "/sample" .. idx
        utils.ensure_directory(testcase_dir)

        write_file(testcase_dir .. "/input.txt", testcase.input or "")
        write_file(testcase_dir .. "/output.txt", testcase.output or "")
        idx = idx + 1
    end

    return {
        language = language,
        problem_dir = root_dir,
        source_path = source_path,
        tests_dir = tests_dir,
    }
end

local function collect_problem_entries(payload)
    if type(payload) ~= "table" then
        return {}
    end

    if type(payload.problems) == "table" then
        local entries = {}
        for _, entry in ipairs(payload.problems) do
            if type(entry) == "table" then
                table.insert(entries, entry.problem or entry)
            end
        end
        return entries
    end

    if type(payload.contest) == "table" and type(payload.contest.problems) == "table" then
        local entries = {}
        for _, entry in ipairs(payload.contest.problems) do
            if type(entry) == "table" then
                table.insert(entries, entry.problem or entry)
            end
        end
        return entries
    end

    if type(payload.problem) == "table" then
        return { payload.problem }
    end

    return { payload }
end

function M.build_import_plan(payload, opts)
    opts = opts or {}
    payload = payload or {}

    local entries = collect_problem_entries(payload)
    if #entries == 0 then
        return nil
    end

    local import_mode = opts.mode or "problem"
    if import_mode == "contest" then
        local contest_name = payload.contest_name
            or (payload.contest and (payload.contest.name or payload.contest.title))
            or payload.group
            or payload.name
            or "contest"

        local root_dir = nil
        if opts.download_state and opts.download_state.root_dir then
            root_dir = opts.download_state.root_dir
        else
            root_dir = get_workspace_root() .. "/" .. sanitize_name(contest_name)
        end

        return {
            kind = "contest",
            root_dir = root_dir,
            problems = entries,
            payload = payload,
        }
    end

    local problem_name = entries[1].name or entries[1].title or payload.name or payload.title or "problem"
    return {
        kind = "problem",
        root_dir = get_workspace_root() .. "/" .. sanitize_name(problem_name),
        problems = entries,
        payload = payload,
    }
end

function M.parse_payload(payload, opts)
    payload = payload or {}
    local plan = M.build_import_plan(payload, opts)
    if not plan then
        return nil
    end

    if opts and opts.confirm ~= false then
        local description = plan.kind == "contest" and "Import contest into " .. plan.root_dir .. "?" or "Import problem into " .. plan.root_dir .. "?"
        if not prompt_confirmation(description) then
            return false
        end
    end

    utils.ensure_directory(plan.root_dir)

    local first_source_path = nil
    for _, problem in ipairs(plan.problems) do
        local problem_dir = ensure_problem_dir(plan.root_dir, problem.name or problem.title or "problem")
        local parsed = create_problem_assets(problem_dir, payload, problem)
        if not first_source_path then
            first_source_path = parsed.source_path
        end
    end

    if first_source_path then
        vim.cmd.edit(first_source_path)
    end

    return {
        kind = plan.kind,
        root_dir = plan.root_dir,
        source_path = first_source_path,
    }
end

function M.import_payload(payload, opts)
    local parsed = M.parse_payload(payload, opts)
    if parsed == false then
        vim.notify("Tuna: import cancelled", vim.log.levels.INFO)
        return false
    end

    if parsed then
        vim.notify("Tuna: imported " .. (parsed.kind or "problem") .. " into " .. parsed.root_dir, vim.log.levels.INFO)
    end

    return parsed
end

return M
