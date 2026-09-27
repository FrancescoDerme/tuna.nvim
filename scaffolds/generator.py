# Generator for stress-testing.
# Seed the RNG from argv[1] so tuna's stress testing can reproduce a failing case.
import random
import sys

random.seed(int(sys.argv[1]) if len(sys.argv) > 1 else 0)

t = random.randint(1, 3)
print(t)
for _ in range(t):
    n = random.randint(1, 10)
    print(n)
    print(*(random.randint(1, 100) for _ in range(n)))
