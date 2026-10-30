#!/usr/bin/env bash
# The dead-code ratchet: the compiler does not grow declarations nothing can reach, and the known
# ones only get fewer (cleanup item 15).
#
# A declaration no executable, theorem, proof or tool reaches is code nobody runs and nobody
# proves anything about: it still has to build, be read, be kept total, and be migrated by every
# refactor. This gate holds the set where it is and lets it only shrink:
#
#   1. scripts/tools/dead_code_inventory.lean walks the ELABORATED environment (macro, `deriving`,
#      `match` and `partial` auxiliaries are references a grep cannot see) and computes what is
#      reachable from the roots: the executables' `main`, every user theorem, everything the
#      proof libraries (Examples, DesignExamples) declare, @[export]/@[extern]/initialize/simp/
#      syntax declarations, instances whose types are live, the generated data modules, values of
#      the types a generator enumerates by reflection (PFnDef, SpecDecl), the
#      identifiers of `#guard`/`#eval`/`example` commands and of the Lean files outside the
#      libraries (scripts/tools/dead_code_ratchet.py roots), and the string-referenced allowlist
#      docs/compiler/dead_code_allowlist.tsv;
#   2. scripts/tools/dead_code_ratchet.py compares the unreachable ones with
#      docs/compiler/dead_code_baseline.tsv, and that baseline with the base revision's:
#      an unreachable declaration not in the baseline FAILS; a baseline row that is reachable or
#      gone FAILS until deleted; a row the base revision's baseline lacks FAILS (the baseline only
#      shrinks); an allowlist row that is not needed (reachable without it), names nothing, or whose
#      file does not mention the name FAILS.
#
# Controls, each must hold or the gate fails:
#   C1  the finder on a known source (--control): exactly the expected reachability, so a planted
#       unused def and its only caller, a dead structure and inductive with their derived
#       instances, and user-written defs whose names look generated (`orphan.ofNat`,
#       `orphan._helper`: provenance, not the name, makes an auxiliary) are unreachable; a def used only by a theorem, only through an equation lemma,
#       only from a `partial def`'s body, only through a `where` helper, only from a `#guard`, or
#       only through the allowlist is reachable;
#   C2  a planted NEW unreachable declaration fails the comparison;
#   C3  a baseline row whose declaration is reachable fails; C4 one whose declaration is gone fails;
#   C5  a baseline row the base revision did not have fails;
#   C6  an allowlist row for a declaration reachable without it fails;
#   C7  an allowlist row whose file does not mention the name fails;
#   C8  two declarations that normalize to one name, one of them unreachable, fail instead of
#       merging (all reachable is harmless: generated and macro-scoped names repeat).
#   C9  an allowlist row citing a compiler source (not a script or test) fails.
# C2-C9 are synthetic (planted rows), so they hold with any baseline, an empty one included.
# And the walk is not vacuous: every compiler module that declares anything contributed.
#
# Requires the compiler and proof libraries built (it runs `lake build` first, a no-op when current).
# Usage: scripts/tests/check_dead_code_ratchet.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/gate_env.sh" || exit 2
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TOOL="scripts/tools/dead_code_inventory.lean"
RATCHET="scripts/tools/dead_code_ratchet.py"
# Generated data modules (scripts/gen): roots, since nobody writes their references by hand.
GENERATED=(Concrete.BuildIdentity Concrete.Proof.ClassificationTable Concrete.Proof.GeneratedAttestations)
# Types whose every value a tool enumerates by reflection: scripts/gen/classifications.lean reads
# each `PFnDef` and `SpecDecl` in the environment with evalConst (the spec bindings, bug 079).
ROOT_TYPES=(Concrete.Proof.PFnDef Concrete.Proof.SpecDecl)

# Browser.lean, the concrete-browser-native root, is a third executable (check_browser_native.sh
# builds it): its own declarations are candidates and its `main` is a root, in a walk of its own.
mapfile -t SRCS < <(git ls-files 'Concrete.lean' 'Concrete/*.lean' 'Main.lean' 'Browser.lean')
MODS=(); for f in "${SRCS[@]}"; do m="${f%.lean}"; MODS+=("${m//\//.}"); done
[ "${#MODS[@]}" -gt 0 ] || { echo "FAIL: no compiler modules found"; exit 1; }

echo "=== build the compiler and the proof libraries (the inventory reads their .olean files) ==="
if lake build "${MODS[@]}" Browser Examples DesignExamples > "$TMP/build.log" 2>&1; then ok "${#MODS[@]} modules, Browser and the proof libraries built"
else tail -20 "$TMP/build.log"; no "lake build failed"; echo "DEAD-CODE-RATCHET: PASS=$PASS FAIL=$FAIL"; exit 1; fi

echo "=== C1: the finder sees what it must on a known source ==="
lake env lean --run "$TOOL" --control > "$TMP/control.tsv" 2> "$TMP/control.err"
grep '	' "$TMP/control.tsv" | cut -f1,5,6 | LC_ALL=C sort > "$TMP/control.got"
LC_ALL=C sort > "$TMP/control.want" <<'EOF'
DeadS	0	0
DeadT	0	0
LiveS	1	1
allowOnly	0	1
deadCaller	0	0
deadLeaf	0	0
guardOnly	1	1
instBEqDeadS	0	0
instDecidableEqDeadT	0	0
instReprDeadS	0	0
instReprLiveS	1	1
liveLeaf	1	1
main	1	1
onlyEqLemma	1	1
orphan	0	0
orphan._helper	0	0
orphan.ofNat	0	0
partialLive	1	1
partialLive.twinOnly	1	1
readsField	1	1
usedByAllow	0	1
usedByTheorem	1	1
EOF
if cmp -s "$TMP/control.got" "$TMP/control.want"; then
  ok "control source: unused def/caller/structure/inductive/instances/generated-looking names unreachable; theorem/eq-lemma/partial/where/#guard/allowlist uses reachable"
else
  no "the finder's control output changed (< want, > got):"; diff "$TMP/control.want" "$TMP/control.got" | head -20
  head -5 "$TMP/control.err"
fi

echo "=== the compiler's reachability against the baseline ==="
python3 "$RATCHET" roots > "$TMP/roots.txt" || no "could not extract the text roots"
python3 "$RATCHET" allow-names > "$TMP/allow.txt" || no "could not read the allowlist"
ARGS=(--roots "$TMP/roots.txt" --allow "$TMP/allow.txt")
for g in "${GENERATED[@]}"; do ARGS+=(--root-module "$g"); done
for t in "${ROOT_TYPES[@]}"; do ARGS+=(--root-type "$t"); done
# THREE WALKS. Main, Concrete.Pipeline.PipelineTest and Browser each declare `main`, so one
# environment cannot import them together. The second walk imports PipelineTest alone, the third
# Browser alone; a declaration is reachable when any walk reaches it (dead_code_ratchet.py merges
# them).
SEPARATE="Concrete.Pipeline.PipelineTest"
MAIN_MODS=(); for m in "${MODS[@]}"; do [ "$m" = "$SEPARATE" ] || [ "$m" = Browser ] || MAIN_MODS+=("$m"); done
inventory_failed() { head -5 "$1"; no "the inventory tool failed"; echo "DEAD-CODE-RATCHET: PASS=$PASS FAIL=$FAIL"; exit 1; }
lake env lean --run "$TOOL" "${ARGS[@]}" "${MAIN_MODS[@]}" Examples DesignExamples > "$TMP/w1.tsv" 2> "$TMP/w1.err" || inventory_failed "$TMP/w1.err"
lake env lean --run "$TOOL" "${ARGS[@]}" "$SEPARATE" > "$TMP/w2.tsv" 2> "$TMP/w2.err" || inventory_failed "$TMP/w2.err"
lake env lean --run "$TOOL" "${ARGS[@]}" Browser > "$TMP/w3.tsv" 2> "$TMP/w3.err" || inventory_failed "$TMP/w3.err"
WALKS=(--walk "$TMP/w1.tsv" --walk "$TMP/w2.tsv" --walk "$TMP/w3.tsv")
missing=""
for i in "${!MODS[@]}"; do
  grep -qE '^(private |protected |noncomputable |partial |unsafe |@\[[^]]*\] )*(def|theorem|structure|inductive|abbrev|instance|class|opaque|axiom) ' "${SRCS[$i]}" || continue
  grep -qxF -- "$(printf 'visited\t%s' "${MODS[$i]}")" <(cut -f1,2 "$TMP/w1.err" "$TMP/w2.err" "$TMP/w3.err") || missing="$missing ${MODS[$i]}"
done
[ -z "$missing" ] && ok "the walk saw declarations from every declaring module (${#MODS[@]} asked for)" \
  || no "modules that declare things contributed nothing to the walk:$missing"

# THE BASELINE ONLY SHRINKS, against the base revision (the same rule as check_totality_ratchet.sh):
#   DEAD_CODE_BASE  set by CI on a push to the revision before the push (github.event.before); an
#                   all-zero value (a new ref) falls back to the merge-base.
#   no base given   merge-base(HEAD, origin/main); HEAD~1 when HEAD is already on origin/main;
#                   FAIL without origin/main rather than guess.
BASE="${DEAD_CODE_BASE:-}"
case "$BASE" in *[!0]*) ;; *) BASE="" ;; esac
BASE_ERR=""
if [ -z "$BASE" ]; then
  MB="$(git merge-base HEAD origin/main 2>/dev/null || true)"
  if [ -z "$MB" ]; then BASE_ERR="no merge-base with origin/main (fetch it, or set DEAD_CODE_BASE)"
  elif [ "$MB" != "$(git rev-parse HEAD)" ]; then BASE="$MB"
  else BASE="HEAD~1"; fi
fi
BASE_ARGS=()
if [ -n "$BASE_ERR" ]; then
  no "$BASE_ERR"
elif ! git rev-parse --verify -q "$BASE^{commit}" >/dev/null; then
  no "base revision '$BASE' does not resolve: fetch history (CI: fetch-depth 0) or set DEAD_CODE_BASE"
elif ! git cat-file -e "$BASE:docs/compiler/dead_code_baseline.tsv" 2>/dev/null; then
  ok "the base revision $(git rev-parse --short "$BASE") has no baseline: this change introduces it"
elif git show "$BASE:docs/compiler/dead_code_baseline.tsv" > "$TMP/base_baseline.tsv"; then
  BASE_ARGS=(--base-baseline "$TMP/base_baseline.tsv")
  ok "comparing the baseline with the base revision $(git rev-parse --short "$BASE")"
else
  no "the base revision's baseline exists but could not be read"
fi

if python3 "$RATCHET" check "${WALKS[@]}" "${BASE_ARGS[@]}" > "$TMP/check.out"; then
  ok "$(tail -1 "$TMP/check.out")"
else
  cat "$TMP/check.out"; no "the dead-code ratchet found the findings above"
fi

# A planted input must make the comparison fail with the named finding.
expect_fail() {  # $1 = label, $2 = substring the finding must contain, rest = extra check args
  local label="$1" want="$2"; shift 2
  if python3 "$RATCHET" check "$@" > "$TMP/neg.out" 2>&1; then
    no "$label: the ratchet accepted it"
  elif grep -qF -- "$want" "$TMP/neg.out"; then ok "$label"
  else no "$label: failed, but without '$want'"; head -5 "$TMP/neg.out"; fi
}
echo "=== negative controls on planted inputs ==="
# Synthetic, so they hold whatever the baseline holds (an empty one included): P is a planted
# unreachable declaration, L a reachable one from the real walk.
P="Concrete.deadCodePlantedControl"
printf '%s\tdef\tConcrete.IR.Lower\t1\t0\t0\n' "$P" > "$TMP/planted.tsv"
L="$(awk -F'\t' '$5 == 1 && $2 == "def" {print $1 "\t" $3; exit}' "$TMP/w1.tsv")"
Ld="$(cut -f1 <<<"$L")"; Lf="$(cut -f2 <<<"$L")"; Lf="${Lf//.//}.lean"
plus_row() { cat docs/compiler/dead_code_baseline.tsv; printf '%s\tdef\t%s\tdead\n' "$1" "$2"; }
expect_fail "C2 a planted unused def fails" "NEW unreachable declaration: def $P" \
  "${WALKS[@]}" --walk "$TMP/planted.tsv"
plus_row "$Ld" "$Lf" > "$TMP/c3_base.tsv"
expect_fail "C3 a baseline row whose declaration is reachable fails" "is reachable now" \
  "${WALKS[@]}" --baseline "$TMP/c3_base.tsv"
plus_row "Concrete.deadCodeNoSuchDeclaration" "Concrete/IR/Lower.lean" > "$TMP/c4_base.tsv"
expect_fail "C4 a baseline row whose declaration is gone fails" "no longer exists" \
  "${WALKS[@]}" --baseline "$TMP/c4_base.tsv"
plus_row "$P" "Concrete/IR/Lower.lean" > "$TMP/c5_base.tsv"
expect_fail "C5 a baseline row the base revision did not have fails" "baseline row ADDED: $P" \
  "${WALKS[@]}" --walk "$TMP/planted.tsv" --baseline "$TMP/c5_base.tsv" --base-baseline docs/compiler/dead_code_baseline.tsv
{ cat docs/compiler/dead_code_allowlist.tsv; printf '%s\t%s\tplanted\n' "$Ld" "scripts/tests/check_dead_code_ratchet.sh"; } > "$TMP/c6_allow.tsv"
expect_fail "C6 an allowlist row for a reachable declaration fails" "reachable without the allowlist" \
  "${WALKS[@]}" --allowlist "$TMP/c6_allow.tsv"
{ cat docs/compiler/dead_code_allowlist.tsv; printf '%s\t%s\tplanted\n' "$P" "tests/README.md"; } > "$TMP/c7_allow.tsv"
expect_fail "C7 an allowlist row whose file does not mention the name fails" "does not mention" \
  "${WALKS[@]}" --walk "$TMP/planted.tsv" --allowlist "$TMP/c7_allow.tsv"
# C8: a reachable declaration and an unreachable one under one key cannot be told apart.
dup="$(awk -F'\t' -v OFS='\t' '$6 == 1 {$5 = 0; $6 = 0; print; exit}' "$TMP/w1.tsv")"
{ cat "$TMP/w1.tsv"; printf '%s\n' "$dup"; } > "$TMP/c8.tsv"
expect_fail "C8 two declarations sharing a normalized name, one unreachable, are refused" "share the name" --walk "$TMP/c8.tsv" --walk "$TMP/w2.tsv"
# C9: an allowlist row may not cite compiler source (its own `def` would satisfy the mention check).
{ cat docs/compiler/dead_code_allowlist.tsv; printf '%s\t%s\tplanted\n' "$P" "Concrete/IR/Lower.lean"; } > "$TMP/c9_allow.tsv"
expect_fail "C9 an allowlist row citing compiler source fails" "is not a script or test" \
  "${WALKS[@]}" --walk "$TMP/planted.tsv" --allowlist "$TMP/c9_allow.tsv"
{ cat docs/compiler/dead_code_allowlist.tsv; printf '%s\t%s\tplanted\n' "$P" "scripts/../Concrete/IR/Lower.lean"; } > "$TMP/c9b_allow.tsv"
expect_fail "C9 ... nor reach it through a non-normal path" "is not a script or test" \
  "${WALKS[@]}" --walk "$TMP/planted.tsv" --allowlist "$TMP/c9b_allow.tsv"

echo "DEAD-CODE-RATCHET: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
