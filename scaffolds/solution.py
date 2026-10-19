# contest: $(JUDGE) $(CONTEST)
# problem: $(PROBLEM)
# tuna's starter, replace it with scaffold.templates (:h tuna-scaffold).

import sys


def solve():
    n = int(sys.stdin.readline())
    a = list(map(int, sys.stdin.readline().split()))


tt = 1
tt = int(sys.stdin.readline())  # comment out for a single test

for _ in range(tt):
    solve()
