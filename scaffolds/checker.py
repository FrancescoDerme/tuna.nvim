# Checker (special judge). Invoked as: checker <input> <output> <answer>
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
