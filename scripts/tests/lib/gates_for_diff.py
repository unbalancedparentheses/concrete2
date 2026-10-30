#!/usr/bin/env python3
"""The impact selector's curated tables (scripts/tests/lib/select_gates.py imports them).

The selector derives most of what a change can break from the gates themselves; these tables hold
what cannot be derived: the derived artifacts a change under a tree moves (ALWAYS_IF), the gates
every change can break (EVERY_CHANGE), and the whole-suite drivers a selection never runs in full
(NOT_AUTO_RUN). The older diff-to-gate selector that also lived here (gates_for_diff.sh, tested by
check_gates_for_diff.sh) was retired once the pre-push hook used select_gates.sh alone.
"""

# A change anywhere in these trees moves something a derived artifact is built from, so
# the freshness gates run whether or not they name the file. This set is what four
# separate CI rounds of R-0483 cost to learn: the stdlib surface manifest, the
# shadow-body extraction coupling, six inert mutation anchors, and the ByteView gate.
ALWAYS_IF = {
    "std/": [
        ("check_stdlib_manifest.sh", "the public stdlib surface is a checked-in derivation"),
        ("check_attestation_manifest.sh", "package content moves attestation identities"),
        ("check_attestation_refs_order.sh", "generated references are compared byte for byte"),
        ("check_classification_freshness.sh", "the classification table is derived from it"),
        ("check_build_identity_freshness.sh", "the embedded identity covers the sources"),
        ("check_std_compiled_coverage.sh", "one compiled probe per std module"),
    ],
    "Concrete/": [
        ("check_build_identity_freshness.sh", "the embedded identity covers these sources"),
        ("check_attestation_manifest.sh", "generated attestations derive from compiler output"),
        ("check_attestation_refs_order.sh", "generated references are compared byte for byte"),
        ("check_classification_freshness.sh", "the classification table is derived from it"),
        ("check_shadow_body_v2.sh", "structural body digests and their coverage ratchet"),
        ("check_mutation_anchors.sh", "renames make mutation anchors INERT, and silently"),
        # A compiler change can alter ANY program's behaviour or report text, and
        # `run_tests.sh` names no compiler source because it compiles the whole corpus —
        # the "broken by a change it never names" case this file warns about, made
        # concrete. Its `--trust-gate` form is listed separately because it runs the
        # self-consistency section the plain form does not, and that is what caught a
        # DIAG-STATUS disagreement introduced by an R-0484 edit to Report.lean.
        ("run_tests.sh", "a compiler change can alter any program's behaviour or output"),
    ],
    "proofs/": [
        ("check_attestation_manifest.sh", "proof links name generated attestation symbols"),
        ("check_proof_freshness.sh", "proof-to-body binding"),
    ],
    "scripts/tests/": [
        ("check_gate_hygiene.sh", "every gate must be pipe-safe and fail loudly"),
        ("check_gate_registration.sh", "a gate nothing runs proves nothing"),
        ("check_mutation_anchors.sh", "driver edits move anchor text"),
    ],
}

# A change to ANY path can break these, so every non-empty diff selects them. They are kept
# apart from ALWAYS_IF because selecting a gate is not mapping a file: a path no rule maps
# still triggers the fail-safe (every gate), which an empty-prefix ALWAYS_IF entry would
# silently switch off. A gate belongs here only if it is cheap (seconds) and its input is
# the whole tree. Bug 252: the Markdown-link gate checks links into every tracked path and
# anchors into every Markdown heading, so a docs-only edit, a renamed heading or a deleted
# file can each break it, and before it was listed nothing selected it.
EVERY_CHANGE = [
    ("check_doc_links.sh", "a Markdown link can name any path, and its anchor any heading"),
]


# NOT AUTO-RUN: the whole-suite drivers. A selection depends on them and on the helpers they run,
# but never runs every gate they could run.
#
#   run_ci_gates_local.sh          executes most of the suite itself, so running it from a
#                                  SELECTIVE runner defeats the selection, and it holds the
#                                  repository lock that exclusive gates need — which makes
#                                  those refuse and look like failures rather than like the
#                                  correct fail-closed refusal they are.
#   check_gate_mutation_coverage.sh  bare, this is a full campaign: hours, exclusive access,
#                                  and it mutates a disposable copy of the tree. It takes
#                                  FAMILY_ID/FAMILY_SPEC for a single-family run, which is
#                                  a deliberate act, not something to trigger by editing a
#                                  file it happens to name.
NOT_AUTO_RUN = {
    "run_ci_gates_local.sh": "runs most of the suite itself; run it directly",
    "check_gate_mutation_coverage.sh": "full campaign, exclusive and hours; use FAMILY_ID for one family",
}
