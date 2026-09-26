// Generator. Invoked as: gen <seed>
// Print one random test to stdout. Seed the RNG from argv[1] so tuna's stress
// testing can reproduce a failing case.
#include <bits/stdc++.h>
using namespace std;

int main(int argc, char** argv) {
    unsigned long long seed = argc > 1 ? strtoull(argv[1], nullptr, 10) : 0ULL;
    mt19937_64 rng(seed);
    auto rnd = [&](long long lo, long long hi) { return lo + (long long)(rng() % (hi - lo + 1)); };

    // TODO: emit a valid random test.
    long long a = rnd(1, 100), b = rnd(1, 100);
    cout << a << ' ' << b << '\n';
    return 0;
}
