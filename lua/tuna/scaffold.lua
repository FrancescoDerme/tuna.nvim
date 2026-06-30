-- lua/tuna/scaffold.lua
--
-- Drop a starter file for the stress/checker harness into the problem directory
-- (`:Tuna scaffold <checker|generator|brute>`), then open it. The built-in
-- templates are dependency-free C++ (no testlib) so they compile anywhere; users
-- can override the filename or the template source per kind via `config.scaffold`.

local config = require("tuna.config")
local utils = require("tuna.utils")

local M = {}

---Default output filename per kind.
local DEFAULT_FILES = {
    checker = "checker.cpp",
    generator = "gen.cpp",
    brute = "brute.cpp",
}

---Built-in, dependency-free templates.
local DEFAULT_TEMPLATES = {
    checker = [[// Checker (special judge). Invoked as: checker <input> <output> <answer>
//   argv[1] = test input        argv[2] = participant output
//   argv[3] = jury answer
// Exit 0 = accepted, non-zero = wrong answer. Put a short reason on stderr.
// Use this when a problem has several correct answers.
#include <bits/stdc++.h>
using namespace std;

int main(int argc, char** argv) {
    if (argc < 4) { cerr << "usage: checker <input> <output> <answer>\n"; return 2; }
    ifstream inf(argv[1]), ouf(argv[2]), ansf(argv[3]);

    // TODO: validate `ouf` against `inf`/`ansf`. Default: token-by-token equality.
    string a, b;
    while (ansf >> b) {
        if (!(ouf >> a) || a != b) { cerr << "wrong answer\n"; return 1; }
    }
    if (ouf >> a) { cerr << "trailing output\n"; return 1; }

    cerr << "ok\n";
    return 0;
}
]],
    generator = [[// Generator. Invoked as: gen <seed>
// Print one random test to stdout. Seed the RNG from argv[1] so tuna's stress
// testing can reproduce a failing case.
#include <bits/stdc++.h>
using namespace std;

int main(int argc, char** argv) {
    unsigned long long seed = argc > 1 ? strtoull(argv[1], nullptr, 10) : 0ULL;
    mt19937_64 rng(seed);
    auto rnd = [&](long long lo, long long hi) { return lo + (long long)(rng() % (hi - lo + 1)); };

    // TODO: emit a valid random test.
    long long a = rnd(1, 100), b = rnd(1, 100);
    cout << a << ' ' << b << '\n';
    return 0;
}
]],
    brute = [[// Reference / brute force. Read from stdin, write the correct answer to stdout.
// Correctness matters, speed does not — this is the oracle tuna compares against.
#include <bits/stdc++.h>
using namespace std;

int main() {
    ios::sync_with_stdio(false);
    cin.tie(nullptr);

    // TODO: solve correctly (a slow but obviously-right approach is ideal).
    return 0;
}
]],
}

---Create (or open) the scaffold file for `kind` in the current problem directory.
---@param kind string "checker" | "generator" | "brute"
---@param bufnr integer? defaults to the current buffer
function M.create(kind, bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not kind or not DEFAULT_TEMPLATES[kind] then
        utils.notify("scaffold: kind must be one of checker | generator | brute.")
        return
    end
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    local scfg = cfg.scaffold or {}

    local fname = (scfg.files and scfg.files[kind]) or DEFAULT_FILES[kind]
    local content = DEFAULT_TEMPLATES[kind]
    local override = scfg.templates and scfg.templates[kind]
    if override then
        override = override:gsub("^~", vim.uv.os_homedir())
        local c = utils.read_file(override)
        if c then
            content = c
        else
            utils.notify("scaffold: template '" .. override .. "' not found; using the built-in.", "WARN")
        end
    end

    local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
    local path = dir .. "/" .. fname

    if utils.file_exists(path) then
        local choice = vim.fn.confirm('"' .. fname .. '" already exists.', "&Open it\n&Overwrite\n&Cancel", 1)
        if choice == 1 then
            vim.cmd.edit(vim.fn.fnameescape(path))
            return
        elseif choice ~= 2 then
            return
        end
    end

    utils.write_file(path, content)
    vim.cmd.edit(vim.fn.fnameescape(path))
    utils.notify("scaffold: created " .. fname .. ".", "INFO")
end

return M
