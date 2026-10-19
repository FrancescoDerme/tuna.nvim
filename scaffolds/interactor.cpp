// Interactor for an interactive problem.
// Read the solution's queries on stdin, print responses on stdout, flush
// after every line. Exit 0 to accept, non-zero to reject.
// tuna's starter, replace it with scaffold.templates (:h tuna-scaffold).

#include <bits/stdc++.h>
#define ll long long
#define ld long double
using namespace std;

bool interactor(ifstream& input) {
    ll secret;
    input >> secret;

    for (int q = 0; q < 40; q++) {
        ll g;
        if (!(cin >> g)) return false;
        if (g == secret) {
            cout << "correct" << endl;
            return true;
        }

        cout << (g < secret ? "higher" : "lower") << endl;
    }

    cerr << "query budget exceeded\n";
    return false;
}

// argv[2] = jury answer (may be empty)
int main(int argc, char** argv) {
    if (argc < 2) {
        cerr << "usage: interactor <input> [answer]\n";
        return 2;
    }

    ifstream input(argv[1]);

    int tt = 1;
    input >> tt, cout << tt << endl;  // comment out for a single test

    for (int t = 1; t <= tt; ++t) {
        if (!interactor(input)) {
            // cerr << "wrong answer on test " << t << "\n";
            return 1;
        }
    }

    return 0;
}
