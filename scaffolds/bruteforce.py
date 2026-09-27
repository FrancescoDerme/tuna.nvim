# Bruteforce solution for stress-testing.
# Read the input from stdin, write the correct answer to stdout.
import sys

tt = int(sys.stdin.readline())
for _ in range(tt):
    n = int(sys.stdin.readline())
    a = list(map(int, sys.stdin.readline().split()))
