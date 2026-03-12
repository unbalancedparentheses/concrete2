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
  | "string_slice"    | "String_slice"    => some .stringSlice
  | "string_char_at"  | "String_char_at"  => some .stringCharAt
  | "string_contains" | "String_contains" => some .stringContains
  | "string_trim"     | "String_trim"     => some .stringTrim
  | "drop_string"     | "String_drop"     => some .dropString

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

-- ============================================================
-- Centralized builtin name tables
-- ============================================================
-- These are the single source of truth for names that carry
-- compiler-known semantics.  Downstream passes should reference
-- these definitions instead of maintaining their own hardcoded copies.
--
-- Organisation:
--   1. Semantic language items — names that define language behaviour
--      (traits, variants, type keywords, entry point).
--   2. Compiler-reserved identifiers — names users cannot redefine
--      but whose identity is an implementation detail.
--   3. Mangling / suffix helpers — deterministic name construction
--      used by elaboration and lowering.
--   4. Convenience predicates.

-- ============================================================
-- 1. Semantic language items
-- ============================================================

/-- The `Self` pseudo-type name used inside impl blocks. -/
def selfTypeName : String := "Self"

/-- The name of the builtin Destroy trait. -/
def destroyTraitName : String := "Destroy"

/-- The name of the destroy method inside the Destroy trait. -/
def destroyMethodName : String := "destroy"

/-- The name of the builtin Result enum. -/
def resultEnumName : String := "Result"

/-- Variant name for the success case of Result. -/
def okVariantName : String := "Ok"

/-- Variant name for the failure case of Result. -/
def errVariantName : String := "Err"

/-- The user-level entry point function name. -/
def mainFnName : String := "main"

/-- The `Unsafe` capability name. -/
def unsafeCapName : String := "Unsafe"

/-- The `Std` capability macro name (expands to all safe caps). -/
def stdCapMacroName : String := "Std"

/-- Newtype positional field name (`.0`). -/
def newtypeFieldName : String := "0"

-- ============================================================
-- 2. Compiler-reserved identifiers
-- ============================================================

/-- Function names reserved by the compiler.
    User code cannot define functions with these names. -/
def reservedFnNames : List String :=
  ["destroy", "abort", "alloc", "free", "alloc_array", "free_array", "realloc_array"]

/-- Builtin function names that need special resolve treatment but
    are NOT in `resolveIntrinsic`.  These are compiler-emitted helpers
    or legacy names that user code may call but not redefine. -/
def extraBuiltinFnNames : List String :=
  ["print", "println", "to_string", "deref", "deref_mut", "add"]

/-- Built-in type names known to the compiler.
    These are always in scope without an explicit import. -/
def builtinTypeNames : List String :=
  [ "Int", "Uint", "Bool", "String", "Float64", "Float32", "Char",
    "i8", "i16", "i32", "u8", "u16", "u32",
    "Heap", "HeapArray", "Vec", "HashMap", "Option", "Result" ]

-- ============================================================
-- 3. Mangling / suffix helpers
-- ============================================================

/-- Build the mangled destroy function name for a type (e.g. "Point_destroy"). -/
def destroyFnNameFor (typeName : String) : String :=
  typeName ++ "_" ++ destroyMethodName

/-- Build a mangled method name: `TypeName_method`. -/
def mangledMethodName (typeName : String) (method : String) : String :=
  typeName ++ "_" ++ method

/-- Suffix appended to HashMap runtime functions when the key type is String. -/
def hashMapStrKeySuffix : String := "_str"

/-- Suffix for compiler-generated sizeof functions. -/
def sizeofSuffix : String := "_sizeof"

-- ============================================================
-- 4. Convenience predicates
-- ============================================================

/-- Check if a function name is reserved by the compiler. -/
def isReservedFnName (name : String) : Bool :=
  reservedFnNames.contains name

/-- Check if a name is any known builtin (intrinsic or extra). -/
def isKnownBuiltinFn (name : String) : Bool :=
  isIntrinsic name || extraBuiltinFnNames.contains name

end Concrete
