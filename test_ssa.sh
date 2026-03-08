#!/usr/bin/env bash
# Run all positive tests with --compile-ssa
set -uo pipefail

COMPILER=".lake/build/bin/concrete"
OUTDIR=$(mktemp -d)
RESDIR=$(mktemp -d)
trap 'rm -rf "$OUTDIR" "$RESDIR"' EXIT

PASS=0
FAIL=0
TOTAL=0

while IFS= read -r line; do
    file=$(echo "$line" | sed 's/^run_ok "\$TESTDIR\//lean_tests\//;s/".*//')
    expected=$(echo "$line" | sed 's/^run_ok "[^"]*"[[:space:]]*//' | sed 's/^"//;s/"$//')
    name=$(basename "$file" .con)

    (
        out="$OUTDIR/$name"
        if ! $COMPILER "$file" --compile-ssa -o "$out" > /dev/null 2>&1; then
            msg=$($COMPILER "$file" --compile-ssa -o "$out" 2>&1 | head -1)
            echo "FAIL $name: $msg"
            exit 1
        fi
        actual=$(perl -e 'alarm 5; exec @ARGV' "$out" 2>&1) || true
        if [ "$actual" = "$expected" ]; then
            echo "ok $name"
        else
            echo "FAIL $name: expected='$expected' got='$actual'"
        fi
    ) > "$RESDIR/$name.out" 2>&1 &

    # Limit to 8 parallel jobs
    TOTAL=$((TOTAL + 1))
    if [ $((TOTAL % 8)) -eq 0 ]; then
        wait
    fi
done < <(grep '^run_ok ' run_tests.sh)

wait

# Collect results
for f in "$RESDIR"/*.out; do
    [ -f "$f" ] || continue
    result=$(cat "$f")
    echo "$result"
    case "$result" in
        ok*) PASS=$((PASS + 1)) ;;
        *) FAIL=$((FAIL + 1)) ;;
    esac
done

echo ""
echo "PASS: $PASS  FAIL: $FAIL  TOTAL: $((PASS + FAIL))"
