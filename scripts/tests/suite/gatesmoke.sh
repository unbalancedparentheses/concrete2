# gatesmoke: the code units of tests/cases/gatesmoke.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_gatesmoke_1() {
if bash "$ROOT_DIR/scripts/tests/check_trusted_method.sh" > "$TMPDIR/tmeth.$$" 2>&1; then
    _tm_pass=$(grep -c "^  ok  " "$TMPDIR/tmeth.$$" || true)
    echo "  ok  trusted-method gate ($_tm_pass checks)"
    PASS=$((PASS + 1))
else
    echo "FAIL  trusted-method gate"
    grep "^  FAIL" "$TMPDIR/tmeth.$$" | awk "NR<=5"
    FAIL=$((FAIL + 1))
fi
rm -f "$TMPDIR/tmeth.$$"
:
}

suite_gatesmoke_2() {
if bash "$ROOT_DIR/scripts/tests/check_cross_package_caps.sh" > "$TMPDIR/xpkgcaps.$$" 2>&1; then
    _xp_pass=$(grep -c "^  ok  " "$TMPDIR/xpkgcaps.$$" || true)
    echo "  ok  cross-package-caps gate ($_xp_pass checks)"
    PASS=$((PASS + 1))
else
    echo "FAIL  cross-package-caps gate"
    grep "^  FAIL" "$TMPDIR/xpkgcaps.$$" | awk "NR<=5"
    FAIL=$((FAIL + 1))
fi
rm -f "$TMPDIR/xpkgcaps.$$"
:
}

suite_gatesmoke_3() {
if bash "$ROOT_DIR/scripts/tests/check_cap_sibling_module.sh" > "$TMPDIR/capsib.$$" 2>&1; then
    _cs_pass=$(grep -c "^  ok  " "$TMPDIR/capsib.$$" || true)
    echo "  ok  cap-sibling-module gate ($_cs_pass checks)"
    PASS=$((PASS + 1))
else
    echo "FAIL  cap-sibling-module gate"
    grep "^  FAIL" "$TMPDIR/capsib.$$" | awk "NR<=5"
    FAIL=$((FAIL + 1))
fi
rm -f "$TMPDIR/capsib.$$"
:
}

suite_gatesmoke_4() {
if bash "$ROOT_DIR/scripts/tests/check_absence_not_fact.sh" > "$TMPDIR/absence.$$" 2>&1; then
    _an_pass=$(grep -c "^  ok  " "$TMPDIR/absence.$$" || true)
    echo "  ok  absence-not-fact gate ($_an_pass checks)"
    PASS=$((PASS + 1))
else
    echo "FAIL  absence-not-fact gate"
    grep "^  FAIL" "$TMPDIR/absence.$$" | awk "NR<=5"
    FAIL=$((FAIL + 1))
fi
rm -f "$TMPDIR/absence.$$"
:
}

suite_gatesmoke_5() {
if bash "$ROOT_DIR/scripts/tests/check_cap_inference.sh" > "$TMPDIR/cap_inf.$$" 2>&1; then
    _ci_pass=$(grep -c "^  ok  " "$TMPDIR/cap_inf.$$" || true)
    echo "  ok  cap-inference gate ($_ci_pass checks)"
    PASS=$((PASS + 1))
else
    echo "FAIL  cap-inference gate"
    grep "^  FAIL" "$TMPDIR/cap_inf.$$" | awk "NR<=5"
    FAIL=$((FAIL + 1))
fi
rm -f "$TMPDIR/cap_inf.$$"
:
}

suite_gatesmoke_6() {
if bash "$ROOT_DIR/scripts/tests/check_gates_for_diff.sh" > "$TMPDIR/gates_map.$$" 2>&1; then
    _gm_pass=$(grep -c "^  ok  " "$TMPDIR/gates_map.$$" || true)
    echo "  ok  diff-to-gate mapping gate ($_gm_pass checks)"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff-to-gate mapping gate"
    grep "^  FAIL" "$TMPDIR/gates_map.$$" | awk "NR<=5"
    FAIL=$((FAIL + 1))
fi
rm -f "$TMPDIR/gates_map.$$"
:
}

suite_gatesmoke_7() {
if bash "$ROOT_DIR/scripts/tests/check_effect_opacity.sh" > "$TMPDIR/effect_opacity.$$" 2>&1; then
    _eo_pass=$(grep -c "^  ok  " "$TMPDIR/effect_opacity.$$" || true)
    echo "  ok  effect opacity gate ($_eo_pass checks)"
    PASS=$((PASS + 1))
else
    echo "FAIL  effect opacity gate"
    grep "^  FAIL" "$TMPDIR/effect_opacity.$$" | awk "NR<=5"
    FAIL=$((FAIL + 1))
fi
rm -f "$TMPDIR/effect_opacity.$$"
:
}

suite_gatesmoke_8() {
if bash "$ROOT_DIR/scripts/tests/check_foreign_assumptions_report.sh" > "$TMPDIR/foreign_assum.$$" 2>&1; then
    _fa_pass=$(grep -c "^  ok  " "$TMPDIR/foreign_assum.$$" || true)
    echo "  ok  foreign-assumptions report gate ($_fa_pass checks)"
    PASS=$((PASS + 1))
else
    echo "FAIL  foreign-assumptions report gate"
    grep "^  FAIL" "$TMPDIR/foreign_assum.$$" | awk "NR<=5"
    FAIL=$((FAIL + 1))
fi
rm -f "$TMPDIR/foreign_assum.$$"
:
}

suite_gatesmoke_9() {
if bash "$ROOT_DIR/scripts/tests/check_cap_struct_cross_package.sh" > "$TMPDIR/cap_struct_xp.$$" 2>&1; then
    _cx_pass=$(grep -c "^  ok  " "$TMPDIR/cap_struct_xp.$$" || true)
    echo "  ok  cap-struct cross-package gate ($_cx_pass checks)"
    PASS=$((PASS + 1))
else
    echo "FAIL  cap-struct cross-package gate"
    grep "^  FAIL" "$TMPDIR/cap_struct_xp.$$" | awk "NR<=5"
    FAIL=$((FAIL + 1))
fi
rm -f "$TMPDIR/cap_struct_xp.$$"
:
}

suite_gatesmoke_10() {
if bash "$ROOT_DIR/scripts/tests/check_spawn_exit.sh" > "$TMPDIR/spawn_exit.$$" 2>&1; then
    _se_pass=$(grep -c "^  ok  " "$TMPDIR/spawn_exit.$$" || true)
    echo "  ok  spawn exec-failure gate ($_se_pass checks)"
    PASS=$((PASS + 1))
else
    echo "FAIL  spawn exec-failure gate"
    grep "^  FAIL" "$TMPDIR/spawn_exit.$$" | awk "NR<=5"
    FAIL=$((FAIL + 1))
fi
rm -f "$TMPDIR/spawn_exit.$$"
:
}

suite_gatesmoke_11() {
if bash "$ROOT_DIR/scripts/tests/check_view_lifetime.sh" > "$TMPDIR/view_lifetime.$$" 2>&1; then
    _vl_pass=$(grep -c "^  ok  " "$TMPDIR/view_lifetime.$$" || true)
    echo "  ok  view lifetime gate ($_vl_pass checks)"
    PASS=$((PASS + 1))
else
    echo "FAIL  view lifetime gate"
    grep "^  FAIL" "$TMPDIR/view_lifetime.$$" | awk "NR<=5"
    FAIL=$((FAIL + 1))
fi
rm -f "$TMPDIR/view_lifetime.$$"
:
}

suite_gatesmoke_12() {
# THE CONSTITUENT'S OUTPUT IS RETAINED, NOT DISCARDED.
#
# This ran each gate as `bash ... >/dev/null 2>&1`, so a failure recorded THAT the gate failed and
# nothing about why. Ten of these fail on macOS and only there; the log said so for weeks and could
# not say more, because the evidence was discarded at the moment it was produced. A batch that
# reports a verdict it cannot explain is barely better than one that does not run.
#
# stdout and stderr are captured SEPARATELY: a gate's refusal goes to stderr and its assertions to
# stdout, and merging them loses which was which. Aggregation is unchanged and still fail-closed —
# every non-zero exit increments FAIL exactly as before.
_gs_show() { # label file
    local _n
    _n="$(awk 'END{print NR+0}' "$2")"
    if [ "$_n" -eq 0 ]; then
        echo "        $1: <empty>"
        return 0
    fi
    if [ "$_n" -gt 40 ]; then
        echo "        $1 ($_n lines, last 40 shown):"
    else
        echo "        $1 ($_n lines):"
    fi
    # `tail | awk`, not a consumer that exits early: awk reads everything tail writes, so nothing can
    # be lost to SIGPIPE under `pipefail` the way `grep -q` would lose it.
    tail -40 "$2" | awk '{ print "          | " $0 }'
}

_gs_run() { # name script -> prints the report, returns the constituent's exit status
    local _name="$1" _script="$2" _rc=0 _out _err
    _out="$(mktemp)"; _err="$(mktemp)"
    if bash "$_script" > "$_out" 2> "$_err"; then
        echo "  ok  $_name"
    else
        _rc=$?
        echo "FAIL  $_name (exit $_rc; run: bash $_script)"
        _gs_show "stdout" "$_out"
        _gs_show "stderr" "$_err"
    fi
    rm -f "$_out" "$_err"
    return $_rc
}

for g in check_lex_escapes check_mixed_width_binops check_type_agreement check_differential_positions check_copy_judgment check_ownership_judgment check_totality_judgment check_corecheck_boundary check_capability_judgment check_trailing_value_blocks; do
    if _gs_run "$g" "scripts/tests/$g.sh"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done

# THE RETENTION IS SELF-TESTED, because a diagnostic path that quietly stops working recreates
# exactly the situation it was added to end. A synthetic constituent writes a known marker to each
# stream and exits non-zero; both markers must appear, and the status must survive unchanged.
_gs_probe="$(mktemp)"; _gs_report="$(mktemp)"
printf '#!/usr/bin/env bash\necho "GS_STDOUT_MARKER"\necho "GS_STDERR_MARKER" >&2\nexit 7\n' > "$_gs_probe"
_gs_probe_rc=0
_gs_run "gate-smoke-retention-selftest" "$_gs_probe" > "$_gs_report" 2>&1 || _gs_probe_rc=$?
if [ "$_gs_probe_rc" = "7" ]; then
    echo "  ok  gate smoke preserves a constituent's exact exit status"
    PASS=$((PASS + 1))
else
    echo "FAIL  gate smoke lost the constituent's exit status (saw $_gs_probe_rc, expected 7)"
    FAIL=$((FAIL + 1))
fi
_gs_missing=""
grep -q 'GS_STDOUT_MARKER' "$_gs_report" || _gs_missing="$_gs_missing stdout"
grep -q 'GS_STDERR_MARKER' "$_gs_report" || _gs_missing="$_gs_missing stderr"
if [ -z "$_gs_missing" ]; then
    echo "  ok  gate smoke retains a failing constituent's stdout and stderr"
    PASS=$((PASS + 1))
else
    echo "FAIL  gate smoke lost:$_gs_missing — a failure would again be reported with no evidence"
    FAIL=$((FAIL + 1))
fi
# NON-VACUITY: nothing is printed for a PASSING constituent, or the check above would be satisfied
# by output that appears regardless of what the gate did.
printf '#!/usr/bin/env bash\nexit 0\n' > "$_gs_probe"
_gs_run "gate-smoke-quiet-selftest" "$_gs_probe" > "$_gs_report" 2>&1 || true
if grep -q 'GS_STDOUT_MARKER' "$_gs_report" || grep -q 'stdout (' "$_gs_report"; then
    echo "FAIL  gate smoke printed a diagnostic for a PASSING gate — the retention check proves nothing"
    FAIL=$((FAIL + 1))
else
    echo "  ok  gate smoke stays quiet for a passing constituent (the retention check is not vacuous)"
    PASS=$((PASS + 1))
fi
rm -f "$_gs_probe" "$_gs_report"
:
}
