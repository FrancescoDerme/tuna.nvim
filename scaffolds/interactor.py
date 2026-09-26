# Interactor for an interactive problem. Invoked as: interactor <input> <answer>
#   argv[1] = test input (hidden data)   argv[2] = jury answer (may be empty)
# Talk to the solution over stdio: read queries with sys.stdin.readline(), print
# responses with print(..., flush=True). Exit 0 to accept, non-zero to reject.
import sys

data = open(sys.argv[1]).read().split()

# TODO: read the hidden data, then interact. Example (guess-the-number):
#   secret = int(data[0])
#   for _ in range(40):
#       line = sys.stdin.readline()
#       if not line:
#           sys.exit(1)
#       g = int(line)
#       if g == secret:
#           print("correct", flush=True); sys.exit(0)
#       print("higher" if g < secret else "lower", flush=True)
#   sys.exit(1)
