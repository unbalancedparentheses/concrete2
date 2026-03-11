namespace Concrete

/-! ## Intrinsic IDs — compiler-internal identity for builtin operations

Builtins are **not** global function names visible to user code.
They are compiler intrinsics with an internal identity.

Resolution order:
1. User-defined functions
2. Stdlib / imported functions
3. Intrinsic fallback (only if no user/stdlib match)

Downstream phases (Check, Elab, Lower, EmitSSA) dispatch on
IntrinsicId, never on raw function-name strings.
-/

inductive IntrinsicId where
  -- Memory management
  | alloc           -- alloc(x) → Heap<T>
  | free            -- free(h) → T
  | destroy         -- destroy(x) → Unit (linear type destructor)

  -- Vec operations
  | vecNew | vecPush | vecGet | vecSet | vecLen | vecPop | vecFree

  -- HashMap operations
  | mapNew | mapInsert | mapGet | mapContains | mapRemove | mapLen | mapFree

  -- String operations
  | stringLength | stringConcat | stringEq | stringSlice
  | stringCharAt | stringContains | stringTrim | dropString

  -- Conversion
  | intToString | stringToInt | boolToString | floatToString

  -- System
  | getArgs | abort

  -- Size queries (compile-time)
  | sizeof | alignof

  -- Type operations
  | unwrap  -- newtype unwrapping
  deriving BEq, Hashable, Repr

/-- Look up an IntrinsicId from a source-level function name.

Multiple source names can map to the same intrinsic (e.g. `vec_new` and
`Vec_new` both resolve to `.vecNew`).  Returns `none` for names that are
not compiler intrinsics. -/
def resolveIntrinsic (name : String) : Option IntrinsicId :=
  match name with
  -- Memory
  | "alloc" => some .alloc
  | "free" => some .free
  | "destroy" => some .destroy

  -- Vec (snake_case and method-call PascalCase)
  | "vec_new"  | "Vec_new"  => some .vecNew
  | "vec_push" | "Vec_push" => some .vecPush
  | "vec_get"  | "Vec_get"  => some .vecGet
  | "vec_set"  | "Vec_set"  => some .vecSet
  | "vec_len"  | "Vec_len"  => some .vecLen
  | "vec_pop"  | "Vec_pop"  => some .vecPop
  | "vec_free" | "Vec_free" => some .vecFree

  -- HashMap (snake_case and method-call PascalCase)
  | "map_new"      | "HashMap_new"      => some .mapNew
  | "map_insert"   | "HashMap_insert"   => some .mapInsert
  | "map_get"      | "HashMap_get"      => some .mapGet
  | "map_contains" | "HashMap_contains" => some .mapContains
  | "map_remove"   | "HashMap_remove"   => some .mapRemove
  | "map_len"      | "HashMap_len"      => some .mapLen
  | "map_free"     | "HashMap_free"     => some .mapFree

  -- String
  | "string_length" | "string_len" | "String_len" => some .stringLength
  | "string_concat" | "String_concat"              => some .stringConcat
  | "string_eq"     | "String_eq"                  => some .stringEq
  | "string_slice"   => some .stringSlice
  | "string_char_at" => some .stringCharAt
  | "string_contains"=> some .stringContains
  | "string_trim"    => some .stringTrim
  | "drop_string"    => some .dropString

  -- Conversion
  | "int_to_string"  => some .intToString
  | "string_to_int"  => some .stringToInt
  | "bool_to_string" => some .boolToString
  | "float_to_string"=> some .floatToString

  -- System
  | "get_args"     => some .getArgs
  | "abort"        => some .abort

  -- Size queries
  | "sizeof"  | "_sizeof" => some .sizeof
  | "alignof" => some .alignof

  -- Type operations
  | "unwrap" => some .unwrap

  | _ => none

/-- Check whether a source-level name is a known intrinsic. -/
def isIntrinsic (name : String) : Bool :=
  (resolveIntrinsic name).isSome

/-- The canonical LLVM/runtime name for an intrinsic.

This is the name emitted in the final IR — it may differ from the
source-level name (e.g. `log` in source → `log` in IR). -/
def IntrinsicId.canonicalName : IntrinsicId → String
  | .alloc => "alloc"
  | .free => "free"
  | .destroy => "destroy"
  | .vecNew => "vec_new"
  | .vecPush => "vec_push"
  | .vecGet => "vec_get"
  | .vecSet => "vec_set"
  | .vecLen => "vec_len"
  | .vecPop => "vec_pop"
  | .vecFree => "vec_free"
  | .mapNew => "map_new"
  | .mapInsert => "map_insert"
  | .mapGet => "map_get"
  | .mapContains => "map_contains"
  | .mapRemove => "map_remove"
  | .mapLen => "map_len"
  | .mapFree => "map_free"
  | .stringLength => "string_length"
  | .stringConcat => "string_concat"
  | .stringEq => "string_eq"
  | .stringSlice => "string_slice"
  | .stringCharAt => "string_char_at"
  | .stringContains => "string_contains"
  | .stringTrim => "string_trim"
  | .dropString => "drop_string"
  | .intToString => "int_to_string"
  | .stringToInt => "string_to_int"
  | .boolToString => "bool_to_string"
  | .floatToString => "float_to_string"
  | .getArgs => "get_args"
  | .abort => "abort"
  | .sizeof => "sizeof"
  | .alignof => "alignof"
  | .unwrap => "unwrap"

/-- Required capability set for an intrinsic, if any. -/
def IntrinsicId.capability : IntrinsicId → Option String
  -- Process
  | .getArgs | .abort => some "Process"
  -- Alloc
  | .alloc | .free
  | .vecNew | .vecPush | .vecPop | .vecFree
  | .mapNew | .mapInsert | .mapRemove | .mapFree => some "Alloc"
  -- Pure (no capability required)
  | _ => none

end Concrete
