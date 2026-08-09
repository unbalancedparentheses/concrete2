-- Generator for `Concrete/Proof/ClassificationTable.lean`. Do not hand-edit the OUTPUT.
--
-- Classification reads a theorem's ELABORATED TYPE, which needs the proof modules imported.
-- The compiler imports neither and cannot: `Examples` imports `Concrete`, so importing the
-- proofs from `Concrete` would be a cycle. The answer is computed here and checked in as data.
--
-- THE NAME SET IS THE UNION OF BOTH WAYS A PROOF CAN BE ATTACHED, and getting that wrong is
-- how the first version of this table looked complete while missing a third of the corpus:
--
--   * `Proof.provedFunctions` — the hardcoded table;
--   * `#[proof_by(...)]` / `#[ensures_proof(...)]` in SOURCE — spliced in below by
--     `scripts/gen/refresh_classifications.sh`, which greps them from examples/.
--
-- `main.verify_message` was `proved` with a REFUSING dependency root because only the first
-- set was enumerated. Its theorem classifies as `body` perfectly well; nobody had asked.
--
-- Regenerate: bash scripts/gen/refresh_classifications.sh
import Concrete
import Examples
open Lean Meta Concrete Concrete.Proof

/-- Source-linked proof names, spliced by the refresh script. -/
def sourceLinkedThms : List Name :=
  [ `Concrete.Proof.compute_checksum_correct,
    `Examples.ConstantTimeTag.Proofs.ct_compare_different_tag_correct,
    `Examples.ConstantTimeTag.Proofs.ct_compare_same_tag_correct,
    `Examples.CryptoVerify.Proofs.check_nonce_correct,
    `Examples.CryptoVerify.Proofs.compute_tag_correct,
    `Examples.CryptoVerify.Proofs.verify_message_composed_correct,
    `Examples.CryptoVerify.Proofs.verify_tag_correct,
    `Examples.DoesNotExist.fake_theorem,
    `Examples.ElfHeader.Proofs.check_class_correct,
    `Examples.ElfHeader.Proofs.check_data_correct,
    `Examples.ElfHeader.Proofs.check_magic_correct,
    `Examples.ElfHeader.Proofs.check_version_correct,
    `Examples.ElfHeader.Proofs.validate_header_correct,
    `Examples.FixedCapacity.Proofs.compute_tag_zero_correct,
    `Examples.FixedCapacity.Proofs.ring_new_correct,
    `Examples.FixedCapacity.Proofs.ring_push_then_contains_correct,
    `Examples.FixedCapacity.Proofs.ring_push_zero_correct,
    `Examples.HmacSha256.Proofs.block_to_words_at_refines_spec,
    `Examples.HmacSha256.Proofs.block_to_words_refines_spec,
    `Examples.HmacSha256.Proofs.ch_refines,
    `Examples.HmacSha256.Proofs.ch_selects_high,
    `Examples.HmacSha256.Proofs.hmac_sha256_refines_spec,
    `Examples.HmacSha256.Proofs.round_refines_list,
    `Examples.HmacSha256.Proofs.sha256_compress_at_refines_spec,
    `Examples.HmacSha256.Proofs.sha256_compress_refines_spec,
    `Examples.HmacSha256.Proofs.sha256_hash_refines_spec,
    `Examples.HmacSha256.Proofs.sha256_init_correct,
    `Examples.HmacSha256.Proofs.sha256_schedule_refines_spec,
    `Examples.HmacSha256.Proofs.state_to_bytes_refines_spec,
    `Examples.LoopInvariant.Proofs.count_up_loop_preserves,
    `Examples.ParseValidate.Proofs.parse_header_too_short,
    `Examples.ParseValidate.Proofs.validate_header_fields_success,
    `Examples.ParseValidate.Proofs.validate_version_correct,
    `Examples.ProofPatterns.Proofs.add_three_correct,
    `Examples.ProofPatterns.Proofs.add_three_not_yet_proved,
    `Examples.ProofPatterns.Proofs.combine_correct,
    `Examples.ProofPatterns.Proofs.copy2_copies_faithfully,
    `Examples.ProofPatterns.Proofs.dbl_correct,
    `Examples.ProofPatterns.Proofs.ghost_sum_correct,
    `Examples.ProofPatterns.Proofs.inc_correct,
    `Examples.ProofPatterns.Proofs.put_writes_index_1_frames_rest,
    `Examples.ProofPatterns.Proofs.scale_by_two_correct,
    `Examples.ProofPatterns.Proofs.sum4_totals_concrete
  ]

#eval show MetaM Unit from do
  let hardcoded := (Proof.provedFunctions.map (fun t => t.2.2)).map (·.toName)
  let names := (hardcoded ++ sourceLinkedThms).eraseDups
  let rows ← classifyAll names
  -- Rows whose edge is `unclassified` are OMITTED: `classifiedEdgeOf` already answers
  -- `unclassified` for an absent name, so listing them would state the default twice and grow
  -- the table with rows that say nothing.
  let useful := rows.filter (fun r => r.2.edge != DependencyEdge.unclassified)
  let lits := useful.map fun (n, ev) => s!"  (\"{n}\", \"{ev.edge.canonical}\")"
  IO.println (String.intercalate ",\n" lits)
