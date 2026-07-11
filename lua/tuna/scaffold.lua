-- lua/tuna/scaffold.lua
--
-- Drop a starter helper for the stress/checker/interactive run modes into the
-- problem directory (`:Tuna scaffold <checker|generator|brute|interactor> [ext]`),
-- then open it. The helper is created in the *solution's* language by default (the
-- current buffer's extension), or in an explicit language when an extension is
-- given. Built-in, dependency-free templates ship for C++ and Python; users can
-- override the template per kind and per language via `config.scaffold.templates`
-- (a path string, or a `{ [ext] = path }` table — like `template_file`).

local config = require("tuna.config")
local utils = require("tuna.utils")
local widgets = require("tuna.widgets")

local M = {}

---Default base names per kind (extension is chosen from the target language).
local DEFAULT_FILES = {
    checker = "checker",
    generator = "gen",
    brute = "brute",
    interactor = "interactor",
}

---Built-in, dependency-free templates, keyed by kind then by extension.
local DEFAULT_TEMPLATES = {
    checker = {
        cpp = [[// Checker (special judge). Invoked as: checker <input> <output> <answer>
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
        py = [[# Checker (special judge). Invoked as: checker <input> <output> <answer>
#   argv[1] = test input   argv[2] = participant output   argv[3] = jury answer
# Exit 0 = accepted, non-zero = wrong answer. Put a short reason on stderr.
import sys

_inf = open(sys.argv[1]).read()
ouf = open(sys.argv[2]).read()
ans = open(sys.argv[3]).read()

# TODO: validate `ouf` against `_inf`/`ans`. Default: token-by-token equality.
if ouf.split() != ans.split():
    print("wrong answer", file=sys.stderr)
    sys.exit(1)
print("ok", file=sys.stderr)
]],
    },
    generator = {
        cpp = [[// Generator. Invoked as: gen <seed>
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
        py = [[# Generator. Invoked as: gen <seed>
# Print one random test to stdout. Seed the RNG from argv[1] so tuna's stress
# testing can reproduce a failing case.
import random, sys

random.seed(int(sys.argv[1]) if len(sys.argv) > 1 else 0)

# TODO: emit a valid random test.
a, b = random.randint(1, 100), random.randint(1, 100)
print(a, b)
]],
    },
    brute = {
        cpp = [[// Reference / brute force. Read from stdin, write the correct answer to stdout.
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
        py = [[# Reference / brute force. Read from stdin, write the correct answer to stdout.
# Correctness matters, speed does not — this is the oracle tuna compares against.
import sys

data = sys.stdin.read().split()

# TODO: solve correctly (a slow but obviously-right approach is ideal).
]],
    },
    interactor = {
        cpp = [[// Interactor for an interactive problem. Invoked as: interactor <input> <answer>
//   argv[1] = test input (the hidden data)   argv[2] = jury answer (may be empty)
// Talk to the solution over stdio: read its queries on stdin, print responses on
// stdout — FLUSH after every line (endl). Exit 0 to accept, non-zero to reject;
// put a short reason on stderr.
#include <bits/stdc++.h>
using namespace std;

int main(int argc, char** argv) {
    if (argc < 2) { cerr << "usage: interactor <input> [answer]\n"; return 2; }
    ifstream inf(argv[1]);

    // TODO: read the hidden data from `inf`, then interact over cin/cout.
    // Example (guess-the-number):
    //   long long secret; inf >> secret;
    //   for (int q = 0; q < 40; q++) {
    //       long long g; if (!(cin >> g)) return 1;
    //       if (g == secret) { cout << "correct" << endl; return 0; }
    //       cout << (g < secret ? "higher" : "lower") << endl;
    //   }
    //   cerr << "query budget exceeded\n"; return 1;
    return 0;
}
]],
        py = [[# Interactor for an interactive problem. Invoked as: interactor <input> <answer>
#   argv[1] = test input (hidden data)   argv[2] = jury answer (may be empty)
# Talk to the solution over stdio: read queries with sys.stdin.readline(), print
# responses with print(..., flush=True). Exit 0 to accept, non-zero to reject.
import sys

data = open(sys.argv[1]).read().split()

# TODO: read the hidden data, then interact. Example (guess-the-number):
#   secret = int(data[0])
#   for _ in range(40):
#       line = sys.stdin.readline()
#       if not line:
#           sys.exit(1)
#       g = int(line)
#       if g == secret:
#           print("correct", flush=True); sys.exit(0)
#       print("higher" if g < secret else "lower", flush=True)
#   sys.exit(1)
]],
    },
}

---Resolve the template content for a kind + extension: a user override (a path
---string, or a `{ [ext] = path }` table) wins; otherwise the built-in for `ext`.
---@param override string|table|nil `config.scaffold.templates[kind]`
---@param ext string target extension (e.g. "cpp", "py")
---@param builtins table<string, string> built-in templates for the kind, by ext
---@return string? # template content, or nil if no template exists for `ext`
local function resolve_template(override, ext, builtins)
    if type(override) == "table" then
        override = override[ext]
    end
    if type(override) == "string" then
        override = override:gsub("^~", vim.uv.os_homedir())
        local c = utils.read_file(override)
        if c then
            return c
        end
        utils.notify("scaffold: template '" .. override .. "' not found; using the built-in.", "WARN")
    end
    return builtins[ext]
end

---Create (or open) the scaffold file for `kind` in the current problem directory.
---@param kind string "checker" | "generator" | "brute" | "interactor"
---@param bufnr integer? defaults to the current buffer
---@param ext string? target language extension; defaults to the buffer's extension
function M.create(kind, bufnr, ext)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not kind or not DEFAULT_TEMPLATES[kind] then
        utils.notify("scaffold: kind must be one of checker | generator | brute | interactor.")
        return
    end
    config.load_buffer_config(bufnr)
    local cfg = config.get_buffer_config(bufnr)
    local scfg = cfg.scaffold or {}

    local bufname = vim.api.nvim_buf_get_name(bufnr)
    ext = ext or vim.fn.fnamemodify(bufname, ":e")
    if ext == "" then
        utils.notify("scaffold: no language to target — open a solution file, or pass an extension.")
        return
    end

    local base = (scfg.files and scfg.files[kind]) or DEFAULT_FILES[kind]
    local fname = base .. "." .. ext
    local content = resolve_template(scfg.templates and scfg.templates[kind], ext, DEFAULT_TEMPLATES[kind])
    if not content then
        utils.notify(
            "scaffold: no built-in "
                .. kind
                .. " template for '."
                .. ext
                .. "', "
                .. "set config.scaffold.templates."
                .. kind
                .. " for this language."
        )
        return
    end

    local dir = vim.fn.fnamemodify(bufname, ":p:h")
    local path = dir .. "/" .. fname

    local function create()
        utils.write_file(path, content)
        vim.cmd.edit(vim.fn.fnameescape(path))
        utils.notify("scaffold: created " .. fname .. ".", "INFO")
    end

    if not utils.file_exists(path) then
        create()
        return
    end

    -- The file already exists: ask via the plugin's floating chooser (same UI as
    -- the mode-switcher menu) rather than a plain `confirm` command-line prompt.
    local restore_winid = vim.api.nvim_get_current_win()
    widgets.menu({ "Open it", "Overwrite", "Cancel" }, '"' .. fname .. '" already exists', function(idx)
        if idx == 1 then
            vim.cmd.edit(vim.fn.fnameescape(path))
        elseif idx == 2 then
            create()
        end
        -- idx 3 (Cancel) or dismissed (nil): do nothing.
    end, restore_winid)
end

return M
