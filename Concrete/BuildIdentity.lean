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
||||||| parent of d105bc7c (fix: bug 091 Codex round 3 review — exclusive references, reassignment provenance)
def buildIdentity : String := "c970505bec99e70152d01cbddbeae8d2"
=======
def buildIdentity : String := "6a84c4f099a6d9cae06cad445e9c465b"
>>>>>>> d105bc7c (fix: bug 091 Codex round 3 review — exclusive references, reassignment provenance)
||||||| parent of 87c4131e (fix: bug 091 Codex round 3 review — no re-pointed references, argument borrows through parens and *)
=======
||||||| parent of 3692f038 (fix: bug 091 Codex round 3 review — newtype payload through &, one place for (*r).p and r.p)
||||||| parent of d105bc7c (fix: bug 091 Codex round 3 review — exclusive references, reassignment provenance)
def buildIdentity : String := "c970505bec99e70152d01cbddbeae8d2"
=======
def buildIdentity : String := "6a84c4f099a6d9cae06cad445e9c465b"
>>>>>>> d105bc7c (fix: bug 091 Codex round 3 review — exclusive references, reassignment provenance)
=======
>>>>>>> 3692f038 (fix: bug 091 Codex round 3 review — newtype payload through &, one place for (*r).p and r.p)
||||||| parent of ab41e479 (fix: bug 091 Codex round 3 review — no re-pointed references, argument borrows through parens and *)
def buildIdentity : String := "6a84c4f099a6d9cae06cad445e9c465b"
=======
def buildIdentity : String := "9941464b15dfa750c2ceae8ac82fcaa9"
>>>>>>> ab41e479 (fix: bug 091 Codex round 3 review — no re-pointed references, argument borrows through parens and *)
||||||| parent of 3692f038 (fix: bug 091 Codex round 3 review — newtype payload through &, one place for (*r).p and r.p)
=======
||||||| parent of 9b927620 (fix: bug 091 Codex round 3 review — nested/conditional reborrow args, borrowed heap interiors)
||||||| parent of ab41e479 (fix: bug 091 Codex round 3 review — no re-pointed references, argument borrows through parens and *)
def buildIdentity : String := "6a84c4f099a6d9cae06cad445e9c465b"
=======
def buildIdentity : String := "9941464b15dfa750c2ceae8ac82fcaa9"
>>>>>>> ab41e479 (fix: bug 091 Codex round 3 review — no re-pointed references, argument borrows through parens and *)
=======
>>>>>>> 9b927620 (fix: bug 091 Codex round 3 review — nested/conditional reborrow args, borrowed heap interiors)
||||||| parent of cf45b39e (fix: bug 091 Codex round 3 review — newtype payload through &, one place for (*r).p and r.p)
def buildIdentity : String := "9941464b15dfa750c2ceae8ac82fcaa9"
=======
def buildIdentity : String := "8afc64a24596743432018e98e8505fcb"
>>>>>>> cf45b39e (fix: bug 091 Codex round 3 review — newtype payload through &, one place for (*r).p and r.p)
||||||| parent of 9b927620 (fix: bug 091 Codex round 3 review — nested/conditional reborrow args, borrowed heap interiors)
=======
||||||| parent of b3e4942f (fix: bug 091 Codex round 3 review — branch borrows are alternatives, &self under a live reborrow)
||||||| parent of cf45b39e (fix: bug 091 Codex round 3 review — newtype payload through &, one place for (*r).p and r.p)
def buildIdentity : String := "9941464b15dfa750c2ceae8ac82fcaa9"
=======
def buildIdentity : String := "8afc64a24596743432018e98e8505fcb"
>>>>>>> cf45b39e (fix: bug 091 Codex round 3 review — newtype payload through &, one place for (*r).p and r.p)
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
||||||| parent of f950969f (fix: bug 106 — model-diff runs under a loop budget; its gate fails on hangs and crashes)
def buildIdentity : String := "38a09dc71192eb2951b6d2d4cbadc57b"
=======
def buildIdentity : String := "90d0f6b73fe5a4bb54088c51c857f23b"
>>>>>>> f950969f (fix: bug 106 — model-diff runs under a loop budget; its gate fails on hangs and crashes)
>>>>>>> 158c12cb (fix: bug 106 — model-diff runs under a loop budget; its gate fails on hangs and crashes)

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
