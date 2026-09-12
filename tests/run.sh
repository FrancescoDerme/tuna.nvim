#!/usr/bin/env bash
# tests/run.sh — run every test file, report, exit non-zero if any failed.
#
#   tests/run.sh            all of them
#   tests/run.sh submit     just tests/submit.lua
set -uo pipefail
cd "$(dirname "$0")/.."

files=()
if [ $# -gt 0 ]; then
    for name in "$@"; do files+=("tests/${name%.lua}.lua"); done
else
    for f in tests/*.lua; do
        case "$(basename "$f")" in harness.lua) ;; *) files+=("$f") ;; esac
    done
fi

failed=0
total_checks=0
for f in "${files[@]}"; do
    out=$(nvim --headless -u NONE --cmd "set noswapfile" -c "set rtp+=." -c "luafile $f" -c "qa!" 2>&1)
    status=$?
    summary=$(printf '%s' "$out" | grep -Eo '[0-9]+ checks, [0-9]+ failures' | tail -1)
    checks=${summary%% *}
    total_checks=$(( total_checks + ${checks:-0} ))
    if [ $status -eq 0 ] && [ -n "$summary" ]; then
        printf '  ok   %-24s %s\n' "$(basename "$f")" "$summary"
    else
        failed=$(( failed + 1 ))
        printf '  FAIL %-24s %s\n' "$(basename "$f")" "${summary:-did not finish}"
        printf '%s\n' "$out" | sed 's/^/       /'
    fi
done

echo
if [ $failed -eq 0 ]; then
    echo "all ${#files[@]} files passed, $total_checks checks"
else
    echo "$failed of ${#files[@]} files failed"
fi
exit $(( failed > 0 ? 1 : 0 ))
