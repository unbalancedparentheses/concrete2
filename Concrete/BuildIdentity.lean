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
<<<<<<< HEAD
<<<<<<< HEAD
def buildIdentity : String := "60bb29dc8b6e66c9427b2ad0064f2626"
||||||| parent of 08b91316 (fix: bug 091 normalized place rule — Codex static review: no parentheses in Check, exact provenance paths)
def buildIdentity : String := "13374fa6583c03971aa3cf243991d8ad"
=======
def buildIdentity : String := "aa8388a9d733729da0b763e072e0755b"
>>>>>>> 08b91316 (fix: bug 091 normalized place rule — Codex static review: no parentheses in Check, exact provenance paths)
||||||| parent of 8e846e7c (fix: bug 091 normalized place rule — Codex static review pass 2: reads normalize, pre-bind provenance, nested casts)
def buildIdentity : String := "aa8388a9d733729da0b763e072e0755b"
=======
def buildIdentity : String := "1f41a5e32458234de8cd9c14aee9e6e7"
>>>>>>> 8e846e7c (fix: bug 091 normalized place rule — Codex static review pass 2: reads normalize, pre-bind provenance, nested casts)
||||||| parent of 81b0c6c3 (fix: bug 091 normalized place rule — Codex static review pass 3: every binding introduction)
def buildIdentity : String := "1f41a5e32458234de8cd9c14aee9e6e7"
=======
def buildIdentity : String := "84a1e4376f94f4c7328d5eea3204fb5d"
>>>>>>> 81b0c6c3 (fix: bug 091 normalized place rule — Codex static review pass 3: every binding introduction)
||||||| parent of 0244652e (fix: bug 091 normalized place rule — Codex static review pass 4: references stored in aggregates)
def buildIdentity : String := "84a1e4376f94f4c7328d5eea3204fb5d"
=======
def buildIdentity : String := "ba1d3d478c8838a74e6d38ab01dc42b3"
>>>>>>> 0244652e (fix: bug 091 normalized place rule — Codex static review pass 4: references stored in aggregates)
||||||| parent of df237863 (fix: bug 091 normalized place rule — Codex static review pass 5: the rule's type knowledge fails closed)
def buildIdentity : String := "ba1d3d478c8838a74e6d38ab01dc42b3"
=======
def buildIdentity : String := "b1972706dc889a1c81282919e2285e81"
>>>>>>> df237863 (fix: bug 091 normalized place rule — Codex static review pass 5: the rule's type knowledge fails closed)
||||||| parent of 9812b805 (fix: bug 091 normalized place rule — Codex static review pass 6: aliases resolved, nested-reference binders)
def buildIdentity : String := "b1972706dc889a1c81282919e2285e81"
=======
def buildIdentity : String := "59ca5de370fb64cc7476a17ebfe86d25"
>>>>>>> 9812b805 (fix: bug 091 normalized place rule — Codex static review pass 6: aliases resolved, nested-reference binders)
||||||| parent of a099d1c3 (fix: bug 091 normalized place rule — Codex static review pass 7: casts resolve aliases)
def buildIdentity : String := "59ca5de370fb64cc7476a17ebfe86d25"
=======
def buildIdentity : String := "520d8e8d226cccfd593d7dd580195a44"
>>>>>>> a099d1c3 (fix: bug 091 normalized place rule — Codex static review pass 7: casts resolve aliases)

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
