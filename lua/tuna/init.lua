-- lua/tuna/init.lua
local config = require("tuna.config")

local M = {}

local loaded = false

---@private
---Lay `fg` over `bg` at `alpha` opacity, both 24-bit RGB. Used to tint a highlight
---towards a colour without painting it at full strength.
---@param fg integer
---@param bg integer
---@param alpha number 0–1
---@return integer
local function blend(fg, bg, alpha)
    local out = 0
    for _, shift in ipairs({ 16, 8, 0 }) do
        local unit = 2 ^ shift
        local a, b = math.floor(fg / unit) % 256, math.floor(bg / unit) % 256
        out = out + math.floor(a * alpha + b * (1 - alpha) + 0.5) * unit
    end
    return out
end

---Create Tuna's highlight groups. Defined with `default = true` so user/colorscheme
---overrides win; re-applied on every `ColorScheme` so they survive a theme switch.
function M.setup_highlight_groups()
    -- The wrong values in the diff are marked by tinting the background red rather
    -- than filling it: a saturated block is louder than the thing it is pointing at.
    -- Mixing into the editor's own background keeps the tint at the strength a diff
    -- highlight normally has, and follows the theme from dark to light. A transparent
    -- background leaves nothing to mix with, so fall back to a dark red.
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local wrong_bg = normal.bg and blend(0xff0000, normal.bg, 0.35) or 0x5f0000
    local groups = {
        TunaRunning = { bold = true },
        TunaDone = {},
        TunaCorrect = { ctermfg = "green", fg = "#00ff00" },
        TunaWarning = { ctermfg = "yellow", fg = "orange" },
        TunaWrong = { ctermfg = "red", fg = "#ff0000" },
        -- The results-UI diff. The line-level groups follow the editor's own diff
        -- colours, so they wear whatever the colorscheme uses for the same idea. The
        -- values that actually disagree do not: `DiffText` is a neutral background in
        -- most themes, so over an already-highlighted line it reads as "selected"
        -- rather than "wrong". They keep the text's own colour and take a red-tinted
        -- background instead (see `wrong_bg` above).
        TunaDiffChange = { link = "DiffChange" }, -- a line whose counterpart disagrees
        TunaDiffText = { bg = wrong_bg, ctermbg = 52 }, -- the tokens/characters that disagree
        TunaDiffAdd = { link = "DiffAdd" }, -- a line the expected output doesn't have
        TunaDiffDelete = { link = "DiffDelete" }, -- a line missing from the output
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
    -- Track the problem/contest to come back to with `:Tuna last …`.
    require("tuna.recent").setup()

    vim.api.nvim_create_autocmd("BufReadPost", {
        group = augroup,
        callback = function(ev)
            require("tuna.submit").restore(ev.buf)
        end,
        desc = "Restore a persisted Tuna submit verdict for a solution buffer",
    })

    if config.current_setup.start_downloading_persistently_on_setup then
        if vim.v.vim_did_enter == 1 then
            require("tuna.commands").download("persistently")
        else
            vim.api.nvim_create_autocmd("VimEnter", {
                group = augroup,
                once = true,
                callback = function()
                    require("tuna.commands").download("persistently")
                end,
                desc = "Start Tuna persistent downloading on startup",
            })
        end
    end
end

---lualine component: shows the download listener's state, or nothing when idle.
---The submit verdict is a separate component (`require("tuna.submit").status`)
---so it can carry its own per-verdict color — see the lualine snippet in CLAUDE.md.
function M.lualine_component()
    return require("tuna.download").status()
end

return M
