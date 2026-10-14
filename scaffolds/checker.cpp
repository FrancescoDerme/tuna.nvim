#include <bits/stdc++.h>
#define ll long long
#define ld long double
using namespace std;

// Checker for problems with multiple answers.
// Exit 0 = accepted, non-zero = wrong answer.
bool checker(ifstream& input, ifstream& output, ifstream& answer) {
    ll n;
    input >> n;
    vector<ll> a(n);
    for (ll i = 0; i < n; ++i) input >> a[i];

    string got, want;
    answer >> want;
    return (output >> got) && got == want;
}

int main(int argc, char** argv) {
    if (argc < 4) {
        cerr << "usage: checker <input> <output> <answer>\n";
        return 2;
    }

    ifstream input(argv[1]), output(argv[2]), answer(argv[3]);

    int tt = 1;
    input >> tt;  // comment out for a single test
    bool wrong = false;

    for (int t = 1; t <= tt; ++t) {
        if (!checker(input, output, answer)) {
            wrong = true;
            // cerr << "wrong answer on test " << t << "\n";
        }
    }

    string extra;
    bool trailing = bool(output >> extra);
    if (trailing) cerr << "trailing output\n";

    if (wrong || trailing) return 1;
    return 0;
}
