-- lua/tuna/init.lua
--
-- The entry point: `setup()`, which only configures (the command and the autocmds are
-- `plugin/tuna.lua`'s), the highlight groups, the resize every UI follows, and the lualine
-- component. `plugin/tuna.lua` loads it at startup for the highlight groups, so it
-- requires nothing at load time.

local M = {}

local download_started = false

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
        -- The accent on the runner UI's *editable* panes (Input, Expected Output):
        -- their border and title, so the two panes you can type into are told apart
        -- from the four you can only read, at a glance and without a legend.
        --
        -- A concrete colour, since it has to stand apart from the grey `FloatBorder`
        -- beside it, which a colorscheme's semantic groups often don't. Magenta is the
        -- one hue this plugin doesn't already spend — green is CORRECT, red WRONG, amber
        -- WARNING/EDITED — and it reads as "special" rather than as a verdict. Bold,
        -- since a border is one cell thin. `default = true`, so a colorscheme defining
        -- `TunaEditable` still wins, and `runner_ui.editable_border_highlight` points
        -- at any group you like.
        TunaEditable = { ctermfg = "magenta", fg = "#c678dd", bold = true },
        -- The letters of the `:Tuna` menu's banner. Its window is blended all the way, so
        -- the editor shows between them instead of a panel the rest of the board doesn't
        -- have; a blended cell takes the colours of whatever is under it, which would paint
        -- the wordmark in the syntax colours of the code behind it. `blend = 0` keeps the
        -- letters out of that, and their colour follows `Normal`, the art being the editor's
        -- own text.
        TunaMenuTitle = { fg = normal.fg, blend = 0 },
    }
    for name, val in pairs(groups) do
        val.default = true
        vim.api.nvim_set_hl(0, name, val)
    end
end

---Resize Tuna's user interface (widgets + any open runner UIs) after the
---window geometry changes. Scheduled so it runs once Neovim has settled.
function M.resize_ui()
    -- Every float tuna shows is drawn by `widgets` or the runner UI, so with neither
    -- loaded there is nothing on screen to resize.
    if not (package.loaded["tuna.ui.widgets"] or package.loaded["tuna.runner_ui"]) then
        return
    end
    vim.schedule(function()
        require("tuna.ui.widgets").resize_widgets()
        for _, r in ipairs(require("tuna.commands").all_runners()) do
            r:resize_ui()
        end
    end)
end

---Change tuna's defaults: `opts` is laid over them, and calling it again replaces what an
---earlier call set rather than adding to it. tuna works without it (`plugin/tuna.lua`).
---@param user_opts table?
function M.setup(user_opts)
    local config = require("tuna.config")
    config.setup(user_opts)

    -- Keymaps are opt-in configuration, so they are applied here, on every call:
    -- re-sourcing a config that changed `keymaps` takes effect like every other option.
    require("tuna.keymaps").setup()

    if config.current_setup.start_downloading_persistently_on_setup and not download_started then
        download_started = true
        if vim.v.vim_did_enter == 1 then
            require("tuna.commands").download("persistently")
        else
            vim.api.nvim_create_autocmd("VimEnter", {
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
---The submit verdict is a separate component (`require("tuna.problem.submit").status`)
---so it can carry its own per-verdict color, as the README's statusline section shows.
function M.lualine_component()
    return require("tuna.problem.download").status()
end

return M
