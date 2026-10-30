# evidence: the code units of tests/cases/evidence.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_evidence_1() {
evidence_pass=0
evidence_fail=0

# --- Predictable check: crypto_verify must PASS ---
if [ -f "examples/crypto_verify/src/main.con" ]; then
    pred_out=$("$COMPILER" examples/crypto_verify/src/main.con --check predictable 2>&1) || true
    if grep <<<"$pred_out" -q "predictable profile: pass"; then
        echo "  ok  predictable: crypto_verify passes"
        evidence_pass=$((evidence_pass + 1))
    else
        echo "  FAIL predictable: crypto_verify should pass"
        echo "$pred_out" | awk "NR<=3" | sed 's/^/    /'
        evidence_fail=$((evidence_fail + 1))
    fi
fi

# --- Predictable check: thesis_demo must FAIL (has I/O) ---
if [ -f "examples/thesis_demo/src/main.con" ]; then
    pred_out=$("$COMPILER" examples/thesis_demo/src/main.con --check predictable 2>&1) || true
    if grep <<<"$pred_out" -q "predictable profile: FAIL"; then
        echo "  ok  predictable: thesis_demo correctly fails (has I/O)"
        evidence_pass=$((evidence_pass + 1))
    else
        echo "  FAIL predictable: thesis_demo should fail"
        evidence_fail=$((evidence_fail + 1))
    fi
fi

# --- Stale-proof check: no UNEXPECTED stale on source-linked examples ---
# (proofs are in-source now; proof_pressure has a DELIBERATE stale, so skip it.)
for main_file in examples/*/src/main.con; do
    [ -f "$main_file" ] || continue
    grep -q '#\[proof_by' "$main_file" || continue
    example_name=$(basename "$(dirname "$(dirname "$main_file")")")
    [ "$example_name" = "proof_pressure" ] && continue
    # DRIFT FIXTURES ARE SUPPOSED TO BE STALE — that is the entire reason they exist. They used to
    # live as `<example>/src/main_drifted.con`, which this glob never matched, so the exclusion was
    # accidental. Each is now its own PACKAGE (a drifted body needs its own package identity), so
    # `examples/*_drifted/src/main.con` matches and they arrived in this loop reporting exactly the
    # staleness they are built to demonstrate.
    #
    # Classified by the file's own HEADER rather than by its name, which is the rule
    # scripts/gen/attestation_manifest.sh already applies to the same population: a renamed drift
    # fixture stays classified, and an innocent `*_drifted` name is not misclassified. Skipping by
    # directory name would have been one character shorter and wrong in both directions.
    grep -qE '^// .*DRIFTED variant' "$main_file" && continue
    ps_out=$("$COMPILER" "$main_file" --report proof-status 2>&1) || true
    if grep <<<"$ps_out" -qE "^-- (proof )?stale"; then
        echo "  FAIL stale-proof: $example_name has stale proofs"
        grep <<<"$ps_out" "^-- stale" | awk "NR<=3" | sed 's/^/    /'
        evidence_fail=$((evidence_fail + 1))
    else
        echo "  ok  stale-proof: $example_name — no stale proofs"
        evidence_pass=$((evidence_pass + 1))
    fi
done

# --- Proof-obligation status: thesis_demo has at least one proved obligation ---
if [ -f "examples/thesis_demo/src/main.con" ]; then
    ob_out=$("$COMPILER" examples/thesis_demo/src/main.con --report obligations 2>&1) || true
    if grep <<<"$ob_out" -q "status:.*proved"; then
        echo "  ok  obligations: thesis_demo has proved obligations"
        evidence_pass=$((evidence_pass + 1))
    else
        echo "  FAIL obligations: thesis_demo should have proved obligations"
        evidence_fail=$((evidence_fail + 1))
    fi
fi

# --- Report artifact generation: all report modes produce non-empty output ---
if [ -f "examples/thesis_demo/src/main.con" ]; then
    report_ok=0
    report_bad=0
    for mode in caps unsafe layout alloc authority proof eligibility proof-status obligations \
                proof-diagnostics extraction effects recursion fingerprints consistency verify traceability mono; do
        rout=$("$COMPILER" examples/thesis_demo/src/main.con --report "$mode" 2>&1) || true
        if [ -n "$rout" ]; then
            report_ok=$((report_ok + 1))
        else
            echo "  FAIL report-gen: --report $mode produced empty output"
            report_bad=$((report_bad + 1))
        fi
    done
    if [ "$report_bad" -eq 0 ]; then
        echo "  ok  report-gen: all $report_ok report modes produce output"
        evidence_pass=$((evidence_pass + 1))
    else
        evidence_fail=$((evidence_fail + report_bad))
    fi
fi

# --- Trust-drift: consistency + fingerprints on source-linked examples ---
for main_file in examples/*/src/main.con; do
    [ -f "$main_file" ] || continue
    grep -q '#\[proof_by' "$main_file" || continue
    example_name=$(basename "$(dirname "$(dirname "$main_file")")")
    # Consistency
    con_out=$("$COMPILER" "$main_file" --report consistency 2>&1) || true
    if grep <<<"$con_out" -q "All consistency checks passed"; then
        echo "  ok  trust-drift: $example_name consistency passes"
        evidence_pass=$((evidence_pass + 1))
    else
        echo "  FAIL trust-drift: $example_name has consistency violations"
        echo "$con_out" | awk "NR<=3" | sed 's/^/    /'
        evidence_fail=$((evidence_fail + 1))
    fi
    # Fingerprints (non-empty)
    fp_out=$("$COMPILER" "$main_file" --report fingerprints 2>&1) || true
    if [ -n "$fp_out" ]; then
        echo "  ok  trust-drift: $example_name fingerprints present"
        evidence_pass=$((evidence_pass + 1))
    else
        echo "  FAIL trust-drift: $example_name fingerprints empty"
        evidence_fail=$((evidence_fail + 1))
    fi
done
:
}

suite_evidence_2() {

drift_check() {
    local name="$1" original="$2" drifted="$3" expect_pattern="$4"
    local orig_snap="$TMPDIR/drift_${name}_orig.json"
    local drift_snap="$TMPDIR/drift_${name}_drift.json"
    "$COMPILER" snapshot "$original" -o "$orig_snap" 2>/dev/null
    "$COMPILER" snapshot "$drifted" -o "$drift_snap" 2>/dev/null
    local diff_out
    diff_out=$("$COMPILER" diff "$orig_snap" "$drift_snap" 2>&1) || true
    local diff_exit=$?
    # diff exits 1 on weakening (but we captured output, check for TRUST WEAKENED)
    if grep <<<"$diff_out" -q "TRUST WEAKENED"; then
        echo "  ok  drift-demo: $name — trust weakening detected"
        evidence_pass=$((evidence_pass + 1))
    else
        echo "  FAIL drift-demo: $name — should detect trust weakening"
        echo "$diff_out" | awk "NR<=3" | sed 's/^/    /'
        evidence_fail=$((evidence_fail + 1))
    fi
    # Check specific drift pattern
    if [ -n "$expect_pattern" ]; then
        if grep <<<"$diff_out" -q "$expect_pattern"; then
            echo "  ok  drift-demo: $name — $expect_pattern found"
            evidence_pass=$((evidence_pass + 1))
        else
            echo "  FAIL drift-demo: $name — expected '$expect_pattern' not found"
            evidence_fail=$((evidence_fail + 1))
        fi
    fi
}

# crypto_verify: proof semantic drift (+ → -, > → >=)
if [ -f "examples/crypto_verify/src/main.con" ] && [ -f "examples/crypto_verify_drifted/src/main.con" ]; then
    drift_check "crypto_verify" \
        "examples/crypto_verify/src/main.con" \
        "examples/crypto_verify_drifted/src/main.con" \
        "proved → stale"
fi

# elf_header: validation weakening (magic byte 127→0, version accepts 0)
if [ -f "examples/elf_header/src/main.con" ] && [ -f "examples/elf_header_drifted/src/main.con" ]; then
    drift_check "elf_header" \
        "examples/elf_header/src/main.con" \
        "examples/elf_header_drifted/src/main.con" \
        "proved → stale"
fi

# thesis_demo: authority escalation + proof drift + resource drift
if [ -f "examples/thesis_demo/src/main.con" ] && [ -f "examples/thesis_demo/src/main_drifted.con" ]; then
    drift_check "thesis_demo" \
        "examples/thesis_demo/src/main.con" \
        "examples/thesis_demo/src/main_drifted.con" \
        "no_external_authority: true → false"

    # Also check authority escalation specifically
    diff_out=$("$COMPILER" diff "$TMPDIR/drift_thesis_demo_orig.json" "$TMPDIR/drift_thesis_demo_drift.json" 2>&1) || true
    if grep <<<"$diff_out" -q "capabilities.*File"; then
        echo "  ok  drift-demo: thesis_demo — authority escalation (File) detected"
        evidence_pass=$((evidence_pass + 1))
    else
        echo "  FAIL drift-demo: thesis_demo — should detect File capability escalation"
        evidence_fail=$((evidence_fail + 1))
    fi

    # Check resource drift (bounded → unbounded)
    if grep <<<"$diff_out" -q "loops.*bounded.*unbounded\|unbounded"; then
        echo "  ok  drift-demo: thesis_demo — resource drift (unbounded loop) detected"
        evidence_pass=$((evidence_pass + 1))
    else
        echo "  FAIL drift-demo: thesis_demo — should detect unbounded loop drift"
        evidence_fail=$((evidence_fail + 1))
    fi
fi

# --- Proof pressure set: all 6 target states in one file ---
pp_out=$($COMPILER examples/proof_pressure/src/main.con --report proof-status 2>/dev/null)

# 1. check_nonce is proved
if grep <<<"$pp_out" -B5 "check_nonce" | has_match "^-- proved"; then
    echo "  ok  pressure-set: check_nonce is proved"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-set: check_nonce should be proved"
    evidence_fail=$((evidence_fail + 1))
fi

# 2. validate_header has NO proof — the honest state after its wrong link was deleted
# RE-PINNED 2026-08-18. `validate_header` carried a link to elf_header's
# `validate_header_correct` — a theorem about ELF magic/class/data/version bytes, on a function
# that checks a nonce and calls check_nonce. Same qualified name, nothing else in common; it passed
# every name-based check for months until correspondence caught it. Repaired by DELETING the claim,
# because no theorem proves that body and attaching the nearest plausible one is the defect being
# repaired. So the pressure set legitimately has one fewer proved function.
if grep <<<"$pp_out" -B5 "validate_header" | has_match "no proof"; then
    echo "  ok  pressure-set: validate_header has no proof (its misattributed link was deleted)"
    evidence_pass=$((evidence_pass + 1))
elif grep <<<"$pp_out" -B5 "validate_header" | has_match "^-- proved"; then
    echo "  FAIL pressure-set: validate_header is proved again — no theorem proves this body; a link was re-attached"
    evidence_fail=$((evidence_fail + 1))
else
    echo "  FAIL pressure-set: validate_header should report no proof"
    evidence_fail=$((evidence_fail + 1))
fi

# 3. compute_checksum is stale
if grep <<<"$pp_out" -B5 "compute_checksum" | has_match "proof stale"; then
    echo "  ok  pressure-set: compute_checksum is stale"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-set: compute_checksum should be stale"
    evidence_fail=$((evidence_fail + 1))
fi

# 4. format_result is ineligible
if grep <<<"$pp_out" -B5 "format_result" | has_match "not eligible"; then
    echo "  ok  pressure-set: format_result is ineligible"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-set: format_result should be ineligible"
    evidence_fail=$((evidence_fail + 1))
fi

# 5. clamp_value is missing (no proof)
if grep <<<"$pp_out" -B5 "clamp_value" | has_match "no proof"; then
    echo "  ok  pressure-set: clamp_value is missing (no proof)"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-set: clamp_value should be missing (no proof)"
    evidence_fail=$((evidence_fail + 1))
fi

# 6. classify_range is blocked
if grep <<<"$pp_out" -B5 "classify_range" | has_match "^-- blocked"; then
    echo "  ok  pressure-set: classify_range is blocked"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-set: classify_range should be blocked"
    evidence_fail=$((evidence_fail + 1))
fi

# 7. Totals line has all 6 states accounted for
if grep <<<"$pp_out" -q "1 proved.*1 stale.*2 unproved.*1 blocked.*2 ineligible"; then
    echo "  ok  pressure-set: totals match expected (1 proved, 1 stale, 2 unproved, 1 blocked, 2 ineligible)"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-set: totals should be 1 proved, 1 stale, 2 unproved, 1 blocked, 2 ineligible"
    echo "    got: $(grep <<<"$pp_out" "Totals:")"
    evidence_fail=$((evidence_fail + 1))
fi

# --- Pressure set: extraction report ---
pp_ext=$($COMPILER examples/proof_pressure/src/main.con --report extraction 2>/dev/null)

# 8. Extraction: check_nonce has correct ProofCore form
# (Body was aligned to crypto_verify's shared spec in commit 8a53c3db: returns 1
#  iff 0 < nonce <= max_nonce, else 0 — so it rides the registered spec/proof.)
if grep <<<"$pp_ext" -A2 "check_nonce" | has_match "if (nonce > 0) then if (nonce <= max_nonce) then 1 else 0 else 0"; then
    echo "  ok  pressure-ext: check_nonce ProofCore form correct"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-ext: check_nonce ProofCore form wrong"
    evidence_fail=$((evidence_fail + 1))
fi

# 9. Extraction: clamp_value has correct ProofCore form
if grep <<<"$pp_ext" -A2 "clamp_value" | has_match "if (x < lo) then lo else if (x > hi) then hi else x"; then
    echo "  ok  pressure-ext: clamp_value ProofCore form correct"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-ext: clamp_value ProofCore form wrong"
    evidence_fail=$((evidence_fail + 1))
fi

# 10. Extraction: classify_range is eligible but extraction failed
if grep <<<"$pp_ext" -A2 "classify_range" | has_match "eligible (extraction failed)"; then
    echo "  ok  pressure-ext: classify_range extraction failed (blocked)"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-ext: classify_range should show extraction failed"
    evidence_fail=$((evidence_fail + 1))
fi

# 11. Extraction: classify_range blocked by integer division
# (Field access became extractable in e2ab5eef, so the blocker was repointed at
#  integer division `/` in commit 8a53c3db — no PBinOp.div, durably unmodeled.
#  The function still reads the Bounds struct, now as a supported construct.)
if grep <<<"$pp_ext" -A5 "classify_range" | has_match "Concrete.BinOp.mod"; then
    echo "  ok  pressure-ext: classify_range blocked by integer remainder at Int"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-ext: classify_range should cite integer remainder at Int as blocker"
    evidence_fail=$((evidence_fail + 1))
fi

# 12. Extraction: format_result is excluded with Console reason
if grep <<<"$pp_ext" -A5 "format_result" | has_match "has capabilities: Console"; then
    echo "  ok  pressure-ext: format_result excluded (Console capability)"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-ext: format_result should cite Console capability"
    evidence_fail=$((evidence_fail + 1))
fi

# 13. Extraction totals: 4 extracted, 1 not extractable, 2 excluded
if grep <<<"$pp_ext" -q "4 extracted.*1 eligible but not extractable.*2 excluded"; then
    echo "  ok  pressure-ext: extraction totals correct (4/1/2)"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-ext: extraction totals should be 4/1/2"
    echo "    got: $(grep <<<"$pp_ext" "Totals:")"
    evidence_fail=$((evidence_fail + 1))
fi

# --- Pressure set: obligations report ---
pp_obl=$($COMPILER examples/proof_pressure/src/main.con --report obligations 2>/dev/null)

# 14. Obligations: validate_header depends on check_nonce
if grep <<<"$pp_obl" -A8 "main.validate_header" | has_match "dependencies: main.check_nonce"; then
    echo "  ok  pressure-obl: validate_header depends on check_nonce"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-obl: validate_header should depend on check_nonce"
    evidence_fail=$((evidence_fail + 1))
fi

# 15. Obligations: proved functions cite registry as source
if grep <<<"$pp_obl" -A5 "main.check_nonce" | has_match "source:.*registry"; then
    echo "  ok  pressure-obl: check_nonce proof source is registry"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-obl: check_nonce should cite registry as source"
    evidence_fail=$((evidence_fail + 1))
fi

# 16. Obligations: missing function has no spec
if grep <<<"$pp_obl" -A5 "main.clamp_value" | has_match "spec:.*(none)"; then
    echo "  ok  pressure-obl: clamp_value has no spec (missing)"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-obl: clamp_value should have no spec"
    evidence_fail=$((evidence_fail + 1))
fi

# 17. Obligations totals match proof-status totals
if grep <<<"$pp_obl" -q "1 proved.*1 stale.*2 missing.*1 blocked.*2 ineligible"; then
    echo "  ok  pressure-obl: obligation totals match proof-status (1 proved)"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-obl: obligation totals should be 1 proved, 1 stale, 2 missing, 1 blocked, 2 ineligible"
    echo "    got: $(grep <<<"$pp_obl" "Totals:")"
    evidence_fail=$((evidence_fail + 1))
fi

# --- Pressure set: eligibility report ---
pp_elig=$($COMPILER examples/proof_pressure/src/main.con --report eligibility 2>/dev/null)

# 18. Eligibility: 5 eligible, 2 excluded
if grep <<<"$pp_elig" -q "5 eligible.*2 excluded"; then
    echo "  ok  pressure-elig: eligibility totals correct (5/2)"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-elig: eligibility totals should be 5 eligible, 2 excluded"
    echo "    got: $(grep <<<"$pp_elig" "Totals:")"
    evidence_fail=$((evidence_fail + 1))
fi

# 19. Eligibility: main excluded as entry point
if grep <<<"$pp_elig" -A2 "main.main" | has_match "entry point"; then
    echo "  ok  pressure-elig: main excluded as entry point"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-elig: main should be excluded as entry point"
    evidence_fail=$((evidence_fail + 1))
fi

# --- Pressure set: effects/evidence consistency ---
pp_eff=$($COMPILER examples/proof_pressure/src/main.con --report effects 2>/dev/null)

# 20. Effects: check_nonce evidence is proved (not enforced)
if grep <<<"$pp_eff" -A1 "check_nonce" | has_match "evidence: proved"; then
    echo "  ok  pressure-eff: check_nonce evidence is proved"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-eff: check_nonce evidence should be proved"
    evidence_fail=$((evidence_fail + 1))
fi

# 21. Effects: compute_checksum evidence shows stale
if grep <<<"$pp_eff" -A1 "compute_checksum" | has_match "proof stale"; then
    echo "  ok  pressure-eff: compute_checksum evidence shows stale"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-eff: compute_checksum evidence should show stale"
    evidence_fail=$((evidence_fail + 1))
fi

# 22. Effects: evidence totals show 2 proved
if grep <<<"$pp_eff" -q "Evidence: 1 proved"; then
    echo "  ok  pressure-eff: effects evidence totals show 1 proved"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-eff: effects evidence should show 1 proved"
    echo "    got: $(grep <<<"$pp_eff" "Evidence:")"
    evidence_fail=$((evidence_fail + 1))
fi

# --- Pressure set: fingerprint determinism ---
# 23. Fingerprints are deterministic across runs
pp_fp1=$($COMPILER examples/proof_pressure/src/main.con --report fingerprints 2>/dev/null)
pp_fp2=$($COMPILER examples/proof_pressure/src/main.con --report fingerprints 2>/dev/null)
if [ "$pp_fp1" = "$pp_fp2" ]; then
    echo "  ok  pressure-fp: fingerprints deterministic across runs"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-fp: fingerprints differ between runs"
    evidence_fail=$((evidence_fail + 1))
fi

# 24. Extraction is deterministic across runs
pp_ext2=$($COMPILER examples/proof_pressure/src/main.con --report extraction 2>/dev/null)
if [ "$pp_ext" = "$pp_ext2" ]; then
    echo "  ok  pressure-fp: extraction deterministic across runs"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-fp: extraction differs between runs"
    evidence_fail=$((evidence_fail + 1))
fi

# --- Pressure set: lean-stubs report ---
pp_lean=$($COMPILER examples/proof_pressure/src/main.con --report lean-stubs 2>/dev/null)

# 25. Lean stubs: generates 4 PExpr definitions (one per extractable function)
stub_count=$(grep <<<"$pp_lean" -c "def .*Expr : PExpr")
if [ "$stub_count" -eq 4 ]; then
    echo "  ok  pressure-lean: 4 PExpr definitions generated"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-lean: expected 4 PExpr defs, got $stub_count"
    evidence_fail=$((evidence_fail + 1))
fi

# 26. Lean stubs: generates function table with all 4 entries
if grep <<<"$pp_lean" -q "def generatedFns"; then
    echo "  ok  pressure-lean: function table generated"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-lean: function table missing"
    evidence_fail=$((evidence_fail + 1))
fi

# Generated symbols carry the MODULE and escape `_` as `__` (so `check_nonce` in
# module `main` is `main_check__nonce`). That derivation is what makes symbols
# collision-proof across modules and keeps the escaping injective; these patterns
# were pinned to the older bare names.
# 27. Lean stubs: check_nonce has .ifThenElse constructor
if grep <<<"$pp_lean" -A5 "main_check__nonceExpr" | has_match ".ifThenElse"; then
    echo "  ok  pressure-lean: check_nonce uses .ifThenElse constructor"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-lean: check_nonce should use .ifThenElse"
    evidence_fail=$((evidence_fail + 1))
fi

# 28. Lean stubs: validate_header has .letIn and .call constructors
if grep <<<"$pp_lean" -A5 "main_validate__headerExpr" | has_match ".letIn"; then
    echo "  ok  pressure-lean: validate_header uses .letIn constructor"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-lean: validate_header should use .letIn"
    evidence_fail=$((evidence_fail + 1))
fi

# 29. Lean stubs: compute_checksum has .binOp .add constructor
if grep <<<"$pp_lean" -A5 "main_compute__checksumExpr" | has_match ".binOp .add"; then
    echo "  ok  pressure-lean: compute_checksum uses .binOp .add"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-lean: compute_checksum should use .binOp .add"
    evidence_fail=$((evidence_fail + 1))
fi

# 30. Lean stubs: 4 theorem stubs generated
thm_count=$(grep <<<"$pp_lean" -c "^theorem")
if [ "$thm_count" -eq 4 ]; then
    echo "  ok  pressure-lean: 4 theorem stubs generated"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-lean: expected 4 theorem stubs, got $thm_count"
    evidence_fail=$((evidence_fail + 1))
fi

# 31. Lean stubs: theorem names match function names
if grep <<<"$pp_lean" -q "theorem main_check__nonce_correct" && \
   grep <<<"$pp_lean" -q "theorem main_validate__header_correct" && \
   grep <<<"$pp_lean" -q "theorem main_compute__checksum_correct" && \
   grep <<<"$pp_lean" -q "theorem main_clamp__value_correct"; then
    echo "  ok  pressure-lean: theorem names match function names"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-lean: theorem names should match function names"
    evidence_fail=$((evidence_fail + 1))
fi

# 32. Lean stubs: excluded functions (format_result, main) are NOT in stubs
if ! grep <<<"$pp_lean" -q "format_resultExpr" && \
   ! grep <<<"$pp_lean" -q "classify_rangeExpr"; then
    echo "  ok  pressure-lean: excluded/blocked functions omitted from stubs"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-lean: excluded/blocked functions should not appear"
    evidence_fail=$((evidence_fail + 1))
fi

# 33. Lean stubs: deterministic across runs
pp_lean2=$($COMPILER examples/proof_pressure/src/main.con --report lean-stubs 2>/dev/null)
if [ "$pp_lean" = "$pp_lean2" ]; then
    echo "  ok  pressure-lean: lean-stubs deterministic across runs"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-lean: lean-stubs differ between runs"
    evidence_fail=$((evidence_fail + 1))
fi

# 34. Lean stubs: eval helpers generated for each function
eval_count=$(grep <<<"$pp_lean" -c "^def eval_")
if [ "$eval_count" -eq 4 ]; then
    echo "  ok  pressure-lean: 4 eval helpers generated"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL pressure-lean: expected 4 eval helpers, got $eval_count"
    evidence_fail=$((evidence_fail + 1))
fi

# --- Lean kernel checking (item 7) ---

# 41. check-proofs: in-source linked proofs (formerly the hardcoded table) are kernel-verified
cp_out=$($COMPILER tests/programs/proof_decode_header.con --report check-proofs 2>&1 || true)
if grep <<<"$cp_out" -q "Kernel-verified" && grep <<<"$cp_out" -q "parse_byte"; then
    echo "  ok  check-proofs: linked proofs kernel-verified"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL check-proofs: linked proofs should be kernel-verified"
    evidence_fail=$((evidence_fail + 1))
fi

# 42. check-proofs: pressure set shows verified + failed
cp_pp=$($COMPILER examples/proof_pressure/src/main.con --report check-proofs 2>&1) || true
if grep <<<"$cp_pp" -q "Kernel-verified (1)" && grep <<<"$cp_pp" -q "Failed (1)"; then
    echo "  ok  check-proofs: pressure set 1 verified, 1 failed"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL check-proofs: pressure set should have 1 verified, 1 failed"
    echo "    got: $(grep <<<"$cp_pp" "Summary:")"
    evidence_fail=$((evidence_fail + 1))
fi


# 45. check-proofs: shows toolchain version
if grep <<<"$cp_out" -q "Toolchain:.*lean4"; then
    echo "  ok  check-proofs: reports Lean toolchain version"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL check-proofs: should report toolchain version"
    evidence_fail=$((evidence_fail + 1))
fi

# 46. check-proofs: exit code 0 when all proofs pass
cp_good_rc=0
$COMPILER tests/programs/proof_decode_header.con --report check-proofs > /dev/null 2>&1 || cp_good_rc=$?
if [ "$cp_good_rc" -eq 0 ]; then
    echo "  ok  check-proofs: exit code 0 when all proofs pass"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL check-proofs: should exit 0 when all proofs pass"
    evidence_fail=$((evidence_fail + 1))
fi

# --- End-to-end Lean attachment workflow (item 8) ---

# 47. E2E: proved function has correct proof-status + obligations + check-proofs
e2e_ps=$($COMPILER tests/programs/proof_decode_header.con --report proof-status 2>&1 || true)
e2e_ob=$($COMPILER tests/programs/proof_decode_header.con --report obligations 2>&1 || true)
if grep <<<"$e2e_ps" -q "proved" && grep <<<"$e2e_ob" -q "status:.*proved" && grep <<<"$cp_out" -q "Kernel-verified"; then
    echo "  ok  e2e-lean: proved function consistent across proof-status, obligations, and check-proofs"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL e2e-lean: proved function should be consistent across all reports"
    evidence_fail=$((evidence_fail + 1))
fi

# 48. E2E: stale function shows stale in proof-status + obligations
e2e_pp_ps=$($COMPILER examples/proof_pressure/src/main.con --report proof-status 2>&1) || true
e2e_pp_ob=$($COMPILER examples/proof_pressure/src/main.con --report obligations 2>&1) || true
if grep <<<"$e2e_pp_ps" -B5 "compute_checksum" | has_match "proof stale" && grep <<<"$e2e_pp_ob" -A3 "compute_checksum" | has_match "status:.*stale"; then
    echo "  ok  e2e-lean: stale function consistent across proof-status and obligations"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL e2e-lean: stale function should be consistent across reports"
    evidence_fail=$((evidence_fail + 1))
fi

# 49. E2E: source-linked proof name matches check-proofs theorem name
# (Example proof theorems were migrated out of Concrete.Proof.* into
#  Examples.CryptoVerify.Proofs.* — check_nonce rides crypto_verify's proof.)
if grep <<<"$cp_pp" -q "check_nonce.*Examples.CryptoVerify.Proofs.check_nonce_correct"; then
    echo "  ok  e2e-lean: source-linked proof name matches kernel-checked theorem"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL e2e-lean: source-linked proof name should appear in check-proofs output"
    evidence_fail=$((evidence_fail + 1))
fi

# 50. E2E: fingerprint in obligations matches extraction fingerprint
e2e_ext=$($COMPILER examples/proof_pressure/src/main.con --report extraction 2>&1) || true
e2e_ob_fp=$(grep <<<"$e2e_pp_ob" -A8 "check_nonce" | grep -o '\[.*\]' | awk "NR==1")
e2e_ext_fp=$(grep <<<"$e2e_ext" -A5 "check_nonce" | grep -o '\[.*\]' | awk "NR==1")
if [ -n "$e2e_ob_fp" ] && [ "$e2e_ob_fp" = "$e2e_ext_fp" ]; then
    echo "  ok  e2e-lean: obligation fingerprint matches extraction fingerprint"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL e2e-lean: obligation and extraction fingerprints should match"
    evidence_fail=$((evidence_fail + 1))
fi

# --- Blocked/ineligible proof pressure tests (item 10) ---

INELIG_SRC="tests/programs/adversarial_proof_ineligible_pressure.con"
BLOCKED_SRC="tests/programs/adversarial_proof_blocked_pressure.con"
BOUNDARY_SRC="tests/programs/adversarial_proof_boundary_pressure.con"

# Collect outputs
inelig_ps=$($COMPILER "$INELIG_SRC" --report proof-status 2>&1 || true)
inelig_ob=$($COMPILER "$INELIG_SRC" --report obligations 2>&1 || true)
blocked_ps=$($COMPILER "$BLOCKED_SRC" --report proof-status 2>&1 || true)
blocked_ob=$($COMPILER "$BLOCKED_SRC" --report obligations 2>&1 || true)
boundary_ps=$($COMPILER "$BOUNDARY_SRC" --report proof-status 2>&1 || true)

# 57. Ineligible: File capability named in reasons
if grep <<<"$inelig_ps" -A6 "caps_file" | has_match "has capabilities: File"; then
    echo "  ok  ineligible-pressure: File capability named in reasons"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: File capability should be named in reasons"
    evidence_fail=$((evidence_fail + 1))
fi

# 58. Ineligible: Network capability named in reasons
if grep <<<"$inelig_ps" -A6 "caps_network" | has_match "has capabilities: Network"; then
    echo "  ok  ineligible-pressure: Network capability named in reasons"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: Network capability should be named in reasons"
    evidence_fail=$((evidence_fail + 1))
fi

# 59. Ineligible: Process capability named in reasons
if grep <<<"$inelig_ps" -A6 "caps_process" | has_match "has capabilities: Process"; then
    echo "  ok  ineligible-pressure: Process capability named in reasons"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: Process capability should be named in reasons"
    evidence_fail=$((evidence_fail + 1))
fi

# 60. Ineligible: Unsafe capability named in reasons
if grep <<<"$inelig_ps" -A6 "caps_unsafe" | has_match "has capabilities: Unsafe"; then
    echo "  ok  ineligible-pressure: Unsafe capability named in reasons"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: Unsafe capability should be named in reasons"
    evidence_fail=$((evidence_fail + 1))
fi

# 61. Ineligible: trusted function shows trusted, not ineligible
if grep <<<"$inelig_ps" -B5 "trusted_fn" | has_match -- "-- trusted"; then
    echo "  ok  ineligible-pressure: trusted function shows trusted status"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: trusted function should show trusted status"
    evidence_fail=$((evidence_fail + 1))
fi

# 62. Ineligible: direct recursion named in reasons
if grep <<<"$inelig_ps" -A6 "recursive_fn" | has_match "recursion (direct)"; then
    echo "  ok  ineligible-pressure: direct recursion named in reasons"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: direct recursion should be named in reasons"
    evidence_fail=$((evidence_fail + 1))
fi

# 63. Ineligible: mutual recursion named in reasons
if grep <<<"$inelig_ps" -A6 "mutual_a" | has_match "recursion (mutual)"; then
    echo "  ok  ineligible-pressure: mutual recursion named in reasons"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: mutual recursion should be named in reasons"
    evidence_fail=$((evidence_fail + 1))
fi

# 64. Ineligible: FFI named in reasons
if grep <<<"$inelig_ps" -A6 "ffi_fn" | has_match "FFI"; then
    echo "  ok  ineligible-pressure: FFI named in reasons"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: FFI should be named in reasons"
    evidence_fail=$((evidence_fail + 1))
fi

# 65. Ineligible: allocation named in reasons
if grep <<<"$inelig_ps" -A6 "alloc_fn" | has_match "allocation"; then
    echo "  ok  ineligible-pressure: allocation named in reasons"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: allocation should be named in reasons"
    evidence_fail=$((evidence_fail + 1))
fi

# 66. Ineligible: combo shows multiple reasons
if grep <<<"$inelig_ps" -A6 "combo_fn" | grep "has capabilities: File" | has_match "recursion (direct)"; then
    echo "  ok  ineligible-pressure: combo function shows multiple reasons"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: combo function should show multiple reasons"
    evidence_fail=$((evidence_fail + 1))
fi

# 67. Ineligible: clean_fn is missing (eligible), not ineligible
if grep <<<"$inelig_ps" -B5 "clean_fn" | has_match -- "-- no proof"; then
    echo "  ok  ineligible-pressure: clean_fn correctly shows missing, not ineligible"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: clean_fn should show missing, not ineligible"
    evidence_fail=$((evidence_fail + 1))
fi

# 68. Ineligible: entry point named in reasons
if grep <<<"$inelig_ps" -A6 'main\.main' | has_match "is entry point (main)"; then
    echo "  ok  ineligible-pressure: entry point named in reasons"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: entry point should be named in reasons"
    evidence_fail=$((evidence_fail + 1))
fi

# 69. Ineligible: obligations report matches proof-status
inelig_ob_inelig=$(grep <<<"$inelig_ob" "status:.*ineligible" | wc -l | tr -d ' ')
inelig_ps_inelig=$(grep <<<"$inelig_ps" "not eligible" | wc -l | tr -d ' ')
if [ "$inelig_ob_inelig" = "$inelig_ps_inelig" ]; then
    echo "  ok  ineligible-pressure: obligations count ($inelig_ob_inelig) matches proof-status count"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: obligations ineligible count ($inelig_ob_inelig) != proof-status count ($inelig_ps_inelig)"
    evidence_fail=$((evidence_fail + 1))
fi

# 70. Ineligible: hint does NOT say 'Remove is entry point'
if ! grep <<<"$inelig_ps" -q "Remove.*is entry point"; then
    echo "  ok  ineligible-pressure: hint does not suggest removing entry point"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL ineligible-pressure: hint should not suggest removing entry point"
    evidence_fail=$((evidence_fail + 1))
fi

# 71. Blocked: integer division named in unsupported
# (struct literal became extractable in e2ab5eef; repointed at integer division,
#  which has no PBinOp.div and stays durably unmodeled — see fixture header.)
if grep <<<"$blocked_ps" -A8 "uses_rem" | has_match "Concrete.BinOp.mod"; then
    echo "  ok  blocked-pressure: integer remainder at Int named in unsupported"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL blocked-pressure: integer remainder at Int should be named in unsupported"
    evidence_fail=$((evidence_fail + 1))
fi

# 72. Blocked: field assignment named in unsupported
# (match expression became extractable in e2ab5eef; repointed at field assignment.)
if grep <<<"$blocked_ps" -A8 "uses_field_assign" | has_match "field assignment"; then
    echo "  ok  blocked-pressure: field assignment named in unsupported"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL blocked-pressure: field assignment should be named in unsupported"
    evidence_fail=$((evidence_fail + 1))
fi

# 73. Blocked: mutable assignment named in unsupported
if grep <<<"$blocked_ps" -A8 "uses_mut" | has_match "mutable assignment"; then
    echo "  ok  blocked-pressure: mutable assignment named in unsupported"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL blocked-pressure: mutable assignment should be named in unsupported"
    evidence_fail=$((evidence_fail + 1))
fi

# 74. Blocked: string literal named in unsupported
if grep <<<"$blocked_ps" -A8 "uses_string" | has_match "string literal"; then
    echo "  ok  blocked-pressure: string literal named in unsupported"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL blocked-pressure: string literal should be named in unsupported"
    evidence_fail=$((evidence_fail + 1))
fi

# 75. Blocked: deref named in unsupported
# (if-without-else became extractable in e2ab5eef; repointed at deref/borrow.)
if grep <<<"$blocked_ps" -A8 "uses_deref" | has_match "deref"; then
    echo "  ok  blocked-pressure: deref named in unsupported"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL blocked-pressure: deref should be named in unsupported"
    evidence_fail=$((evidence_fail + 1))
fi

# 76. Blocked: extractable_fn is missing (extractable), not blocked
if grep <<<"$blocked_ps" -B5 "extractable_fn" | has_match -- "-- no proof"; then
    echo "  ok  blocked-pressure: extractable_fn correctly shows missing, not blocked"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL blocked-pressure: extractable_fn should show missing, not blocked"
    evidence_fail=$((evidence_fail + 1))
fi

# 77. Blocked: obligations report shows blocked status
blocked_ob_count=$(grep <<<"$blocked_ob" "status:.*blocked" | wc -l | tr -d ' ')
blocked_ps_count=$(grep <<<"$blocked_ps" "^-- blocked" | wc -l | tr -d ' ')
if [ "$blocked_ob_count" = "$blocked_ps_count" ]; then
    echo "  ok  blocked-pressure: obligations blocked count ($blocked_ob_count) matches proof-status"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL blocked-pressure: obligations blocked count ($blocked_ob_count) != proof-status ($blocked_ps_count)"
    evidence_fail=$((evidence_fail + 1))
fi

# 78. Blocked: proof-status totals line shows blocked count
if grep <<<"$blocked_ps" -q "5 blocked"; then
    echo "  ok  blocked-pressure: totals line shows 5 blocked"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL blocked-pressure: totals line should show 5 blocked"
    evidence_fail=$((evidence_fail + 1))
fi


# 81. Boundary: combo_profile shows both source and profile reasons
if grep <<<"$boundary_ps" -A6 "combo_profile" | grep "has capabilities: Alloc" | has_match "recursion (direct)"; then
    echo "  ok  boundary-pressure: combo_profile shows both source and profile reasons"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL boundary-pressure: combo_profile should show both source and profile reasons"
    evidence_fail=$((evidence_fail + 1))
fi

# 82. Boundary: consistency check passes for ineligible pressure set
inelig_con=$($COMPILER "$INELIG_SRC" --report consistency 2>&1 || true)
if grep <<<"$inelig_con" -q "All.*pass\|0 failures"; then
    echo "  ok  boundary-pressure: consistency check passes for ineligible functions"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL boundary-pressure: consistency check should pass for ineligible functions"
    echo "    $(grep <<<"$inelig_con" -i "fail" | awk "NR<=3")"
    evidence_fail=$((evidence_fail + 1))
fi

# 83. Boundary: consistency check passes for blocked functions
blocked_con=$($COMPILER "$BLOCKED_SRC" --report consistency 2>&1 || true)
if grep <<<"$blocked_con" -q "All.*pass\|0 failures"; then
    echo "  ok  boundary-pressure: consistency check passes for blocked functions"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL boundary-pressure: consistency check should pass for blocked functions"
    echo "    $(grep <<<"$blocked_con" -i "fail" | awk "NR<=3")"
    evidence_fail=$((evidence_fail + 1))
fi

# 84. Boundary: diagnostics-json includes unsupported field for blocked functions
blocked_json=$($COMPILER "$BLOCKED_SRC" --report diagnostics-json 2>/dev/null)
if echo "$blocked_json" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
blocked = [f for f in data['facts'] if f.get('kind') == 'proof_status' and f.get('state') == 'blocked']
assert len(blocked) > 0, 'no blocked facts'
for b in blocked:
    assert 'unsupported' in b, f'missing unsupported field in {b[\"function\"]}'
    assert len(b['unsupported']) > 0, f'empty unsupported for {b[\"function\"]}'
" 2>/dev/null; then
    echo "  ok  boundary-pressure: diagnostics-json includes unsupported field for blocked"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL boundary-pressure: diagnostics-json should include unsupported field for blocked"
    evidence_fail=$((evidence_fail + 1))
fi

# 85. Boundary: diagnostics-json includes profile_gates for ineligible functions
inelig_json=$($COMPILER "$INELIG_SRC" --report diagnostics-json 2>/dev/null)
if echo "$inelig_json" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
inelig = [f for f in data['facts'] if f.get('kind') == 'proof_status' and f.get('state') == 'ineligible']
assert len(inelig) > 0, 'no ineligible facts'
for i in inelig:
    assert 'profile_gates' in i, f'missing profile_gates in {i[\"function\"]}'
    assert len(i['profile_gates']) > 0, f'empty profile_gates for {i[\"function\"]}'
" 2>/dev/null; then
    echo "  ok  boundary-pressure: diagnostics-json includes profile_gates for ineligible"
    evidence_pass=$((evidence_pass + 1))
else
    echo "  FAIL boundary-pressure: diagnostics-json should include profile_gates for ineligible"
    evidence_fail=$((evidence_fail + 1))
fi


if [ "$evidence_fail" -gt 0 ]; then
    echo "  $evidence_fail evidence gate failures"
fi
echo "  $evidence_pass evidence gates passed"
PASS=$((PASS + evidence_pass))
FAIL=$((FAIL + evidence_fail))
:
}
