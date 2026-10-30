# evidence+trust-gate.2: the code units of tests/cases/evidence+trust-gate.2.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_evidence_trust_gate_2_1() {
sc_pass=0
sc_fail=0

PP_DIR="examples/proof_pressure"

# 1. Build summary counts only user functions (not 300+ stdlib)
sc_build=$(cd "$PP_DIR" && "$ROOT_DIR/$COMPILER" build -o "$TMPDIR/test_sc_pp" 2>&1)
sc_summary=$(grep <<<"$sc_build" "^Proofs:")
if grep <<<"$sc_summary" -qE "^Proofs: [0-9]+ proved, [0-9]+ stale, [0-9]+ missing, [0-9]+ blocked$"; then
    echo "  ok  scoping: build summary shows user-only counts"
    sc_pass=$((sc_pass + 1))
else
    echo "  FAIL scoping: build summary should show user-only counts"
    echo "    got: $sc_summary"
    sc_fail=$((sc_fail + 1))
fi
rm -f "$TMPDIR/test_sc_pp"

# 2. Build summary does not include large stdlib counts (total should be < 20)
# SUMMED IN THE SHELL, not with `bc`. `bc` is not part of a base POSIX install and is absent from
# this environment, so this line exited 127 and — under `set -e` — killed the trust gate outright,
# roughly 300 assertions before the end. An external tool used for one addition is a whole-suite
# outage waiting to happen, and arithmetic is something the shell already does.
sc_total=$(grep <<<"$sc_summary" -oE '[0-9]+' | awk '{t += $1} END {print t+0}')
if [ "$sc_total" -lt 20 ]; then
    echo "  ok  scoping: build summary total < 20 (user-only, not stdlib)"
    sc_pass=$((sc_pass + 1))
else
    echo "  FAIL scoping: build summary total should be < 20 (got $sc_total, likely includes stdlib)"
    sc_fail=$((sc_fail + 1))
fi

# 3. Check output has no std.* function entries
sc_check=$(cd "$PP_DIR" && "$ROOT_DIR/$COMPILER" check 2>&1) || true
if ! grep <<<"$sc_check" -q '`std\.'; then
    echo "  ok  scoping: check report has no std.* functions"
    sc_pass=$((sc_pass + 1))
else
    echo "  FAIL scoping: check report should not include std.* functions"
    sc_fail=$((sc_fail + 1))
fi

# 4. Check output only shows main.* functions
if grep <<<"$sc_check" '`main\.' | has_match "main\."; then
    echo "  ok  scoping: check report shows main.* functions"
    sc_pass=$((sc_pass + 1))
else
    echo "  FAIL scoping: check report should show main.* functions"
    sc_fail=$((sc_fail + 1))
fi

# 5. Check totals line has small count (user functions only)
sc_totals=$(grep <<<"$sc_check" "^Totals:")
sc_fn_count=$(grep <<<"$sc_totals" -oE '^Totals: [0-9]+' | grep -oE '[0-9]+')
if [ -n "$sc_fn_count" ] && [ "$sc_fn_count" -lt 20 ]; then
    echo "  ok  scoping: check totals count < 20 (user-only)"
    sc_pass=$((sc_pass + 1))
else
    echo "  FAIL scoping: check totals should be < 20 (got $sc_fn_count)"
    sc_fail=$((sc_fail + 1))
fi

# 6. Check shows dependency obligations hidden footer
if grep <<<"$sc_check" -q "dependency obligations hidden"; then
    echo "  ok  scoping: check shows dependency obligations hidden footer"
    sc_pass=$((sc_pass + 1))
else
    echo "  FAIL scoping: check should show dependency obligations hidden footer"
    sc_fail=$((sc_fail + 1))
fi

# 7. Check exit code based on user obligations only
# (proof_pressure has stale/missing user obligations, so still exits 1)
sc_check_rc=0
(cd "$PP_DIR" && "$ROOT_DIR/$COMPILER" check >/dev/null 2>&1) || sc_check_rc=$?
if [ "$sc_check_rc" -eq 1 ]; then
    echo "  ok  scoping: check exit code reflects user obligations"
    sc_pass=$((sc_pass + 1))
else
    echo "  FAIL scoping: check should exit 1 for user stale/missing (got $sc_check_rc)"
    sc_fail=$((sc_fail + 1))
fi

# 8. Next steps only reference main.* functions
sc_next=$(echo "$sc_check" | sed -n '/^Next steps:/,/^$/p')
if grep <<<"$sc_next" -q "main\." && ! grep <<<"$sc_next" -q "std\."; then
    echo "  ok  scoping: next steps reference only user functions"
    sc_pass=$((sc_pass + 1))
else
    echo "  FAIL scoping: next steps should only reference user functions"
    sc_fail=$((sc_fail + 1))
fi

# 9. require-proofs policy only enforces on user package
# main is entry point (ineligible), so require-proofs should not trigger
# stdlib functions are ineligible/blocked/trusted — require-proofs should ignore them
SC_TMPDIR=$(mktemp -d)
mkdir -p "$SC_TMPDIR/src"
cat > "$SC_TMPDIR/Concrete.toml" << 'TOML'
[package]
name = "scope_test"
version = "0.1.0"

[policy]
require-proofs = true
TOML
cat > "$SC_TMPDIR/src/main.con" << 'CON'
pub fn main() -> Int {
    return 0;
}
CON
sc_rp_rc=0
sc_rp_out=$(cd "$SC_TMPDIR" && "$ROOT_DIR/$COMPILER" build -o "$TMPDIR/test_sc_rp" 2>&1) || sc_rp_rc=$?
if [ "$sc_rp_rc" -eq 0 ]; then
    echo "  ok  scoping: require-proofs passes when user code needs no proofs"
    sc_pass=$((sc_pass + 1))
else
    echo "  FAIL scoping: require-proofs should pass for ineligible-only user code (got exit $sc_rp_rc)"
    echo "    out: $(echo "$sc_rp_out" | tail -5)"
    sc_fail=$((sc_fail + 1))
fi
rm -f "$TMPDIR/test_sc_rp"
rm -rf "$SC_TMPDIR"

# 10. require-proofs still catches user-package violations
SC_TMPDIR2=$(mktemp -d)
mkdir -p "$SC_TMPDIR2/src"
cat > "$SC_TMPDIR2/Concrete.toml" << 'TOML'
[package]
name = "scope_test2"
version = "0.1.0"

[policy]
require-proofs = true
TOML
cat > "$SC_TMPDIR2/src/main.con" << 'CON'
fn add(a: Int, b: Int) -> Int {
    return a + b;
}

pub fn main() -> Int {
    return add(1, 2);
}
CON
sc_rp2_rc=0
sc_rp2_out=$(cd "$SC_TMPDIR2" && "$ROOT_DIR/$COMPILER" build -o "$TMPDIR/test_sc_rp2" 2>&1) || sc_rp2_rc=$?
if [ "$sc_rp2_rc" -ne 0 ] && grep <<<"$sc_rp2_out" -q "policy violation.*main\.add"; then
    echo "  ok  scoping: require-proofs catches user-package missing proof"
    sc_pass=$((sc_pass + 1))
else
    echo "  FAIL scoping: require-proofs should catch user missing proof (exit=$sc_rp2_rc)"
    echo "    out: $(echo "$sc_rp2_out" | tail -5)"
    sc_fail=$((sc_fail + 1))
fi
rm -f "$TMPDIR/test_sc_rp2"
rm -rf "$SC_TMPDIR2"

if [ "$sc_fail" -gt 0 ]; then
    echo "  $sc_fail scoping test failures"
fi
echo "  $sc_pass scoping tests passed"
PASS=$((PASS + sc_pass))
FAIL=$((FAIL + sc_fail))
:
}
