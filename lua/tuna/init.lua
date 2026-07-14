-- lua/tuna/init.lua
local config = require("tuna.config")

local M = {}

local loaded = false

---Create Tuna's highlight groups. Defined with `default = true` so user/colorscheme
---overrides win; re-applied on every `ColorScheme` so they survive a theme switch.
function M.setup_highlight_groups()
    local groups = {
        TunaRunning = { bold = true },
        TunaDone = {},
        TunaCorrect = { ctermfg = "green", fg = "#00ff00" },
        TunaWarning = { ctermfg = "yellow", fg = "orange" },
        TunaWrong = { ctermfg = "red", fg = "#ff0000" },
    }
    for name, val in pairs(groups) do
        val.default = true
        vim.api.nvim_set_hl(0, name, val)
    end
end

---Resize Tuna's user interface (widgets + any open results UIs) after the
---window geometry changes. Scheduled so it runs once Neovim has settled.
function M.resize_ui()
    vim.schedule(function()
        require("tuna.widgets").resize_widgets()
        for _, r in pairs(require("tuna.commands").runners) do
            r:resize_ui()
        end
        require("tuna.stress").resize_all()
        require("tuna.interactive").resize_all()
        require("tuna.multi").resize_all()
    end)
end

function M.setup(user_opts)
    config.setup(user_opts)

    if loaded then
        return
    end
    loaded = true

    vim.api.nvim_create_user_command("Tuna", function(opts)
        if #opts.fargs == 0 then
            require("tuna.dashboard").open() -- bare `:Tuna` opens the dashboard
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

    -- Let a lowercase `:tuna …` work too: expand `tuna` to `Tuna` when it's the
    -- command word (so completion and dispatch behave identically).
    vim.cmd(
        [[cnoreabbrev <expr> tuna (getcmdtype() == ':' && getcmdline() =~# '^\s*tuna$') ? 'Tuna' : 'tuna']]
    )

    local augroup = vim.api.nvim_create_augroup("Tuna", { clear = true })

    M.setup_highlight_groups()
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = augroup,
        callback = M.setup_highlight_groups,
        desc = "Re-apply Tuna highlight groups after a colorscheme change",
    })

    vim.api.nvim_create_autocmd("VimResized", {
        group = augroup,
        callback = M.resize_ui,
        desc = "Resize Tuna's UI when the window geometry changes",
    })

    require("tuna.keymaps").setup()

    vim.api.nvim_create_autocmd("BufReadPost", {
        group = augroup,
        callback = function(ev)
            require("tuna.submit").restore(ev.buf)
        end,
        desc = "Restore a persisted Tuna submit verdict for a solution buffer",
    })

    if config.current_setup.start_receiving_persistently_on_setup then
        if vim.v.vim_did_enter == 1 then
            require("tuna.commands").receive("persistently")
        else
            vim.api.nvim_create_autocmd("VimEnter", {
                group = augroup,
                once = true,
                callback = function()
                    require("tuna.commands").receive("persistently")
                end,
                desc = "Start Tuna persistent receiving on startup",
            })
        end
    end
end

---lualine component: shows the receive listener's state, or nothing when idle.
---The submit verdict is a separate component (`require("tuna.submit").status`)
---so it can carry its own per-verdict color — see the lualine snippet in CLAUDE.md.
function M.lualine_component()
    return require("tuna.receive").status()
end

return M
