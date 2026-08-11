import Concrete.Proof.Sha256Spec

/-!
# Content hashing

`shortHash` is GENERAL — it digests toolchain identifiers, workspace identifiers, import sets,
table values, theorem artifacts, dependency and assumption sets, and body fingerprints. It is not
body-specific, so it does not belong in `BodyIdentity` even though the body digest is built from
it; naming a general helper after one of its callers is how a "canonical producer" ends up with a
second copy elsewhere.

Imports `Sha256Spec` and nothing else, so it sits below everything that hashes.
-/

namespace Concrete

/-- Two-digit lowercase hex of a byte. -/
private def byteToHex (b : Sha256Spec.Byte) : String :=
  let digits := "0123456789abcdef".toList
  let n := b.toNat
  String.ofList [digits.getD (n / 16) '0', digits.getD (n % 16) '0']

/-- Compact, stable hex hash of a body fingerprint, for the in-source
    `#[proof_fingerprint("…")]` attribute. The full PExpr string is grotesque in
    source, so we store a digest. SHA-256 truncated to 128 bits: the previous
    64-bit non-cryptographic `String.hash` defended against accidental drift but
    not against a crafted body that collides with the recorded fingerprint —
    a silent stale→proved upgrade. Reuses the in-repo FIPS 180-4 spec
    (`Concrete.Sha256Spec`), so the digest needs no new trusted code. -/
def shortHash (fingerprint : String) : String :=
  let bytes : List Sha256Spec.Byte :=
    fingerprint.toUTF8.toList.map fun b => BitVec.ofNat 8 b.toNat
  let digest := (Sha256Spec.hash bytes).take 16
  String.join (digest.map byteToHex)

end Concrete
