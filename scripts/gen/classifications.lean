-- Generator for `Concrete/Proof/ClassificationTable.lean`.
--
-- The classification reads a theorem's ELABORATED TYPE, which exists only while Lean is
-- elaborating and only with the proof modules imported. The compiler imports neither, and
-- cannot: `Examples` imports `Concrete`, so having `Concrete` import the proofs would be a
-- cycle. So the answer is computed here and checked in as DATA.
--
-- Regenerate with:
--   lake env lean scripts/gen/classifications.lean > /tmp/rows.txt
-- then splice the rows into Concrete/Proof/ClassificationTable.lean.
--
-- `check_dependency_edges.sh` asserts the checked-in table AGREES with a fresh classification,
-- so a stale table is a gate failure rather than a silent wrong answer.
import Concrete
import Examples
open Lean Meta Concrete Concrete.Proof
#eval show MetaM Unit from do
  let names := Proof.provedFunctions.map (fun t => t.2.2)
  let rows ← classifyAll (names.map (·.toName))
  let lits := rows.map fun (n, ev) => s!"  (\"{n}\", \"{ev.edge.canonical}\")"
  IO.println (String.intercalate ",\n" lits)
