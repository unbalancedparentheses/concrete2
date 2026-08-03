#!/usr/bin/env bash
# R-0004 V2 input — TypeId / FieldId / VariantId, and `definedIn` provenance.
#
# A type reference in evidence must name the DECLARATION it resolved to, not the
# spelling at the use site. Two same-named types in different modules are two
# types; an import alias is not a third.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
[ -x ".lake/build/bin/concrete" ] || { echo "error: build first" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
probe() {
  local label="$1" want="$2" body="$3"
  printf 'import Concrete\nopen Concrete\n%s\n' "$body" > "$TMP/p.lean"
  local out; out="$(lake env lean "$TMP/p.lean" 2>&1 || true)"
  if grep -qE "error:|error\(lean" <<<"$out"; then
    no "$label — probe did not elaborate: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-150)"
  elif grep -qF -- "$want" <<<"$out"; then ok "$label"
  else no "$label — got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-150)"; fi
}

echo "=== identity, not spelling ==="
probe "same type name in two modules are different types" "false" \
'#eval (TypeId.ofUser "m1" "Point").render == (TypeId.ofUser "m2" "Point").render'
probe "a builtin is not a user type of the same name" "false" \
'#eval (TypeId.ofBuiltin "Option").render == (TypeId.ofUser "m" "Option").render'
# A builtin has NO defining module. Empty must mean "none exists", not "unknown".
probe "a builtin carries no defining module" "true" \
'#eval (TypeId.ofBuiltin "Option").defModule.isEmpty && (TypeId.ofBuiltin "Option").ns == TypeNamespace.builtin'
probe "the namespace list covers every constructor" "true" \
'#eval TypeNamespace.all.length == 2
  && (TypeNamespace.all.map TypeNamespace.canonical).eraseDups.length == 2'

echo ""
echo "=== a field/variant is named by its OWNER, not by its own name ==="
# Two structs may both have `x`; the field name alone is not an identity.
probe "same field name on different types differs" "false" \
'#eval ({ owner := TypeId.ofUser "m" "A", field := "x" } : FieldId).render
     == ({ owner := TypeId.ofUser "m" "B", field := "x" } : FieldId).render'
probe "same variant name on different enums differs" "false" \
'#eval ({ owner := TypeId.ofUser "m" "A", variant := "Yes" } : VariantId).render
     == ({ owner := TypeId.ofUser "m" "B", variant := "Yes" } : VariantId).render'
probe "a field and a variant of one name do not collide" "false" \
'#eval ({ owner := TypeId.ofUser "m" "A", field := "x" } : FieldId).render
     == ({ owner := TypeId.ofUser "m" "A", variant := "x" } : VariantId).render'

echo ""
echo "=== definedIn is populated at every ingress path ==="
CC=".lake/build/bin/concrete"
# The ALIASED import is the case that separates real provenance from a name copy:
# bug 064's fix makes `name` the local spelling, so origin must come from
# definedIn or it is lost.
cat > "$TMP/prov.con" <<'CON'
mod lib { pub struct Copy Point { pub x: Int, pub y: Int } }
mod app {
    import lib.{ Point as Coord };
    fn use_alias(c: Coord) -> Int { return c.x; }
    pub fn main() -> Int { return use_alias(Coord { x: 1, y: 2 }); }
}
CON
if "$CC" "$TMP/prov.con" >/dev/null 2>&1; then
  ok "an aliased imported type still compiles (bug 064 stays fixed)"
else
  no "the aliased-import program regressed"
fi
# Structural: no ingress path may drop provenance.
paths=$( { grep -c "definedIn :=" "$ROOT_DIR/Concrete/Resolve/FileSummary.lean" || true; } )
[ "${paths:-0}" -ge 5 ] \
  && ok "all ingress paths stamp definedIn ($paths sites)" \
  || no "only ${paths:-0} definedIn sites in FileSummary — an ingress path drops provenance"
# definedIn must be a String, not an Option: one declaration, one identity,
# regardless of which side of an import it is seen from.
probe "definedIn is not optional" "true" \
'#eval ({ name := "S", fields := [] } : StructDef).definedIn == ""'

echo ""
echo "BUILTIN types have no module, so they need the namespace, not a blank one"
probe "a blank-module USER type is distinguishable from a builtin" "false" \
'#eval (TypeId.ofUser "" "Option").render == (TypeId.ofBuiltin "Option").render'

echo ""
echo "TYPE-IDENTITY: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
