// Interactor for an interactive problem. Invoked as: interactor <input> <answer>
//   argv[1] = test input (the hidden data)   argv[2] = jury answer (may be empty)
// Talk to the solution over stdio: read its queries on stdin, print responses on
// stdout — FLUSH after every line (endl). Exit 0 to accept, non-zero to reject;
// put a short reason on stderr.
#include <bits/stdc++.h>
using namespace std;

int main(int argc, char** argv) {
    if (argc < 2) { cerr << "usage: interactor <input> [answer]\n"; return 2; }
    ifstream inf(argv[1]);

    // TODO: read the hidden data from `inf`, then interact over cin/cout.
    // Example (guess-the-number):
    //   long long secret; inf >> secret;
    //   for (int q = 0; q < 40; q++) {
    //       long long g; if (!(cin >> g)) return 1;
    //       if (g == secret) { cout << "correct" << endl; return 0; }
    //       cout << (g < secret ? "higher" : "lower") << endl;
    //   }
    //   cerr << "query budget exceeded\n"; return 1;
    return 0;
}
