-- lua/tuna/config.lua
--
-- Configuration layering:
--   defaults  →  user opts (passed to setup())  →  local per-directory config
--
-- `setup()` merges defaults with the user's options once, producing
-- `current_setup`. Local configuration (a `.tuna.lua` file found by walking up
-- the directory tree from a buffer's file) is applied lazily, per buffer, on
-- top of `current_setup` and cached in `buffer_configs`.

local utils = require("tuna.utils")

local M = {}

---Default configuration. UI sub-tables are provisional and will be finalized as
---the native UI modules land (widgets, runner_ui).
M.defaults = {
    -- name of the per-directory config file, searched upward from each file
    local_config_file_name = ".tuna.lua",

    -- save behaviour before running
    save_current_file = true,
    save_all_files = false,

    -- compilation
    compile_directory = ".", -- relative to the source file's directory
    compile_command = {
        c = { exec = "gcc", args = { "-Wall", "$(FNAME)", "-o", "$(FNOEXT)" } },
        cpp = { exec = "g++", args = { "-Wall", "$(FNAME)", "-o", "$(FNOEXT)" } },
        rust = { exec = "rustc", args = { "$(FNAME)" } },
        java = { exec = "javac", args = { "$(FNAME)" } },
    },

    -- running
    running_directory = ".", -- relative to the source file's directory
    run_command = {
        c = { exec = "./$(FNOEXT)" },
        cpp = { exec = "./$(FNOEXT)" },
        rust = { exec = "./$(FNOEXT)" },
        python = { exec = "python3", args = { "$(FNAME)" } },
        java = { exec = "java", args = { "$(FNOEXT)" } },
    },
    multiple_testing = -1, -- testcases to run at once: -1 = CPU count, 0 = all, n = n
    maximum_time = 5000, -- per-process time limit in ms (process is killed past it)
    -- "exact" | "squish" | { "float", tol = 1e-6 } | function(out, expected)
    -- "float" compares token-wise, accepting numeric tokens within `tol` absolute
    -- or relative error (non-numeric tokens must match exactly) — for problems with
    -- floating-point answers, no custom checker needed.
    output_compare_method = "squish",
    -- Verdict source. Default "builtin" means: plain comparison via
    -- output_compare_method, *unless* a sibling `checker.*` source file is found
    -- (see tool_names) and the per-buffer checker toggle is on — then that file is
    -- compiled and used as a special judge. Set explicitly to override:
    --   "builtin"                 -> always plain comparison, no auto-discovery
    --   a path string, or a       -> testlib-style external checker, invoked as
    --   command table { exec,args }   `checker <input> <output> <answer>`. A path to
    --                                a *source* file is compiled first; args expand
    --                                $(INPUT)/$(OUTPUT)/$(ANSWER), exec expands
    --                                $(FNOEXT) etc.
    -- An external checker accepts any correct answer (special judge), which is how
    -- problems with multiple valid outputs are supported.
    checker = "builtin",
    view_output_diff = false,

    -- Helper programs (checker / generator / reference / interactor) for the
    -- stress / interactive / special-judge run modes are discovered by convention:
    -- a sibling source file whose *base name* matches one of these (any extension),
    -- compiled and run with the same commands as a solution of that language. This
    -- is what lets you switch run modes with no .tuna.lua — just drop the file in.
    tool_names = {
        checker = { "checker", "check" },
        generator = { "gen", "generator" },
        reference = { "brute", "reference" },
        interactor = { "interactor", "interact" },
    },

    -- stress testing (:Tuna run stress) — hunt for an input where the solution and
    -- a trusted reference disagree. generator/reference are discovered by
    -- convention (gen.* / brute.*); set these only to override — a command spec (a
    -- string, or { exec, args }) expanded with the usual $(FNOEXT)/$(ABSDIR)/…
    -- modifiers. The generator gets the iteration number appended as a seed (unless
    -- seed_arg = false) so failures are reproducible.
    stress = {
        generator = nil, -- override discovery, e.g. { exec = "python3", args = { "$(ABSDIR)/gen.py" } }
        reference = nil, -- override discovery: a correct-but-slow solution
        count = 100, -- maximum generator iterations before giving up
        seed_arg = true, -- append the iteration seed as the generator's last argument
        -- How many counterexamples a single `:Tuna run stress` may save before it
        -- stops, and the hard cap on the total number of testcases stress will let
        -- accumulate on disk. The search stops as soon as either is reached; each
        -- saved counterexample is appended as a normal testcase (so it becomes a
        -- regression test). Both are surfaced live in the stress runner UI.
        saves_per_run = 1, -- counterexamples to save per run before stopping
        max_saved = 10, -- never grow the testcase set beyond this many total
    },

    -- interactive problems (:Tuna run interactive [live|feed|interactor]) — the
    -- solution talks to the other side over stdio, turn by turn. Three sources:
    --   * live       — YOU are the other side: type into the (editable) Input pane,
    --                  each <CR> line is sent to the solution; no auto-verdict.
    --   * feed       — the testcase input plays the other side, one line per turn;
    --                  judged against the expected output if present.
    --   * interactor — a written interactor.* program decides the verdict (exit 0 =
    --                  AC). Secondary: auto-used only when an interactor.* exists.
    -- The chosen source is remembered per buffer, so a later bare `:Tuna run`
    -- repeats it. `interactor` below overrides interactor discovery; it receives the
    -- testcase input/answer via $(INPUT)/$(ANSWER) (default: those two files appended
    -- as args).
    interactive = {
        interactor = nil, -- override discovery, e.g. { exec = "python3", args = { "$(ABSDIR)/interactor.py" } }
    },

    -- scaffolding (:Tuna scaffold <checker|generator|brute|interactor> [ext]) — drop
    -- a starter helper into the problem directory, in the solution's language by
    -- default. `files` are base names (extension chosen from the target language).
    -- `templates[kind]` overrides the built-in stub: a template-file path string,
    -- or a per-language { [ext] = path } table (like `template_file`). Built-in
    -- stubs exist for cpp and py.
    scaffold = {
        files = { checker = "checker", generator = "gen", brute = "brute", interactor = "interactor" },
        templates = { checker = nil, generator = nil, brute = nil, interactor = nil },
    },

    -- testcase storage (see DIFFERENCES.md: layout is fully customizable)
    testcases_directory = ".", -- where testcases live, relative to the source file
    testcases_storage = "files", -- "files" | "single_file" | "directory"
    testcases_auto_detect = true, -- if the chosen mode finds nothing, try the others
    -- "single_file" mode: one msgpack-encoded file
    testcases_single_file_format = "$(FNOEXT).testcases",
    -- "files" mode: a pair of text files per testcase. Either a single format
    -- string or an ordered list of them. On load, formats are tried in order and
    -- the first that discovers any testcase wins (no merging across formats, so a
    -- folder holding two problems' per-source testcases never cross-contaminates).
    -- The first entry is canonical: new testcases are written with it. The default
    -- picks up the source-named pair first, then a shared, un-prefixed `input<N>.txt`
    -- so any solution in a folder can run testcases it didn't create (e.g. run all
    -- versions, or CC-downloaded testcases whose source name differs).
    -- A format without `$(TCNUM)` (e.g. `out.txt`) names a single testcase (index 0),
    -- and a testcase may have only an output (it runs with empty stdin).
    testcases_input_file_format = { "$(FNOEXT)_input$(TCNUM).txt", "input$(TCNUM).txt", "in.txt" },
    testcases_output_file_format = { "$(FNOEXT)_output$(TCNUM).txt", "output$(TCNUM).txt", "out.txt" },
    -- "directory" mode: one sub-directory per testcase holding input/output files
    testcases_directory_format = "tests/$(TCNUM)",
    testcases_directory_input = "input.txt",
    testcases_directory_output = "output.txt",

    -- receive (Competitive Companion integration)
    companion_port = 27121,
    receive_print_message = true,
    start_receiving_persistently_on_setup = false,
    -- Per-judge parsing of Competitive Companion's `task.group` ("Judge - Contest")
    -- into the $(JUDGE)/$(CONTEST) modifiers. Add a parser for a new judge, override
    -- a built-in, or disable one with `false`. A parser gets
    -- `{ judge, contest, group, task }` and returns overrides (nil fields kept):
    --   judge_parsers = {
    --     codechef = function(ctx) return { contest = ctx.contest:match("%((.-)%)") } end,
    --     codeforces = false,               -- keep Codeforces' raw contest name
    --     ["*"] = function(ctx) ... end,     -- catch-all for judges with no parser
    --   }
    -- Codeforces and AtCoder have built-in defaults (see `judges.lua`).
    judge_parsers = {},
    template_file = false, -- false | string with modifiers | { [ext] = path }
    evaluate_template_modifiers = false,
    date_format = "%c",
    received_files_extension = "cpp",
    received_problems_path = "$(CWD)/$(PROBLEM).$(FEXT)",
    received_problems_prompt_path = true,
    received_contests_directory = "$(CWD)",
    received_contests_problems_path = "$(PROBLEM).$(FEXT)",
    received_contests_prompt_directory = true,
    received_contests_prompt_extension = true,
    open_received_problems = true,
    open_received_contests = true,
    replace_received_testcases = false,

    -- submit (:Tuna submit) — hand the current solution to an external submit tool.
    submit = {
        provider = "command", -- entry in submit.providers (see submit.lua)
        -- The "command" provider expands this through the modifier engine (adds
        -- $(URL)/$(LANG) to the usual $(FABSPATH)/$(FNAME)/…) and runs it in a
        -- terminal. nil = submit is unconfigured (errors with a hint). Example:
        --   command = 'subwithoutcred "$(URL)" "$(LANG)" "$(FABSPATH)"',
        command = nil,
        -- How to find the problem URL: a Lua pattern scanned over the first
        -- `url_scan_lines` header lines (first capture = URL), or a
        -- function(ctx) -> string. Falls back to the per-problem sidecar below.
        url = "submit at:%s*(%S+)",
        url_scan_lines = 10,
        url_store_file = ".tuna.json", -- receive writes {url,name,group} here per problem
        -- filetype -> the language name your submit tool expects
        languages = { cpp = "C++", c = "C", python = "Python 3", java = "Java", rust = "Rust" },
        terminal = "auto", -- "auto" (toggleterm if installed, else split) | "toggleterm" | "split"
        direction = "vertical", -- terminal orientation: "vertical" | "horizontal"
        reuse_terminal = true, -- keep one cached submit terminal across submits
        -- Watch mode: run the submit command as a tracked async job (no terminal),
        -- parse its stdout for the judge verdict, and show it in the lualine
        -- component — persistently, per solution buffer, until the next submit.
        -- Requires a submit tool that polls and prints a verdict (e.g. the Rust
        -- `submitter`). Leave false to keep the fire-and-forget terminal behaviour.
        watch = false,
        -- How long (ms) the terminal-path "submitting …" flash stays up (watch mode
        -- ignores this — its state persists until the next submit). 0 disables it.
        status_time = 6000,
        -- Verdict classifier for watch mode: ordered { lua_pattern, state } rules
        -- matched (first wins) against each lowercased stdout status line. States
        -- `accepted`/`rejected`/`partial` are final; `pending` keeps watching.
        -- Unmatched lines are ignored (so "Submission url: …" etc. don't show).
        verdicts = {
            { "queued", "pending" },
            { "in queue", "pending" },
            { "testing", "pending" },
            { "running", "pending" },
            { "compiling", "pending" },
            { "judging", "pending" },
            { "pending", "pending" },
            { "accepted", "accepted" },
            { "pretests passed", "accepted" },
            { "partial", "partial" },
            { "wrong answer", "rejected" },
            { "time limit", "rejected" },
            { "memory limit", "rejected" },
            { "idleness limit", "rejected" },
            { "runtime error", "rejected" },
            { "compilation error", "rejected" },
            { "denial of judgement", "rejected" },
            { "challenged", "rejected" },
            { "hacked", "rejected" },
            { "skipped", "rejected" },
            { "rejected", "rejected" },
            { "failed", "rejected" },
            { "crashed", "rejected" },
            { "security", "rejected" },
        },
        -- state -> highlight group for the lualine verdict color (reuses tuna's
        -- runner highlight groups; override to taste).
        verdict_hl = {
            pending = "TunaWarning",
            accepted = "TunaCorrect",
            partial = "TunaWarning",
            rejected = "TunaWrong",
            error = "TunaWrong",
        },
    },

    -- Opt-in keymaps. Nothing is mapped unless you add entries; each maps an action
    -- to a left-hand side (a string, or a list of strings; false/nil disables it).
    -- Actions mirror the :Tuna subcommands — see keymaps.lua `M.actions`. Two scopes:
    --   * `mappings` — buffer-local, set on solution files (filetypes in `filetypes`)
    --     via a FileType autocmd, so they follow you from one solution to the next.
    --   * `global`   — always available, set once regardless of the current buffer
    --     (handy for buffer-agnostic actions like `menu` or `receive_*`).
    -- Example:
    --   keymaps = {
    --     mappings = { submit = "<leader>ts", run = "<leader>tr" },
    --     global   = { menu = "<leader>tt", receive_problem = "<leader>tp" },
    --   }
    keymaps = {
        filetypes = { "c", "cpp", "rust", "java", "python" },
        mappings = {},
        global = {},
    },

    -- UI: native floats (no nui). Border is passed to nvim_open_win; the border
    -- highlight is applied via the window's `winhighlight` (FloatBorder remap).
    floating_border = "rounded",
    floating_border_highlight = "FloatBorder",
    editor_ui = {
        width = 0.4,
        height = 0.6,
        show_nu = true,
        show_rnu = false,
        normal_mode_mappings = {
            switch_window = { "<C-h>", "<C-l>", "<C-i>" },
            save_and_close = "<C-s>",
            cancel = { "q", "Q" },
        },
        insert_mode_mappings = {
            switch_window = { "<C-h>", "<C-l>", "<C-i>" },
            save_and_close = "<C-s>",
            cancel = "<C-q>",
        },
    },
    picker_ui = {
        width = 0.2,
        height = 0.3,
        mappings = {
            focus_next = { "j", "<down>", "<Tab>" }, -- move to the next entry (wraps)
            focus_prev = { "k", "<up>", "<S-Tab>" }, -- move to the previous entry (wraps)
            close = { "<esc>", "<C-c>", "q", "Q" },
            submit = "<cr>",
        },
    },
    runner_ui = {
        interface = "popup", -- "popup" | "split"
        selector_show_nu = false,
        selector_show_rnu = false,
        show_nu = true,
        show_rnu = false,
        mappings = {
            -- move focus between panes, by geometry, as { left, down, up, right }.
            -- Tuna handles this itself so it works for the floating (popup)
            -- interface too, where the built-in `<C-w>hjkl` can't cross floats.
            switch_window = { "<M-h>", "<M-j>", "<M-k>", "<M-l>" },
            run_again = "R",
            run_all_again = "<C-r>",
            kill = "K",
            kill_all = "<C-k>",
            view_input = { "i", "I" },
            view_output = { "a", "A" },
            view_stdout = { "o", "O" },
            view_stderr = { "e", "E" },
            toggle_diff = { "d", "D" },
            close = { "q", "Q" },
        },
        viewer = {
            width = 0.5,
            height = 0.5,
            show_nu = true,
            show_rnu = false,
            open_when_compilation_fails = true,
        },
    },
    popup_ui = {
        total_width = 0.8,
        total_height = 0.8,
        layout = {
            { 3, "tc" },
            { 4, { { 1, "so" }, { 1, "si" } } },
            { 4, { { 1, "eo" }, { 1, "se" } } },
        },
    },
    split_ui = {
        position = "right", -- "top" | "bottom" | "left" | "right"
        relative_to_editor = true,
        total_width = 0.3,
        vertical_layout = {
            { 1, "tc" },
            { 1, { { 1, "so" }, { 1, "eo" } } },
            { 1, { { 1, "si" }, { 1, "se" } } },
        },
        total_height = 0.4,
        horizontal_layout = {
            { 2, "tc" },
            { 3, { { 1, "so" }, { 1, "si" } } },
            { 3, { { 1, "eo" }, { 1, "se" } } },
        },
    },
}

---Configuration produced by `setup()` (defaults + user opts).
---@type table?
M.current_setup = nil

---Per-buffer resolved configuration (current_setup + local config), cached.
---@type table<integer, table>
M.buffer_configs = {}

---Return a configuration table built by extending `cfg_tbl` with `opts`.
---@param cfg_tbl table? base configuration (defaults to `M.defaults`)
---@param opts table? options to layer on top
---@return table
function M.update_config_table(cfg_tbl, opts)
    if not opts then
        return vim.deepcopy(cfg_tbl or M.defaults)
    end

    local new_config = vim.tbl_deep_extend("force", cfg_tbl or M.defaults, opts)

    -- `vim.tbl_deep_extend` merges list-like tables by index, which is wrong for
    -- command argument lists: a user-supplied `args` must replace the default
    -- entirely, not be spliced over it index-by-index.
    for lang, cmd in pairs(opts.compile_command or {}) do
        if cmd.args then
            new_config.compile_command[lang].args = cmd.args
        end
    end
    for lang, cmd in pairs(opts.run_command or {}) do
        if cmd.args then
            new_config.run_command[lang].args = cmd.args
        end
    end

    -- Same index-merge hazard for the file-format lists: a user-supplied list must
    -- replace the default list wholesale (a plain string override is fine as-is).
    for _, key in ipairs({ "testcases_input_file_format", "testcases_output_file_format" }) do
        if type(opts[key]) == "table" then
            new_config[key] = opts[key]
        end
    end

    return new_config
end

---Initialise configuration from user options.
---@param opts table? user options
function M.setup(opts)
    M.current_setup = M.update_config_table(M.current_setup, opts)
    M.buffer_configs = {} -- invalidate caches so buffers re-resolve against new setup
end

---Find and load the nearest `.tuna.lua`, searching upward from `directory`.
---@param directory string directory to start the upward search from
---@return table? # the local configuration, or `nil` if absent or invalid
function M.load_local_config(directory)
    if not directory or directory == "" then
        directory = vim.fn.getcwd()
    end
    -- `vim.fs.find` with `upward = true` walks up the parent chain for us,
    -- replacing competitest's hand-rolled directory loop.
    local found = vim.fs.find(M.current_setup.local_config_file_name, {
        path = directory,
        upward = true,
        type = "file",
    })
    if not found[1] then
        return nil
    end

    local ok, local_config = pcall(dofile, found[1])
    if not ok or type(local_config) ~= "table" then
        utils.notify("load_local_config: '" .. found[1] .. "' did not return a table.")
        return nil
    end
    return local_config
end

---Load the local configuration for a directory and extend `current_setup` with it.
---@param directory string
---@return table
function M.load_local_config_and_extend(directory)
    return M.update_config_table(M.current_setup, M.load_local_config(directory))
end

---Resolve and cache the configuration for a buffer.
---@param bufnr integer
function M.load_buffer_config(bufnr)
    local directory = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
    M.buffer_configs[bufnr] = M.load_local_config_and_extend(directory)
end

---Get the configuration for a buffer, resolving it on first access.
---@param bufnr integer
---@return table
function M.get_buffer_config(bufnr)
    if not M.buffer_configs[bufnr] then
        M.load_buffer_config(bufnr)
    end
    return M.buffer_configs[bufnr]
end

return M
