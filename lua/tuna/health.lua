-- lua/tuna/health.lua
--
-- `:checkhealth tuna` — diagnose a tuna.nvim setup. Reports the Neovim version,
-- whether `setup()` ran, the toolchains referenced by compile/run commands, the
-- Competitive Companion listener, the submit configuration, and optional
-- integrations. Read-only: it never spawns compilers or mutates state.

local health = vim.health

local M = {}

---A plain command name that can be looked up on `$PATH` — no path separator and
---no unexpanded `$(...)` modifier. `./$(FNOEXT)` (a per-problem build output) and
---`/tmp/$(FNOEXT)` are *not* bare and are skipped: they don't exist until a
---solution is compiled, so checking them would always warn spuriously.
---@param exec any
---@return boolean
local function bare_command(exec)
    return type(exec) == "string" and exec:match("^[%w._+-]+$") ~= nil
end

---First whitespace-delimited token of a shell command line (the program name).
---@param command string
---@return string?
local function command_program(command)
    return command:match("^%s*(%S+)")
end

local function check_neovim()
    health.start("tuna: Neovim")
    if vim.fn.has("nvim-0.10") == 1 then
        local v = vim.version()
        health.ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
    else
        health.error(
            "Neovim 0.10+ is required",
            { "tuna uses vim.system() and vim.uv; upgrade Neovim to 0.10 or newer" }
        )
    end
end

---@return table cfg the effective configuration (setup's, else defaults)
local function check_setup()
    health.start("tuna: setup")
    local config = require("tuna.config")
    if config.current_setup then
        health.ok("require('tuna').setup() has been called")
        return config.current_setup
    end
    health.warn(
        "require('tuna').setup() has not been called — reporting against defaults",
        { "call require('tuna').setup({ ... }) in your config" }
    )
    return config.defaults
end

local function check_toolchains(cfg)
    health.start("tuna: compilers & interpreters")

    -- Collect every bare tool referenced by a compile/run command, remembering
    -- which languages use it (multiple languages may share `g++`, `gcc`, …).
    local langs_of = {}
    for _, group in ipairs({ cfg.compile_command, cfg.run_command }) do
        for lang, cmd in pairs(group or {}) do
            if type(cmd) == "table" and bare_command(cmd.exec) then
                langs_of[cmd.exec] = langs_of[cmd.exec] or {}
                langs_of[cmd.exec][lang] = true
            end
        end
    end

    local execs = vim.tbl_keys(langs_of)
    if #execs == 0 then
        health.info("no plain-name compilers/interpreters configured to check")
        return
    end
    table.sort(execs)

    for _, exec in ipairs(execs) do
        local langs = vim.tbl_keys(langs_of[exec])
        table.sort(langs)
        local for_langs = ("(%s)"):format(table.concat(langs, ", "))
        if vim.fn.executable(exec) == 1 then
            health.ok(("`%s` found %s"):format(exec, for_langs))
        else
            health.warn(
                ("`%s` not found on PATH %s"):format(exec, for_langs),
                { "install it, or point compile_command/run_command at the right binary" }
            )
        end
    end
end

local function check_receive(cfg)
    health.start("tuna: Competitive Companion")
    local receive = require("tuna.receive")
    health.info(("listener port: %d"):format(cfg.companion_port))
    if receive.is_receiving() then
        health.ok(("listening (mode: %s)"):format(receive.mode() or "on"))
    else
        health.info("not currently listening — start with `:Tuna receive <mode>`")
    end
    health.info(
        ("point the Competitive Companion browser extension at port %d"):format(cfg.companion_port)
    )
end

---Every provider a submit configuration can reach: the base provider plus any
---per-judge override.
---@param s table submit config
---@return table<string, boolean>
local function submit_providers(s)
    local providers = { [s.provider or "command"] = true }
    for _, jcfg in pairs(s.judges or {}) do
        if type(jcfg) == "table" and jcfg.provider then
            providers[jcfg.provider] = true
        end
    end
    return providers
end

local function check_submit(cfg)
    health.start("tuna: submit")
    local s = cfg.submit or {}
    local providers = submit_providers(s)

    if providers.command then
        if type(s.command) == "function" then
            health.ok("submit.command is a function (custom dispatch)")
        elseif type(s.command) == "string" then
            local tool = command_program(s.command)
            if tool and bare_command(tool) then
                if vim.fn.executable(tool) == 1 then
                    health.ok(("submit tool `%s` found"):format(tool))
                else
                    health.warn(
                        ("submit tool `%s` not found on PATH"):format(tool),
                        { "install your submit CLI, or adjust submit.command" }
                    )
                end
            else
                health.info(("submit.command runs: %s"):format(s.command))
            end
        else
            -- The default `command` provider with no command set. Only a problem
            -- if no judge routes elsewhere (e.g. a browser-only AtCoder setup).
            local only_browser = providers.browser and vim.tbl_count(providers) == 1
            if not only_browser then
                health.info(
                    "submit is unconfigured (submit.command is nil) — `:Tuna submit` will error until set"
                )
            end
        end
    end

    if providers.browser then
        if vim.fn.has("clipboard") == 1 then
            health.ok("browser provider: clipboard available (source is copied on submit)")
        else
            health.warn(
                "browser provider needs a clipboard tool to copy the source",
                { "install xclip/xsel/wl-clipboard (Linux) — see :help clipboard" }
            )
        end
    end
end

local function check_integrations()
    health.start("tuna: optional integrations")
    for _, plugin in ipairs({ "toggleterm", "lualine" }) do
        if pcall(require, plugin) then
            health.ok(("`%s` installed"):format(plugin))
        else
            health.info(("`%s` not installed (optional)"):format(plugin))
        end
    end
end

function M.check()
    check_neovim()
    local cfg = check_setup()
    check_toolchains(cfg)
    check_receive(cfg)
    check_submit(cfg)
    check_integrations()
end

return M
