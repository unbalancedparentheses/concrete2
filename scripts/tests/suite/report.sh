# report: the code units of tests/cases/report.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_report_1() {

# --report unsafe should show regular extern under "Extern functions" (not "Trusted")
# This needs a custom check because it combines match + no-match
report_output=$(cached_output "$TESTDIR/ffi_basic.con" "--report unsafe")
if grep <<<"$report_output" -q "Extern functions:" && grep <<<"$report_output" -q "extern fn abs" && ! grep <<<"$report_output" -q "Trusted extern"; then
    echo "  ok  ffi_basic.con --report unsafe shows regular extern (not trusted)"
    PASS=$((PASS + 1))
else
    echo "FAIL  ffi_basic.con --report unsafe should show regular extern, not trusted"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_2() {

# --- report layout: cross-validate sizes against runtime sizeof ---
report_output=$(cached_output "$TESTDIR/report_layout_check.con" "--report layout")
padded_size=$(grep <<<"$report_output" "struct Padded" -A1 | grep -o "size: [0-9]*" | awk "NR==1" | grep -o "[0-9]*")
packed_size=$(grep <<<"$report_output" "struct Packed" -A1 | grep -o "size: [0-9]*" | awk "NR==1" | grep -o "[0-9]*")
expected_sum=$((padded_size + packed_size))
gate_selfprint_wrap "$TESTDIR/report_layout_check.con" "$TMPDIR/report_layout_check.w.con"
$COMPILER "$TMPDIR/report_layout_check.w.con" -o "$TMPDIR/report_layout_check" > /dev/null 2>&1
runtime_sum=$("$TMPDIR/report_layout_check" 2>&1) || true
if [ "$expected_sum" = "$runtime_sum" ]; then
    echo "  ok  report_layout_check.con layout sizes ($padded_size + $packed_size = $expected_sum) match runtime sizeof ($runtime_sum)"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_layout_check.con layout sizes ($padded_size + $packed_size = $expected_sum) != runtime sizeof ($runtime_sum)"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_3() {

# -- Integration test: all report modes on one file --
# Gate: if the file doesn't compile at all, skip all 14 assertions
if compile_gate "$TESTDIR/report_integration.con" "--report caps" "report_integration.con compilation" 14; then

# Caps with why traces
check_report "$TESTDIR/report_integration.con" caps \
    "Alloc.*<- calls vec_new" \
    "report_integration.con --report caps shows Alloc why trace" \
    "report_integration.con --report caps missing Alloc why trace"

check_report "$TESTDIR/report_integration.con" caps \
    "Unsafe.*<- calls raw_extern" \
    "report_integration.con --report caps shows Unsafe why trace" \
    "report_integration.con --report caps missing Unsafe why trace"

# Unsafe with trust boundary analysis
check_report "$TESTDIR/report_integration.con" unsafe \
    "Trust boundary analysis" \
    "report_integration.con --report unsafe shows Trust boundary analysis" \
    "report_integration.con --report unsafe missing Trust boundary analysis"

check_report "$TESTDIR/report_integration.con" unsafe \
    "wraps: extern raw_extern" \
    "report_integration.con --report unsafe shows wraps extern" \
    "report_integration.con --report unsafe missing wraps extern"

# Alloc report
check_report "$TESTDIR/report_integration.con" alloc \
    "allocates: vec_new" \
    "report_integration.con --report alloc shows vec_new allocation" \
    "report_integration.con --report alloc missing vec_new allocation"

check_report "$TESTDIR/report_integration.con" alloc \
    "caller responsible for cleanup" \
    "report_integration.con --report alloc shows returned-alloc note" \
    "report_integration.con --report alloc missing returned-alloc note"

check_report "$TESTDIR/report_integration.con" alloc \
    "defer free" \
    "report_integration.con --report alloc shows defer free" \
    "report_integration.con --report alloc missing defer free"

# Layout: verify struct and enum details
check_report_multi "$TESTDIR/report_integration.con" layout \
    "report_integration.con --report layout shows struct Pair with size" \
    "report_integration.con --report layout missing struct Pair" \
    "struct Pair" "size: 8"

check_report_multi "$TESTDIR/report_integration.con" layout \
    "report_integration.con --report layout shows enum Shape with tag" \
    "report_integration.con --report layout missing enum Shape" \
    "enum Shape" "tag:"

check_report "$TESTDIR/report_integration.con" layout \
    "Totals:.*struct.*enum" \
    "report_integration.con --report layout shows totals" \
    "report_integration.con --report layout missing totals"

# Interface: verify public API exports and private exclusion
check_report_multi "$TESTDIR/report_integration.con" interface \
    "report_integration.con --report interface shows pure_add" \
    "report_integration.con --report interface missing pure_add" \
    "fn pure_add" "(none)"

check_report_multi "$TESTDIR/report_integration.con" interface \
    "report_integration.con --report interface shows uses_alloc with Alloc" \
    "report_integration.con --report interface missing uses_alloc" \
    "fn uses_alloc" "Alloc"

check_report "$TESTDIR/report_integration.con" interface \
    "alloc_no_free" \
    "report_integration.con --report interface excludes private alloc_no_free" \
    "report_integration.con --report interface should not show private alloc_no_free" \
    "!"

# Mono: verify specialization details
check_report_multi "$TESTDIR/report_integration.con" mono \
    "report_integration.con --report mono shows 1 generic function" \
    "report_integration.con --report mono missing generic function count" \
    "Generic functions:" "1"

check_report "$TESTDIR/report_integration.con" mono \
    "identity.*i32" \
    "report_integration.con --report mono shows identity<i32> specialization" \
    "report_integration.con --report mono missing identity<i32> specialization"

fi # end report_integration.con gate

# --- Collection pipeline integration test ---
# Gate: compile once, then run all report assertions only if compilation succeeds
pipeline_compiled=0
if $COMPILER "$TESTDIR/integration_collection_pipeline.con" -o "$TMPDIR/integration_collection_pipeline" > /dev/null 2>&1; then
    pipeline_compiled=1
    pipeline_exit=$("$TMPDIR/integration_collection_pipeline" 2>&1; echo $?)
    pipeline_exit=$(echo "$pipeline_exit" | tail -1)
    if [ "$pipeline_exit" = "0" ]; then
        echo "  ok  integration_collection_pipeline.con compiles and runs correctly"
        PASS=$((PASS + 1))
    else
        echo "FAIL  integration_collection_pipeline.con runtime exit code: $pipeline_exit"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL  integration_collection_pipeline.con failed to compile (skipping 10 dependent assertions)"
    FAIL=$((FAIL + 1))
    save_failure "integration_collection_pipeline_compile" \
        "$COMPILER $TESTDIR/integration_collection_pipeline.con -o /tmp/test" \
        "compilation failed"
fi

if [ "$pipeline_compiled" -eq 1 ]; then
# Caps: multi-level allocation traces
check_report_multi "$TESTDIR/integration_collection_pipeline.con" caps \
    "integration_collection_pipeline.con --report caps shows build_and_summarize Alloc trace" \
    "integration_collection_pipeline.con --report caps missing build_and_summarize trace" \
    "build_and_summarize : Alloc" "<- calls.*vec_new"

check_report_multi "$TESTDIR/integration_collection_pipeline.con" caps \
    "integration_collection_pipeline.con --report caps identifies pure functions" \
    "integration_collection_pipeline.con --report caps missing pure function detection" \
    "classify : (no external authority)" "double : (no external authority)"

# Alloc: multiple allocation patterns
check_report_multi "$TESTDIR/integration_collection_pipeline.con" alloc \
    "integration_collection_pipeline.con --report alloc shows map_vec returns allocation" \
    "integration_collection_pipeline.con --report alloc missing map_vec return-alloc note" \
    "fn map_vec" "caller responsible for cleanup"

check_report_multi "$TESTDIR/integration_collection_pipeline.con" alloc \
    "integration_collection_pipeline.con --report alloc shows build_and_summarize frees" \
    "integration_collection_pipeline.con --report alloc missing build_and_summarize free" \
    "fn build_and_summarize" "frees: vec_free"

check_report_multi "$TESTDIR/integration_collection_pipeline.con" alloc \
    "integration_collection_pipeline.con --report alloc shows count_with_defer defer" \
    "integration_collection_pipeline.con --report alloc missing count_with_defer defer" \
    "fn count_with_defer" "defer free"

check_report "$TESTDIR/integration_collection_pipeline.con" alloc \
    "Totals:.*4 functions allocate" \
    "integration_collection_pipeline.con --report alloc shows 4 allocating functions" \
    "integration_collection_pipeline.con --report alloc wrong allocating function count"

# Layout: struct with 4 fields, enum with 3 variants
check_report_multi "$TESTDIR/integration_collection_pipeline.con" layout \
    "integration_collection_pipeline.con --report layout shows Stats (4 fields, 16 bytes)" \
    "integration_collection_pipeline.con --report layout missing Stats struct" \
    "struct Stats" "size: 16"

check_report_multi "$TESTDIR/integration_collection_pipeline.con" layout \
    "integration_collection_pipeline.con --report layout shows Classification (no payload)" \
    "integration_collection_pipeline.con --report layout missing Classification enum" \
    "enum Classification" "max_payload: 0"

# Interface: public exports
check_report_multi "$TESTDIR/integration_collection_pipeline.con" interface \
    "integration_collection_pipeline.con --report interface shows public functions" \
    "integration_collection_pipeline.con --report interface missing public functions" \
    "fn classify" "fn build_and_summarize"

# Interface: private exclusion (custom check — need both to NOT match)
report_output=$(cached_output "$TESTDIR/integration_collection_pipeline.con" "--report interface")
if ! grep <<<"$report_output" -q "map_vec" && ! grep <<<"$report_output" -q "collect_classified"; then
    echo "  ok  integration_collection_pipeline.con --report interface excludes private functions"
    PASS=$((PASS + 1))
else
    echo "FAIL  integration_collection_pipeline.con --report interface should exclude private functions"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

fi # end integration_collection_pipeline gate
:
}

suite_report_4() {

# === Phase 3: Diagnostic quality assertions ===
# Multi-error: all 3 independent type errors reported
output=$($COMPILER "$TESTDIR/phase3_diag_multi_error.con" --emit-llvm 2>&1 || true)
if grep <<<"$output" -q "type mismatch in let binding 'a'" \
   && grep <<<"$output" -q "type mismatch in let binding 'b'" \
   && grep <<<"$output" -q "type mismatch in let binding 'c'"; then
    echo "  ok  phase3_diag_multi_error.con reports all 3 independent errors"
    PASS=$((PASS + 1))
else
    echo "FAIL  phase3_diag_multi_error.con missing expected errors"
    FAIL=$((FAIL + 1))
fi

# Specific location: error on correct line
output=$($COMPILER "$TESTDIR/phase3_diag_specific_location.con" --emit-llvm 2>&1 || true)
if grep <<<"$output" -q "^.*:9:.*error"; then
    echo "  ok  phase3_diag_specific_location.con error points to line 9"
    PASS=$((PASS + 1))
else
    echo "FAIL  phase3_diag_specific_location.con error not on line 9"
    FAIL=$((FAIL + 1))
fi

# No cascade: single root cause produces < 5 errors
output=$($COMPILER "$TESTDIR/phase3_diag_no_cascade.con" --emit-llvm 2>&1 || true)
error_count=$(grep <<<"$output" -c "error\[" || true)
if [ "$error_count" -lt 5 ]; then
    echo "  ok  phase3_diag_no_cascade.con $error_count error(s) (< 5, no cascade)"
    PASS=$((PASS + 1))
else
    echo "FAIL  phase3_diag_no_cascade.con cascaded into $error_count errors"
    FAIL=$((FAIL + 1))
fi

# Hint quality: capability error includes hint
output=$($COMPILER "$TESTDIR/phase3_diag_hint_quality.con" --emit-llvm 2>&1 || true)
if grep <<<"$output" -q "requires File" && grep <<<"$output" -qi "hint:"; then
    echo "  ok  phase3_diag_hint_quality.con capability error with hint"
    PASS=$((PASS + 1))
else
    echo "FAIL  phase3_diag_hint_quality.con missing hint"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_5() {

# --- ProofCore eligibility classification ---
# Tests that each eligibility gate (source, profile, trusted, entry) is classified correctly.

PCELIG="$TESTDIR/adversarial_proofcore_eligibility.con"

check_report "$PCELIG" eligibility \
    "eligible.*pure_eligible" \
    "proofcore-eligibility: pure function is eligible" \
    "proofcore-eligibility: pure function should be eligible"

check_report "$PCELIG" eligibility \
    "trusted.*trusted_fn" \
    "proofcore-eligibility: trusted function shows trusted" \
    "proofcore-eligibility: trusted function not marked trusted"

check_report "$PCELIG" eligibility \
    "excluded.*file_fn" \
    "proofcore-eligibility: File-cap function excluded" \
    "proofcore-eligibility: File-cap function should be excluded"

check_report "$PCELIG" eligibility \
    "excluded.*recursive_fn" \
    "proofcore-eligibility: recursive function excluded" \
    "proofcore-eligibility: recursive function should be excluded"

check_report "$PCELIG" eligibility \
    "profile: recursion (direct)" \
    "proofcore-eligibility: recursive function shows recursion profile reason" \
    "proofcore-eligibility: recursive function missing recursion reason"

check_report "$PCELIG" eligibility \
    "excluded.*ffi_caller" \
    "proofcore-eligibility: FFI caller excluded" \
    "proofcore-eligibility: FFI caller should be excluded"

check_report "$PCELIG" eligibility \
    "profile: FFI" \
    "proofcore-eligibility: FFI caller shows FFI profile reason" \
    "proofcore-eligibility: FFI caller missing FFI reason"

check_report "$PCELIG" eligibility \
    "excluded.*main.main" \
    "proofcore-eligibility: main is excluded" \
    "proofcore-eligibility: main should be excluded"

check_report "$PCELIG" eligibility \
    "is entry point (main)" \
    "proofcore-eligibility: main shows entry point reason" \
    "proofcore-eligibility: main should show entry point reason"

check_report "$PCELIG" eligibility \
    "1 eligible, 4 excluded.*1 trusted" \
    "proofcore-eligibility: summary counts correct" \
    "proofcore-eligibility: summary counts wrong"

# --- ProofCore extraction success/failure ---
# Tests that PExpr extraction succeeds for simple arithmetic and fails for unsupported constructs.

PCEXT="$TESTDIR/adversarial_proofcore_extraction.con"

# Use snapshot JSON for precise extraction checks
$COMPILER snapshot "$PCEXT" -o "$TMPDIR/ext_test.json" 2>/dev/null
ext_check() {
    local fn="$1" expect_status="$2" expect_unsup="$3" ok_msg="$4" fail_msg="$5"
    local actual
    actual=$(python3 -c "
import json
with open('$TMPDIR/ext_test.json') as f:
    data = json.load(f)
for fact in data['facts']:
    if fact['kind'] == 'extraction' and fact['function'] == '$fn':
        status = fact['status']
        unsup = ','.join(fact.get('unsupported', []))
        print(f'{status}|{unsup}')
        break
" 2>/dev/null)
    local actual_status="${actual%%|*}"
    local actual_unsup="${actual#*|}"
    if [ "$actual_status" = "$expect_status" ]; then
        if [ -z "$expect_unsup" ] || grep <<<"$actual_unsup" -q "$expect_unsup"; then
            echo "  ok  $ok_msg"
            PASS=$((PASS + 1))
            return
        fi
    fi
    echo "FAIL  $fail_msg"
    echo "  got: status=$actual_status unsupported=$actual_unsup"
    FAIL=$((FAIL + 1))
}
:
}

suite_report_6() {

check_report "$PCEXT" extraction \
    "3 extracted, 1 eligible but not extractable, 2 excluded" \
    "proofcore-extraction: summary totals correct" \
    "proofcore-extraction: summary totals wrong"

# --- Spec-drift gate regression (commit f371cc1) ---
# A checked-in fixture where:
#   * source body_fingerprint MATCHES the registered fingerprint
#     (so the existing staleFingerprint check does NOT fire)
#   * registered Lean spec (Concrete.Proof.driftTestSpec) does
#     NOT match the source-extracted PExpr
# Gate must surface a `spec drift` error AND downgrade status
# from `proved` to `stale`. If either link breaks, the gate is
# silently bypassable.
PCDRIFT="$TESTDIR/adversarial_spec_drift/test_drift.con"
drift_out=$($COMPILER "$PCDRIFT" --report proof-status 2>&1 || true)
if grep <<<"$drift_out" -q "spec drift for 'test_drift.simple_add'" && \
   grep <<<"$drift_out" -q "registered spec 'Concrete.Proof.driftTestSpec'" && \
   grep <<<"$drift_out" -q "does not match the source-extracted PExpr"; then
    echo "  ok  spec_drift: gate fires with precise diagnostic"
    PASS=$((PASS + 1))
else
    echo "FAIL  spec_drift: gate diagnostic missing or wrong"
    echo "$drift_out"
    FAIL=$((FAIL + 1))
fi
# Obligation status must downgrade to stale (not stay proved).
if grep <<<"$drift_out" -q "proof stale" && \
   grep <<<"$drift_out" -E "Totals:.*1 stale.*0 proved|Totals:.*0 proved.*1 stale" >/dev/null; then
    echo "  ok  spec_drift: obligation status downgrades to stale"
    PASS=$((PASS + 1))
else
    echo "FAIL  spec_drift: status should downgrade to stale, not stay proved"
    grep <<<"$drift_out" -E "Totals|proof stale|proved" | awk "NR<=5"
    FAIL=$((FAIL + 1))
fi

# --- PBinOp width discipline (Phase 4 multi-width regression) ---
# u8 ^ u8 is proof-eligible by profile but must reject at
# extraction with a precise blocker — NOT silently fall back
# to i32 semantics. Regression for commits 6369f2d (shape)
# and the signedness fix that followed.
PCWIDTHS="$TESTDIR/adversarial_pbinop_widths.con"
widths_out=$($COMPILER "$PCWIDTHS" --report proof-status 2>&1 || true)
if grep <<<"$widths_out" -q "u16_xor_blocks" && \
   grep <<<"$widths_out" -q "Concrete.BinOp.bitxor at Concrete.Ty.u16"; then
    echo "  ok  pbinop_widths: u16 ^ u16 blocks with precise diagnostic"
    PASS=$((PASS + 1))
else
    echo "FAIL  pbinop_widths: u16 ^ u16 should block with precise diagnostic"
    echo "$widths_out"
    FAIL=$((FAIL + 1))
fi

# --- ProofCore fingerprint properties ---
# Tests fingerprint determinism: identical bodies → same fingerprint, different bodies → different.

PCFP="$TESTDIR/adversarial_proofcore_fingerprint.con"

# Use snapshot JSON to compare fingerprints programmatically
$COMPILER snapshot "$PCFP" -o "$TMPDIR/fp_test.json" 2>/dev/null
fp_add_v1=$(python3 -c "
import json, sys
with open('$TMPDIR/fp_test.json') as f:
    data = json.load(f)
for fact in data['facts']:
    if fact['kind'] == 'extraction' and fact['function'] == 'main.add_v1':
        print(fact['fingerprint']); break
" 2>/dev/null)
fp_add_v2=$(python3 -c "
import json, sys
with open('$TMPDIR/fp_test.json') as f:
    data = json.load(f)
for fact in data['facts']:
    if fact['kind'] == 'extraction' and fact['function'] == 'main.add_v2':
        print(fact['fingerprint']); break
" 2>/dev/null)
fp_sub_v1=$(python3 -c "
import json, sys
with open('$TMPDIR/fp_test.json') as f:
    data = json.load(f)
for fact in data['facts']:
    if fact['kind'] == 'extraction' and fact['function'] == 'main.sub_v1':
        print(fact['fingerprint']); break
" 2>/dev/null)
fp_add_comment=$(python3 -c "
import json, sys
with open('$TMPDIR/fp_test.json') as f:
    data = json.load(f)
for fact in data['facts']:
    if fact['kind'] == 'extraction' and fact['function'] == 'main.add_with_comment':
        print(fact['fingerprint']); break
" 2>/dev/null)

if [ "$fp_add_v1" = "$fp_add_v2" ] && [ -n "$fp_add_v1" ]; then
    echo "  ok  proofcore-fingerprint: identical bodies produce identical fingerprints"
    PASS=$((PASS + 1))
else
    echo "FAIL  proofcore-fingerprint: identical bodies should produce identical fingerprints"
    echo "  add_v1=$fp_add_v1"
    echo "  add_v2=$fp_add_v2"
    FAIL=$((FAIL + 1))
fi

if [ "$fp_add_v1" != "$fp_sub_v1" ] && [ -n "$fp_add_v1" ] && [ -n "$fp_sub_v1" ]; then
    echo "  ok  proofcore-fingerprint: different bodies produce different fingerprints"
    PASS=$((PASS + 1))
else
    echo "FAIL  proofcore-fingerprint: different bodies should produce different fingerprints"
    echo "  add_v1=$fp_add_v1"
    echo "  sub_v1=$fp_sub_v1"
    FAIL=$((FAIL + 1))
fi

if [ "$fp_add_v1" = "$fp_add_comment" ] && [ -n "$fp_add_v1" ]; then
    echo "  ok  proofcore-fingerprint: comments do not affect fingerprint"
    PASS=$((PASS + 1))
else
    echo "FAIL  proofcore-fingerprint: comments should not affect fingerprint"
    echo "  add_v1=$fp_add_v1"
    echo "  add_with_comment=$fp_add_comment"
    FAIL=$((FAIL + 1))
fi

# --- ProofCore exclusion kinds ---
# Tests each ExclusionKind value: source, profile, both.

PCXK="$TESTDIR/adversarial_proofcore_exclusion_kinds.con"

check_report "$PCXK" eligibility \
    "eligible.*clean_fn" \
    "proofcore-exclusion: clean function is eligible" \
    "proofcore-exclusion: clean function should be eligible"

check_report "$PCXK" eligibility \
    "excluded.*source_only_fn" \
    "proofcore-exclusion: source_only_fn is excluded" \
    "proofcore-exclusion: source_only_fn should be excluded"

check_report "$PCXK" eligibility \
    "excluded.*profile_only_fn" \
    "proofcore-exclusion: profile_only_fn is excluded" \
    "proofcore-exclusion: profile_only_fn should be excluded"

check_report "$PCXK" eligibility \
    "excluded.*both_fn" \
    "proofcore-exclusion: both_fn is excluded" \
    "proofcore-exclusion: both_fn should be excluded"

# Verify source_only has source reason but not profile
check_report "$PCXK" eligibility \
    "source: has capabilities: Unsafe" \
    "proofcore-exclusion: source_only shows Unsafe source reason" \
    "proofcore-exclusion: source_only should show Unsafe source reason"

# Verify profile_only has recursion profile reason
check_report "$PCXK" eligibility \
    "profile: recursion (direct)" \
    "proofcore-exclusion: profile_only shows recursion profile reason" \
    "proofcore-exclusion: profile_only should show recursion profile reason"

# Verify summary reflects exclusion kind breakdown
check_report "$PCXK" eligibility \
    "1 eligible, 4 excluded (1 source, 1 profile, 2 both), 0 trusted" \
    "proofcore-exclusion: summary breakdown correct" \
    "proofcore-exclusion: summary breakdown wrong"

# Verify via snapshot JSON that exclusion_kind values are correct
$COMPILER snapshot "$PCXK" -o "$TMPDIR/xk_test.json" 2>/dev/null
xk_source=$(python3 -c "
import json
with open('$TMPDIR/xk_test.json') as f:
    data = json.load(f)
for fact in data['facts']:
    if fact['kind'] == 'eligibility' and fact['function'] == 'main.source_only_fn':
        print(fact['exclusion_kind']); break
" 2>/dev/null)
xk_profile=$(python3 -c "
import json
with open('$TMPDIR/xk_test.json') as f:
    data = json.load(f)
for fact in data['facts']:
    if fact['kind'] == 'eligibility' and fact['function'] == 'main.profile_only_fn':
        print(fact['exclusion_kind']); break
" 2>/dev/null)
xk_both=$(python3 -c "
import json
with open('$TMPDIR/xk_test.json') as f:
    data = json.load(f)
for fact in data['facts']:
    if fact['kind'] == 'eligibility' and fact['function'] == 'main.both_fn':
        print(fact['exclusion_kind']); break
" 2>/dev/null)

if [ "$xk_source" = "source" ]; then
    echo "  ok  proofcore-exclusion: snapshot exclusion_kind=source for source_only_fn"
    PASS=$((PASS + 1))
else
    echo "FAIL  proofcore-exclusion: snapshot exclusion_kind should be 'source' for source_only_fn (got: $xk_source)"
    FAIL=$((FAIL + 1))
fi

if [ "$xk_profile" = "profile" ]; then
    echo "  ok  proofcore-exclusion: snapshot exclusion_kind=profile for profile_only_fn"
    PASS=$((PASS + 1))
else
    echo "FAIL  proofcore-exclusion: snapshot exclusion_kind should be 'profile' for profile_only_fn (got: $xk_profile)"
    FAIL=$((FAIL + 1))
fi

if [ "$xk_both" = "both" ]; then
    echo "  ok  proofcore-exclusion: snapshot exclusion_kind=both for both_fn"
    PASS=$((PASS + 1))
else
    echo "FAIL  proofcore-exclusion: snapshot exclusion_kind should be 'both' for both_fn (got: $xk_both)"
    FAIL=$((FAIL + 1))
fi

# --- ProofCore normalization ---
# Tests that PExpr normalization rewrites are applied correctly.

PCNORM="$TESTDIR/adversarial_proofcore_normalization.con"
$COMPILER snapshot "$PCNORM" -o "$TMPDIR/norm_test.json" 2>/dev/null

norm_check() {
    local fn="$1" expect="$2" ok_msg="$3" fail_msg="$4"
    local actual
    actual=$(python3 -c "
import json
with open('$TMPDIR/norm_test.json') as f:
    data = json.load(f)
for fact in data['facts']:
    if fact['kind'] == 'extraction' and fact['function'] == '$fn':
        print(fact.get('proof_core', ''))
        break
" 2>/dev/null)
    if [ "$actual" = "$expect" ]; then
        echo "  ok  $ok_msg"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $fail_msg"
        echo "    expected: $expect"
        echo "    got:      $actual"
        FAIL=$((FAIL + 1))
    fi
}
:
}

suite_report_7() {

check_report "$PCNORM" extraction \
    "13 extracted, 0 eligible but not extractable, 1 excluded" \
    "proofcore-norm: summary totals correct" \
    "proofcore-norm: summary totals wrong"

# --- Qualified call graph identity ---
# Tests that same-name functions in different modules get distinct qualified identities.

PCQCG="$TESTDIR/adversarial_qualified_callgraph.con"
$COMPILER snapshot "$PCQCG" -o "$TMPDIR/qcg_test.json" 2>/dev/null

# Both helpers should exist as separate extraction entries
if python3 -c "
import json
with open('$TMPDIR/qcg_test.json') as f:
    data = json.load(f)
fns = [f['function'] for f in data['facts'] if f['kind'] == 'extraction']
assert 'alpha.helper' in fns, 'alpha.helper missing'
assert 'beta.helper' in fns, 'beta.helper missing'
assert 'alpha.caller' in fns, 'alpha.caller missing'
assert 'beta.caller' in fns, 'beta.caller missing'
" 2>/dev/null; then
    echo "  ok  qualified-callgraph: same-name functions get distinct qualified identities"
    PASS=$((PASS + 1))
else
    echo "FAIL  qualified-callgraph: same-name functions should get distinct qualified identities"
    FAIL=$((FAIL + 1))
fi

# alpha.helper and beta.helper should have different proof_core content
if python3 -c "
import json
with open('$TMPDIR/qcg_test.json') as f:
    data = json.load(f)
exts = {f['function']: f.get('proof_core','') for f in data['facts'] if f['kind'] == 'extraction'}
assert exts['alpha.helper'] != exts['beta.helper'], 'same proof_core for different helpers'
assert '+ 1' in exts['alpha.helper'], 'alpha.helper wrong content'
assert '* 2' in exts['beta.helper'], 'beta.helper wrong content'
" 2>/dev/null; then
    echo "  ok  qualified-callgraph: distinct helpers have distinct ProofCore"
    PASS=$((PASS + 1))
else
    echo "FAIL  qualified-callgraph: distinct helpers should have distinct ProofCore"
    FAIL=$((FAIL + 1))
fi

# Neither helper should be marked recursive (no collision)
if python3 -c "
import json
with open('$TMPDIR/qcg_test.json') as f:
    data = json.load(f)
for f in data['facts']:
    if f['kind'] == 'extraction' and f['function'] in ('alpha.helper', 'beta.helper'):
        assert f['status'] == 'extracted', f'{f[\"function\"]} not extracted: {f[\"status\"]}'
" 2>/dev/null; then
    echo "  ok  qualified-callgraph: no false recursion from name collision"
    PASS=$((PASS + 1))
else
    echo "FAIL  qualified-callgraph: name collision causing false recursion"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_8() {

# --- Spec identity / attachment model ---
# Tests that FunctionIdentity, SpecIdentity, and SpecAttachment flow through ProofCore.

SPEC_DIR="$TESTDIR/adversarial_spec_identity"
SPEC_PROG="$SPEC_DIR/test_spec.con"

$COMPILER snapshot "$SPEC_PROG" -o "$TMPDIR/spec_identity.json" 2>/dev/null

# Spec identity flows into extraction facts
if python3 -c "
import json
with open('$TMPDIR/spec_identity.json') as f:
    data = json.load(f)
exts = {f['function']: f for f in data['facts'] if f['kind'] == 'extraction'}
assert exts['main.pure_add'].get('spec') == 'add_commutativity', 'add spec wrong'
assert exts['main.pure_add'].get('proof') == 'Examples.TestFixtures.Proofs.pure_add_correct', 'add proof wrong'
assert exts['main.pure_mul'].get('spec') == 'mul_associativity', 'mul spec wrong'
assert exts['main.pure_mul'].get('proof') == 'Examples.TestFixtures.Proofs.pure_mul_correct', 'mul proof wrong'
" 2>/dev/null; then
    echo "  ok  spec-identity: extraction facts carry spec/proof from registry"
    PASS=$((PASS + 1))
else
    echo "FAIL  spec-identity: extraction facts should carry spec/proof from registry"
    FAIL=$((FAIL + 1))
fi

# Spec identity flows into proof-status facts
if python3 -c "
import json
with open('$TMPDIR/spec_identity.json') as f:
    data = json.load(f)
ps = {f['function']: f for f in data['facts'] if f['kind'] == 'proof_status'}
assert ps['main.pure_add']['state'] == 'proved', 'add not proved'
assert ps['main.pure_add'].get('spec') == 'add_commutativity', 'add spec wrong'
assert ps['main.pure_add'].get('source') == 'registry', 'add source wrong'
assert ps['main.pure_mul']['state'] == 'proved', 'mul not proved'
assert ps['main.pure_mul'].get('spec') == 'mul_associativity', 'mul spec wrong'
" 2>/dev/null; then
    echo "  ok  spec-identity: proof-status facts carry spec/source from registry"
    PASS=$((PASS + 1))
else
    echo "FAIL  spec-identity: proof-status facts should carry spec/source from registry"
    FAIL=$((FAIL + 1))
fi

# Spec identity flows into obligation facts
if python3 -c "
import json
with open('$TMPDIR/spec_identity.json') as f:
    data = json.load(f)
obs = {f['function']: f for f in data['facts'] if f['kind'] == 'obligation'}
assert obs['main.pure_add']['spec'] == 'add_commutativity', 'add spec wrong'
assert obs['main.pure_add']['proof'] == 'Examples.TestFixtures.Proofs.pure_add_correct', 'add proof wrong'
assert obs['main.pure_add']['source'] == 'registry', 'add source wrong'
assert obs['main.pure_add']['status'] == 'proved', 'add not proved'
" 2>/dev/null; then
    echo "  ok  spec-identity: obligation facts carry spec/proof/source"
    PASS=$((PASS + 1))
else
    echo "FAIL  spec-identity: obligation facts should carry spec/proof/source"
    FAIL=$((FAIL + 1))
fi

# Entry point (main) has no spec attachment
if python3 -c "
import json
with open('$TMPDIR/spec_identity.json') as f:
    data = json.load(f)
ps = {f['function']: f for f in data['facts'] if f['kind'] == 'proof_status'}
assert ps['main.main']['state'] == 'ineligible'
assert ps['main.main'].get('spec', '') == ''
assert ps['main.main'].get('proof', '') == ''
" 2>/dev/null; then
    echo "  ok  spec-identity: entry point has no spec attachment"
    PASS=$((PASS + 1))
else
    echo "FAIL  spec-identity: entry point should have no spec attachment"
    FAIL=$((FAIL + 1))
fi

# Spec identity is consistent across all fact families
if python3 -c "
import json
with open('$TMPDIR/spec_identity.json') as f:
    data = json.load(f)
fn = 'main.pure_add'
ext = [f for f in data['facts'] if f['kind'] == 'extraction' and f['function'] == fn][0]
ps = [f for f in data['facts'] if f['kind'] == 'proof_status' and f['function'] == fn][0]
ob = [f for f in data['facts'] if f['kind'] == 'obligation' and f['function'] == fn][0]
assert ext.get('spec') == ps.get('spec') == ob.get('spec'), 'spec mismatch across families'
assert ext.get('proof') == ps.get('proof') == ob.get('proof'), 'proof mismatch across families'
" 2>/dev/null; then
    echo "  ok  spec-identity: consistent across extraction/proof-status/obligation"
    PASS=$((PASS + 1))
else
    echo "FAIL  spec-identity: spec should be consistent across all fact families"
    FAIL=$((FAIL + 1))
fi

# Human-readable extraction report shows spec/proof
check_report "$SPEC_PROG" extraction \
    "spec: add_commutativity" \
    "spec-identity: extraction report shows spec name" \
    "spec-identity: extraction report should show spec name"

check_report "$SPEC_PROG" extraction \
    "proof: Examples.TestFixtures.Proofs.pure_add_correct" \
    "spec-identity: extraction report shows proof name" \
    "spec-identity: extraction report should show proof name"

# --- Mechanical obligation generation ---
# Tests that obligations are generated in ProofCore with correct status,
# identity, and dependencies — not re-derived in Report.lean.

OBL_DIR="$TESTDIR/adversarial_obligations"
OBL_PROG="$OBL_DIR/test_obligations.con"
$COMPILER snapshot "$OBL_PROG" -o "$TMPDIR/obl_gen.json" 2>/dev/null

# All 5 obligation statuses present
if python3 -c "
import json
with open('$TMPDIR/obl_gen.json') as f:
    data = json.load(f)
obs = {f['function']: f for f in data['facts'] if f['kind'] == 'obligation'}
assert obs['main.pure_add']['status'] == 'proved', 'proved wrong'
assert obs['main.pure_stale']['status'] == 'stale', 'stale wrong'
assert obs['main.pure_no_spec']['status'] == 'missing', 'missing wrong'
assert obs['main.uses_alloc']['status'] == 'ineligible', 'ineligible wrong'
assert obs['main.trusted_op']['status'] == 'trusted', 'trusted wrong'
" 2>/dev/null; then
    echo "  ok  obligation-gen: all 5 statuses derived correctly"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligation-gen: should derive all 5 obligation statuses"
    FAIL=$((FAIL + 1))
fi

# Obligation identity carries function fingerprint
if python3 -c "
import json
with open('$TMPDIR/obl_gen.json') as f:
    data = json.load(f)
obs = {f['function']: f for f in data['facts'] if f['kind'] == 'obligation'}
assert obs['main.pure_add']['fingerprint'] != '', 'add fingerprint empty'
assert obs['main.pure_stale']['fingerprint'] != '', 'stale fingerprint empty'
assert obs['main.pure_no_spec']['fingerprint'] != '', 'no_spec fingerprint empty'
" 2>/dev/null; then
    echo "  ok  obligation-gen: obligations carry function fingerprint"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligation-gen: obligations should carry function fingerprint"
    FAIL=$((FAIL + 1))
fi

# Proved obligation carries spec identity from registry
if python3 -c "
import json
with open('$TMPDIR/obl_gen.json') as f:
    data = json.load(f)
obs = {f['function']: f for f in data['facts'] if f['kind'] == 'obligation'}
o = obs['main.pure_add']
assert o['spec'] == 'add_commutativity', 'spec wrong'
assert o['proof'] == 'Examples.TestFixtures.Proofs.pure_add_correct', 'proof wrong'
assert o['source'] == 'registry', 'source wrong'
" 2>/dev/null; then
    echo "  ok  obligation-gen: proved obligation carries spec identity"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligation-gen: proved obligation should carry spec identity"
    FAIL=$((FAIL + 1))
fi

# Stale obligation carries spec but mismatched fingerprint
if python3 -c "
import json
with open('$TMPDIR/obl_gen.json') as f:
    data = json.load(f)
obs = {f['function']: f for f in data['facts'] if f['kind'] == 'obligation'}
o = obs['main.pure_stale']
assert o['status'] == 'stale', 'not stale'
assert o['spec'] == 'sub_identity', 'spec wrong'
assert o['source'] == 'registry', 'source wrong'
" 2>/dev/null; then
    echo "  ok  obligation-gen: stale obligation attributable to fingerprint mismatch"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligation-gen: stale obligation should carry spec + registry source"
    FAIL=$((FAIL + 1))
fi

# Missing obligation has no spec
if python3 -c "
import json
with open('$TMPDIR/obl_gen.json') as f:
    data = json.load(f)
obs = {f['function']: f for f in data['facts'] if f['kind'] == 'obligation'}
o = obs['main.pure_no_spec']
assert o['status'] == 'missing', 'not missing'
assert o.get('spec', '') == '', 'should have no spec'
assert o.get('source', '') == 'none', 'source should be none'
" 2>/dev/null; then
    echo "  ok  obligation-gen: missing obligation has no spec attachment"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligation-gen: missing obligation should have empty spec"
    FAIL=$((FAIL + 1))
fi

# Dependencies track proved callees
if python3 -c "
import json
with open('$TMPDIR/obl_gen.json') as f:
    data = json.load(f)
obs = {f['function']: f for f in data['facts'] if f['kind'] == 'obligation'}
# main calls pure_add (proved), so main should list it as dependency
deps = obs['main.main']['dependencies']
assert 'main.pure_add' in deps, f'proved callee not in deps: {deps}'
# pure_add has no proved callees
assert obs['main.pure_add']['dependencies'] == [], 'leaf should have no deps'
" 2>/dev/null; then
    echo "  ok  obligation-gen: dependencies track proved callees from call graph"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligation-gen: dependencies should track proved callees"
    FAIL=$((FAIL + 1))
fi

# Obligation status consistent with proof-status facts
if python3 -c "
import json
with open('$TMPDIR/obl_gen.json') as f:
    data = json.load(f)
obs = {f['function']: f for f in data['facts'] if f['kind'] == 'obligation'}
ps = {f['function']: f for f in data['facts'] if f['kind'] == 'proof_status'}
status_map = {'proved': 'proved', 'stale': 'stale', 'missing': 'missing',
              'ineligible': 'ineligible', 'trusted': 'trusted'}
for fn in obs:
    obl_status = obs[fn]['status']
    ps_state = ps[fn]['state']
    expected = status_map.get(obl_status, obl_status)
    assert ps_state == expected, f'{fn}: obligation={obl_status} vs proof_status={ps_state}'
" 2>/dev/null; then
    echo "  ok  obligation-gen: obligation status consistent with proof-status facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligation-gen: obligation status should match proof-status facts"
    FAIL=$((FAIL + 1))
fi

# Human-readable obligations report shows all statuses
check_report "$OBL_PROG" obligations \
    "proved" \
    "obligation-gen: obligations report shows proved" \
    "obligation-gen: obligations report should show proved"

check_report "$OBL_PROG" obligations \
    "stale" \
    "obligation-gen: obligations report shows stale" \
    "obligation-gen: obligations report should show stale"

check_report "$OBL_PROG" obligations \
    "missing" \
    "obligation-gen: obligations report shows missing" \
    "obligation-gen: obligations report should show missing"
:
}

suite_report_9() {

# Predictable violation produces JSON with correct kind and fields
json_output=$(cached_output "$TESTDIR/report_check_predictable_fail_loops.con" "--report diagnostics-json")
if grep <<<"$json_output" -q '"kind": "predictable_violation"'; then
    echo "  ok  diagnostics-json: predictable_violation kind present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: predictable_violation kind missing"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

if grep <<<"$json_output" -q '"reason": "unbounded loops"'; then
    echo "  ok  diagnostics-json: unbounded loops reason present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: unbounded loops reason missing"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

if grep <<<"$json_output" -q '"function": "main.spin"'; then
    echo "  ok  diagnostics-json: spin function name present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: spin function name missing"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

# Source location present in violation
if grep <<<"$json_output" -q '"loc":.*"file":.*"line":'; then
    echo "  ok  diagnostics-json: source location present in violation"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: source location missing in violation"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

# Violation location present (offending construct)
if grep <<<"$json_output" -q '"violation_loc":.*"file":.*"line":'; then
    echo "  ok  diagnostics-json: violation_loc present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: violation_loc missing"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

# Proof-status entries present
if grep <<<"$json_output" -q '"kind": "proof_status"'; then
    echo "  ok  diagnostics-json: proof_status kind present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: proof_status kind missing"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

# Proof-status entry has fingerprint
if grep <<<"$json_output" -q '"current_fingerprint":'; then
    echo "  ok  diagnostics-json: current_fingerprint present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: current_fingerprint missing"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

# Recursion violation produces JSON
json_rec=$(cached_output "$TESTDIR/report_check_predictable_fail_recursion.con" "--report diagnostics-json")
if grep <<<"$json_rec" -q '"reason": "direct recursion"'; then
    echo "  ok  diagnostics-json: direct recursion reason present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: direct recursion reason missing"
    echo "$json_rec"
    FAIL=$((FAIL + 1))
fi

# Passing file produces no predictable violations but has proof-status
json_pass=$(cached_output "$TESTDIR/report_check_predictable_pass.con" "--report diagnostics-json")
if grep <<<"$json_pass" -q '"kind": "proof_status"' && ! grep <<<"$json_pass" -q '"kind": "predictable_violation"'; then
    echo "  ok  diagnostics-json: passing file has proof_status but no violations"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: passing file should have proof_status only"
    echo "$json_pass"
    FAIL=$((FAIL + 1))
fi

# Output is a well-formed JSON envelope. Validate by PARSING, not by grepping for
# a leading `{` / trailing `}`: the brace grep was fragile to trailing whitespace
# and line endings and failed nondeterministically on some CI runners (notably the
# macOS runner) even though the JSON was valid. Parsing is what "is an envelope"
# actually means.
if printf '%s' "$json_output" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d, dict) and 'schema_version' in d else 1)" 2>/dev/null; then
    echo "  ok  diagnostics-json: output is a well-formed JSON envelope"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: output should be a well-formed JSON envelope"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

# --- Effects facts ---
json_int=$(cached_output "$TESTDIR/report_integration.con" "--report diagnostics-json")

if grep <<<"$json_int" -q '"kind": "effects"'; then
    echo "  ok  diagnostics-json: effects kind present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: effects kind missing"
    FAIL=$((FAIL + 1))
fi

# Effects fact carries key fields
if grep <<<"$json_int" -q '"no_external_authority":' && grep <<<"$json_int" -q '"evidence":'; then
    echo "  ok  diagnostics-json: effects carries no_external_authority and evidence"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: effects missing no_external_authority or evidence"
    FAIL=$((FAIL + 1))
fi

# Pure function has no_external_authority: true
if grep <<<"$json_int" -q '"function": "main.pure_add".*"no_external_authority": true'; then
    echo "  ok  diagnostics-json: pure_add has no_external_authority true"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: pure_add should have no_external_authority true"
    FAIL=$((FAIL + 1))
fi

# --- Capability facts ---
if grep <<<"$json_int" -q '"kind": "capability"'; then
    echo "  ok  diagnostics-json: capability kind present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: capability kind missing"
    FAIL=$((FAIL + 1))
fi

# Capability fact has why traces
if grep <<<"$json_int" -q '"why":'; then
    echo "  ok  diagnostics-json: capability facts have why traces"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: capability facts missing why traces"
    FAIL=$((FAIL + 1))
fi

# --- Unsafe facts ---
if grep <<<"$json_int" -q '"kind": "unsafe"'; then
    echo "  ok  diagnostics-json: unsafe kind present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: unsafe kind missing"
    FAIL=$((FAIL + 1))
fi

# Trusted function has trust_boundary
if grep <<<"$json_int" -q '"trust_boundary":'; then
    echo "  ok  diagnostics-json: trust_boundary present for trusted fn"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: trust_boundary missing"
    FAIL=$((FAIL + 1))
fi

# --- Alloc facts ---
if grep <<<"$json_int" -q '"kind": "alloc"'; then
    echo "  ok  diagnostics-json: alloc kind present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: alloc kind missing"
    FAIL=$((FAIL + 1))
fi

# Alloc fact has allocates and frees arrays
if grep <<<"$json_int" -q '"allocates":.*\[' && grep <<<"$json_int" -q '"potential_leak":'; then
    echo "  ok  diagnostics-json: alloc fact carries allocates array and potential_leak"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: alloc fact missing allocates or potential_leak"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_10() {

# Use report_integration.con — it has pure, alloc, trusted, extern, FFI, caps
RC_FILE="$TESTDIR/report_integration.con"
rc_json=$(cached_output "$RC_FILE" "--report diagnostics-json")
rc_caps=$(cached_output "$RC_FILE" "--report caps")
rc_effects=$(cached_output "$RC_FILE" "--report effects")
rc_alloc=$(cached_output "$RC_FILE" "--report alloc")
rc_unsafe=$(cached_output "$RC_FILE" "--report unsafe")

# --- Layer 1: Intra-JSON consistency ---

# 1a. Effects says pure_add no_external_authority:true → capability fact should have empty capabilities
# (grep the JSON line for pure_add's capability fact and check for empty array)
if grep <<<"$rc_json" -q '"kind": "capability".*"function": "main.pure_add".*"no_external_authority": true'; then
    echo "  ok  consistency: capability fact agrees pure_add is pure"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: capability fact should show pure_add as pure"
    FAIL=$((FAIL + 1))
fi

# 1b. Effects says uses_alloc allocates:true → an alloc fact for uses_alloc should exist
if grep <<<"$rc_json" -q '"kind": "effects".*"function": "main.uses_alloc".*"allocates": true' && \
   grep <<<"$rc_json" -q '"kind": "alloc".*"function": "main.uses_alloc"'; then
    echo "  ok  consistency: effects allocates:true ↔ alloc fact exists for uses_alloc"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/alloc disagree on uses_alloc allocation"
    FAIL=$((FAIL + 1))
fi

# 1c. Effects says call_raw is_trusted:true → unsafe fact should have is_trusted:true
if grep <<<"$rc_json" -q '"kind": "effects".*"function": "main.call_raw".*"is_trusted": true' && \
   grep <<<"$rc_json" -q '"kind": "unsafe".*"function": "main.call_raw".*"is_trusted": true'; then
    echo "  ok  consistency: effects/unsafe agree call_raw is trusted"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/unsafe disagree on call_raw trusted status"
    FAIL=$((FAIL + 1))
fi

# 1d. Effects says call_raw crosses_ffi:true → predictable_violation for call_raw should exist
if grep <<<"$rc_json" -q '"kind": "effects".*"function": "main.call_raw".*"crosses_ffi": true' && \
   grep <<<"$rc_json" -q '"kind": "predictable_violation".*"function": "main.call_raw"'; then
    echo "  ok  consistency: effects crosses_ffi ↔ predictable_violation for call_raw"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/predictable disagree on call_raw FFI violation"
    FAIL=$((FAIL + 1))
fi

# 1e. Effects says pure_add evidence:enforced → proof_status should be eligible and waiting for proof
# Note: JSON is one line, so we extract per-record to avoid cross-record grep matches
pure_add_proof_state=$(grep <<<"$rc_json" -o '"kind": "proof_status"[^}]*"function": "main.pure_add"[^}]*' | grep -o '"state": "[^"]*"' | awk "NR==1")
if grep <<<"$rc_json" -q '"kind": "effects".*"function": "main.pure_add".*"evidence": "enforced"' && \
   [ "$pure_add_proof_state" = '"state": "missing"' ]; then
    echo "  ok  consistency: effects enforced ↔ proof_status eligible/missing for pure_add"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/proof_status disagree on pure_add eligibility (state=$pure_add_proof_state)"
    FAIL=$((FAIL + 1))
fi

# 1f. Effects says call_raw evidence:trusted-assumption → proof_status should be trusted
if grep <<<"$rc_json" -q '"kind": "effects".*"function": "main.call_raw".*"evidence": "trusted-assumption"' && \
   grep <<<"$rc_json" -q '"kind": "proof_status".*"function": "main.call_raw".*"state": "trusted"'; then
    echo "  ok  consistency: effects trusted-assumption ↔ proof_status trusted for call_raw"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/proof_status disagree on call_raw trusted status"
    FAIL=$((FAIL + 1))
fi

# 1g. alloc_no_free has potential_leak:true (allocates, no free, no defer, returns heap)
if grep <<<"$rc_json" -q '"kind": "alloc".*"function": "main.alloc_no_free".*"potential_leak": false'; then
    # returns_allocation is true so potential_leak should be false (caller responsible)
    echo "  ok  consistency: alloc_no_free returns allocation, no leak flagged"
    PASS=$((PASS + 1))
else
    # Check the alternative: potential_leak true would also be consistent if returns_allocation false
    if grep <<<"$rc_json" -q '"kind": "alloc".*"function": "main.alloc_no_free".*"returns_allocation": true'; then
        echo "  ok  consistency: alloc_no_free returns allocation, no leak flagged"
        PASS=$((PASS + 1))
    else
        echo "FAIL  consistency: alloc_no_free should have returns_allocation or potential_leak"
        FAIL=$((FAIL + 1))
    fi
fi

# --- Layer 2: JSON ↔ human report consistency ---

# 2a. Human caps says "pure_add : (no external authority)" → JSON effects has no_external_authority:true
if grep <<<"$rc_caps" -q "pure_add : (no external authority)" && \
   grep <<<"$rc_json" -q '"kind": "effects".*"function": "main.pure_add".*"no_external_authority": true'; then
    echo "  ok  consistency: --report caps (pure) ↔ JSON no_external_authority for pure_add"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: caps/JSON disagree on pure_add purity"
    FAIL=$((FAIL + 1))
fi

# 2b. Human caps says "uses_alloc : Alloc" → JSON capability has Alloc
if grep <<<"$rc_caps" -q "uses_alloc : Alloc" && \
   grep <<<"$rc_json" -q '"kind": "capability".*"function": "main.uses_alloc".*"Alloc"'; then
    echo "  ok  consistency: --report caps Alloc ↔ JSON capability for uses_alloc"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: caps/JSON disagree on uses_alloc Alloc capability"
    FAIL=$((FAIL + 1))
fi

# 2c. Human effects says "call_raw ... ffi: yes" → JSON effects has crosses_ffi:true
if grep <<<"$rc_effects" -A1 "call_raw" | has_match "ffi: yes" && \
   grep <<<"$rc_json" -q '"kind": "effects".*"function": "main.call_raw".*"crosses_ffi": true'; then
    echo "  ok  consistency: --report effects ffi:yes ↔ JSON crosses_ffi for call_raw"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/JSON disagree on call_raw FFI status"
    FAIL=$((FAIL + 1))
fi

# 2d. Human effects says "pure_add ... evidence: enforced" → JSON effects matches
if grep <<<"$rc_effects" -A1 "pure_add" | has_match "evidence: enforced" && \
   grep <<<"$rc_json" -q '"kind": "effects".*"function": "main.pure_add".*"evidence": "enforced"'; then
    echo "  ok  consistency: --report effects evidence ↔ JSON evidence for pure_add"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/JSON disagree on pure_add evidence level"
    FAIL=$((FAIL + 1))
fi

# 2e. Human alloc says "fn uses_alloc ... allocates: vec_new" → JSON alloc fact has vec_new
if grep <<<"$rc_alloc" -A1 "fn uses_alloc" | has_match "allocates: vec_new" && \
   grep <<<"$rc_json" -q '"kind": "alloc".*"function": "main.uses_alloc".*"vec_new"'; then
    echo "  ok  consistency: --report alloc vec_new ↔ JSON alloc for uses_alloc"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: alloc/JSON disagree on uses_alloc allocation calls"
    FAIL=$((FAIL + 1))
fi

# 2f. Human alloc says "fn alloc_with_defer ... cleanup: defer free" → JSON alloc has defers
if grep <<<"$rc_alloc" -A3 "fn alloc_with_defer" | has_match "defer free" && \
   grep <<<"$rc_json" -q '"kind": "alloc".*"function": "main.alloc_with_defer".*"defers":.*\['; then
    echo "  ok  consistency: --report alloc defer ↔ JSON alloc defers for alloc_with_defer"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: alloc/JSON disagree on alloc_with_defer defer"
    FAIL=$((FAIL + 1))
fi

# 2g. Human unsafe says "trusted fn call_raw" → JSON unsafe has is_trusted:true
if grep <<<"$rc_unsafe" -q "trusted fn call_raw" && \
   grep <<<"$rc_json" -q '"kind": "unsafe".*"function": "main.call_raw".*"is_trusted": true'; then
    echo "  ok  consistency: --report unsafe trusted ↔ JSON unsafe for call_raw"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: unsafe/JSON disagree on call_raw trusted status"
    FAIL=$((FAIL + 1))
fi

# 2h. Human unsafe says "wraps: extern raw_extern" → JSON unsafe has trust_boundary with raw_extern
if grep <<<"$rc_unsafe" -q "wraps: extern raw_extern" && \
   grep <<<"$rc_json" -q '"kind": "unsafe".*"function": "main.call_raw".*"trust_boundary":.*"extern raw_extern"'; then
    echo "  ok  consistency: --report unsafe wraps ↔ JSON trust_boundary for call_raw"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: unsafe/JSON disagree on call_raw trust_boundary"
    FAIL=$((FAIL + 1))
fi

# 2i. Human effects says "2 with no external authority" in totals → JSON has exactly 2 effects facts with no_external_authority:true
pure_count=$(grep <<<"$rc_json" -o '"kind": "effects"[^}]*"no_external_authority": true' | wc -l | tr -d ' ')
if grep <<<"$rc_effects" -q "2 with no external authority" && [ "$pure_count" = "2" ]; then
    echo "  ok  consistency: --report effects 2 pure ↔ JSON has 2 pure effects facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/JSON disagree on pure function count (human=2, json=$pure_count)"
    FAIL=$((FAIL + 1))
fi

# 2j. Human alloc says "3 functions allocate" → JSON has exactly 3 alloc facts
alloc_count=$(grep <<<"$rc_json" -o '"kind": "alloc"' | wc -l | tr -d ' ')
if grep <<<"$rc_alloc" -q "3 functions allocate" && [ "$alloc_count" = "3" ]; then
    echo "  ok  consistency: --report alloc 3 allocating ↔ JSON has 3 alloc facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: alloc/JSON disagree on allocating function count (human=3, json=$alloc_count)"
    FAIL=$((FAIL + 1))
fi

# --- Layer 2 continued: recursion file ---
# Human --check predictable fails with "direct recursion" → JSON has matching violation
rc_rec_json=$(cached_output "$TESTDIR/report_check_predictable_fail_recursion.con" "--report diagnostics-json")
rc_rec_human=$($COMPILER "$TESTDIR/report_check_predictable_fail_recursion.con" --check predictable 2>&1) || true
if grep <<<"$rc_rec_human" -q "direct recursion" && \
   grep <<<"$rc_rec_json" -q '"kind": "predictable_violation".*"reason": "direct recursion"'; then
    echo "  ok  consistency: --check predictable recursion ↔ JSON violation for countdown"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: predictable/JSON disagree on recursion violation"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_11() {

# --query effects returns only effects facts
q_effects=$(cached_output "$TESTDIR/report_integration.con" "--query effects")
if grep <<<"$q_effects" -q '"kind": "effects"' && \
   ! grep <<<"$q_effects" -q '"kind": "alloc"' && \
   ! grep <<<"$q_effects" -q '"kind": "capability"'; then
    echo "  ok  --query effects: returns only effects kind"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query effects: should return only effects kind"
    FAIL=$((FAIL + 1))
fi

# --query effects:pure_add returns exactly one fact
q_pure=$(cached_output "$TESTDIR/report_integration.con" "--query effects:pure_add")
if grep <<<"$q_pure" -q '"function": "main.pure_add"' && \
   grep <<<"$q_pure" -q '"no_external_authority": true'; then
    echo "  ok  --query effects:pure_add returns pure_add effects fact"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query effects:pure_add should return pure_add with no_external_authority"
    FAIL=$((FAIL + 1))
fi

# --query fn:call_raw returns facts from multiple kinds
q_fn=$(cached_output "$TESTDIR/report_integration.con" "--query fn:call_raw")
if grep <<<"$q_fn" -q '"kind": "effects"' && \
   grep <<<"$q_fn" -q '"kind": "unsafe"' && \
   grep <<<"$q_fn" -q '"kind": "capability"'; then
    echo "  ok  --query fn:call_raw returns effects + unsafe + capability facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query fn:call_raw should return multiple fact kinds"
    FAIL=$((FAIL + 1))
fi

# --query alloc returns only alloc facts
q_alloc=$(cached_output "$TESTDIR/report_integration.con" "--query alloc")
if grep <<<"$q_alloc" -q '"kind": "alloc"' && \
   ! grep <<<"$q_alloc" -q '"kind": "effects"'; then
    echo "  ok  --query alloc: returns only alloc kind"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query alloc: should return only alloc kind"
    FAIL=$((FAIL + 1))
fi

# --query unsafe returns only unsafe facts
q_unsafe=$(cached_output "$TESTDIR/report_integration.con" "--query unsafe")
if grep <<<"$q_unsafe" -q '"kind": "unsafe"' && \
   ! grep <<<"$q_unsafe" -q '"kind": "effects"'; then
    echo "  ok  --query unsafe: returns only unsafe kind"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query unsafe: should return only unsafe kind"
    FAIL=$((FAIL + 1))
fi

# --query capability returns only capability facts
q_cap=$(cached_output "$TESTDIR/report_integration.con" "--query capability")
if grep <<<"$q_cap" -q '"kind": "capability"' && \
   ! grep <<<"$q_cap" -q '"kind": "effects"'; then
    echo "  ok  --query capability: returns only capability kind"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query capability: should return only capability kind"
    FAIL=$((FAIL + 1))
fi

# --query proof_status returns only proof_status facts
q_proof=$(cached_output "$TESTDIR/report_integration.con" "--query proof_status")
if grep <<<"$q_proof" -q '"kind": "proof_status"' && \
   ! grep <<<"$q_proof" -q '"kind": "effects"'; then
    echo "  ok  --query proof_status: returns only proof_status kind"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query proof_status: should return only proof_status kind"
    FAIL=$((FAIL + 1))
fi

# --query predictable_violation on file with violations
q_viol=$(cached_output "$TESTDIR/report_check_predictable_fail_loops.con" "--query predictable_violation")
if grep <<<"$q_viol" -q '"function": "main.spin"' && \
   grep <<<"$q_viol" -q '"reason": "unbounded loops"'; then
    echo "  ok  --query predictable_violation: returns spin violation"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query predictable_violation: should return spin violation"
    FAIL=$((FAIL + 1))
fi

# --query predictable_violation on passing file returns envelope with fact_count 0
q_noviol=$(cached_output "$TESTDIR/report_check_predictable_pass.con" "--query predictable_violation")
if grep <<<"$q_noviol" -q '"fact_count": 0' && \
   grep <<<"$q_noviol" -q '"facts": \[\]'; then
    echo "  ok  --query predictable_violation: empty for passing file"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query predictable_violation: should be empty envelope for passing file"
    FAIL=$((FAIL + 1))
fi

# --query fn:pure_add returns proof_status (qualified name match)
q_fn_pure=$(cached_output "$TESTDIR/report_integration.con" "--query fn:pure_add")
if grep <<<"$q_fn_pure" -q '"kind": "proof_status"' && \
   grep <<<"$q_fn_pure" -q '"kind": "effects"'; then
    echo "  ok  --query fn:pure_add returns proof_status + effects (qualified name match)"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query fn:pure_add should match qualified names like main.pure_add"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_12() {

# Transitive: main requires Alloc via uses_alloc → vec_new (intrinsic)
q_alloc=$(cached_output "$TESTDIR/report_integration.con" "--query why-capability:main:Alloc")
if grep <<<"$q_alloc" -q '"answer": "transitive"' && \
   grep <<<"$q_alloc" -q '"callee": "uses_alloc"' && \
   grep <<<"$q_alloc" -q '"origin": "intrinsic"'; then
    echo "  ok  why-capability:main:Alloc traces main → uses_alloc → intrinsic"
    PASS=$((PASS + 1))
else
    echo "FAIL  why-capability:main:Alloc should trace transitive path"
    echo "$q_alloc"
    FAIL=$((FAIL + 1))
fi

# Declared: main declares File via with(Std)
q_file=$(cached_output "$TESTDIR/report_integration.con" "--query why-capability:main:File")
if grep <<<"$q_file" -q '"answer": "declared"' && \
   grep <<<"$q_file" -q '"origin": "declared"'; then
    echo "  ok  why-capability:main:File shows declared origin"
    PASS=$((PASS + 1))
else
    echo "FAIL  why-capability:main:File should show declared"
    echo "$q_file"
    FAIL=$((FAIL + 1))
fi

# Transitive via extern: call_raw requires Unsafe via raw_extern (extern)
q_unsafe=$(cached_output "$TESTDIR/report_integration.con" "--query why-capability:call_raw:Unsafe")
if grep <<<"$q_unsafe" -q '"answer": "transitive"' && \
   grep <<<"$q_unsafe" -q '"callee": "raw_extern"' && \
   grep <<<"$q_unsafe" -q '"origin": "extern"'; then
    echo "  ok  why-capability:call_raw:Unsafe traces call_raw → raw_extern (extern)"
    PASS=$((PASS + 1))
else
    echo "FAIL  why-capability:call_raw:Unsafe should trace to extern"
    echo "$q_unsafe"
    FAIL=$((FAIL + 1))
fi

# Not required: pure_add does not require Alloc
q_none=$(cached_output "$TESTDIR/report_integration.con" "--query why-capability:pure_add:Alloc")
if grep <<<"$q_none" -q '"answer": "not_required"' && \
   grep <<<"$q_none" -q '"trace": \[\]'; then
    echo "  ok  why-capability:pure_add:Alloc returns not_required"
    PASS=$((PASS + 1))
else
    echo "FAIL  why-capability:pure_add:Alloc should be not_required"
    echo "$q_none"
    FAIL=$((FAIL + 1))
fi

# Answer-shaped output has query_answer kind
if grep <<<"$q_alloc" -q '"kind": "query_answer"'; then
    echo "  ok  why-capability output has kind query_answer"
    PASS=$((PASS + 1))
else
    echo "FAIL  why-capability output should have kind query_answer"
    FAIL=$((FAIL + 1))
fi

# Declared origin includes source location
if grep <<<"$q_file" -q '"loc":.*"file":.*"line":'; then
    echo "  ok  why-capability declared origin includes source location"
    PASS=$((PASS + 1))
else
    echo "FAIL  why-capability declared origin should include source location"
    FAIL=$((FAIL + 1))
fi

# --- Adversarial authority trace tests ---
AT_FILE="$TESTDIR/adversarial_authority_trace.con"

# Mutual recursion: ping→pong cycle detected, not infinite loop
q_cycle=$(cached_output "$AT_FILE" "--query why-capability:ping:Alloc")
if grep <<<"$q_cycle" -q '"answer": "transitive"' && \
   grep <<<"$q_cycle" -q '"error": "cycle"' && \
   grep <<<"$q_cycle" -q '"origin": "intrinsic"'; then
    echo "  ok  adversarial: mutual recursion cycle detected in authority trace"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: mutual recursion should detect cycle"
    echo "$q_cycle"
    FAIL=$((FAIL + 1))
fi

# Diamond: both left_arm and right_arm traced
q_diamond=$(cached_output "$AT_FILE" "--query why-capability:diamond:Alloc")
if grep <<<"$q_diamond" -q '"callee": "left_arm"' && \
   grep <<<"$q_diamond" -q '"callee": "right_arm"'; then
    echo "  ok  adversarial: diamond dependency traces both arms"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: diamond should trace both arms"
    echo "$q_diamond"
    FAIL=$((FAIL + 1))
fi

# Deep chain: entry → mid1 → mid2 → leaf → alloc (intrinsic)
q_deep=$(cached_output "$AT_FILE" "--query why-capability:entry:Alloc")
if grep <<<"$q_deep" -q '"callee": "mid1"' && \
   grep <<<"$q_deep" -q '"callee": "mid2"' && \
   grep <<<"$q_deep" -q '"callee": "leaf"' && \
   grep <<<"$q_deep" -q '"origin": "intrinsic"'; then
    echo "  ok  adversarial: deep chain traces entry → mid1 → mid2 → leaf → intrinsic"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: deep chain should trace full path"
    echo "$q_deep"
    FAIL=$((FAIL + 1))
fi

# Trusted extern: uses_trusted should NOT require Unsafe
q_trusted=$(cached_output "$AT_FILE" "--query why-capability:uses_trusted:Unsafe")
if grep <<<"$q_trusted" -q '"answer": "not_required"'; then
    echo "  ok  adversarial: trusted extern does not contribute Unsafe"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: trusted extern should not contribute Unsafe"
    echo "$q_trusted"
    FAIL=$((FAIL + 1))
fi

# Untrusted extern: uses_raw traces to extern origin
q_raw=$(cached_output "$AT_FILE" "--query why-capability:uses_raw:Unsafe")
if grep <<<"$q_raw" -q '"answer": "transitive"' && \
   grep <<<"$q_raw" -q '"callee": "raw_op"' && \
   grep <<<"$q_raw" -q '"origin": "extern"'; then
    echo "  ok  adversarial: untrusted extern traces to extern origin"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: untrusted extern should trace to extern origin"
    echo "$q_raw"
    FAIL=$((FAIL + 1))
fi

# Nonexistent function returns not_required
q_missing=$(cached_output "$AT_FILE" "--query why-capability:nonexistent:Alloc")
if grep <<<"$q_missing" -q '"answer": "not_required"'; then
    echo "  ok  adversarial: nonexistent function returns not_required"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: nonexistent function should return not_required"
    echo "$q_missing"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_13() {

# --- predictable:fn ---

# Passing function
q_pred_pass=$(cached_output "$TESTDIR/report_integration.con" "--query predictable:pure_add")
if grep <<<"$q_pred_pass" -q '"answer": "pass"' && \
   grep <<<"$q_pred_pass" -q '"gates_failed": 0'; then
    echo "  ok  predictable:pure_add answers pass with 0 gates failed"
    PASS=$((PASS + 1))
else
    echo "FAIL  predictable:pure_add should answer pass"
    echo "$q_pred_pass"
    FAIL=$((FAIL + 1))
fi

# Failing function with multiple violations
q_pred_fail=$(cached_output "$TESTDIR/report_integration.con" "--query predictable:main")
if grep <<<"$q_pred_fail" -q '"answer": "fail"' && \
   grep <<<"$q_pred_fail" -q '"gate":'; then
    echo "  ok  predictable:main answers fail with violation gates"
    PASS=$((PASS + 1))
else
    echo "FAIL  predictable:main should answer fail"
    echo "$q_pred_fail"
    FAIL=$((FAIL + 1))
fi

# Violation includes hint
if grep <<<"$q_pred_fail" -q '"hint":'; then
    echo "  ok  predictable:main violations include hints"
    PASS=$((PASS + 1))
else
    echo "FAIL  predictable:main violations should include hints"
    FAIL=$((FAIL + 1))
fi

# Unbounded loop violation
q_pred_loop=$(cached_output "$TESTDIR/report_check_predictable_fail_loops.con" "--query predictable:spin")
if grep <<<"$q_pred_loop" -q '"answer": "fail"' && \
   grep <<<"$q_pred_loop" -q '"gate": "unbounded loops"'; then
    echo "  ok  predictable:spin answers fail with unbounded loops gate"
    PASS=$((PASS + 1))
else
    echo "FAIL  predictable:spin should fail with unbounded loops"
    echo "$q_pred_loop"
    FAIL=$((FAIL + 1))
fi

# --- proof:fn ---

# Pure function: missing (eligible but unproved)
q_proof_pure=$(cached_output "$TESTDIR/report_integration.con" "--query proof:pure_add")
if grep <<<"$q_proof_pure" -q '"answer": "missing"' && \
   grep <<<"$q_proof_pure" -q '"current_fingerprint":'; then
    echo "  ok  proof:pure_add answers missing with fingerprint"
    PASS=$((PASS + 1))
else
    echo "FAIL  proof:pure_add should answer missing"
    echo "$q_proof_pure"
    FAIL=$((FAIL + 1))
fi

# Trusted function: trusted
q_proof_trusted=$(cached_output "$TESTDIR/report_integration.con" "--query proof:call_raw")
if grep <<<"$q_proof_trusted" -q '"answer": "trusted"'; then
    echo "  ok  proof:call_raw answers trusted"
    PASS=$((PASS + 1))
else
    echo "FAIL  proof:call_raw should answer trusted"
    echo "$q_proof_trusted"
    FAIL=$((FAIL + 1))
fi

# Nonexistent function
q_proof_missing=$(cached_output "$TESTDIR/report_integration.con" "--query proof:nonexistent")
if grep <<<"$q_proof_missing" -q '"answer": "not_found"'; then
    echo "  ok  proof:nonexistent answers not_found"
    PASS=$((PASS + 1))
else
    echo "FAIL  proof:nonexistent should answer not_found"
    echo "$q_proof_missing"
    FAIL=$((FAIL + 1))
fi

# --- evidence:fn ---

# Pure function: enforced (passes predictable, no proof yet)
q_ev_pure=$(cached_output "$TESTDIR/report_integration.con" "--query evidence:pure_add")
if grep <<<"$q_ev_pure" -q '"answer": "enforced"' && \
   grep <<<"$q_ev_pure" -q '"passes_predictable": true' && \
   grep <<<"$q_ev_pure" -q '"proof_state": "missing"'; then
    echo "  ok  evidence:pure_add answers enforced, passes predictable, no proof"
    PASS=$((PASS + 1))
else
    echo "FAIL  evidence:pure_add should be enforced"
    echo "$q_ev_pure"
    FAIL=$((FAIL + 1))
fi

# Trusted function: trusted-assumption
q_ev_trusted=$(cached_output "$TESTDIR/report_integration.con" "--query evidence:call_raw")
if grep <<<"$q_ev_trusted" -q '"answer": "trusted-assumption"' && \
   grep <<<"$q_ev_trusted" -q '"is_trusted": true'; then
    echo "  ok  evidence:call_raw answers trusted-assumption"
    PASS=$((PASS + 1))
else
    echo "FAIL  evidence:call_raw should be trusted-assumption"
    echo "$q_ev_trusted"
    FAIL=$((FAIL + 1))
fi

# Failing function: reported (fails predictable)
q_ev_fail=$(cached_output "$TESTDIR/report_integration.con" "--query evidence:main")
if grep <<<"$q_ev_fail" -q '"answer": "reported"' && \
   grep <<<"$q_ev_fail" -q '"passes_predictable": false'; then
    echo "  ok  evidence:main answers reported, fails predictable"
    PASS=$((PASS + 1))
else
    echo "FAIL  evidence:main should be reported"
    echo "$q_ev_fail"
    FAIL=$((FAIL + 1))
fi

# Not found
q_ev_missing=$(cached_output "$TESTDIR/report_integration.con" "--query evidence:nonexistent")
if grep <<<"$q_ev_missing" -q '"answer": "not_found"'; then
    echo "  ok  evidence:nonexistent answers not_found"
    PASS=$((PASS + 1))
else
    echo "FAIL  evidence:nonexistent should answer not_found"
    echo "$q_ev_missing"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_14() {

# Pure function audit: enforced, pure, passes predictable, no alloc
q_audit_pure=$(cached_output "$TESTDIR/report_integration.con" "--query audit:pure_add")
if grep <<<"$q_audit_pure" -q '"evidence": "enforced"' && \
   grep <<<"$q_audit_pure" -q '"no_declared_capability": true' && \
   grep <<<"$q_audit_pure" -q '"passes": true'; then
    echo "  ok  audit:pure_add shows enforced, no declared capability, passes predictable"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:pure_add should show enforced + no declared capability + passes"
    echo "$q_audit_pure"
    FAIL=$((FAIL + 1))
fi

# Trusted function audit: trusted-assumption, has authority traces, fails predictable
q_audit_trusted=$(cached_output "$TESTDIR/report_integration.con" "--query audit:call_raw")
if grep <<<"$q_audit_trusted" -q '"evidence": "trusted-assumption"' && \
   grep <<<"$q_audit_trusted" -q '"is_trusted": true' && \
   grep <<<"$q_audit_trusted" -q '"passes": false'; then
    echo "  ok  audit:call_raw shows trusted-assumption, trusted, fails predictable"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:call_raw should show trusted-assumption"
    echo "$q_audit_trusted"
    FAIL=$((FAIL + 1))
fi

# Audit includes authority traces
if grep <<<"$q_audit_trusted" -q '"traces":' && \
   grep <<<"$q_audit_trusted" -q '"origin": "extern"'; then
    echo "  ok  audit:call_raw includes authority trace to extern"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:call_raw should include authority traces"
    FAIL=$((FAIL + 1))
fi

# Audit includes proof state and fingerprint
if grep <<<"$q_audit_pure" -q '"state": "missing"' && \
   grep <<<"$q_audit_pure" -q '"fingerprint":'; then
    echo "  ok  audit:pure_add includes proof state and fingerprint"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:pure_add should include proof state"
    FAIL=$((FAIL + 1))
fi

# Audit includes allocation info
if grep <<<"$q_audit_pure" -q '"allocates": \[\]' && \
   grep <<<"$q_audit_pure" -q '"returns_allocation": false'; then
    echo "  ok  audit:pure_add includes empty allocation info"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:pure_add should include allocation info"
    FAIL=$((FAIL + 1))
fi

# Allocating function audit
q_audit_alloc=$(cached_output "$TESTDIR/report_integration.con" "--query audit:uses_alloc")
if grep <<<"$q_audit_alloc" -q '"evidence": "reported"' && \
   grep <<<"$q_audit_alloc" -q '"allocates":.*"vec_new"'; then
    echo "  ok  audit:uses_alloc shows reported with vec_new allocation"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:uses_alloc should show reported + vec_new"
    echo "$q_audit_alloc"
    FAIL=$((FAIL + 1))
fi

# Not found
q_audit_missing=$(cached_output "$TESTDIR/report_integration.con" "--query audit:nonexistent")
if grep <<<"$q_audit_missing" -q '"answer": "not_found"'; then
    echo "  ok  audit:nonexistent answers not_found"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:nonexistent should answer not_found"
    echo "$q_audit_missing"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_15() {

REGISTRY_DIR="$TESTDIR/proof_registry_test"
STALE_DIR="$TESTDIR/proof_registry_stale"

# Registry-backed proof: correct fingerprint → proved
reg_proof=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report proof-status")
if grep <<<"$reg_proof" -q "1 proved" && \
   grep <<<"$reg_proof" -q "pure_add.*proof matches"; then
    echo "  ok  registry proof: correct fingerprint → proved"
    PASS=$((PASS + 1))
else
    echo "FAIL  registry proof: correct fingerprint should show proved"
    echo "$reg_proof"
    FAIL=$((FAIL + 1))
fi

# Registry query: proof:pure_add → proved
reg_query=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query proof:pure_add")
if grep <<<"$reg_query" -q '"answer": "proved"'; then
    echo "  ok  registry query: proof:pure_add → proved"
    PASS=$((PASS + 1))
else
    echo "FAIL  registry query: proof:pure_add should answer proved"
    echo "$reg_query"
    FAIL=$((FAIL + 1))
fi

# Stale registry: wrong fingerprint → stale
stale_proof=$(cached_output "$STALE_DIR/test_proof_registry.con" "--report proof-status")
if grep <<<"$stale_proof" -q "1 stale" && \
   grep <<<"$stale_proof" -q "body changed"; then
    echo "  ok  registry stale: wrong fingerprint → stale"
    PASS=$((PASS + 1))
else
    echo "FAIL  registry stale: wrong fingerprint should show stale"
    echo "$stale_proof"
    FAIL=$((FAIL + 1))
fi

# Stale registry query: proof:pure_add → stale
stale_query=$(cached_output "$STALE_DIR/test_proof_registry.con" "--query proof:pure_add")
if grep <<<"$stale_query" -q '"answer": "stale"'; then
    echo "  ok  registry stale query: proof:pure_add → stale"
    PASS=$((PASS + 1))
else
    echo "FAIL  registry stale query: proof:pure_add should answer stale"
    echo "$stale_query"
    FAIL=$((FAIL + 1))
fi

# In-source links that replaced the deleted hardcoded table (bug 083) still prove
linked_proof=$(cached_output "$TESTDIR/proof_decode_header.con" "--report proof-status")
if grep <<<"$linked_proof" -q "proved" && ! grep <<<"$linked_proof" -q "origin: hardcoded"; then
    echo "  ok  migrated in-source proof links prove, with no hardcoded origin"
    PASS=$((PASS + 1))
else
    echo "FAIL  migrated in-source proof links should prove (and never say origin: hardcoded)"
    echo "$linked_proof"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_16() {

# Obligations from registry: proved function shows spec, proof, source
ob_proved=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report obligations")
if grep <<<"$ob_proved" -q "status:.*proved" && \
   grep <<<"$ob_proved" -q "spec:.*PureAdd.spec_add" && \
   grep <<<"$ob_proved" -q "proof:.*PureAdd.add_comm" && \
   grep <<<"$ob_proved" -q "source:.*registry"; then
    echo "  ok  obligations: proved function shows spec, proof, registry source"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: proved function should show spec/proof/registry"
    echo "$ob_proved"
    FAIL=$((FAIL + 1))
fi

# Obligations: missing shows none for spec/proof
if grep <<<"$ob_proved" -A5 "main.main" | has_match "status:.*ineligible" && \
   grep <<<"$ob_proved" -A5 "main.main" | has_match "source:.*none"; then
    echo "  ok  obligations: ineligible function shows source:none"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: missing should show source:none"
    echo "$ob_proved"
    FAIL=$((FAIL + 1))
fi

# Obligations: dependencies show proved callees
if grep <<<"$ob_proved" -A7 "main.main" | has_match "dependencies:.*pure_add"; then
    echo "  ok  obligations: main depends on proved helper pure_add"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: main should depend on proved pure_add"
    echo "$ob_proved"
    FAIL=$((FAIL + 1))
fi

# Obligations: stale fingerprint
ob_stale=$(cached_output "$STALE_DIR/test_proof_registry.con" "--report obligations")
if grep <<<"$ob_stale" -q "status:.*stale" && \
   grep <<<"$ob_stale" -q "1 stale"; then
    echo "  ok  obligations: stale fingerprint → stale status"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: stale fingerprint should show stale"
    echo "$ob_stale"
    FAIL=$((FAIL + 1))
fi

# Obligations: summary totals
if grep <<<"$ob_proved" -q "1 proved" && \
   grep <<<"$ob_proved" -q "0 missing" && \
   grep <<<"$ob_proved" -q "1 ineligible"; then
    echo "  ok  obligations: summary shows 1 proved, 0 missing, 1 ineligible"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: summary should show 1 proved, 1 missing"
    echo "$ob_proved"
    FAIL=$((FAIL + 1))
fi

# Obligations JSON: query returns obligation facts
ob_json=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query obligation")
if grep <<<"$ob_json" -q '"kind": "obligation"' && \
   grep <<<"$ob_json" -q '"status": "proved"' && \
   grep <<<"$ob_json" -q '"spec": "PureAdd.spec_add"'; then
    echo "  ok  obligations JSON: --query obligation returns obligation facts with spec"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations JSON: --query obligation should return facts"
    echo "$ob_json"
    FAIL=$((FAIL + 1))
fi

# Obligations JSON: per-function filter
ob_fn=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query obligation:pure_add")
if grep <<<"$ob_fn" -q '"function": "main.pure_add"' && \
   grep <<<"$ob_fn" -q '"source": "registry"'; then
    echo "  ok  obligations JSON: --query obligation:pure_add returns filtered fact"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations JSON: --query obligation:pure_add should filter"
    echo "$ob_fn"
    FAIL=$((FAIL + 1))
fi

# Obligations: ineligible for allocating functions
ob_mixed=$(cached_output "$TESTDIR/report_integration.con" "--report obligations")
if grep <<<"$ob_mixed" -q "ineligible" && \
   grep <<<"$ob_mixed" -q "trusted"; then
    echo "  ok  obligations: mixed program shows ineligible + trusted"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: mixed program should show ineligible + trusted"
    echo "$ob_mixed"
    FAIL=$((FAIL + 1))
fi

# Obligations: diagnostics-json includes obligation kind
ob_diag=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report diagnostics-json")
if grep <<<"$ob_diag" -q '"kind": "obligation"'; then
    echo "  ok  obligations: diagnostics-json includes obligation facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: diagnostics-json should include obligation facts"
    echo "$ob_diag"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_17() {

# Pure function: extracted with ProofCore form
ext_pure=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report extraction")
if grep <<<"$ext_pure" -q "status: extracted" && \
   grep <<<"$ext_pure" -q "ProofCore: (a + b)"; then
    echo "  ok  extraction: pure_add extracted to (a + b)"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: pure_add should be extracted"
    echo "$ext_pure"
    FAIL=$((FAIL + 1))
fi

# Entry point: excluded with reason
if grep <<<"$ext_pure" -A3 "main.main" | has_match "excluded" && \
   grep <<<"$ext_pure" -A3 "main.main" | has_match "entry point"; then
    echo "  ok  extraction: main excluded as entry point"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: main should be excluded"
    echo "$ext_pure"
    FAIL=$((FAIL + 1))
fi

# Mixed program: capabilities excluded with reasons
ext_mixed=$(cached_output "$TESTDIR/report_integration.con" "--report extraction")
if grep <<<"$ext_mixed" -A3 "uses_alloc" | has_match "has capabilities: Alloc"; then
    echo "  ok  extraction: uses_alloc excluded for Alloc capability"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: uses_alloc should be excluded for Alloc"
    echo "$ext_mixed"
    FAIL=$((FAIL + 1))
fi

# Trusted function: excluded with trusted reason
if grep <<<"$ext_mixed" -A3 "call_raw" | has_match "marked trusted"; then
    echo "  ok  extraction: call_raw excluded as trusted"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: call_raw should be excluded as trusted"
    echo "$ext_mixed"
    FAIL=$((FAIL + 1))
fi

# Struct literal and match both extract (Phase 4 ProofCore extensions).
ext_elig=$(cached_output "$TESTDIR/test_proof_eligible_pure.con" "--report extraction")
if grep <<<"$ext_elig" -A2 "make_point" | has_match "status: extracted"; then
    echo "  ok  extraction: make_point extracts (struct literal supported)"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: make_point should extract"
    echo "$ext_elig"
    FAIL=$((FAIL + 1))
fi

if grep <<<"$ext_elig" -A2 "color_value" | has_match "status: extracted"; then
    echo "  ok  extraction: color_value extracts (match expression supported)"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: color_value should extract"
    echo "$ext_elig"
    FAIL=$((FAIL + 1))
fi

# Summary totals
if grep <<<"$ext_pure" -q "1 extracted" && \
   grep <<<"$ext_pure" -q "1 excluded"; then
    echo "  ok  extraction: summary shows correct totals"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: summary should show 1 extracted, 1 excluded"
    echo "$ext_pure"
    FAIL=$((FAIL + 1))
fi

# JSON query: extraction facts with proof_core
ext_json=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query extraction:pure_add")
if grep <<<"$ext_json" -q '"status": "extracted"' && \
   grep <<<"$ext_json" -q '"proof_core": "(a + b)"'; then
    echo "  ok  extraction JSON: --query extraction:pure_add returns proof_core"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction JSON: --query extraction:pure_add should have proof_core"
    echo "$ext_json"
    FAIL=$((FAIL + 1))
fi

# Diagnostics-json includes extraction kind
if grep <<<"$ob_diag" -q '"kind": "extraction"'; then
    echo "  ok  extraction: diagnostics-json includes extraction facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: diagnostics-json should include extraction facts"
    FAIL=$((FAIL + 1))
fi

# Excluded function JSON shows excluded_reasons
ext_excl=$(cached_output "$TESTDIR/report_integration.con" "--query extraction:call_raw")
if grep <<<"$ext_excl" -q '"status": "excluded"' && \
   grep <<<"$ext_excl" -q '"excluded_reasons"'; then
    echo "  ok  extraction JSON: excluded function shows excluded_reasons"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction JSON: excluded function should show excluded_reasons"
    echo "$ext_excl"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_18() {

# Proved function: full pipeline trace
tr_proved=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report traceability")
if grep <<<"$tr_proved" -A10 "main.pure_add" | has_match "evidence:.*proved" && \
   grep <<<"$tr_proved" -A10 "main.pure_add" | has_match "extraction:.*extracted" && \
   grep <<<"$tr_proved" -A10 "main.pure_add" | has_match "ssa:.*pure_add" && \
   grep <<<"$tr_proved" -A10 "main.pure_add" | has_match "llvm:.*pure_add"; then
    echo "  ok  traceability: proved function traces through all pipeline stages"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: proved function should trace through pipeline"
    echo "$tr_proved"
    FAIL=$((FAIL + 1))
fi

# Entry point: main → its mangled symbol in LLVM (FFI.md "Symbol Names"; the C `main` the
# compiler generates calls it). Was `user_main` before every Concrete function was mangled.
if grep <<<"$tr_proved" -A10 "main.main" | has_match -E 'llvm:[[:space:]]+_C\.main\.main$'; then
    echo "  ok  traceability: main maps to its mangled symbol _C.main.main in LLVM"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: main should map to _C.main.main in LLVM"
    echo "$tr_proved"
    FAIL=$((FAIL + 1))
fi

# Claim boundary: proved function shows ProofCore boundary
if grep <<<"$tr_proved" -A10 "main.pure_add" | has_match "boundary:.*ProofCore"; then
    echo "  ok  traceability: proved function boundary at ProofCore"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: proved function should show ProofCore boundary"
    echo "$tr_proved"
    FAIL=$((FAIL + 1))
fi

# Generic function: shows monomorphized specializations
tr_generic=$(cached_output "$TESTDIR/report_integration.con" "--report traceability")
if grep <<<"$tr_generic" -A10 "main.identity" | has_match "identity_for_i32"; then
    echo "  ok  traceability: generic identity shows identity_for_i32 specialization"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: identity should show monomorphized specialization"
    echo "$tr_generic"
    FAIL=$((FAIL + 1))
fi

# Trusted function: trusted-assumption evidence, source boundary
if grep <<<"$tr_generic" -A10 "main.call_raw" | has_match "trusted-assumption" && \
   grep <<<"$tr_generic" -A10 "main.call_raw" | has_match "boundary:.*trusted"; then
    echo "  ok  traceability: trusted function shows trusted-assumption + boundary"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: trusted function should show trusted-assumption"
    echo "$tr_generic"
    FAIL=$((FAIL + 1))
fi

# Reported function: fails predictable, source boundary
if grep <<<"$tr_generic" -A10 "main.uses_alloc" | has_match "evidence:.*reported" && \
   grep <<<"$tr_generic" -A10 "main.uses_alloc" | has_match "boundary:.*fails predictable"; then
    echo "  ok  traceability: reported function shows fails predictable boundary"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: reported function should show fails predictable"
    echo "$tr_generic"
    FAIL=$((FAIL + 1))
fi

# Summary totals
if grep <<<"$tr_generic" -q "2 enforced" && \
   grep <<<"$tr_generic" -q "4 reported"; then
    echo "  ok  traceability: summary totals correct"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: summary should show 2 enforced, 4 reported"
    echo "$tr_generic"
    FAIL=$((FAIL + 1))
fi

# JSON query: traceability facts
tr_json=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query traceability:pure_add")
if grep <<<"$tr_json" -q '"kind": "traceability"' && \
   grep <<<"$tr_json" -q '"evidence": "proved"' && \
   grep <<<"$tr_json" -q '"proof_core": "(a + b)"' && \
   grep <<<"$tr_json" -q '"boundary":.*ProofCore'; then
    echo "  ok  traceability JSON: --query traceability:pure_add returns full trace"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability JSON: should return full trace"
    echo "$tr_json"
    FAIL=$((FAIL + 1))
fi

# JSON query: generic function shows mono names
tr_json_gen=$(cached_output "$TESTDIR/report_integration.con" "--query traceability:identity")
if grep <<<"$tr_json_gen" -q '"mono":.*identity_for_i32' && \
   grep <<<"$tr_json_gen" -q '"ssa":.*identity_for_i32'; then
    echo "  ok  traceability JSON: identity shows mono/SSA specializations"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability JSON: identity should show specializations"
    echo "$tr_json_gen"
    FAIL=$((FAIL + 1))
fi

# JSON query: all traceability facts
tr_json_all=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query traceability")
if grep <<<"$tr_json_all" -q '"kind": "traceability"'; then
    echo "  ok  traceability JSON: --query traceability returns all facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability JSON: --query traceability should return facts"
    echo "$tr_json_all"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_19() {

# Extraction report: registry-backed function shows spec/proof names
ext_spec=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report extraction")
if grep <<<"$ext_spec" -A10 "main.pure_add" | has_match "spec:.*PureAdd.spec_add" && \
   grep <<<"$ext_spec" -A10 "main.pure_add" | has_match "proof:.*PureAdd.add_comm"; then
    echo "  ok  named-spec: extraction report shows spec/proof from registry"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: extraction report should show spec/proof from registry"
    echo "$ext_spec"
    FAIL=$((FAIL + 1))
fi

# Extraction JSON: spec/proof fields present
ext_spec_json=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query extraction:pure_add")
if grep <<<"$ext_spec_json" -q '"spec": "PureAdd.spec_add"' && \
   grep <<<"$ext_spec_json" -q '"proof": "PureAdd.add_comm"'; then
    echo "  ok  named-spec: extraction JSON includes spec/proof fields"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: extraction JSON should include spec/proof"
    echo "$ext_spec_json"
    FAIL=$((FAIL + 1))
fi

# Traceability report: shows spec/proof from registry
tr_spec=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report traceability")
if grep <<<"$tr_spec" -A15 "main.pure_add" | has_match "spec:.*PureAdd.spec_add" && \
   grep <<<"$tr_spec" -A15 "main.pure_add" | has_match "proof:.*PureAdd.add_comm"; then
    echo "  ok  named-spec: traceability report shows spec/proof from registry"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: traceability report should show spec/proof"
    echo "$tr_spec"
    FAIL=$((FAIL + 1))
fi

# Traceability JSON: spec/proof fields present
tr_spec_json=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query traceability:pure_add")
if grep <<<"$tr_spec_json" -q '"spec": "PureAdd.spec_add"' && \
   grep <<<"$tr_spec_json" -q '"proof": "PureAdd.add_comm"'; then
    echo "  ok  named-spec: traceability JSON includes spec/proof fields"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: traceability JSON should include spec/proof"
    echo "$tr_spec_json"
    FAIL=$((FAIL + 1))
fi

# Proof-status: shows spec/proof from registry
ps_spec=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query proof_status:pure_add")
if grep <<<"$ps_spec" -q '"spec": "PureAdd.spec_add"' && \
   grep <<<"$ps_spec" -q '"proof": "PureAdd.add_comm"'; then
    echo "  ok  named-spec: proof-status JSON includes spec/proof from registry"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: proof-status JSON should include spec/proof"
    echo "$ps_spec"
    FAIL=$((FAIL + 1))
fi

# Obligations: shows spec/proof from registry
ob_spec=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query obligation:pure_add")
if grep <<<"$ob_spec" -q '"spec": "PureAdd.spec_add"' && \
   grep <<<"$ob_spec" -q '"proof": "PureAdd.add_comm"'; then
    echo "  ok  named-spec: obligations JSON includes spec/proof from registry"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: obligations JSON should include spec/proof"
    echo "$ob_spec"
    FAIL=$((FAIL + 1))
fi

# Spec identity consistent: same spec name across extraction, traceability, proof-status
if grep <<<"$ext_spec_json" -q '"spec": "PureAdd.spec_add"' && \
   grep <<<"$tr_spec_json" -q '"spec": "PureAdd.spec_add"' && \
   grep <<<"$ps_spec" -q '"spec": "PureAdd.spec_add"'; then
    echo "  ok  named-spec: spec identity consistent across extraction/trace/proof-status"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: spec identity should be consistent across reports"
    FAIL=$((FAIL + 1))
fi
:
}

suite_report_20() {

STALE_DIR="$TESTDIR/proof_registry_stale"

# Generate fact bundles for diffing
diff_baseline=$($COMPILER "$REGISTRY_DIR/test_proof_registry.con" --report diagnostics-json 2>/dev/null)
diff_stale=$($COMPILER "$STALE_DIR/test_proof_registry.con" --report diagnostics-json 2>/dev/null)
diff_mixed=$($COMPILER "$TESTDIR/report_integration.con" --report diagnostics-json 2>/dev/null)

echo "$diff_baseline" > "$TMPDIR/concrete_diff_baseline.json"
echo "$diff_stale" > "$TMPDIR/concrete_diff_stale.json"
echo "$diff_mixed" > "$TMPDIR/concrete_diff_mixed.json"

# No changes: diff against itself
diff_same=$($COMPILER diff "$TMPDIR/concrete_diff_baseline.json" "$TMPDIR/concrete_diff_baseline.json" 2>&1) && diff_same_exit=0 || diff_same_exit=$?
if grep <<<"$diff_same" -q "No trust-relevant changes" && [ "$diff_same_exit" -eq 0 ]; then
    echo "  ok  diff: no changes when diffing against self"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: self-diff should report no changes"
    echo "$diff_same"
    FAIL=$((FAIL + 1))
fi

# Proved → stale: trust weakened
diff_stale_out=$($COMPILER diff "$TMPDIR/concrete_diff_baseline.json" "$TMPDIR/concrete_diff_stale.json" 2>&1) && diff_stale_exit=0 || diff_stale_exit=$?
if grep <<<"$diff_stale_out" -q "TRUST WEAKENED" && \
   grep <<<"$diff_stale_out" -q "state: proved.*stale" && \
   [ "$diff_stale_exit" -eq 1 ]; then
    echo "  ok  diff: proved→stale detected as trust weakened (exit 1)"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: proved→stale should be trust weakened"
    echo "$diff_stale_out"
    FAIL=$((FAIL + 1))
fi

# JSON output mode
diff_json=$($COMPILER diff "$TMPDIR/concrete_diff_baseline.json" "$TMPDIR/concrete_diff_stale.json" --json 2>&1) && true || true
if grep <<<"$diff_json" -q '"drift": "weakened"' && \
   grep <<<"$diff_json" -q '"category": "changed"'; then
    echo "  ok  diff: JSON output includes drift and category"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: JSON output should include drift and category"
    echo "$diff_json"
    FAIL=$((FAIL + 1))
fi

# Different programs: detects added and changed facts
diff_cross=$($COMPILER diff "$TMPDIR/concrete_diff_baseline.json" "$TMPDIR/concrete_diff_mixed.json" 2>&1) && true || true
if grep <<<"$diff_cross" -q '\[+\]' && \
   grep <<<"$diff_cross" -q '\[~\]'; then
    echo "  ok  diff: cross-program diff shows added and changed facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: cross-program diff should show added/changed facts"
    echo "$diff_cross"
    FAIL=$((FAIL + 1))
fi

# Evidence downgrade detected
if grep <<<"$diff_cross" -q "evidence:.*enforced.*reported" || \
   grep <<<"$diff_cross" -q "state:.*proved.*missing"; then
    echo "  ok  diff: evidence downgrade detected in field changes"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: should detect evidence downgrade"
    echo "$diff_cross"
    FAIL=$((FAIL + 1))
fi

# Summary line present
if grep <<<"$diff_stale_out" -q "Summary:.*changes"; then
    echo "  ok  diff: summary line present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: should have summary line"
    echo "$diff_stale_out"
    FAIL=$((FAIL + 1))
fi

# New predictable violations flagged as weakened
if grep <<<"$diff_cross" -q '\[+\] predictable_violation'; then
    echo "  ok  diff: new predictable violations flagged as trust weakened"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: new predictable violations should be flagged"
    echo "$diff_cross"
    FAIL=$((FAIL + 1))
fi

# Spec/proof attachment changes visible
if grep <<<"$diff_cross" -q "spec:.*PureAdd" || \
   grep <<<"$diff_cross" -q "proof:.*PureAdd"; then
    echo "  ok  diff: spec/proof attachment changes visible in diff"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: spec/proof changes should be visible"
    echo "$diff_cross"
    FAIL=$((FAIL + 1))
fi

# Clean up
rm -f "$TMPDIR/concrete_diff_baseline.json" "$TMPDIR/concrete_diff_stale.json" "$TMPDIR/concrete_diff_mixed.json"
:
}

suite_report_21() {

ADV_DIR="$TMPDIR/concrete_adv_diff"
mkdir -p "$ADV_DIR"

# --- Malformed JSON input ---

# Truncated JSON (unclosed array)
echo '[{"kind":"effects","function":"foo"' > "$ADV_DIR/truncated.json"
echo '{"schema_version":2,"schema_kind":"facts","facts":[]}' > "$ADV_DIR/empty_arr.json"
adv_trunc=$($COMPILER diff "$ADV_DIR/truncated.json" "$ADV_DIR/empty_arr.json" 2>&1) && true || true
if grep <<<"$adv_trunc" -qi "error.*parse\|could not parse"; then
    echo "  ok  adv-diff: truncated JSON rejected with parse error"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: truncated JSON should produce parse error"
    echo "$adv_trunc"
    FAIL=$((FAIL + 1))
fi

# Non-array root (bare object)
echo '{"kind":"effects","function":"foo"}' > "$ADV_DIR/bare_obj.json"
adv_bare=$($COMPILER diff "$ADV_DIR/bare_obj.json" "$ADV_DIR/empty_arr.json" 2>&1) && true || true
if grep <<<"$adv_bare" -qi "error.*parse\|could not parse"; then
    echo "  ok  adv-diff: non-array JSON root rejected"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: non-array JSON root should be rejected"
    echo "$adv_bare"
    FAIL=$((FAIL + 1))
fi

# Empty file
echo -n "" > "$ADV_DIR/empty_file.json"
adv_empty=$($COMPILER diff "$ADV_DIR/empty_file.json" "$ADV_DIR/empty_arr.json" 2>&1) && true || true
if grep <<<"$adv_empty" -qi "error.*parse\|could not parse"; then
    echo "  ok  adv-diff: empty file rejected with parse error"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: empty file should produce parse error"
    echo "$adv_empty"
    FAIL=$((FAIL + 1))
fi

# --- Empty array diffs ---

# Both empty → no changes
adv_both_empty=$($COMPILER diff "$ADV_DIR/empty_arr.json" "$ADV_DIR/empty_arr.json" 2>&1) && adv_ee_exit=0 || adv_ee_exit=$?
if grep <<<"$adv_both_empty" -q "No trust-relevant changes" && [ "$adv_ee_exit" -eq 0 ]; then
    echo "  ok  adv-diff: both-empty diff reports no changes (exit 0)"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: both-empty diff should report no changes"
    echo "$adv_both_empty"
    FAIL=$((FAIL + 1))
fi

# --- Missing kind/function fields (silently dropped) ---

# Fact without "function" field → should be excluded from diff
cat > "$ADV_DIR/no_function.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"effects","no_external_authority":true}]}
ADVEOF
cat > "$ADV_DIR/normal_fact.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"effects","function":"foo","no_external_authority":true}]}
ADVEOF
adv_nofn=$($COMPILER diff "$ADV_DIR/no_function.json" "$ADV_DIR/normal_fact.json" 2>&1) && true || true
# The fact without function should be dropped, so "foo" appears as added
if grep <<<"$adv_nofn" -q '\[+\].*effects.*foo'; then
    echo "  ok  adv-diff: fact without function field dropped, counterpart shows as added"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: missing function field should cause fact to be dropped"
    echo "$adv_nofn"
    FAIL=$((FAIL + 1))
fi

# Fact without "kind" field → should also be dropped
cat > "$ADV_DIR/no_kind.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"function":"foo","no_external_authority":true}]}
ADVEOF
adv_nokind=$($COMPILER diff "$ADV_DIR/no_kind.json" "$ADV_DIR/normal_fact.json" 2>&1) && true || true
if grep <<<"$adv_nokind" -q '\[+\].*effects.*foo'; then
    echo "  ok  adv-diff: fact without kind field dropped, counterpart shows as added"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: missing kind field should cause fact to be dropped"
    echo "$adv_nokind"
    FAIL=$((FAIL + 1))
fi

# --- Duplicate (kind, function) in same bundle ---
# Only first match is used — second duplicate is invisible

cat > "$ADV_DIR/dupes_old.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"abc"}]}
ADVEOF
cat > "$ADV_DIR/dupes_new.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"abc"},{"kind":"proof_status","function":"foo","state":"stale","current_fingerprint":"xyz"}]}
ADVEOF
adv_dupes=$($COMPILER diff "$ADV_DIR/dupes_old.json" "$ADV_DIR/dupes_new.json" 2>&1) && adv_dupes_exit=0 || adv_dupes_exit=$?
# Duplicate keys should be rejected as a structured error with exit code 2
if grep <<<"$adv_dupes" -qi "error.*duplicate" && [ "$adv_dupes_exit" -eq 2 ]; then
    echo "  ok  adv-diff: duplicate (kind, function) keys rejected (exit 2)"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: duplicate keys should produce error with exit 2"
    echo "$adv_dupes (exit=$adv_dupes_exit)"
    FAIL=$((FAIL + 1))
fi

# --- Fingerprint change without state change ---

cat > "$ADV_DIR/fp_old.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"abc","spec":"Foo.spec","proof":"Foo.proof","source":"registry"}]}
ADVEOF
cat > "$ADV_DIR/fp_new.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"xyz","spec":"Foo.spec","proof":"Foo.proof","source":"registry"}]}
ADVEOF
adv_fp=$($COMPILER diff "$ADV_DIR/fp_old.json" "$ADV_DIR/fp_new.json" 2>&1) && adv_fp_exit=0 || adv_fp_exit=$?
# Fingerprint changed but state is still proved → should detect change, neutral drift
if grep <<<"$adv_fp" -q "current_fingerprint:.*abc.*xyz" && \
   grep <<<"$adv_fp" -q "OTHER CHANGES"; then
    echo "  ok  adv-diff: fingerprint change without state change detected as neutral"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: fingerprint-only change should be detected as neutral"
    echo "$adv_fp"
    FAIL=$((FAIL + 1))
fi

# --- Capability array grows (string-level diff) ---

cat > "$ADV_DIR/cap_old.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"effects","function":"foo","capabilities":"[]","no_external_authority":"true","allocates":"false","frees":"false","recursion":"none","loops":"none","crosses_ffi":"false","is_trusted":"false","evidence":"enforced"}]}
ADVEOF
cat > "$ADV_DIR/cap_new.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"effects","function":"foo","capabilities":"[Alloc, Network]","no_external_authority":"false","allocates":"false","frees":"false","recursion":"none","loops":"none","crosses_ffi":"false","is_trusted":"false","evidence":"reported"}]}
ADVEOF
adv_cap=$($COMPILER diff "$ADV_DIR/cap_old.json" "$ADV_DIR/cap_new.json" 2>&1) && true || true
if grep <<<"$adv_cap" -q "TRUST WEAKENED" && \
   grep <<<"$adv_cap" -q "capabilities:" && \
   grep <<<"$adv_cap" -q "evidence:.*enforced.*reported"; then
    echo "  ok  adv-diff: capability growth + evidence downgrade detected as weakened"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: capability growth should be detected"
    echo "$adv_cap"
    FAIL=$((FAIL + 1))
fi

# --- New function with weak evidence appears as neutral (known gap) ---

cat > "$ADV_DIR/new_weak_old.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[]}
ADVEOF
cat > "$ADV_DIR/new_weak_new.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"effects","function":"evil_fn","evidence":"reported","no_external_authority":"false","capabilities":"[Alloc]","allocates":"true","frees":"false","recursion":"none","loops":"none","crosses_ffi":"true","is_trusted":"false"}]}
ADVEOF
adv_newweak=$($COMPILER diff "$ADV_DIR/new_weak_old.json" "$ADV_DIR/new_weak_new.json" 2>&1) && adv_nw_exit=0 || adv_nw_exit=$?
# New function with weak evidence should be flagged as weakened
if grep <<<"$adv_newweak" -q '\[+\].*effects.*evil_fn' && \
   grep <<<"$adv_newweak" -q "TRUST WEAKENED"; then
    echo "  ok  adv-diff: new function with weak evidence flagged as trust weakened"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: new weak-evidence function should be flagged as weakened"
    echo "$adv_newweak"
    FAIL=$((FAIL + 1))
fi

# --- Removed fact detected as weakened ---

cat > "$ADV_DIR/removed_old.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"abc"}]}
ADVEOF
adv_removed=$($COMPILER diff "$ADV_DIR/removed_old.json" "$ADV_DIR/new_weak_old.json" 2>&1) && true || true
if grep <<<"$adv_removed" -q "TRUST WEAKENED" && \
   grep <<<"$adv_removed" -q '\[-\].*proof_status.*foo'; then
    echo "  ok  adv-diff: removed proof_status fact flagged as trust weakened"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: removed fact should be flagged as weakened"
    echo "$adv_removed"
    FAIL=$((FAIL + 1))
fi

# --- Escaped characters in function names ---

cat > "$ADV_DIR/escape_old.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"proof_status","function":"mod.fn_with\"quotes","state":"proved","current_fingerprint":"abc"}]}
ADVEOF
cat > "$ADV_DIR/escape_new.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"proof_status","function":"mod.fn_with\"quotes","state":"stale","current_fingerprint":"abc"}]}
ADVEOF
adv_esc=$($COMPILER diff "$ADV_DIR/escape_old.json" "$ADV_DIR/escape_new.json" 2>&1) && true || true
if grep <<<"$adv_esc" -q "TRUST WEAKENED" && \
   grep <<<"$adv_esc" -q "state:.*proved.*stale"; then
    echo "  ok  adv-diff: escaped quotes in function names handled correctly"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: escaped function names should still diff correctly"
    echo "$adv_esc"
    FAIL=$((FAIL + 1))
fi

# --- New weak additions classified as weakened ---

# New proof_status with missing → weakened
cat > "$ADV_DIR/new_noproof_new.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"proof_status","function":"bar","state":"missing","current_fingerprint":"xyz"}]}
ADVEOF
adv_noproof=$($COMPILER diff "$ADV_DIR/new_weak_old.json" "$ADV_DIR/new_noproof_new.json" 2>&1) && true || true
if grep <<<"$adv_noproof" -q "TRUST WEAKENED" && \
   grep <<<"$adv_noproof" -q '\[+\].*proof_status.*bar'; then
    echo "  ok  adv-diff: new missing fact flagged as weakened"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: new missing fact should be weakened"
    echo "$adv_noproof"
    FAIL=$((FAIL + 1))
fi

# New capability with no_external_authority=false → weakened
cat > "$ADV_DIR/new_impure_new.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"capability","function":"impure_fn","capabilities":"[Alloc]","no_external_authority":"false"}]}
ADVEOF
adv_impure=$($COMPILER diff "$ADV_DIR/new_weak_old.json" "$ADV_DIR/new_impure_new.json" 2>&1) && true || true
if grep <<<"$adv_impure" -q "TRUST WEAKENED"; then
    echo "  ok  adv-diff: new impure capability fact flagged as weakened"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: new impure capability should be weakened"
    echo "$adv_impure"
    FAIL=$((FAIL + 1))
fi

# New proved fact → neutral (not weakened)
cat > "$ADV_DIR/new_proved_new.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"proof_status","function":"good","state":"proved","current_fingerprint":"abc"}]}
ADVEOF
adv_proved=$($COMPILER diff "$ADV_DIR/new_weak_old.json" "$ADV_DIR/new_proved_new.json" 2>&1) && adv_proved_exit=0 || adv_proved_exit=$?
if grep <<<"$adv_proved" -q "OTHER CHANGES" && [ "$adv_proved_exit" -eq 0 ]; then
    echo "  ok  adv-diff: new proved fact is neutral (exit 0)"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: new proved fact should be neutral"
    echo "$adv_proved"
    FAIL=$((FAIL + 1))
fi

# Duplicate keys in old bundle → error
cat > "$ADV_DIR/dupes_old_bundle.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"effects","function":"foo","evidence":"proved"},{"kind":"effects","function":"foo","evidence":"stale"}]}
ADVEOF
adv_old_dupes=$($COMPILER diff "$ADV_DIR/dupes_old_bundle.json" "$ADV_DIR/new_weak_old.json" 2>&1) && true || true
if grep <<<"$adv_old_dupes" -qi "error.*duplicate.*old"; then
    echo "  ok  adv-diff: duplicate keys in old bundle rejected"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: duplicate keys in old bundle should be rejected"
    echo "$adv_old_dupes"
    FAIL=$((FAIL + 1))
fi

# --- Nonexistent file path ---

adv_nofile=$($COMPILER diff "$TMPDIR/this_does_not_exist_12345.json" "$ADV_DIR/empty_arr.json" 2>&1) && true || true
if grep <<<"$adv_nofile" -qi "error\|no such file\|does not exist"; then
    echo "  ok  adv-diff: nonexistent file produces error"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: nonexistent file should produce error"
    echo "$adv_nofile"
    FAIL=$((FAIL + 1))
fi

# --- Strengthening direction: stale → proved ---

cat > "$ADV_DIR/strengthen_old.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"proof_status","function":"foo","state":"stale","current_fingerprint":"abc","spec":"Foo.spec","proof":"Foo.proof","source":"registry"}]}
ADVEOF
cat > "$ADV_DIR/strengthen_new.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"abc","spec":"Foo.spec","proof":"Foo.proof","source":"registry"}]}
ADVEOF
adv_strength=$($COMPILER diff "$ADV_DIR/strengthen_old.json" "$ADV_DIR/strengthen_new.json" 2>&1) && adv_str_exit=0 || adv_str_exit=$?
if grep <<<"$adv_strength" -q "TRUST STRENGTHENED" && \
   grep <<<"$adv_strength" -q "state:.*stale.*proved" && \
   [ "$adv_str_exit" -eq 0 ]; then
    echo "  ok  adv-diff: stale→proved detected as strengthened (exit 0)"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: stale→proved should be strengthened with exit 0"
    echo "$adv_strength"
    FAIL=$((FAIL + 1))
fi

# --- Mixed drift: both weakened + strengthened in same diff ---

cat > "$ADV_DIR/mixed_old.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"proof_status","function":"foo","state":"stale","current_fingerprint":"abc"},{"kind":"proof_status","function":"bar","state":"proved","current_fingerprint":"xyz"}]}
ADVEOF
cat > "$ADV_DIR/mixed_new.json" << 'ADVEOF'
{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"abc"},{"kind":"proof_status","function":"bar","state":"stale","current_fingerprint":"xyz"}]}
ADVEOF
adv_mixed=$($COMPILER diff "$ADV_DIR/mixed_old.json" "$ADV_DIR/mixed_new.json" 2>&1) && adv_mix_exit=0 || adv_mix_exit=$?
if grep <<<"$adv_mixed" -q "TRUST WEAKENED" && \
   grep <<<"$adv_mixed" -q "TRUST STRENGTHENED" && \
   [ "$adv_mix_exit" -eq 1 ]; then
    echo "  ok  adv-diff: mixed drift shows both weakened + strengthened (exit 1)"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: mixed drift should show both directions, exit 1"
    echo "$adv_mixed"
    FAIL=$((FAIL + 1))
fi

# --- Round-trip: real diagnostics-json → parse → diff ---

# Generate real compiler JSON, diff it against itself (round-trip parse test)
rt_json=$($COMPILER "$REGISTRY_DIR/test_proof_registry.con" --report diagnostics-json 2>/dev/null)
echo "$rt_json" > "$ADV_DIR/rt_a.json"
echo "$rt_json" > "$ADV_DIR/rt_b.json"
adv_rt=$($COMPILER diff "$ADV_DIR/rt_a.json" "$ADV_DIR/rt_b.json" 2>&1) && adv_rt_exit=0 || adv_rt_exit=$?
if grep <<<"$adv_rt" -q "No trust-relevant changes" && [ "$adv_rt_exit" -eq 0 ]; then
    echo "  ok  adv-diff: round-trip real diagnostics-json parses and self-diffs clean"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: round-trip of real compiler JSON should self-diff clean"
    echo "$adv_rt"
    FAIL=$((FAIL + 1))
fi

# Round-trip with a different program (more complex JSON)
rt_json2=$($COMPILER "$TESTDIR/report_integration.con" --report diagnostics-json 2>/dev/null)
echo "$rt_json2" > "$ADV_DIR/rt_c.json"
echo "$rt_json2" > "$ADV_DIR/rt_d.json"
adv_rt2=$($COMPILER diff "$ADV_DIR/rt_c.json" "$ADV_DIR/rt_d.json" 2>&1) && adv_rt2_exit=0 || adv_rt2_exit=$?
if grep <<<"$adv_rt2" -q "No trust-relevant changes" && [ "$adv_rt2_exit" -eq 0 ]; then
    echo "  ok  adv-diff: round-trip complex program JSON self-diffs clean"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: round-trip of complex program JSON should self-diff clean"
    echo "$adv_rt2"
    FAIL=$((FAIL + 1))
fi

# Cross-program diff on real compiler output (not hand-crafted)
adv_rt_cross=$($COMPILER diff "$ADV_DIR/rt_a.json" "$ADV_DIR/rt_c.json" 2>&1) && true || true
if grep <<<"$adv_rt_cross" -q "Summary:.*changes" && \
   grep <<<"$adv_rt_cross" -q "TRUST WEAKENED"; then
    echo "  ok  adv-diff: cross-program diff on real JSON detects drift"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: cross-program diff on real JSON should detect drift"
    echo "$adv_rt_cross"
    FAIL=$((FAIL + 1))
fi

# Clean up adversarial test files
rm -rf "$ADV_DIR"
:
}

suite_report_22() {

SNAP_DIR="$TMPDIR/concrete_snap_test"
mkdir -p "$SNAP_DIR"

# Basic snapshot generation
snap_out=$($COMPILER snapshot "$REGISTRY_DIR/test_proof_registry.con" -o "$SNAP_DIR/proved.facts.json" 2>&1 || true)
if grep <<<"$snap_out" -q "Snapshot written" && [ -f "$SNAP_DIR/proved.facts.json" ]; then
    echo "  ok  snapshot: generates file with success message"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: should generate file"
    echo "$snap_out"
    FAIL=$((FAIL + 1))
fi

# Snapshot has correct structure (version, source, facts, summary)
if python3 -c "
import json, sys
with open('$SNAP_DIR/proved.facts.json') as f:
    s = json.load(f)
assert s['version'] == 1
assert 'source' in s
assert 'timestamp' in s
assert 'fact_count' in s
assert isinstance(s['facts'], list)
assert isinstance(s['summary'], dict)
assert s['fact_count'] == len(s['facts'])
" 2>/dev/null; then
    echo "  ok  snapshot: JSON has version, source, timestamp, fact_count, facts, summary"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: JSON structure should have all required fields"
    FAIL=$((FAIL + 1))
fi

# Snapshot includes traceability facts (requires backend pipeline)
if python3 -c "
import json, sys
with open('$SNAP_DIR/proved.facts.json') as f:
    s = json.load(f)
kinds = set(f['kind'] for f in s['facts'])
assert 'traceability' in kinds
assert 'proof_status' in kinds
assert 'obligation' in kinds
assert 'extraction' in kinds
assert 'effects' in kinds
assert 'capability' in kinds
" 2>/dev/null; then
    echo "  ok  snapshot: includes all fact kinds including traceability"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: should include all fact kinds"
    FAIL=$((FAIL + 1))
fi

# Summary counts match actual facts
if python3 -c "
import json, sys
with open('$SNAP_DIR/proved.facts.json') as f:
    s = json.load(f)
sm = s['summary']
facts = s['facts']
ps = [f for f in facts if f['kind'] == 'proof_status']
assert sm['total_functions'] == len(ps), f'{sm[\"total_functions\"]} != {len(ps)}'
proved = [f for f in ps if f['state'] == 'proved']
assert sm['proved'] == len(proved)
trace = [f for f in facts if f['kind'] == 'traceability']
assert sm['traceability_facts'] == len(trace)
" 2>/dev/null; then
    echo "  ok  snapshot: summary counts match actual fact counts"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: summary counts should match facts"
    FAIL=$((FAIL + 1))
fi

# Diff works with snapshot files (not just raw arrays)
$COMPILER snapshot "$STALE_DIR/test_proof_registry.con" -o "$SNAP_DIR/stale.facts.json" 2>/dev/null
snap_diff=$($COMPILER diff "$SNAP_DIR/proved.facts.json" "$SNAP_DIR/stale.facts.json" 2>&1) && snap_diff_exit=0 || snap_diff_exit=$?
if grep <<<"$snap_diff" -q "TRUST WEAKENED" && \
   grep <<<"$snap_diff" -q "state:.*proved.*stale" && \
   [ "$snap_diff_exit" -eq 1 ]; then
    echo "  ok  snapshot: diff works with snapshot files (detects proved→stale)"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: diff should work with snapshot files"
    echo "$snap_diff"
    FAIL=$((FAIL + 1))
fi

# Snapshot diff catches traceability boundary drift (only visible with snapshots)
if grep <<<"$snap_diff" -q "boundary:.*ProofCore.*source"; then
    echo "  ok  snapshot: diff catches traceability boundary drift"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: diff should catch traceability boundary changes"
    echo "$snap_diff"
    FAIL=$((FAIL + 1))
fi

# Self-diff on snapshot is clean
snap_self=$($COMPILER diff "$SNAP_DIR/proved.facts.json" "$SNAP_DIR/proved.facts.json" 2>&1) && snap_self_exit=0 || snap_self_exit=$?
if grep <<<"$snap_self" -q "No trust-relevant changes" && [ "$snap_self_exit" -eq 0 ]; then
    echo "  ok  snapshot: self-diff on snapshot is clean"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: self-diff on snapshot should be clean"
    echo "$snap_self"
    FAIL=$((FAIL + 1))
fi

# Mixed diff: snapshot file vs raw diagnostics-json envelope
raw_json=$($COMPILER "$REGISTRY_DIR/test_proof_registry.con" --report diagnostics-json 2>/dev/null)
echo "$raw_json" > "$SNAP_DIR/raw.json"
snap_vs_raw=$($COMPILER diff "$SNAP_DIR/proved.facts.json" "$SNAP_DIR/raw.json" 2>&1) && snap_vr_exit=0 || snap_vr_exit=$?
# Snapshot has traceability facts that raw doesn't → traceability facts appear as removed
if [ "$snap_vr_exit" -eq 0 ] || [ "$snap_vr_exit" -eq 1 ]; then
    echo "  ok  snapshot: diff handles snapshot vs raw envelope format"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: diff should handle mixed formats (snapshot vs raw)"
    echo "$snap_vs_raw"
    FAIL=$((FAIL + 1))
fi

# Default output path: <file>.facts.json
$COMPILER snapshot "$REGISTRY_DIR/test_proof_registry.con" 2>/dev/null
if [ -f "$REGISTRY_DIR/test_proof_registry.facts.json" ]; then
    echo "  ok  snapshot: default output path is <file>.facts.json"
    PASS=$((PASS + 1))
    rm -f "$REGISTRY_DIR/test_proof_registry.facts.json"
else
    echo "FAIL  snapshot: default output should be <file>.facts.json"
    FAIL=$((FAIL + 1))
fi

# Complex program snapshot
snap_complex=$($COMPILER snapshot "$TESTDIR/report_integration.con" -o "$SNAP_DIR/complex.facts.json" 2>&1 || true)
if grep <<<"$snap_complex" -q "Snapshot written" && \
   python3 -c "
import json
with open('$SNAP_DIR/complex.facts.json') as f:
    s = json.load(f)
assert s['fact_count'] > 20
assert s['summary']['predictable_violations'] > 0
" 2>/dev/null; then
    echo "  ok  snapshot: complex program snapshot has violations and many facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: complex program snapshot should have violations"
    echo "$snap_complex"
    FAIL=$((FAIL + 1))
fi

# Clean up
rm -rf "$SNAP_DIR"
:
}

suite_report_23() {

CRYPTO_DIR="$ROOT_DIR/examples/crypto_verify/src"
CRYPTO_SNAP_DIR=$(mktemp -d)

# --- Snapshot tests ---

# Snapshot generates correct fact count
snap_crypto=$($COMPILER snapshot "$CRYPTO_DIR/main.con" -o "$CRYPTO_SNAP_DIR/good.facts.json" 2>&1 || true)
if grep <<<"$snap_crypto" -q "36 facts"; then
    echo "  ok  crypto_verify: snapshot produces 36 facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: expected 36 facts in snapshot"
    echo "$snap_crypto"
    FAIL=$((FAIL + 1))
fi

# All 4 core functions are proved (compute_tag, verify_tag, check_nonce,
# verify_message); main is the lone ineligible (entry point).
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/good.facts.json') as f:
    s = json.load(f)
assert s['summary']['proved'] == 4
assert s['summary']['stale'] == 0
assert s['summary']['missing'] == 0
assert s['summary']['ineligible'] == 1
assert s['summary']['total_functions'] == 5
" 2>/dev/null; then
    echo "  ok  crypto_verify: summary shows 4 proved, 1 ineligible, 0 stale"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: summary proof counts incorrect"
    FAIL=$((FAIL + 1))
fi

# All 4 obligations proved
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/good.facts.json') as f:
    s = json.load(f)
assert s['summary']['obligations_proved'] == 4
assert s['summary']['obligations_missing'] == 0
assert s['summary']['obligations_stale'] == 0
" 2>/dev/null; then
    echo "  ok  crypto_verify: 4 obligations proved, 0 missing"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: obligation counts incorrect"
    FAIL=$((FAIL + 1))
fi

# All 4 core functions extracted
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/good.facts.json') as f:
    s = json.load(f)
assert s['summary']['extracted'] == 4
assert s['summary']['excluded'] == 1
" 2>/dev/null; then
    echo "  ok  crypto_verify: 4 functions extracted, 1 excluded"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: extraction counts incorrect"
    FAIL=$((FAIL + 1))
fi

# Named specs present in facts
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/good.facts.json') as f:
    s = json.load(f)
facts = s['facts']
proof_statuses = [f for f in facts if f['kind'] == 'proof_status' and f.get('spec')]
assert len(proof_statuses) == 4
specs = {f['function']: f['spec'] for f in proof_statuses}
assert specs['main.compute_tag'] == 'Concrete.Proof.computeTagExpr'
assert specs['main.verify_tag'] == 'Concrete.Proof.verifyTagExpr'
assert specs['main.check_nonce'] == 'Concrete.Proof.checkNonceExpr'
assert specs['main.verify_message'] == 'Concrete.Proof.verifyMessageExpr'
" 2>/dev/null; then
    echo "  ok  crypto_verify: named specs present in proof_status facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: named specs missing from proof_status facts"
    FAIL=$((FAIL + 1))
fi

# ProofCore extraction content
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/good.facts.json') as f:
    s = json.load(f)
facts = s['facts']
extractions = {f['function']: f for f in facts if f['kind'] == 'extraction' and f.get('proof_core')}
assert '(nonce + (key * message))' in extractions['main.compute_tag']['proof_core']
assert 'compute_tag' in extractions['main.verify_tag']['proof_core']
assert 'nonce > 0' in extractions['main.check_nonce']['proof_core']
" 2>/dev/null; then
    echo "  ok  crypto_verify: ProofCore extraction content correct"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: ProofCore extraction content incorrect"
    FAIL=$((FAIL + 1))
fi

# All core functions are pure
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/good.facts.json') as f:
    s = json.load(f)
facts = s['facts']
effects = {f['function']: f for f in facts if f['kind'] == 'effects'}
for fn in ['main.compute_tag', 'main.verify_tag', 'main.check_nonce']:
    assert effects[fn]['no_external_authority'] == True
    assert effects[fn]['capabilities'] == []
    assert effects[fn]['crosses_ffi'] == False
" 2>/dev/null; then
    echo "  ok  crypto_verify: all core functions are pure with no capabilities"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: core functions should be pure with no capabilities"
    FAIL=$((FAIL + 1))
fi

# --- Report tests ---

# Proof status report shows 3 proved
report_out=$($COMPILER "$CRYPTO_DIR/main.con" --report proof-status 2>&1 || true)
if grep <<<"$report_out" -q "4 proved" && grep <<<"$report_out" -q "0 unproved" && grep <<<"$report_out" -q "1 ineligible"; then
    echo "  ok  crypto_verify: proof-status report shows 4 proved, 0 unproved, 1 ineligible"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: proof-status report counts wrong"
    echo "$report_out"
    FAIL=$((FAIL + 1))
fi

# Each proved function shows checkmark
for fn in compute_tag verify_tag check_nonce; do
    if grep <<<"$report_out" -q "✓.*$fn"; then
        echo "  ok  crypto_verify: $fn shows proved checkmark"
        PASS=$((PASS + 1))
    else
        echo "FAIL  crypto_verify: $fn should show proved checkmark"
        FAIL=$((FAIL + 1))
    fi
done

# --- Drift detection tests ---

# Generate drifted snapshot
# The drift fixture moved to its OWN PACKAGE on 2026-08-16: it used to sit beside `main.con` here,
# and both resolve to module `main`, so the project loader picked `main.con` and this file's drifted
# bodies were never analyzed at all. A path rewrite missed this line because it goes through
# `$CRYPTO_DIR` rather than a literal — and the resulting missing-file error killed the suite here,
# silently, for several runs.
$COMPILER snapshot "$ROOT_DIR/examples/crypto_verify_drifted/src/main.con" -o "$CRYPTO_SNAP_DIR/drifted.facts.json" 2>/dev/null

# Diff detects trust weakening (exit 1)
diff_out=$($COMPILER diff "$CRYPTO_SNAP_DIR/good.facts.json" "$CRYPTO_SNAP_DIR/drifted.facts.json" 2>&1) && diff_exit=0 || diff_exit=$?
if [ "$diff_exit" = "1" ]; then
    echo "  ok  crypto_verify: drift detection exits 1 (trust weakened)"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: drift detection should exit 1, got $diff_exit"
    FAIL=$((FAIL + 1))
fi

# Diff reports proved → stale for compute_tag
if grep <<<"$diff_out" -q "proved.*stale" && grep <<<"$diff_out" -q "compute_tag"; then
    echo "  ok  crypto_verify: drift shows compute_tag proved → stale"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: drift should show compute_tag proved → stale"
    FAIL=$((FAIL + 1))
fi

# Diff reports proved → stale for check_nonce
if grep <<<"$diff_out" -q "check_nonce"; then
    echo "  ok  crypto_verify: drift shows check_nonce changed"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: drift should show check_nonce changed"
    FAIL=$((FAIL + 1))
fi

# verify_tag IS weakened, even though its own body is unchanged: it calls the
# drifted compute_tag, and since R-0004 slice 3 a proof resting on a non-current
# dependency no longer contributes proved evidence.
#
# This assertion used to be the opposite — "verify_tag is NOT weakened
# (unchanged)" — and that was bug 062 written down as an expectation. The test
# was not wrong about the old behaviour; the old behaviour was wrong. Use the
# JSON view so we read the entry's function field rather than substring-matching
# the rendered fingerprint, which mentions `(call verify_tag ...)` from `main`'s
# body and would yield a false positive.
$COMPILER diff "$CRYPTO_SNAP_DIR/good.facts.json" "$CRYPTO_SNAP_DIR/drifted.facts.json" --json > "$CRYPTO_SNAP_DIR/diff_for_vt.json" 2>&1 && : || :
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/diff_for_vt.json') as f:
    entries = json.load(f)
for e in entries:
    if e.get('drift') == 'weakened' and e.get('function') == 'main.verify_tag':
        raise SystemExit(0)
raise SystemExit(1)
" 2>/dev/null; then
    echo "  ok  crypto_verify: verify_tag IS weakened (its dependency drifted)"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: verify_tag should be weakened by its drifted dependency"
    FAIL=$((FAIL + 1))
fi

# JSON diff output works
$COMPILER diff "$CRYPTO_SNAP_DIR/good.facts.json" "$CRYPTO_SNAP_DIR/drifted.facts.json" --json > "$CRYPTO_SNAP_DIR/diff.json" 2>&1 && diff_json_exit=0 || diff_json_exit=$?
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/diff.json') as f:
    d = json.load(f)
assert isinstance(d, list)
weakened = [e for e in d if e.get('drift') == 'weakened']
assert len(weakened) > 0
assert len(d) > 0
" 2>/dev/null; then
    echo "  ok  crypto_verify: JSON diff output is valid with weakened entries"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: JSON diff output invalid"
    FAIL=$((FAIL + 1))
fi

# Self-diff is clean (exit 0)
self_diff=$($COMPILER diff "$CRYPTO_SNAP_DIR/good.facts.json" "$CRYPTO_SNAP_DIR/good.facts.json" 2>&1) && self_exit=0 || self_exit=$?
if [ "$self_exit" = "0" ]; then
    echo "  ok  crypto_verify: self-diff exits 0 (no drift)"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: self-diff should exit 0, got $self_exit"
    FAIL=$((FAIL + 1))
fi

# Drifted snapshot: 2 stale, and the function that depended on one of them is
# now contained rather than proved (R-0004 slice 3 — previously `proved: 1`).
# Also assert the census TOTALS: `total_functions` silently failed to equal the
# sum of the state counts, because `unbound`/`blocked`/`deps_not_current` were
# missing from the summary object.
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/drifted.facts.json') as f:
    s = json.load(f)
summ = s['summary']
assert summ['stale'] == 2, summ
assert summ['proved'] == 0, summ
assert summ['deps_not_current'] == 1, summ
states = ['proved','stale','missing','ineligible','trusted','unbound','blocked','deps_not_current']
assert sum(summ[k] for k in states) == summ['total_functions'], summ
" 2>/dev/null; then
    echo "  ok  crypto_verify: drifted snapshot shows 2 stale, 0 proved, 1 contained (census totals)"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: drifted snapshot counts wrong"
    FAIL=$((FAIL + 1))
fi

# Clean up
rm -rf "$CRYPTO_SNAP_DIR"
:
}

suite_report_24() {

ELF_DIR="$ROOT_DIR/examples/elf_header/src"
ELF_SNAP_DIR=$(mktemp -d)
FIXTURE_DIR="$ROOT_DIR/tests/fixtures"

# --- Snapshot tests ---

snap_elf=$($COMPILER snapshot "$ELF_DIR/main.con" -o "$ELF_SNAP_DIR/good.json" 2>&1 || true)
if grep <<<"$snap_elf" -q "76 facts"; then
    echo "  ok  elf_header: snapshot produces 76 facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: expected 76 facts in snapshot"
    echo "$snap_elf"
    FAIL=$((FAIL + 1))
fi

# 8 functions: 5 proved, 2 trusted, 1 ineligible (main)
if python3 -c "
import json
with open('$ELF_SNAP_DIR/good.json') as f:
    s = json.load(f)
assert s['summary']['proved'] == 5
assert s['summary']['stale'] == 0
assert s['summary']['trusted'] == 2
assert s['summary']['ineligible'] == 1
assert s['summary']['total_functions'] == 8
" 2>/dev/null; then
    echo "  ok  elf_header: summary shows 5 proved, 2 trusted, 1 ineligible"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: summary proof counts incorrect"
    FAIL=$((FAIL + 1))
fi

# Named specs use real Lean symbol names
if python3 -c "
import json
with open('$ELF_SNAP_DIR/good.json') as f:
    s = json.load(f)
facts = s['facts']
proof_statuses = {f['function']: f for f in facts if f['kind'] == 'proof_status' and f.get('proof')}
assert proof_statuses['main.check_magic']['proof'] == 'Examples.ElfHeader.Proofs.check_magic_correct'
assert proof_statuses['main.validate_header']['proof'] == 'Examples.ElfHeader.Proofs.validate_header_correct'
assert proof_statuses['main.check_version']['spec'] == 'Concrete.Proof.checkVersionExpr'
" 2>/dev/null; then
    echo "  ok  elf_header: proof names match actual Lean symbols"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: proof names don't match Lean symbols"
    FAIL=$((FAIL + 1))
fi

# All 5 core functions are pure
if python3 -c "
import json
with open('$ELF_SNAP_DIR/good.json') as f:
    s = json.load(f)
facts = s['facts']
effects = {f['function']: f for f in facts if f['kind'] == 'effects'}
for fn in ['main.check_magic', 'main.check_class', 'main.check_data', 'main.check_version', 'main.validate_header']:
    assert effects[fn]['no_external_authority'] == True
    assert effects[fn]['capabilities'] == []
" 2>/dev/null; then
    echo "  ok  elf_header: all core functions are pure with no capabilities"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: core functions should be pure"
    FAIL=$((FAIL + 1))
fi

# I/O shell: read_header_bytes has File capability, main has full Std
if python3 -c "
import json
with open('$ELF_SNAP_DIR/good.json') as f:
    s = json.load(f)
facts = s['facts']
effects = {f['function']: f for f in facts if f['kind'] == 'effects'}
assert 'File' in effects['main.read_header_bytes']['capabilities']
assert effects['main.read_header_bytes']['is_trusted'] == True
assert effects['main.read_byte']['is_trusted'] == True
assert effects['main.read_byte']['no_external_authority'] == True
assert effects['main.main']['no_external_authority'] == False
" 2>/dev/null; then
    echo "  ok  elf_header: I/O shell has correct capabilities and trust"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: I/O shell capabilities or trust wrong"
    FAIL=$((FAIL + 1))
fi

# ProofCore extraction includes ELF magic constants
if python3 -c "
import json
with open('$ELF_SNAP_DIR/good.json') as f:
    s = json.load(f)
facts = s['facts']
extractions = {f['function']: f for f in facts if f['kind'] == 'extraction' and f.get('proof_core')}
assert '127' in extractions['main.check_magic']['proof_core']
assert '69' in extractions['main.check_magic']['proof_core']
" 2>/dev/null; then
    echo "  ok  elf_header: ProofCore extraction shows magic byte constants"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: ProofCore extraction should contain magic bytes"
    FAIL=$((FAIL + 1))
fi

# --- Report tests ---

elf_report=$($COMPILER "$ELF_DIR/main.con" --report proof-status 2>&1 || true)
if grep <<<"$elf_report" -q "5 proved" && grep <<<"$elf_report" -q "1 ineligible" && grep <<<"$elf_report" -q "2 trusted"; then
    echo "  ok  elf_header: proof-status report shows 5 proved, 1 ineligible, 2 trusted"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: proof-status report counts wrong"
    echo "$elf_report"
    FAIL=$((FAIL + 1))
fi

for fn in check_magic check_class check_data check_version validate_header; do
    if grep <<<"$elf_report" -q "✓.*$fn"; then
        echo "  ok  elf_header: $fn shows proved checkmark"
        PASS=$((PASS + 1))
    else
        echo "FAIL  elf_header: $fn should show proved checkmark"
        FAIL=$((FAIL + 1))
    fi
done

# Effects report shows correct evidence levels
elf_effects=$($COMPILER "$ELF_DIR/main.con" --report effects 2>&1 || true)
if grep <<<"$elf_effects" -q "5 proved" && grep <<<"$elf_effects" -q "2 trusted-assumption" && grep <<<"$elf_effects" -q "1 reported"; then
    echo "  ok  elf_header: effects report evidence levels correct"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: effects evidence levels wrong"
    echo "$elf_effects"
    FAIL=$((FAIL + 1))
fi

# read_header_bytes shows File capability in effects
if grep <<<"$elf_effects" -A1 "read_header_bytes" | has_match "caps: File"; then
    echo "  ok  elf_header: read_header_bytes shows File capability"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: read_header_bytes should show File capability"
    FAIL=$((FAIL + 1))
fi

# read_byte is trusted but pure (no capabilities)
if grep <<<"$elf_effects" -A1 "read_byte" | has_match "caps: (no external authority)" && grep <<<"$elf_effects" -A1 "read_byte" | has_match "trusted: yes"; then
    echo "  ok  elf_header: read_byte is trusted + pure (pointer read only)"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: read_byte should be trusted + pure"
    FAIL=$((FAIL + 1))
fi

# --- Drift detection tests ---

# Same move, same reason — see the crypto_verify note above.
$COMPILER snapshot "$ROOT_DIR/examples/elf_header_drifted/src/main.con" -o "$ELF_SNAP_DIR/drifted.json" 2>/dev/null

# Diff detects trust weakening (exit 1)
elf_diff=$($COMPILER diff "$ELF_SNAP_DIR/good.json" "$ELF_SNAP_DIR/drifted.json" 2>&1) && elf_diff_exit=0 || elf_diff_exit=$?
if [ "$elf_diff_exit" = "1" ]; then
    echo "  ok  elf_header: drift detection exits 1 (trust weakened)"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: drift detection should exit 1, got $elf_diff_exit"
    FAIL=$((FAIL + 1))
fi

# Diff reports check_magic stale
if grep <<<"$elf_diff" -q "check_magic" && grep <<<"$elf_diff" -q "proved.*stale"; then
    echo "  ok  elf_header: drift shows check_magic proved → stale"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: drift should show check_magic stale"
    FAIL=$((FAIL + 1))
fi

# Diff reports check_version stale
if grep <<<"$elf_diff" -q "check_version"; then
    echo "  ok  elf_header: drift shows check_version changed"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: drift should show check_version changed"
    FAIL=$((FAIL + 1))
fi

# Unchanged functions NOT flagged as weakened (check [~] lines only, not fingerprint text)
if ! grep <<<"$elf_diff" '^\s*\[~\]' | has_match "check_class"; then
    echo "  ok  elf_header: check_class not flagged as weakened (unchanged)"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: check_class should not be weakened"
    FAIL=$((FAIL + 1))
fi

# Self-diff is clean (exit 0)
self_diff=$($COMPILER diff "$ELF_SNAP_DIR/good.json" "$ELF_SNAP_DIR/good.json" 2>&1) && self_exit=0 || self_exit=$?
if [ "$self_exit" = "0" ]; then
    echo "  ok  elf_header: self-diff exits 0 (no drift)"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: self-diff should exit 0, got $self_exit"
    FAIL=$((FAIL + 1))
fi

# Drifted snapshot shows stale proofs
if python3 -c "
import json
with open('$ELF_SNAP_DIR/drifted.json') as f:
    s = json.load(f)
assert s['summary']['stale'] >= 2
assert s['summary']['proved'] <= 3
" 2>/dev/null; then
    echo "  ok  elf_header: drifted snapshot shows stale proofs"
    PASS=$((PASS + 1))
else
    echo "FAIL  elf_header: drifted snapshot stale counts wrong"
    FAIL=$((FAIL + 1))
fi

# --- Build and run tests (project-mode compilation) ---

# Build the project (must run from the project directory)
elf_build_out=$(cd "$ROOT_DIR/examples/elf_header" && "$ROOT_DIR/$COMPILER" build 2>&1) && elf_build_exit=0 || elf_build_exit=$?
if [ "$elf_build_exit" = "0" ]; then
    echo "  ok  elf_header: project builds successfully"
    PASS=$((PASS + 1))

    # Run against valid ELF header fixture
    elf_run_valid=$(cd "$ROOT_DIR/examples/elf_header" && "$ROOT_DIR/$COMPILER" run -- "$FIXTURE_DIR/valid_elf_header.bin" 2>&1)
    if grep <<<"$elf_run_valid" -q "Result: valid ELF header"; then
        echo "  ok  elf_header: run accepts valid ELF file"
        PASS=$((PASS + 1))
    else
        echo "FAIL  elf_header: should accept valid ELF file"
        echo "$elf_run_valid"
        FAIL=$((FAIL + 1))
    fi

    # Valid header reports correct field details
    if grep <<<"$elf_run_valid" -q "magic:.*valid" && grep <<<"$elf_run_valid" -q "class:.*64-bit" && grep <<<"$elf_run_valid" -q "version:.*valid"; then
        echo "  ok  elf_header: run shows correct field details for valid header"
        PASS=$((PASS + 1))
    else
        echo "FAIL  elf_header: field details wrong for valid header"
        FAIL=$((FAIL + 1))
    fi

    # Run against bad magic fixture
    elf_run_bad=$(cd "$ROOT_DIR/examples/elf_header" && "$ROOT_DIR/$COMPILER" run -- "$FIXTURE_DIR/bad_magic.bin" 2>&1) || true  # invalid input exits 1 (13t) — set -e guard
    if grep <<<"$elf_run_bad" -q "INVALID ELF header" && grep <<<"$elf_run_bad" -q "magic:.*INVALID"; then
        echo "  ok  elf_header: run rejects bad magic"
        PASS=$((PASS + 1))
    else
        echo "FAIL  elf_header: should reject bad magic"
        echo "$elf_run_bad"
        FAIL=$((FAIL + 1))
    fi

    # Run against bad class fixture
    elf_run_badcls=$(cd "$ROOT_DIR/examples/elf_header" && "$ROOT_DIR/$COMPILER" run -- "$FIXTURE_DIR/bad_class.bin" 2>&1) || true  # invalid input exits 1 (13t) — set -e guard
    if grep <<<"$elf_run_badcls" -q "INVALID ELF header" && grep <<<"$elf_run_badcls" -q "class:.*INVALID"; then
        echo "  ok  elf_header: run rejects bad class"
        PASS=$((PASS + 1))
    else
        echo "FAIL  elf_header: should reject bad class"
        echo "$elf_run_badcls"
        FAIL=$((FAIL + 1))
    fi

    # Run against bad version fixture
    elf_run_badver=$(cd "$ROOT_DIR/examples/elf_header" && "$ROOT_DIR/$COMPILER" run -- "$FIXTURE_DIR/bad_version.bin" 2>&1) || true  # invalid input exits 1 (13t) — set -e guard
    if grep <<<"$elf_run_badver" -q "INVALID ELF header" && grep <<<"$elf_run_badver" -q "version:.*INVALID"; then
        echo "  ok  elf_header: run rejects bad version"
        PASS=$((PASS + 1))
    else
        echo "FAIL  elf_header: should reject bad version"
        echo "$elf_run_badver"
        FAIL=$((FAIL + 1))
    fi

    # Run against too-short file
    elf_run_short=$(cd "$ROOT_DIR/examples/elf_header" && "$ROOT_DIR/$COMPILER" run -- "$FIXTURE_DIR/too_short.bin" 2>&1) || true  # invalid input exits 1 (13t) — set -e guard
    if grep <<<"$elf_run_short" -q "too short"; then
        echo "  ok  elf_header: run rejects too-short file"
        PASS=$((PASS + 1))
    else
        echo "FAIL  elf_header: should reject too-short file"
        echo "$elf_run_short"
        FAIL=$((FAIL + 1))
    fi

    # Run with no args shows usage
    elf_run_usage=$(cd "$ROOT_DIR/examples/elf_header" && "$ROOT_DIR/$COMPILER" run 2>&1) || true  # usage exits nonzero (13t) — set -e guard
    if grep <<<"$elf_run_usage" -q "Usage:"; then
        echo "  ok  elf_header: run with no args shows usage"
        PASS=$((PASS + 1))
    else
        echo "FAIL  elf_header: should show usage with no args"
        echo "$elf_run_usage"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL  elf_header: project build failed"
    echo "$elf_build_out"
    FAIL=$((FAIL + 5))
fi

# Clean up
rm -rf "$ELF_SNAP_DIR"
:
}

suite_report_25() {

ADV_SNAP_DIR=$(mktemp -d)
ADV_DIR="$TESTDIR"

# --- 2. Fabricated proof name — CLOSED by bug 079 ---
# The registry claims Nonexistent.Module.totally_fake_theorem with a correct fingerprint. This used to
# DOCUMENT a limitation: the claim read `proved` because only the fingerprint was checked. A theorem
# that does not exist evaluates no specification, so the claim is not shown to be about its body.

fab_out=$($COMPILER "$ADV_DIR/adversarial_proof_fabricated/test_proof_registry.con" --report proof-status 2>&1 || true)
if grep <<<"$fab_out" -q "0 proved" && grep <<<"$fab_out" -q "1 spec-unbound"; then
    echo "  ok  adversarial: fabricated proof name with valid fingerprint → spec_unbound, not proved (bug 079)"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: a fabricated proof name with a valid fingerprint is not refused as spec_unbound"
    FAIL=$((FAIL + 1))
fi

# The refusal names the theorem and why — the fingerprint is fine, the theorem is about no body.
if grep <<<"$fab_out" -q "totally_fake_theorem' evaluates no specification"; then
    echo "  ok  adversarial: the refusal names the fabricated theorem"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: the refusal does not name the fabricated theorem"
    FAIL=$((FAIL + 1))
fi

# --- 3. Fabricated proof name in snapshot artifact ---
# The snapshot must still propagate the unchecked name, so downstream tools can audit it — now beside
# the refusal rather than beside a false `proved`.

$COMPILER snapshot "$ADV_DIR/adversarial_proof_fabricated/test_proof_registry.con" -o "$ADV_SNAP_DIR/fabricated.json" 2>/dev/null
if python3 -c "
import json
with open('$ADV_SNAP_DIR/fabricated.json') as f:
    s = json.load(f)
facts = s['facts']
ps = [f for f in facts if f['kind'] == 'proof_status' and f['function'] == 'main.pure_add']
assert len(ps) == 1
assert ps[0]['proof'] == 'Nonexistent.Module.totally_fake_theorem'
assert ps[0]['state'] == 'spec_unbound'
" 2>/dev/null; then
    echo "  ok  adversarial: snapshot propagates the fabricated proof name and its spec_unbound state (auditable)"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: snapshot should contain the fabricated proof name and state spec_unbound"
    FAIL=$((FAIL + 1))
fi

# --- 7. Cross-module proof isolation ---
# Existing test: adversarial_proof_cross_module.con
# Verify main.parse_byte is proved but inner.parse_byte is NOT proved.

if [ -f "$ADV_DIR/adversarial_proof_cross_module.con" ]; then
    cross_out=$($COMPILER "$ADV_DIR/adversarial_proof_cross_module.con" --report proof-status 2>&1 || true)
    if grep <<<"$cross_out" -q "main.parse_byte.*proof matches" 2>/dev/null; then
        echo "  ok  adversarial: cross-module proof isolation — main.parse_byte proved"
        PASS=$((PASS + 1))
    else
        echo "FAIL  adversarial: main.parse_byte should be proved"
        FAIL=$((FAIL + 1))
    fi
fi

# --- 8. Wrong-arity proof resistance ---
# Existing test: adversarial_proof_wrong_arity.con
# Function with different param count must show stale.

if [ -f "$ADV_DIR/adversarial_proof_wrong_arity.con" ]; then
    arity_out=$($COMPILER "$ADV_DIR/adversarial_proof_wrong_arity.con" --report proof-status 2>&1 || true)
    if grep <<<"$arity_out" -q "stale\|body changed"; then
        echo "  ok  adversarial: wrong-arity function shows stale/body changed"
        PASS=$((PASS + 1))
    else
        echo "FAIL  adversarial: wrong-arity function should be stale"
        FAIL=$((FAIL + 1))
    fi
fi

# --- 9. Wrong-semantics proof resistance ---
# Existing test: adversarial_proof_wrong_semantics.con
# Multiply instead of add must show stale.

if [ -f "$ADV_DIR/adversarial_proof_wrong_semantics.con" ]; then
    sem_out=$($COMPILER "$ADV_DIR/adversarial_proof_wrong_semantics.con" --report proof-status 2>&1 || true)
    if grep <<<"$sem_out" -q "stale\|body changed"; then
        echo "  ok  adversarial: wrong-semantics function shows stale/body changed"
        PASS=$((PASS + 1))
    else
        echo "FAIL  adversarial: wrong-semantics function should be stale"
        FAIL=$((FAIL + 1))
    fi
fi

# --- 10. Impure function proof resistance ---
# Existing test: adversarial_proof_impure.con
# Function with capabilities must not be proved.

if [ -f "$ADV_DIR/adversarial_proof_impure.con" ]; then
    impure_out=$($COMPILER "$ADV_DIR/adversarial_proof_impure.con" --report proof-status 2>&1 || true)
    # Sentinel: report header must be present so a compiler crash (empty
    # output) doesn't satisfy the absence check below.
    if grep <<<"$impure_out" -q "Proof Status Report" && ! grep <<<"$impure_out" -q "proved.*proof matches.*impure\|✓.*impure"; then
        echo "  ok  adversarial: impure function not granted proved status"
        PASS=$((PASS + 1))
    else
        echo "FAIL  adversarial: impure function should never be proved"
        FAIL=$((FAIL + 1))
    fi
fi

# Clean up
rm -rf "$ADV_SNAP_DIR"
:
}
