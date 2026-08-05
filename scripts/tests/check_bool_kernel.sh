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

# ============================ RUNG 5: EUF ============================
echo "=== EUF (rung 5): uninterpreted spec functions in three kernels ==="
EUFDEMO="examples/euf_kernel_demo/src/main.con"
if [ ! -f "$EUFDEMO" ]; then
  no "$EUFDEMO missing"
else
EW="$WORK/euf"; mkdir -p "$EW/n"
"$BIN" "$EUFDEMO" --report bool-kernel > "$EW/report.txt" 2>&1

# The symbol must be QUANTIFIED, never declared: a `Parameter`/`axiom` would enter the trusted
# base and `Print Assumptions` would report it, turning an axiom-free attestation into an
# axiom-bearing one.
if grep -qE "^Parameter |^Axiom |^axiom " "$EW/report.txt"; then
  no "a spec symbol is DECLARED (Parameter/Axiom) — that puts it in the trusted base"
else
  ok "spec symbols are quantified function variables, never declared"
fi

# Propositional abstraction is sound in ONE direction. It must never claim to refute: an earlier
# version reported "FALSE — no kernel should close it" for CONGRUENCE, the defining property of
# an uninterpreted function.
if grep -q "no kernel should close it" "$EW/report.txt"; then
  no "the abstraction claims to REFUTE — it cannot; it forgets that f is a function"
else
  ok "the abstraction only ever confirms (tautology) or reports inconclusive"
fi
grep -q "congruence#euf0\]" "$EW/report.txt" \
  && ok "a congruence obligation is collected" \
  || no "the congruence obligation is missing"
# Symmetry through an opaque term IS a tautology once equality atoms are normalised: `f m = t`
# and `t = f m` are one atom, and treating them as two made this look falsifiable.
awk '/sym_through_opaque#euf0/{f=1} f&&/abstraction:/{print;exit}' "$EW/report.txt" \
  | grep -q "tautology" \
  && ok "symmetry through an opaque term is a tautology (equality atoms are normalised)" \
  || no "equality atoms are not normalised — `f m = t` and `t = f m` count as two atoms"
# And congruence must be inconclusive, not a tautology — that is the documented incompleteness.
awk '/eufdemo.congruence#euf0/{f=1} f&&/abstraction:/{print;exit}' "$EW/report.txt" \
  | grep -q "inconclusive" \
  && ok "congruence is inconclusive under abstraction (the incompleteness, shown)" \
  || no "congruence is being reported as decided — the abstraction cannot decide it"

python3 - "$EW/report.txt" "$EW" <<'PYEUF'
import re, sys
report, work = sys.argv[1], sys.argv[2]
txt = open(report).read()
for b in re.split(r"\n  \[", txt)[1:]:
    if "#euf" not in b.split("]")[0]: continue
    name = b.split("]")[0].split(".")[1].split("#")[0]
    def sect(marker):
        # bounded by the NEXT marker, not end-of-block: an unbounded `.*?$` swallowed the other
        # kernels' sections and produced files that could not parse.
        m = re.search(r"--- " + marker + r" ---\n(.*?)(?=\n    ---|\Z)", b, re.S)
        return m.group(1).rstrip() if m else None
    for mk, ext in [("lean:by_cases", ".lean"), ("rocq:congruence", ".v")]:
        v = sect(mk)
        if v: open(f"{work}/{name}{ext}", "w").write(v + "\n")
    iv = sect(r"isabelle:auto \(euf\)")
    if iv:
        d = work + "/n" if name == "bad_constant" else work
        open(f"{d}/Thy_{name}.thy", "w").write(iv.replace("theory EufGoal", f"theory Thy_{name}") + "\n")
good = ["sym_through_opaque", "congruence", "nested", "demorgan_opaque"]
open(f"{work}/ROOT", "w").write("session EUF = HOL +\n  theories\n" + "".join(f"    Thy_{n}\n" for n in good))
open(f"{work}/n/ROOT", "w").write("session EUFN = HOL +\n  theories\n    Thy_bad_constant\n")
PYEUF

EUF_TRUE="sym_through_opaque congruence nested demorgan_opaque"
ELC=0
for t in $EUF_TRUE; do
  timeout 300 lake env lean "$EW/$t.lean" >/dev/null 2>&1 && ELC=$((ELC+1))
done
[ "$ELC" = "4" ] \
  && ok "lean closed all 4 EUF goals (by_cases on DECIDABLE atoms, no classical axiom)" \
  || no "lean closed only $ELC of 4 EUF goals"
if timeout 300 lake env lean "$EW/bad_constant.lean" >/dev/null 2>&1; then
  no "lean CLOSED \`f m = f t\` — the symbol is not uninterpreted"
else
  ok "lean refuses \`f m = f t\` (nothing implies an opaque f is constant)"
fi

if command -v coqc >/dev/null 2>&1; then
  ERC=0; EAX=0
  for t in $EUF_TRUE; do
    O="$( cd "$EW" && coqc "$t.v" 2>&1 )"
    echo "$O" | grep -q "Closed under the global context" && EAX=$((EAX+1))
    echo "$O" | grep -qiE "^error|error:" || ERC=$((ERC+1))
  done
  [ "$ERC" = "4" ] && ok "rocq closed all 4 EUF goals" || no "rocq closed only $ERC of 4 EUF goals"
  # The important one. `~(A/\B) -> ~A \/ ~B` is classically valid; importing `Classical` would
  # close it and show up here as an axiom. Decidable case analysis keeps it clean.
  [ "$EAX" = "4" ] \
    && ok "all 4 are AXIOM-FREE — no Classical import leaked in" \
    || no "only $EAX of 4 axiom-free — a classical axiom is in the attestation"
  BO="$( cd "$EW" && coqc bad_constant.v 2>&1 )"
  if echo "$BO" | grep -qiE "congruence failed|Tactic failure|No applicable"; then
    ok "rocq refuses \`f m = f t\`"
  else
    no "rocq did not refuse \`f m = f t\`"
  fi
else
  inconc "coqc absent — EUF Rocq assertions (incl. axiom-freedom) not run"
fi

if command -v isabelle >/dev/null 2>&1; then
  EIO="$( cd "$EW" && isabelle build -D . 2>&1 )"
  printf '%s' "$EIO" | grep -q "^Finished" \
    && ok "isabelle closed all 4 EUF goals" \
    || no "isabelle did not finish the EUF session"
  EIN="$( cd "$EW/n" && isabelle build -D . 2>&1 )"
  if printf '%s' "$EIN" | grep -qE "Failed to finish proof|FAILED"; then
    ok "isabelle refuses \`f m = f t\`"
  else
    no "isabelle did not refuse \`f m = f t\`"
  fi
else
  inconc "isabelle absent — EUF HOL assertions not run"
fi
fi

# ====================== RUNGS 6+7: DATATYPES + ARRAYS ======================
echo "=== rungs 6+7: struct declarations and array reads in three kernels ==="
DTDEMO="examples/datatype_kernel_demo/src/main.con"
if [ ! -f "$DTDEMO" ]; then
  no "$DTDEMO missing"
else
DW="$WORK/dt"; mkdir -p "$DW/n"
"$BIN" "$DTDEMO" --report bool-kernel > "$DW/report.txt" 2>&1

# The DECLARATION must be emitted. Nothing told a prover a Concrete struct existed before this
# tier: CoreExtract emits Gallina Definitions and zero Inductive/Record.
grep -q "^Record Hdr" "$DW/report.txt" \
  && ok "Rocq Record declaration is emitted with the goal" \
  || no "no Record declaration — the lemma would reference an unknown type"
grep -q "^record Hdr" "$DW/report.txt" \
  && ok "Isabelle record declaration is emitted" || no "no Isabelle record declaration"
grep -q "^structure Hdr" "$DW/report.txt" \
  && ok "Lean structure declaration is emitted" || no "no Lean structure declaration"
# Field projection is the one genuine syntax difference: field-first vs field-last.
grep -q "(magic h)" "$DW/report.txt" && grep -q "h.magic" "$DW/report.txt" \
  && ok "field projection is rendered per kernel (magic h vs h.magic)" \
  || no "field projection is not being rendered per kernel"
# Arrays as total functions, sound because bounds are proved elsewhere.
grep -qE "\(a : Z -> Z\)" "$DW/report.txt" \
  && ok "an array is modelled as a total index -> value function" \
  || no "arrays are not modelled as functions"

python3 - "$DW/report.txt" "$DW" <<'PYDT'
import re, sys
report, work = sys.argv[1], sys.argv[2]
txt = open(report).read()
for b in re.split(r"\n  \[", txt)[1:]:
    if "#struct" not in b.split("]")[0]: continue
    name = b.split("]")[0].split(".")[1].split("#")[0]
    def sect(mk):
        m = re.search(r"--- " + mk + r" ---\n(.*?)(?=\n    ---|\Z)", b, re.S)
        return m.group(1).rstrip() if m else None
    for mk, ext in [(r"lean:by_cases \(struct\)", ".lean"), ("rocq:record", ".v")]:
        v = sect(mk)
        if v: open(f"{work}/{name}{ext}", "w").write(v + "\n")
    iv = sect("isabelle:record")
    if iv:
        d = work + "/n" if name == "bad_array" else work
        open(f"{d}/Thy_{name}.thy", "w").write(iv.replace("theory StructGoal", f"theory Thy_{name}") + "\n")
good = ["magic_kept", "both_fields", "array_read_stable", "mixed_demorgan"]
open(f"{work}/ROOT", "w").write("session DT = HOL +\n  theories\n" + "".join(f"    Thy_{n}\n" for n in good))
open(f"{work}/n/ROOT", "w").write("session DTN = HOL +\n  theories\n    Thy_bad_array\n")
PYDT

DT_TRUE="magic_kept both_fields array_read_stable mixed_demorgan"
DLC=0
for t in $DT_TRUE; do timeout 300 lake env lean "$DW/$t.lean" >/dev/null 2>&1 && DLC=$((DLC+1)); done
[ "$DLC" = "4" ] && ok "lean closed all 4 struct/array goals" || no "lean closed only $DLC of 4"
if timeout 300 lake env lean "$DW/bad_array.lean" >/dev/null 2>&1; then
  no "lean CLOSED \`a i = a j\` — two different array reads are being conflated"
else
  ok "lean refuses \`a i = a j\` (different indices need not agree)"
fi

if command -v coqc >/dev/null 2>&1; then
  DRC=0; DAX=0
  for t in $DT_TRUE; do
    O="$( cd "$DW" && coqc "$t.v" 2>&1 )"
    echo "$O" | grep -q "Closed under the global context" && DAX=$((DAX+1))
    echo "$O" | grep -qiE "^error|error:" || DRC=$((DRC+1))
  done
  [ "$DRC" = "4" ] && ok "rocq closed all 4 struct/array goals" || no "rocq closed only $DRC of 4"
  [ "$DAX" = "4" ] \
    && ok "all 4 axiom-free — Record declarations add nothing to the trusted base" \
    || no "only $DAX of 4 axiom-free"
  BAO="$( cd "$DW" && coqc bad_array.v 2>&1 )"
  if echo "$BAO" | grep -qiE "congruence failed|Tactic failure|No applicable"; then
    ok "rocq refuses \`a i = a j\`"
  else
    no "rocq did not refuse \`a i = a j\`"
  fi
else
  inconc "coqc absent — struct/array Rocq assertions not run"
fi

if command -v isabelle >/dev/null 2>&1; then
  DIO="$( cd "$DW" && isabelle build -D . 2>&1 )"
  printf '%s' "$DIO" | grep -q "^Finished" \
    && ok "isabelle closed all 4 struct/array goals" \
    || no "isabelle did not finish the struct session"
  DIN="$( cd "$DW/n" && isabelle build -D . 2>&1 )"
  if printf '%s' "$DIN" | grep -qE "Failed to finish proof|FAILED"; then
    ok "isabelle refuses \`a i = a j\`"
  else
    no "isabelle did not refuse \`a i = a j\`"
  fi
else
  inconc "isabelle absent — struct/array HOL assertions not run"
fi
fi

echo ""
echo "BOOL-KERNEL: PASS=$PASS  FAIL=$FAIL  INCONC=$INCONC"
[ "$FAIL" -eq 0 ]
