#include <bits/stdc++.h>
#define ll long long
#define ld long double
using namespace std;

// Bruteforce solution for stress-testing.
// Read from stdin, write the correct answer to stdout.
void bruteforce() {
    ll n;
    cin >> n;
    vector<ll> a(n);
    for (ll i = 0; i < n; ++i) cin >> a[i];
    return;
}

int main() {
    ios_base::sync_with_stdio(0);
    cout << setprecision(10) << fixed;
    cin.tie(0);
    cout.tie(0);

    bruteforce();
}
