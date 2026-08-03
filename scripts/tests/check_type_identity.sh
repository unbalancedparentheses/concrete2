#!/usr/bin/env bash
# R-0004 V2 input: definition-site TypeId / FieldId / VariantId.
#
# These checks exercise buildFileSummary and resolveImports. Constructor-only
# probes are insufficient: the dangerous failure is a sound identity type fed
# the importer's alias, a bare nested-module name, or a transport module.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

fatal() {
  local rc=$?
  echo "FATAL: check_type_identity stopped at line ${BASH_LINENO[0]} (exit $rc)" >&2
  exit "$rc"
}
trap fatal ERR

[ -x ".lake/build/bin/concrete" ] || { echo "error: build first" >&2; exit 2; }
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/type_identity.lean" <<'LEAN'
import Concrete

open Concrete

def assertTypeIdentity (label : String) (condition : Bool) : IO Unit :=
  if condition then IO.println ("  ok   " ++ label)
  else throw (IO.userError ("FAILED: " ++ label))

def point (name : String := "Point") : StructDef :=
  { name := name
    fields := [{ name := "x", ty := .int, isPublic := true }]
    isPublic := true }

def choice (name : String := "Choice") : EnumDef :=
  { name := name
    variants := [{ name := "Yes", fields := [] }]
    isPublic := true }

def emptyModule (name : String) : Module :=
  { name := name, structs := [], enums := [], functions := [] }

def libModule : Module :=
  { name := "lib", structs := [point], enums := [choice], functions := [] }

def aliasImports : List ImportDecl :=
  [{ moduleName := "lib"
     symbols := [
       { name := "Point", alias := some "Coord" },
       { name := "Choice", alias := some "Decision" }
     ] }]

def resolveAlias : Except Diagnostics ResolvedImports :=
  resolveImports aliasImports [("lib", buildFileSummary libModule)]
    (fun m => "unknown " ++ m) (fun s m => s ++ " not public in " ++ m)

def aliasKeepsDefinitionSite : Bool :=
  match resolveAlias with
  | .error _ => false
  | .ok ri =>
      match ri.structs, ri.enums with
      | [sd], [ed] =>
          sd.name == "Coord"
            && sd.typeId? == some (TypeId.user "lib" "Point")
            && ed.name == "Decision"
            && ed.typeId? == some (TypeId.user "lib" "Choice")
      | _, _ => false

def transitiveModule : Module :=
  { name := "transitive"
    structs := [
      point "Leaf",
      { name := "Outer"
        fields := [{ name := "leaf", ty := .named "Leaf", isPublic := true }]
        isPublic := true }
    ]
    enums := []
    functions := [] }

def transitiveImports : List ImportDecl :=
  [{ moduleName := "transitive", symbols := [{ name := "Outer" }] }]

def transitiveKeepsDefinitionSite : Bool :=
  match resolveImports transitiveImports
      [("transitive", buildFileSummary transitiveModule)]
      (fun m => "unknown " ++ m) (fun s m => s ++ " not public in " ++ m) with
  | .error _ => false
  | .ok ri =>
      match ri.structs.find? (fun sd => sd.name == "Leaf") with
      | some sd => sd.typeId? == some (TypeId.user "transitive" "Leaf")
      | none => false

def nestedRoot (root : String) : Module :=
  { (emptyModule root) with
    submodules := [
      { (emptyModule "sub") with structs := [point] }
    ] }

def nestedId (root : String) : Option TypeId :=
  let table := buildSummaryTable [nestedRoot root]
  match table.find? (fun (key, _) => key == root ++ ".sub") with
  | some (_, summary) => (summary.structs.head?).bind StructDef.typeId?
  | none => none

def ownerA : TypeId := TypeId.user "m" "A"
def ownerB : TypeId := TypeId.user "m" "B"

#eval do
  assertTypeIdentity "same spelling in two modules gives different TypeIds"
    (TypeId.ofUser "m1" "Point" != TypeId.ofUser "m2" "Point")
  assertTypeIdentity "builtin identity requires and preserves BuiltinEnumId"
    (TypeId.ofBuiltin .option != TypeId.ofBuiltin .result)
  assertTypeIdentity "builtin and same-spelled user type are distinct"
    (TypeId.ofBuiltin .option != TypeId.ofUser "m" "Option")
  assertTypeIdentity "raw unresolved declarations fail closed"
    ((point).typeId?.isNone && (choice).typeId?.isNone)
  assertTypeIdentity "local summaries mint user identities"
    (((buildFileSummary libModule).structs.head?).bind StructDef.typeId?
      == some (TypeId.user "lib" "Point"))
  assertTypeIdentity "aliases change lookup spelling but not definition identity"
    aliasKeepsDefinitionSite
  assertTypeIdentity "transitive closure transports rather than remints identity"
    transitiveKeepsDefinitionSite
  assertTypeIdentity "nested modules carry their fully-qualified definition path"
    (nestedId "a" == some (TypeId.user "a.sub" "Point"))
  assertTypeIdentity "same nested spelling under different parents stays distinct"
    (nestedId "a" != nestedId "b")
  assertTypeIdentity "compiler enums derive identity from builtinId"
    (builtinOptionEnum.typeId? == some (TypeId.builtin .option)
      && builtinResultEnum.typeId? == some (TypeId.builtin .result))
  assertTypeIdentity "field identity is owner-relative"
    (({ owner := ownerA, field := "x" } : FieldId)
      != ({ owner := ownerB, field := "x" } : FieldId))
  assertTypeIdentity "variant identity is owner-relative and domain-separated from fields"
    (({ owner := ownerA, variant := "x" } : VariantId).render
      != ({ owner := ownerA, field := "x" } : FieldId).render)
LEAN

echo "=== semantic type identity through the production resolver ==="
if LEAN_OUT="$(lake env lean "$TMP_DIR/type_identity.lean" 2>&1)"; then
  :
else
  rc=$?
  printf '%s\n' "$LEAN_OUT" >&2
  echo "FATAL: semantic TypeId probe did not elaborate" >&2
  exit "$rc"
fi
printf '%s\n' "$LEAN_OUT"
if printf '%s\n' "$LEAN_OUT" | grep -Eq 'error:|error\(lean'; then
  echo "FATAL: Lean probe emitted a diagnostic" >&2
  exit 1
fi
OK_COUNT="$(printf '%s\n' "$LEAN_OUT" | grep -c '^  ok   ' || true)"
if [ "$OK_COUNT" -ne 12 ]; then
  echo "FATAL: expected 12 semantic controls, saw $OK_COUNT" >&2
  exit 1
fi

echo ""
echo "=== builtin identity cannot be minted from display text ==="
cat > "$TMP_DIR/raw_builtin.lean" <<'LEAN'
import Concrete
open Concrete
#check TypeId.ofBuiltin "Option"
LEAN
if RAW_OUT="$(lake env lean "$TMP_DIR/raw_builtin.lean" 2>&1)"; then
  echo "FATAL: TypeId.ofBuiltin accepted a raw String" >&2
  exit 1
fi
if ! printf '%s\n' "$RAW_OUT" | grep -q 'BuiltinEnumId'; then
  echo "FATAL: raw-builtin rejection was not the expected type mismatch" >&2
  printf '%s\n' "$RAW_OUT" >&2
  exit 1
fi
echo "  ok   raw strings cannot mint builtin TypeIds"

echo ""
echo "=== ordinary compiler path ==="
if .lake/build/bin/concrete tests/programs/bug_064_aliased_imported_type.con \
    >"$TMP_DIR/bug064.out" 2>"$TMP_DIR/bug064.err"; then
  echo "  ok   aliased imported type still compiles (bug 064)"
else
  echo "FATAL: bug 064 regressed" >&2
  sed -n '1,120p' "$TMP_DIR/bug064.err" >&2
  exit 1
fi

echo ""
echo "TYPE-IDENTITY: PASS=14 FAIL=0"
