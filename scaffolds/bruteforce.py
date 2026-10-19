# Bruteforce solution for stress-testing.
# Read the input from stdin, write the correct answer to stdout.
# tuna's starter, replace it with scaffold.templates (:h tuna-scaffold).

import sys

tt = 1
tt = int(sys.stdin.readline())  # comment out for a single test

for _ in range(tt):
    n = int(sys.stdin.readline())
    a = list(map(int, sys.stdin.readline().split()))
