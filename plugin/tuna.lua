-- plugin/tuna.lua
--
-- Run by Neovim at startup: the `:Tuna` command, the highlight groups and the autocmds
-- that keep things in step, so tuna works without a `setup()` call, which only changes
-- the defaults (`:h lua-plugin-init`). Nothing here loads the rest of tuna: the command
-- and each autocmd require what they need when they run, and an autocmd only once its
-- event concerns tuna. A session that never uses tuna loads `tuna` alone, the module the
-- highlight groups are defined in.
if vim.g.loaded_tuna then
    return
end
vim.g.loaded_tuna = true

vim.api.nvim_create_user_command("Tuna", function(opts)
    if #opts.fargs == 0 then
        -- Bare `:Tuna` opens the menu, for the solution behind a results pane when that
        -- is where it is typed.
        require("tuna.menu").open(require("tuna.commands").target_buffer())
        return
    end
    require("tuna.commands").execute(opts.fargs)
end, {
    nargs = "*",
    desc = "Tuna",
    complete = function(...)
        return require("tuna.commands").complete(...)
    end,
})

-- Let a lowercase `:tuna …` work too: expand `tuna` to `Tuna` when it's the command
-- word (so completion and dispatch behave identically).
vim.cmd([[cnoreabbrev <expr> tuna (getcmdtype() == ':' && getcmdline() =~# '^\s*tuna$') ? 'Tuna' : 'tuna']])

local augroup = vim.api.nvim_create_augroup("Tuna", { clear = true })

require("tuna").setup_highlight_groups()
vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
        require("tuna").setup_highlight_groups()
    end,
    desc = "Re-apply Tuna highlight groups after a colorscheme change",
})

vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
        require("tuna").resize_ui()
    end,
    desc = "Resize Tuna's UI when the window geometry changes",
})

-- Track the problem/contest to come back to with `:Tuna last …`. A buffer that is not a
-- file on disk is never a problem, and deciding whether one is takes `recent`.
vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(ev)
        if vim.bo[ev.buf].buftype == "" and vim.api.nvim_buf_get_name(ev.buf) ~= "" then
            require("tuna.recent").track(ev.buf)
        end
    end,
    desc = "Remember the problem Tuna should return to with `:Tuna last problem`",
})

vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
        -- Only a session that loaded `recent` has anything of it to save.
        local recent = package.loaded["tuna.recent"]
        if recent then
            recent.flush()
        end
    end,
    desc = "Persist Tuna's recent problems and contests",
})

vim.api.nvim_create_autocmd("BufReadPost", {
    group = augroup,
    callback = function(ev)
        -- Only a file with a sidecar beside it can have a verdict to restore, the one
        -- `submit.restore` reads (the setup's `problem_store_file`), and looking for it
        -- is a stat. `setup()` loads `config`, so a session it has not loaded uses the
        -- default name.
        local path = vim.api.nvim_buf_get_name(ev.buf)
        if path == "" then
            return
        end
        local config = package.loaded["tuna.config"]
        local store = config and config.current_setup.problem_store_file or ".tuna.json"
        if vim.uv.fs_stat(vim.fs.dirname(vim.fs.normalize(path)) .. "/" .. store) then
            require("tuna.submit").restore(ev.buf)
        end
    end,
    desc = "Restore a persisted Tuna submit verdict for a solution buffer",
})
