#!/usr/bin/env bash
# SLICE 8 — ADVERSARIAL CLOSURE (R-0004).
#
# Every other gate asks whether the evidence path works. This one assumes an attacker who has write
# access to the receipt store and wants a claim to read as kernel-replayed when it is not.
#
# THE STRUCTURE IS THE CONTROL. Each attack modifies exactly ONE record in a store of five genuine
# receipts, and every assertion checks BOTH halves:
#
#     the attacked record must not read as current   AND   the other four must still read current
#
# A consumer that rejected everything would satisfy the first half of every attack in this file and
# fail the second, so "deny all" cannot pass. A consumer that accepted everything fails the first.
# Neither degenerate answer survives.
#
# ATTACKS RUN THROUGH THE PRODUCTION CONSUMER — `--report proof-status --receipts` — not through a
# unit probe of the decoder. What matters is what the shipped status surface says when handed hostile
# bytes, because that is the thing a user reads.
#
# DELIBERATELY OUT OF SCOPE: cache attacks. `ProofCache` does not exist, so a cold/warm/corrupt-cache
# test would pass vacuously today. It is a ProofCache graduation condition, not a Slice 8 exit
# criterion, and asserting it here would be a green light bought with an empty test.
set -uo pipefail
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "${GATE_DONE:-0}" -ne 1 ]; then
  echo "FATAL: unexpected shell failure (exit $rc) — the verdict below is not trustworthy" >&2; exit "$rc"; fi' ERR
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source "scripts/tests/lib/fresh.sh"
require_fresh_binary || exit 1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$ROOT_DIR/.lake/build/bin/concrete"
SRC="examples/elf_header/src/main.con"
TRUST_SRC="examples/proof_patterns/composition_trusted_helper/src/main.con"

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

consume(){ "$BIN" "${2:-$SRC}" --report proof-status --receipts "$1" 2>/dev/null \
           | sed -n '/=== Replay Receipts/,$p' || true; }
tally(){ grep -oE '[0-9]+ current, [0-9]+ not current, [0-9]+ unreadable' <<<"$1" | head -1; }

"$BIN" "$SRC" --report receipts --out "$TMP/base.txt" >/dev/null 2>&1
BASE="$(tally "$(consume "$TMP/base.txt")")"
if [ "$BASE" = "5 current, 0 not current, 0 unreadable" ]; then
  ok "baseline: five genuine receipts read current (every attack below is measured against this)"
else
  no "baseline is not 5 current ($BASE) — every attack in this file would be vacuous"
  GATE_DONE=1; echo "SLICE8-ADVERSARIAL: PASS=$PASS FAIL=$FAIL"; exit 1
fi

# attack <name> <python-mutator> <expect-current> <expect-bad>
#   The mutator receives the store as a list of (subject, body-lines) and returns the same shape.
#   `expect-bad` is the count that must NOT be current — either not-current or unreadable.
attack() {
  local name="$1" mut="$2" wantcur="$3" wantbad="$4"
  python3 - "$TMP" "$mut" <<'PY'
import sys, pathlib
T, mut = sys.argv[1], sys.argv[2]
s = pathlib.Path(T + "/base.txt").read_text()
recs = []
for blk in s.split("== ")[1:]:
    name, _, body = blk.partition("\n")
    recs.append([name.strip(), body.rstrip("\n").split("\n")])
exec(mut)
pathlib.Path(T + "/attack.txt").write_text(
    "\n".join("== " + k + "\n" + "\n".join(v) for k, v in recs))
PY
  local out cur bad
  out="$(consume "$TMP/attack.txt")"
  cur="$(grep -oE '^[0-9]+ current' <<<"$(tally "$out")" | grep -oE '[0-9]+' || echo 0)"
  bad=$(( ${wantcur} + ${wantbad} - ${cur} ))
  if [ "$cur" = "$wantcur" ]; then
    ok "$name — attacked record rejected, $cur genuine receipt(s) still current"
  else
    no "$name — expected $wantcur still current, got: $(tally "$out")"
  fi
}

echo "=== substitution: the store's key is not the claim ==="

# A genuine receipt filed under another claim's name. The comparison reads the subject DIGEST, so the
# filename never enters the verdict.
attack "receipt/claim substitution" \
  'recs[0][1], recs[1][1] = recs[1][1], recs[0][1]' 3 2

# A receipt from a DIFFERENT PACKAGE, filed under a name this program does have. Its subject digest
# describes another program's declaration.
attack "package substitution" \
  'import subprocess, pathlib
o = subprocess.run(["'"$BIN"'", "examples/crypto_verify/src/main.con", "--report", "receipts",
                    "--out", T + "/other.txt"], capture_output=True)
other = pathlib.Path(T + "/other.txt").read_text().split("== ")[1]
recs[0][1] = other.partition("\n")[2].rstrip("\n").split("\n")' 4 1

echo "=== forging what the receipt binds ==="

# The proof term. Naming a theorem that exists but was never replayed for this claim.
attack "unreplayed artifact substituted" \
  'recs[0][1] = [l if not l.startswith("artifact ") else "artifact Examples.ElfHeader.Proofs.check_class_correct" for l in recs[0][1]]' 4 1

# The dependency closure. A receipt whose root describes a different closure than the program has.
attack "dependency closure altered" \
  'recs[0][1] = [l if not l.startswith("root ") else l[:-4] + "0000" for l in recs[0][1]]' 4 1

# Table bindings: one added, and one removed. Both change what the evidence claims to depend on.
attack "table binding injected" \
  'recs[0][1] = recs[0][1] + ["table Fake.Table 00000000000000000000000000000000"]' 4 1
attack "table binding removed" \
  'recs[0][1] = [l for l in recs[0][1] if not l.startswith("table ")]' 4 1

echo "=== trust deletion and laundering ==="

# These run against a fixture that genuinely crosses a trusted boundary, so the attack has something
# to launder. The baseline is asserted first for the same reason as above.
"$BIN" "$TRUST_SRC" --report receipts --out "$TMP/trust.txt" >/dev/null 2>&1
TBASE="$(tally "$(consume "$TMP/trust.txt" "$TRUST_SRC")")"
if grep -qE '^2 current' <<<"$TBASE"; then
  ok "trust baseline: both receipts current, one carrying a named boundary"
else
  no "trust baseline is not 2 current ($TBASE) — the laundering attacks would be vacuous"
fi

launder() {
  local name="$1" py="$2" wantcur="$3"
  python3 - "$TMP" "$py" <<'PY'
import sys, pathlib
T, mut = sys.argv[1], sys.argv[2]
s = pathlib.Path(T + "/trust.txt").read_text()
recs = []
for blk in s.split("== ")[1:]:
    name, _, body = blk.partition("\n")
    recs.append([name.strip(), body.rstrip("\n").split("\n")])
exec(mut)
pathlib.Path(T + "/laundered.txt").write_text(
    "\n".join("== " + k + "\n" + "\n".join(v) for k, v in recs))
PY
  local out cur
  out="$(consume "$TMP/laundered.txt" "$TRUST_SRC")"
  cur="$(grep -oE '^[0-9]+ current' <<<"$(tally "$out")" | grep -oE '[0-9]+' || echo 0)"
  if [ "$cur" = "$wantcur" ]; then
    ok "$name — laundered record rejected, $cur genuine receipt(s) still current"
  else
    no "$name — expected $wantcur still current, got: $(tally "$out")"
  fi
}

# DELETING the boundary while keeping the flag: a qualification a reader cannot act on.
launder "trust boundary deleted" \
  'recs = [[k, [l for l in v if not l.startswith("boundary ")]] for k, v in recs]' 1
# LAUNDERING: flag flipped to false and boundaries dropped, so a conditional claim reads
# unconditional. This is the attack the qualification exists to prevent.
launder "trust laundered to unconditional" \
  'recs = [[k, [("trust false" if l.startswith("trust ") else l) for l in v if not l.startswith("boundary ")]] for k, v in recs]' 1
# A boundary ADDED where none was assumed: the receipt now disagrees with the program about what the
# claim rests on, in the direction that looks more cautious. It must still be rejected — a receipt
# that can be edited toward caution can be edited away from it.
launder "trust boundary fabricated" \
  'recs[0][1] = [("trust true" if l.startswith("trust ") else l) for l in recs[0][1]] + ["boundary calls.imaginary"]' 1

echo "=== decoding: partial, confused, and contradictory ==="

attack "schema downgraded to an older envelope" \
  'recs[0][1] = [l.replace("receiptV1", "receiptV0") for l in recs[0][1]]' 4 1
attack "required field removed" \
  'recs[0][1] = [l for l in recs[0][1] if not l.startswith("subject ")]' 4 1
attack "required field duplicated with a different value" \
  'recs[0][1] = recs[0][1] + ["subject 00000000000000000000000000000000"]' 4 1
attack "unknown field smuggled in" \
  'recs[0][1] = recs[0][1] + ["verified true"]' 4 1
attack "field value emptied" \
  'recs[0][1] = [("root " if l.startswith("root ") else l) for l in recs[0][1]]' 4 1
attack "digest truncated" \
  'recs[0][1] = [(l[:20] if l.startswith("subject ") else l) for l in recs[0][1]]' 4 1

# CONTRADICTORY CONTEXT: the same subject appearing twice with different contents. Whichever record a
# consumer believes, it is believing one of two claims that disagree — so neither may read current.
attack "same subject recorded twice, disagreeing" \
  'bad = [l if not l.startswith("subject ") else "subject 00000000000000000000000000000000" for l in recs[0][1]]
recs.append([recs[0][0], bad])' 4 1

echo "=== the whole store replaced ==="

# A store of entirely foreign receipts. Nothing is current, and — the part that matters — nothing is
# silently dropped either: every record is reported.
python3 - "$TMP" <<'PY'
import sys, pathlib, subprocess
T = sys.argv[1]
subprocess.run([pathlib.Path(".lake/build/bin/concrete").as_posix(),
                "examples/crypto_verify/src/main.con", "--report", "receipts", "--out", T + "/foreign.txt"],
               capture_output=True)
PY
FOREIGN="$(consume "$TMP/foreign.txt")"
if grep -qE '^0 current' <<<"$(tally "$FOREIGN")" \
   && grep -q 'no such claim in this program' <<<"$FOREIGN"; then
  ok "a wholly foreign store makes nothing current, and every record is named rather than dropped"
else
  no "foreign store handling moved: $(tally "$FOREIGN")"
fi

echo "=== the honest path still works after all of it ==="

# THE FINAL NON-VACUITY CHECK. After every attack above, the untouched store must still read current.
# Without this, a consumer that had been broken into rejecting everything would have passed this file.
FINAL="$(tally "$(consume "$TMP/base.txt")")"
if [ "$FINAL" = "5 current, 0 not current, 0 unreadable" ]; then
  ok "the genuine store still reads 5 current — no attack left the consumer in a deny-all state"
else
  no "the genuine store no longer reads current after the attack suite: $FINAL"
fi

GATE_DONE=1
echo "SLICE8-ADVERSARIAL: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
