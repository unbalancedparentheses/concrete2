#!/usr/bin/env bash
# Pure-core proof arc, slice 1 (docs/verification/PURE_CORE_PROOF_ARC.md): the stdlib's
# first kernel-backed proof link, held to the arc's Definition of Done —
# registered + fingerprint-fresh + kernel-verified + MUTATION-SENSITIVE.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fresh.sh"
require_fresh_binary || exit 1
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
C=".lake/build/bin/concrete"
[ -x "$C" ] || { echo "error: build first" >&2; exit 2; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# std IS A PACKAGE AND IS NOW COMPILED AS ONE. This gate used to copy `std/src` to a temp directory
# and compile the loose tree, because `loadProject` refused a package whose entry is `src/lib.con`.
# That workaround DESTROYED the package identity, which is the thing scoped evidence depends on — so
# after the Package 2 authority transition every std subject carried a source name only and its
# correspondence and dependency root refused. The 11-proved figure this gate asserted was obtainable
# only by bypassing scoped evidence.
#
# The underlying bug (a package injected as its own dependency) was fixed 2026-08-16, so the copy is
# gone and std is compiled in place.
st=$("$C" std/src/lib.con --report proof-status 2>&1)

# WHAT THESE LINKS ARE WORTH NOW, re-pinned 2026-08-16 to the measured truth rather than to a number
# that was only obtainable by bypassing scoped evidence.
#
# Nine of the eleven links report `dependency closure unjustified`. That is DELIBERATE and it is not
# a regression from the package fix: their theorems depend on `pureCoreFns`, which carries no
# manifest row and therefore describes no definitions and justifies nothing — the same disposition
# Package 2 gave `proofFns` and `proofFnsExt`. A table without a manifest row cannot witness a
# per-edge justification, so a claim resting on one cannot be proved. Asserting these nine as
# `proved` would require re-adopting the de-packaged compilation that made the refusal invisible.
#
# The two base64 links DO prove, and they are the live positive control: without them "nine are
# unjustified" would also be satisfied by std carrying no evidence at all.
for fn in std.option.option_Option_unwrap_or std.option.option_Option_map \
          std.result.result_Result_map std.result.result_Result_map_err \
          std.numeric.numeric_NonZeroU32_try_new \
          std.numeric.numeric_NonZeroU32_try_from_u64 \
          std.numeric.numeric_NonZeroU64_try_new \
          std.numeric.numeric_Port_try_new \
          std.numeric.numeric_Port_try_from_u32; do
  grep -q "\`$fn\` cannot contribute proved evidence" <<<"$st" \
    && ok "$fn: unjustified because pureCoreFns has no manifest row (expected)" \
    || no "$fn: no longer reports an unjustified closure — if pureCoreFns was converted, re-pin these nine to proved"
done
for fn in std.base64.base64_char_of std.base64.base64_val_of; do
  grep -q "✓ \`$fn\` — proof matches current body" <<<"$st" \
    && ok "$fn: registered + fingerprint-fresh (the control the nine above are measured against)" \
    || no "$fn: proof link missing or stale — the unjustified assertions above are now vacuous"
done

# THE TRIPWIRE ON THE DEFERRAL. The nine are unjustified only while `pureCoreFns` is unconverted.
# The day it gains a manifest row this must go red, so the std arc is re-pinned rather than quietly
# staying at two.
if "$C" examples/elf_header/src/main.con --report subject-facts >/dev/null 2>&1; then
  PCF="$(cat > "$TMP/pcf.lean" <<'LEAN'
import Concrete
open Concrete.Proof
#eval (scopedEntryEvidence pureCoreFns).toOption == some []
LEAN
  lake env lean "$TMP/pcf.lean" 2>&1 || true)"
  if grep -q 'true' <<<"$PCF"; then
    ok "TRIPWIRE: pureCoreFns still has empty scoped membership, so the nine cannot be justified yet"
  else
    no "pureCoreFns now carries scoped membership — the nine std links must be re-pinned to proved"
  fi
fi

# 1c. every std proved link is SPEC-DRIFT-COVERED — the specs table is keyed
#     by qualified name and proof-status witnesses the lookup (a mis-keyed
#     spec silently skips the drift check; slice 2 made that state visible).
drift_ok=$(grep -c "spec: drift-checked" <<<"$st")
drift_no=$(grep -c "spec: NOT drift-covered" <<<"$st")
# Drift coverage is reported for links that can carry evidence, so it follows the nine into the
# unjustified state. Pinned at the measured 2 with 0 UNCOVERED: an uncovered link would be a
# mis-keyed spec silently skipping its drift check, which is a different and real defect.
[ "$drift_ok" -eq 2 ] && [ "$drift_no" -eq 0 ] \
  && ok "drift coverage: both justifiable std links are drift-checked, none uncovered" \
  || no "drift coverage: expected 2 drift-checked / 0 uncovered, got $drift_ok/$drift_no"

# 2. the Lean kernel verifies the referenced theorems (import-reachable)
cp=$("$C" std/src/lib.con --report check-proofs 2>&1)
if grep -q '✓ std.option.option_Option_unwrap_or — Examples.PureCore.Proofs.option_unwrap_or_correct' <<<"$cp"; then
  no "std.option.option_Option_unwrap_or is kernel-verified again — it was unjustified, so re-pin the std arc"
elif grep -q 'Examples.PureCore.Proofs.option_unwrap_or_correct' <<<"$cp"; then
  no "std.option.option_Option_unwrap_or entered the replay set but did not verify — that is a real kernel failure"
else
  ok "std.option.option_Option_unwrap_or: not replayed, because an unjustified claim is not a replay target"
fi
if grep -q '✓ std.option.option_Option_map — Examples.PureCore.Proofs.option_map_correct' <<<"$cp"; then
  no "std.option.option_Option_map is kernel-verified again — it was unjustified, so re-pin the std arc"
elif grep -q 'Examples.PureCore.Proofs.option_map_correct' <<<"$cp"; then
  no "std.option.option_Option_map entered the replay set but did not verify — that is a real kernel failure"
else
  ok "std.option.option_Option_map: not replayed, because an unjustified claim is not a replay target"
fi
if grep -q '✓ std.result.result_Result_map — Examples.PureCore.Proofs.result_map_correct' <<<"$cp"; then
  no "std.result.result_Result_map is kernel-verified again — it was unjustified, so re-pin the std arc"
elif grep -q 'Examples.PureCore.Proofs.result_map_correct' <<<"$cp"; then
  no "std.result.result_Result_map entered the replay set but did not verify — that is a real kernel failure"
else
  ok "std.result.result_Result_map: not replayed, because an unjustified claim is not a replay target"
fi
if grep -q '✓ std.result.result_Result_map_err — Examples.PureCore.Proofs.result_map_err_correct' <<<"$cp"; then
  no "std.result.result_Result_map_err is kernel-verified again — it was unjustified, so re-pin the std arc"
elif grep -q 'Examples.PureCore.Proofs.result_map_err_correct' <<<"$cp"; then
  no "std.result.result_Result_map_err entered the replay set but did not verify — that is a real kernel failure"
else
  ok "std.result.result_Result_map_err: not replayed, because an unjustified claim is not a replay target"
fi
for pair in "numeric_NonZeroU32_try_new:numeric_try_new_correct" \
            "numeric_NonZeroU32_try_from_u64:nonzero_u32_try_from_u64_correct" \
            "numeric_NonZeroU64_try_new:numeric_try_new_correct" \
            "numeric_Port_try_new:numeric_try_new_correct" \
            "numeric_Port_try_from_u32:port_try_from_u32_correct"; do
  fn=${pair%%:*}; thm=${pair##*:}
  if grep -q "✓ std.numeric.$fn — Examples.PureCore.Proofs.$thm" <<<"$cp"; then
    no "$fn is kernel-verified again — it was unjustified, so re-pin the std arc"
  elif grep -q "Examples.PureCore.Proofs.$thm" <<<"$cp"; then
    no "$fn entered the replay set but did not verify — that is a real kernel failure"
  else
    ok "$fn: not replayed, because an unjustified claim is not a replay target"
  fi
done
grep -q '✓ std.base64.base64_char_of — Examples.PureCore.Proofs.base64_char_of_correct' <<<"$cp" \
  && ok "base64.char_of: kernel-verified" \
  || no "base64.char_of: kernel check failed or theorem unreachable"
grep -q '✓ std.base64.base64_val_of — Examples.PureCore.Proofs.base64_val_of_correct' <<<"$cp" \
  && ok "base64.val_of: kernel-verified" \
  || no "base64.val_of: kernel check failed or theorem unreachable"
# EXACTLY the two justifiable links, and ZERO failures. The count moved from 11 to 2 when std began
# compiling as a package: nine claims rest on `pureCoreFns`, which has no manifest row, so they are
# not replay targets. Zero failures still matters — a link that entered the set and was refused is a
# real kernel failure, distinct from one that was never asked about.
grep -q 'Summary: 2 verified, 0 failed' <<<"$cp" \
  && ok "check-proofs: exactly 2 verified, zero failures" \
  || no "check-proofs count drifted or reports failures: $(grep -o 'Summary:.*' <<<"$cp" | head -1)"

# 3. MUTATION: a body change must go STALE (evidence is load-bearing)
# The mutation needs a WRITABLE copy, and it must be a copy of the PACKAGE — `Concrete.toml` and
# all — because a loose source tree has no package identity and would reproduce the very bypass
# this gate stopped relying on.
cp -r std "$TMP/stdpkg"
perl -0pi -e 's/Option::None => \{ return default; \},/Option::None => { let d2: T = default; return d2; },/' "$TMP/stdpkg/src/option.con"
mst=$("$C" "$TMP/stdpkg/src/lib.con" --report proof-status 2>&1)
grep -q 'stale fingerprint for .std.option.option_Option_unwrap_or' <<<"$mst" \
  && ok "mutation: body change flagged stale (fingerprint machinery live)" \
  || no "mutation: body change NOT flagged — evidence is decorative"

# 4. trusted fns stay excluded from proof links (the honesty boundary):
#    bytes.view carries a kernel-checked MODEL theorem but no registry link.
grep -q '#\[proof_by' std/src/bytes.con \
  && no "bytes.view carries proof_by attributes (trusted fns must not link)" \
  || ok "bytes.view: model-refined comment only (trusted boundary visible)"
grep -q "bytes_view_guard_correct" proofs/Examples/PureCore/Proofs.lean \
  && ok "bytes.view model theorem present (kernel-checked in Examples lib)" \
  || no "bytes.view model theorem missing"

# 5. the H1 radix guard-step fact: same pattern (step lemma is not a
#    whole-function spec, so no registry link — comment + kernel theorem).
grep -qE '^\s*#\[proof_by' std/src/parse.con \
  && no "parse.con carries proof_by attributes (step lemma must not claim a whole-fn link)" \
  || ok "parse_hex: guard-step comment only (no whole-loop overclaim)"
grep -q "hex_guard_step_preserves_u64" proofs/Examples/PureCore/Proofs.lean \
  && ok "H1 guard-step lemma present (kernel-checked, by omega)" \
  || no "H1 guard-step lemma missing"
grep -q "hex_guard_step_preserves_u64" std/src/parse.con \
  && ok "parse_hex source comment references the lemma" \
  || no "parse_hex source comment missing lemma reference"

# 6. PureCore slice 3 — Bytes::index_of / Bytes::slice (workloads 5/7/8):
#    model-refinement class like bytes.view — kernel theorems + source
#    comments, NEVER registry links (both are trusted raw-pointer impls).
for thm in bytes_slice_guard_correct bytes_index_of_step_correct \
           index_of_scan_step_preserves_bounds index_of_hit_in_range \
           slice_copy_step_in_bounds; do
  grep -q "$thm" proofs/Examples/PureCore/Proofs.lean \
    && ok "slice-3 theorem present: $thm" \
    || no "slice-3 theorem missing: $thm"
done
grep -q "bytes_index_of_step_correct" std/src/bytes.con \
  && ok "index_of source comment references its model theorem" \
  || no "index_of source comment missing"
grep -q "bytes_slice_guard_correct" std/src/bytes.con \
  && ok "slice source comment references its model theorem" \
  || no "slice source comment missing"

# 6. the alphabet ROUNDTRIP corollary (encode-then-decode identity) is
#    kernel-present and referenced from the base64 source.
grep -q "base64_alphabet_roundtrip" proofs/Examples/PureCore/Proofs.lean \
  && ok "base64 roundtrip theorem present (kernel-checked)" \
  || no "base64 roundtrip theorem missing"
grep -q "base64_alphabet_roundtrip" std/src/base64.con \
  && ok "base64 source comment references the roundtrip" \
  || no "base64 source comment missing roundtrip reference"

echo
echo "PURECORE-PROOFS: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
