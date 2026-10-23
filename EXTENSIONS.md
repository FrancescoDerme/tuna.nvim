These features are not currently in tuna, but might be added in the future.

- The IOI/OI format, where the solution `freopen`s `input.txt` and `output.txt` instead of using stdin and stdout.
  tuna feeds a testcase on stdin and judges what comes back on stdout, so such a solution reads nothing and its answer is never compared.
- Debugger integration.
  Launching nvim-dap on a chosen testcase's input, with a separate unoptimised build.
  Most of this belongs to nvim-dap rather than to tuna: what only tuna can supply is "debug this row".
- Hiding results rows by verdict.
