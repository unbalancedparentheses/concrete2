# malformed: the code units of tests/cases/malformed.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_malformed_1() {
mal_pass=0
mal_fail=0
MAL_DIR=$(mktemp -d)

# --- 1. Truncated snapshot JSON → explicit error, nonzero exit ---
echo '[{"kind":"effects","function":"foo"' > "$MAL_DIR/truncated.json"
echo '{"schema_version":2,"schema_kind":"facts","facts":[]}' > "$MAL_DIR/good.json"
mal_out=$($COMPILER diff "$MAL_DIR/truncated.json" "$MAL_DIR/good.json" 2>&1) && mal_exit=0 || mal_exit=$?
if [ "$mal_exit" -ne 0 ] && grep <<<"$mal_out" -q "error.*parse\|could not parse"; then
    echo "  ok  malformed: truncated snapshot JSON produces explicit error"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: truncated snapshot JSON should produce explicit error (exit=$mal_exit)"
    mal_fail=$((mal_fail + 1))
fi

# --- 2. Both snapshots truncated → errors for both ---
mal_out2=$($COMPILER diff "$MAL_DIR/truncated.json" "$MAL_DIR/truncated.json" 2>&1) && mal_exit2=0 || mal_exit2=$?
if [ "$mal_exit2" -ne 0 ]; then
    echo "  ok  malformed: two truncated snapshots produce error"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: two truncated snapshots should fail"
    mal_fail=$((mal_fail + 1))
fi

# --- 6. Malformed Concrete.toml dependency → warning ---
mkdir -p "$MAL_DIR/toml_bad/src"
cat > "$MAL_DIR/toml_bad/src/main.con" << 'CONEOF'
fn main() -> i32 { return 0; }
CONEOF
cat > "$MAL_DIR/toml_bad/Concrete.toml" << 'TOMLEOF'
[package]
name = "test"

[dependencies]
garbled line without equals

[policy]
unknown_future_key = true
predictable = false
TOMLEOF
mal_toml=$(cd "$MAL_DIR/toml_bad" && $ROOT_DIR/$COMPILER build 2>&1) && toml_exit=0 || toml_exit=$?
if grep <<<"$mal_toml" -q "warning.*Concrete.toml.*dependencies"; then
    echo "  ok  malformed: bad Concrete.toml dependency line produces warning"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: bad Concrete.toml dependency line should produce warning"
    echo "    output: $(echo "$mal_toml" | awk "NR<=3")"
    mal_fail=$((mal_fail + 1))
fi

# --- 7. Unrecognized Concrete.toml policy key → warning ---
if grep <<<"$mal_toml" -q "warning.*Concrete.toml.*policy.*unrecognized"; then
    echo "  ok  malformed: unrecognized policy key produces warning"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: unrecognized policy key should produce warning"
    mal_fail=$((mal_fail + 1))
fi

# --- 8. Diff with non-existent file → explicit diagnostic ---
mal_nofile=$($COMPILER diff "$TMPDIR/nonexistent_file_12345.json" "$MAL_DIR/good.json" 2>&1) && nofile_exit=0 || nofile_exit=$?
if [ "$nofile_exit" -ne 0 ] && grep <<<"$mal_nofile" -q "error: file not found"; then
    echo "  ok  malformed: diff with non-existent file produces explicit diagnostic"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: diff with non-existent file should produce 'file not found' diagnostic"
    echo "    output: $(echo "$mal_nofile" | awk "NR<=2")"
    mal_fail=$((mal_fail + 1))
fi

# --- 9. Snapshot facts with missing required fields → warnings ---
echo '{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"effects"},{"function":"bar"}]}' > "$MAL_DIR/missing_fields.json"
mal_fields=$($COMPILER diff "$MAL_DIR/missing_fields.json" "$MAL_DIR/good.json" 2>&1 || true)
if grep <<<"$mal_fields" -q "warning.*missing required.*function" && grep <<<"$mal_fields" -q "warning.*missing required.*kind"; then
    echo "  ok  malformed: snapshot facts with missing fields produce warnings"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: snapshot facts with missing fields should produce warnings"
    mal_fail=$((mal_fail + 1))
fi

# --- 10. Snapshot that is not an array/object → error ---
echo '"just a string"' > "$MAL_DIR/bad_type.json"
mal_type=$($COMPILER diff "$MAL_DIR/bad_type.json" "$MAL_DIR/good.json" 2>&1) && type_exit=0 || type_exit=$?
if [ "$type_exit" -ne 0 ] && grep <<<"$mal_type" -q "error"; then
    echo "  ok  malformed: non-array snapshot JSON produces error"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: non-array snapshot JSON should produce error"
    mal_fail=$((mal_fail + 1))
fi

# --- 11. Snapshot with duplicate fact keys → error ---
echo '{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"effects","function":"foo","no_external_authority":true},{"kind":"effects","function":"foo","no_external_authority":false}]}' > "$MAL_DIR/dupes.json"
mal_dupe=$($COMPILER diff "$MAL_DIR/dupes.json" "$MAL_DIR/good.json" 2>&1) && dupe_exit=0 || dupe_exit=$?
if [ "$dupe_exit" -ne 0 ] && grep <<<"$mal_dupe" -q "duplicate"; then
    echo "  ok  malformed: snapshot with duplicate keys produces error"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: snapshot with duplicate keys should produce error"
    mal_fail=$((mal_fail + 1))
fi

# --- 13. Bundle validation: missing manifest → error ---
mkdir -p "$MAL_DIR/bundle_no_manifest/source"
echo 'fn main() -> i32 { return 0; }' > "$MAL_DIR/bundle_no_manifest/source/main.con"
bun_no=$($COMPILER validate-bundle "$MAL_DIR/bundle_no_manifest" 2>&1) && bun_no_exit=0 || bun_no_exit=$?
if [ "$bun_no_exit" -ne 0 ] && grep <<<"$bun_no" -q "error.*manifest.json missing"; then
    echo "  ok  malformed: bundle without manifest produces error"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: bundle without manifest should produce error"
    mal_fail=$((mal_fail + 1))
fi

# --- 14. Bundle validation: corrupted manifest → error ---
mkdir -p "$MAL_DIR/bundle_bad_manifest/source"
echo 'fn main() -> i32 { return 0; }' > "$MAL_DIR/bundle_bad_manifest/source/main.con"
echo 'NOT JSON' > "$MAL_DIR/bundle_bad_manifest/manifest.json"
bun_bad=$($COMPILER validate-bundle "$MAL_DIR/bundle_bad_manifest" 2>&1) && bun_bad_exit=0 || bun_bad_exit=$?
if [ "$bun_bad_exit" -ne 0 ] && grep <<<"$bun_bad" -q "error.*not a valid JSON"; then
    echo "  ok  malformed: bundle with corrupted manifest produces error"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: bundle with corrupted manifest should produce error"
    mal_fail=$((mal_fail + 1))
fi

# --- 15. Bundle validation: partial manifest (missing fields) → warnings ---
mkdir -p "$MAL_DIR/bundle_partial/source"
echo 'fn main() -> i32 { return 0; }' > "$MAL_DIR/bundle_partial/source/main.con"
echo '{"version": 1}' > "$MAL_DIR/bundle_partial/manifest.json"
bun_part=$($COMPILER validate-bundle "$MAL_DIR/bundle_partial" 2>&1 || true)
if grep <<<"$bun_part" -q "warning.*missing.*source_path" && grep <<<"$bun_part" -q "warning.*missing.*artifacts"; then
    echo "  ok  malformed: bundle with partial manifest produces field warnings"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: bundle with partial manifest should produce field warnings"
    mal_fail=$((mal_fail + 1))
fi

# --- 16. Bundle validation: valid bundle passes ---
$COMPILER debug-bundle "$TESTDIR/bug_if_expression.con" -o "$MAL_DIR/valid_bundle" > /dev/null 2>&1
bun_ok=$($COMPILER validate-bundle "$MAL_DIR/valid_bundle" 2>&1 || true)
if grep <<<"$bun_ok" -q "is valid"; then
    echo "  ok  malformed: valid bundle passes validation"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: valid bundle should pass validation"
    echo "    output: $(echo "$bun_ok" | awk "NR<=3")"
    mal_fail=$((mal_fail + 1))
fi

# --- 17. Concrete.toml missing [package] → warning ---
mkdir -p "$MAL_DIR/toml_nopkg/src"
echo 'fn main() -> i32 { return 0; }' > "$MAL_DIR/toml_nopkg/src/main.con"
cat > "$MAL_DIR/toml_nopkg/Concrete.toml" << 'TOMLEOF'
[dependencies]
TOMLEOF
# THE EXIT CODE IS CAPTURED, and that is not incidental. This suite runs under `set -e`, so a bare
# `x=$(cmd)` whose command exits non-zero ends the ENTIRE trust gate right there — no summary, no
# failure line, just a truncated log and exit 1. That is what happened here: the whole gate died
# after "valid bundle passes validation" and reported nothing about the ~4000 lines that follow.
#
# A project with no [package] name now REFUSES rather than warning-and-building. That refusal is
# correct and pre-existing: definition identity is package-scoped, so a manifest that declares no
# name yields no scoped identity and no ProofCore, and building one would let unscoped definitions
# participate in evidence. It only became reachable when project detection was repaired — before
# that, running from inside a project silently fell back to standalone mode and never loaded the
# manifest at all.
#
# So both halves are asserted: the warning still names the problem, and the build refuses.
mal_nopkg=$(cd "$MAL_DIR/toml_nopkg" && $ROOT_DIR/$COMPILER build 2>&1) && nopkg_exit=0 || nopkg_exit=$?
if grep <<<"$mal_nopkg" -q "warning.*missing.*\[package\]" && [ "$nopkg_exit" -ne 0 ]; then
    echo "  ok  malformed: Concrete.toml without [package] warns and refuses (identity is package-scoped)"
    mal_pass=$((mal_pass + 1))
elif [ "$nopkg_exit" -eq 0 ]; then
    echo "  FAIL malformed: Concrete.toml without [package] BUILT successfully — an unnamed package has no scoped identity, so its definitions must not reach evidence"
    mal_fail=$((mal_fail + 1))
else
    echo "  FAIL malformed: Concrete.toml without [package] refused without naming the reason"
    echo "    output: $(echo "$mal_nopkg" | awk "NR<=3")"
    mal_fail=$((mal_fail + 1))
fi

# --- 18. Concrete.toml unknown section → warning ---
mkdir -p "$MAL_DIR/toml_unk/src"
echo 'fn main() -> i32 { return 0; }' > "$MAL_DIR/toml_unk/src/main.con"
cat > "$MAL_DIR/toml_unk/Concrete.toml" << 'TOMLEOF'
[package]
name = "test"

[alien_section]
foo = "bar"
TOMLEOF
# Exit code captured for the same reason as the [package] case above: an unhandled non-zero here
# would kill the suite rather than fail this test.
mal_unk=$(cd "$MAL_DIR/toml_unk" && $ROOT_DIR/$COMPILER build 2>&1) || true
if grep <<<"$mal_unk" -q "warning.*unrecognized section"; then
    echo "  ok  malformed: Concrete.toml with unknown section produces warning"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: Concrete.toml with unknown section should produce warning"
    mal_fail=$((mal_fail + 1))
fi

# --- 19. Bundle manifest with wrong field types → type errors ---
mkdir -p "$MAL_DIR/bundle_bad_types/source"
echo 'fn main() -> i32 { return 0; }' > "$MAL_DIR/bundle_bad_types/source/main.con"
cat > "$MAL_DIR/bundle_bad_types/manifest.json" << 'MEOF'
{
  "version": "oops",
  "source_path": 42,
  "failed_at": 999,
  "artifacts": {
    "core_ir": "yes",
    "mono_ir": "yes",
    "ssa_ir": "yes",
    "llvm_ir": "yes",
    "proof_core": "yes"
  }
}
MEOF
bun_types=$($COMPILER validate-bundle "$MAL_DIR/bundle_bad_types" 2>&1) && bun_types_exit=0 || bun_types_exit=$?
if [ "$bun_types_exit" -ne 0 ] && grep <<<"$bun_types" -q "\"version\" must be a number" && grep <<<"$bun_types" -q "\"source_path\" must be a string" && grep <<<"$bun_types" -q "must be a boolean"; then
    echo "  ok  malformed: bundle with wrong field types produces type errors"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: bundle with wrong field types should produce type errors"
    echo "    output: $(echo "$bun_types" | awk "NR<=3")"
    mal_fail=$((mal_fail + 1))
fi

# --- 24. Diff shows <missing> for absent fields, not empty string ---
echo '{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"effects","function":"foo","no_external_authority":true,"evidence":"enforced","capabilities":"[]","crosses_ffi":false,"is_trusted":false}]}' > "$MAL_DIR/diff_old.json"
echo '{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"effects","function":"foo","evidence":"enforced"}]}' > "$MAL_DIR/diff_new.json"
diff_out=$($COMPILER diff "$MAL_DIR/diff_old.json" "$MAL_DIR/diff_new.json" 2>&1) || true
if grep <<<"$diff_out" -q "<missing>"; then
    echo "  ok  malformed: diff reports <missing> for absent fields"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: diff should report <missing> for absent fields"
    mal_fail=$((mal_fail + 1))
fi

# --- 25. New fact with unknown kind classified as weakened ---
echo '{"schema_version":2,"schema_kind":"facts","facts":[]}' > "$MAL_DIR/drift_old.json"
echo '{"schema_version":2,"schema_kind":"facts","facts":[{"kind":"totally_unknown_kind","function":"bar"}]}' > "$MAL_DIR/drift_new.json"
drift_out=$($COMPILER diff "$MAL_DIR/drift_old.json" "$MAL_DIR/drift_new.json" 2>&1) || true
if grep <<<"$drift_out" -q "weakened"; then
    echo "  ok  malformed: unknown fact kind in new facts classified as weakened"
    mal_pass=$((mal_pass + 1))
else
    echo "  FAIL malformed: unknown fact kind should be classified as weakened, not neutral"
    mal_fail=$((mal_fail + 1))
fi

rm -rf "$MAL_DIR"

if [ "$mal_fail" -gt 0 ]; then
    echo "  $mal_fail malformed artifact test failures"
fi
echo "  $mal_pass malformed artifact tests passed"
PASS=$((PASS + mal_pass))
FAIL=$((FAIL + mal_fail))
:
}
