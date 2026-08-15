#!/usr/bin/env bash
# Emit `Concrete/Proof/GeneratedAttestations.lean` from the attestation manifest.
#
# These are the OPAQUE TYPED REFERENCES a proof author selects. Nobody transcribes a package identity
# or a digest: hand-copied digests go stale silently, and a hand-written package name is the collision
# scoped identity exists to remove.
#
# `Except`-typed, deliberately. `DefinitionIdentity.of?` validates and its constructor is private, so
# a reference that fails validation stays a REFUSAL rather than becoming a value — the `needs_recheck`
# disposition, not a default.
#
# One symbol per (table, package, declaration), because a table reused across packages needs one
# attestation PER PACKAGE and collapsing them is what the scoped identity exists to prevent.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

MAN="$(bash scripts/gen/attestation_manifest.sh 2>/dev/null)" || {
  echo "FATAL: the manifest refused; refusing to emit references from it" >&2; exit 1; }

OUT="Concrete/Proof/GeneratedAttestations.lean"
{
  echo "import Concrete.Proof.DefinitionIdentity"
  echo
  echo "/-!"
  echo "# Generated attestation references — do not edit"
  echo
  echo "Emitted by \`scripts/gen/attestation_refs.sh\` from the attestation manifest, which is itself"
  echo "derived from compiler-produced subject facts. A proof author SELECTS one of these symbols; the"
  echo "components are never written by hand."
  echo
  echo "\`Except\`-typed because \`of?\` validates and the constructor is private: a reference that fails"
  echo "validation stays a refusal rather than becoming a value."
  echo "-/"
  echo
  echo "namespace Concrete.Proof.GeneratedAttestations"
  echo
  printf '%s\n' "$MAN" | grep ' <- ' | grep -v EXCLUDED | while read -r line; do
    tbl="${line%% <-*}"
    rest="${line#* <- }"
    pkgdecl="${rest%% *}"
    pkg="${pkgdecl%%/*}"
    moddecl="${pkgdecl#*/}"
    mod="${moddecl%%.*}"
    decl="${moddecl#*.}"
    impl="$(printf '%s' "$rest" | grep -oE 'impl=[0-9a-f]+' | cut -d= -f2)"
    [ -n "$impl" ] || continue
    # Symbol names the TABLE, the PACKAGE and the DECLARATION. A name omitting the package would
    # collide across packages for a reused table, which is the collapse this exists to prevent.
    tblshort="$(printf '%s' "$tbl" | sed 's/.*\.//')"
    sym="$(printf '%s_%s_%s' "$tblshort" "${pkg:0:8}" "$decl" | tr -c 'A-Za-z0-9_' '_')"
    echo "def $sym : Except DefinitionIdentityRefusal DefinitionIdentity :="
    echo "  DefinitionIdentity.of? \"$pkg\" \"$mod\" \"$decl\" \"$impl\""
  done
  echo
  echo "end Concrete.Proof.GeneratedAttestations"
} > "$OUT"

echo "wrote $OUT ($(grep -c '^def ' "$OUT") references)"
