# Interactor for an interactive problem.
# Read the solution's queries on stdin, print responses on stdout, flush
# after every line. Exit 0 to accept, non-zero to reject.
import sys

# argv[2] = jury answer (may be empty)
if len(sys.argv) < 2:
    print("usage: interactor <input> [answer]", file=sys.stderr)
    sys.exit(2)

with open(sys.argv[1]) as f:
    data = f.read().split()

secret = int(data[0])
for _ in range(40):
    line = sys.stdin.readline()
    if not line:
        sys.exit(1)
    g = int(line)
    if g == secret:
        print("correct", flush=True)
        sys.exit(0)
    print("higher" if g < secret else "lower", flush=True)

print("query budget exceeded", file=sys.stderr)
sys.exit(1)
