### Research: Consolidating docs/verification Into One Verification Specification (2026-10-29)

Added [a research note](research/process/verification-docs-consolidation-2026-10.md) for
R-0554 item 5. It inventories the 59 files in `docs/verification/`, giving each file's role and
the scripts, workflows and Lean sources that read it. It records where the documents overlap and
sixteen places where they contradict each other, among them two documents that each claim to be the
one public statement, a ranked tier list against "evidence is a vector, not a ladder", two
meanings of `solver_checked`, and proof-eligibility gates described as both advisory and
required. It proposes nine verification chapters in the `docs/spec` format (CLAIM-, PROV-, ATT-,
OBL-, SMT-, KRN-, RCPT-, TCB- and REG-), the `spec.py` and `one_spec.py` extensions they need,
twelve migration slices, and eleven decisions for the owner. No document is moved or changed and
no policy is decided.
