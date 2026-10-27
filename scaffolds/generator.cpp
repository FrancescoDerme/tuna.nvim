// Generator for stress-testing, and for one testcase at a time with `t` on the runner UI.
// tuna's starter, replace it with scaffold.templates (:h tuna-scaffold).

#include <bits/stdc++.h>
#define ll long long
#define ld long double
using namespace std;

void generator(unsigned ll seed) {
    mt19937_64 rng(seed);

    auto rnd = [&](ll lo, ll hi) {
        return lo + (ll)(rng() % (hi - lo + 1));
    };

    ll tt = rnd(1, 3);
    cout << tt << '\n';

    while (tt--) {
        ll n = rnd(1, 10);
        cout << n << '\n';
        for (ll i = 0; i < n; ++i)
            cout << rnd(1, 100) << " \n"[i == n - 1];
    }
}

int main(int argc, char** argv) {
    // Seed from argv[1], which tuna changes on every iteration.
    // Without an argument (stress.pass_seed = false), seed from the clock.
    unsigned ll seed =
        argc > 1 ? strtoull(argv[1], nullptr, 10)
                 : chrono::steady_clock::now().time_since_epoch().count();

    ::generator(seed);
    return 0;
}
