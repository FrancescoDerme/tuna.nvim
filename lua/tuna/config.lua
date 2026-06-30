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
    output_compare_method = "squish", -- "exact" | "squish" | function(out, expected)
    -- verdict source: "builtin" uses output_compare_method; otherwise a
    -- testlib-style external checker. May be a path string, or a command table
    -- { exec, args } whose args expand $(INPUT)/$(OUTPUT)/$(ANSWER) (default:
    -- `checker <input> <output> <answer>`). The exec also expands $(FNOEXT) etc.
    checker = "builtin",
    view_output_diff = false,

    -- stress testing (:Tuna stress) — hunt for an input where the solution and a
    -- trusted reference disagree. generator/reference are command specs (a string,
    -- or { exec, args }) expanded with the usual $(FNOEXT)/$(ABSDIR)/… modifiers.
    -- The generator gets the iteration number appended as a seed (unless
    -- seed_arg = false) so failures are reproducible.
    stress = {
        generator = nil, -- e.g. { exec = "$(ABSDIR)/gen", args = {} } or "python3 gen.py"
        reference = nil, -- a correct-but-slow solution, same input/output contract
        count = 100, -- maximum iterations before giving up
        seed_arg = true, -- append the iteration seed as the generator's last argument
    },

    -- interactive problems (:Tuna interactive) — the solution talks to an
    -- interactor over stdio; the interactor decides the verdict (exit 0 = AC). The
    -- interactor command spec receives the testcase input/answer via $(INPUT)/
    -- $(ANSWER) placeholders (default: those two files appended as args).
    interactive = {
        interactor = nil, -- e.g. { exec = "$(ABSDIR)/interactor", args = {} }
    },

    -- testcase storage (see DIFFERENCES.md: layout is fully customizable)
    testcases_directory = ".", -- where testcases live, relative to the source file
    testcases_storage = "files", -- "files" | "single_file" | "directory"
    testcases_auto_detect = true, -- if the chosen mode finds nothing, try the others
    -- "single_file" mode: one msgpack-encoded file
    testcases_single_file_format = "$(FNOEXT).testcases",
    -- "files" mode: a pair of text files per testcase
    testcases_input_file_format = "$(FNOEXT)_input$(TCNUM).txt",
    testcases_output_file_format = "$(FNOEXT)_output$(TCNUM).txt",
    -- "directory" mode: one sub-directory per testcase holding input/output files
    testcases_directory_format = "tests/$(TCNUM)",
    testcases_directory_input = "input.txt",
    testcases_directory_output = "output.txt",

    -- receive (Competitive Companion integration)
    companion_port = 27121,
    receive_print_message = true,
    start_receiving_persistently_on_setup = false,
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
