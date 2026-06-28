-- lua/tuna/utils.lua
local M = {}

-- Replace placeholders like $(FNAME) in a string with actual values.
-- modifiers is a table, e.g. { FNAME = "main.cpp", TNO = "1" }
function M.apply_modifiers(str, modifiers)
    if type(str) ~= "string" then
        return str
    end

    local result = str
    for key, value in pairs(modifiers) do
        -- string.gsub uses "%" as an escape character instead of "\".
        -- Escape the "$" and parentheses to match "$(KEY)"
        local pattern = "%$%(" .. key .. "%)"
        result = string.gsub(result, pattern, value)
    end

    return result
end

-- Example
function M.file_exists(filepath)
    local stat = vim.uv.fs_stat(filepath)
    return stat ~= nil and stat.type == "file"
end

return M
