// Checker (special judge). Invoked as: checker <input> <output> <answer>
//   argv[1] = test input        argv[2] = participant output
//   argv[3] = jury answer
// Exit 0 = accepted, non-zero = wrong answer. Put a short reason on stderr.
// Use this when a problem has several correct answers.
#include <bits/stdc++.h>
using namespace std;

int main(int argc, char** argv) {
    if (argc < 4) { cerr << "usage: checker <input> <output> <answer>\n"; return 2; }
    ifstream inf(argv[1]), ouf(argv[2]), ansf(argv[3]);

    // TODO: validate `ouf` against `inf`/`ansf`. Default: token-by-token equality.
    string a, b;
    while (ansf >> b) {
        if (!(ouf >> a) || a != b) { cerr << "wrong answer\n"; return 1; }
    }
    if (ouf >> a) { cerr << "trailing output\n"; return 1; }

    cerr << "ok\n";
    return 0;
}
