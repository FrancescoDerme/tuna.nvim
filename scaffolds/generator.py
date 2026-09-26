# Generator. Invoked as: gen <seed>
# Print one random test to stdout. Seed the RNG from argv[1] so tuna's stress
# testing can reproduce a failing case.
import random, sys

random.seed(int(sys.argv[1]) if len(sys.argv) > 1 else 0)

# TODO: emit a valid random test.
a, b = random.randint(1, 100), random.randint(1, 100)
print(a, b)
