local receive = require("tuna.receive")

local M = {}

M.server = nil
M.port = 4242
M.host = "127.0.0.1"
M.running = false
M.download_state = {}

local function parse_payload(buffer)
    if type(buffer) ~= "string" then
        return nil
    end

    local content = buffer
    local header_end = buffer:find("\r\n\r\n")
    if header_end then
        local headers = buffer:sub(1, header_end - 1)
        local content_length = headers:match("Content%-Length:%s*(%d+)")
        local body = buffer:sub(header_end + 4)

        if content_length then
            content_length = tonumber(content_length)
            if content_length and #body >= content_length then
                body = body:sub(1, content_length)
            end
        end

        content = body
    end

    local last_line = content:match("^.+\r\n(.+)$")
    if last_line then
        content = last_line
    end

    content = content:match("^%s*(.-)%s*$")
    if content == "" then
        return nil
    end

    local ok, decoded = pcall(vim.json.decode, content)
    if ok and type(decoded) == "table" then
        return decoded
    end

    return nil
end

function M.start_server(port, host, opts)
    opts = opts or {}
    port = port or M.port
    host = host or M.host

    if M.running and M.server then
        return true
    end

    M.download_state = opts.download_state or { mode = opts.mode or "problem" }

    local server = vim.uv.new_tcp()
    local ok, err = server:bind(host, port)
    if not ok then
        vim.notify("Tuna: failed to bind listener: " .. tostring(err), vim.log.levels.ERROR)
        return false, err
    end

    local bound_port = port
    local sock_name = server:getsockname()
    if sock_name and sock_name.port then
        bound_port = sock_name.port
    end

    server:listen(128, function(err)
        if err then
            vim.notify("Tuna: listener error: " .. tostring(err), vim.log.levels.ERROR)
            return
        end

        local client = vim.uv.new_tcp()
        server:accept(client)

        local message = {}
        client:read_start(function(read_err, chunk)
            if read_err then
                client:read_stop()
                client:close()
                return
            end

            if chunk then
                table.insert(message, chunk)
                return
            end

            client:read_stop()

            local payload = parse_payload(table.concat(message))
            if payload then
                client:write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                vim.schedule(function()
                    receive.import_payload(payload, {
                        mode = opts.mode or "problem",
                        confirm = true,
                        download_state = M.download_state,
                    })
                    M.stop_server()
                end)
            else
                client:write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            end

            client:shutdown()
            client:close()
        end)
    end)

    M.server = server
    M.running = true
    M.port = bound_port
    M.host = host
    return true
end

function M.stop_server()
    if M.server then
        if M.server:is_active() and not M.server:is_closing() then
            M.server:close()
        end
        M.server = nil
    end
    M.running = false
    M.download_state = {}
end

function M.status()
    if M.running then
        return "tuna listening"
    end

    return "tuna"
end

return M
