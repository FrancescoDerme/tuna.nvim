-- lua/tuna/temp.lua
--
-- `:Tuna temp` — a scratch solution to write in *before* the problem exists.
--
-- The minutes before a contest opens are dead time one would rather spend typing the
-- parts of a solution that never change. The obstacle is the template's header: those
-- `$(JUDGE)`/`$(PROBLEM)`/`$(URL)` lines can only be filled in by a real received
-- problem, so a file started by hand either carries a header full of unevaluated
-- modifiers (which `:Tuna submit` refuses, and `:Tuna clean` would offer to delete) or
-- has no header at all.
--
-- So the scratch is the template *minus* its modifier header, and `:Tuna temp sync`
-- puts the two halves back together: it starts a receive, and the first problem that
-- lands keeps its freshly evaluated header while its body is replaced by whatever was
-- written in the scratch. The cursor is carried across, the scratch file is removed,
-- and what remains is an ordinary received problem — testcases, sidecar and all.

local utils = require("tuna.utils")
local config = require("tuna.config")

local M = {}

---A scratch waiting to be folded into the next received problem: the lines written in
---it, the cursor row, and the buffer to wipe once it has been absorbed.
---@type { lines: string[], row: integer, bufnr: integer }?
M.pending = nil

---Resolve the template path for `ext`, the way `receive` does (a string is a path with
---file-format modifiers, a table maps extension → path).
---@param ext string
---@param cfg table
---@return string? path
local function template_path(ext, cfg)
    local path
    if type(cfg.template_file) == "string" then
        -- The modifiers are file-format ones, so they need a file name to expand
        -- against; a fictitious one in the cwd is enough to fill `$(FEXT)`.
        path = utils.eval_string(vim.fn.getcwd() .. "/temp." .. ext, cfg.template_file)
    elseif type(cfg.template_file) == "table" then
        path = cfg.template_file[ext]
    end
    if not path then
        return nil
    end
    path = path:gsub("^~", vim.uv.os_homedir())
    return utils.file_exists(path) and path or nil
end

---Split a template into its header and its body. The header is the run of leading
---lines carrying `$(...)` modifiers — the part only a real problem can fill in — plus
---the blank lines under it. Counting instead of hard-coding a number keeps this
---working when the template's header grows a line.
---@param lines string[]
---@return integer header the number of header lines
---@return integer blanks the blank lines between header and body
local function split_template(lines)
    local header = 0
    while lines[header + 1] and lines[header + 1]:find("%$%b()") do
        header = header + 1
    end
    if header == 0 then
        return 0, 0
    end
    local blanks = 0
    while lines[header + blanks + 1] == "" do
        blanks = blanks + 1
    end
    return header, blanks
end

---Where the scratch file lives (`temp.file`, with `$(FEXT)` expanded).
---@param ext string
---@param cfg table
---@return string
local function scratch_path(ext, cfg)
    local spec = (cfg.temp or {}).file or (vim.fn.stdpath("cache") .. "/tuna_temp.$(FEXT)")
    return (spec:gsub("%$%(FEXT%)", ext):gsub("^~", vim.uv.os_homedir()))
end

---The language the scratch should be written in: the current buffer's, when it is a
---solution file, else the configured default.
---@param bufnr integer
---@param cfg table
---@return string ext
local function scratch_ext(bufnr, cfg)
    local name = vim.api.nvim_buf_get_name(bufnr)
    local ext = name ~= "" and vim.fn.fnamemodify(name, ":e") or ""
    if ext ~= "" and (cfg.run_command or {})[vim.bo[bufnr].filetype] then
        return ext
    end
    return (cfg.temp or {}).extension or cfg.received_files_extension or "cpp"
end

---`:Tuna temp` — open the scratch solution, creating it from the template's body.
---An existing scratch is reopened rather than overwritten, so an interrupted session
---(or a restart) resumes where it left off.
---@param bufnr integer? defaults to the current buffer
function M.start(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)

    local ext = scratch_ext(bufnr, cfg)
    local path = scratch_path(ext, cfg)

    if utils.file_exists(path) then
        vim.cmd.edit(vim.fn.fnameescape(path))
        utils.notify("temp: resumed the existing scratch — ':Tuna temp sync' folds it into a problem.", "INFO")
        return
    end

    local tmpl = template_path(ext, cfg)
    if not tmpl then
        utils.notify("temp: no template file configured for '" .. ext .. "'.", "WARN")
        return
    end
    local lines = vim.split(utils.read_file(tmpl) or "", "\n", { plain = true })
    local header, blanks = split_template(lines)
    local body = vim.list_slice(lines, header + blanks + 1)

    if not utils.write_file(path, table.concat(body, "\n")) then
        utils.notify("temp: could not write the scratch file at '" .. path .. "'.", "WARN")
        return
    end
    vim.cmd.edit(vim.fn.fnameescape(path))

    -- The configured template cursor counts template lines, and the header is gone.
    if type(cfg.template_cursor) == "number" then
        local shifted = vim.tbl_extend("force", cfg, { template_cursor = cfg.template_cursor - header - blanks })
        utils.place_cursor(shifted)
    else
        utils.place_cursor(cfg)
    end
end

---`:Tuna temp sync` — download the problem this scratch was written for and fold the
---scratch into it. Run from the scratch buffer; the merge happens in `absorb`, once
---the receive opens the problem.
---@param bufnr integer? defaults to the current buffer
function M.sync(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)

    local name = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
    local ext = name ~= "" and vim.fn.fnamemodify(name, ":e") or ""
    if name == "" or name ~= vim.fs.normalize(scratch_path(ext, cfg)) then
        utils.notify("temp: run ':Tuna temp sync' from the scratch buffer (':Tuna temp' opens it).", "WARN")
        return
    end

    M.pending = {
        -- The buffer's lines, not the file's: unsaved edits are the whole point.
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
        row = vim.api.nvim_win_get_cursor(0)[1],
        bufnr = bufnr,
    }

    local mode = (cfg.temp or {}).receive or "contest"
    local err = require("tuna.receive").start_receiving(
        mode,
        cfg.companion_port,
        cfg.receive_print_message,
        cfg.receive_print_message,
        bufnr,
        cfg
    )
    if err then
        M.pending = nil
        utils.notify("temp: " .. err, "WARN")
    end
end

---Fold a waiting scratch into the problem `receive` has just opened: the problem keeps
---its evaluated header, the scratch supplies the body. Called by `receive`; a no-op
---unless `:Tuna temp sync` armed it.
---@param filepath string the received problem just opened
---@param cfg table resolved configuration for that directory
function M.absorb(filepath, cfg)
    local pending = M.pending
    if not pending then
        return
    end
    M.pending = nil -- one problem only, whatever happens below

    local buf = vim.fn.bufnr(filepath)
    if buf == -1 or not vim.api.nvim_buf_is_valid(buf) then
        utils.notify("temp: the received problem is not open, so the scratch was left alone.", "WARN")
        return
    end

    -- The header to keep is as long as the template's, since that is what produced it.
    local ext = vim.fn.fnamemodify(filepath, ":e")
    local tmpl = template_path(ext, cfg)
    local header, blanks = 0, 0
    if tmpl then
        header, blanks = split_template(vim.split(utils.read_file(tmpl) or "", "\n", { plain = true }))
    end

    local kept = vim.api.nvim_buf_get_lines(buf, 0, header + blanks, false)
    local merged = vim.list_extend(kept, pending.lines)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, merged)
    vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent keepalt write")
    end)

    -- The scratch has been consumed: remove the file and its buffer, so nothing is
    -- left that could be edited (or written back) by mistake.
    local scratch = vim.api.nvim_buf_get_name(pending.bufnr)
    if vim.api.nvim_buf_is_valid(pending.bufnr) then
        vim.bo[pending.bufnr].modified = false
        pcall(vim.api.nvim_buf_delete, pending.bufnr, { force = true })
    end
    if scratch ~= "" then
        utils.delete_file(scratch)
    end

    -- Land on the line that was being typed, now shifted down by the restored header.
    local row = pending.row + header + blanks
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
            pcall(vim.api.nvim_win_set_cursor, win, { math.min(row, vim.api.nvim_buf_line_count(buf)), 0 })
        end
    end
    utils.notify("temp: scratch folded into " .. vim.fn.fnamemodify(filepath, ":~:."), "INFO")
end

return M
