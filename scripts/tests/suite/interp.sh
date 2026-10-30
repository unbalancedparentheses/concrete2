# interp: the code units of tests/cases/interp.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_interp_1() {
interp_pass=0
interp_fail=0

# 1. parse_validate: interpreter matches compiled exit code (0)
PV_SRC="examples/parse_validate/src/main.con"
pv_interp_exit=0
"$COMPILER" "$PV_SRC" --interp 2>/dev/null || pv_interp_exit=$?
if [ "$pv_interp_exit" -eq 0 ]; then
    echo "  ok  interp: parse_validate returns exit 0"
    interp_pass=$((interp_pass + 1))
else
    echo "  FAIL interp: parse_validate should return exit 0, got $pv_interp_exit"
    interp_fail=$((interp_fail + 1))
fi

# 2. Simple function call: add(2,3) == 5
cat > "$TMPDIR/interp_test_call.con" << 'TESTEOF'
fn add(a: i32, b: i32) -> i32 {
    return a + b;
}
pub fn main() -> Int {
    let x: i32 = add(2, 3);
    if x == 5 { return 0; }
    return 1;
}
TESTEOF
call_exit=0
"$COMPILER" "$TMPDIR/interp_test_call.con" --interp 2>/dev/null || call_exit=$?
if [ "$call_exit" -eq 0 ]; then
    echo "  ok  interp: function calls work (add 2 3 == 5)"
    interp_pass=$((interp_pass + 1))
else
    echo "  FAIL interp: function call test should return 0, got $call_exit"
    interp_fail=$((interp_fail + 1))
fi

# 3. Array indexing in bounded loop
cat > "$TMPDIR/interp_test_arr.con" << 'TESTEOF'
pub fn main() -> Int {
    let arr: [i32; 4] = [10, 20, 30, 40];
    let mut acc: i32 = 0;
    for (let mut i: i32 = 0; i < 4; i = i + 1) {
        acc = acc + arr[i];
    }
    if acc == 100 { return 0; }
    return 1;
}
TESTEOF
arr_exit=0
"$COMPILER" "$TMPDIR/interp_test_arr.con" --interp 2>/dev/null || arr_exit=$?
if [ "$arr_exit" -eq 0 ]; then
    echo "  ok  interp: array indexing in bounded loop"
    interp_pass=$((interp_pass + 1))
else
    echo "  FAIL interp: array loop test should return 0, got $arr_exit"
    interp_fail=$((interp_fail + 1))
fi

# 4. Struct creation and field access
cat > "$TMPDIR/interp_test_struct.con" << 'TESTEOF'
struct Copy Point {
    x: i32,
    y: i32,
}
fn make_point(x: i32, y: i32) -> Point {
    return Point { x: x, y: y };
}
pub fn main() -> Int {
    let p: Point = make_point(10, 20);
    if p.x != 10 { return 1; }
    if p.y != 20 { return 2; }
    return 0;
}
TESTEOF
struct_exit=0
"$COMPILER" "$TMPDIR/interp_test_struct.con" --interp 2>/dev/null || struct_exit=$?
if [ "$struct_exit" -eq 0 ]; then
    echo "  ok  interp: struct creation and field access"
    interp_pass=$((interp_pass + 1))
else
    echo "  FAIL interp: struct test should return 0, got $struct_exit"
    interp_fail=$((interp_fail + 1))
fi

# 5. Enum match with field bindings
cat > "$TMPDIR/interp_test_enum.con" << 'TESTEOF'
enum Copy Result {
    Ok { val: i32 },
    Err { code: i32 },
}
fn try_parse(ok: i32) -> Result {
    if ok == 1 { return Result::Ok { val: 42 }; }
    return Result::Err { code: 99 };
}
pub fn main() -> Int {
    match try_parse(1) {
        Result::Ok { val } => {
            if val != 42 { return 1; }
        },
        Result::Err { code } => { return 2; },
    }
    match try_parse(0) {
        Result::Ok { val } => { return 3; },
        Result::Err { code } => {
            if code != 99 { return 4; }
        },
    }
    return 0;
}
TESTEOF
enum_exit=0
"$COMPILER" "$TMPDIR/interp_test_enum.con" --interp 2>/dev/null || enum_exit=$?
if [ "$enum_exit" -eq 0 ]; then
    echo "  ok  interp: enum match with field bindings"
    interp_pass=$((interp_pass + 1))
else
    echo "  FAIL interp: enum match test should return 0, got $enum_exit"
    interp_fail=$((interp_fail + 1))
fi

# 6. XOR bitwise operation (used by parse_validate checksum)
cat > "$TMPDIR/interp_test_xor.con" << 'TESTEOF'
pub fn main() -> Int {
    let a: i32 = 1 ^ 2;
    if a != 3 { return 1; }
    let b: i32 = 3 ^ 0;
    if b != 3 { return 2; }
    let c: i32 = 255 ^ 255;
    if c != 0 { return 3; }
    return 0;
}
TESTEOF
xor_exit=0
"$COMPILER" "$TMPDIR/interp_test_xor.con" --interp 2>/dev/null || xor_exit=$?
if [ "$xor_exit" -eq 0 ]; then
    echo "  ok  interp: XOR bitwise operation"
    interp_pass=$((interp_pass + 1))
else
    echo "  FAIL interp: XOR test should return 0, got $xor_exit"
    interp_fail=$((interp_fail + 1))
fi

# 7. Unsupported construct produces clear diagnostic: a foreign function outside the
# interpreter's C-function table is refused, never guessed (floats, the old example, are
# modelled since the interpreter-coverage pass).
cat > "$TMPDIR/interp_test_unsup.con" << 'TESTEOF'
trusted extern fn getpid() with(Process) -> i32;
pub fn main() with(Process) -> Int {
    let p: i32 = getpid();
    return 0;
}
TESTEOF
unsup_out=$("$COMPILER" "$TMPDIR/interp_test_unsup.con" --interp 2>&1) && unsup_exit=0 || unsup_exit=$?
if [ "$unsup_exit" -ne 0 ] && grep <<<"$unsup_out" -q "interp:.*not modelled"; then
    echo "  ok  interp: unsupported construct gives clear diagnostic"
    interp_pass=$((interp_pass + 1))
else
    echo "  FAIL interp: should fail with 'interp: ... not modelled'"
    interp_fail=$((interp_fail + 1))
fi

# 8. Interpreter matches compiled binary for parse_validate (exit code AND stdout)
# self-printing wrapper (MAIN_EXIT_MODEL stage 2): the compiled side prints its
# result so stdout is comparable with interp's value print.
gate_selfprint_wrap "$PV_SRC" "$TMPDIR/interp_pv_wrapped.con"
if "$COMPILER" "$TMPDIR/interp_pv_wrapped.con" -o "$TMPDIR/interp_pv_compiled" 2>/dev/null; then
    pv_compiled_out=$("$TMPDIR/interp_pv_compiled" 2>/dev/null) && pv_compiled_exit=0 || pv_compiled_exit=$?
    pv_interp_out=$("$COMPILER" "$PV_SRC" --interp 2>/dev/null) && pv_interp_exit2=0 || pv_interp_exit2=$?
    if [ "$pv_interp_exit2" -eq "$pv_compiled_exit" ] && [ "$pv_interp_out" = "$pv_compiled_out" ]; then
        echo "  ok  interp: parse_validate interp matches compiled (exit=$pv_compiled_exit, stdout='$pv_compiled_out')"
        interp_pass=$((interp_pass + 1))
    else
        echo "  FAIL interp: mismatch: interp(exit=$pv_interp_exit2,out='$pv_interp_out') vs compiled(exit=$pv_compiled_exit,out='$pv_compiled_out')"
        interp_fail=$((interp_fail + 1))
    fi
else
    echo "  SKIP interp: compiled binary comparison (compile failed)"
    interp_fail=$((interp_fail + 1))
fi

# 9. Scope isolation: block-local let bindings must not leak out of if-branches.
# The leak was observable only by shadowing an outer `x` inside the branch and reading
# the outer one afterwards. Exit 2i SCOPE-1@1 (E0301) makes that shape illegal, and
# without it a leaked binding cannot be named, so the leg is PINNED as an E0301 refusal
# on the interpreter path, plus the closest legal control: sibling branches that bind
# the same name each see their own value.
cat > "$TMPDIR/interp_test_scope.con" << 'TESTEOF'
pub fn main() -> Int {
    let x: i32 = 1;
    if true { let x: i32 = 2; }
    if x == 1 { return 0; }
    return 1;
}
TESTEOF
scope_exit=0
scope_out=$("$COMPILER" "$TMPDIR/interp_test_scope.con" --interp 2>&1) || scope_exit=$?
if [ "$scope_exit" -ne 0 ] && grep -qF "(E0301)" <<<"$scope_out"; then
    echo "  ok  interp: an if-branch let shadowing an outer binding is refused (E0301)"
    interp_pass=$((interp_pass + 1))
else
    echo "  FAIL interp: if-branch shadowing let not refused with E0301 (exit=$scope_exit)"
    interp_fail=$((interp_fail + 1))
fi
cat > "$TMPDIR/interp_test_scope_sib.con" << 'TESTEOF'
pub fn main() -> Int {
    let mut r: i32 = 0;
    if true { let x: i32 = 2; r = r + x; }
    if true { let x: i32 = 30; r = r + x; }
    if r == 32 { return 0; }
    return 1;
}
TESTEOF
scope_exit=0
"$COMPILER" "$TMPDIR/interp_test_scope_sib.con" --interp 2>/dev/null || scope_exit=$?
if [ "$scope_exit" -eq 0 ]; then
    echo "  ok  interp: sibling if-branch let bindings of one name are independent"
    interp_pass=$((interp_pass + 1))
else
    echo "  FAIL interp: sibling if-branch bindings of one name interfere (exit=$scope_exit)"
    interp_fail=$((interp_fail + 1))
fi

# 10. Negative array index must error, not silently write element 0
cat > "$TMPDIR/interp_test_negidx.con" << 'TESTEOF'
pub fn main() -> Int {
    let mut arr: [i32; 4] = [10, 20, 30, 40];
    arr[0 - 1] = 99;
    if arr[0] == 10 { return 0; }
    return 1;
}
TESTEOF
negidx_out=$("$COMPILER" "$TMPDIR/interp_test_negidx.con" --interp 2>&1) && negidx_exit=0 || negidx_exit=$?
if [ "$negidx_exit" -ne 0 ] && grep <<<"$negidx_out" -qi "negative\|out of bounds"; then
    echo "  ok  interp: negative array index produces error diagnostic"
    interp_pass=$((interp_pass + 1))
else
    echo "  FAIL interp: negative array index should error, got exit=$negidx_exit"
    interp_fail=$((interp_fail + 1))
fi

# 11. Observable contract: interp should print return value and exit 0 (like compiled)
cat > "$TMPDIR/interp_test_contract.con" << 'TESTEOF'
pub fn main() -> Int {
    return 7;
}
TESTEOF
contract_out=$("$COMPILER" "$TMPDIR/interp_test_contract.con" --interp 2>/dev/null)
contract_exit=$?
if [ "$contract_exit" -eq 0 ] && grep <<<"$contract_out" -q "^7$"; then
    echo "  ok  interp: prints return value and exits 0 (matches compiled contract)"
    interp_pass=$((interp_pass + 1))
else
    echo "  FAIL interp: should print '7' and exit 0, got stdout='$contract_out' exit=$contract_exit"
    interp_fail=$((interp_fail + 1))
fi

# 12. Match-arm mutations to outer variables must persist
cat > "$TMPDIR/interp_test_match_mut.con" << 'TESTEOF'
enum Copy E { A }
pub fn main() -> Int {
    let e: E = E::A;
    let mut x: i32 = 1;
    match e {
        E::A => { x = 2; },
    }
    if x == 2 { return 0; }
    return 1;
}
TESTEOF
match_mut_out=$("$COMPILER" "$TMPDIR/interp_test_match_mut.con" --interp 2>/dev/null)
match_mut_exit=$?
if [ "$match_mut_exit" -eq 0 ] && grep <<<"$match_mut_out" -q "^0$"; then
    echo "  ok  interp: match-arm mutations to outer variables persist"
    interp_pass=$((interp_pass + 1))
else
    echo "  FAIL interp: match-arm mutation lost (x should be 2 after match)"
    interp_fail=$((interp_fail + 1))
fi

echo "  $interp_pass interpreter gates passed"
PASS=$((PASS + interp_pass))
FAIL=$((FAIL + interp_fail))
:
}

suite_interp_2() {
oracle_log="$TMPDIR/oracle.log"
if bash ./scripts/tests/test_oracle.sh > "$oracle_log" 2>&1; then
    grep -E '^(PEND|ORACLE:)' "$oracle_log" | sed 's/^/  /'
    PASS=$((PASS + 1))
else
    cat "$oracle_log" | sed 's/^/  /'
    echo "  FAIL oracle: differential corpus had mismatches (see above)"
    FAIL=$((FAIL + 1))
fi
:
}
