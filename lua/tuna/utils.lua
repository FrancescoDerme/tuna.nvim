local M = {}

function M.apply_modifiers(str, modifiers)
    if type(str) ~= "string" then
        return str
    end

    local result = str
    for key, value in pairs(modifiers) do
        local pattern = "%$%(" .. key .. "%)"
        result = string.gsub(result, pattern, value)
    end

    return result
end

function M.file_exists(filepath)
    local stat = vim.uv.fs_stat(filepath)
    return stat ~= nil and stat.type == "file"
end

function M.directory_exists(path)
    local stat = vim.uv.fs_stat(path)
    return stat ~= nil and stat.type == "directory"
end

function M.normalize_path(path, base_dir)
    if type(path) ~= "string" or path == "" then
        return base_dir or "."
    end

    if path:sub(1, 1) == "/" then
        return path
    end

    return vim.fn.fnamemodify((base_dir or ".") .. "/" .. path, ":p")
end

function M.ensure_directory(path)
    if not path or path == "" then
        return false
    end

    if M.directory_exists(path) then
        return true
    end

    vim.fn.mkdir(path, "p")
    return M.directory_exists(path)
end

return M
