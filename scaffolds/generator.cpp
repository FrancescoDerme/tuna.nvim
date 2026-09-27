#include <bits/stdc++.h>
#define ll long long
#define ld long double
using namespace std;

// Generator for stress-testing.
// Seed the RNG from argv[1] so tuna's stress testing can reproduce a
// failing case.
void generator(unsigned ll seed) {
    mt19937_64 rng(seed);

    auto rnd = [&](ll lo, ll hi) {
        return lo + (ll)(rng() % (hi - lo + 1));
    };

    ll t = rnd(1, 3);
    cout << t << '\n';
    while (t--) {
        ll n = rnd(1, 10);
        cout << n << '\n';
        for (ll i = 0; i < n; ++i)
            cout << rnd(1, 100) << " \n"[i == n - 1];
    }
}

int main(int argc, char** argv) {
    unsigned ll seed = argc > 1 ? strtoull(argv[1], nullptr, 10) : 0ULL;

    ::generator(seed);
    return 0;
}
