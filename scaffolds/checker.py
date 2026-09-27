# Checker for problems with multiple answers.
# Exit 0 = accepted, non-zero = wrong answer.
import sys

if len(sys.argv) < 4:
    print("usage: checker <input> <output> <answer>", file=sys.stderr)
    sys.exit(2)

with open(sys.argv[1]) as f:
    _input = f.read()
with open(sys.argv[2]) as f:
    output = f.read().split()
with open(sys.argv[3]) as f:
    answer = f.read().split()

if output[: len(answer)] != answer:
    print("wrong answer", file=sys.stderr)
    sys.exit(1)

if len(output) > len(answer):
    print("wrong answer: trailing output", file=sys.stderr)
    sys.exit(1)

print("ok", file=sys.stderr)
