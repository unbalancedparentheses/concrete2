# positive: the code units of tests/cases/positive.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_positive_1() {
# Network test. Runs in EVERY mode, including fast. It was `--full`-only, and CI runs
# fast, so nothing executed it — which is exactly how it sat broken on Linux for as long
# as it did, hardcoding the BSD `sockaddr_in` layout. A loopback bind costs microseconds;
# there was never a speed reason to hide it. The opt-out below is for environments with
# no loopback networking, which is a real condition and is named as itself.
if [ "${SKIP_NETWORK_TESTS:-0}" = "1" ]; then
    echo "skip tests/programs/net_tcp_roundtrip.con (SKIP_NETWORK_TESTS=1)"
    SKIP=$((SKIP + 1))
else
    run_ok "$TESTDIR/net_tcp_roundtrip.con" 42
fi
:
}

suite_positive_2() {
run_ok "$TESTDIR/adversarial_codegen_enum_match.con" "$(printf '10\n25\n30\n42')"
run_ok "$TESTDIR/adversarial_codegen_string_operations.con" "$(printf 'hello world\n11')"
:
}

suite_positive_3() {

# abort test: compiles but exits with nonzero (signal)
run_abort_worker() {
    local file="$1"
    local result_file="$2"
    local name
    name=$(path_key "${file%.con}")
    local out="$TMPDIR/$name"
    if ! $COMPILER "$file" -o "$out" > /dev/null 2>&1; then
        {
            echo "FAIL"
            echo "FAIL  $file — compilation failed"
        } > "$result_file"
        return
    fi
    # Suppress bash's own "Abort trap" diagnostic for expected signal exits.
    # We only care whether the program exited successfully or not.
    if { "$out" > /dev/null 2>&1; } 2>/dev/null; then
        {
            echo "FAIL"
            echo "FAIL  $file — expected nonzero exit"
        } > "$result_file"
    else
        {
            echo "PASS"
            echo "  ok  $file => nonzero exit"
        } > "$result_file"
    fi
}
run_abort() {
    local file="$1"
    if ! filter_match "$file"; then SKIP=$((SKIP + 1)); return; fi
    if [ "$TEST_JOBS" -le 1 ]; then
        JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
        run_abort_worker "$file" "$result_file"
        record_result "$result_file"
        return
    fi
    JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
    throttle_jobs
    (run_abort_worker "$file" "$result_file") &
    JOB_PIDS+=("$!")
    JOB_FILES+=("$result_file")
}
:
}

suite_positive_4() {
# Bug 191 (FIXED): test programs and std tests wrote fixed /tmp paths; on a shared host the first
# user to run the suite owned them, fopen returned NULL for everyone else and file_write_read
# segfaulted (rc 139). Scratch now comes from CONCRETE_TEST_TMPDIR, set by the runner. An
# environment error is an exit code, never a crash: unset -> 100, a directory that does not exist
# (the open for writing fails) -> 101.
r191_bin="$TMPDIR/r191_fwr"
if $COMPILER "$TESTDIR/file_write_read.con" -o "$r191_bin" >/dev/null 2>&1; then
    r191_unset=0; env -u CONCRETE_TEST_TMPDIR "$r191_bin" >/dev/null 2>&1 || r191_unset=$?
    r191_absent=0; CONCRETE_TEST_TMPDIR="$TMPDIR/r191_absent" "$r191_bin" >/dev/null 2>&1 || r191_absent=$?
    if [ "$r191_unset" = "100" ] && [ "$r191_absent" = "101" ]; then
        echo "  ok  regress_191 file_write_read: unset scratch -> 100, missing directory -> 101 (no crash)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  regress_191 file_write_read: unset gave $r191_unset (want 100), missing directory gave $r191_absent (want 101)"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL  regress_191: file_write_read.con did not compile"
    FAIL=$((FAIL + 1))
fi
# The runner provides the directory: with the caller's variable set to a sentinel, the test binary
# must see a different, writable directory (regress_191_test_scratch: 1 unset, 2 inherited the
# sentinel, 3 not writable). Before the fix it inherited the sentinel.
r191_out=$(CONCRETE_TEST_TMPDIR=/nonexistent/r191_sentinel $COMPILER "$TESTDIR/regress_191_test_scratch.con" --test 2>&1) \
    && r191_rc=0 || r191_rc=$?
if [ "$r191_rc" = "0" ] && grep -q "^PASS: .*test_runner_scratch" <<<"$r191_out"; then
    echo "  ok  regress_191_test_scratch: --test overrides the caller's CONCRETE_TEST_TMPDIR with a writable private directory"
    PASS=$((PASS + 1))
else
    echo "FAIL  regress_191_test_scratch --test with the caller's CONCRETE_TEST_TMPDIR at a sentinel: rc $r191_rc $(awk 'NR<=3' <<<"$r191_out" | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
fi
:
}

suite_positive_5() {

# Networking tests. `tcp_basic` was guarded by `SKIP_FLAKY_TCP_TEST` and IS NOT FLAKY.
# It failed deterministically, on Linux, every time, because it wrote a BSD `sockaddr_in`
# with a `sin_len` byte Linux does not have. The label is what stopped anyone looking: a
# skip whose stated reason is wrong is a defect with a lid on it. Both the reason and the
# variable name are now the true one.
if [ "${SKIP_NETWORK_TESTS:-0}" = "1" ]; then
    echo "skip tests/programs/tcp_basic.con (SKIP_NETWORK_TESTS=1)"
    SKIP=$((SKIP + 1))
else
    run_ok "$TESTDIR/tcp_basic.con" 1
fi
:
}

suite_positive_6() {
# Bug 212: an uppercase constant before the block of an if / while / match head is read as a
# struct literal; the E0001 must name that reading (the accepted language is unchanged).
run_err "$TESTDIR/error_212_const_in_if_head.con" "\`LIMIT {\` is read as the start of a struct literal"
run_err "$TESTDIR/error_212_const_in_while_head.con" "\`LIMIT {\` is read as the start of a struct literal"
:
}

suite_positive_7() {
run_err "$TESTDIR/error_212_const_in_match_head.con" "\`MODE {\` is read as the start of a struct literal"
# Negative control: a head that parsed as written is never blamed (the hint follows the parser's
# actual struct-literal decision, not the token before the brace).
for r212n in error_212_no_hint_qualified_head error_212_no_hint_literal_head; do
    r212n_out=$($COMPILER "$TESTDIR/$r212n.con" --emit-llvm 2>&1 >/dev/null || true)
    if grep -q '(E0001)' <<<"$r212n_out" && ! grep -q 'is read as the start of a struct literal' <<<"$r212n_out"; then
        echo "  ok  bug 212: $r212n: a head that parsed is not blamed (E0001 without the hint)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  bug 212: negative control $r212n: $(head -3 <<<"$r212n_out" | tr '\n' ' ')"
        FAIL=$((FAIL + 1))
    fi
done
# Bug 214: a binding left unconsumed by two returns is refused once per return, and each E0208
# names its own return (line 9 and line 10), so the two refusals differ.
run_err "$TESTDIR/error_214_two_returns_leak.con" "is still unconsumed when this \`return\` leaves the function"
r214_out=$($COMPILER "$TESTDIR/error_214_two_returns_leak.con" --emit-llvm 2>&1 >/dev/null || true)
if grep -q 'related (9:[0-9]*): .b. is still unconsumed when this `return`' <<<"$r214_out" \
   && grep -q 'related (10:[0-9]*): .b. is still unconsumed when this `return`' <<<"$r214_out"; then
    echo "  ok  bug 214: each leaking return is named (lines 9 and 10)"
    PASS=$((PASS + 1))
else
    echo "FAIL  bug 214: the two E0208 refusals do not name returns 9 and 10: $(grep -c 'related' <<<"$r214_out") related lines"
    FAIL=$((FAIL + 1))
fi
:
}
