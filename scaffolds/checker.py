# Checker for problems with multiple answers.
# Exit 0 = accepted, non-zero = wrong answer.
# tuna's starter, replace it with scaffold.templates (:h tuna-scaffold).

import sys

if len(sys.argv) < 4:
    print("usage: checker <input> <output> <answer>", file=sys.stderr)
    sys.exit(2)

with open(sys.argv[1]) as f:
    inp = iter(f.read().split())
with open(sys.argv[2]) as f:
    output = iter(f.read().split())
with open(sys.argv[3]) as f:
    answer = iter(f.read().split())


def checker():
    n = int(next(inp))
    a = [int(next(inp)) for _ in range(n)]
    return next(output, None) == next(answer)


tt = 1
tt = int(next(inp))  # comment out for a single test
wrong = False

for t in range(1, tt + 1):
    if not checker():
        wrong = True
        # print(f"wrong answer on test {t}", file=sys.stderr)

trailing = next(output, None) is not None
if trailing:
    print("trailing output", file=sys.stderr)
if wrong or trailing:
    sys.exit(1)
