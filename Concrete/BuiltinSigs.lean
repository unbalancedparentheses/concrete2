import Concrete.FileSummary

namespace Concrete

/-! ## Shared builtin function signatures

These are the compiler-builtin function signatures used by both
the type checker (Check) and elaborator (Elab).  Defined once here
so the two passes can never silently diverge.
-/

/-- Canonical builtin function signatures keyed by runtime name.
    Order matters: Check.lean derives positional indices from this list. -/
def builtinFnSigs : List (String × FnSummary) := [
  ("string_length", { params := [("s", .ref .string)], retTy := .int }),
  ("string_concat", { params := [("a", .string), ("b", .string)], retTy := .string }),
  ("drop_string", { params := [("s", .string)], retTy := .unit }),
  ("string_slice", { params := [("s", .ref .string), ("start", .int), ("end_", .int)], retTy := .string }),
  ("string_char_at", { params := [("s", .ref .string), ("index", .int)], retTy := .int }),
  ("string_contains", { params := [("haystack", .ref .string), ("needle", .ref .string)], retTy := .bool }),
  ("string_eq", { params := [("a", .ref .string), ("b", .ref .string)], retTy := .bool }),
  ("int_to_string", { params := [("n", .int)], retTy := .string }),
  ("string_to_int", { params := [("s", .ref .string)], retTy := .generic "Result" [.int, .int] }),
  ("bool_to_string", { params := [("b", .bool)], retTy := .string }),
  ("float_to_string", { params := [("f", .float64)], retTy := .string }),
  ("get_args", { params := [], retTy := .heapArray .string, capSet := .concrete ["Process"] }),
  ("string_trim", { params := [("s", .ref .string)], retTy := .string })
]

end Concrete
