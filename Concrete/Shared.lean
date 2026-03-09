import Concrete.AST

namespace Concrete

/-! ## Shared semantic helpers

Used by Check, CoreCheck, and other passes that need type classification
or capability comparison.
-/

/-- Is this a numeric type (supports arithmetic operators)? -/
def isNumeric : Ty → Bool
  | .int | .uint | .i8 | .i16 | .i32 | .u8 | .u16 | .u32 => true
  | .float64 | .float32 => true
  | _ => false

/-- Is this an integer type (supports comparison and bitwise operators)? -/
def isInteger : Ty → Bool
  | .int | .uint | .i8 | .i16 | .i32 | .u8 | .u16 | .u32 => true
  | _ => false

/-- Check if two types are compatible (equal or both numeric). -/
def typesCompatible (a b : Ty) : Bool :=
  a == b || (isNumeric a && isNumeric b)

/-- Check if capSet `caller` is a superset of `callee`. -/
def capsContain (caller callee : CapSet) : Bool :=
  match callee with
  | .empty => true
  | .concrete calleeCaps =>
    match caller with
    | .empty => calleeCaps.isEmpty
    | .concrete callerCaps => calleeCaps.all fun c => callerCaps.contains c
    | .var _ => true  -- capability variable assumed to satisfy
    | .union a b => capsContain a callee || capsContain b callee
  | .var _ => true  -- capability variable, can't check statically here
  | .union a b => capsContain caller a && capsContain caller b

end Concrete
