#include <bits/stdc++.h>
#define ll long long
#define ld long double
using namespace std;

// Checker for problems with multiple answers.
// Exit 0 = accepted, non-zero = wrong answer.
int checker([[maybe_unused]] ifstream& input, ifstream& output, ifstream& answer) {
    string a, b;

    while (answer >> b) {
        if (!(output >> a) || a != b) {
            cerr << "wrong answer\n";
            return 1;
        }
    }

    if (output >> a) {
        cerr << "wrong answer: trailing output\n";
        return 1;
    }

    cerr << "ok\n";
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 4) {
        cerr << "usage: checker <input> <output> <answer>\n";
        return 2;
    }

    ifstream input(argv[1]), output(argv[2]), answer(argv[3]);
    return checker(input, output, answer);
}
