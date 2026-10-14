# Generator for stress-testing.
import random
import sys

# Seed from argv[1], which tuna changes on every iteration.
# Without an argument (stress.pass_seed = false), seed randomly.
random.seed(int(sys.argv[1]) if len(sys.argv) > 1 else None)

tt = random.randint(1, 3)
print(tt)

for _ in range(tt):
    n = random.randint(1, 10)
    print(n)
    print(*(random.randint(1, 100) for _ in range(n)))
