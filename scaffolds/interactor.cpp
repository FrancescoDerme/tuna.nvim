#include <bits/stdc++.h>
#define ll long long
#define ld long double
using namespace std;

// Interactor for an interactive problem.
// Read the solution's queries on stdin, print responses on stdout, flush
// after every line. Exit 0 to accept, non-zero to reject.
int interactor(ifstream& input) {
    ll secret;
    input >> secret;

    for (int q = 0; q < 40; q++) {
        ll g;
        if (!(cin >> g)) return 1;
        if (g == secret) {
            cout << "correct" << endl;
            return 0;
        }

        cout << (g < secret ? "higher" : "lower") << endl;
    }

    cerr << "query budget exceeded\n";
    return 1;
}

// argv[2] = jury answer (may be empty)
int main(int argc, char** argv) {
    if (argc < 2) {
        cerr << "usage: interactor <input> [answer]\n";
        return 2;
    }

    ifstream input(argv[1]);
    return interactor(input);
}
