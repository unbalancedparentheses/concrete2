#!/usr/bin/env bash
# Constructor-coverage gate (pipeline refactor #3).
#
# The compiler has many independent recursive walkers (checker, elaborator,
# monomorphizer, core-checker, proof extraction, interpreter, lowering,
# formatter). Every new AST/Core expression constructor risks ONE of those
# walkers silently not handling it — a wildcard `| _ =>` swallows it, and the
# miss only surfaces as a runtime wrong-answer much later. This is the
# compiler-pipeline analogue of the feature-interaction checklist.
#
# This gate makes "every constructor is handled by every walker that must handle
# it" a mechanically-checked invariant:
#
#   - the surface `Expr` constructors are extracted from Frontend/AST.lean and
#     each must appear explicitly (`.ctor`) in every FRONTEND pass;
#   - the core `CExpr` constructors are extracted from Elab/Core.lean and each
#     must appear explicitly in every CORE pass.
#
# The constructor lists are read from the source, not hard-coded, so adding a
# constructor and forgetting to teach a walker about it FAILS this gate. The
# four surface-only forms (methodCall / staticMethodCall / arrowAccess / paren)
# are desugared in Resolve/Elab and correctly do not exist as CExpr — that is
# why the two matrices are checked against different constructor lists.
#
# A pass "handles" a constructor iff the token `.<ctor>` occurs in its file.
# Today every cell is covered; this gate locks that in. It greps source only
# (no compiler build required) and lives in the grammar CI job.

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS+1)); }
no() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# Extract the `| ctorName` heads of an inductive block from a Lean file.
# $1 = file, $2 = inductive name.
ctors_of() {
  awk -v want="inductive $2 where" '
    $0 ~ want {f=1; next}
    f && /^(inductive|structure|def|abbrev|end|namespace)/ {exit}
    f && /^[[:space:]]*\|/ {print}
  ' "$1" | grep -oE "\| [a-z][A-Za-z0-9_]+" | sed 's/| //' | sort -u
}

# Assert every constructor in $3.. appears in file $1 (pass label $2).
covers() {
  local file="$1" label="$2"; shift 2
  local missing=""
  for c in "$@"; do
    grep -qE "\.${c}([^A-Za-z0-9_]|\$)" "$file" || missing="$missing $c"
  done
  if [ -z "$missing" ]; then ok "$label handles all ${#} constructors"
  else no "$label is MISSING:$missing  (add an explicit arm in $file)"; fi
}

mapfile -t EXPR_CTORS  < <(ctors_of Concrete/Frontend/AST.lean Expr)
mapfile -t CEXPR_CTORS < <(ctors_of Concrete/Elab/Core.lean CExpr)

echo "=== surface Expr (${#EXPR_CTORS[@]} constructors) handled by every frontend pass ==="
[ "${#EXPR_CTORS[@]}" -ge 20 ] || no "extracted only ${#EXPR_CTORS[@]} Expr constructors — parser broken?"
covers Concrete/Check/Check.lean     "checker (Check)"     "${EXPR_CTORS[@]}"
covers Concrete/Elab/Elab.lean       "elaborator (Elab)"   "${EXPR_CTORS[@]}"
covers Concrete/Frontend/Format.lean "formatter (Format)"  "${EXPR_CTORS[@]}"
# OBLIGATION DISCOVERY. Enrolled 2026-08-06.
#
# HONEST LIMIT, measured rather than assumed: `covers` is FILE-granular, so this catches "no
# walker anywhere handles constructor X" and NOT "walker #2 forgot X while walker #3 still has
# it". Verified by mutation -- deleting the `.allocCall` arm from `collectDivisorsE` does not
# fail this gate, because three sibling walkers still mention `.allocCall`.
#
# So it guards the extreme case, not the case that actually occurred. Recording that because a
# gate described as preventing a bug class, which only prevents its worst version, is how a green
# number starts meaning less than it appears to. Per-walker coverage needs a checker that parses
# each `def` separately -- worth doing, and not what this is.
#
# It should have been enrolled from the start regardless: the walkers
# that decide whether a runtime-safety obligation is EMITTED live here, and a constructor no
# walker handles is an obligation that is never generated -- no failed proof, no `unproven`
# marker, just a green report. Seven such defects were found by hand this year (`(a)[i]`,
# `b.data[i]`, unannotated array sizes, nested declarations, shadowed bindings); every one was a
# case some walker did not cover. This gate is the mechanical version of that search.
# Leaves are EXCLUDED, and the distinction is the whole point. A `boolLit`/`strLit`/`fnRef`
# contains no subexpression, so a catch-all returning `[]` is CORRECT for it -- demanding an
# explicit arm would be noise. What must never be missed is a COMPOUND constructor: one holding a
# sub-expression the walker has to recurse into, because forgetting one silently loses every
# obligation underneath it.
OBLIGATION_COMPOUND=()
for c in "${EXPR_CTORS[@]}"; do
  case "$c" in
    boolLit|charLit|floatLit|strLit|intLit|ident|fnRef) continue ;;
    *) OBLIGATION_COMPOUND+=("$c") ;;
  esac
done
covers Concrete/Report/ReportObligations.lean "obligation discovery (compound ctors)" "${OBLIGATION_COMPOUND[@]}"

echo ""
echo "=== core CExpr (${#CEXPR_CTORS[@]} constructors) handled by every core pass ==="
[ "${#CEXPR_CTORS[@]}" -ge 20 ] || no "extracted only ${#CEXPR_CTORS[@]} CExpr constructors — parser broken?"
covers Concrete/IR/Lower.lean         "lowering (Lower)"       "${CEXPR_CTORS[@]}"
covers Concrete/IR/Mono.lean          "mono (Mono)"            "${CEXPR_CTORS[@]}"
covers Concrete/Check/CoreCheck.lean  "core-check (CoreCheck)" "${CEXPR_CTORS[@]}"
covers Concrete/Interp/Interp.lean    "interpreter (Interp)"   "${CEXPR_CTORS[@]}"
covers Concrete/Proof/ProofCore.lean  "proof extraction"       "${CEXPR_CTORS[@]}"

echo ""
echo "CONSTRUCTOR-COVERAGE: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
