#!/usr/bin/env bash
# Non-arithmetic multi-kernel gate (branch spike/non-arithmetic-multi-kernel).
#
# Every other kernel-agreement gate in this repo is LINEAR INTEGER ARITHMETIC: omega, lia,
# presburger. Three mature decision procedures for one theory. This gate carries BOOLEAN
# postconditions to the same three kernels, where each must use a different procedure —
# `destruct; reflexivity` (Rocq), `auto` (Isabelle/HOL), `decide` (Lean) — so agreement is not
# three invocations of the same idea.
#
# Two things this tier has that the arithmetic tier does not:
#
#   1. Reference-evaluator agreement is EXHAUSTIVE (all 2^n assignments), not sampled. A kernel
#      cannot close a lowering that means something else without this gate noticing.
#   2. The Rocq proofs are CONSTRUCTIVE, verified by `Print Assumptions` reporting
#      "Closed under the global context". Lowering Concrete `bool` to Rocq `Prop` instead would
#      make De Morgan need classical logic and put an axiom in an attestation.
#
# WHY THIS GATE RUNS THE GENERATED SCRIPTS rather than trusting the in-Lean `rfl` locks: the
# locks passed while the emitted Rocq did not compile at all (`&&` needs `bool_scope`), and
# again while `xor` was a type error (`negb (a = b)` — `a = b` is a `Prop`). Both were found
# here and only here.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
BIN="./.lake/build/bin/concrete"
DEMO="examples/bool_kernel_demo/src/main.con"
PASS=0; FAIL=0; INCONC=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
# "I could not test it" and "it is wrong" are different facts; conflating them is the failure
# this repo's other prover gates are careful about, so the count is in the summary line.
inconc(){ echo "  INCONC $1"; INCONC=$((INCONC+1)); }

lake build >/dev/null 2>&1 || { echo "FAIL build failed"; exit 1; }
[ -x "$BIN" ] || { echo "FAIL $BIN missing"; exit 1; }
[ -f "$DEMO" ] || { echo "FAIL $DEMO missing"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPORT="$WORK/report.txt"
"$BIN" "$DEMO" --report bool-kernel > "$REPORT" 2>&1

echo "=== the obligations are non-arithmetic, and the tier says so ==="
grep -q "EXHAUSTIVE" "$REPORT" \
  && ok "the report states agreement is exhaustive, not sampled" \
  || no "the exhaustiveness claim is gone"
# No arithmetic tactic may appear: if lia/presburger/omega shows up, this is not a
# non-arithmetic tier any more.
if grep -qE "\blia\b|\bpresburger\b|\bomega\b|ZArith" "$REPORT"; then
  no "an ARITHMETIC tactic or ZArith appears — the non-arithmetic claim is false"
else
  ok "no arithmetic tactic and no ZArith in any lowering"
fi

echo "=== reference evaluator: exhaustive, and it discriminates ==="
NHOLD="$(grep -c "holds on every assignment" "$REPORT")"
[ "$NHOLD" = "4" ] \
  && ok "4 obligations hold on every assignment (got $NHOLD)" \
  || no "expected 4 exhaustively-true obligations, got $NHOLD"
grep -q "wrong_post#boolpost0\]  reference evaluator: FALSE" "$REPORT" \
  && ok "the WRONG postcondition is caught before any kernel is asked" \
  || no "a false postcondition is not being caught by the reference evaluator"
# Coverage must be stated: a function this tier cannot handle is NAMED, not silently absent.
grep -q "multi_stmt: body is not a single" "$REPORT" \
  && ok "a function outside the tier is named, not silently skipped" \
  || no "skipped functions are not reported — coverage can be over-read"

# ---- extract the generated per-kernel sources -------------------------------------------
python3 - "$REPORT" "$WORK" <<'PY'
import re, sys
report, work = sys.argv[1], sys.argv[2]
txt = open(report).read()
names = []
for b in re.split(r"\n  \[", txt)[1:]:
    name = b.split("]")[0].split(".")[1].split("#")[0]
    names.append(name)
    m = re.search(r"--- rocq:destruct ---\n(.*?)\n(?=    --- isabelle)", b, re.S)
    if m: open(f"{work}/{name}.v", "w").write(m.group(1).strip() + "\n")
    mi = re.search(r"--- isabelle:auto ---\n(.*?)\nend", b, re.S)
    if mi:
        thy = (mi.group(1) + "\nend").replace("theory BoolPost", f"theory Thy_{name}")
        open(f"{work}/Thy_{name}.thy", "w").write(thy.strip() + "\n")
    ml = re.search(r"lean:decide goal: (.*)", b)
    if ml: open(f"{work}/{name}.lean", "w").write(f"theorem bp : {ml.group(1).strip()} := by decide\n")
open(f"{work}/names.txt", "w").write("\n".join(names))
# TRUE goals only in the Isabelle session; the false one is built separately as a control.
true_names = [n for n in names if n != "wrong_post"]
open(f"{work}/ROOT", "w").write("session BK = HOL +\n  theories\n" +
                                "".join(f"    Thy_{n}\n" for n in true_names))
PY
TRUE_FNS="nand nor and3 xor"

echo "=== LEAN (decide): the four close, the false one is REFUSED ==="
LCLOSED=0
for t in $TRUE_FNS; do
  if timeout 300 lake env lean "$WORK/$t.lean" >/dev/null 2>&1; then LCLOSED=$((LCLOSED+1)); fi
done
[ "$LCLOSED" = "4" ] \
  && ok "lean:decide closed all 4 boolean goals" \
  || no "lean:decide closed only $LCLOSED of 4"
if timeout 300 lake env lean "$WORK/wrong_post.lean" >/dev/null 2>&1; then
  no "lean:decide CLOSED the false postcondition — the tier has no teeth"
else
  ok "lean:decide refuses the false postcondition"
fi

echo "=== ROCQ (destruct/reflexivity) + AXIOM-FREEDOM ==="
if command -v coqc >/dev/null 2>&1; then
  RCLOSED=0; RAXFREE=0
  for t in $TRUE_FNS; do
    O="$( cd "$WORK" && coqc "$t.v" 2>&1 )"
    echo "$O" | grep -q "Closed under the global context" && RAXFREE=$((RAXFREE+1))
    echo "$O" | grep -qiE "^error|error:" || RCLOSED=$((RCLOSED+1))
  done
  [ "$RCLOSED" = "4" ] \
    && ok "rocq closed all 4 (the GENERATED scripts, not hand-written ones)" \
    || no "rocq closed only $RCLOSED of 4 — the emitted script is wrong"
  [ "$RAXFREE" = "4" ] \
    && ok "all 4 are axiom-free (Print Assumptions: closed under the global context)" \
    || no "only $RAXFREE of 4 are axiom-free — a classical axiom leaked into an attestation"
  WO="$( cd "$WORK" && coqc wrong_post.v 2>&1 )"
  if echo "$WO" | grep -qi "unable to unify"; then
    ok "rocq refuses the false postcondition (Unable to unify)"
  else
    no "rocq did not refuse the false postcondition"
  fi
else
  inconc "coqc not on PATH — run under \`nix develop .#provers\` for the Rocq assertions"
fi

echo "=== ISABELLE/HOL (auto) ==="
if command -v isabelle >/dev/null 2>&1; then
  IO_OUT="$( cd "$WORK" && isabelle build -D . 2>&1 )"
  printf '%s' "$IO_OUT" | grep -q "^Finished" \
    && ok "isabelle closed all 4 boolean goals with \`auto\`" \
    || no "isabelle did not finish the session — the emitted theory is wrong"
  # The false control as its own session, so its failure cannot be confused with a real one.
  mkdir -p "$WORK/ctl"
  sed 's/theory Thy_wrong_post/theory Thy_ctl/' "$WORK/Thy_wrong_post.thy" > "$WORK/ctl/Thy_ctl.thy" 2>/dev/null
  printf 'session CTL = HOL +\n  theories\n    Thy_ctl\n' > "$WORK/ctl/ROOT"
  CO="$( cd "$WORK/ctl" && isabelle build -D . 2>&1 )"
  if printf '%s' "$CO" | grep -qE "Failed to finish proof|FAILED"; then
    ok "isabelle refuses the false postcondition"
  else
    no "isabelle did not refuse the false postcondition"
  fi
else
  inconc "isabelle not on PATH — run under \`nix develop .#provers\` for the HOL assertions"
fi

echo "=== the sort choice is load-bearing, not cosmetic ==="
# Concrete `bool` -> Rocq `bool`. Over `Prop`, De Morgan needs classical logic and
# `Print Assumptions` would report it. The generated scripts must therefore never open ZArith
# nor state the lemma over Prop.
grep -q "Open Scope bool_scope" "$REPORT" \
  && ok "the Rocq lowering opens bool_scope (required for && and ||)" \
  || no "bool_scope is gone — the emitted script will not compile"
grep -q "From Stdlib Require Import Bool" "$REPORT" \
  && ok "and imports Bool (required for nested boolean equality \`eqb\`)" \
  || no "the Bool import is gone — a nested equality will be a Prop/bool type error"

echo ""
echo "BOOL-KERNEL: PASS=$PASS  FAIL=$FAIL  INCONC=$INCONC"
[ "$FAIL" -eq 0 ]
