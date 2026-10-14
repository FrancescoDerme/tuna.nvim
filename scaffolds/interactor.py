# Interactor for an interactive problem.
# Read the solution's queries on stdin, print responses on stdout, flush
# after every line. Exit 0 to accept, non-zero to reject.
import sys

# argv[2] = jury answer (may be empty)
if len(sys.argv) < 2:
    print("usage: interactor <input> [answer]", file=sys.stderr)
    sys.exit(2)

with open(sys.argv[1]) as f:
    data = iter(f.read().split())


def interactor():
    secret = int(next(data))
    for _ in range(40):
        line = sys.stdin.readline()
        if not line:
            return False
        g = int(line)
        if g == secret:
            print("correct", flush=True)
            return True
        print("higher" if g < secret else "lower", flush=True)
    print("query budget exceeded", file=sys.stderr)
    return False


tt = 1
tt = int(next(data))  # comment out for a single test
print(tt, flush=True)  # this too

for t in range(1, tt + 1):
    if not interactor():
        # print(f"wrong answer on test {t}", file=sys.stderr)
        sys.exit(1)
