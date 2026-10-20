/-!
# Generated compiler build identity — do not edit

Emitted by `scripts/gen/build_identity.sh` from the compiler's own sources. A receipt binds this to
name the compiler that produced it.

EMBEDDED AT BUILD TIME on purpose. Identities derived from the repository at REPORT time —
`git status`, `git rev-parse HEAD` — describe the tree the binary is later pointed at rather than
the binary, and are wrong in both directions: a binary built from one commit claims another once the
checkout moves, and a binary built from uncommitted sources claims whatever is checked out. This
value travels with the artifact.

A run-time digest of the executable would be strictly stronger and is not portable: neither
`/proc/self/exe` nor GNU `sha256sum` exists on macOS, which is an active CI platform, and hashing
a 178 MB binary in-process is not viable with the in-repo SHA-256. **Known limit: a binary patched
after build keeps the constant its sources produced.** This identifies the BUILD, not the bytes.

Staleness is a gate failure rather than a silent wrong answer:
`check_build_identity_freshness.sh` re-derives this and fails on disagreement.
-/

namespace Concrete

/-- 128-bit digest over the compiler's own sources at build time. -/
def buildIdentity : String := "60bb29dc8b6e66c9427b2ad0064f2626"
=======
>>>>>>> b3e4942f (fix: bug 091 Codex round 3 review — branch borrows are alternatives, &self under a live reborrow)
||||||| parent of e1a51c88 (fix: bug 091 Codex round 3 review — nested/conditional reborrow args, borrowed heap interiors)
def buildIdentity : String := "8afc64a24596743432018e98e8505fcb"
=======
def buildIdentity : String := "4d6fcd563eb743b0c85d641a8c6b05a0"
>>>>>>> e1a51c88 (fix: bug 091 Codex round 3 review — nested/conditional reborrow args, borrowed heap interiors)
||||||| parent of b3e4942f (fix: bug 091 Codex round 3 review — branch borrows are alternatives, &self under a live reborrow)
=======
||||||| parent of 82324ebb (fix: bug 091 Codex round 3 review — a nested reborrow may be used while its parent is held)
||||||| parent of e1a51c88 (fix: bug 091 Codex round 3 review — nested/conditional reborrow args, borrowed heap interiors)
def buildIdentity : String := "8afc64a24596743432018e98e8505fcb"
=======
def buildIdentity : String := "4d6fcd563eb743b0c85d641a8c6b05a0"
>>>>>>> e1a51c88 (fix: bug 091 Codex round 3 review — nested/conditional reborrow args, borrowed heap interiors)
=======
>>>>>>> 82324ebb (fix: bug 091 Codex round 3 review — a nested reborrow may be used while its parent is held)
||||||| parent of a13aeb8a (fix: bug 091 Codex round 3 review — branch borrows are alternatives, &self under a live reborrow)
def buildIdentity : String := "4d6fcd563eb743b0c85d641a8c6b05a0"
=======
def buildIdentity : String := "2ab1e7072fa0849880c8d551f0d61715"
>>>>>>> a13aeb8a (fix: bug 091 Codex round 3 review — branch borrows are alternatives, &self under a live reborrow)
||||||| parent of 82324ebb (fix: bug 091 Codex round 3 review — a nested reborrow may be used while its parent is held)
=======
||||||| parent of 837fea6f (fix: bug 091 round 3 — one normalized place rule for borrows, receivers, arguments and overlap)
||||||| parent of a13aeb8a (fix: bug 091 Codex round 3 review — branch borrows are alternatives, &self under a live reborrow)
def buildIdentity : String := "4d6fcd563eb743b0c85d641a8c6b05a0"
=======
def buildIdentity : String := "2ab1e7072fa0849880c8d551f0d61715"
>>>>>>> a13aeb8a (fix: bug 091 Codex round 3 review — branch borrows are alternatives, &self under a live reborrow)
=======
>>>>>>> 837fea6f (fix: bug 091 round 3 — one normalized place rule for borrows, receivers, arguments and overlap)
||||||| parent of 4b14e540 (fix: bug 091 Codex round 3 review — a nested reborrow may be used while its parent is held)
def buildIdentity : String := "2ab1e7072fa0849880c8d551f0d61715"
=======
def buildIdentity : String := "55c97717f6baa62339941c71e0da7d16"
>>>>>>> 4b14e540 (fix: bug 091 Codex round 3 review — a nested reborrow may be used while its parent is held)
||||||| parent of 837fea6f (fix: bug 091 round 3 — one normalized place rule for borrows, receivers, arguments and overlap)
=======
||||||| parent of 2e5c8235 (fix: bug 105 contained — Check refuses a reference-valued if/match (E0238))
||||||| parent of 4b14e540 (fix: bug 091 Codex round 3 review — a nested reborrow may be used while its parent is held)
def buildIdentity : String := "2ab1e7072fa0849880c8d551f0d61715"
=======
def buildIdentity : String := "55c97717f6baa62339941c71e0da7d16"
>>>>>>> 4b14e540 (fix: bug 091 Codex round 3 review — a nested reborrow may be used while its parent is held)
=======
>>>>>>> 2e5c8235 (fix: bug 105 contained — Check refuses a reference-valued if/match (E0238))
||||||| parent of 0b897854 (fix: bug 091 round 3 — one normalized place rule for borrows, receivers, arguments and overlap)
def buildIdentity : String := "55c97717f6baa62339941c71e0da7d16"
=======
def buildIdentity : String := "7374f99d16c68754afa551e470841aca"
>>>>>>> 0b897854 (fix: bug 091 round 3 — one normalized place rule for borrows, receivers, arguments and overlap)
||||||| parent of 2e5c8235 (fix: bug 105 contained — Check refuses a reference-valued if/match (E0238))
=======
||||||| parent of 158c12cb (fix: bug 106 — model-diff runs under a loop budget; its gate fails on hangs and crashes)
||||||| parent of 0b897854 (fix: bug 091 round 3 — one normalized place rule for borrows, receivers, arguments and overlap)
def buildIdentity : String := "55c97717f6baa62339941c71e0da7d16"
=======
def buildIdentity : String := "7374f99d16c68754afa551e470841aca"
>>>>>>> 0b897854 (fix: bug 091 round 3 — one normalized place rule for borrows, receivers, arguments and overlap)
=======
>>>>>>> 158c12cb (fix: bug 106 — model-diff runs under a loop budget; its gate fails on hangs and crashes)
||||||| parent of 50299870 (fix: bug 105 contained — Check refuses a reference-valued if/match (E0238))
def buildIdentity : String := "7374f99d16c68754afa551e470841aca"
=======
def buildIdentity : String := "38a09dc71192eb2951b6d2d4cbadc57b"
>>>>>>> 50299870 (fix: bug 105 contained — Check refuses a reference-valued if/match (E0238))
||||||| parent of 158c12cb (fix: bug 106 — model-diff runs under a loop budget; its gate fails on hangs and crashes)
=======
||||||| parent of 3acf4767 (fix: bug 091 normalized place rule — Codex review: casts, reference arguments, ancestry, fail-closed heap base)
||||||| parent of 50299870 (fix: bug 105 contained — Check refuses a reference-valued if/match (E0238))
def buildIdentity : String := "7374f99d16c68754afa551e470841aca"
=======
def buildIdentity : String := "38a09dc71192eb2951b6d2d4cbadc57b"
>>>>>>> 50299870 (fix: bug 105 contained — Check refuses a reference-valued if/match (E0238))
=======
>>>>>>> 3acf4767 (fix: bug 091 normalized place rule — Codex review: casts, reference arguments, ancestry, fail-closed heap base)
||||||| parent of f950969f (fix: bug 106 — model-diff runs under a loop budget; its gate fails on hangs and crashes)
def buildIdentity : String := "38a09dc71192eb2951b6d2d4cbadc57b"
=======
def buildIdentity : String := "90d0f6b73fe5a4bb54088c51c857f23b"
>>>>>>> f950969f (fix: bug 106 — model-diff runs under a loop budget; its gate fails on hangs and crashes)
||||||| parent of 3acf4767 (fix: bug 091 normalized place rule — Codex review: casts, reference arguments, ancestry, fail-closed heap base)
=======
||||||| parent of 86c34685 (fix: bug 091 normalized place rule — Codex static review: no parentheses in Check, exact provenance paths)
||||||| parent of f950969f (fix: bug 106 — model-diff runs under a loop budget; its gate fails on hangs and crashes)
def buildIdentity : String := "38a09dc71192eb2951b6d2d4cbadc57b"
=======
def buildIdentity : String := "90d0f6b73fe5a4bb54088c51c857f23b"
>>>>>>> f950969f (fix: bug 106 — model-diff runs under a loop budget; its gate fails on hangs and crashes)
=======
>>>>>>> 86c34685 (fix: bug 091 normalized place rule — Codex static review: no parentheses in Check, exact provenance paths)
||||||| parent of 69254623 (fix: bug 091 normalized place rule — Codex review: casts, reference arguments, ancestry, fail-closed heap base)
def buildIdentity : String := "90d0f6b73fe5a4bb54088c51c857f23b"
=======
def buildIdentity : String := "2e0f72c3d6051855c78fed906488751d"
>>>>>>> 69254623 (fix: bug 091 normalized place rule — Codex review: casts, reference arguments, ancestry, fail-closed heap base)
||||||| parent of e6c0d249 (fix: bug 091 normalized place rule — Codex review pass 2: reads/writes, scoped borrows, shadowing, intrinsics)
=======
||||||| parent of f1e62480 (fix: bug 091 normalized place rule — Codex static review pass 2: reads normalize, pre-bind provenance, nested casts)
||||||| parent of 69254623 (fix: bug 091 normalized place rule — Codex review: casts, reference arguments, ancestry, fail-closed heap base)
def buildIdentity : String := "90d0f6b73fe5a4bb54088c51c857f23b"
=======
def buildIdentity : String := "2e0f72c3d6051855c78fed906488751d"
>>>>>>> 69254623 (fix: bug 091 normalized place rule — Codex review: casts, reference arguments, ancestry, fail-closed heap base)
=======
>>>>>>> f1e62480 (fix: bug 091 normalized place rule — Codex static review pass 2: reads normalize, pre-bind provenance, nested casts)
||||||| parent of e8a386f4 (fix: bug 091 normalized place rule — Codex review pass 2: reads/writes, scoped borrows, shadowing, intrinsics)
def buildIdentity : String := "2e0f72c3d6051855c78fed906488751d"
=======
def buildIdentity : String := "4f5c7d08f266f675a58507c89c213091"
>>>>>>> e8a386f4 (fix: bug 091 normalized place rule — Codex review pass 2: reads/writes, scoped borrows, shadowing, intrinsics)
||||||| parent of 7869d3ad (fix: bug 091 normalized place rule — Codex review pass 3: bare assignment, match-through-ref binders, heap field loads)
=======
||||||| parent of ea2e04ea (fix: bug 091 normalized place rule — Codex static review pass 4: references stored in aggregates)
||||||| parent of e8a386f4 (fix: bug 091 normalized place rule — Codex review pass 2: reads/writes, scoped borrows, shadowing, intrinsics)
def buildIdentity : String := "2e0f72c3d6051855c78fed906488751d"
=======
def buildIdentity : String := "4f5c7d08f266f675a58507c89c213091"
>>>>>>> e8a386f4 (fix: bug 091 normalized place rule — Codex review pass 2: reads/writes, scoped borrows, shadowing, intrinsics)
=======
>>>>>>> ea2e04ea (fix: bug 091 normalized place rule — Codex static review pass 4: references stored in aggregates)
||||||| parent of 91003b79 (fix: bug 091 normalized place rule — Codex review pass 3: bare assignment, match-through-ref binders, heap field loads)
def buildIdentity : String := "4f5c7d08f266f675a58507c89c213091"
=======
def buildIdentity : String := "13374fa6583c03971aa3cf243991d8ad"
>>>>>>> 91003b79 (fix: bug 091 normalized place rule — Codex review pass 3: bare assignment, match-through-ref binders, heap field loads)
||||||| parent of 86c34685 (fix: bug 091 normalized place rule — Codex static review: no parentheses in Check, exact provenance paths)
=======
||||||| parent of 121fa78b (fix: bug 091 normalized place rule — Codex static review pass 5: the rule's type knowledge fails closed)
||||||| parent of 91003b79 (fix: bug 091 normalized place rule — Codex review pass 3: bare assignment, match-through-ref binders, heap field loads)
def buildIdentity : String := "4f5c7d08f266f675a58507c89c213091"
=======
def buildIdentity : String := "13374fa6583c03971aa3cf243991d8ad"
>>>>>>> 91003b79 (fix: bug 091 normalized place rule — Codex review pass 3: bare assignment, match-through-ref binders, heap field loads)
=======
>>>>>>> 121fa78b (fix: bug 091 normalized place rule — Codex static review pass 5: the rule's type knowledge fails closed)
||||||| parent of 08b91316 (fix: bug 091 normalized place rule — Codex static review: no parentheses in Check, exact provenance paths)
def buildIdentity : String := "13374fa6583c03971aa3cf243991d8ad"
=======
def buildIdentity : String := "aa8388a9d733729da0b763e072e0755b"
>>>>>>> 08b91316 (fix: bug 091 normalized place rule — Codex static review: no parentheses in Check, exact provenance paths)
||||||| parent of f1e62480 (fix: bug 091 normalized place rule — Codex static review pass 2: reads normalize, pre-bind provenance, nested casts)
=======
||||||| parent of 8e846e7c (fix: bug 091 normalized place rule — Codex static review pass 2: reads normalize, pre-bind provenance, nested casts)
def buildIdentity : String := "aa8388a9d733729da0b763e072e0755b"
=======
def buildIdentity : String := "1f41a5e32458234de8cd9c14aee9e6e7"
>>>>>>> 8e846e7c (fix: bug 091 normalized place rule — Codex static review pass 2: reads normalize, pre-bind provenance, nested casts)
||||||| parent of fe03c831 (fix: bug 091 normalized place rule — Codex static review pass 3: every binding introduction)
=======
||||||| parent of 81b0c6c3 (fix: bug 091 normalized place rule — Codex static review pass 3: every binding introduction)
def buildIdentity : String := "1f41a5e32458234de8cd9c14aee9e6e7"
=======
def buildIdentity : String := "84a1e4376f94f4c7328d5eea3204fb5d"
>>>>>>> 81b0c6c3 (fix: bug 091 normalized place rule — Codex static review pass 3: every binding introduction)
||||||| parent of ea2e04ea (fix: bug 091 normalized place rule — Codex static review pass 4: references stored in aggregates)
=======
||||||| parent of 0244652e (fix: bug 091 normalized place rule — Codex static review pass 4: references stored in aggregates)
def buildIdentity : String := "84a1e4376f94f4c7328d5eea3204fb5d"
=======
def buildIdentity : String := "ba1d3d478c8838a74e6d38ab01dc42b3"
>>>>>>> 0244652e (fix: bug 091 normalized place rule — Codex static review pass 4: references stored in aggregates)
||||||| parent of 121fa78b (fix: bug 091 normalized place rule — Codex static review pass 5: the rule's type knowledge fails closed)
=======
||||||| parent of df237863 (fix: bug 091 normalized place rule — Codex static review pass 5: the rule's type knowledge fails closed)
def buildIdentity : String := "ba1d3d478c8838a74e6d38ab01dc42b3"
=======
def buildIdentity : String := "b1972706dc889a1c81282919e2285e81"
>>>>>>> df237863 (fix: bug 091 normalized place rule — Codex static review pass 5: the rule's type knowledge fails closed)
||||||| parent of 9de324af (fix: bug 091 normalized place rule — Codex static review pass 6: aliases resolved, nested-reference binders)
=======
||||||| parent of 9812b805 (fix: bug 091 normalized place rule — Codex static review pass 6: aliases resolved, nested-reference binders)
def buildIdentity : String := "b1972706dc889a1c81282919e2285e81"
=======
def buildIdentity : String := "59ca5de370fb64cc7476a17ebfe86d25"
>>>>>>> 9812b805 (fix: bug 091 normalized place rule — Codex static review pass 6: aliases resolved, nested-reference binders)
>>>>>>> 9de324af (fix: bug 091 normalized place rule — Codex static review pass 6: aliases resolved, nested-reference binders)

/-- How many source files the identity above was computed over.

    Carried so that a SHRINKING inventory is detectable. The content digest moves when a file is
    removed, but it moves the same way it does for an ordinary edit — this value distinguishes the
    two, and a digest computed over fewer files is a weaker claim wearing the same shape. -/
def buildIdentitySourceCount : Nat := 105

/-- Digest of the inventory's FILE LIST, independent of file contents.

    Moves only when files are added, removed, or renamed. Together with the count, this makes
    "the inventory changed" distinguishable from "a source changed". -/
def buildIdentityInventoryDigest : String := "5575a687796b6810869d28ec2cbe0aa4"

end Concrete
