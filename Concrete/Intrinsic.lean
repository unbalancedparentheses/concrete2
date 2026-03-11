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
  | allocArray      -- low-level array alloc
  | freeArray       -- low-level array free
  | reallocArray    -- low-level array realloc

  -- Vec operations
  | vecNew | vecPush | vecGet | vecSet | vecLen | vecPop | vecFree

  -- HashMap operations
  | mapNew | mapInsert | mapGet | mapContains | mapRemove | mapLen | mapFree

  -- HeapArray operations
  | heapArrayNew | heapArrayGet | heapArraySet | heapArrayLen | heapArrayFree

  -- String operations
  | stringLength | stringConcat | stringEq | stringSlice
  | stringCharAt | stringContains | stringTrim | dropString
  | stringFromChar

  -- Conversion
  | intToString | stringToInt | boolToString | floatToString
  | charToInt | intToChar

  -- I/O
  | printString | printInt | printBool | printChar
  | eprintString | readLine

  -- File I/O
  | readFile | writeFile | appendFile

  -- Network
  | tcpConnect | tcpListen | tcpAccept
  | socketSend | socketRecv | socketClose

  -- Math (Float64 → Float64 unless noted)
  | sqrt | sin | cos | tan | pow | log_ | exp | floor | ceil

  -- System
  | getEnv | getArgs | exitProcess | abort
  | processExec | processExit
  | clockNow | envGet | envSet
  | randomInt | randomFloat

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
  | "alloc_array" => some .allocArray
  | "free_array" => some .freeArray
  | "realloc_array" => some .reallocArray

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

  -- HeapArray
  | "heap_array_new" | "HeapArray_new" => some .heapArrayNew
  | "heap_array_get" | "HeapArray_get" => some .heapArrayGet
  | "heap_array_set" | "HeapArray_set" => some .heapArraySet
  | "heap_array_len" | "HeapArray_len" => some .heapArrayLen
  | "heap_array_free"| "HeapArray_free"=> some .heapArrayFree

  -- String
  | "string_length" | "string_len" | "String_len" => some .stringLength
  | "string_concat" | "String_concat"              => some .stringConcat
  | "string_eq"     | "String_eq"                  => some .stringEq
  | "string_slice"   => some .stringSlice
  | "string_char_at" => some .stringCharAt
  | "string_contains"=> some .stringContains
  | "string_trim"    => some .stringTrim
  | "drop_string"    => some .dropString
  | "string_from_char" => some .stringFromChar

  -- Conversion
  | "int_to_string"  => some .intToString
  | "string_to_int"  => some .stringToInt
  | "bool_to_string" => some .boolToString
  | "float_to_string"=> some .floatToString
  | "char_to_int"    => some .charToInt
  | "int_to_char"    => some .intToChar

  -- I/O
  | "print_string"  => some .printString
  | "print_int"     => some .printInt
  | "print_bool"    => some .printBool
  | "print_char"    => some .printChar
  | "eprint_string" => some .eprintString
  | "read_line"     => some .readLine

  -- File
  | "read_file"   => some .readFile
  | "write_file"  => some .writeFile
  | "append_file" => some .appendFile

  -- Network
  | "tcp_connect" => some .tcpConnect
  | "tcp_listen"  => some .tcpListen
  | "tcp_accept"  => some .tcpAccept
  | "socket_send" => some .socketSend
  | "socket_recv" => some .socketRecv
  | "socket_close"=> some .socketClose

  -- Math
  | "sqrt"  => some .sqrt
  | "sin"   => some .sin
  | "cos"   => some .cos
  | "tan"   => some .tan
  | "pow"   => some .pow
  | "log"   => some .log_
  | "exp"   => some .exp
  | "floor" => some .floor
  | "ceil"  => some .ceil

  -- System
  | "get_env"      => some .getEnv
  | "env_get"      => some .envGet
  | "env_set"      => some .envSet
  | "get_args"     => some .getArgs
  | "exit_process" | "process_exit" => some .exitProcess
  | "abort"        => some .abort
  | "process_exec" => some .processExec
  | "clock_now"    => some .clockNow
  | "random_int"   => some .randomInt
  | "random_float" => some .randomFloat

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
  | .allocArray => "alloc_array"
  | .freeArray => "free_array"
  | .reallocArray => "realloc_array"
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
  | .heapArrayNew => "heap_array_new"
  | .heapArrayGet => "heap_array_get"
  | .heapArraySet => "heap_array_set"
  | .heapArrayLen => "heap_array_len"
  | .heapArrayFree => "heap_array_free"
  | .stringLength => "string_length"
  | .stringConcat => "string_concat"
  | .stringEq => "string_eq"
  | .stringSlice => "string_slice"
  | .stringCharAt => "string_char_at"
  | .stringContains => "string_contains"
  | .stringTrim => "string_trim"
  | .dropString => "drop_string"
  | .stringFromChar => "string_from_char"
  | .intToString => "int_to_string"
  | .stringToInt => "string_to_int"
  | .boolToString => "bool_to_string"
  | .floatToString => "float_to_string"
  | .charToInt => "char_to_int"
  | .intToChar => "int_to_char"
  | .printString => "print_string"
  | .printInt => "print_int"
  | .printBool => "print_bool"
  | .printChar => "print_char"
  | .eprintString => "eprint_string"
  | .readLine => "read_line"
  | .readFile => "read_file"
  | .writeFile => "write_file"
  | .appendFile => "append_file"
  | .tcpConnect => "tcp_connect"
  | .tcpListen => "tcp_listen"
  | .tcpAccept => "tcp_accept"
  | .socketSend => "socket_send"
  | .socketRecv => "socket_recv"
  | .socketClose => "socket_close"
  | .sqrt => "sqrt"
  | .sin => "sin"
  | .cos => "cos"
  | .tan => "tan"
  | .pow => "pow"
  | .log_ => "log"
  | .exp => "exp"
  | .floor => "floor"
  | .ceil => "ceil"
  | .getEnv => "get_env"
  | .envGet => "env_get"
  | .envSet => "env_set"
  | .getArgs => "get_args"
  | .exitProcess => "exit_process"
  | .abort => "abort"
  | .processExec => "process_exec"
  | .processExit => "process_exit"
  | .clockNow => "clock_now"
  | .randomInt => "random_int"
  | .randomFloat => "random_float"
  | .sizeof => "sizeof"
  | .alignof => "alignof"
  | .unwrap => "unwrap"

/-- Required capability set for an intrinsic, if any. -/
def IntrinsicId.capability : IntrinsicId → Option String
  -- I/O
  | .printString | .printInt | .printBool | .printChar
  | .eprintString | .readLine => some "Console"
  -- File
  | .readFile | .writeFile | .appendFile => some "File"
  -- Network
  | .tcpConnect | .tcpListen | .tcpAccept
  | .socketSend | .socketRecv | .socketClose => some "Network"
  -- Process
  | .getArgs | .exitProcess | .abort | .processExec | .processExit => some "Process"
  -- Env
  | .getEnv | .envGet | .envSet => some "Env"
  -- Alloc
  | .alloc | .free
  | .vecNew | .vecPush | .vecPop | .vecFree
  | .mapNew | .mapInsert | .mapRemove | .mapFree
  | .heapArrayNew | .heapArrayFree
  | .allocArray | .freeArray | .reallocArray => some "Alloc"
  -- Random
  | .randomInt | .randomFloat => some "Random"
  -- Time
  | .clockNow => some "Time"
  -- Pure (no capability required)
  | _ => none

end Concrete
