#!/usr/bin/env bash
# Phase 6C #5: gate mutation-testing — prove the pipeline gates are load-bearing.
#
# For each rule FAMILY, apply a one-line source mutation that disables the rule
# (while still building) and prove the family's SPECIFIC gate goes red (KILLED).
# A mutation whose gate stays green is a SURVIVOR = a decorative gate = failure.
#
# HEAVY / NIGHTLY: the behavioral families need a `lake build` per mutation (~1-3
# min each), so this is not a per-commit gate. Grep-only families (constructor
# coverage, source-maps) need no rebuild. Run one family with FAMILY=<n>, or all
# (default). Restore is via `git checkout --` (assumes a clean tree for the
# mutated files); a final clean rebuild is done at the end.
#
# Most families' gates are OUTSIDE run_tests.sh --fast, so we invoke each gate directly.
#
# COVERAGE, stated because this harness is the thing that stops gates being decorative and
# its own coverage was never written down (2026-08-04 sweep):
#
#   180 gate scripts in scripts/tests/
#    55 guard a SOUNDNESS claim — breaking the rule would let the compiler assert something
#       false about a program (a missing trap, a false `proved`, a laundered axiom)
#    18 of those 55 are the GATE FIELD of a family here
#    37 of those 55 have NONE
#
# Count coverage from the GATE FIELD of `add` lines, never by grepping this file for gate
# names. Two gates read as covered for a while because their names appear only in prose:
# `check_multi_kernel.sh` (mentioned in a note about dirty-tree refusal) and
# `check_totality_judgment.sh` (mentioned in the survivor note below, which says explicitly
# that it does NOT cover its rule). The name-grep figure was 20; the real figure is 18, and
# the inherited "11 of 180" was inflated the same way.
#
# `--coverage` prints the real numbers so nobody has to grep. Third instance today of a
# metric measuring a proxy instead of the thing, and this file exists to prevent that class.
#
# Those figures are RECOMPUTED, not derived by arithmetic. A first version of this header
# said 17/38, reached by adding the four families of that pass to a previous count — wrong,
# because six of the covered gates (source-maps, copy-judgment, corecheck-boundary,
# diagnostics-quality, mono-name-collision, constructor-coverage) are not soundness gates at
# all, so "covered" and "covered AND soundness" are different sets. Same defect class this
# file exists to catch: a number restated instead of measured.
#
# The 42 are not known to be decorative. They are UNMEASURED, which is a different claim
# from safe, and the distinction is the whole reason this file exists: for a week, every
# defect found landed in the unmeasured set while the suite was green.
#
# Selection rule for extending this list: a gate qualifies if breaking the rule it guards
# would let the compiler assert something FALSE. Gates over formatting, naming, docs hygiene
# or CI plumbing are out of scope — they matter, but their failure mode is noise rather than
# a wrong claim.

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
LAKE="${LAKE:-lake}"
ONLY="${FAMILY:-}"

# `--coverage`: report which soundness gates have a control, computed from the GATE FIELD of
# the `add` lines below — not from a grep for gate names, which counts prose.
if [ "${1:-}" = "--coverage" ]; then
  SELF="$0"
  TARGETED="$(grep -E '^add "' "$SELF" | awk '{print $4}' | tr -d '"' | sort -u)"
  sound=0; cov=0; missing=""
  for f in scripts/tests/check_*.sh; do
    b="$(basename "$f")"
    k="$(grep -ciE 'unsound|must never|false green|no false|trap|proved|axiom|forge|launder' "$f")"
    [ "$k" -ge 4 ] || continue
    sound=$((sound+1))
    if printf '%s\n' "$TARGETED" | grep -qx "$b"; then cov=$((cov+1)); else missing="$missing $b"; fi
  done
  echo "soundness gates: $sound"
  echo "  with a negative control: $cov"
  echo "  without: $((sound-cov))"
  echo "uncovered:"; printf '%s\n' $missing | sed 's/^/  /'
  exit 0
fi

# family i: NAME FILE GATE NEEDS_BUILD ; OLD/NEW written to temp files per family.
NAME=();  FILE=();  GATE=();  BUILD=()
OLD=();   NEW=()
add(){ NAME+=("$1"); FILE+=("$2"); GATE+=("$3"); BUILD+=("$4"); OLD+=("$5"); NEW+=("$6"); }

add "corecheck-unsafe-op" "Concrete/Check/CoreCheck.lean" "check_corecheck_boundary.sh" yes \
  'addCCError (.missingCapability "*raw_ptr" "Unsafe" "")' \
  'pure ()'
add "copy-predicate" "Concrete/Check/Layout.lean" "check_copy_judgment.sh" yes \
  '| some (isC, _, _) => isC' \
  '| some (_, _, _) => true'
add "checked-arith-trap" "Concrete/Backend/EmitSSA.lean" "check_checked_arith.sh" yes \
  $'      let mnem := if ssaIsSignedInt operandTy then "sadd" else "uadd"\n      emitStructured s (.call (some dst) iTy (.global (checkedCallName mnem operandTy)) [(iTy, lOp), (iTy, rOp)])' \
  $'      let _mnem := if ssaIsSignedInt operandTy then "sadd" else "uadd"\n      emitStructured s (.binOp dst .add iTy lOp rOp)'
add "capability-requirement" "Concrete/Check/CoreCheck.lean" "check_capability_judgment.sh" yes \
  'if !capD.satisfied then' \
  'if false then'
add "walker-constructor" "Concrete/Check/CoreCheck.lean" "check_constructor_coverage.sh" no \
  '| .intLit _ _ | .floatLit _ _ | .boolLit _ | .strLit _ | .charLit _ => pure ()' \
  '| .intLit _ _ | .floatLit _ _ | .boolLit _ | .strLit _ | _ => pure ()'
add "source-span-stamping" "Concrete/Elab/Elab.lean" "check_source_maps.sh" no \
  'declSpan := some f.span' \
  'declSpan := none'
add "mono-name-hygiene" "Concrete/IR/Mono.lean" "check_mono_name_collision.sh" yes \
  '| .generic n args => n ++ "_T_" ++ "_".intercalate (args.map tyToSuffix) ++ "_E"' \
  '| .generic n _args => n'
add "diagnostic-quality" "Concrete/Check/CoreCheck.lean" "check_diagnostics_quality.sh" yes \
  '| .insufficientCapabilities _ required _ => some s!"add '"'"'with({required})'"'"' to the calling function, or wrap the call in a trusted function"' \
  '| .insufficientCapabilities _ _ _ => none'
add "fact-invalidation" "Concrete/Report/ReportObligations.lean" "check_scoped_collector.sh" yes \
  '| _ => dropStaleHyps scope (assignedScalarsS s)' \
  '| _ => scope'
add "report-schema-row" "Concrete/Report/Report.lean" "check_vc_schema.sh" yes \
  '("kind", .str v.kind),' \
  '("knd", .str v.kind),'

# ---------------------------------------------------------------------------
# 2026-08-04: the R-0460..R-0465 gates. Registered because they were NOT here, and
# every failure of the past week landed in exactly the uncovered set: a gate that
# passed while the thing it guarded was broken. 11 of 180 gates had negative
# controls; the newest and most load-bearing had none.
#
# Each mutation below was verified by hand when the gate was written. Verified by
# hand means verified once, by whoever remembered. These entries make it repeat.
# ---------------------------------------------------------------------------

# H23's composition: drop the cap and a proved obligation resting on an unproved
# invariant reads proved again. This is the defect, restored exactly.
add "hypothesis-cap" "Main.lean" "check_known_wrong_corpus.sh" yes \
  'return Report.capOnHypothesisDebt (Report.dischargeVCs vcs omegaProved (bvCallKeys ++ bvOvfKeys))' \
  'return Report.dischargeVCs vcs omegaProved (bvCallKeys ++ bvOvfKeys)'

# H24's insufficiency: drop the quotient condition and a division reports proved
# while trapping on signed MIN / -1. Also breaks trapConditions_sufficient, so this
# one is expected to fail the BUILD as well as the gate — recorded because a
# mutation that cannot compile is a stronger result than a gate going red.
add "trap-quotient-condition" "Concrete/Semantics/IntArith.lean" "check_known_wrong_corpus.sh" yes \
  '| .div | .mod => [.divisorNonZero, .quotientInRange]' \
  '| .div | .mod => [.divisorNonZero]'

# The multi-kernel firewall: let attestation act on an unproved VC and a badge can be
# minted for something no kernel proved.
add "attestation-precondition" "Concrete/Report/Report.lean" "check_discharge_adapters.sh" yes \
  $'    actsOn := fun s => s == "proved_by_kernel_decision" || s == "proved_by_lean"\n                       || s == "proved_by_lean_replay",' \
  $'    actsOn := fun _ => true,'

# The independence coordinate: collapse Isabelle into CIC and the badge overstates
# foundational independence — two CIC kernels reported as two foundations.
add "kernel-foundation" "Concrete/Report/Evidence.lean" "check_evidence_algebra.sh" yes \
  '| "isabelle" => .hol' \
  '| "isabelle" => .cic'

# The reference evaluator's division convention: swap truncating for Lean's `/` and
# every lowering-agreement check is validated against the wrong reference at
# negative operands.
# Re-pointed 2026-08-04: the reference evaluator moved into the term IR when `evalIntEnv`
# stopped being a `partial def`, so the division convention now lives in `TermIR.evalInt`.
# The mutation is meaningful — Lean's `/` on Int is FLOORED (`-7 / 2 = -4`) while `.tdiv`
# truncates (`-3`), so swapping them silently re-points the reference every rendering is
# validated against, at exactly the inputs positive tests never reach.
#
# Expect "killed by build": the convention is now pinned by `rfl` examples, and for a
# compile-time lock a build failure IS the correct kill — which this harness can finally say,
# as of the invalid-mutation split above.
add "reference-division" "Concrete/Semantics/TermIR.lean" "check_vc_bridge_register.sh" yes \
  '| .tdiv => if b == 0 then none else some (IntArith.tdiv a b)' \
  '| .tdiv => if b == 0 then none else some (a / b)'

# The artifact fuzzer's claim classification: treat every function as claimed and a
# trap in an admittedly-unproved function is reported as a Register A counterexample —
# a false alarm, which is how a fuzzer gets switched off.
add "fuzz-claim-classes" "Concrete/Report/ReportObligations.lean" "check_artifact_fuzz.sh" yes \
  'artifactFuzzDriverFor (cases.filter (fun c => c.claim != "unproved")) "artifact_fuzz_all"' \
  'artifactFuzzDriverFor cases "artifact_fuzz_all"'

# ---------------------------------------------------------------------------
# 2026-08-04, second pass: a sweep of the SOUNDNESS gates that had no control.
#
# Selection rule, so the next person can extend it the same way: a gate qualifies
# if breaking the rule it guards would let the compiler assert something FALSE
# about a program — a missing trap, a false `proved`, a laundered axiom. Gates over
# formatting, naming, docs hygiene or CI plumbing are out of scope; they matter, but
# their failure mode is noise, not a wrong claim.
# ---------------------------------------------------------------------------

# Bug 053, restored exactly: make every unary op read as non-side-effecting and a
# DISCARDED integer negation is deleted, taking the documented MIN trap with it. The
# compiled program exits 0 where the interpreter aborts.
add "trap-preservation-unary" "Concrete/IR/SSACleanup.lean" "check_trap_inventory.sh" yes \
  'if !(IntArith.unaryOpCanTrap op ty) then false' \
  'if true then false'

# NO FALSE GREEN, the obligation red-team's first clause: make the constant-divisor
# verdict unconditionally true and `x / 0` at compile time reads proved.
add "const-divisor-verdict" "Concrete/Report/ReportObligations.lean" "check_obligation_redteam.sh" yes \
  '| some k => (some (decide (k ≠ 0)), none)' \
  '| some k => (some (decide (k == k)), none)'

# The same false-green in the bounds family: a constant index outside the array
# reads proved.
add "const-bounds-verdict" "Concrete/Report/ReportObligations.lean" "check_obligation_redteam.sh" yes \
  '| some k => (some (decide (0 ≤ k) && decide (k < (Int.ofNat n))), none)' \
  '| some k => (some (decide (k == k)), none)'

# The FOLD path, which is what check_int_arith_semantics.sh actually guards:
# interpret == fold-then-interpret == compiled. Make a trapping constant operation fold
# to a value and the trap disappears under constant folding — the interpreter aborts
# while the folded/compiled program returns 0.
#
# Chosen after a first attempt failed for an INSTRUCTIVE reason. Removing the div
# overflow trap from `evalIntBinOp` does not compile: `div_obligation_necessary`
# (R-0460) rejects it. That is stronger protection than a gate — but it meant the
# family proved the THEOREM was load-bearing while claiming to prove the gate was, and
# a control that validates something other than its stated subject is exactly the
# false-green this harness exists to prevent. `foldIntBinOp` is covered by no theorem,
# so a mutation there reaches the gate.
add "fold-drops-trap" "Concrete/Semantics/IntArith.lean" "check_int_arith_semantics.sh" yes \
  '| .trap _    => some none' \
  '| .trap _    => some (some 0)'

# ---------------------------------------------------------------------------
# 2026-08-04, third pass: the remaining soundness gates, batch 1.
# Each mutation removes a RUNTIME CHECK or a trust boundary, so the compiled program
# does something the compiler said it would not.
# ---------------------------------------------------------------------------

# H8's check: stop emitting the array bounds check and an out-of-range index reads
# and writes past the array instead of aborting. The obligation layer is untouched,
# so this is the pure lowering failure — proved obligation, unchecked artifact.
# INFLATE the length rather than deleting the call or replacing the length outright. Two
# earlier attempts died on a lint, not on the check: `pure ()` left `idxI64` unused, and a
# constant length left `len` unused, and this project treats an unused binding as a build
# error. A mutation that cannot compile proves nothing about the gate (see fold-drops-trap).
# `len + 999999999` keeps both bindings live and makes the check pass for every real index.
add "bounds-check-emission" "Concrete/IR/Lower.lean" "check_array_bounds.sh" yes \
  '[idxI64, .intConst (Int.ofNat len) .int] .unit)' \
  '[idxI64, .intConst (Int.ofNat len + 999999999) .int] .unit)'

# ---------------------------------------------------------------------------
# 2026-08-04, batch 2 of the remaining soundness gates.
# ---------------------------------------------------------------------------

# Checked integer NEGATION: make `-x` compute `0 - 0` so it neither traps at MIN nor
# returns the right value. Bug 053's sibling — that one deleted a discarded negation,
# this one keeps it and makes it wrong. Operands changed rather than the call replaced,
# because dropping the call leaves `mnem` unused and this project errors on that.
add "checked-negation" "Concrete/Backend/EmitSSA.lean" "check_arith_redteam.sh" yes \
  '[(iTy, .intLit 0), (iTy, valOp)]' \
  '[(iTy, .intLit 0), (iTy, .intLit 0)]'

# Proof FRESHNESS (bugs 059/060): make staleness detection always answer "fresh", so a
# proof whose subject has changed underneath it keeps reading proved. The stored digest
# is still there and still compared — the comparison just always agrees, which is the
# shape a real staleness bug takes.
add "proof-staleness" "Concrete/Proof/ProofCore.lean" "check_proof_freshness.sh" yes \
  $'    | some h => shortHash currentFp != h\n    | none   => a.expectedFp != currentFp' \
  $'    | some h => shortHash currentFp == shortHash currentFp && h != h\n    | none   => a.expectedFp != a.expectedFp'

# H2's check: route float→int through a raw `fptosi` instead of the checked helper.
# LLVM says raw fptosi is POISON on NaN/±inf/out-of-range, so this is undefined
# behaviour reachable from safe source.
add "checked-float-cast" "Concrete/Backend/EmitSSA.lean" "check_float_cast.sh" yes \
  'emitStructured s (.call (some dst) dstLLTy (.global (checkedF2ICallName srcTy targetTy)) [(srcLLTy, valOp)])' \
  'emitStructured s (.cast dst .fptosi srcLLTy valOp dstLLTy)'

# Wrapping arithmetic must NOT trap: make `wrapping_add` emit the CHECKED add and a
# documented-wrapping operation aborts instead of wrapping. The inverse direction of
# the checked-arith family — that one removes a trap, this one adds one where the
# language promises none.
add "wrapping-stays-unchecked" "Concrete/Backend/EmitSSA.lean" "check_wrapping_arith.sh" yes \
  '| .wrappingAdd => emitStructured s (.binOp dst .add iTy lOp rOp)' \
  '| .wrappingAdd => emitStructured s (.call (some dst) iTy (.global (checkedCallName "sadd" operandTy)) [(iTy, lOp), (iTy, rOp)])'

# ---------------------------------------------------------------------------
# 2026-08-04, batch 3. APPENDED at the end deliberately: family numbers are
# positional, and inserting mid-list earlier today renumbered everything below and
# sent a validation run at two already-covered families.
# ---------------------------------------------------------------------------

# A SURVIVOR that turned into a finding about the GATE, not about the rule.
#
# Making `blockDiverges` always answer false — so code after a `return` reads as
# reachable — leaves `check_totality_judgment.sh` GREEN. That gate's header names
# `blockDiverges` among the single-sourced facts it covers, but what it actually tests is
# arithmetic traps and interp/compiled value agreement; no fixture in it exercises
# divergence detection. Its scope is narrower than its name and header claim, and that is
# worth knowing on its own.
#
# The RULE is guarded, though, and decisively: measured with the mutation applied,
# `make test` goes from 1702/0 to **1315 passed / 76 failed** — E0213 linear-variable
# errors, because divergence detection is what allows an `if` without `else` whose
# then-branch returns. So this family targets `run_tests.sh`, the check that actually
# kills it, rather than the gate whose name suggested it should.
#
# Recorded this way because the first instinct — delete the family, or leave it aimed at a
# gate it does not exercise — would have converted a measurement into either silence or a
# false green.
add "divergence-detection" "Concrete/Check/CheckHelpers.lean" "run_tests.sh" yes \
  $'partial def blockDiverges (stmts : List Stmt) : Bool :=\n  match stmts.getLast? with\n  | none => false\n  | some s => stmtDiverges s' \
  $'partial def blockDiverges (stmts : List Stmt) : Bool :=\n  match stmts.getLast? with\n  | none => false\n  | some _ => false'

# Check and Elab must route integer-literal typing through the ONE shared judgment.
# Make Check DISCARD a hint Elab still honours and the E0228/E0715 bug class returns:
# two passes inferring a source type independently and disagreeing. Phrased to keep
# `hintR` live — dropping it outright leaves it unused, which this project treats as a
# build error, and a mutation that cannot compile tests nothing.
add "shared-type-judgment" "Concrete/Check/Check.lean" "check_type_agreement.sh" yes \
  'let d := TypeJudgment.intLitDecision hintR' \
  'let d := TypeJudgment.intLitDecision (if hintR.isSome then none else hintR)'

# R-0455 Register B row 1. Making the transformation a NO-OP still preserves meaning — the
# soundness theorem holds — so the thing that must fail is the non-vacuity lock. It does, at
# BUILD time, because those locks are `rfl` examples: for a compile-time lock, "killed by
# build" is the correct mechanism rather than the weak one, unlike a mutation that dies on an
# unrelated lint. This family records that the vacuity guard, not just the soundness proof,
# is load-bearing.
add "transform-has-effect" "Concrete/Semantics/TermIR.lean" "check_transform_register.sh" yes \
  $'    | .bin .tmod l r =>\n      let l\' := elimTmod l\n      let r\' := elimTmod r\n      .bin .sub l\' (.bin .mul r\' (.bin .tdiv l\' r\'))' \
  $'    | .bin .tmod l r => .bin .tmod (elimTmod l) (elimTmod r)'

# R-0004 slice 5. The subject digest binds the STRUCTURAL body; before 2026-08-09 it bound the
# legacy Core-statement hash, which is what bugs 059/060 are filed against. This mutation
# restores the old behaviour in the direction that matters — the body stops contributing to the
# subject at all — and `check_proof_freshness.sh` must go red on its SHADOW(body) leg.
#
# It is the RIGHT mutation for this gate because it is indistinguishable from the pre-change
# state at every other surface: the digest still exists, still refuses incomplete facts, still
# moves on signature and contract edits. Only "a body edit moves the subject" is lost, and if
# the gate does not notice, then binding the structural body bought nothing.
add "subject-binds-body" "Concrete/Proof/ProofCore.lean" "check_proof_freshness.sh" yes \
  $'    | .ok complete =>\n      some (shortHash ("subjectV2:" ++ facts.canonical\n              ++ "|body:" ++ shortHash (Proof.bodyBytesV2 complete)))' \
  $'    | .ok _ =>\n      some (shortHash ("subjectV2:" ++ facts.canonical))'

# R-0004 slice 6, blocker (c) containment. `rowJustifies` refuses a classification whose theorem
# SHAPE cannot support it, and `classifiedEdgeOf` downgrades such a row to `unclassified`. The
# probes for that use SYNTHETIC rows, which proves the function rejects — not that the consumer
# acts on it for a real row in the checked-in table.
#
# This mutation relabels a real row `body` -> `contract` while leaving `quantifies = false`. The
# row stays structurally valid: well-formed digests, one table, no duplicates. Only the
# correspondence condition fails, so nothing but `rowJustifies` can catch it — which is exactly
# what makes it the right mutation for this control.
add "classification-justifies" "Concrete/Proof/ClassificationTable.lean" "check_dependency_edges.sh" yes \
  $'  ("Concrete.Proof.parse_byte_correct", "body", "7bcec2d7871f93204b26e2bf83d5acf1", [("Concrete.Proof.proofFns", "6fe095a9f592a2e2b556e87f30306584")], false),' \
  $'  ("Concrete.Proof.parse_byte_correct", "contract", "7bcec2d7871f93204b26e2bf83d5acf1", [("Concrete.Proof.proofFns", "6fe095a9f592a2e2b556e87f30306584")], false),'

# R-0004 slice 6. `tableEntryEvidence` RECOMPUTES the canonical body digest from `PFnDef.body` and
# refuses unless the stored provenance agrees. Before that, the stored digest was copied and every
# downstream check compared metadata to metadata, so this state bound successfully:
#
#     body replaced, `identity` retained, `sourceBodyDigest` retained
#
# The mutation restores exactly the old behaviour — the comparison still runs, its verdict is just
# discarded — so the table entry is trusted again while everything else about the join is
# untouched. Nothing but the recompute can catch it, which is what makes it the right control:
# schema and scope checks still pass, identities are unique, and the manifest join still agrees.
# RETARGETED 2026-08-13 when `tableEntryEvidence` moved from `Option` to a named-refusal `Except`.
# The harness FAILED rather than passing when its OLD text vanished, which is the behaviour that
# makes a stale control detectable instead of a quiet always-green.
add "entry-body-recomputed" "Concrete/Proof/DependencyEdge.lean" "check_dependency_edges.sh" yes \
  $'          if stored.value != recomputed then' \
  $'          if false then'

# R-0004 slice 6, manifest provenance. `CompleteImplementation.of?` refuses facts describing a
# DIFFERENT callable than the one claimed, which is what stops a manifest row pairing one callable's
# identity with another's signature, contracts and capabilities.
#
# SCOPE OF THIS CONTROL, stated because the neighbouring gap is easy to conflate with it: this covers
# the facts/callable mispairing ONLY. A `body` or `extracted` belonging to another entry is NOT
# covered and has deliberately no mutation, because neither `CompleteEvidenceBodyV2` nor `PExpr`
# carries identity, so such a mutation would SURVIVE — and a surviving control recorded as coverage
# is worse than an absent one. See the named gap in ROADMAP.md R-0004 item 2.
add "implementation-facts-match-callable" "Concrete/Proof/ImplementationIdentity.lean" "check_dependency_edges.sh" yes \
  $'  if facts.id != callable then none' \
  $'  if false then none'

# R-0004 slice 6, manifest completeness. `ManifestResult.usable?` compares the rows against the
# STORED denominator (`expected`), which is what stops a producer that drops entries from returning a
# smaller manifest that looks complete. The mutation discards that comparison, restoring exactly the
# `filterMap` behaviour: rows are then trusted to be their own denominator.
#
# The refusals check is left intact by this mutation, so the probe that kills it is the one whose
# refusal list is EMPTY and whose rows are a strict subset of `expected` — i.e. it can only be caught
# by the stored-denominator comparison, not by any other condition.
add "manifest-rows-match-expected" "Concrete/Proof/DependencyEdge.lean" "check_dependency_edges.sh" yes \
  $'  else if r.impls.map (\u00b7.callable) != r.expected then none' \
  $'  else if false then none'

# R-0004 slice 6, the laundering itself. The producer records a NAMED refusal for an entry it cannot
# build a row for; the mutation drops that entry instead, which is exactly what `filterMap` did.
#
# This is the control for the REAL-CORPUS gate, not a synthetic one, and that is the point: under the
# mutation the corpus reports expected=63 rows=63 refused=0 usable=yes for every file — a complete
# manifest, with the incompleteness gone from the accounting rather than fixed. Only a gate that
# stores the denominator can see the difference, which is what check_impl_manifest.sh does.
add "manifest-refusal-recorded" "Concrete/Proof/ProofCore.lean" "check_impl_manifest.sh" yes \
  $'          | none => refuse .extractedMissing' \
  $'          | none => acc'

# R-0004 slice 6. THE DISPATCH IS SECURITY-RELEVANT INVENTORY. It maps a hand-back table name to the
# `FnTable` the compiler links, and per-edge correspondence rests on it: if an entry is removed or
# misrouted, the tables a theorem names stop resolving, its edges lose their witnesses, and the
# subject must fall to `missing` rather than corresponding on a table it never read.
#
# The mutation MISROUTES one entry to `none` — the shape a stale dispatch actually takes when a
# table is renamed and the list is not updated. It is caught by the real-corpus assertion
# (6/11 subjects fully correspond), not by a synthetic probe, so this covers the production path.
add "dispatch-entry-routes" "Concrete/Proof/TableResolve.lean" "check_dependency_edges.sh" yes \
  $'  | "Concrete.Proof.cryptoFns"         => some cryptoFns' \
  $'  | "Concrete.Proof.cryptoFns"         => none'

# R-0004 slice 6. Surplus must be RETAINED, not dropped. The review named this explicitly:
# "dropping surplus handling through filterMap must be mutation-killed". The mutation empties the
# surplus set while leaving every other set intact, which is exactly what a `filterMap` that
# discarded unmatched witnesses would do — the join still reports matched/missing/ambiguous and
# looks healthy.
add "correspondence-surplus-retained" "Concrete/Proof/Correspondence.lean" "check_dependency_edges.sh" yes \
  $'  let surplus := ours.filter (fun w => !(i.requestedEdges.any (fun r => witnessTargets r w)))' \
  $'  let surplus := []'

# R-0004 slice 6. External table material is GENERATOR-ASSERTED: no body exists to recompute it
# against, so the entry-derived digest recorded beside it is its ONLY independent verification.
# The mutation changes the stored digest alone, leaving the entry list intact — the shape a stale
# hand-back row takes after a table changes and the digest is regenerated but the rows are not, or
# vice versa. If the comparison is not load-bearing this passes unnoticed and external evidence is
# accepted on trust with a decorative digest beside it.
add "external-table-digest-checked" "Concrete/Proof/ClassificationTable.lean" "check_dependency_edges.sh" yes \
  $'  ("Examples.ProofPatterns.Proofs.combineFns", "1393cec60470308d80326ce29c170734", [("calls", "dbl", "b78225e71dcabeba3282cf29cdc93ef5"), ("calls", "inc", "547e67b5f2b072131034d8cec278c032")])' \
  $'  ("Examples.ProofPatterns.Proofs.combineFns", "00000000000000000000000000000000", [("calls", "dbl", "b78225e71dcabeba3282cf29cdc93ef5"), ("calls", "inc", "547e67b5f2b072131034d8cec278c032")])'

# R-0004 slice 6. MISROUTING a table name to ANOTHER TABLE'S VALUE — distinct from the
# routed-to-`none` case already covered. Routing to `none` makes the table unresolvable and the
# subject's edges fall to `missing`; routing to a WRONG table resolves successfully and answers
# membership from the wrong material, which is the more dangerous shape because nothing looks
# absent. `cryptoFns` is pointed at `elfFns`: both resolve, both have entries, and the callees
# simply are not the ones the theorem bound.
add "dispatch-routes-to-correct-table" "Concrete/Proof/TableResolve.lean" "check_dependency_edges.sh" yes \
  $'  | "Concrete.Proof.cryptoFns"         => some cryptoFns' \
  $'  | "Concrete.Proof.cryptoFns"         => some elfFns'

# R-0004 slice 6. RELABELLING asserted evidence as checked. The digest agreeing does not mean a
# body was ever read, and this mutation makes external material claim it was — the single most
# consequential lie this subsystem could tell, because every downstream consumer treats
# `compilerLinked` as recomputed-from-source.
add "external-stays-asserted" "Concrete/Proof/TableResolve.lean" "check_dependency_edges.sh" yes \
  $'      else .ok (.generatorAsserted, rows)' \
  $'      else .ok (.compilerLinked, rows)'

# R-0004 slice 6. IDENTITY RETENTION FOR EXCLUDED CALLEES. A trusted helper is excluded from the
# proof entries but is still a real callable. Resolving callee names only against `entries` reported
# it as `«unresolved»`, which turned a `trusted` edge into a `missing` one and cost the subject its
# correspondence. The mutation restores the entries-only lookup — the exact defect — and must be
# caught by the REAL-CORPUS correspondence assertion (9/11), not by a synthetic probe.
add "excluded-identity-retained" "Concrete/Proof/ProofCore.lean" "check_dependency_edges.sh" yes \
  $'    | none => (pc.excluded.find? (fun x => x.qualName == qn)).map (\u00b7.callableId)' \
  $'    | none => none'

# R-0004 attestation provenance. DRIFT SELECTION: the classifier matches a fixture's own header
# (`// … DRIFTED variant`) rather than its filename, so a renamed drift fixture stays classified. The
# mutation breaks the match, which lets a DRIFTED implementation be attested — the hazard that
# actually occurred when `proofFns` references resolved to `main_drifted.con`.
add "manifest-drift-classified" "scripts/gen/attestation_manifest.sh" "check_attestation_manifest.sh" no \
  $'DRIFT="$(grep -rlE \'^// .*DRIFTED variant\' examples --include=\'*.con\' 2>/dev/null | sort)"' \
  $'DRIFT="$(grep -rlE \'^// .*NO_SUCH_MARKER\' examples --include=\'*.con\' 2>/dev/null | sort)"'

# R-0004 attestation provenance. PACKAGE COLLAPSE: `contentRoot` binds module CONTENT. The mutation
# reverts it to module NAMES ONLY, which is the state that collapsed `composition` and
# `composition_trusted_helper` — two different programs — into one package identity.
# The mutation makes CONTENT contribute nothing while keeping every binding live. A first version
# deleted `srcPart` from the concatenation, which left it unused and failed the build on a lint — the
# harness correctly called that INVALID, because a mutation that cannot compile tests nothing.
add "package-identity-binds-content" "Concrete/Proof/DefinitionIdentity.lean" "check_attestation_manifest.sh" yes \
  $'    let srcPart := srcs.foldl (fun a d => a ++ "|S" ++ d) ""\n    PackageIdentity.synthetic (Concrete.shortHash ("pkgSyntheticV1:" ++ mods ++ srcPart))' \
  $'    let srcPart := srcs.foldl (fun a _ => a) ""\n    PackageIdentity.synthetic (Concrete.shortHash ("pkgSyntheticV1:" ++ mods ++ srcPart))'

# R-0004 attestation provenance. OMISSION OF THE SOURCE-LINKED POPULATION. The manifest scans fixtures
# carrying `#[proof_by]`/`#[ensures_proof]`; dropping that population leaves only whatever the other
# path reaches. Killed by the exact row/attestation denominators, which is the point of pinning them.
add "manifest-source-population" "scripts/gen/attestation_manifest.sh" "check_attestation_manifest.sh" no \
  $'done < <(grep -rlE \'#\\[(proof_by|ensures_proof)\\(\' examples --include=\'*.con\' 2>/dev/null | sort)' \
  $'done < <(grep -rlE \'#\\[(proof_by)\\(\' examples --include=\'*.con\' 2>/dev/null | grep -v ensures | sort)'

# R-0004 attestation provenance. DISCARDED SURPLUS. A table attested but referenced by no
# classification row authorises material nothing asked for. The mutation drops the check, so surplus
# stops being reported — the shape where a manifest quietly authorises more than the corpus requests.
add "manifest-surplus-refused" "scripts/gen/attestation_manifest.sh" "check_attestation_manifest.sh" no \
  $'  printf \'%s\\n\' "$KNOWN_TABLES" | grep -qx "$t" || { refuse "table \'$t\' is attested but referenced by no classification row (surplus)"; SURPLUS=$((SURPLUS+1)); }' \
  $'  printf \'%s\\n\' "$KNOWN_TABLES" | grep -qx "$t" || true'

# R-0004 attestation provenance. SILENT FILTERING of subjects that have no identity or no table. Both
# counts must stay EXPLICIT: a subject dropped from the denominator is indistinguishable from one that
# never existed, which is the laundering the typed reconciliation exists to prevent. The mutation
# stops counting untabled subjects, so the reconciliation no longer balances.
add "manifest-no-silent-filtering" "scripts/gen/attestation_manifest.sh" "check_attestation_manifest.sh" no \
  $'  if [ "$tables" = "-" ] || [ -z "$tables" ]; then UNTABLED=$((UNTABLED+1)); continue; fi' \
  $'  if [ "$tables" = "-" ] || [ -z "$tables" ]; then continue; fi'

# R-0004 attestation provenance. THE DUPLICATE PATH IS LIVE. Deleting the duplicate check could not
# kill — duplicates are 0 in this corpus, so removing a check with no live case is undetectable, the
# same vacuity that retargeted the surplus control. So the mutation makes the emitter record each
# mapping TWICE, which must be caught as a duplicate. A duplicate matters because it means one input
# row was counted twice, and every denominator built on it is then wrong.
add "manifest-duplicate-path-live" "scripts/gen/attestation_manifest.sh" "check_attestation_manifest.sh" no \
  $'    printf \'%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n\' "$t" "$pkg" "$mod" "$decl" "$impl" "$src" >> "$TMP/pairs.tsv"' \
  $'    printf \'%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n\' "$t" "$pkg" "$mod" "$decl" "$impl" "$src" >> "$TMP/pairs.tsv"; printf \'%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n\' "$t" "$pkg" "$mod" "$decl" "$impl" "$src" >> "$TMP/pairs.tsv"'

# R-0004 attestation provenance. SAME-NAME CROSS-PACKAGE SUBSTITUTION. The conflict key is
# (table, package, module, decl). Dropping PACKAGE from it conflates same-named declarations across
# different packages — precisely the `main.validate_header` collision that motivated scoped identity —
# so distinct implementations in distinct packages register as one key with several implementations.
# Retargeted to the awk grouping. The first version altered a `cut` field set and SURVIVED, because
# the old grep-based detection went silently inert when the key changed — it found nothing and
# reported no conflicts. That survival was a finding about the CHECK, and the check was rewritten to
# group over the whole key instead of reconstructing and grepping it.
add "manifest-key-includes-package" "scripts/gen/attestation_manifest.sh" "check_attestation_manifest.sh" no \
  $'CONFLICTS="$(awk -F\'\\t\' \'{ key = $1 FS $2 FS $3 FS $4; if (!(key in seen)) { seen[key] = $5 }' \
  $'CONFLICTS="$(awk -F\'\\t\' \'{ key = $1 FS $3 FS $4; if (!(key in seen)) { seen[key] = $5 }'

# R-0004 package 2. PARTIAL CONVERSION THAT READS AS A FINISHED ONE. A table site selects generated
# references by hand, so it can select FEWER than the manifest offers — and nothing about the result
# looks unfinished: the table reports `attested`, `scopedEntryEvidence` returns rows, and the
# definitions nobody selected are simply not described. The mutation drops one of `elfFns`'s five
# attestations, which must be caught by the per-table reconciliation (manifest rows = attested +
# NAMED exclusions), not by a count that only has to be nonzero.
add "attestation-conversion-complete" "Concrete/Proof/Proof.lean" "check_attestation_manifest.sh" yes \
  $'    , AttestedPFnDef.of checkDataFn       GeneratedAttestations.elfFns_543bfb75_check_data\n    , AttestedPFnDef.of checkMagicFn      GeneratedAttestations.elfFns_543bfb75_check_magic' \
  $'    , AttestedPFnDef.of checkMagicFn      GeneratedAttestations.elfFns_543bfb75_check_magic'

# ...and the same mutation PER CONVERTED TABLE, because the reconciliation is per table: a version
# that only reconciled the table someone happened to mutate would leave every other conversion
# unmeasured. `elfFns` above has a named exclusion, so its arithmetic is rows = attested + 1;
# `fixedCapacityFns` has none, so it is the control for the simple case rows = attested.
add "attestation-conversion-complete-fixedcapacity" "Concrete/Proof/Proof.lean" "check_attestation_manifest.sh" yes \
  $'    , AttestedPFnDef.of ringNewFn       GeneratedAttestations.fixedCapacityFns_214c7171_ring_new\n    , AttestedPFnDef.of ringPushFn      GeneratedAttestations.fixedCapacityFns_214c7171_ring_push' \
  $'    , AttestedPFnDef.of ringPushFn      GeneratedAttestations.fixedCapacityFns_214c7171_ring_push'

# R-0004 package 2, and the same family for the table whose manifest rows are FEWER than its entries.
# `parseValidateFns` has 8 entries and 3 rows, so a reader could mistake a dropped attestation for
# the known subject/callee shortfall. The reconciliation is against the MANIFEST, not the entry
# count, so dropping one still fails: 3 rows, 2 attested, 0 named exclusions.
add "attestation-conversion-complete-parsevalidate" "Concrete/Proof/Proof.lean" "check_attestation_manifest.sh" yes \
  $'    , AttestedPFnDef.of validateHeaderFieldsFn GeneratedAttestations.parseValidateFns_420510fb_validate_header_fields\n    , AttestedPFnDef.of validateVersionFn      GeneratedAttestations.parseValidateFns_420510fb_validate_version' \
  $'    , AttestedPFnDef.of validateVersionFn      GeneratedAttestations.parseValidateFns_420510fb_validate_version'

# R-0004 package 2. A DRIFTED IMPLEMENTATION ATTESTED. This is the exclusion that is NOT a
# judgement call: `evidence_classes/stale_proof` links the same theorem while its body starts `diff`
# at 1, and the compiler reports SPEC DRIFT for it. The mutation selects that manifest row anyway —
# which is what a conversion driven mechanically off the manifest would do, since the manifest's
# header-grep drift classifier does not exclude it. Killed by the drift check, which re-derives the
# verdict from the compiler rather than from the fixture's prose.
#
# It SWAPS a legitimate reference for the drifted one rather than adding it, deliberately: adding
# would also break the row/attestation arithmetic, so the kill could come from the reconciliation
# and the drift check would never be exercised. With the swap the counts still reconcile (3 rows =
# 2 attested + 1 declared exclusion) and only the drift check can catch it — and only because it
# reads what the table site BOUND, not what the exclusion list DECLARED.
add "attestation-never-binds-drifted-impl" "Concrete/Proof/Proof.lean" "check_attestation_manifest.sh" yes \
  $'    , AttestedPFnDef.of ctCompareFn GeneratedAttestations.ctTagFns_404dc2c1_ct_compare ]' \
  $'    , AttestedPFnDef.of ctCompareFn GeneratedAttestations.ctTagFns_13c8e415_ct_compare ]'

# R-0004 package 2. A DEPENDENCY REFERENCE LEFT UNBOUND. The subject/dependency split only matters if
# an unbound reference is caught, and the earlier reconciliation could not see one: it compared
# attestations against SUBJECT rows, so dropping a dependency binding left the counts agreeing. The
# reconciliation now runs over the distinct reference set for each table, so a model the table could
# describe exactly and does not is a failure.
add "attestation-dependency-reference-bound" "Concrete/Proof/Proof.lean" "check_attestation_manifest.sh" yes \
  $'    [ AttestedPFnDef.of computeChecksumFn      GeneratedAttestations.parseValidateFns_420510fb_compute_checksum\n    , AttestedPFnDef.of parseHeaderFn          GeneratedAttestations.parseValidateFns_420510fb_parse_header' \
  $'    [ AttestedPFnDef.of parseHeaderFn          GeneratedAttestations.parseValidateFns_420510fb_parse_header'

# R-0004 package 2. THE ENTRANCE ASSERTION MUST BE ABLE TO SAY NO. It exists to be red until the flip
# is safe, and a completion gate that cannot fail is worse than none — it converts an unchecked
# assumption into a green check. The mutation returns one table to the unattested state, which is
# precisely the condition the flip must not proceed over.
#
# THE FIRST VERSION OF THIS MUTATION SURVIVED, and the survival was a finding about the mutation
# rather than about the gate: it appended `[] |>.withAttestations` before the real list, so the table
# was attested with nothing and then attested again with everything — a no-op. The harness reported
# SURVIVED, which is the honest answer for a mutation that changed no behaviour. It now empties the
# attestation list outright, which is the actual unattested state.
add "atomic-flip-entrance-refuses-pending" "Concrete/Proof/Proof.lean" "check_atomic_flip_entrance.sh" yes \
  $'    [ AttestedPFnDef.of fcTagFn         GeneratedAttestations.fixedCapacityFns_214c7171_compute_tag\n    , AttestedPFnDef.of ringContainsFn  GeneratedAttestations.fixedCapacityFns_214c7171_ring_contains\n    , AttestedPFnDef.of ringNewFn       GeneratedAttestations.fixedCapacityFns_214c7171_ring_new\n    , AttestedPFnDef.of ringPushFn      GeneratedAttestations.fixedCapacityFns_214c7171_ring_push ]' \
  $'    []'

# ...and it must also refuse a table whose bound references are not LOAD-BEARING. Binding an
# attestation the scoped lookup cannot answer with would satisfy "pending is zero" while carrying
# nothing: the mutation attests a model the table does not hold, which `scopedEntryEvidence` refuses
# as `attestedModelNotInTable` — so the membership no longer equals the bound count.
add "atomic-flip-entrance-refuses-inert-binding" "Concrete/Proof/Proof.lean" "check_atomic_flip_entrance.sh" yes \
  $'    [ AttestedPFnDef.of checkClassFn      GeneratedAttestations.elfFns_543bfb75_check_class' \
  $'    [ AttestedPFnDef.of checkNonceFn      GeneratedAttestations.elfFns_543bfb75_check_class'


# ---------------------------------------------------------------------------
# R-0004 package 2: THE SCOPED JOIN'S FIVE ATTACK CLASSES. The flip replaced a name-keyed evidence
# join with an identity-keyed one; each mutation below removes one component of that identity or one
# of the join's refusals, and each must be caught by a control that exists on the real corpus where
# one exists, and synthetically where the corpus has no case.
# ---------------------------------------------------------------------------

# COLLISION: two programs declaring the same functions. Dropping the PACKAGE component makes
# `main_drifted`'s edges match `elfFns` again — the exact substitution the flip closed, measured on
# a real fixture rather than argued.
add "scoped-identity-compares-package" "Concrete/Proof/DefinitionIdentity.lean" "check_dependency_edges.sh" yes \
  $'  a.packageIdentity == b.packageIdentity\n    && a.moduleIdentity == b.moduleIdentity' \
  $'  a.moduleIdentity == b.moduleIdentity'

# SUBSTITUTION: the same declaration in the same package with a DIFFERENT body. The corpus has no
# such pair — that would be one program compiled twice — so the control is synthetic, and dropping
# the implementation component must still be caught.
add "scoped-identity-compares-implementation" "Concrete/Proof/DefinitionIdentity.lean" "check_dependency_edges.sh" yes \
  $'    && a.declarationIdentity == b.declarationIdentity\n    && a.implementationIdentity == b.implementationIdentity' \
  $'    && a.declarationIdentity == b.declarationIdentity'

# OMISSION: an edge the compiler HAS whose callee cannot be keyed. Dropping it before the join leaves
# every result set empty while the closure covers less than was asked — fail-open, and invisible
# without a control, since the corpus currently has no unkeyable edge.
add "scoped-join-carries-unkeyable-edges" "Concrete/Proof/Correspondence.lean" "check_dependency_edges.sh" yes \
  $'  let unscopedRefusals := i.unscopedEdges.map (fun (c, k, w) => WitnessRefusal.unscopedCallee c k w)' \
  $'  let unscopedRefusals : List WitnessRefusal := []'

# MISATTACHMENT: a theorem whose table does not hold the callee's definition. Making membership
# answer `true` regardless restores `proof_pressure`'s false correspondence AND `main_drifted`'s.
#
# THE FIRST VERSION OF THIS MUTATION SURVIVED, and the survival was a finding about the CORPUS: it
# made an UNREADABLE table justify its edges, and every table this corpus names is now readable, so
# the branch it flipped has no live case. That is why the unreadable-table refusal is asserted
# directly by a probe instead — a branch with no corpus case needs a control, not a mutation that
# silently tests nothing.
add "scoped-join-membership-answers-identity" "Concrete/Proof/DependencyEdge.lean" "check_dependency_edges.sh" yes \
  $'def scopedEvidenceContains (rows : List ScopedEntryEvidence) (d : DefinitionIdentity) : Bool :=\n  rows.any (fun r => r.definition.sameDefinition d)' \
  $'def scopedEvidenceContains (rows : List ScopedEntryEvidence) (d : DefinitionIdentity) : Bool :=\n  let _ := d\n  !rows.isEmpty'


# AUTHORITY: a friendly verdict must survive its dependency justification. The mutation makes the
# authority pass accept every subject, which is the state the corpus was in before it was wired —
# and `main_drifted`'s cross-program closure reports `proved` again.
add "authority-consumes-correspondence" "Concrete/Proof/ProofCore.lean" "check_dependency_edges.sh" yes \
  $'      if i.requestedEdges.isEmpty && i.unscopedEdges.isEmpty then true\n      else (Proof.correspond i).usable i.requestedEdges.length' \
  $'      if i.requestedEdges.isEmpty && i.unscopedEdges.isEmpty then true\n      else true'


# R-0004 package 2. THE LEAF-BOUNDARY RULE. Only a TRUSTED exclusion may be a dependency-node leaf:
# an ineligible callee is unprovable, and a closure over it must refuse rather than serialize. The
# mutation removes the filter, so every excluded definition becomes a leaf again — killed by the
# probe that CALLS `dependencyNodesOf` with one trusted and one ineligible exclusion and reads the
# node set. An earlier probe asserted two facts about `isCurrentForDependents` instead and never
# touched the node builder, so this mutation would have survived it.
add "root-leaf-only-trusted-exclusions" "Concrete/Proof/ProofCore.lean" "check_dependency_edges.sh" yes \
  $'    if !x.eligibility.isTrusted then none else' \
  $'    if false then none else'


# R-0004 package 2. THE PROVED-ROOTS INVARIANT MUST BE LOAD-BEARING. It is expected to hold vacuously
# on this corpus — every subject whose root refuses is already not `proved` — so the only way to know
# it works is to remove it and watch a control go red. The mutation drops it from the violation list
# that `selfCheck` returns, which is exactly how it would be lost in a refactor.
#
# NEUTRALIZED, NOT DELETED. Deleting the operand fails to compile (the record literals take their
# expected type from this concatenation) and deleting the binding fails an unused-binding lint — the
# harness called both INVALID, correctly, since a mutation that cannot compile tests nothing.
# `.take 0` keeps every binding live and every type inferable while making the invariant report
# nothing, which is precisely the behaviour a silent regression would have.
add "proved-roots-invariant-reported" "Concrete/Proof/ProofCore.lean" "check_dependency_edges.sh" yes \
  $'  oblKnown ++ oblStatus ++ provedRoots ++ provedExtracted ++ provedFp ++ staleFp' \
  $'  oblKnown ++ oblStatus ++ (provedRoots.take 0) ++ provedExtracted ++ provedFp ++ staleFp'

N=${#NAME[@]}
PASS=0; FAIL=0

# PRECONDITION: every file this run will mutate must be clean.
#
# Restore is `git checkout --`, which discards whatever is in the working tree. If a file
# is already modified when we start — by a previous run that died, or by someone's
# in-progress edit — this script silently destroys that work, and worse, a mutation
# stranded by an earlier abort is treated as pristine source. The later families then run
# their gates against a doubly-mutated tree and their KILLED/SURVIVED verdicts are wrong
# without saying so.
#
# Observed 2026-07-31: a `pkill` of this script left Concrete/Check/Layout.lean mutated,
# because the EXIT trap does not fire on signal-based termination (now also trapped
# below). Recovery depended on someone running `git status`, not on the tooling.
# check_multi_kernel.sh already refuses to run dirty for exactly this reason; this is the
# same guard.
DIRTY=""
for f in $(printf "%s\n" "${FILE[@]}" | sort -u); do
  git diff --quiet -- "$f" 2>/dev/null || DIRTY="$DIRTY $f"
done
if [ -n "$DIRTY" ]; then
  echo "error: refusing to run — these files have uncommitted changes and would be" >&2
  echo "       DESTROYED by the restore step:$DIRTY" >&2
  echo "       Commit, stash, or 'git checkout --' them first. If a previous run was" >&2
  echo "       killed, verify the diff is yours before discarding it." >&2
  exit 2
fi

TMP=$(mktemp -d)
# INT/TERM as well as EXIT: plain EXIT did not restore the tree when this script was
# killed (observed 2026-07-31, Layout.lean left mutated). The handler re-raises so the
# exit status still reflects the signal.
#
# KNOWN LIMIT, measured rather than assumed: bash defers a trap until the current
# foreground command returns, so a TERM delivered while `lake build` is running does not
# take effect for however long that build has left — verified by sending TERM to a run
# mid-build and watching it continue. Restoration is therefore reliable but NOT prompt.
# If you must stop a run immediately, kill the build too, then check `git status` before
# doing anything else; the dirty-tree guard above will refuse the next run rather than
# silently treating a stranded mutation as pristine source, which is the failure this
# pair of mechanisms exists to prevent.
restore_all(){ rm -rf "$TMP"; git checkout -- $(printf "%s " "${FILE[@]}" | tr " " "\n" | sort -u) 2>/dev/null; }
trap 'restore_all' EXIT
trap 'restore_all; trap - INT TERM; kill -s INT $$' INT
trap 'restore_all; trap - INT TERM; kill -s TERM $$' TERM

apply(){ # file oldfile newfile
  python3 - "$1" "$2" "$3" <<'PY'
import sys
f,ofl,nfl=sys.argv[1],sys.argv[2],sys.argv[3]
src=open(f).read(); old=open(ofl).read(); new=open(nfl).read()
assert src.count(old)>=1, f"OLD not found in {f}"
open(f,'w').write(src.replace(old,new,1))
PY
}

run_one(){
  local i="$1"
  local nm="${NAME[$i]}" file="${FILE[$i]}" gate="scripts/tests/${GATE[$i]}" needs="${BUILD[$i]}"
  printf '%s\n' "${OLD[$i]}" > "$TMP/old"; printf '%s\n' "${NEW[$i]}" > "$TMP/new"
  # strip the trailing newline the printf added (match raw substring)
  perl -i -pe 'chomp if eof' "$TMP/old" "$TMP/new"
  echo "--- family $((i+1))/$N: $nm ($file -> ${GATE[$i]}) ---"
  if ! apply "$file" "$TMP/old" "$TMP/new" 2>"$TMP/aerr"; then
    echo "  FAIL $nm: could not apply mutation ($(cat "$TMP/aerr"))"; FAIL=$((FAIL+1)); git checkout -- "$file" 2>/dev/null; return
  fi
  local killed=0 note="" invalid=0
  if [ "$needs" = yes ]; then
    if ! "$LAKE" build >"$TMP/build.log" 2>&1; then
      # A build failure is NOT automatically a kill. Distinguish two very different things:
      #
      #   * the type system (or a proof) REJECTED the mutation — a real and strong result,
      #     stronger than a gate going red, because the defect is unrepresentable; versus
      #   * the mutation is simply BROKEN — most often an unused binding, which this project
      #     treats as an error, so replacing `emit (...)` with `pure ()` or dropping a use of
      #     `len`/`mnem`/`hintR` fails to compile for a reason that has nothing to do with the
      #     rule under test.
      #
      # The second case reported KILLED four times this week. Each time the family passed
      # while testing NOTHING, and once the gate silently ran the previous binary. A harness
      # that cannot tell "unrepresentable" from "my patch is malformed" manufactures exactly
      # the false green it exists to prevent.
      # ORDER MATTERS, and getting it wrong is easy: a genuine rejection often emits a lint
      # warning ALONGSIDE the real error (removing the div range check breaks
      # `div_obligation_necessary` AND leaves a simp argument unused). Checking for the lint
      # first therefore misclassifies real kills as invalid — which my first version did,
      # caught by self-testing both directions instead of only the one I was fixing.
      #
      # So: look for a GENUINE error first. Only a failure that is lint-and-nothing-else is
      # an invalid mutation.
      if grep -qE "unsolved goals|[Tt]ype mismatch|Unknown identifier|Unknown constant|\
failed to synthesize|Missing cases|declaration uses 'sorry'" "$TMP/build.log"; then
        killed=1
        note="(killed by build — type system or a proof rejected the mutation)"
      elif grep -qE "unused variable|This simp argument is unused|unused binding" "$TMP/build.log"; then
        invalid=1
        note="(INVALID mutation — build failed on an unused-binding lint, not on the rule; \
rewrite it so every binding stays live, e.g. change an operand rather than deleting a call)"
      else
        invalid=1
        note="(INVALID mutation — build failed for an unrecognised reason; inspect the log \
rather than counting it as a kill)"
      fi
    fi
  fi
  if [ "$invalid" -eq 1 ]; then
    echo "  FAIL $nm $note"; FAIL=$((FAIL+1))
    git checkout -- "$file" 2>/dev/null
    return
  fi
  if [ "$killed" -eq 0 ]; then
    if bash "$gate" >"$TMP/gate.log" 2>&1; then
      note="(SURVIVED — gate stayed green)"
    else
      killed=1; note="(killed by ${GATE[$i]})"
    fi
  fi
  git checkout -- "$file" 2>/dev/null
  if [ "$killed" -eq 1 ]; then echo "  ok   $nm KILLED $note"; PASS=$((PASS+1));
  else echo "  FAIL $nm $note"; FAIL=$((FAIL+1)); fi
}

echo "=== gate mutation coverage: $N families ==="
if [ -n "$ONLY" ]; then run_one "$((ONLY-1))"; else for i in $(seq 0 $((N-1))); do run_one "$i"; done; fi

# leave a clean binary behind
echo "--- restoring clean build ---"
"$LAKE" build >/dev/null 2>&1 || echo "  warn: clean rebuild failed; run 'lake build'"

echo
echo "GATE-MUTATION-COVERAGE: PASS=$PASS FAIL=$FAIL (of $N families)"
[ "$FAIL" -eq 0 ]
