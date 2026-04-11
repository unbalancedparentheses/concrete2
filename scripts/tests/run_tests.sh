#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# --- CLI argument parsing ---
MODE="fast"           # fast (default) | full | stdlib | O2 | codegen | report | affected
FILTER=""             # glob pattern to match test file paths
SECTION=""            # internal: which sections to run
STDLIB_MODULE=""      # single stdlib module to target (e.g., "string", "map")
AFFECTED_FILES=""     # comma-separated list of changed files for --affected mode

usage() {
    cat <<'USAGE'
Usage: scripts/tests/run_tests.sh [OPTIONS]

The default mode is --fast: parallel execution on all cores, network tests
skipped. This is the recommended developer workflow for edit-test loops.

Use --full before merging to run the complete suite including network tests.
Use --filter to iterate on a single area without paying for the full suite.

Modes:
  --fast              Fast tier — skip network/TCP tests (DEFAULT)
  --full              Complete suite — all sections including slow tests
  --filter PATTERN    Only tests whose file path contains PATTERN
  --stdlib            Only stdlib module + collection verification
  --stdlib-module M   Only run tests for stdlib module M (e.g., string, map, vec)
  --O2               Only -O2 optimized-build regression tests
  --codegen           Only codegen differential + SSA structure tests
  --report            Only --report output verification tests
  --affected          Auto-detect changed files (git diff) and run affected tests
  --affected FILES    Run tests affected by specific files (comma-separated)
  --manifest          List all test files with categories (no execution)

Options:
  -j N                Override parallelism (default: number of CPU cores)
  -h, --help          Show this help

Environment:
  TEST_JOBS=N         Same as -j N
  LLI_PATH=/path/lli  Use lli (LLVM interpreter) for ~15x faster tests
  SKIP_FLAKY_TCP_TEST=1  Skip the flaky TCP test

Recommended workflows:
  ./scripts/tests/run_tests.sh                        # daily driver — fast parallel
  ./scripts/tests/run_tests.sh --filter struct_loop   # iterate on one area
  ./scripts/tests/run_tests.sh --stdlib               # after touching std/src/
  ./scripts/tests/run_tests.sh --stdlib-module map    # iterate on one stdlib module
  ./scripts/tests/run_tests.sh --O2                   # after lowering changes
  ./scripts/tests/run_tests.sh --full                 # pre-merge — complete coverage
  ./scripts/tests/run_tests.sh -j 1                   # debug ordering issues
  ./scripts/tests/run_tests.sh --affected             # run tests for uncommitted changes
  ./scripts/tests/run_tests.sh --affected Concrete/Lower.lean,Concrete/SSA.lean
USAGE
    exit 0
}

# Auto-detect CPU count for default parallelism
if [ -z "${TEST_JOBS:-}" ]; then
    if command -v nproc &>/dev/null; then
        TEST_JOBS=$(nproc)
    elif command -v sysctl &>/dev/null; then
        TEST_JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    else
        TEST_JOBS=4
    fi
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --full)    MODE="full"; shift ;;
        --fast)    MODE="fast"; shift ;;
        --stdlib)  MODE="stdlib"; shift ;;
        --stdlib-module) MODE="stdlib-module"; STDLIB_MODULE="$2"; shift 2 ;;
        --O2)      MODE="O2"; shift ;;
        --codegen) MODE="codegen"; shift ;;
        --report)  MODE="report"; shift ;;
        --affected)
            MODE="affected"
            if [ $# -gt 1 ] && [[ "$2" != --* ]]; then
                AFFECTED_FILES="$2"; shift 2
            else
                # Auto-detect from git diff
                AFFECTED_FILES=$(git diff --name-only HEAD 2>/dev/null | tr '\n' ',')
                AFFECTED_FILES="${AFFECTED_FILES%,}"  # trim trailing comma
                if [ -z "$AFFECTED_FILES" ]; then
                    # Also check staged
                    AFFECTED_FILES=$(git diff --cached --name-only 2>/dev/null | tr '\n' ',')
                    AFFECTED_FILES="${AFFECTED_FILES%,}"
                fi
                if [ -z "$AFFECTED_FILES" ]; then
                    echo "No changed files detected. Running full fast suite."
                    MODE="fast"
                fi
                shift
            fi
            ;;
        --filter)  FILTER="$2"; shift 2 ;;
        --manifest) MODE="manifest"; shift ;;
        -j)        TEST_JOBS="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)         echo "Unknown option: $1"; usage ;;
    esac
done

# --- Manifest mode: list all tests and exit ---
if [ "$MODE" = "manifest" ]; then
    echo "# Concrete test manifest (auto-generated)"
    echo "# category | kind | file"
    echo "#"
    # Pass-level Lean tests
    echo "passlevel | lean_pass | Concrete/PipelineTest.lean (32 tests)"
    # Positive tests (run_ok)
    for f in tests/programs/*.con; do
        base=$(basename "$f" .con)
        if [[ "$base" == error_* ]]; then
            echo "negative | run_err | $f"
        elif [[ "$base" == regress_* ]]; then
            echo "regression | run_ok | $f"
        elif [[ "$base" == integration_* ]]; then
            echo "integration | run_ok | $f"
        elif [[ "$base" == hardening_* ]]; then
            echo "hardening | run_ok | $f"
        elif [[ "$base" == bug_* ]]; then
            echo "regression | run_ok | $f"
        elif [[ "$base" == codegen_* ]]; then
            echo "codegen | check_codegen | $f"
        elif [[ "$base" == report_* ]]; then
            echo "report | check_report | $f"
        elif [[ "$base" == fmt_* ]]; then
            echo "property | run_ok | $f"
        elif [[ "$base" == abort_* ]]; then
            echo "unit | run_abort | $f"
        else
            echo "unit | run_ok | $f"
        fi
    done
    # Multi-module tests
    for f in tests/programs/module_*/main.con; do
        [ -f "$f" ] && echo "multi_module | run_ok | $f"
    done
    # Stdlib modules
    for f in tests/programs/stdlib_*.con; do
        echo "stdlib | run_test | $f"
    done
    # Fuzz
    [ -f scripts/tests/test_parser_fuzz.sh ] && echo "fuzz | fuzz | scripts/tests/test_parser_fuzz.sh"
    echo "#"
    echo "# Total .con files: $(ls tests/programs/*.con 2>/dev/null | wc -l | tr -d ' ')"
    exit 0
fi

# --- Dependency-aware section resolution for --affected mode ---
# Reads tests/fixtures/test_dep_map.toml to map changed files to test sections.

DEP_MAP_FILE="tests/fixtures/test_dep_map.toml"

# lookup_dep_map FILE — look up sections for a file from tests/fixtures/test_dep_map.toml
# Returns comma-separated sections, or empty string if not found.
# Parses the TOML structure: [source."path"] blocks with sections = [...] arrays.
lookup_dep_map() {
    local query="$1"
    if [ ! -f "$DEP_MAP_FILE" ]; then
        return
    fi
    # Find the [source."<query>"] block and extract its sections line.
    # We iterate line by line, tracking which source block we're in.
    local in_block=""
    local found_sections=""
    while IFS= read -r line; do
        # Match [source."Concrete/Foo.lean"] or [source."std/src/*"]
        if [[ "$line" =~ ^\[source\.\" ]]; then
            # Extract the quoted path
            local path
            path=$(echo "$line" | sed 's/\[source\."\(.*\)"\]/\1/')
            in_block="$path"
            continue
        fi
        # Match [always] or other top-level blocks — end current source block
        if [[ "$line" =~ ^\[ ]]; then
            in_block=""
            continue
        fi
        # If we're in the right block, look for sections = [...]
        if [ -n "$in_block" ]; then
            # Check exact match
            local match=""
            if [ "$in_block" = "$query" ]; then
                match=1
            fi
            # Check glob match (e.g., "std/src/*" matches "std/src/vec.con")
            if [ -z "$match" ] && [[ "$in_block" == *"*"* ]]; then
                # Convert glob to regex for matching
                local pattern="${in_block//\*/.*}"
                if [[ "$query" =~ ^${pattern}$ ]]; then
                    match=1
                fi
            fi
            if [ -n "$match" ] && [[ "$line" =~ ^sections ]]; then
                # Extract the array content: sections = ["a", "b", "c"]
                found_sections=$(echo "$line" | sed 's/sections *= *\[//; s/\]//; s/"//g; s/ //g')
                echo "$found_sections"
                return
            fi
        fi
    done < "$DEP_MAP_FILE"
}

resolve_affected_sections() {
    local files="$1"
    # Always run pass-level tests (from [always] block)
    local sections=""
    local always_sections
    always_sections=$(lookup_dep_map "__always__")
    if [ -z "$always_sections" ]; then
        # Read [always] block directly
        always_sections=$(awk '/^\[always\]/{found=1; next} /^\[/{found=0} found && /^sections/{gsub(/sections *= *\[|\]|"| /,""); print}' "$DEP_MAP_FILE" 2>/dev/null)
    fi
    sections="${always_sections:-passlevel}"

    IFS=',' read -ra file_list <<< "$files"
    for f in "${file_list[@]}"; do
        local file_sections
        file_sections=$(lookup_dep_map "$f")
        if [ -n "$file_sections" ]; then
            sections="$sections,$file_sections"
        else
            # File not in dep map — run everything to be safe
            sections="$sections,positive,negative,testflag,report,codegen,O2,stdlib,collection"
        fi
    done

    # Deduplicate
    echo "$sections" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//'
}

# Resolve which sections are active based on MODE
case "$MODE" in
    full)    SECTION="passlevel,positive,negative,testflag,report,codegen,O2,stdlib,collection,xtarget,perf" ;;
    fast)    SECTION="passlevel,positive,negative,testflag,report,codegen,O2,stdlib,collection" ;;
    stdlib)  SECTION="stdlib,collection" ;;
    stdlib-module) SECTION="stdlib" ;;
    O2)      SECTION="O2" ;;
    codegen) SECTION="codegen,O2" ;;
    report)  SECTION="report" ;;
    affected)
        SECTION=$(resolve_affected_sections "$AFFECTED_FILES")
        echo "=== Affected mode ==="
        echo "  changed files: $AFFECTED_FILES"
        echo "  sections: $SECTION"
        echo ""
        ;;
esac

section_active() {
    [[ ",$SECTION," == *",$1,"* ]]
}

# If --filter is set, check whether a file path matches the pattern
filter_match() {
    local file="$1"
    [ -z "$FILTER" ] && return 0
    # Match against basename and full path
    local base
    base=$(basename "$file" .con)
    [[ "$file" == *${FILTER}* ]] || [[ "$base" == *${FILTER}* ]]
}

COMPILER=".lake/build/bin/concrete"
TESTDIR="tests/programs"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
JOBDIR="$TMPDIR/jobs"
mkdir -p "$JOBDIR"

# --- Compiler output cache ---
# Avoids recompiling the same file with the same flags.
# Usage: output=$(cached_output "file.con" "--report caps")
CACHEDIR="$TMPDIR/cache"
mkdir -p "$CACHEDIR"
# Track cache stats via files (counters don't survive subshells)
CACHE_HITS_FILE="$TMPDIR/cache_hits"
CACHE_MISSES_FILE="$TMPDIR/cache_misses"
echo 0 > "$CACHE_HITS_FILE"
echo 0 > "$CACHE_MISSES_FILE"

cached_output() {
    local file="$1"
    local flags="$2"
    local key
    key=$(echo "${file}|${flags}" | sed 's/[^a-zA-Z0-9_.-]/_/g')
    local cache_file="$CACHEDIR/$key"
    if [ -f "$cache_file" ]; then
        echo $(( $(cat "$CACHE_HITS_FILE") + 1 )) > "$CACHE_HITS_FILE"
        cat "$cache_file"
    else
        echo $(( $(cat "$CACHE_MISSES_FILE") + 1 )) > "$CACHE_MISSES_FILE"
        $COMPILER "$file" $flags 2>&1 | tee "$cache_file"
    fi
}

# Dependency gate: try compiling a file; if it fails, skip N assertions
# Usage: if ! compile_gate "file.con" "--report caps" "description" COUNT; then skip; fi
SKIPPED_DEPS=0
compile_gate() {
    local file="$1"
    local flags="$2"
    local desc="$3"
    local count="$4"
    if $COMPILER "$file" $flags > /dev/null 2>&1; then
        return 0
    else
        echo "FAIL  $desc — compilation failed (skipping $count dependent assertions)"
        FAIL=$((FAIL + 1))
        SKIPPED_DEPS=$((SKIPPED_DEPS + count))
        save_failure "$(path_key "$desc")" "$COMPILER $file $flags" "compilation failed"
        return 1
    fi
}

# --- Failure artifact preservation ---
# On test failure, save artifacts and rerun command to .test-failures/
FAILDIR=".test-failures"

save_failure() {
    local test_name="$1"
    local rerun_cmd="$2"
    local output="$3"
    mkdir -p "$FAILDIR"
    local fail_file="$FAILDIR/$test_name"
    {
        echo "# Failed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Rerun:"
        echo "$rerun_cmd"
        echo ""
        echo "# Output:"
        echo "$output"
    } > "$fail_file"
}

# Clean previous failure artifacts at start of run
rm -rf "$FAILDIR"

# --- Report assertion helper ---
# check_report FILE MODE GREP_PATTERN OK_MSG FAIL_MSG [NEGATE]
# Compiles FILE with --report MODE (cached), greps for PATTERN.
# If NEGATE is "!" then the pattern must NOT match.
check_report() {
    local file="$1" mode="$2" pattern="$3" ok_msg="$4" fail_msg="$5"
    local negate="${6:-}"
    local output
    output=$(cached_output "$file" "--report $mode")
    local matched=0
    if echo "$output" | grep -q "$pattern"; then
        matched=1
    fi
    if [ "$negate" = "!" ]; then
        if [ "$matched" -eq 0 ]; then
            echo "  ok  $ok_msg"
            PASS=$((PASS + 1))
        else
            echo "FAIL  $fail_msg"
            echo "$output"
            FAIL=$((FAIL + 1))
            save_failure "$(path_key "$fail_msg")" "$COMPILER $file --report $mode" "$output"
        fi
    else
        if [ "$matched" -eq 1 ]; then
            echo "  ok  $ok_msg"
            PASS=$((PASS + 1))
        else
            echo "FAIL  $fail_msg"
            echo "$output"
            FAIL=$((FAIL + 1))
            save_failure "$(path_key "$fail_msg")" "$COMPILER $file --report $mode" "$output"
        fi
    fi
}

# --- Multi-pattern report assertion ---
# check_report_multi FILE MODE OK_MSG FAIL_MSG PATTERN1 [PATTERN2 ...]
# All patterns must match.
check_report_multi() {
    local file="$1" mode="$2" ok_msg="$3" fail_msg="$4"
    shift 4
    local output
    output=$(cached_output "$file" "--report $mode")
    local all_match=1
    for pattern in "$@"; do
        if ! echo "$output" | grep -q "$pattern"; then
            all_match=0
            break
        fi
    done
    if [ "$all_match" -eq 1 ]; then
        echo "  ok  $ok_msg"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $fail_msg"
        echo "$output"
        FAIL=$((FAIL + 1))
        save_failure "$(path_key "$fail_msg")" "$COMPILER $file --report $mode" "$output"
    fi
}

# --- Profile check assertion ---
# check_profile FILE PROFILE GREP_PATTERN OK_MSG FAIL_MSG [NEGATE]
# Compiles FILE with --check PROFILE, greps for PATTERN.
# If NEGATE is "!" then the pattern must NOT match.
# Note: --check may return non-zero exit (profile violation), so we suppress errors.
check_profile() {
    local file="$1" profile="$2" pattern="$3" ok_msg="$4" fail_msg="$5"
    local negate="${6:-}"
    local output
    output=$($COMPILER "$file" --check "$profile" 2>&1 || true)
    local matched=0
    if echo "$output" | grep -q "$pattern"; then
        matched=1
    fi
    if [ "$negate" = "!" ]; then
        if [ "$matched" -eq 0 ]; then
            echo "  ok  $ok_msg"
            PASS=$((PASS + 1))
        else
            echo "FAIL  $fail_msg"
            echo "$output"
            FAIL=$((FAIL + 1))
            save_failure "$(path_key "$fail_msg")" "$COMPILER $file --check $profile" "$output"
        fi
    else
        if [ "$matched" -eq 1 ]; then
            echo "  ok  $ok_msg"
            PASS=$((PASS + 1))
        else
            echo "FAIL  $fail_msg"
            echo "$output"
            FAIL=$((FAIL + 1))
            save_failure "$(path_key "$fail_msg")" "$COMPILER $file --check $profile" "$output"
        fi
    fi
}

# check_profile_multi FILE PROFILE OK_MSG FAIL_MSG PATTERN1 [PATTERN2 ...]
# All patterns must match.
check_profile_multi() {
    local file="$1" profile="$2" ok_msg="$3" fail_msg="$4"
    shift 4
    local output
    output=$($COMPILER "$file" --check "$profile" 2>&1 || true)
    local all_match=1
    for pattern in "$@"; do
        if ! echo "$output" | grep -q "$pattern"; then
            all_match=0
            break
        fi
    done
    if [ "$all_match" -eq 1 ]; then
        echo "  ok  $ok_msg"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $fail_msg"
        echo "$output"
        FAIL=$((FAIL + 1))
        save_failure "$(path_key "$fail_msg")" "$COMPILER $file --check $profile" "$output"
    fi
}

# --- Emit output helper (cached) ---
# cached_emit FILE FLAG — returns cached output of $COMPILER FILE FLAG
cached_emit() {
    cached_output "$1" "$2"
}

# --- lli auto-detection ---
# Use lli (LLVM interpreter) for positive tests when available.
# This skips clang linking entirely and is ~15x faster per test.
LLI=""
if command -v lli &>/dev/null; then
    LLI="lli"
elif [ -x "${LLI_PATH:-}" ]; then
    LLI="$LLI_PATH"
fi

PASS=0
FAIL=0
SKIP=0
JOB_SEQ=0
declare -a JOB_PIDS=()
declare -a JOB_FILES=()

LLI_STATUS="off"
[ -n "$LLI" ] && LLI_STATUS="on ($LLI)"
echo "Mode: $MODE | Jobs: $TEST_JOBS | Filter: ${FILTER:-<none>} | lli: $LLI_STATUS"
echo ""

path_key() {
    local path="$1"
    path="${path//\//__}"
    path="${path//:/_}"
    path="${path// /_}"
    echo "$path"
}

record_result() {
    local result_file="$1"
    local status message
    status=$(sed -n '1p' "$result_file")
    message=$(sed -n '2,$p' "$result_file")
    echo "$message"
    if [ "$status" = "PASS" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        # Save failure artifact with rerun info
        local fail_name
        fail_name=$(echo "$message" | head -1 | sed 's/FAIL  //' | sed 's/[^a-zA-Z0-9_.-]/_/g' | head -c 120)
        if [ -n "$fail_name" ]; then
            mkdir -p "$FAILDIR"
            {
                echo "# Failed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
                echo "# Output:"
                echo "$message"
            } > "$FAILDIR/$fail_name"
        fi
    fi
}

flush_one_job() {
    local pid="${JOB_PIDS[0]}"
    local result_file="${JOB_FILES[0]}"
    wait "$pid" || true
    record_result "$result_file"
    JOB_PIDS=("${JOB_PIDS[@]:1}")
    JOB_FILES=("${JOB_FILES[@]:1}")
}

flush_jobs() {
    while [ "${#JOB_PIDS[@]}" -gt 0 ]; do
        flush_one_job
    done
}

throttle_jobs() {
    while [ "${#JOB_PIDS[@]}" -ge "$TEST_JOBS" ]; do
        flush_one_job
    done
}

# Positive tests: should compile and produce expected output
# Uses lli (LLVM interpreter) when available to skip clang linking (~15x faster).
run_ok_worker() {
    local file="$1"
    local expected="$2"
    local result_file="$3"
    local name
    name=$(path_key "${file%.con}")
    local out="$TMPDIR/$name"

    local actual
    if [ -n "$LLI" ]; then
        # Fast path: emit LLVM IR and interpret directly (no clang)
        local llpath="$out.ll"
        if ! $COMPILER "$file" --emit-llvm > "$llpath" 2>/dev/null; then
            {
                echo "FAIL"
                echo "FAIL  $file — compilation failed (expected success)"
                echo "# Rerun: $COMPILER $file --emit-llvm"
            } > "$result_file"
            return
        fi
        actual=$($LLI "$llpath" 2>&1) || true
    else
        # Fallback: compile to native binary via clang
        if ! $COMPILER "$file" -o "$out" > /dev/null 2>&1; then
            {
                echo "FAIL"
                echo "FAIL  $file — compilation failed (expected success)"
                echo "# Rerun: $COMPILER $file -o /tmp/test_rerun && /tmp/test_rerun"
            } > "$result_file"
            return
        fi
        actual=$("$out" 2>&1) || true
    fi
    if [ "$actual" = "$expected" ]; then
        {
            echo "PASS"
            echo "  ok  $file => $expected"
        } > "$result_file"
    else
        {
            echo "FAIL"
            echo "FAIL  $file — expected '$expected', got '$actual'"
            echo "# Rerun: $COMPILER $file -o /tmp/test_rerun && /tmp/test_rerun"
        } > "$result_file"
    fi
}

run_ok() {
    local file="$1"
    local expected="$2"
    if ! filter_match "$file"; then SKIP=$((SKIP + 1)); return; fi
    if [ "$TEST_JOBS" -le 1 ]; then
        JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
        run_ok_worker "$file" "$expected" "$result_file"
        record_result "$result_file"
        return
    fi
    JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
    throttle_jobs
    (run_ok_worker "$file" "$expected" "$result_file") &
    JOB_PIDS+=("$!")
    JOB_FILES+=("$result_file")
}

# Compile to LLVM IR then link with clang -O2 and check output
run_ok_O2_worker() {
    local file="$1"
    local expected="$2"
    local result_file="$3"
    local name
    name=$(path_key "${file%.con}")
    local llpath="$TMPDIR/${name}.ll"
    local out="$TMPDIR/${name}_O2"

    local llvm_ir
    if ! llvm_ir=$($COMPILER "$file" --emit-llvm 2>&1); then
        { echo "FAIL"; echo "FAIL  $file -O2 — emit-llvm failed"; } > "$result_file"
        return
    fi
    echo "$llvm_ir" > "$llpath"
    if ! clang "$llpath" -o "$out" -O2 -Wno-override-module > /dev/null 2>&1; then
        { echo "FAIL"; echo "FAIL  $file -O2 — clang -O2 failed"; } > "$result_file"
        return
    fi
    local actual
    actual=$("$out" 2>&1) || true
    if [ "$actual" = "$expected" ]; then
        { echo "PASS"; echo "  ok  $file -O2 => $expected"; } > "$result_file"
    else
        { echo "FAIL"; echo "FAIL  $file -O2 — expected '$expected', got '$actual'"; } > "$result_file"
    fi
}

run_ok_O2() {
    local file="$1"
    local expected="$2"
    if ! filter_match "$file"; then SKIP=$((SKIP + 1)); return; fi
    if [ "$TEST_JOBS" -le 1 ]; then
        JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
        run_ok_O2_worker "$file" "$expected" "$result_file"
        record_result "$result_file"
        return
    fi
    JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
    throttle_jobs
    (run_ok_O2_worker "$file" "$expected" "$result_file") &
    JOB_PIDS+=("$!")
    JOB_FILES+=("$result_file")
}

# Negative tests: should fail to compile with a specific error substring
# Uses --emit-llvm to skip clang (error is detected before codegen linking).
run_err_worker() {
    local file="$1"
    local expected_err="$2"
    local result_file="$3"
    local name
    name=$(path_key "${file%.con}")
    local out="$TMPDIR/$name"

    local stderr
    if stderr=$($COMPILER "$file" --emit-llvm 2>&1 > /dev/null); then
        {
            echo "FAIL"
            echo "FAIL  $file — compiled successfully (expected error)"
        } > "$result_file"
        return
    fi
    if grep -Fq -- "$expected_err" <<<"$stderr"; then
        {
            echo "PASS"
            echo "  ok  $file => error: $expected_err"
        } > "$result_file"
    else
        {
            echo "FAIL"
            echo "FAIL  $file — expected error '$expected_err', got: $stderr"
        } > "$result_file"
    fi
}

run_err() {
    local file="$1"
    local expected_err="$2"
    if ! filter_match "$file"; then SKIP=$((SKIP + 1)); return; fi
    if [ "$TEST_JOBS" -le 1 ]; then
        JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
        run_err_worker "$file" "$expected_err" "$result_file"
        record_result "$result_file"
        return
    fi
    JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
    throttle_jobs
    (run_err_worker "$file" "$expected_err" "$result_file") &
    JOB_PIDS+=("$!")
    JOB_FILES+=("$result_file")
}

if section_active positive; then
echo "=== Positive tests ==="
run_ok "$TESTDIR/fib.con"                55
run_ok "$TESTDIR/arithmetic.con"         65
run_ok "$TESTDIR/if_else.con"            1
run_ok "$TESTDIR/while_loop.con"         5050
run_ok "$TESTDIR/recursion.con"          479001600
run_ok "$TESTDIR/nested_calls.con"       42
run_ok "$TESTDIR/struct_basic.con"       7
run_ok "$TESTDIR/struct_field_assign.con" 33
run_ok "$TESTDIR/struct_loop_field_assign.con" 42
run_ok "$TESTDIR/struct_loop_break.con"  42
run_ok "$TESTDIR/struct_nested_loop.con" 42
run_ok "$TESTDIR/struct_if_else_merge.con" 42
run_ok "$TESTDIR/struct_match_merge.con" 42
run_ok "$TESTDIR/match_int_basic.con" 42
run_ok "$TESTDIR/match_int_default.con" 42
run_ok "$TESTDIR/match_int_negative.con" 42
run_ok "$TESTDIR/match_bool.con" 42
run_ok "$TESTDIR/linear_consume.con"     42
run_ok "$TESTDIR/linear_branch_agree.con" 42
run_ok "$TESTDIR/linear_loop_inner.con"  3
run_ok "$TESTDIR/enum_basic.con"        2
run_ok "$TESTDIR/enum_fields.con"       12
run_ok "$TESTDIR/enum_linear.con"       42
run_ok "$TESTDIR/borrow_read.con"      10
run_ok "$TESTDIR/borrow_mut.con"       42
run_ok "$TESTDIR/borrow_no_consume.con" 42
run_ok "$TESTDIR/sequential_mut_borrow.con" 43
run_ok "$TESTDIR/generic_fn.con"       42
run_ok "$TESTDIR/generic_struct.con"   30
run_ok "$TESTDIR/string_basic.con"    5
run_ok "$TESTDIR/string_borrow.con"   10
run_ok "$TESTDIR/result_ok.con"      42
run_ok "$TESTDIR/result_err.con"     99
run_ok "$TESTDIR/result_generic_try.con" 42
# Network test — skip in fast mode
if [ "$MODE" != "fast" ]; then
    run_ok "$TESTDIR/net_tcp_roundtrip.con" 42
else
    echo "skip tests/programs/net_tcp_roundtrip.con (fast mode)"
    SKIP=$((SKIP + 1))
fi
run_ok "$TESTDIR/module_basic.con"   42
run_ok "$TESTDIR/module_struct.con"  30
run_ok "$TESTDIR/array_basic.con"   20
run_ok "$TESTDIR/array_assign.con"  5
run_ok "$TESTDIR/cast_basic.con"    42
run_ok "$TESTDIR/cast_float.con"    7
run_ok "$TESTDIR/impl_method.con"   30
run_ok "$TESTDIR/impl_mut_method.con" 42
run_ok "$TESTDIR/impl_static.con"   7
run_ok "$TESTDIR/trait_basic.con"   30
run_ok "$TESTDIR/trait_multiple.con" 50
run_ok "$TESTDIR/cap_basic.con"    0
run_ok "$TESTDIR/cap_bang.con"     30
run_ok "$TESTDIR/cap_method.con"   0
run_ok "$TESTDIR/break_basic.con"  5
run_ok "$TESTDIR/continue_basic.con" 25
run_ok "$TESTDIR/break_for.con"    10
run_ok "$TESTDIR/continue_for.con" 27
# Phase 3: defer/destroy/Copy
run_ok "$TESTDIR/defer_basic.con" 10
run_ok "$TESTDIR/defer_lifo.con" 42
run_ok "$TESTDIR/defer_early_return.con" 10
run_ok "$TESTDIR/defer_loop.con" 42
run_ok "$TESTDIR/destroy_trait.con" 42
run_ok "$TESTDIR/copy_struct.con" 42
run_ok "$TESTDIR/copy_enum.con" 42

# Adversarial codegen tests
run_ok "$TESTDIR/adversarial_codegen_deeply_nested_if.con" 42
run_ok "$TESTDIR/adversarial_codegen_for_loop_zero_iters.con" 99
run_ok "$TESTDIR/adversarial_codegen_cast_chain.con" 42
run_ok "$TESTDIR/adversarial_codegen_many_params.con" 36
run_ok "$TESTDIR/adversarial_codegen_enum_match.con" "$(printf '10\n25\n30\n42')"
run_ok "$TESTDIR/adversarial_codegen_string_operations.con" "$(printf 'hello world\n11')"
run_ok "$TESTDIR/adversarial_codegen_bool_logic.con" 42
run_ok "$TESTDIR/adversarial_codegen_nested_struct_array.con" 37
run_ok "$TESTDIR/adversarial_codegen_array_in_loop.con" 100
run_ok "$TESTDIR/adversarial_codegen_struct_return_chain.con" 10
run_ok "$TESTDIR/adversarial_codegen_array_bounds.con" 77
run_ok "$TESTDIR/adversarial_codegen_large_struct.con" 55
# Adversarial linear/cap positive tests
run_ok "$TESTDIR/adversarial_linear_correct_chain.con" 30
run_ok "$TESTDIR/adversarial_cap_correct_propagation.con" 0

# abort test: compiles but exits with nonzero (signal)
run_abort_worker() {
    local file="$1"
    local result_file="$2"
    local name
    name=$(path_key "${file%.con}")
    local out="$TMPDIR/$name"
    if ! $COMPILER "$file" -o "$out" > /dev/null 2>&1; then
        {
            echo "FAIL"
            echo "FAIL  $file — compilation failed"
        } > "$result_file"
        return
    fi
    # Suppress bash's own "Abort trap" diagnostic for expected signal exits.
    # We only care whether the program exited successfully or not.
    if { "$out" > /dev/null 2>&1; } 2>/dev/null; then
        {
            echo "FAIL"
            echo "FAIL  $file — expected nonzero exit"
        } > "$result_file"
    else
        {
            echo "PASS"
            echo "  ok  $file => nonzero exit"
        } > "$result_file"
    fi
}
run_abort() {
    local file="$1"
    if ! filter_match "$file"; then SKIP=$((SKIP + 1)); return; fi
    if [ "$TEST_JOBS" -le 1 ]; then
        JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
        run_abort_worker "$file" "$result_file"
        record_result "$result_file"
        return
    fi
    JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
    throttle_jobs
    (run_abort_worker "$file" "$result_file") &
    JOB_PIDS+=("$!")
    JOB_FILES+=("$result_file")
}
run_abort "$TESTDIR/abort_basic.con"

# Phase 5: Allocator system
run_ok "$TESTDIR/alloc_basic.con" 30
run_ok "$TESTDIR/alloc_propagate.con" 30
run_ok "$TESTDIR/heap_arrow.con" 20
run_ok "$TESTDIR/heap_arrow_mut.con" 42

# Phase 6: Borrow regions
run_ok "$TESTDIR/borrow_named.con" 30
run_ok "$TESTDIR/borrow_mut_named.con" 42
run_ok "$TESTDIR/borrow_multi.con" 35

# Capability polymorphism
run_ok "$TESTDIR/cap_poly.con" 42
run_ok "$TESTDIR/cap_poly_chain.con" 42

# Borrow escape (positive — deref value is OK)
run_ok "$TESTDIR/escape_return.con" 10

# Complex multi-feature programs
run_ok "$TESTDIR/complex_linked_list.con" 42
run_ok "$TESTDIR/complex_closure_pipeline.con" 27
run_ok "$TESTDIR/complex_struct_methods.con" 42
run_ok "$TESTDIR/complex_defer_destroy.con" 42
run_ok "$TESTDIR/complex_enum_result.con" 25
run_ok "$TESTDIR/result_string.con" 5
run_ok "$TESTDIR/complex_borrow_compute.con" 170
run_ok "$TESTDIR/complex_generic_container.con" 42
run_ok "$TESTDIR/complex_loop_accumulate.con" 50

# Phase 4: while-as-expression
run_ok "$TESTDIR/while_expr_basic.con" 5
run_ok "$TESTDIR/while_expr_no_break.con" 99
run_ok "$TESTDIR/while_expr_nested.con" 6
run_ok "$TESTDIR/break_accumulate.con" 10
run_ok "$TESTDIR/while_nested_break.con" 6

# Additional capability tests
run_ok "$TESTDIR/cap_std_expand.con" 0
run_ok "$TESTDIR/cap_nested_call.con" 42

# Additional defer/Copy tests
run_ok "$TESTDIR/defer_nested_scope.con" 42
run_ok "$TESTDIR/defer_try.con" 42
run_ok "$TESTDIR/copy_multiple_use.con" 50

# Additional allocator tests
run_ok "$TESTDIR/heap_struct_method.con" 30
run_ok "$TESTDIR/alloc_free_loop.con" 45

# Additional borrow region tests
run_ok "$TESTDIR/borrow_sequential.con" 30
run_ok "$TESTDIR/borrow_copy_in_block.con" 42

# Phase 7: Bitwise operators + hex/bin/oct literals
run_ok "$TESTDIR/bitwise_and.con" 15
run_ok "$TESTDIR/bitwise_or.con" 255
run_ok "$TESTDIR/bitwise_xor.con" 240
run_ok "$TESTDIR/bitwise_shift.con" 1056
run_ok "$TESTDIR/bitwise_not.con" -1
run_ok "$TESTDIR/hex_literal.con" 255
run_ok "$TESTDIR/bin_oct_literal.con" 73

# Phase 7b: Print / basic I/O
run_ok "$TESTDIR/print_int_basic.con" "42"
run_ok "$TESTDIR/print_bool_basic.con" "true"
run_ok "$TESTDIR/builtin_println_mixed.con" "42
hello
true
false"
run_ok "$TESTDIR/builtin_print_multi_arg.con" "count: 42 ok: true"
run_ok "$TESTDIR/builtin_println_i32.con" "42
A"
run_ok "$TESTDIR/print_in_loop.con" "0
1
2"

# Phase 7c: Module file resolution
run_ok "$TESTDIR/module_file/main.con" 42
run_ok "$TESTDIR/module_qualified/main.con" 42
run_ok "$TESTDIR/module_qualified_mixed/main.con" 42
run_ok "$TESTDIR/module_qualified_two_mods/main.con" 42
run_ok "$TESTDIR/module_qualified_toplevel_shadow/main.con" 42
run_ok "$TESTDIR/module_qualified_extern/main.con" 42
run_ok "$TESTDIR/module_qualified_impl/main.con" 42
run_ok "$TESTDIR/module_qualified_collision/main.con" 54
run_ok "$TESTDIR/module_qualified_parent_shadow/main.con" 42
run_ok "$TESTDIR/module_import_collision/main.con" 54

# Additional complex tests
run_ok "$TESTDIR/complex_fibonacci_closure.con" 55
run_ok "$TESTDIR/complex_state_machine.con" 42
run_ok "$TESTDIR/complex_builder_pattern.con" 60
run_ok "$TESTDIR/complex_error_chain.con" 40
run_ok "$TESTDIR/complex_defer_cleanup.con" 30

# Phase C: Self keyword
run_ok "$TESTDIR/self_type_basic.con" 42
run_ok "$TESTDIR/self_type_method.con" 42

# Phase D: Labeled loops
run_ok "$TESTDIR/labeled_break.con" 42
run_ok "$TESTDIR/labeled_continue.con" 0

# Phase E: Trait bounds
run_ok "$TESTDIR/trait_bound_basic.con" 30
run_ok "$TESTDIR/trait_bound_multiple.con" 50

# Phase G: Recursive data structure tests
run_ok "$TESTDIR/complex_recursive_list.con" 42
run_ok "$TESTDIR/complex_recursive_tree.con" 42
run_ok "$TESTDIR/complex_recursive_mutual.con" 42

# Phase 7c: Heap dereference
run_ok "$TESTDIR/heap_deref_basic.con" 30
run_ok "$TESTDIR/heap_deref_int.con" 42
run_ok "$TESTDIR/heap_deref_enum.con" 42
run_ok "$TESTDIR/heap_deref_recursive.con" 42

# Phase 9a: Option<T>
run_ok "$TESTDIR/option_basic.con" 52
run_ok "$TESTDIR/option_heap.con" 42
run_ok "$TESTDIR/option_string.con" 2
run_ok "$TESTDIR/option_mixed_payloads.con" 44

# Phase 11: File I/O builtins
run_ok "$TESTDIR/file_write_read.con" 5
run_ok "$TESTDIR/file_read_basic.con" 12

# Phase 10: Monomorphized trait dispatch
run_ok "$TESTDIR/trait_dispatch_basic.con" 30
run_ok "$TESTDIR/trait_dispatch_multi.con" 47
run_ok "$TESTDIR/trait_dispatch_chain.con" 42

# Phase 12: New stdlib builtins
run_ok "$TESTDIR/string_slice_basic.con" 5
run_ok "$TESTDIR/string_char_at_basic.con" 65
run_ok "$TESTDIR/string_contains_basic.con" 1
run_ok "$TESTDIR/string_eq_basic.con" 1
run_ok "$TESTDIR/int_to_string_basic.con" 2
run_ok "$TESTDIR/string_to_int_basic.con" 123
run_ok "$TESTDIR/string_trim_basic.con" 5
run_ok "$TESTDIR/print_char_basic.con" "A0"

# Vec<T> tests
run_ok "$TESTDIR/vec_basic.con" 23
run_ok "$TESTDIR/vec_push_get.con" 500
run_ok "$TESTDIR/vec_pop.con" 42
run_ok "$TESTDIR/vec_set_basic.con" 99
run_ok "$TESTDIR/vec_len_after_ops.con" 32
run_ok "$TESTDIR/vec_stress_realloc.con" 249
run_ok "$TESTDIR/vec_set_all.con" 60
run_ok "$TESTDIR/vec_pop_until_empty.con" 29

# Networking tests (skipped in fast mode)
if [ "$MODE" = "fast" ] || [ "${SKIP_FLAKY_TCP_TEST:-0}" = "1" ]; then
    echo "skip tests/programs/tcp_basic.con (fast mode or SKIP_FLAKY_TCP_TEST=1)"
    SKIP=$((SKIP + 1))
else
    run_ok "$TESTDIR/tcp_basic.con" 1
fi
run_ok "$TESTDIR/socket_listen_close.con" 0

# Phase 7: FFI / Unsafe
run_ok "$TESTDIR/ffi_basic.con" 42
run_ok "$TESTDIR/trusted_extern_basic.con" 42

# Phase 8: Additional coverage
run_ok "$TESTDIR/nested_match_enum.con" 60
run_ok "$TESTDIR/generic_pair.con" 42
run_ok "$TESTDIR/enum_multi_variant.con" 8
run_ok "$TESTDIR/trait_multi_bound.con" 42
run_ok "$TESTDIR/while_nested_labeled.con" 25
run_ok "$TESTDIR/if_else_while.con" 3
run_ok "$TESTDIR/while_seq_scoping.con" 400
run_ok "$TESTDIR/fmt_parse_roundtrip.con" 0
run_ok "$TESTDIR/vec_trace.con" 0
run_ok "$TESTDIR/struct_nested.con" 42
run_ok "$TESTDIR/complex_multi_feature.con" 40
run_ok "$TESTDIR/complex_heap_borrow.con" 42
run_ok "$TESTDIR/complex_enum_nested.con" 87
run_ok "$TESTDIR/defer_multiple.con" 30
run_ok "$TESTDIR/borrow_in_method.con" 67
run_ok "$TESTDIR/generic_multi_bound_dispatch.con" 49
run_ok "$TESTDIR/complex_recursive_enum.con" 19
run_ok "$TESTDIR/struct_method_chain.con" 39
run_ok "$TESTDIR/complex_option_chain.con" 26
run_ok "$TESTDIR/complex_trait_hierarchy.con" 45
run_ok "$TESTDIR/cap_propagation_deep.con" "1
42"

# Unsafe boundary: ref-to-ptr is safe (no Unsafe needed)
run_ok "$TESTDIR/ref_to_ptr_safe.con" 0

# repr(C) / FFI safety
run_ok "$TESTDIR/repr_c_basic.con" 42
run_ok "$TESTDIR/repr_c_nested.con" 42
run_ok "$TESTDIR/repr_c_cross_module.con" 30

# Function pointer from struct field (indirect call fix)
run_ok "$TESTDIR/fn_ptr_struct_field.con" 42
run_ok "$TESTDIR/fn_ptr_method_call.con" 42
run_ok "$TESTDIR/stdlib_hashmap.con" 0

# Integration tests: multi-feature programs
run_ok "$TESTDIR/integration_text_processing.con" 0
run_ok "$TESTDIR/integration_data_structures.con" 0
run_ok "$TESTDIR/integration_error_handling.con" 0
run_ok "$TESTDIR/integration_generic_pipeline.con" 42
run_ok "$TESTDIR/integration_state_machine.con" 42
run_ok "$TESTDIR/integration_compiler_stress.con" 42
run_ok "$TESTDIR/integration_multi_module.con" 42
run_ok "$TESTDIR/integration_recursive_structures.con" 42
run_ok "$TESTDIR/integration_multi_file_calculator.con" 42
run_ok "$TESTDIR/integration_type_registry.con" 42
run_ok "$TESTDIR/integration_pipeline_processor.con" 42
run_ok "$TESTDIR/integration_stress_workload.con" 42
run_ok "$TESTDIR/bug_cross_module_struct_field.con" 42
run_ok "$TESTDIR/bug_i32_literal_type.con" 42
run_ok "$TESTDIR/bug_cross_module_mut_borrow.con" 42
run_ok "$TESTDIR/bug_array_var_index_assign.con" 42
run_ok "$TESTDIR/bug_if_expression.con" 0
run_ok "$TESTDIR/bug_print_builtins.con" "hello 42
0"
run_ok "$TESTDIR/bug_string_building.con" 0
run_ok "$TESTDIR/bug_clock_builtin.con" 0
run_ok "$TESTDIR/bug_enum_in_struct.con" 0
run_ok "$TESTDIR/bug_stack_array_borrow_copy.con" 42
run_ok "$TESTDIR/hardening_int_literal_inference.con" 42
run_ok "$TESTDIR/hardening_borrow_edge_cases.con" 42
run_ok "$TESTDIR/hardening_cross_module_enum.con" 42
run_ok "$TESTDIR/hardening_cross_module_trait.con" 42
run_ok "$TESTDIR/hardening_cross_module_type_alias.con" 42
run_ok "$TESTDIR/struct_enum_field_vec.con" 123

fi # end section: positive

echo ""
flush_jobs
if section_active negative; then
echo "=== Negative tests (expected errors) ==="
run_err "$TESTDIR/error_unconsumed.con"        "was never consumed"
run_err "$TESTDIR/error_use_after_move.con"    "used after move"
run_err "$TESTDIR/error_branch_disagree.con"   "consumed in one branch"
run_err "$TESTDIR/error_loop_consume.con"      "inside a loop"
run_err "$TESTDIR/error_type_mismatch.con"     "type mismatch"
run_err "$TESTDIR/error_no_else_consume.con"   "no else branch"
run_err "$TESTDIR/error_enum_nonexhaustive.con"   "non-exhaustive match"
run_err "$TESTDIR/error_enum_match_disagree.con"   "match arms disagree"
run_err "$TESTDIR/error_enum_unknown_variant.con"  "unknown variant"
run_err "$TESTDIR/error_borrow_after_move.con"    "used after move"
run_err "$TESTDIR/error_linear_used_not_consumed.con" "was never consumed"
run_err "$TESTDIR/error_deref_non_ref.con"        "cannot dereference"
run_err "$TESTDIR/error_generic_count.con"       "expects 2 arguments"
run_err "$TESTDIR/error_generic_type.con"        "type mismatch"
run_err "$TESTDIR/error_generic_unused_linear.con" "was never consumed"
run_err "$TESTDIR/error_string_unconsumed.con"   "was never consumed"
run_err "$TESTDIR/error_try_non_result.con"      "requires a Result enum"
run_err "$TESTDIR/error_try_wrong_return.con"    "function must return same Result type"
run_err "$TESTDIR/error_import_private.con"      "is not public"
run_err "$TESTDIR/error_private_field.con"       "unknown module"
run_err "$TESTDIR/error_array_type.con"          "type mismatch"
run_err "$TESTDIR/error_array_index.con"         "type mismatch"
run_err "$TESTDIR/error_cast_invalid.con"        "cannot cast"
run_err "$TESTDIR/error_unknown_method.con"      "no method"
run_err "$TESTDIR/error_trait_missing_method.con" "missing method"
run_err "$TESTDIR/error_trait_wrong_sig.con"     "signature does not match"
run_err "$TESTDIR/error_cap_pure.con"            "but caller has"
run_err "$TESTDIR/error_cap_propagation.con"     "but caller has"
run_err "$TESTDIR/error_cap_method.con"          "but caller has"
run_err "$TESTDIR/error_cap_poly_inline.con"     "requires capability"
run_err "$TESTDIR/error_break_outside.con"       "break outside of loop"
run_err "$TESTDIR/error_continue_outside.con"    "continue outside of loop"
# Phase 3: defer/destroy/Copy errors
run_err "$TESTDIR/error_defer_move.con"          "reserved by defer"
run_err "$TESTDIR/error_copy_destroy.con"        "implements Destroy and cannot be Copy"
run_err "$TESTDIR/error_copy_linear_field.con"   "contains non-copy field"
run_err "$TESTDIR/error_destroy_no_impl.con"     "does not implement Destroy"
run_err "$TESTDIR/error_destroy_reserved.con"    "is a reserved identifier"
# Phase 5: Allocator errors
run_err "$TESTDIR/error_alloc_no_cap.con"       "but caller has"
run_err "$TESTDIR/error_heap_direct_access.con"  "use '->' for heap access"
run_err "$TESTDIR/error_heap_leak.con"           "was never consumed"
run_err "$TESTDIR/error_alloc_reserved.con"      "is a reserved identifier"
# Phase 6: Borrow region errors
run_err "$TESTDIR/error_borrow_escape.con"     "cannot escape its borrow block"
run_err "$TESTDIR/error_borrow_frozen.con"     "is frozen by borrow block"
run_err "$TESTDIR/error_borrow_shadow.con"     "shadows existing name"
run_err "$TESTDIR/error_borrow_mut_conflict.con" "is frozen by borrow block"
run_err "$TESTDIR/error_named_ref_mut_conflict.con" "already borrowed"
# Additional escape analysis errors
run_err "$TESTDIR/error_escape_return.con"     "cannot escape its borrow block"
run_err "$TESTDIR/error_escape_field.con"      "cannot escape its borrow block"
# While-as-expression errors
run_err "$TESTDIR/error_while_expr_type.con"   "does not match else type"
# Additional break/continue errors
run_err "$TESTDIR/error_break_linear_skip.con" "break would skip unconsumed linear variable"
# Additional borrow errors
run_err "$TESTDIR/error_borrow_double_mut.con"   "is frozen by borrow block"
run_err "$TESTDIR/error_borrow_assign_frozen.con" "frozen by borrow block"
# Bitwise errors
run_err "$TESTDIR/error_bitwise_float.con" "type mismatch"
# Print errors
run_err "$TESTDIR/error_print_no_cap.con" "but caller has"
# Module errors
run_err "$TESTDIR/error_module_not_found.con" "module file not found"
run_err "$TESTDIR/module_circular/main.con" "circular module import"
# Self keyword errors
run_err "$TESTDIR/error_self_outside_impl.con" "Self can only be used inside impl blocks"
# Labeled loop errors
run_err "$TESTDIR/error_unknown_label.con" "unknown loop label"
run_err "$TESTDIR/error_label_not_loop.con" "label can only precede while or for"
# Trait bound errors
run_err "$TESTDIR/error_trait_bound_missing.con" "does not implement trait"
# Trait dispatch errors
run_err "$TESTDIR/error_trait_dispatch_missing.con" "no method"
# File I/O errors
run_err "$TESTDIR/error_file_no_cap.con" "but caller has"
# FFI errors
run_err "$TESTDIR/error_ffi_no_unsafe.con" "but caller has"
# Vec errors
run_err "$TESTDIR/error_vec_no_alloc.con" "but caller has"
# Network errors
run_err "$TESTDIR/error_network_no_cap.con" "but caller has"
# Match exhaustiveness
run_err "$TESTDIR/error_match_missing_variant.con" "missing variant"
# Return type mismatch
run_err "$TESTDIR/error_return_type_mismatch.con" "type mismatch"
# Capability propagation errors
run_err "$TESTDIR/error_cap_deep_missing.con" "but caller has"
# Borrow conflict errors
run_err "$TESTDIR/error_borrow_double_mut.con" "frozen by borrow"

# Span-bearing diagnostics (Resolve errors include line:col prefix)
run_err "$TESTDIR/error_resolve_undeclared_span.con" "4:12: error[resolve]: undeclared variable"
run_err "$TESTDIR/error_resolve_unknown_func_span.con" "3:18: error[resolve]: unknown function"
run_err "$TESTDIR/error_resolve_unknown_type.con" "error[resolve]: unknown type 'Foo'"
run_err "$TESTDIR/error_resolve_not_enum.con" "is not an enum"
run_err "$TESTDIR/error_resolve_multi_errors.con" "unknown function 'unknown2'"
run_err "$TESTDIR/error_resolve_unknown_enum.con" "unknown enum 'Phantom'"
# Check error variants
run_err "$TESTDIR/error_assign_immutable.con" "cannot assign to immutable"
run_err "$TESTDIR/error_assign_overwrites_linear.con" "cannot reassign linear variable"
run_err "$TESTDIR/error_linear_reassign_after_drop.con" "cannot reassign linear variable"
run_ok  "$TESTDIR/copy_reassign.con" 0
# Match-as-expression
run_ok  "$TESTDIR/match_expr.con" 0
run_ok  "$TESTDIR/match_expr_linear.con" 0
run_ok  "$TESTDIR/match_expr_return_arm.con" 0
run_err "$TESTDIR/error_match_arm_type_mismatch.con" "match arm type"
run_err "$TESTDIR/error_arrow_not_heap.con" "arrow access"
# repr(C) / FFI safety errors
run_err "$TESTDIR/error_repr_c_generic.con" "cannot have type parameters"
run_err "$TESTDIR/error_repr_c_string_field.con" "non-FFI-safe field"
run_err "$TESTDIR/error_extern_string_param.con" "non-FFI-safe parameter"
run_err "$TESTDIR/error_extern_non_repr_struct.con" "non-FFI-safe parameter"
run_err "$TESTDIR/error_repr_c_on_enum.con" "can only be applied to struct"
# Unsafe boundary errors
run_err "$TESTDIR/error_ptr_deref_no_unsafe.con" "requires capability"
run_err "$TESTDIR/error_ptr_assign_no_unsafe.con" "requires capability"
run_err "$TESTDIR/error_ptr_cast_no_unsafe.con" "requires capability"
run_err "$TESTDIR/error_int_to_ptr_no_unsafe.con" "requires capability"
# Trusted boundary tests
run_ok "$TESTDIR/trusted_fn_ptr_deref.con" 0
run_ok "$TESTDIR/trusted_impl_basic.con" 0
run_ok "$TESTDIR/trusted_ptr_assign.con" 0
run_ok "$TESTDIR/trusted_ptr_cast.con" 0
run_err "$TESTDIR/error_trusted_extern_needs_unsafe.con" "but caller has"
run_err "$TESTDIR/error_trusted_on_struct.con" "trusted"
run_ok "$TESTDIR/trusted_trait_impl.con" 0
run_ok "$TESTDIR/trusted_ptr_arith.con" 0
run_err "$TESTDIR/error_ptr_arith_no_unsafe.con" "requires capability"
# Trusted runtime tests
run_ok "$TESTDIR/trusted_deref_runtime.con" 42
run_ok "$TESTDIR/trusted_assign_runtime.con" 77
run_ok "$TESTDIR/trusted_cast_runtime.con" 0
run_ok "$TESTDIR/trusted_arith_runtime.con" 32
run_ok "$TESTDIR/trusted_with_alloc.con" 10
run_ok "$TESTDIR/trusted_report_check.con" 0
# Capability propagation errors
run_err "$TESTDIR/error_cap_alloc_missing.con" "but caller has"
run_err "$TESTDIR/error_cap_console_missing.con" "but caller has"
run_err "$TESTDIR/error_cap_multi_missing.con" "but caller has"
# Trusted + capabilities interaction errors
run_err "$TESTDIR/error_trusted_no_alloc.con" "but caller has"
# Trusted boundary negative tests
run_err "$TESTDIR/error_untrusted_calls_trusted_ptr.con" "requires capability"
run_err "$TESTDIR/error_untrusted_ptr_assign.con" "requires capability"
# Builtin capability enforcement
run_err "$TESTDIR/error_abort_no_process.con" "but caller has"
# Multi-error recovery: multiple errors reported from one function body
run_err "$TESTDIR/error_multi_body.con" "type mismatch in let binding 'y'"
run_err "$TESTDIR/error_multi_body.con" "type mismatch in let binding 'x'"
run_err "$TESTDIR/error_multi_recovery.con" "type mismatch in let binding 'x'"
run_err "$TESTDIR/error_multi_recovery.con" "type mismatch in let binding 'y'"
# Capability alias tests
run_ok "$TESTDIR/cap_alias_basic.con" 1
run_ok "$TESTDIR/cap_alias_pub.con" 42
run_err "$TESTDIR/error_cap_alias_missing.con" "requires Network but caller has"
# Union tests
run_ok "$TESTDIR/union_basic.con" 42

# === Type system soundness tests ===
run_ok "$TESTDIR/test_generic_chain.con" 42
run_ok "$TESTDIR/test_generic_nested_struct.con" 42
run_ok "$TESTDIR/test_method_generic.con" 42
run_ok "$TESTDIR/test_enum_recursive_sum.con" 42
run_ok "$TESTDIR/test_match_exhaustive_nested.con" 42
run_ok "$TESTDIR/test_linearity_branch_agree.con" 42
run_ok "$TESTDIR/test_linearity_match_consume.con" 42
run_ok "$TESTDIR/test_defer_linearity.con" 42
run_ok "$TESTDIR/test_defer_drop_string.con" "hello
hello
1"
run_ok "$TESTDIR/test_defer_multi_consuming.con" "ab
cd
2"
run_ok "$TESTDIR/test_defer_break_no_double.con" "ok
3"
run_ok "$TESTDIR/test_defer_nested_if.con" "yes
yes
1"
run_ok "$TESTDIR/test_defer_consuming_lifo.con" "first second
0"
run_ok "$TESTDIR/test_defer_in_loop_func.con" "xxx
3"
run_ok "$TESTDIR/test_defer_block_scope.con" "inner
1"
run_ok "$TESTDIR/test_defer_loop_iteration.con" "xxx
3"
run_ok "$TESTDIR/test_defer_loop_break_scope.con" "yyy
2"
run_ok "$TESTDIR/test_defer_loop_continue_scope.con" "zzz
3"
run_ok "$TESTDIR/test_defer_try_nested.con" "inner outer
109"
run_ok "$TESTDIR/test_defer_nested_lifo.con" "cba
0"
run_ok "$TESTDIR/test_defer_loop_inner_return.con" "IIIIO
3"
run_ok "$TESTDIR/test_alloca_loop_stress.con" 200000
run_ok "$TESTDIR/test_string_literal_in_loop.con" 5
run_ok "$TESTDIR/test_argv.con" 0
run_ok "$TESTDIR/test_trait_multi_bound.con" 42
run_err "$TESTDIR/error_defer_linear_reuse.con"  "reserved by defer"
run_err "$TESTDIR/error_linearity_branch_disagree.con" "consumed in one branch"
run_err "$TESTDIR/error_linearity_double_consume.con" "used after move"
run_err "$TESTDIR/error_match_non_exhaustive.con" "non-exhaustive match"
run_err "$TESTDIR/error_match_int_no_default.con" "non-exhaustive match"
run_err "$TESTDIR/error_match_bool_no_false.con" "non-exhaustive match"
run_err "$TESTDIR/error_generic_bound_missing.con" "no method"

# === Codegen edge case tests ===
run_ok "$TESTDIR/test_int_overflow_wrap.con" 42
run_ok "$TESTDIR/test_nested_struct_access.con" 42
run_ok "$TESTDIR/test_nested_if_else.con" 42
run_ok "$TESTDIR/test_loop_nested_three.con" 42
run_ok "$TESTDIR/test_large_struct_pass.con" 42
run_ok "$TESTDIR/test_cast_chain.con" 42
run_ok "$TESTDIR/test_early_return_loop.con" 42
run_ok "$TESTDIR/test_many_locals.con" 42
run_ok "$TESTDIR/test_recursive_fibonacci.con" 42
run_ok "$TESTDIR/test_comparison_chain.con" 42

# === Optimization-sensitive codegen tests ===
run_ok "$TESTDIR/test_dead_code_after_return.con" 42
run_ok "$TESTDIR/test_unused_variable.con" 42
run_ok "$TESTDIR/test_constant_fold_complex.con" 42
run_ok "$TESTDIR/test_branch_same_value.con" 42
run_ok "$TESTDIR/test_loop_invariant.con" 42
run_ok "$TESTDIR/test_deeply_nested_return.con" 42
run_ok "$TESTDIR/test_zero_iterations.con" 42
run_ok "$TESTDIR/test_single_iteration_loop.con" 42

# === Capability and trusted tests ===
run_ok "$TESTDIR/test_cap_subset_chain.con" 42
run_ok "$TESTDIR/test_cap_poly_apply.con" 42
run_ok "$TESTDIR/test_cap_alias_nested.con" 42
run_ok "$TESTDIR/test_trusted_impl_method.con" 42
run_ok "$TESTDIR/test_trusted_extern_call.con" 42
run_err "$TESTDIR/error_cap_superset_missing.con" "requires File, Network but caller has"
run_err "$TESTDIR/error_cap_poly_insufficient.con" "requires capability"
run_err "$TESTDIR/error_trusted_not_viral.con" "requires capability"
run_err "$TESTDIR/error_extern_needs_unsafe.con" "requires Unsafe"
run_err "$TESTDIR/error_trusted_no_extern.con" "requires Unsafe"

# === Cross-module and parser tests ===
run_ok "$TESTDIR/test_module_nested.con" 42
run_ok "$TESTDIR/test_module_struct_method.con" 42
run_ok "$TESTDIR/test_module_enum_match.con" 42
run_ok "$TESTDIR/test_module_reexport_type.con" 42
run_ok "$TESTDIR/test_module_sibling_qualified.con" 29
run_ok "$TESTDIR/test_deeply_nested_expr.con" 42
run_ok "$TESTDIR/test_many_params.con" 42
run_ok "$TESTDIR/test_empty_struct.con" 42
run_ok "$TESTDIR/test_enum_many_variants.con" 42
run_ok "$TESTDIR/test_defer_early_return.con" 42
run_ok "$TESTDIR/test_defer_loop_break.con" 42
run_err "$TESTDIR/error_module_private.con" "is not public"
run_err "$TESTDIR/error_private_impl_method.con" "no method"
run_err "$TESTDIR/error_private_trait_impl_method.con" "no method"
run_ok "$TESTDIR/pub_impl_method.con" 30
run_err "$TESTDIR/error_deeply_nested_type_mismatch.con" "type mismatch"

# === ABI / FFI tests ===
run_ok "$TESTDIR/test_repr_c_nested.con" 42
run_ok "$TESTDIR/test_fn_ptr_call_chain.con" 42
run_ok "$TESTDIR/test_fn_ptr_in_struct.con" 42
run_ok "$TESTDIR/test_sizeof_basic_types.con" 42
run_ok "$TESTDIR/test_array_bounds.con" 42
run_ok "$TESTDIR/test_ptr_round_trip.con" 42
run_err "$TESTDIR/error_repr_c_with_generic.con" "cannot have type parameters"
run_err "$TESTDIR/error_fn_ptr_wrong_sig.con" "type mismatch"

# === Phase 3: Large mixed-feature programs ===
run_ok "$TESTDIR/phase3_expression_evaluator.con" 42
run_ok "$TESTDIR/phase3_task_scheduler.con" 42
run_ok "$TESTDIR/phase3_data_pipeline.con" 42
run_ok "$TESTDIR/phase3_type_checker.con" 42
run_ok "$TESTDIR/phase3_state_machine.con" 42
run_ok "$TESTDIR/phase3_report_consistency.con" 42

# === Phase 3: Diagnostic quality tests ===
# Multi-error: compiler reports all 3 independent errors in one function body
run_err "$TESTDIR/phase3_diag_multi_error.con" "type mismatch in let binding 'a'"
# Specific location: error points to correct line in nested code
run_err "$TESTDIR/phase3_diag_specific_location.con" "type mismatch"
# Hint quality: capability error includes actionable hint
run_err "$TESTDIR/phase3_diag_hint_quality.con" "hint:"
# Type mismatch shows both expected and got types
run_err "$TESTDIR/phase3_diag_type_mismatch.con" "expected"

# === String edge case tests ===
run_ok "$TESTDIR/string_empty.con" 0
run_ok "$TESTDIR/string_concat_empty.con" 5
run_ok "$TESTDIR/string_eq_same.con" 1
run_ok "$TESTDIR/string_eq_different.con" 0
run_ok "$TESTDIR/string_slice_full.con" 5
run_ok "$TESTDIR/string_multi_fn.con" 8
run_ok "$TESTDIR/string_contains_empty.con" 1
run_ok "$TESTDIR/string_char_at_first_last.con" 196
run_ok "$TESTDIR/string_trim_spaces.con" 2
run_ok "$TESTDIR/string_to_int_roundtrip.con" 42

# === Math function tests ===
run_ok "$TESTDIR/math_sqrt.con" 5
run_ok "$TESTDIR/math_pow.con" 81
run_ok "$TESTDIR/math_abs.con" 52
run_ok "$TESTDIR/trait_numeric_abs.con" 57
run_ok "$TESTDIR/math_floor_ceil.con" 34
run_ok "$TESTDIR/math_sin_cos.con" 10
run_ok "$TESTDIR/math_exp_log.con" 10

# === Integer edge case tests ===
run_ok "$TESTDIR/int_arithmetic_negative.con" 50
run_ok "$TESTDIR/int_division.con" 31
run_ok "$TESTDIR/int_bitwise_combined.con" 15
run_ok "$TESTDIR/int_shift_basic.con" 4
run_ok "$TESTDIR/int_cast_i32.con" 42
run_ok "$TESTDIR/int_large_multiply.con" 56088

# === Newtype tests ===
run_ok "$TESTDIR/newtype_basic.con" 42
run_ok "$TESTDIR/newtype_copy.con" 20
run_ok "$TESTDIR/newtype_linear.con" 7
run_ok "$TESTDIR/newtype_generic.con" 100
run_err "$TESTDIR/error_newtype_no_implicit.con" "type mismatch"
run_err "$TESTDIR/error_newtype_wrong_inner.con" "type mismatch"

# === ABI / Layout tests ===
run_ok "$TESTDIR/sizeof_basic.con" 12
run_ok "$TESTDIR/alignof_basic.con" 12
run_ok "$TESTDIR/repr_packed.con" 7
run_ok "$TESTDIR/repr_align.con" 16
run_err "$TESTDIR/error_repr_packed_align.con" "cannot have both"
run_err "$TESTDIR/error_repr_align_not_pow2.con" "must be a power of two"

# === Summary-path tests ===
run_ok "$TESTDIR/summary_import_pub_fn.con" 42
run_ok "$TESTDIR/summary_import_pub_constant.con" 42
run_ok "$TESTDIR/summary_import_pub_extern.con" 42
run_ok "$TESTDIR/summary_import_pub_newtype.con" 42
run_ok "$TESTDIR/summary_import_type_alias.con" 42
run_ok "$TESTDIR/summary_submodule.con" 42
run_ok "$TESTDIR/summary_trait_impl_cross_module.con" 42
run_err "$TESTDIR/error_summary_trait_missing_cross.con" "missing method"

fi # end section: negative

# === --test flag tests ===
echo ""
flush_jobs
if section_active testflag; then
echo "=== --test flag tests ==="
run_test_worker() {
    local file="$1"
    local expected="$2"
    local result_file="$3"

    local output exit_code
    output=$($COMPILER "$file" --test 2>&1) && exit_code=0 || exit_code=$?
    if [ "$exit_code" = "$expected" ]; then
        {
            echo "PASS"
            echo "  ok  $file --test (exit $expected)"
        } > "$result_file"
    else
        {
            echo "FAIL"
            echo "FAIL  $file --test — expected exit $expected, got $exit_code"
            echo "$output"
        } > "$result_file"
    fi
}

run_test() {
    local file="$1"
    local expected="$2"
    if ! filter_match "$file"; then SKIP=$((SKIP + 1)); return; fi
    if [ "$TEST_JOBS" -le 1 ]; then
        JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
        run_test_worker "$file" "$expected" "$result_file"
        record_result "$result_file"
        return
    fi
    JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
    throttle_jobs
    (run_test_worker "$file" "$expected" "$result_file") &
    JOB_PIDS+=("$!")
    JOB_FILES+=("$result_file")
}

run_test "$TESTDIR/test_flag_pass.con" 0
run_test "$TESTDIR/test_flag_mixed.con" 1
run_test "$TESTDIR/test_flag_submodule.con" 0

# #[test] validation errors
run_err "$TESTDIR/error_test_with_params.con" "must have no parameters"
run_err "$TESTDIR/error_test_generic.con" "must not be generic"
run_err "$TESTDIR/error_test_wrong_return.con" "must return i32"
run_err "$TESTDIR/error_test_on_struct.con" "can only be applied to function"

fi # end section: testflag

# === Report output tests ===
echo ""
flush_jobs
if section_active report; then
echo "=== Report output tests ==="

# --report unsafe should show trusted boundaries
check_report_multi "$TESTDIR/trusted_report_check.con" unsafe \
    "trusted_report_check.con --report unsafe shows trusted boundaries" \
    "trusted_report_check.con --report unsafe missing trusted boundaries" \
    "trusted impl Buffer" "trusted fn raw_read"

# --report unsafe should show trusted extern fn declarations separately from regular extern fn
check_report_multi "$TESTDIR/trusted_extern_basic.con" unsafe \
    "trusted_extern_basic.con --report unsafe shows trusted extern functions" \
    "trusted_extern_basic.con --report unsafe missing trusted extern functions" \
    "Trusted extern functions" "trusted extern fn abs"

# --report caps should show trusted extern with (none) capability
check_report_multi "$TESTDIR/trusted_extern_basic.con" caps \
    "trusted_extern_basic.con --report caps shows trusted extern with no capability" \
    "trusted_extern_basic.con --report caps missing trusted extern info" \
    "trusted extern:" "abs : (none)"

# --report unsafe should show regular extern under "Extern functions" (not "Trusted")
# This needs a custom check because it combines match + no-match
report_output=$(cached_output "$TESTDIR/ffi_basic.con" "--report unsafe")
if echo "$report_output" | grep -q "Extern functions:" && echo "$report_output" | grep -q "extern fn abs" && ! echo "$report_output" | grep -q "Trusted extern"; then
    echo "  ok  ffi_basic.con --report unsafe shows regular extern (not trusted)"
    PASS=$((PASS + 1))
else
    echo "FAIL  ffi_basic.con --report unsafe should show regular extern, not trusted"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

# --- report caps: pure, single cap, multi cap ---
check_report "$TESTDIR/report_caps_check.con" caps \
    "pure_fn : (pure)" \
    "report_caps_check.con --report caps shows pure_fn : (pure)" \
    "report_caps_check.con --report caps missing pure_fn : (pure)"

check_report "$TESTDIR/report_caps_check.con" caps \
    "alloc_fn : Alloc" \
    "report_caps_check.con --report caps shows alloc_fn : Alloc" \
    "report_caps_check.con --report caps missing alloc_fn : Alloc"

check_report "$TESTDIR/report_caps_check.con" caps \
    "multi_fn : File, Network" \
    "report_caps_check.con --report caps shows multi_fn : File, Network" \
    "report_caps_check.con --report caps missing multi_fn : File, Network"

# --- report unsafe: Unsafe capability + raw pointer signatures ---
check_report_multi "$TESTDIR/report_unsafe_rawptr.con" unsafe \
    "report_unsafe_rawptr.con --report unsafe shows Unsafe capability for ptr_swap" \
    "report_unsafe_rawptr.con --report unsafe missing Unsafe capability for ptr_swap" \
    "Functions with Unsafe capability" "ptr_swap"

check_report_multi "$TESTDIR/report_unsafe_rawptr.con" unsafe \
    "report_unsafe_rawptr.con --report unsafe shows raw pointer signatures for ptr_swap" \
    "report_unsafe_rawptr.con --report unsafe missing raw pointer signatures for ptr_swap" \
    "Functions with raw pointer signatures" "ptr_swap"

# --- report layout: struct sizes, packed, enum tags ---
check_report_multi "$TESTDIR/report_layout_check.con" layout \
    "report_layout_check.con --report layout shows struct Padded with size and align" \
    "report_layout_check.con --report layout missing struct Padded with size/align" \
    "struct Padded" "size:" "align:"

check_report_multi "$TESTDIR/report_layout_check.con" layout \
    "report_layout_check.con --report layout shows struct Packed with #[packed]" \
    "report_layout_check.con --report layout missing struct Packed with #[packed]" \
    "struct Packed" "#\[packed\]"

check_report_multi "$TESTDIR/report_layout_check.con" layout \
    "report_layout_check.con --report layout shows enum Shape with tag and payload_offset" \
    "report_layout_check.con --report layout missing enum Shape with tag/payload_offset" \
    "enum Shape" "tag:" "payload_offset:"

# --- report layout: cross-validate sizes against runtime sizeof ---
report_output=$(cached_output "$TESTDIR/report_layout_check.con" "--report layout")
padded_size=$(echo "$report_output" | grep "struct Padded" -A1 | grep -o "size: [0-9]*" | head -1 | grep -o "[0-9]*")
packed_size=$(echo "$report_output" | grep "struct Packed" -A1 | grep -o "size: [0-9]*" | head -1 | grep -o "[0-9]*")
expected_sum=$((padded_size + packed_size))
$COMPILER "$TESTDIR/report_layout_check.con" -o "$TMPDIR/report_layout_check" > /dev/null 2>&1
runtime_sum=$("$TMPDIR/report_layout_check" 2>&1) || true
if [ "$expected_sum" = "$runtime_sum" ]; then
    echo "  ok  report_layout_check.con layout sizes ($padded_size + $packed_size = $expected_sum) match runtime sizeof ($runtime_sum)"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_layout_check.con layout sizes ($padded_size + $packed_size = $expected_sum) != runtime sizeof ($runtime_sum)"
    FAIL=$((FAIL + 1))
fi

# --- report interface: public API, struct fields, private exclusion ---
check_report_multi "$TESTDIR/report_interface_check.con" interface \
    "report_interface_check.con --report interface shows fn add_points with [Alloc]" \
    "report_interface_check.con --report interface missing fn add_points with [Alloc]" \
    "fn add_points" "\[Alloc\]"

check_report_multi "$TESTDIR/report_interface_check.con" interface \
    "report_interface_check.con --report interface shows struct Point with x: i32" \
    "report_interface_check.con --report interface missing struct Point with x: i32" \
    "struct Point" "x: i32"

check_report "$TESTDIR/report_interface_check.con" interface \
    "private_helper" \
    "report_interface_check.con --report interface excludes private_helper" \
    "report_interface_check.con --report interface should not show private_helper" \
    "!"

# --- report mono: generic count and specializations ---
check_report "$TESTDIR/report_mono_check.con" mono \
    "Generic functions:" \
    "report_mono_check.con --report mono shows Generic functions" \
    "report_mono_check.con --report mono missing Generic functions"

check_report "$TESTDIR/report_mono_check.con" mono \
    "Specializations:" \
    "report_mono_check.con --report mono shows Specializations" \
    "report_mono_check.con --report mono missing Specializations"

# -- Integration test: all report modes on one file --
# Gate: if the file doesn't compile at all, skip all 14 assertions
if compile_gate "$TESTDIR/report_integration.con" "--report caps" "report_integration.con compilation" 14; then

# Caps with why traces
check_report "$TESTDIR/report_integration.con" caps \
    "Alloc.*<- calls vec_new" \
    "report_integration.con --report caps shows Alloc why trace" \
    "report_integration.con --report caps missing Alloc why trace"

check_report "$TESTDIR/report_integration.con" caps \
    "Unsafe.*<- calls raw_extern" \
    "report_integration.con --report caps shows Unsafe why trace" \
    "report_integration.con --report caps missing Unsafe why trace"

# Unsafe with trust boundary analysis
check_report "$TESTDIR/report_integration.con" unsafe \
    "Trust boundary analysis" \
    "report_integration.con --report unsafe shows Trust boundary analysis" \
    "report_integration.con --report unsafe missing Trust boundary analysis"

check_report "$TESTDIR/report_integration.con" unsafe \
    "wraps: extern raw_extern" \
    "report_integration.con --report unsafe shows wraps extern" \
    "report_integration.con --report unsafe missing wraps extern"

# Alloc report
check_report "$TESTDIR/report_integration.con" alloc \
    "allocates: vec_new" \
    "report_integration.con --report alloc shows vec_new allocation" \
    "report_integration.con --report alloc missing vec_new allocation"

check_report "$TESTDIR/report_integration.con" alloc \
    "caller responsible for cleanup" \
    "report_integration.con --report alloc shows returned-alloc note" \
    "report_integration.con --report alloc missing returned-alloc note"

check_report "$TESTDIR/report_integration.con" alloc \
    "defer free" \
    "report_integration.con --report alloc shows defer free" \
    "report_integration.con --report alloc missing defer free"

# Layout: verify struct and enum details
check_report_multi "$TESTDIR/report_integration.con" layout \
    "report_integration.con --report layout shows struct Pair with size" \
    "report_integration.con --report layout missing struct Pair" \
    "struct Pair" "size: 8"

check_report_multi "$TESTDIR/report_integration.con" layout \
    "report_integration.con --report layout shows enum Shape with tag" \
    "report_integration.con --report layout missing enum Shape" \
    "enum Shape" "tag:"

check_report "$TESTDIR/report_integration.con" layout \
    "Totals:.*struct.*enum" \
    "report_integration.con --report layout shows totals" \
    "report_integration.con --report layout missing totals"

# Interface: verify public API exports and private exclusion
check_report_multi "$TESTDIR/report_integration.con" interface \
    "report_integration.con --report interface shows pure_add" \
    "report_integration.con --report interface missing pure_add" \
    "fn pure_add" "(pure)"

check_report_multi "$TESTDIR/report_integration.con" interface \
    "report_integration.con --report interface shows uses_alloc with Alloc" \
    "report_integration.con --report interface missing uses_alloc" \
    "fn uses_alloc" "Alloc"

check_report "$TESTDIR/report_integration.con" interface \
    "alloc_no_free" \
    "report_integration.con --report interface excludes private alloc_no_free" \
    "report_integration.con --report interface should not show private alloc_no_free" \
    "!"

# Mono: verify specialization details
check_report_multi "$TESTDIR/report_integration.con" mono \
    "report_integration.con --report mono shows 1 generic function" \
    "report_integration.con --report mono missing generic function count" \
    "Generic functions:" "1"

check_report "$TESTDIR/report_integration.con" mono \
    "identity.*i32" \
    "report_integration.con --report mono shows identity<i32> specialization" \
    "report_integration.con --report mono missing identity<i32> specialization"

fi # end report_integration.con gate

# --- Collection pipeline integration test ---
# Gate: compile once, then run all report assertions only if compilation succeeds
pipeline_compiled=0
if $COMPILER "$TESTDIR/integration_collection_pipeline.con" -o "$TMPDIR/integration_collection_pipeline" > /dev/null 2>&1; then
    pipeline_compiled=1
    pipeline_exit=$("$TMPDIR/integration_collection_pipeline" 2>&1; echo $?)
    pipeline_exit=$(echo "$pipeline_exit" | tail -1)
    if [ "$pipeline_exit" = "0" ]; then
        echo "  ok  integration_collection_pipeline.con compiles and runs correctly"
        PASS=$((PASS + 1))
    else
        echo "FAIL  integration_collection_pipeline.con runtime exit code: $pipeline_exit"
        FAIL=$((FAIL + 1))
    fi
else
    echo "FAIL  integration_collection_pipeline.con failed to compile (skipping 10 dependent assertions)"
    FAIL=$((FAIL + 1))
    save_failure "integration_collection_pipeline_compile" \
        "$COMPILER $TESTDIR/integration_collection_pipeline.con -o /tmp/test" \
        "compilation failed"
fi

if [ "$pipeline_compiled" -eq 1 ]; then
# Caps: multi-level allocation traces
check_report_multi "$TESTDIR/integration_collection_pipeline.con" caps \
    "integration_collection_pipeline.con --report caps shows build_and_summarize Alloc trace" \
    "integration_collection_pipeline.con --report caps missing build_and_summarize trace" \
    "build_and_summarize : Alloc" "<- calls.*vec_new"

check_report_multi "$TESTDIR/integration_collection_pipeline.con" caps \
    "integration_collection_pipeline.con --report caps identifies pure functions" \
    "integration_collection_pipeline.con --report caps missing pure function detection" \
    "classify : (pure)" "double : (pure)"

# Alloc: multiple allocation patterns
check_report_multi "$TESTDIR/integration_collection_pipeline.con" alloc \
    "integration_collection_pipeline.con --report alloc shows map_vec returns allocation" \
    "integration_collection_pipeline.con --report alloc missing map_vec return-alloc note" \
    "fn map_vec" "caller responsible for cleanup"

check_report_multi "$TESTDIR/integration_collection_pipeline.con" alloc \
    "integration_collection_pipeline.con --report alloc shows build_and_summarize frees" \
    "integration_collection_pipeline.con --report alloc missing build_and_summarize free" \
    "fn build_and_summarize" "frees: vec_free"

check_report_multi "$TESTDIR/integration_collection_pipeline.con" alloc \
    "integration_collection_pipeline.con --report alloc shows count_with_defer defer" \
    "integration_collection_pipeline.con --report alloc missing count_with_defer defer" \
    "fn count_with_defer" "defer free"

check_report "$TESTDIR/integration_collection_pipeline.con" alloc \
    "Totals:.*4 functions allocate" \
    "integration_collection_pipeline.con --report alloc shows 4 allocating functions" \
    "integration_collection_pipeline.con --report alloc wrong allocating function count"

# Layout: struct with 4 fields, enum with 3 variants
check_report_multi "$TESTDIR/integration_collection_pipeline.con" layout \
    "integration_collection_pipeline.con --report layout shows Stats (4 fields, 16 bytes)" \
    "integration_collection_pipeline.con --report layout missing Stats struct" \
    "struct Stats" "size: 16"

check_report_multi "$TESTDIR/integration_collection_pipeline.con" layout \
    "integration_collection_pipeline.con --report layout shows Classification (no payload)" \
    "integration_collection_pipeline.con --report layout missing Classification enum" \
    "enum Classification" "max_payload: 0"

# Interface: public exports
check_report_multi "$TESTDIR/integration_collection_pipeline.con" interface \
    "integration_collection_pipeline.con --report interface shows public functions" \
    "integration_collection_pipeline.con --report interface missing public functions" \
    "fn classify" "fn build_and_summarize"

# Interface: private exclusion (custom check — need both to NOT match)
report_output=$(cached_output "$TESTDIR/integration_collection_pipeline.con" "--report interface")
if ! echo "$report_output" | grep -q "map_vec" && ! echo "$report_output" | grep -q "collect_classified"; then
    echo "  ok  integration_collection_pipeline.con --report interface excludes private functions"
    PASS=$((PASS + 1))
else
    echo "FAIL  integration_collection_pipeline.con --report interface should exclude private functions"
    echo "$report_output"
    FAIL=$((FAIL + 1))
fi

fi # end integration_collection_pipeline gate

# === Authority report tests (--report authority) ===

check_report "$TESTDIR/report_caps_check.con" authority \
    "capability Alloc" \
    "report_caps_check.con --report authority shows Alloc capability section" \
    "report_caps_check.con --report authority missing Alloc section"

check_report "$TESTDIR/report_caps_check.con" authority \
    "capability File" \
    "report_caps_check.con --report authority shows File capability section" \
    "report_caps_check.con --report authority missing File section"

check_report "$TESTDIR/report_caps_check.con" authority \
    "pure_fn" \
    "report_caps_check.con --report authority excludes pure_fn from cap sections" \
    "report_caps_check.con --report authority wrongly includes pure_fn" "!"

check_report "$TESTDIR/report_integration.con" authority \
    "capability Alloc" \
    "report_integration.con --report authority shows Alloc section" \
    "report_integration.con --report authority missing Alloc section"

check_report "$TESTDIR/report_integration.con" authority \
    "capability Unsafe" \
    "report_integration.con --report authority shows Unsafe section" \
    "report_integration.con --report authority missing Unsafe section"

check_report "$TESTDIR/report_integration.con" authority \
    "uses_alloc.*vec_new" \
    "report_integration.con --report authority traces uses_alloc -> vec_new" \
    "report_integration.con --report authority missing uses_alloc chain"

check_report "$TESTDIR/report_integration.con" authority \
    "call_raw.*raw_extern" \
    "report_integration.con --report authority traces call_raw -> raw_extern" \
    "report_integration.con --report authority missing call_raw chain"

check_report "$TESTDIR/report_integration.con" authority \
    "Totals:.*7 functions" \
    "report_integration.con --report authority totals correct" \
    "report_integration.con --report authority wrong totals"

# === Proof eligibility report tests (--report proof) ===

check_report "$TESTDIR/report_caps_check.con" proof \
    "✓ pure_fn" \
    "report_caps_check.con --report proof marks pure_fn eligible" \
    "report_caps_check.con --report proof missing pure_fn eligible"

check_report "$TESTDIR/report_caps_check.con" proof \
    "✗ alloc_fn.*capabilities.*Alloc" \
    "report_caps_check.con --report proof excludes alloc_fn for Alloc" \
    "report_caps_check.con --report proof missing alloc_fn exclusion"

check_report "$TESTDIR/report_integration.con" proof \
    "✓ pure_add" \
    "report_integration.con --report proof marks pure_add eligible" \
    "report_integration.con --report proof missing pure_add eligible"

check_report "$TESTDIR/report_integration.con" proof \
    "✗ call_raw.*trusted boundary" \
    "report_integration.con --report proof excludes call_raw for trusted" \
    "report_integration.con --report proof missing call_raw trusted exclusion"

check_report "$TESTDIR/report_integration.con" proof \
    "✗ call_raw.*calls extern.*raw_extern" \
    "report_integration.con --report proof excludes call_raw for extern call" \
    "report_integration.con --report proof missing call_raw extern exclusion"

check_report "$TESTDIR/report_integration.con" proof \
    "2 eligible for ProofCore" \
    "report_integration.con --report proof shows 2 eligible" \
    "report_integration.con --report proof wrong eligible count"

check_report "$TESTDIR/report_integration.con" proof \
    "5 excluded" \
    "report_integration.con --report proof shows 5 excluded" \
    "report_integration.con --report proof wrong excluded count"

# --- Proof boundary: pure-only program ---
check_report_multi "$TESTDIR/test_proof_eligible_pure.con" proof \
    "test_proof_eligible_pure.con --report proof 4 eligible, 1 excluded" \
    "test_proof_eligible_pure.con --report proof wrong counts" \
    "4 eligible for ProofCore" "1 excluded"

check_report_multi "$TESTDIR/test_proof_eligible_pure.con" proof \
    "test_proof_eligible_pure.con --report proof add,multiply,make_point,color_value eligible" \
    "test_proof_eligible_pure.con --report proof missing eligible fns" \
    "✓ add" "✓ multiply" "✓ make_point" "✓ color_value"

check_report "$TESTDIR/test_proof_eligible_pure.con" proof \
    "✗ main.*capabilities" \
    "test_proof_eligible_pure.con --report proof main excluded for caps" \
    "test_proof_eligible_pure.con --report proof main not excluded"

# --- Proof boundary: mixed eligible/ineligible ---
check_report_multi "$TESTDIR/test_proof_mixed.con" proof \
    "test_proof_mixed.con --report proof add,max eligible" \
    "test_proof_mixed.con --report proof missing eligible fns" \
    "✓ add" "✓ max"

check_report "$TESTDIR/test_proof_mixed.con" proof \
    "✗ read_data.*capabilities.*File" \
    "test_proof_mixed.con --report proof read_data excluded for File cap" \
    "test_proof_mixed.con --report proof read_data not excluded"

check_report "$TESTDIR/test_proof_mixed.con" proof \
    "✗ ptr_op.*trusted boundary" \
    "test_proof_mixed.con --report proof ptr_op excluded for trusted" \
    "test_proof_mixed.con --report proof ptr_op not excluded"

check_report_multi "$TESTDIR/test_proof_mixed.con" proof \
    "test_proof_mixed.con --report proof 2 eligible, 3 excluded" \
    "test_proof_mixed.con --report proof wrong counts" \
    "2 eligible for ProofCore" "3 excluded"

# --- Proof boundary: trusted excluded even without pointer ops ---
check_report "$TESTDIR/test_proof_trusted_excluded.con" proof \
    "✗ safe_transform.*trusted boundary" \
    "test_proof_trusted_excluded.con --report proof safe_transform excluded" \
    "test_proof_trusted_excluded.con --report proof safe_transform not excluded"

check_report "$TESTDIR/test_proof_trusted_excluded.con" proof \
    "✓ pure_helper" \
    "test_proof_trusted_excluded.con --report proof pure_helper eligible" \
    "test_proof_trusted_excluded.con --report proof pure_helper not eligible"

check_report_multi "$TESTDIR/test_proof_trusted_excluded.con" proof \
    "test_proof_trusted_excluded.con --report proof 2 eligible, 1 excluded" \
    "test_proof_trusted_excluded.con --report proof wrong counts" \
    "2 eligible for ProofCore" "1 excluded"

# === Phase 3: Report consistency cross-checks ===

# Cross-check 1: proof-eligible functions are pure in caps report
check_report "$TESTDIR/phase3_report_consistency.con" proof \
    "✓ pure_compute" \
    "consistency: proof marks pure_compute eligible" \
    "consistency: pure_compute not proof-eligible"

check_report "$TESTDIR/phase3_report_consistency.con" caps \
    "pure_compute.*(pure)" \
    "consistency: caps confirms pure_compute is pure" \
    "consistency: caps disagrees on pure_compute"

check_report "$TESTDIR/phase3_report_consistency.con" proof \
    "✓ pure_multiply" \
    "consistency: proof marks pure_multiply eligible" \
    "consistency: pure_multiply not proof-eligible"

check_report "$TESTDIR/phase3_report_consistency.con" caps \
    "pure_multiply.*(pure)" \
    "consistency: caps confirms pure_multiply is pure" \
    "consistency: caps disagrees on pure_multiply"

# Cross-check 2: trusted functions in unsafe report AND excluded from proof
check_report "$TESTDIR/phase3_report_consistency.con" unsafe \
    "trusted_read" \
    "consistency: unsafe shows trusted_read" \
    "consistency: unsafe missing trusted_read"

check_report "$TESTDIR/phase3_report_consistency.con" proof \
    "✗ trusted_read.*trusted boundary" \
    "consistency: proof excludes trusted_read" \
    "consistency: proof doesn't exclude trusted_read"

check_report "$TESTDIR/phase3_report_consistency.con" unsafe \
    "safe_abs" \
    "consistency: unsafe shows safe_abs" \
    "consistency: unsafe missing safe_abs"

# Cross-check 3: functions with capabilities appear in caps report
check_report "$TESTDIR/phase3_report_consistency.con" caps \
    "needs_alloc.*Alloc" \
    "consistency: caps shows needs_alloc requires Alloc" \
    "consistency: caps missing needs_alloc Alloc"

check_report "$TESTDIR/phase3_report_consistency.con" proof \
    "✗ needs_alloc.*capabilities.*Alloc" \
    "consistency: proof excludes needs_alloc for Alloc" \
    "consistency: proof doesn't exclude needs_alloc"

# Cross-check 4: generic functions appear in mono report
check_report "$TESTDIR/phase3_report_consistency.con" mono \
    "identity.*identity_for_i32" \
    "consistency: mono shows identity<i32> specialization" \
    "consistency: mono missing identity specialization"

check_report "$TESTDIR/phase3_report_consistency.con" mono \
    "generic_add_one.*generic_add_one_for_i32" \
    "consistency: mono shows generic_add_one<i32> specialization" \
    "consistency: mono missing generic_add_one specialization"

# Cross-check 5: allocating functions in alloc report
check_report "$TESTDIR/phase3_report_consistency.con" alloc \
    "needs_alloc" \
    "consistency: alloc shows needs_alloc" \
    "consistency: alloc missing needs_alloc"

check_report "$TESTDIR/phase3_report_consistency.con" alloc \
    "alloc_and_free" \
    "consistency: alloc shows alloc_and_free" \
    "consistency: alloc missing alloc_and_free"

# Cross-check 6: repr(C) struct in layout report
check_report "$TESTDIR/phase3_report_consistency.con" layout \
    "CPoint.*repr(C)" \
    "consistency: layout shows CPoint as repr(C)" \
    "consistency: layout missing CPoint repr(C)"

# Cross-check 7: proof eligible count matches pure count in caps
check_report "$TESTDIR/phase3_report_consistency.con" proof \
    "5 eligible for ProofCore" \
    "consistency: proof shows 5 eligible" \
    "consistency: proof wrong eligible count"

# === Phase 3: Diagnostic quality assertions ===
# Multi-error: all 3 independent type errors reported
output=$($COMPILER "$TESTDIR/phase3_diag_multi_error.con" --emit-llvm 2>&1 || true)
if echo "$output" | grep -q "type mismatch in let binding 'a'" \
   && echo "$output" | grep -q "type mismatch in let binding 'b'" \
   && echo "$output" | grep -q "type mismatch in let binding 'c'"; then
    echo "  ok  phase3_diag_multi_error.con reports all 3 independent errors"
    PASS=$((PASS + 1))
else
    echo "FAIL  phase3_diag_multi_error.con missing expected errors"
    FAIL=$((FAIL + 1))
fi

# Specific location: error on correct line
output=$($COMPILER "$TESTDIR/phase3_diag_specific_location.con" --emit-llvm 2>&1 || true)
if echo "$output" | grep -q "^.*:9:.*error"; then
    echo "  ok  phase3_diag_specific_location.con error points to line 9"
    PASS=$((PASS + 1))
else
    echo "FAIL  phase3_diag_specific_location.con error not on line 9"
    FAIL=$((FAIL + 1))
fi

# No cascade: single root cause produces < 5 errors
output=$($COMPILER "$TESTDIR/phase3_diag_no_cascade.con" --emit-llvm 2>&1 || true)
error_count=$(echo "$output" | grep -c "error\[" || true)
if [ "$error_count" -lt 5 ]; then
    echo "  ok  phase3_diag_no_cascade.con $error_count error(s) (< 5, no cascade)"
    PASS=$((PASS + 1))
else
    echo "FAIL  phase3_diag_no_cascade.con cascaded into $error_count errors"
    FAIL=$((FAIL + 1))
fi

# Hint quality: capability error includes hint
output=$($COMPILER "$TESTDIR/phase3_diag_hint_quality.con" --emit-llvm 2>&1 || true)
if echo "$output" | grep -q "requires File" && echo "$output" | grep -qi "hint:"; then
    echo "  ok  phase3_diag_hint_quality.con capability error with hint"
    PASS=$((PASS + 1))
else
    echo "FAIL  phase3_diag_hint_quality.con missing hint"
    FAIL=$((FAIL + 1))
fi

# === Predictable profile tests (--check predictable) ===

echo ""
echo "=== Predictable profile tests ==="

# --- Gate 0: full pass (all functions pass all five gates) ---
check_profile "$TESTDIR/report_check_predictable_pass.con" predictable \
    "predictable profile: pass" \
    "predictable_pass.con passes all five gates" \
    "predictable_pass.con should pass but failed"

check_profile "$TESTDIR/report_check_predictable_pass.con" predictable \
    "4 functions checked" \
    "predictable_pass.con checks all 4 functions" \
    "predictable_pass.con wrong function count"

# --- Gate 1: recursion rejection ---
check_profile "$TESTDIR/report_check_predictable_fail_recursion.con" predictable \
    "countdown.*direct recursion" \
    "predictable rejects direct recursion" \
    "predictable should reject recursion"

check_profile "$TESTDIR/report_check_predictable_fail_recursion.con" predictable \
    "1 function(s) failed" \
    "predictable recursion: 1 failed" \
    "predictable recursion: wrong fail count"

# --- Gate 2: unbounded loop rejection ---
check_profile "$TESTDIR/report_check_predictable_fail_loops.con" predictable \
    "spin.*unbounded loop" \
    "predictable rejects unbounded while loop" \
    "predictable should reject unbounded loop"

# --- Gate 3: allocation rejection ---
check_profile "$TESTDIR/report_check_predictable_fail_alloc.con" predictable \
    "heap_op.*allocates" \
    "predictable rejects allocation" \
    "predictable should reject allocation"

# --- Gate 4: FFI rejection ---
check_profile "$TESTDIR/report_check_predictable_fail_ffi.con" predictable \
    "call_extern.*calls extern" \
    "predictable rejects FFI/extern calls" \
    "predictable should reject FFI"

# --- Gate 5: blocking rejection ---
check_profile "$TESTDIR/report_check_predictable_fail_blocking.con" predictable \
    "read_something.*may block.*File" \
    "predictable rejects blocking I/O (File)" \
    "predictable should reject blocking"

check_profile "$TESTDIR/report_check_predictable_fail_blocking.con" predictable \
    "main.*may block.*File" \
    "predictable rejects blocking I/O in main (File)" \
    "predictable should reject blocking in main"

# --- Core vs shell: thesis demo ---
check_profile "$TESTDIR/report_check_predictable_core_vs_shell.con" predictable \
    "1 function(s) failed, 3 passed" \
    "predictable core-vs-shell: 3 pass, 1 fail (main)" \
    "predictable core-vs-shell: wrong pass/fail split"

check_profile "$TESTDIR/report_check_predictable_core_vs_shell.con" predictable \
    "main.*may block" \
    "predictable core-vs-shell: main fails for blocking" \
    "predictable core-vs-shell: main should fail"

check_profile "$TESTDIR/report_check_predictable_core_vs_shell.con" predictable \
    "parse_byte" \
    "predictable core-vs-shell: parse_byte not in violations" \
    "predictable core-vs-shell: parse_byte wrongly rejected" "!"

check_profile "$TESTDIR/report_check_predictable_core_vs_shell.con" predictable \
    "validate" \
    "predictable core-vs-shell: validate not in violations" \
    "predictable core-vs-shell: validate wrongly rejected" "!"

# --- Packet decoder: flagship thesis example ---
check_profile_multi "examples/packet/src/main.con" predictable \
    "predictable packet decoder: 16 pass, main fails" \
    "predictable packet decoder: wrong pass/fail split" \
    "1 function(s) failed" "16 passed"

check_profile "examples/packet/src/main.con" predictable \
    "main.*may block" \
    "predictable packet decoder: main fails for blocking" \
    "predictable packet decoder: main should fail"

# === Evidence level tests (--report effects + proved) ===

echo ""
echo "=== Evidence level tests ==="

# parse_byte has a Lean proof → evidence: proved (name + detail on adjacent lines)
check_report "$TESTDIR/report_check_predictable_core_vs_shell.con" effects \
    "evidence: proved" \
    "evidence: parse_byte shows proved (has Lean proof)" \
    "evidence: parse_byte should show proved"

# validate passes profile but has no proof → evidence: enforced
check_report "$TESTDIR/report_check_predictable_core_vs_shell.con" effects \
    "loops: bounded.*evidence: enforced" \
    "evidence: validate shows enforced (passes profile, no proof)" \
    "evidence: validate should show enforced"

# main fails profile (blocking I/O) → evidence: reported
check_report "$TESTDIR/report_check_predictable_core_vs_shell.con" effects \
    "evidence: reported" \
    "evidence: main shows reported (fails profile)" \
    "evidence: main should show reported"

# Summary includes proved count
check_report "$TESTDIR/report_check_predictable_core_vs_shell.con" effects \
    "1 proved" \
    "evidence summary: 1 proved function" \
    "evidence summary: wrong proved count"

# Packet decoder: trusted functions show trusted-assumption
check_report "examples/packet/src/main.con" effects \
    "trusted-assumption" \
    "evidence: packet decoder has trusted-assumption functions" \
    "evidence: packet decoder should have trusted-assumption"

# --- Proof maintenance: rename drops evidence ---
check_report "$TESTDIR/report_evidence_rename_drops.con" effects \
    "read_byte" \
    "evidence maintenance: renamed function exists in report" \
    "evidence maintenance: renamed function missing from report"

check_report "$TESTDIR/report_evidence_rename_drops.con" effects \
    "evidence: proved" \
    "evidence maintenance: renamed function should not be proved" \
    "evidence maintenance: renamed function wrongly proved" "!"

check_report "$TESTDIR/report_evidence_rename_drops.con" effects \
    "0 proved" \
    "evidence maintenance: 0 proved after rename" \
    "evidence maintenance: wrong proved count after rename"

# --- Proof maintenance: stable across refactor ---
check_report "$TESTDIR/report_evidence_stable.con" effects \
    "evidence: proved" \
    "evidence maintenance: parse_byte stays proved with surrounding changes" \
    "evidence maintenance: parse_byte lost proof after refactor"

check_report "$TESTDIR/report_evidence_stable.con" effects \
    "1 proved" \
    "evidence maintenance: exactly 1 proved in refactored file" \
    "evidence maintenance: wrong proved count in refactored file"

# --- check_length: bounds guard with Lean proof ---
check_report "$TESTDIR/report_evidence_check_length.con" effects \
    "evidence: proved" \
    "evidence: check_length shows proved (bounds guard theorem)" \
    "evidence: check_length should show proved"

check_report "$TESTDIR/report_evidence_check_length.con" effects \
    "1 proved, 1 enforced" \
    "evidence: check_length file has 1 proved + 1 enforced" \
    "evidence: check_length file wrong evidence counts"

# --- decode_header: proved parser-core function ---
check_report "$TESTDIR/proof_decode_header.con" effects \
    "3 proved, 1 enforced" \
    "evidence: decode_header file has 3 proved + 1 enforced" \
    "evidence: decode_header file wrong evidence counts"

check_report "$TESTDIR/proof_decode_header.con" effects \
    "evidence: proved" \
    "evidence: decode_header shows proved (parser-core proof)" \
    "evidence: decode_header should show proved"

# --- Proof maintenance: refactored decode_header shows stale proof ---
check_report "$TESTDIR/proof_maintenance_decode_header.con" effects \
    "proof stale: body changed" \
    "proof maintenance: refactored decode_header shows stale warning" \
    "proof maintenance: should show stale warning after refactor"

check_report "$TESTDIR/proof_maintenance_decode_header.con" effects \
    "2 proved, 3 enforced" \
    "proof maintenance: 2 proved (helpers) + 3 enforced after refactor" \
    "proof maintenance: wrong evidence counts after refactor"

# --- Thesis demo: all three pillars ---
check_report "examples/thesis_demo/src/main.con" effects \
    "2 proved, 2 enforced, 0 trusted-assumption, 1 reported" \
    "thesis demo: evidence counts 2/2/0/1" \
    "thesis demo: wrong evidence counts"

check_profile "examples/thesis_demo/src/main.con" predictable \
    "4 passed" \
    "thesis demo: 4 functions pass predictable" \
    "thesis demo: wrong pass count"

check_profile "examples/thesis_demo/src/main.con" predictable \
    "main.*may block" \
    "thesis demo: only main fails (blocking I/O)" \
    "thesis demo: unexpected failure reason"

# === Adversarial tests ===

echo ""
echo "=== Adversarial tests ==="

# --- Proof integrity: wrong semantics detected via body fingerprint ---
check_report "$TESTDIR/adversarial_proof_wrong_semantics.con" effects \
    "evidence: proved" \
    "adversarial: wrong-semantics parse_byte not proved (fingerprint mismatch)" \
    "adversarial: wrong-semantics parse_byte should not be proved" "!"

check_report "$TESTDIR/adversarial_proof_wrong_semantics.con" effects \
    "proof stale: body changed" \
    "adversarial: wrong-semantics parse_byte shows stale proof warning" \
    "adversarial: wrong-semantics should show stale proof warning"

check_report "$TESTDIR/adversarial_proof_wrong_semantics.con" effects \
    "evidence: enforced" \
    "adversarial: wrong-semantics parse_byte drops to enforced" \
    "adversarial: wrong-semantics parse_byte should be enforced"

# --- Proof integrity: impure function cannot be "proved" ---
check_report "$TESTDIR/adversarial_proof_impure.con" effects \
    "evidence: proved" \
    "adversarial: impure parse_byte correctly blocked from proved" \
    "adversarial: impure function wrongly claimed as proved" "!"

check_report "$TESTDIR/adversarial_proof_impure.con" effects \
    "evidence: reported" \
    "adversarial: impure parse_byte shows reported" \
    "adversarial: impure parse_byte should be reported"

# --- Evidence: trusted overrides proof ---
check_report "$TESTDIR/adversarial_evidence_trusted_not_proved.con" effects \
    "evidence: trusted-assumption" \
    "adversarial: trusted parse_byte shows trusted-assumption, not proved" \
    "adversarial: trusted function should not claim proved"

check_report "$TESTDIR/adversarial_evidence_trusted_not_proved.con" effects \
    "evidence: proved" \
    "adversarial: trusted parse_byte not proved" \
    "adversarial: trusted function wrongly shows proved" "!"

# --- Profile: mutual recursion caught ---
check_profile "$TESTDIR/adversarial_profile_mutual_recursion.con" predictable \
    "mutual recursion" \
    "adversarial: mutual recursion detected by profile" \
    "adversarial: mutual recursion not caught"

check_profile "$TESTDIR/adversarial_profile_mutual_recursion.con" predictable \
    "2 function(s) failed" \
    "adversarial: both ping and pong flagged" \
    "adversarial: mutual recursion wrong fail count"

# --- Profile: hidden Alloc capability caught ---
check_profile "$TESTDIR/adversarial_profile_hidden_alloc.con" predictable \
    "has Alloc capability" \
    "adversarial: Alloc capability detected even without intrinsic calls" \
    "adversarial: Alloc capability not caught"

check_profile "$TESTDIR/adversarial_profile_hidden_alloc.con" predictable \
    "3 function(s) failed" \
    "adversarial: all 3 Alloc functions flagged" \
    "adversarial: hidden Alloc wrong fail count"

# --- Profile: all 5 violations in one function ---
check_profile "$TESTDIR/adversarial_all_violations.con" predictable \
    "direct recursion" \
    "adversarial: all-violations recursion detected" \
    "adversarial: all-violations recursion missed"

check_profile "$TESTDIR/adversarial_all_violations.con" predictable \
    "unbounded loop" \
    "adversarial: all-violations unbounded loops detected" \
    "adversarial: all-violations unbounded loops missed"

check_profile "$TESTDIR/adversarial_all_violations.con" predictable \
    "has Alloc capability" \
    "adversarial: all-violations Alloc detected" \
    "adversarial: all-violations Alloc missed"

check_profile "$TESTDIR/adversarial_all_violations.con" predictable \
    "calls extern" \
    "adversarial: all-violations FFI detected" \
    "adversarial: all-violations FFI missed"

check_profile "$TESTDIR/adversarial_all_violations.con" predictable \
    "may block" \
    "adversarial: all-violations blocking detected" \
    "adversarial: all-violations blocking missed"

# --- Capability: escalation rejected at compile time ---
run_err "$TESTDIR/adversarial_cap_escalation.con" "but caller has"

# --- Proof identity: same name in different module must not inherit proof ---
check_report "$TESTDIR/adversarial_proof_cross_module.con" effects \
    "1 proved, 3 enforced" \
    "adversarial: cross-module same-name only 1 proved (qualified identity)" \
    "adversarial: cross-module proof isolation failed"

check_report "$TESTDIR/adversarial_proof_cross_module.con" effects \
    "inner_parse_byte" \
    "adversarial: inner parse_byte present in report" \
    "adversarial: inner parse_byte missing from report"

check_report "$TESTDIR/adversarial_proof_cross_module.con" effects \
    "evidence: proved" \
    "adversarial: outer parse_byte is proved" \
    "adversarial: outer parse_byte should be proved"

# --- Proof identity: wrong arity function not proved ---
check_report "$TESTDIR/adversarial_proof_wrong_arity.con" effects \
    "evidence: proved" \
    "adversarial: wrong-arity parse_byte not proved" \
    "adversarial: wrong-arity parse_byte should not be proved" "!"

check_report "$TESTDIR/adversarial_proof_wrong_arity.con" effects \
    "proof stale: body changed" \
    "adversarial: wrong-arity parse_byte shows stale warning" \
    "adversarial: wrong-arity should show stale warning"

# --- Capability: trusted does not bypass callee capability checking ---
run_err "$TESTDIR/adversarial_trusted_cap_laundering.con" "but caller has"

# --- Loop: unbounded while with comparison but no progress ---
check_report "$TESTDIR/adversarial_loop_disguised.con" effects \
    "loops: unbounded" \
    "adversarial: disguised unbounded loop detected" \
    "adversarial: disguised unbounded loop not caught"

check_report "$TESTDIR/adversarial_loop_disguised.con" effects \
    "evidence: reported" \
    "adversarial: unbounded loop function is reported (not enforced)" \
    "adversarial: unbounded loop function should not be enforced"

check_profile "$TESTDIR/adversarial_loop_disguised.con" predictable \
    "spin.*unbounded" \
    "adversarial: spin rejected by predictable profile" \
    "adversarial: spin should fail predictable profile"

# --- Fn pointer: indirect call does not claim proved ---
check_report "$TESTDIR/adversarial_fn_ptr_indirect.con" effects \
    "evidence: proved" \
    "adversarial: fn pointer apply not proved" \
    "adversarial: fn pointer apply should not be proved" "!"

check_report "$TESTDIR/adversarial_fn_ptr_indirect.con" effects \
    "0 proved, 3 enforced" \
    "adversarial: fn pointer file has 0 proved (no registered proof)" \
    "adversarial: fn pointer file wrong evidence counts"

# --- Linear type system: compiler rejects violations ---
run_err "$TESTDIR/adversarial_linear_double_use.con" "used after move"
run_err "$TESTDIR/adversarial_linear_leak.con" "was never consumed"
run_err "$TESTDIR/adversarial_linear_branch_consume.con" "consumed in one branch"
run_err "$TESTDIR/adversarial_linear_borrow_and_move.con" "frozen by borrow"

# --- Linear type system: correct chain compiles and runs ---
check_report "$TESTDIR/adversarial_linear_correct_chain.con" effects \
    "5 functions" \
    "adversarial: linear correct chain has expected function count" \
    "adversarial: linear correct chain wrong function count"

# --- Capability system: compiler rejects violations ---
run_err "$TESTDIR/adversarial_cap_transitive.con" "but caller has"
run_err "$TESTDIR/adversarial_cap_alloc_without_cap.con" "but caller has"
run_err "$TESTDIR/adversarial_cap_subset.con" "but caller has"
run_err "$TESTDIR/adversarial_cap_pure_no_io.con" "but caller has"

# --- Capability system: correct propagation works ---
check_report "$TESTDIR/adversarial_cap_correct_propagation.con" effects \
    "3 functions" \
    "adversarial: cap correct propagation compiles" \
    "adversarial: cap correct propagation should compile"

# --- Predictable profile: nested bounded loops pass ---
check_profile "$TESTDIR/adversarial_profile_nested_loops.con" predictable \
    "pass" \
    "adversarial: nested bounded loops pass predictable" \
    "adversarial: nested bounded loops should pass"

check_report "$TESTDIR/adversarial_profile_nested_loops.con" effects \
    "loops: bounded" \
    "adversarial: nested loops classified as bounded" \
    "adversarial: nested loops should be bounded"

# --- Predictable profile: bounded vs unbounded in same file ---
check_report "$TESTDIR/adversarial_profile_bounded_then_unbounded.con" effects \
    "loops: unbounded" \
    "adversarial: unbounded while(true) detected" \
    "adversarial: unbounded while(true) not caught"

# --- Predictable profile: deep pure call chain ---
check_report "$TESTDIR/adversarial_profile_deep_call_chain.con" effects \
    "0 reported" \
    "adversarial: deep call chain all enforced (0 reported)" \
    "adversarial: deep call chain should have 0 reported"

# --- Predictable profile: all 4 evidence levels in one file ---
check_report "$TESTDIR/adversarial_profile_mixed_evidence.con" effects \
    "1 proved" \
    "adversarial: mixed evidence has 1 proved" \
    "adversarial: mixed evidence wrong proved count"

check_report "$TESTDIR/adversarial_profile_mixed_evidence.con" effects \
    "1 trusted-assumption" \
    "adversarial: mixed evidence has 1 trusted-assumption" \
    "adversarial: mixed evidence wrong trusted count"

check_report "$TESTDIR/adversarial_profile_mixed_evidence.con" effects \
    "1 reported" \
    "adversarial: mixed evidence has 1 reported" \
    "adversarial: mixed evidence wrong reported count"

# --- Predictable profile: mutual recursion through 2 functions ---
check_profile "$TESTDIR/adversarial_profile_recursive_through_two.con" predictable \
    "alpha.*mutual\|beta.*mutual" \
    "adversarial: mutual recursion A<->B detected" \
    "adversarial: mutual recursion A<->B not caught"

# --- Source locations in reports ---
check_report "$TESTDIR/adversarial_profile_mixed_evidence.con" effects \
    "@ .*adversarial_profile_mixed_evidence.con:" \
    "adversarial: effects report includes source locations" \
    "adversarial: effects report missing source locations"

check_profile "$TESTDIR/adversarial_profile_bounded_then_unbounded.con" predictable \
    "adversarial_profile_bounded_then_unbounded.con:[0-9].*spin" \
    "adversarial: predictable failure includes file:line" \
    "adversarial: predictable failure missing file:line"

check_profile "$TESTDIR/adversarial_profile_bounded_then_unbounded.con" predictable \
    "18 |.*while true" \
    "adversarial: unbounded loop violation shows while source line" \
    "adversarial: unbounded loop violation missing while source line"

check_profile "$TESTDIR/adversarial_profile_bounded_then_unbounded.con" predictable \
    "hint: Use a for loop" \
    "adversarial: predictable failure includes Elm-style hint" \
    "adversarial: predictable failure missing Elm-style hint"

# --- Proof status report ---
# Stale proof detection with fingerprint diff
check_report "$TESTDIR/proof_maintenance_decode_header.con" proof-status \
    "proof stale" \
    "proof-status: stale proof detected" \
    "proof-status: stale proof not detected"

check_report "$TESTDIR/proof_maintenance_decode_header.con" proof-status \
    "expected fingerprint" \
    "proof-status: expected fingerprint shown" \
    "proof-status: expected fingerprint missing"

check_report "$TESTDIR/proof_maintenance_decode_header.con" proof-status \
    "current fingerprint" \
    "proof-status: current fingerprint shown" \
    "proof-status: current fingerprint missing"

# Proved function
check_report "$TESTDIR/adversarial_profile_mixed_evidence.con" proof-status \
    "proof matches current body" \
    "proof-status: proved function shown" \
    "proof-status: proved function missing"

# Trusted function
check_report "$TESTDIR/adversarial_profile_mixed_evidence.con" proof-status \
    "trusted assumption" \
    "proof-status: trusted function shown" \
    "proof-status: trusted function missing"

# Not eligible
check_report "$TESTDIR/adversarial_profile_mixed_evidence.con" proof-status \
    "fails predictable profile" \
    "proof-status: ineligible function shown with reason" \
    "proof-status: ineligible function missing"

# Summary counts
check_report "$TESTDIR/adversarial_profile_mixed_evidence.con" proof-status \
    "1 proved.*0 stale.*2 unproved.*1 ineligible.*1 trusted" \
    "proof-status: summary counts correct" \
    "proof-status: summary counts wrong"

# --- diagnostics-json: machine-readable diagnostic records ---
echo ""
echo "=== Diagnostics JSON tests ==="

# Predictable violation produces JSON with correct kind and fields
json_output=$(cached_output "$TESTDIR/report_check_predictable_fail_loops.con" "--report diagnostics-json")
if echo "$json_output" | grep -q '"kind": "predictable_violation"'; then
    echo "  ok  diagnostics-json: predictable_violation kind present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: predictable_violation kind missing"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

if echo "$json_output" | grep -q '"reason": "unbounded loops"'; then
    echo "  ok  diagnostics-json: unbounded loops reason present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: unbounded loops reason missing"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

if echo "$json_output" | grep -q '"function": "spin"'; then
    echo "  ok  diagnostics-json: spin function name present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: spin function name missing"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

# Source location present in violation
if echo "$json_output" | grep -q '"loc":.*"file":.*"line":'; then
    echo "  ok  diagnostics-json: source location present in violation"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: source location missing in violation"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

# Violation location present (offending construct)
if echo "$json_output" | grep -q '"violation_loc":.*"file":.*"line":'; then
    echo "  ok  diagnostics-json: violation_loc present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: violation_loc missing"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

# Proof-status entries present
if echo "$json_output" | grep -q '"kind": "proof_status"'; then
    echo "  ok  diagnostics-json: proof_status kind present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: proof_status kind missing"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

# Proof-status entry has fingerprint
if echo "$json_output" | grep -q '"current_fingerprint":'; then
    echo "  ok  diagnostics-json: current_fingerprint present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: current_fingerprint missing"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

# Recursion violation produces JSON
json_rec=$(cached_output "$TESTDIR/report_check_predictable_fail_recursion.con" "--report diagnostics-json")
if echo "$json_rec" | grep -q '"reason": "direct recursion"'; then
    echo "  ok  diagnostics-json: direct recursion reason present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: direct recursion reason missing"
    echo "$json_rec"
    FAIL=$((FAIL + 1))
fi

# Passing file produces no predictable violations but has proof-status
json_pass=$(cached_output "$TESTDIR/report_check_predictable_pass.con" "--report diagnostics-json")
if echo "$json_pass" | grep -q '"kind": "proof_status"' && ! echo "$json_pass" | grep -q '"kind": "predictable_violation"'; then
    echo "  ok  diagnostics-json: passing file has proof_status but no violations"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: passing file should have proof_status only"
    echo "$json_pass"
    FAIL=$((FAIL + 1))
fi

# Output is valid JSON array (starts with [ and ends with ])
if echo "$json_output" | grep -q '^\[' && echo "$json_output" | grep -q '\]$'; then
    echo "  ok  diagnostics-json: output is JSON array"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: output should be a JSON array"
    echo "$json_output"
    FAIL=$((FAIL + 1))
fi

# --- Effects facts ---
json_int=$(cached_output "$TESTDIR/report_integration.con" "--report diagnostics-json")

if echo "$json_int" | grep -q '"kind": "effects"'; then
    echo "  ok  diagnostics-json: effects kind present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: effects kind missing"
    FAIL=$((FAIL + 1))
fi

# Effects fact carries key fields
if echo "$json_int" | grep -q '"is_pure":' && echo "$json_int" | grep -q '"evidence":'; then
    echo "  ok  diagnostics-json: effects carries is_pure and evidence"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: effects missing is_pure or evidence"
    FAIL=$((FAIL + 1))
fi

# Pure function has is_pure: true
if echo "$json_int" | grep -q '"function": "pure_add".*"is_pure": true'; then
    echo "  ok  diagnostics-json: pure_add has is_pure true"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: pure_add should have is_pure true"
    FAIL=$((FAIL + 1))
fi

# --- Capability facts ---
if echo "$json_int" | grep -q '"kind": "capability"'; then
    echo "  ok  diagnostics-json: capability kind present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: capability kind missing"
    FAIL=$((FAIL + 1))
fi

# Capability fact has why traces
if echo "$json_int" | grep -q '"why":'; then
    echo "  ok  diagnostics-json: capability facts have why traces"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: capability facts missing why traces"
    FAIL=$((FAIL + 1))
fi

# --- Unsafe facts ---
if echo "$json_int" | grep -q '"kind": "unsafe"'; then
    echo "  ok  diagnostics-json: unsafe kind present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: unsafe kind missing"
    FAIL=$((FAIL + 1))
fi

# Trusted function has trust_boundary
if echo "$json_int" | grep -q '"trust_boundary":'; then
    echo "  ok  diagnostics-json: trust_boundary present for trusted fn"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: trust_boundary missing"
    FAIL=$((FAIL + 1))
fi

# --- Alloc facts ---
if echo "$json_int" | grep -q '"kind": "alloc"'; then
    echo "  ok  diagnostics-json: alloc kind present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: alloc kind missing"
    FAIL=$((FAIL + 1))
fi

# Alloc fact has allocates and frees arrays
if echo "$json_int" | grep -q '"allocates":.*\[' && echo "$json_int" | grep -q '"potential_leak":'; then
    echo "  ok  diagnostics-json: alloc fact carries allocates array and potential_leak"
    PASS=$((PASS + 1))
else
    echo "FAIL  diagnostics-json: alloc fact missing allocates or potential_leak"
    FAIL=$((FAIL + 1))
fi

# =============================================================
# Report-consistency tests: JSON ↔ human reports, intra-JSON
# =============================================================
echo ""
echo "=== Report consistency tests ==="

# Use report_integration.con — it has pure, alloc, trusted, extern, FFI, caps
RC_FILE="$TESTDIR/report_integration.con"
rc_json=$(cached_output "$RC_FILE" "--report diagnostics-json")
rc_caps=$(cached_output "$RC_FILE" "--report caps")
rc_effects=$(cached_output "$RC_FILE" "--report effects")
rc_alloc=$(cached_output "$RC_FILE" "--report alloc")
rc_unsafe=$(cached_output "$RC_FILE" "--report unsafe")

# --- Layer 1: Intra-JSON consistency ---

# 1a. Effects says pure_add is_pure:true → capability fact should have empty capabilities
# (grep the JSON line for pure_add's capability fact and check for empty array)
if echo "$rc_json" | grep -q '"kind": "capability".*"function": "pure_add".*"is_pure": true'; then
    echo "  ok  consistency: capability fact agrees pure_add is pure"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: capability fact should show pure_add as pure"
    FAIL=$((FAIL + 1))
fi

# 1b. Effects says uses_alloc allocates:true → an alloc fact for uses_alloc should exist
if echo "$rc_json" | grep -q '"kind": "effects".*"function": "uses_alloc".*"allocates": true' && \
   echo "$rc_json" | grep -q '"kind": "alloc".*"function": "uses_alloc"'; then
    echo "  ok  consistency: effects allocates:true ↔ alloc fact exists for uses_alloc"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/alloc disagree on uses_alloc allocation"
    FAIL=$((FAIL + 1))
fi

# 1c. Effects says call_raw is_trusted:true → unsafe fact should have is_trusted:true
if echo "$rc_json" | grep -q '"kind": "effects".*"function": "call_raw".*"is_trusted": true' && \
   echo "$rc_json" | grep -q '"kind": "unsafe".*"function": "call_raw".*"is_trusted": true'; then
    echo "  ok  consistency: effects/unsafe agree call_raw is trusted"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/unsafe disagree on call_raw trusted status"
    FAIL=$((FAIL + 1))
fi

# 1d. Effects says call_raw crosses_ffi:true → predictable_violation for call_raw should exist
if echo "$rc_json" | grep -q '"kind": "effects".*"function": "call_raw".*"crosses_ffi": true' && \
   echo "$rc_json" | grep -q '"kind": "predictable_violation".*"function": "call_raw"'; then
    echo "  ok  consistency: effects crosses_ffi ↔ predictable_violation for call_raw"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/predictable disagree on call_raw FFI violation"
    FAIL=$((FAIL + 1))
fi

# 1e. Effects says pure_add evidence:enforced → proof_status should be eligible and waiting for proof
# Note: JSON is one line, so we extract per-record to avoid cross-record grep matches
pure_add_proof_state=$(echo "$rc_json" | grep -o '"kind": "proof_status"[^}]*"function": "main.pure_add"[^}]*' | grep -o '"state": "[^"]*"' | head -1)
if echo "$rc_json" | grep -q '"kind": "effects".*"function": "pure_add".*"evidence": "enforced"' && \
   [ "$pure_add_proof_state" = '"state": "no_proof"' ]; then
    echo "  ok  consistency: effects enforced ↔ proof_status eligible/no_proof for pure_add"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/proof_status disagree on pure_add eligibility (state=$pure_add_proof_state)"
    FAIL=$((FAIL + 1))
fi

# 1f. Effects says call_raw evidence:trusted-assumption → proof_status should be trusted
if echo "$rc_json" | grep -q '"kind": "effects".*"function": "call_raw".*"evidence": "trusted-assumption"' && \
   echo "$rc_json" | grep -q '"kind": "proof_status".*"function": "main.call_raw".*"state": "trusted"'; then
    echo "  ok  consistency: effects trusted-assumption ↔ proof_status trusted for call_raw"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/proof_status disagree on call_raw trusted status"
    FAIL=$((FAIL + 1))
fi

# 1g. alloc_no_free has potential_leak:true (allocates, no free, no defer, returns heap)
if echo "$rc_json" | grep -q '"kind": "alloc".*"function": "alloc_no_free".*"potential_leak": false'; then
    # returns_allocation is true so potential_leak should be false (caller responsible)
    echo "  ok  consistency: alloc_no_free returns allocation, no leak flagged"
    PASS=$((PASS + 1))
else
    # Check the alternative: potential_leak true would also be consistent if returns_allocation false
    if echo "$rc_json" | grep -q '"kind": "alloc".*"function": "alloc_no_free".*"returns_allocation": true'; then
        echo "  ok  consistency: alloc_no_free returns allocation, no leak flagged"
        PASS=$((PASS + 1))
    else
        echo "FAIL  consistency: alloc_no_free should have returns_allocation or potential_leak"
        FAIL=$((FAIL + 1))
    fi
fi

# --- Layer 2: JSON ↔ human report consistency ---

# 2a. Human caps says "pure_add : (pure)" → JSON effects has is_pure:true
if echo "$rc_caps" | grep -q "pure_add : (pure)" && \
   echo "$rc_json" | grep -q '"kind": "effects".*"function": "pure_add".*"is_pure": true'; then
    echo "  ok  consistency: --report caps (pure) ↔ JSON is_pure for pure_add"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: caps/JSON disagree on pure_add purity"
    FAIL=$((FAIL + 1))
fi

# 2b. Human caps says "uses_alloc : Alloc" → JSON capability has Alloc
if echo "$rc_caps" | grep -q "uses_alloc : Alloc" && \
   echo "$rc_json" | grep -q '"kind": "capability".*"function": "uses_alloc".*"Alloc"'; then
    echo "  ok  consistency: --report caps Alloc ↔ JSON capability for uses_alloc"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: caps/JSON disagree on uses_alloc Alloc capability"
    FAIL=$((FAIL + 1))
fi

# 2c. Human effects says "call_raw ... ffi: yes" → JSON effects has crosses_ffi:true
if echo "$rc_effects" | grep -A1 "call_raw" | grep -q "ffi: yes" && \
   echo "$rc_json" | grep -q '"kind": "effects".*"function": "call_raw".*"crosses_ffi": true'; then
    echo "  ok  consistency: --report effects ffi:yes ↔ JSON crosses_ffi for call_raw"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/JSON disagree on call_raw FFI status"
    FAIL=$((FAIL + 1))
fi

# 2d. Human effects says "pure_add ... evidence: enforced" → JSON effects matches
if echo "$rc_effects" | grep -A1 "pure_add" | grep -q "evidence: enforced" && \
   echo "$rc_json" | grep -q '"kind": "effects".*"function": "pure_add".*"evidence": "enforced"'; then
    echo "  ok  consistency: --report effects evidence ↔ JSON evidence for pure_add"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/JSON disagree on pure_add evidence level"
    FAIL=$((FAIL + 1))
fi

# 2e. Human alloc says "fn uses_alloc ... allocates: vec_new" → JSON alloc fact has vec_new
if echo "$rc_alloc" | grep -A1 "fn uses_alloc" | grep -q "allocates: vec_new" && \
   echo "$rc_json" | grep -q '"kind": "alloc".*"function": "uses_alloc".*"vec_new"'; then
    echo "  ok  consistency: --report alloc vec_new ↔ JSON alloc for uses_alloc"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: alloc/JSON disagree on uses_alloc allocation calls"
    FAIL=$((FAIL + 1))
fi

# 2f. Human alloc says "fn alloc_with_defer ... cleanup: defer free" → JSON alloc has defers
if echo "$rc_alloc" | grep -A3 "fn alloc_with_defer" | grep -q "defer free" && \
   echo "$rc_json" | grep -q '"kind": "alloc".*"function": "alloc_with_defer".*"defers":.*\['; then
    echo "  ok  consistency: --report alloc defer ↔ JSON alloc defers for alloc_with_defer"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: alloc/JSON disagree on alloc_with_defer defer"
    FAIL=$((FAIL + 1))
fi

# 2g. Human unsafe says "trusted fn call_raw" → JSON unsafe has is_trusted:true
if echo "$rc_unsafe" | grep -q "trusted fn call_raw" && \
   echo "$rc_json" | grep -q '"kind": "unsafe".*"function": "call_raw".*"is_trusted": true'; then
    echo "  ok  consistency: --report unsafe trusted ↔ JSON unsafe for call_raw"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: unsafe/JSON disagree on call_raw trusted status"
    FAIL=$((FAIL + 1))
fi

# 2h. Human unsafe says "wraps: extern raw_extern" → JSON unsafe has trust_boundary with raw_extern
if echo "$rc_unsafe" | grep -q "wraps: extern raw_extern" && \
   echo "$rc_json" | grep -q '"kind": "unsafe".*"function": "call_raw".*"trust_boundary":.*"extern raw_extern"'; then
    echo "  ok  consistency: --report unsafe wraps ↔ JSON trust_boundary for call_raw"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: unsafe/JSON disagree on call_raw trust_boundary"
    FAIL=$((FAIL + 1))
fi

# 2i. Human effects says "2 pure" in totals → JSON has exactly 2 effects facts with is_pure:true
pure_count=$(echo "$rc_json" | grep -o '"kind": "effects"[^}]*"is_pure": true' | wc -l | tr -d ' ')
if echo "$rc_effects" | grep -q "2 pure" && [ "$pure_count" = "2" ]; then
    echo "  ok  consistency: --report effects 2 pure ↔ JSON has 2 pure effects facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: effects/JSON disagree on pure function count (human=2, json=$pure_count)"
    FAIL=$((FAIL + 1))
fi

# 2j. Human alloc says "3 functions allocate" → JSON has exactly 3 alloc facts
alloc_count=$(echo "$rc_json" | grep -o '"kind": "alloc"' | wc -l | tr -d ' ')
if echo "$rc_alloc" | grep -q "3 functions allocate" && [ "$alloc_count" = "3" ]; then
    echo "  ok  consistency: --report alloc 3 allocating ↔ JSON has 3 alloc facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: alloc/JSON disagree on allocating function count (human=3, json=$alloc_count)"
    FAIL=$((FAIL + 1))
fi

# --- Layer 2 continued: recursion file ---
# Human --check predictable fails with "direct recursion" → JSON has matching violation
rc_rec_json=$(cached_output "$TESTDIR/report_check_predictable_fail_recursion.con" "--report diagnostics-json")
rc_rec_human=$($COMPILER "$TESTDIR/report_check_predictable_fail_recursion.con" --check predictable 2>&1) || true
if echo "$rc_rec_human" | grep -q "direct recursion" && \
   echo "$rc_rec_json" | grep -q '"kind": "predictable_violation".*"reason": "direct recursion"'; then
    echo "  ok  consistency: --check predictable recursion ↔ JSON violation for countdown"
    PASS=$((PASS + 1))
else
    echo "FAIL  consistency: predictable/JSON disagree on recursion violation"
    FAIL=$((FAIL + 1))
fi

# =============================================================
# Fact query CLI tests (--query)
# =============================================================
echo ""
echo "=== Fact query CLI tests ==="

# --query effects returns only effects facts
q_effects=$(cached_output "$TESTDIR/report_integration.con" "--query effects")
if echo "$q_effects" | grep -q '"kind": "effects"' && \
   ! echo "$q_effects" | grep -q '"kind": "alloc"' && \
   ! echo "$q_effects" | grep -q '"kind": "capability"'; then
    echo "  ok  --query effects: returns only effects kind"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query effects: should return only effects kind"
    FAIL=$((FAIL + 1))
fi

# --query effects:pure_add returns exactly one fact
q_pure=$(cached_output "$TESTDIR/report_integration.con" "--query effects:pure_add")
if echo "$q_pure" | grep -q '"function": "pure_add"' && \
   echo "$q_pure" | grep -q '"is_pure": true'; then
    echo "  ok  --query effects:pure_add returns pure_add effects fact"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query effects:pure_add should return pure_add with is_pure"
    FAIL=$((FAIL + 1))
fi

# --query fn:call_raw returns facts from multiple kinds
q_fn=$(cached_output "$TESTDIR/report_integration.con" "--query fn:call_raw")
if echo "$q_fn" | grep -q '"kind": "effects"' && \
   echo "$q_fn" | grep -q '"kind": "unsafe"' && \
   echo "$q_fn" | grep -q '"kind": "capability"'; then
    echo "  ok  --query fn:call_raw returns effects + unsafe + capability facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query fn:call_raw should return multiple fact kinds"
    FAIL=$((FAIL + 1))
fi

# --query alloc returns only alloc facts
q_alloc=$(cached_output "$TESTDIR/report_integration.con" "--query alloc")
if echo "$q_alloc" | grep -q '"kind": "alloc"' && \
   ! echo "$q_alloc" | grep -q '"kind": "effects"'; then
    echo "  ok  --query alloc: returns only alloc kind"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query alloc: should return only alloc kind"
    FAIL=$((FAIL + 1))
fi

# --query unsafe returns only unsafe facts
q_unsafe=$(cached_output "$TESTDIR/report_integration.con" "--query unsafe")
if echo "$q_unsafe" | grep -q '"kind": "unsafe"' && \
   ! echo "$q_unsafe" | grep -q '"kind": "effects"'; then
    echo "  ok  --query unsafe: returns only unsafe kind"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query unsafe: should return only unsafe kind"
    FAIL=$((FAIL + 1))
fi

# --query capability returns only capability facts
q_cap=$(cached_output "$TESTDIR/report_integration.con" "--query capability")
if echo "$q_cap" | grep -q '"kind": "capability"' && \
   ! echo "$q_cap" | grep -q '"kind": "effects"'; then
    echo "  ok  --query capability: returns only capability kind"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query capability: should return only capability kind"
    FAIL=$((FAIL + 1))
fi

# --query proof_status returns only proof_status facts
q_proof=$(cached_output "$TESTDIR/report_integration.con" "--query proof_status")
if echo "$q_proof" | grep -q '"kind": "proof_status"' && \
   ! echo "$q_proof" | grep -q '"kind": "effects"'; then
    echo "  ok  --query proof_status: returns only proof_status kind"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query proof_status: should return only proof_status kind"
    FAIL=$((FAIL + 1))
fi

# --query predictable_violation on file with violations
q_viol=$(cached_output "$TESTDIR/report_check_predictable_fail_loops.con" "--query predictable_violation")
if echo "$q_viol" | grep -q '"function": "spin"' && \
   echo "$q_viol" | grep -q '"reason": "unbounded loops"'; then
    echo "  ok  --query predictable_violation: returns spin violation"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query predictable_violation: should return spin violation"
    FAIL=$((FAIL + 1))
fi

# --query predictable_violation on passing file returns empty array
q_noviol=$(cached_output "$TESTDIR/report_check_predictable_pass.con" "--query predictable_violation")
if [ "$q_noviol" = "[]" ]; then
    echo "  ok  --query predictable_violation: empty for passing file"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query predictable_violation: should be empty for passing file"
    FAIL=$((FAIL + 1))
fi

# --query fn:pure_add returns proof_status (qualified name match)
q_fn_pure=$(cached_output "$TESTDIR/report_integration.con" "--query fn:pure_add")
if echo "$q_fn_pure" | grep -q '"kind": "proof_status"' && \
   echo "$q_fn_pure" | grep -q '"kind": "effects"'; then
    echo "  ok  --query fn:pure_add returns proof_status + effects (qualified name match)"
    PASS=$((PASS + 1))
else
    echo "FAIL  --query fn:pure_add should match qualified names like main.pure_add"
    FAIL=$((FAIL + 1))
fi

# =============================================================
# Authority trace query tests (--query why-capability)
# =============================================================
echo ""
echo "=== Authority trace query tests ==="

# Transitive: main requires Alloc via uses_alloc → vec_new (intrinsic)
q_alloc=$(cached_output "$TESTDIR/report_integration.con" "--query why-capability:main:Alloc")
if echo "$q_alloc" | grep -q '"answer": "transitive"' && \
   echo "$q_alloc" | grep -q '"callee": "uses_alloc"' && \
   echo "$q_alloc" | grep -q '"origin": "intrinsic"'; then
    echo "  ok  why-capability:main:Alloc traces main → uses_alloc → intrinsic"
    PASS=$((PASS + 1))
else
    echo "FAIL  why-capability:main:Alloc should trace transitive path"
    echo "$q_alloc"
    FAIL=$((FAIL + 1))
fi

# Declared: main declares File via with(Std)
q_file=$(cached_output "$TESTDIR/report_integration.con" "--query why-capability:main:File")
if echo "$q_file" | grep -q '"answer": "declared"' && \
   echo "$q_file" | grep -q '"origin": "declared"'; then
    echo "  ok  why-capability:main:File shows declared origin"
    PASS=$((PASS + 1))
else
    echo "FAIL  why-capability:main:File should show declared"
    echo "$q_file"
    FAIL=$((FAIL + 1))
fi

# Transitive via extern: call_raw requires Unsafe via raw_extern (extern)
q_unsafe=$(cached_output "$TESTDIR/report_integration.con" "--query why-capability:call_raw:Unsafe")
if echo "$q_unsafe" | grep -q '"answer": "transitive"' && \
   echo "$q_unsafe" | grep -q '"callee": "raw_extern"' && \
   echo "$q_unsafe" | grep -q '"origin": "extern"'; then
    echo "  ok  why-capability:call_raw:Unsafe traces call_raw → raw_extern (extern)"
    PASS=$((PASS + 1))
else
    echo "FAIL  why-capability:call_raw:Unsafe should trace to extern"
    echo "$q_unsafe"
    FAIL=$((FAIL + 1))
fi

# Not required: pure_add does not require Alloc
q_none=$(cached_output "$TESTDIR/report_integration.con" "--query why-capability:pure_add:Alloc")
if echo "$q_none" | grep -q '"answer": "not_required"' && \
   echo "$q_none" | grep -q '"trace": \[\]'; then
    echo "  ok  why-capability:pure_add:Alloc returns not_required"
    PASS=$((PASS + 1))
else
    echo "FAIL  why-capability:pure_add:Alloc should be not_required"
    echo "$q_none"
    FAIL=$((FAIL + 1))
fi

# Answer-shaped output has query_answer kind
if echo "$q_alloc" | grep -q '"kind": "query_answer"'; then
    echo "  ok  why-capability output has kind query_answer"
    PASS=$((PASS + 1))
else
    echo "FAIL  why-capability output should have kind query_answer"
    FAIL=$((FAIL + 1))
fi

# Declared origin includes source location
if echo "$q_file" | grep -q '"loc":.*"file":.*"line":'; then
    echo "  ok  why-capability declared origin includes source location"
    PASS=$((PASS + 1))
else
    echo "FAIL  why-capability declared origin should include source location"
    FAIL=$((FAIL + 1))
fi

# --- Adversarial authority trace tests ---
AT_FILE="$TESTDIR/adversarial_authority_trace.con"

# Mutual recursion: ping→pong cycle detected, not infinite loop
q_cycle=$(cached_output "$AT_FILE" "--query why-capability:ping:Alloc")
if echo "$q_cycle" | grep -q '"answer": "transitive"' && \
   echo "$q_cycle" | grep -q '"error": "cycle"' && \
   echo "$q_cycle" | grep -q '"origin": "intrinsic"'; then
    echo "  ok  adversarial: mutual recursion cycle detected in authority trace"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: mutual recursion should detect cycle"
    echo "$q_cycle"
    FAIL=$((FAIL + 1))
fi

# Diamond: both left_arm and right_arm traced
q_diamond=$(cached_output "$AT_FILE" "--query why-capability:diamond:Alloc")
if echo "$q_diamond" | grep -q '"callee": "left_arm"' && \
   echo "$q_diamond" | grep -q '"callee": "right_arm"'; then
    echo "  ok  adversarial: diamond dependency traces both arms"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: diamond should trace both arms"
    echo "$q_diamond"
    FAIL=$((FAIL + 1))
fi

# Deep chain: entry → mid1 → mid2 → leaf → alloc (intrinsic)
q_deep=$(cached_output "$AT_FILE" "--query why-capability:entry:Alloc")
if echo "$q_deep" | grep -q '"callee": "mid1"' && \
   echo "$q_deep" | grep -q '"callee": "mid2"' && \
   echo "$q_deep" | grep -q '"callee": "leaf"' && \
   echo "$q_deep" | grep -q '"origin": "intrinsic"'; then
    echo "  ok  adversarial: deep chain traces entry → mid1 → mid2 → leaf → intrinsic"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: deep chain should trace full path"
    echo "$q_deep"
    FAIL=$((FAIL + 1))
fi

# Trusted extern: uses_trusted should NOT require Unsafe
q_trusted=$(cached_output "$AT_FILE" "--query why-capability:uses_trusted:Unsafe")
if echo "$q_trusted" | grep -q '"answer": "not_required"'; then
    echo "  ok  adversarial: trusted extern does not contribute Unsafe"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: trusted extern should not contribute Unsafe"
    echo "$q_trusted"
    FAIL=$((FAIL + 1))
fi

# Untrusted extern: uses_raw traces to extern origin
q_raw=$(cached_output "$AT_FILE" "--query why-capability:uses_raw:Unsafe")
if echo "$q_raw" | grep -q '"answer": "transitive"' && \
   echo "$q_raw" | grep -q '"callee": "raw_op"' && \
   echo "$q_raw" | grep -q '"origin": "extern"'; then
    echo "  ok  adversarial: untrusted extern traces to extern origin"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: untrusted extern should trace to extern origin"
    echo "$q_raw"
    FAIL=$((FAIL + 1))
fi

# Nonexistent function returns not_required
q_missing=$(cached_output "$AT_FILE" "--query why-capability:nonexistent:Alloc")
if echo "$q_missing" | grep -q '"answer": "not_required"'; then
    echo "  ok  adversarial: nonexistent function returns not_required"
    PASS=$((PASS + 1))
else
    echo "FAIL  adversarial: nonexistent function should return not_required"
    echo "$q_missing"
    FAIL=$((FAIL + 1))
fi

# =============================================================
# Semantic query tests: predictable, proof, evidence
# =============================================================
echo ""
echo "=== Semantic query tests ==="

# --- predictable:fn ---

# Passing function
q_pred_pass=$(cached_output "$TESTDIR/report_integration.con" "--query predictable:pure_add")
if echo "$q_pred_pass" | grep -q '"answer": "pass"' && \
   echo "$q_pred_pass" | grep -q '"gates_failed": 0'; then
    echo "  ok  predictable:pure_add answers pass with 0 gates failed"
    PASS=$((PASS + 1))
else
    echo "FAIL  predictable:pure_add should answer pass"
    echo "$q_pred_pass"
    FAIL=$((FAIL + 1))
fi

# Failing function with multiple violations
q_pred_fail=$(cached_output "$TESTDIR/report_integration.con" "--query predictable:main")
if echo "$q_pred_fail" | grep -q '"answer": "fail"' && \
   echo "$q_pred_fail" | grep -q '"gate":'; then
    echo "  ok  predictable:main answers fail with violation gates"
    PASS=$((PASS + 1))
else
    echo "FAIL  predictable:main should answer fail"
    echo "$q_pred_fail"
    FAIL=$((FAIL + 1))
fi

# Violation includes hint
if echo "$q_pred_fail" | grep -q '"hint":'; then
    echo "  ok  predictable:main violations include hints"
    PASS=$((PASS + 1))
else
    echo "FAIL  predictable:main violations should include hints"
    FAIL=$((FAIL + 1))
fi

# Unbounded loop violation
q_pred_loop=$(cached_output "$TESTDIR/report_check_predictable_fail_loops.con" "--query predictable:spin")
if echo "$q_pred_loop" | grep -q '"answer": "fail"' && \
   echo "$q_pred_loop" | grep -q '"gate": "unbounded loops"'; then
    echo "  ok  predictable:spin answers fail with unbounded loops gate"
    PASS=$((PASS + 1))
else
    echo "FAIL  predictable:spin should fail with unbounded loops"
    echo "$q_pred_loop"
    FAIL=$((FAIL + 1))
fi

# --- proof:fn ---

# Pure function: no_proof (eligible but unproved)
q_proof_pure=$(cached_output "$TESTDIR/report_integration.con" "--query proof:pure_add")
if echo "$q_proof_pure" | grep -q '"answer": "no_proof"' && \
   echo "$q_proof_pure" | grep -q '"current_fingerprint":'; then
    echo "  ok  proof:pure_add answers no_proof with fingerprint"
    PASS=$((PASS + 1))
else
    echo "FAIL  proof:pure_add should answer no_proof"
    echo "$q_proof_pure"
    FAIL=$((FAIL + 1))
fi

# Trusted function: trusted
q_proof_trusted=$(cached_output "$TESTDIR/report_integration.con" "--query proof:call_raw")
if echo "$q_proof_trusted" | grep -q '"answer": "trusted"'; then
    echo "  ok  proof:call_raw answers trusted"
    PASS=$((PASS + 1))
else
    echo "FAIL  proof:call_raw should answer trusted"
    echo "$q_proof_trusted"
    FAIL=$((FAIL + 1))
fi

# Nonexistent function
q_proof_missing=$(cached_output "$TESTDIR/report_integration.con" "--query proof:nonexistent")
if echo "$q_proof_missing" | grep -q '"answer": "not_found"'; then
    echo "  ok  proof:nonexistent answers not_found"
    PASS=$((PASS + 1))
else
    echo "FAIL  proof:nonexistent should answer not_found"
    echo "$q_proof_missing"
    FAIL=$((FAIL + 1))
fi

# --- evidence:fn ---

# Pure function: enforced (passes predictable, no proof yet)
q_ev_pure=$(cached_output "$TESTDIR/report_integration.con" "--query evidence:pure_add")
if echo "$q_ev_pure" | grep -q '"answer": "enforced"' && \
   echo "$q_ev_pure" | grep -q '"passes_predictable": true' && \
   echo "$q_ev_pure" | grep -q '"proof_state": "no_proof"'; then
    echo "  ok  evidence:pure_add answers enforced, passes predictable, no proof"
    PASS=$((PASS + 1))
else
    echo "FAIL  evidence:pure_add should be enforced"
    echo "$q_ev_pure"
    FAIL=$((FAIL + 1))
fi

# Trusted function: trusted-assumption
q_ev_trusted=$(cached_output "$TESTDIR/report_integration.con" "--query evidence:call_raw")
if echo "$q_ev_trusted" | grep -q '"answer": "trusted-assumption"' && \
   echo "$q_ev_trusted" | grep -q '"is_trusted": true'; then
    echo "  ok  evidence:call_raw answers trusted-assumption"
    PASS=$((PASS + 1))
else
    echo "FAIL  evidence:call_raw should be trusted-assumption"
    echo "$q_ev_trusted"
    FAIL=$((FAIL + 1))
fi

# Failing function: reported (fails predictable)
q_ev_fail=$(cached_output "$TESTDIR/report_integration.con" "--query evidence:main")
if echo "$q_ev_fail" | grep -q '"answer": "reported"' && \
   echo "$q_ev_fail" | grep -q '"passes_predictable": false'; then
    echo "  ok  evidence:main answers reported, fails predictable"
    PASS=$((PASS + 1))
else
    echo "FAIL  evidence:main should be reported"
    echo "$q_ev_fail"
    FAIL=$((FAIL + 1))
fi

# Not found
q_ev_missing=$(cached_output "$TESTDIR/report_integration.con" "--query evidence:nonexistent")
if echo "$q_ev_missing" | grep -q '"answer": "not_found"'; then
    echo "  ok  evidence:nonexistent answers not_found"
    PASS=$((PASS + 1))
else
    echo "FAIL  evidence:nonexistent should answer not_found"
    echo "$q_ev_missing"
    FAIL=$((FAIL + 1))
fi

# --- audit:fn ---
echo ""
echo "=== Audit query tests ==="

# Pure function audit: enforced, pure, passes predictable, no alloc
q_audit_pure=$(cached_output "$TESTDIR/report_integration.con" "--query audit:pure_add")
if echo "$q_audit_pure" | grep -q '"evidence": "enforced"' && \
   echo "$q_audit_pure" | grep -q '"is_pure": true' && \
   echo "$q_audit_pure" | grep -q '"passes": true'; then
    echo "  ok  audit:pure_add shows enforced, pure, passes predictable"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:pure_add should show enforced + pure + passes"
    echo "$q_audit_pure"
    FAIL=$((FAIL + 1))
fi

# Trusted function audit: trusted-assumption, has authority traces, fails predictable
q_audit_trusted=$(cached_output "$TESTDIR/report_integration.con" "--query audit:call_raw")
if echo "$q_audit_trusted" | grep -q '"evidence": "trusted-assumption"' && \
   echo "$q_audit_trusted" | grep -q '"is_trusted": true' && \
   echo "$q_audit_trusted" | grep -q '"passes": false'; then
    echo "  ok  audit:call_raw shows trusted-assumption, trusted, fails predictable"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:call_raw should show trusted-assumption"
    echo "$q_audit_trusted"
    FAIL=$((FAIL + 1))
fi

# Audit includes authority traces
if echo "$q_audit_trusted" | grep -q '"traces":' && \
   echo "$q_audit_trusted" | grep -q '"origin": "extern"'; then
    echo "  ok  audit:call_raw includes authority trace to extern"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:call_raw should include authority traces"
    FAIL=$((FAIL + 1))
fi

# Audit includes proof state and fingerprint
if echo "$q_audit_pure" | grep -q '"state": "no_proof"' && \
   echo "$q_audit_pure" | grep -q '"fingerprint":'; then
    echo "  ok  audit:pure_add includes proof state and fingerprint"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:pure_add should include proof state"
    FAIL=$((FAIL + 1))
fi

# Audit includes allocation info
if echo "$q_audit_pure" | grep -q '"allocates": \[\]' && \
   echo "$q_audit_pure" | grep -q '"returns_allocation": false'; then
    echo "  ok  audit:pure_add includes empty allocation info"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:pure_add should include allocation info"
    FAIL=$((FAIL + 1))
fi

# Allocating function audit
q_audit_alloc=$(cached_output "$TESTDIR/report_integration.con" "--query audit:uses_alloc")
if echo "$q_audit_alloc" | grep -q '"evidence": "reported"' && \
   echo "$q_audit_alloc" | grep -q '"allocates":.*"vec_new"'; then
    echo "  ok  audit:uses_alloc shows reported with vec_new allocation"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:uses_alloc should show reported + vec_new"
    echo "$q_audit_alloc"
    FAIL=$((FAIL + 1))
fi

# Not found
q_audit_missing=$(cached_output "$TESTDIR/report_integration.con" "--query audit:nonexistent")
if echo "$q_audit_missing" | grep -q '"answer": "not_found"'; then
    echo "  ok  audit:nonexistent answers not_found"
    PASS=$((PASS + 1))
else
    echo "FAIL  audit:nonexistent should answer not_found"
    echo "$q_audit_missing"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Proof registry artifact tests ==="

REGISTRY_DIR="$TESTDIR/proof_registry_test"
STALE_DIR="$TESTDIR/proof_registry_stale"
MISS_DIR="$TESTDIR/proof_registry_miss"

# Registry-backed proof: correct fingerprint → proved
reg_proof=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report proof-status")
if echo "$reg_proof" | grep -q "1 proved" && \
   echo "$reg_proof" | grep -q "pure_add.*proof matches"; then
    echo "  ok  registry proof: correct fingerprint → proved"
    PASS=$((PASS + 1))
else
    echo "FAIL  registry proof: correct fingerprint should show proved"
    echo "$reg_proof"
    FAIL=$((FAIL + 1))
fi

# Registry query: proof:pure_add → proved
reg_query=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query proof:pure_add")
if echo "$reg_query" | grep -q '"answer": "proved"'; then
    echo "  ok  registry query: proof:pure_add → proved"
    PASS=$((PASS + 1))
else
    echo "FAIL  registry query: proof:pure_add should answer proved"
    echo "$reg_query"
    FAIL=$((FAIL + 1))
fi

# Stale registry: wrong fingerprint → stale
stale_proof=$(cached_output "$STALE_DIR/test_proof_registry.con" "--report proof-status")
if echo "$stale_proof" | grep -q "1 stale" && \
   echo "$stale_proof" | grep -q "body changed"; then
    echo "  ok  registry stale: wrong fingerprint → stale"
    PASS=$((PASS + 1))
else
    echo "FAIL  registry stale: wrong fingerprint should show stale"
    echo "$stale_proof"
    FAIL=$((FAIL + 1))
fi

# Stale registry query: proof:pure_add → stale
stale_query=$(cached_output "$STALE_DIR/test_proof_registry.con" "--query proof:pure_add")
if echo "$stale_query" | grep -q '"answer": "stale"'; then
    echo "  ok  registry stale query: proof:pure_add → stale"
    PASS=$((PASS + 1))
else
    echo "FAIL  registry stale query: proof:pure_add should answer stale"
    echo "$stale_query"
    FAIL=$((FAIL + 1))
fi

# Miss registry: wrong function name → not proved
miss_proof=$(cached_output "$MISS_DIR/test_proof_registry.con" "--report proof-status")
if echo "$miss_proof" | grep -q "0 proved" && \
   echo "$miss_proof" | grep -q "0 stale"; then
    echo "  ok  registry miss: wrong function name → no proof"
    PASS=$((PASS + 1))
else
    echo "FAIL  registry miss: wrong function name should show 0 proved, 0 stale"
    echo "$miss_proof"
    FAIL=$((FAIL + 1))
fi

# Miss registry query: proof:pure_add → no_proof (not stale, because name doesn't match)
miss_query=$(cached_output "$MISS_DIR/test_proof_registry.con" "--query proof:pure_add")
if echo "$miss_query" | grep -q '"answer": "no_proof"'; then
    echo "  ok  registry miss query: proof:pure_add → no_proof"
    PASS=$((PASS + 1))
else
    echo "FAIL  registry miss query: proof:pure_add should answer no_proof"
    echo "$miss_query"
    FAIL=$((FAIL + 1))
fi

# Hardcoded proof still works (backward compatibility)
hardcoded_proof=$(cached_output "$TESTDIR/proof_decode_header.con" "--report proof-status")
if echo "$hardcoded_proof" | grep -q "proved"; then
    echo "  ok  hardcoded proof still works during registry transition"
    PASS=$((PASS + 1))
else
    echo "FAIL  hardcoded proof should still work"
    echo "$hardcoded_proof"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Proof obligations report tests ==="

# Obligations from registry: proved function shows spec, proof, source
ob_proved=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report obligations")
if echo "$ob_proved" | grep -q "status:.*proved" && \
   echo "$ob_proved" | grep -q "spec:.*PureAdd.spec_add" && \
   echo "$ob_proved" | grep -q "proof:.*PureAdd.add_comm" && \
   echo "$ob_proved" | grep -q "source:.*registry"; then
    echo "  ok  obligations: proved function shows spec, proof, registry source"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: proved function should show spec/proof/registry"
    echo "$ob_proved"
    FAIL=$((FAIL + 1))
fi

# Obligations: missing_proof shows none for spec/proof
if echo "$ob_proved" | grep -A5 "main.main" | grep -q "status:.*missing_proof" && \
   echo "$ob_proved" | grep -A5 "main.main" | grep -q "source:.*none"; then
    echo "  ok  obligations: missing_proof function shows source:none"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: missing_proof should show source:none"
    echo "$ob_proved"
    FAIL=$((FAIL + 1))
fi

# Obligations: dependencies show proved callees
if echo "$ob_proved" | grep -A7 "main.main" | grep -q "dependencies:.*pure_add"; then
    echo "  ok  obligations: main depends on proved helper pure_add"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: main should depend on proved pure_add"
    echo "$ob_proved"
    FAIL=$((FAIL + 1))
fi

# Obligations: stale fingerprint
ob_stale=$(cached_output "$STALE_DIR/test_proof_registry.con" "--report obligations")
if echo "$ob_stale" | grep -q "status:.*stale" && \
   echo "$ob_stale" | grep -q "1 stale"; then
    echo "  ok  obligations: stale fingerprint → stale status"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: stale fingerprint should show stale"
    echo "$ob_stale"
    FAIL=$((FAIL + 1))
fi

# Obligations: summary totals
if echo "$ob_proved" | grep -q "1 proved" && \
   echo "$ob_proved" | grep -q "1 missing"; then
    echo "  ok  obligations: summary shows 1 proved, 1 missing"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: summary should show 1 proved, 1 missing"
    echo "$ob_proved"
    FAIL=$((FAIL + 1))
fi

# Obligations JSON: query returns obligation facts
ob_json=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query obligation")
if echo "$ob_json" | grep -q '"kind": "obligation"' && \
   echo "$ob_json" | grep -q '"status": "proved"' && \
   echo "$ob_json" | grep -q '"spec": "PureAdd.spec_add"'; then
    echo "  ok  obligations JSON: --query obligation returns obligation facts with spec"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations JSON: --query obligation should return facts"
    echo "$ob_json"
    FAIL=$((FAIL + 1))
fi

# Obligations JSON: per-function filter
ob_fn=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query obligation:pure_add")
if echo "$ob_fn" | grep -q '"function": "main.pure_add"' && \
   echo "$ob_fn" | grep -q '"source": "registry"'; then
    echo "  ok  obligations JSON: --query obligation:pure_add returns filtered fact"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations JSON: --query obligation:pure_add should filter"
    echo "$ob_fn"
    FAIL=$((FAIL + 1))
fi

# Obligations: not_eligible for allocating functions
ob_mixed=$(cached_output "$TESTDIR/report_integration.con" "--report obligations")
if echo "$ob_mixed" | grep -q "not_eligible" && \
   echo "$ob_mixed" | grep -q "trusted"; then
    echo "  ok  obligations: mixed program shows not_eligible + trusted"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: mixed program should show not_eligible + trusted"
    echo "$ob_mixed"
    FAIL=$((FAIL + 1))
fi

# Obligations: diagnostics-json includes obligation kind
ob_diag=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report diagnostics-json")
if echo "$ob_diag" | grep -q '"kind": "obligation"'; then
    echo "  ok  obligations: diagnostics-json includes obligation facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  obligations: diagnostics-json should include obligation facts"
    echo "$ob_diag"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Source-to-ProofCore extraction tests ==="

# Pure function: extracted with ProofCore form
ext_pure=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report extraction")
if echo "$ext_pure" | grep -q "status: extracted" && \
   echo "$ext_pure" | grep -q "ProofCore: (a + b)"; then
    echo "  ok  extraction: pure_add extracted to (a + b)"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: pure_add should be extracted"
    echo "$ext_pure"
    FAIL=$((FAIL + 1))
fi

# Entry point: excluded with reason
if echo "$ext_pure" | grep -A3 "main.main" | grep -q "excluded" && \
   echo "$ext_pure" | grep -A3 "main.main" | grep -q "entry point"; then
    echo "  ok  extraction: main excluded as entry point"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: main should be excluded"
    echo "$ext_pure"
    FAIL=$((FAIL + 1))
fi

# Mixed program: capabilities excluded with reasons
ext_mixed=$(cached_output "$TESTDIR/report_integration.con" "--report extraction")
if echo "$ext_mixed" | grep -A3 "uses_alloc" | grep -q "has capabilities: Alloc"; then
    echo "  ok  extraction: uses_alloc excluded for Alloc capability"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: uses_alloc should be excluded for Alloc"
    echo "$ext_mixed"
    FAIL=$((FAIL + 1))
fi

# Trusted function: excluded with trusted reason
if echo "$ext_mixed" | grep -A3 "call_raw" | grep -q "marked trusted"; then
    echo "  ok  extraction: call_raw excluded as trusted"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: call_raw should be excluded as trusted"
    echo "$ext_mixed"
    FAIL=$((FAIL + 1))
fi

# Eligible but not extractable: struct literal, match
ext_elig=$(cached_output "$TESTDIR/test_proof_eligible_pure.con" "--report extraction")
if echo "$ext_elig" | grep -A3 "make_point" | grep -q "extraction failed" && \
   echo "$ext_elig" | grep -A3 "make_point" | grep -q "struct literal"; then
    echo "  ok  extraction: make_point eligible but blocked by struct literal"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: make_point should fail on struct literal"
    echo "$ext_elig"
    FAIL=$((FAIL + 1))
fi

if echo "$ext_elig" | grep -A3 "color_value" | grep -q "match expression"; then
    echo "  ok  extraction: color_value eligible but blocked by match expression"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: color_value should fail on match expression"
    echo "$ext_elig"
    FAIL=$((FAIL + 1))
fi

# Summary totals
if echo "$ext_pure" | grep -q "1 extracted" && \
   echo "$ext_pure" | grep -q "1 excluded"; then
    echo "  ok  extraction: summary shows correct totals"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: summary should show 1 extracted, 1 excluded"
    echo "$ext_pure"
    FAIL=$((FAIL + 1))
fi

# JSON query: extraction facts with proof_core
ext_json=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query extraction:pure_add")
if echo "$ext_json" | grep -q '"status": "extracted"' && \
   echo "$ext_json" | grep -q '"proof_core": "(a + b)"'; then
    echo "  ok  extraction JSON: --query extraction:pure_add returns proof_core"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction JSON: --query extraction:pure_add should have proof_core"
    echo "$ext_json"
    FAIL=$((FAIL + 1))
fi

# Diagnostics-json includes extraction kind
if echo "$ob_diag" | grep -q '"kind": "extraction"'; then
    echo "  ok  extraction: diagnostics-json includes extraction facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction: diagnostics-json should include extraction facts"
    FAIL=$((FAIL + 1))
fi

# Excluded function JSON shows excluded_reasons
ext_excl=$(cached_output "$TESTDIR/report_integration.con" "--query extraction:call_raw")
if echo "$ext_excl" | grep -q '"status": "excluded"' && \
   echo "$ext_excl" | grep -q '"excluded_reasons"'; then
    echo "  ok  extraction JSON: excluded function shows excluded_reasons"
    PASS=$((PASS + 1))
else
    echo "FAIL  extraction JSON: excluded function should show excluded_reasons"
    echo "$ext_excl"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Source/Core/SSA/LLVM traceability tests ==="

# Proved function: full pipeline trace
tr_proved=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report traceability")
if echo "$tr_proved" | grep -A10 "main.pure_add" | grep -q "evidence:.*proved" && \
   echo "$tr_proved" | grep -A10 "main.pure_add" | grep -q "extraction:.*extracted" && \
   echo "$tr_proved" | grep -A10 "main.pure_add" | grep -q "ssa:.*pure_add" && \
   echo "$tr_proved" | grep -A10 "main.pure_add" | grep -q "llvm:.*pure_add"; then
    echo "  ok  traceability: proved function traces through all pipeline stages"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: proved function should trace through pipeline"
    echo "$tr_proved"
    FAIL=$((FAIL + 1))
fi

# Entry point: main → user_main in LLVM
if echo "$tr_proved" | grep -A10 "main.main" | grep -q "llvm:.*user_main"; then
    echo "  ok  traceability: main maps to user_main in LLVM"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: main should map to user_main in LLVM"
    echo "$tr_proved"
    FAIL=$((FAIL + 1))
fi

# Claim boundary: proved function shows ProofCore boundary
if echo "$tr_proved" | grep -A10 "main.pure_add" | grep -q "boundary:.*ProofCore"; then
    echo "  ok  traceability: proved function boundary at ProofCore"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: proved function should show ProofCore boundary"
    echo "$tr_proved"
    FAIL=$((FAIL + 1))
fi

# Generic function: shows monomorphized specializations
tr_generic=$(cached_output "$TESTDIR/report_integration.con" "--report traceability")
if echo "$tr_generic" | grep -A10 "main.identity" | grep -q "identity_for_i32"; then
    echo "  ok  traceability: generic identity shows identity_for_i32 specialization"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: identity should show monomorphized specialization"
    echo "$tr_generic"
    FAIL=$((FAIL + 1))
fi

# Trusted function: trusted-assumption evidence, source boundary
if echo "$tr_generic" | grep -A10 "main.call_raw" | grep -q "trusted-assumption" && \
   echo "$tr_generic" | grep -A10 "main.call_raw" | grep -q "boundary:.*trusted"; then
    echo "  ok  traceability: trusted function shows trusted-assumption + boundary"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: trusted function should show trusted-assumption"
    echo "$tr_generic"
    FAIL=$((FAIL + 1))
fi

# Reported function: fails predictable, source boundary
if echo "$tr_generic" | grep -A10 "main.uses_alloc" | grep -q "evidence:.*reported" && \
   echo "$tr_generic" | grep -A10 "main.uses_alloc" | grep -q "boundary:.*fails predictable"; then
    echo "  ok  traceability: reported function shows fails predictable boundary"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: reported function should show fails predictable"
    echo "$tr_generic"
    FAIL=$((FAIL + 1))
fi

# Summary totals
if echo "$tr_generic" | grep -q "2 enforced" && \
   echo "$tr_generic" | grep -q "4 reported"; then
    echo "  ok  traceability: summary totals correct"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability: summary should show 2 enforced, 4 reported"
    echo "$tr_generic"
    FAIL=$((FAIL + 1))
fi

# JSON query: traceability facts
tr_json=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query traceability:pure_add")
if echo "$tr_json" | grep -q '"kind": "traceability"' && \
   echo "$tr_json" | grep -q '"evidence": "proved"' && \
   echo "$tr_json" | grep -q '"proof_core": "(a + b)"' && \
   echo "$tr_json" | grep -q '"boundary":.*ProofCore'; then
    echo "  ok  traceability JSON: --query traceability:pure_add returns full trace"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability JSON: should return full trace"
    echo "$tr_json"
    FAIL=$((FAIL + 1))
fi

# JSON query: generic function shows mono names
tr_json_gen=$(cached_output "$TESTDIR/report_integration.con" "--query traceability:identity")
if echo "$tr_json_gen" | grep -q '"mono":.*identity_for_i32' && \
   echo "$tr_json_gen" | grep -q '"ssa":.*identity_for_i32'; then
    echo "  ok  traceability JSON: identity shows mono/SSA specializations"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability JSON: identity should show specializations"
    echo "$tr_json_gen"
    FAIL=$((FAIL + 1))
fi

# JSON query: all traceability facts
tr_json_all=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query traceability")
if echo "$tr_json_all" | grep -q '"kind": "traceability"'; then
    echo "  ok  traceability JSON: --query traceability returns all facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  traceability JSON: --query traceability should return facts"
    echo "$tr_json_all"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Named spec/proof identity tests ==="

# Extraction report: registry-backed function shows spec/proof names
ext_spec=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report extraction")
if echo "$ext_spec" | grep -A10 "main.pure_add" | grep -q "spec:.*PureAdd.spec_add" && \
   echo "$ext_spec" | grep -A10 "main.pure_add" | grep -q "proof:.*PureAdd.add_comm"; then
    echo "  ok  named-spec: extraction report shows spec/proof from registry"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: extraction report should show spec/proof from registry"
    echo "$ext_spec"
    FAIL=$((FAIL + 1))
fi

# Extraction JSON: spec/proof fields present
ext_spec_json=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query extraction:pure_add")
if echo "$ext_spec_json" | grep -q '"spec": "PureAdd.spec_add"' && \
   echo "$ext_spec_json" | grep -q '"proof": "PureAdd.add_comm"'; then
    echo "  ok  named-spec: extraction JSON includes spec/proof fields"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: extraction JSON should include spec/proof"
    echo "$ext_spec_json"
    FAIL=$((FAIL + 1))
fi

# Traceability report: shows spec/proof from registry
tr_spec=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--report traceability")
if echo "$tr_spec" | grep -A15 "main.pure_add" | grep -q "spec:.*PureAdd.spec_add" && \
   echo "$tr_spec" | grep -A15 "main.pure_add" | grep -q "proof:.*PureAdd.add_comm"; then
    echo "  ok  named-spec: traceability report shows spec/proof from registry"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: traceability report should show spec/proof"
    echo "$tr_spec"
    FAIL=$((FAIL + 1))
fi

# Traceability JSON: spec/proof fields present
tr_spec_json=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query traceability:pure_add")
if echo "$tr_spec_json" | grep -q '"spec": "PureAdd.spec_add"' && \
   echo "$tr_spec_json" | grep -q '"proof": "PureAdd.add_comm"'; then
    echo "  ok  named-spec: traceability JSON includes spec/proof fields"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: traceability JSON should include spec/proof"
    echo "$tr_spec_json"
    FAIL=$((FAIL + 1))
fi

# Proof-status: shows spec/proof from registry
ps_spec=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query proof_status:pure_add")
if echo "$ps_spec" | grep -q '"spec": "PureAdd.spec_add"' && \
   echo "$ps_spec" | grep -q '"proof": "PureAdd.add_comm"'; then
    echo "  ok  named-spec: proof-status JSON includes spec/proof from registry"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: proof-status JSON should include spec/proof"
    echo "$ps_spec"
    FAIL=$((FAIL + 1))
fi

# Obligations: shows spec/proof from registry
ob_spec=$(cached_output "$REGISTRY_DIR/test_proof_registry.con" "--query obligation:pure_add")
if echo "$ob_spec" | grep -q '"spec": "PureAdd.spec_add"' && \
   echo "$ob_spec" | grep -q '"proof": "PureAdd.add_comm"'; then
    echo "  ok  named-spec: obligations JSON includes spec/proof from registry"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: obligations JSON should include spec/proof"
    echo "$ob_spec"
    FAIL=$((FAIL + 1))
fi

# Spec identity consistent: same spec name across extraction, traceability, proof-status
if echo "$ext_spec_json" | grep -q '"spec": "PureAdd.spec_add"' && \
   echo "$tr_spec_json" | grep -q '"spec": "PureAdd.spec_add"' && \
   echo "$ps_spec" | grep -q '"spec": "PureAdd.spec_add"'; then
    echo "  ok  named-spec: spec identity consistent across extraction/trace/proof-status"
    PASS=$((PASS + 1))
else
    echo "FAIL  named-spec: spec identity should be consistent across reports"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Semantic diff / trust drift tests ==="

STALE_DIR="$TESTDIR/proof_registry_stale"
MISS_DIR="$TESTDIR/proof_registry_miss"

# Generate fact bundles for diffing
diff_baseline=$($COMPILER "$REGISTRY_DIR/test_proof_registry.con" --report diagnostics-json 2>/dev/null)
diff_stale=$($COMPILER "$STALE_DIR/test_proof_registry.con" --report diagnostics-json 2>/dev/null)
diff_mixed=$($COMPILER "$TESTDIR/report_integration.con" --report diagnostics-json 2>/dev/null)

echo "$diff_baseline" > /tmp/concrete_diff_baseline.json
echo "$diff_stale" > /tmp/concrete_diff_stale.json
echo "$diff_mixed" > /tmp/concrete_diff_mixed.json

# No changes: diff against itself
diff_same=$($COMPILER diff /tmp/concrete_diff_baseline.json /tmp/concrete_diff_baseline.json 2>&1) && diff_same_exit=0 || diff_same_exit=$?
if echo "$diff_same" | grep -q "No trust-relevant changes" && [ "$diff_same_exit" -eq 0 ]; then
    echo "  ok  diff: no changes when diffing against self"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: self-diff should report no changes"
    echo "$diff_same"
    FAIL=$((FAIL + 1))
fi

# Proved → stale: trust weakened
diff_stale_out=$($COMPILER diff /tmp/concrete_diff_baseline.json /tmp/concrete_diff_stale.json 2>&1) && diff_stale_exit=0 || diff_stale_exit=$?
if echo "$diff_stale_out" | grep -q "TRUST WEAKENED" && \
   echo "$diff_stale_out" | grep -q "state: proved.*stale" && \
   [ "$diff_stale_exit" -eq 1 ]; then
    echo "  ok  diff: proved→stale detected as trust weakened (exit 1)"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: proved→stale should be trust weakened"
    echo "$diff_stale_out"
    FAIL=$((FAIL + 1))
fi

# JSON output mode
diff_json=$($COMPILER diff /tmp/concrete_diff_baseline.json /tmp/concrete_diff_stale.json --json 2>&1) && true || true
if echo "$diff_json" | grep -q '"drift": "weakened"' && \
   echo "$diff_json" | grep -q '"category": "changed"'; then
    echo "  ok  diff: JSON output includes drift and category"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: JSON output should include drift and category"
    echo "$diff_json"
    FAIL=$((FAIL + 1))
fi

# Different programs: detects added and changed facts
diff_cross=$($COMPILER diff /tmp/concrete_diff_baseline.json /tmp/concrete_diff_mixed.json 2>&1) && true || true
if echo "$diff_cross" | grep -q '\[+\]' && \
   echo "$diff_cross" | grep -q '\[~\]'; then
    echo "  ok  diff: cross-program diff shows added and changed facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: cross-program diff should show added/changed facts"
    echo "$diff_cross"
    FAIL=$((FAIL + 1))
fi

# Evidence downgrade detected
if echo "$diff_cross" | grep -q "evidence:.*enforced.*reported" || \
   echo "$diff_cross" | grep -q "state:.*proved.*no_proof"; then
    echo "  ok  diff: evidence downgrade detected in field changes"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: should detect evidence downgrade"
    echo "$diff_cross"
    FAIL=$((FAIL + 1))
fi

# Summary line present
if echo "$diff_stale_out" | grep -q "Summary:.*changes"; then
    echo "  ok  diff: summary line present"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: should have summary line"
    echo "$diff_stale_out"
    FAIL=$((FAIL + 1))
fi

# New predictable violations flagged as weakened
if echo "$diff_cross" | grep -q '\[+\] predictable_violation'; then
    echo "  ok  diff: new predictable violations flagged as trust weakened"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: new predictable violations should be flagged"
    echo "$diff_cross"
    FAIL=$((FAIL + 1))
fi

# Spec/proof attachment changes visible
if echo "$diff_cross" | grep -q "spec:.*PureAdd" || \
   echo "$diff_cross" | grep -q "proof:.*PureAdd"; then
    echo "  ok  diff: spec/proof attachment changes visible in diff"
    PASS=$((PASS + 1))
else
    echo "FAIL  diff: spec/proof changes should be visible"
    echo "$diff_cross"
    FAIL=$((FAIL + 1))
fi

# Clean up
rm -f /tmp/concrete_diff_baseline.json /tmp/concrete_diff_stale.json /tmp/concrete_diff_mixed.json

echo ""
echo "=== Adversarial diff tests ==="

ADV_DIR="/tmp/concrete_adv_diff"
mkdir -p "$ADV_DIR"

# --- Malformed JSON input ---

# Truncated JSON (unclosed array)
echo '[{"kind":"effects","function":"foo"' > "$ADV_DIR/truncated.json"
echo '[]' > "$ADV_DIR/empty_arr.json"
adv_trunc=$($COMPILER diff "$ADV_DIR/truncated.json" "$ADV_DIR/empty_arr.json" 2>&1) && true || true
if echo "$adv_trunc" | grep -qi "error.*parse\|could not parse"; then
    echo "  ok  adv-diff: truncated JSON rejected with parse error"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: truncated JSON should produce parse error"
    echo "$adv_trunc"
    FAIL=$((FAIL + 1))
fi

# Non-array root (bare object)
echo '{"kind":"effects","function":"foo"}' > "$ADV_DIR/bare_obj.json"
adv_bare=$($COMPILER diff "$ADV_DIR/bare_obj.json" "$ADV_DIR/empty_arr.json" 2>&1) && true || true
if echo "$adv_bare" | grep -qi "error.*parse\|could not parse"; then
    echo "  ok  adv-diff: non-array JSON root rejected"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: non-array JSON root should be rejected"
    echo "$adv_bare"
    FAIL=$((FAIL + 1))
fi

# Empty file
echo -n "" > "$ADV_DIR/empty_file.json"
adv_empty=$($COMPILER diff "$ADV_DIR/empty_file.json" "$ADV_DIR/empty_arr.json" 2>&1) && true || true
if echo "$adv_empty" | grep -qi "error.*parse\|could not parse"; then
    echo "  ok  adv-diff: empty file rejected with parse error"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: empty file should produce parse error"
    echo "$adv_empty"
    FAIL=$((FAIL + 1))
fi

# --- Empty array diffs ---

# Both empty → no changes
adv_both_empty=$($COMPILER diff "$ADV_DIR/empty_arr.json" "$ADV_DIR/empty_arr.json" 2>&1) && adv_ee_exit=0 || adv_ee_exit=$?
if echo "$adv_both_empty" | grep -q "No trust-relevant changes" && [ "$adv_ee_exit" -eq 0 ]; then
    echo "  ok  adv-diff: both-empty diff reports no changes (exit 0)"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: both-empty diff should report no changes"
    echo "$adv_both_empty"
    FAIL=$((FAIL + 1))
fi

# --- Missing kind/function fields (silently dropped) ---

# Fact without "function" field → should be excluded from diff
cat > "$ADV_DIR/no_function.json" << 'ADVEOF'
[{"kind":"effects","is_pure":true}]
ADVEOF
cat > "$ADV_DIR/normal_fact.json" << 'ADVEOF'
[{"kind":"effects","function":"foo","is_pure":true}]
ADVEOF
adv_nofn=$($COMPILER diff "$ADV_DIR/no_function.json" "$ADV_DIR/normal_fact.json" 2>&1) && true || true
# The fact without function should be dropped, so "foo" appears as added
if echo "$adv_nofn" | grep -q '\[+\].*effects.*foo'; then
    echo "  ok  adv-diff: fact without function field dropped, counterpart shows as added"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: missing function field should cause fact to be dropped"
    echo "$adv_nofn"
    FAIL=$((FAIL + 1))
fi

# Fact without "kind" field → should also be dropped
cat > "$ADV_DIR/no_kind.json" << 'ADVEOF'
[{"function":"foo","is_pure":true}]
ADVEOF
adv_nokind=$($COMPILER diff "$ADV_DIR/no_kind.json" "$ADV_DIR/normal_fact.json" 2>&1) && true || true
if echo "$adv_nokind" | grep -q '\[+\].*effects.*foo'; then
    echo "  ok  adv-diff: fact without kind field dropped, counterpart shows as added"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: missing kind field should cause fact to be dropped"
    echo "$adv_nokind"
    FAIL=$((FAIL + 1))
fi

# --- Duplicate (kind, function) in same bundle ---
# Only first match is used — second duplicate is invisible

cat > "$ADV_DIR/dupes_old.json" << 'ADVEOF'
[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"abc"}]
ADVEOF
cat > "$ADV_DIR/dupes_new.json" << 'ADVEOF'
[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"abc"},{"kind":"proof_status","function":"foo","state":"stale","current_fingerprint":"xyz"}]
ADVEOF
adv_dupes=$($COMPILER diff "$ADV_DIR/dupes_old.json" "$ADV_DIR/dupes_new.json" 2>&1) && adv_dupes_exit=0 || adv_dupes_exit=$?
# Duplicate keys should be rejected as a structured error with exit code 2
if echo "$adv_dupes" | grep -qi "error.*duplicate" && [ "$adv_dupes_exit" -eq 2 ]; then
    echo "  ok  adv-diff: duplicate (kind, function) keys rejected (exit 2)"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: duplicate keys should produce error with exit 2"
    echo "$adv_dupes (exit=$adv_dupes_exit)"
    FAIL=$((FAIL + 1))
fi

# --- Fingerprint change without state change ---

cat > "$ADV_DIR/fp_old.json" << 'ADVEOF'
[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"abc","spec":"Foo.spec","proof":"Foo.proof","source":"registry"}]
ADVEOF
cat > "$ADV_DIR/fp_new.json" << 'ADVEOF'
[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"xyz","spec":"Foo.spec","proof":"Foo.proof","source":"registry"}]
ADVEOF
adv_fp=$($COMPILER diff "$ADV_DIR/fp_old.json" "$ADV_DIR/fp_new.json" 2>&1) && adv_fp_exit=0 || adv_fp_exit=$?
# Fingerprint changed but state is still proved → should detect change, neutral drift
if echo "$adv_fp" | grep -q "current_fingerprint:.*abc.*xyz" && \
   echo "$adv_fp" | grep -q "OTHER CHANGES"; then
    echo "  ok  adv-diff: fingerprint change without state change detected as neutral"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: fingerprint-only change should be detected as neutral"
    echo "$adv_fp"
    FAIL=$((FAIL + 1))
fi

# --- Capability array grows (string-level diff) ---

cat > "$ADV_DIR/cap_old.json" << 'ADVEOF'
[{"kind":"effects","function":"foo","capabilities":"[]","is_pure":"true","allocates":"false","frees":"false","recursion":"none","loops":"none","crosses_ffi":"false","is_trusted":"false","evidence":"enforced"}]
ADVEOF
cat > "$ADV_DIR/cap_new.json" << 'ADVEOF'
[{"kind":"effects","function":"foo","capabilities":"[Alloc, Network]","is_pure":"false","allocates":"false","frees":"false","recursion":"none","loops":"none","crosses_ffi":"false","is_trusted":"false","evidence":"reported"}]
ADVEOF
adv_cap=$($COMPILER diff "$ADV_DIR/cap_old.json" "$ADV_DIR/cap_new.json" 2>&1) && true || true
if echo "$adv_cap" | grep -q "TRUST WEAKENED" && \
   echo "$adv_cap" | grep -q "capabilities:" && \
   echo "$adv_cap" | grep -q "evidence:.*enforced.*reported"; then
    echo "  ok  adv-diff: capability growth + evidence downgrade detected as weakened"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: capability growth should be detected"
    echo "$adv_cap"
    FAIL=$((FAIL + 1))
fi

# --- New function with weak evidence appears as neutral (known gap) ---

cat > "$ADV_DIR/new_weak_old.json" << 'ADVEOF'
[]
ADVEOF
cat > "$ADV_DIR/new_weak_new.json" << 'ADVEOF'
[{"kind":"effects","function":"evil_fn","evidence":"reported","is_pure":"false","capabilities":"[Alloc]","allocates":"true","frees":"false","recursion":"none","loops":"none","crosses_ffi":"true","is_trusted":"false"}]
ADVEOF
adv_newweak=$($COMPILER diff "$ADV_DIR/new_weak_old.json" "$ADV_DIR/new_weak_new.json" 2>&1) && adv_nw_exit=0 || adv_nw_exit=$?
# New function with weak evidence should be flagged as weakened
if echo "$adv_newweak" | grep -q '\[+\].*effects.*evil_fn' && \
   echo "$adv_newweak" | grep -q "TRUST WEAKENED"; then
    echo "  ok  adv-diff: new function with weak evidence flagged as trust weakened"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: new weak-evidence function should be flagged as weakened"
    echo "$adv_newweak"
    FAIL=$((FAIL + 1))
fi

# --- Removed fact detected as weakened ---

cat > "$ADV_DIR/removed_old.json" << 'ADVEOF'
[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"abc"}]
ADVEOF
adv_removed=$($COMPILER diff "$ADV_DIR/removed_old.json" "$ADV_DIR/new_weak_old.json" 2>&1) && true || true
if echo "$adv_removed" | grep -q "TRUST WEAKENED" && \
   echo "$adv_removed" | grep -q '\[-\].*proof_status.*foo'; then
    echo "  ok  adv-diff: removed proof_status fact flagged as trust weakened"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: removed fact should be flagged as weakened"
    echo "$adv_removed"
    FAIL=$((FAIL + 1))
fi

# --- Escaped characters in function names ---

cat > "$ADV_DIR/escape_old.json" << 'ADVEOF'
[{"kind":"proof_status","function":"mod.fn_with\"quotes","state":"proved","current_fingerprint":"abc"}]
ADVEOF
cat > "$ADV_DIR/escape_new.json" << 'ADVEOF'
[{"kind":"proof_status","function":"mod.fn_with\"quotes","state":"stale","current_fingerprint":"abc"}]
ADVEOF
adv_esc=$($COMPILER diff "$ADV_DIR/escape_old.json" "$ADV_DIR/escape_new.json" 2>&1) && true || true
if echo "$adv_esc" | grep -q "TRUST WEAKENED" && \
   echo "$adv_esc" | grep -q "state:.*proved.*stale"; then
    echo "  ok  adv-diff: escaped quotes in function names handled correctly"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: escaped function names should still diff correctly"
    echo "$adv_esc"
    FAIL=$((FAIL + 1))
fi

# --- New weak additions classified as weakened ---

# New proof_status with no_proof → weakened
cat > "$ADV_DIR/new_noproof_new.json" << 'ADVEOF'
[{"kind":"proof_status","function":"bar","state":"no_proof","current_fingerprint":"xyz"}]
ADVEOF
adv_noproof=$($COMPILER diff "$ADV_DIR/new_weak_old.json" "$ADV_DIR/new_noproof_new.json" 2>&1) && true || true
if echo "$adv_noproof" | grep -q "TRUST WEAKENED" && \
   echo "$adv_noproof" | grep -q '\[+\].*proof_status.*bar'; then
    echo "  ok  adv-diff: new no_proof fact flagged as weakened"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: new no_proof fact should be weakened"
    echo "$adv_noproof"
    FAIL=$((FAIL + 1))
fi

# New capability with is_pure=false → weakened
cat > "$ADV_DIR/new_impure_new.json" << 'ADVEOF'
[{"kind":"capability","function":"impure_fn","capabilities":"[Alloc]","is_pure":"false"}]
ADVEOF
adv_impure=$($COMPILER diff "$ADV_DIR/new_weak_old.json" "$ADV_DIR/new_impure_new.json" 2>&1) && true || true
if echo "$adv_impure" | grep -q "TRUST WEAKENED"; then
    echo "  ok  adv-diff: new impure capability fact flagged as weakened"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: new impure capability should be weakened"
    echo "$adv_impure"
    FAIL=$((FAIL + 1))
fi

# New proved fact → neutral (not weakened)
cat > "$ADV_DIR/new_proved_new.json" << 'ADVEOF'
[{"kind":"proof_status","function":"good","state":"proved","current_fingerprint":"abc"}]
ADVEOF
adv_proved=$($COMPILER diff "$ADV_DIR/new_weak_old.json" "$ADV_DIR/new_proved_new.json" 2>&1) && adv_proved_exit=0 || adv_proved_exit=$?
if echo "$adv_proved" | grep -q "OTHER CHANGES" && [ "$adv_proved_exit" -eq 0 ]; then
    echo "  ok  adv-diff: new proved fact is neutral (exit 0)"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: new proved fact should be neutral"
    echo "$adv_proved"
    FAIL=$((FAIL + 1))
fi

# Duplicate keys in old bundle → error
cat > "$ADV_DIR/dupes_old_bundle.json" << 'ADVEOF'
[{"kind":"effects","function":"foo","evidence":"proved"},{"kind":"effects","function":"foo","evidence":"stale"}]
ADVEOF
adv_old_dupes=$($COMPILER diff "$ADV_DIR/dupes_old_bundle.json" "$ADV_DIR/new_weak_old.json" 2>&1) && true || true
if echo "$adv_old_dupes" | grep -qi "error.*duplicate.*old"; then
    echo "  ok  adv-diff: duplicate keys in old bundle rejected"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: duplicate keys in old bundle should be rejected"
    echo "$adv_old_dupes"
    FAIL=$((FAIL + 1))
fi

# --- Nonexistent file path ---

adv_nofile=$($COMPILER diff "/tmp/this_does_not_exist_12345.json" "$ADV_DIR/empty_arr.json" 2>&1) && true || true
if echo "$adv_nofile" | grep -qi "error\|no such file\|does not exist"; then
    echo "  ok  adv-diff: nonexistent file produces error"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: nonexistent file should produce error"
    echo "$adv_nofile"
    FAIL=$((FAIL + 1))
fi

# --- Strengthening direction: stale → proved ---

cat > "$ADV_DIR/strengthen_old.json" << 'ADVEOF'
[{"kind":"proof_status","function":"foo","state":"stale","current_fingerprint":"abc","spec":"Foo.spec","proof":"Foo.proof","source":"registry"}]
ADVEOF
cat > "$ADV_DIR/strengthen_new.json" << 'ADVEOF'
[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"abc","spec":"Foo.spec","proof":"Foo.proof","source":"registry"}]
ADVEOF
adv_strength=$($COMPILER diff "$ADV_DIR/strengthen_old.json" "$ADV_DIR/strengthen_new.json" 2>&1) && adv_str_exit=0 || adv_str_exit=$?
if echo "$adv_strength" | grep -q "TRUST STRENGTHENED" && \
   echo "$adv_strength" | grep -q "state:.*stale.*proved" && \
   [ "$adv_str_exit" -eq 0 ]; then
    echo "  ok  adv-diff: stale→proved detected as strengthened (exit 0)"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: stale→proved should be strengthened with exit 0"
    echo "$adv_strength"
    FAIL=$((FAIL + 1))
fi

# --- Mixed drift: both weakened + strengthened in same diff ---

cat > "$ADV_DIR/mixed_old.json" << 'ADVEOF'
[{"kind":"proof_status","function":"foo","state":"stale","current_fingerprint":"abc"},{"kind":"proof_status","function":"bar","state":"proved","current_fingerprint":"xyz"}]
ADVEOF
cat > "$ADV_DIR/mixed_new.json" << 'ADVEOF'
[{"kind":"proof_status","function":"foo","state":"proved","current_fingerprint":"abc"},{"kind":"proof_status","function":"bar","state":"stale","current_fingerprint":"xyz"}]
ADVEOF
adv_mixed=$($COMPILER diff "$ADV_DIR/mixed_old.json" "$ADV_DIR/mixed_new.json" 2>&1) && adv_mix_exit=0 || adv_mix_exit=$?
if echo "$adv_mixed" | grep -q "TRUST WEAKENED" && \
   echo "$adv_mixed" | grep -q "TRUST STRENGTHENED" && \
   [ "$adv_mix_exit" -eq 1 ]; then
    echo "  ok  adv-diff: mixed drift shows both weakened + strengthened (exit 1)"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: mixed drift should show both directions, exit 1"
    echo "$adv_mixed"
    FAIL=$((FAIL + 1))
fi

# --- Round-trip: real diagnostics-json → parse → diff ---

# Generate real compiler JSON, diff it against itself (round-trip parse test)
rt_json=$($COMPILER "$REGISTRY_DIR/test_proof_registry.con" --report diagnostics-json 2>/dev/null)
echo "$rt_json" > "$ADV_DIR/rt_a.json"
echo "$rt_json" > "$ADV_DIR/rt_b.json"
adv_rt=$($COMPILER diff "$ADV_DIR/rt_a.json" "$ADV_DIR/rt_b.json" 2>&1) && adv_rt_exit=0 || adv_rt_exit=$?
if echo "$adv_rt" | grep -q "No trust-relevant changes" && [ "$adv_rt_exit" -eq 0 ]; then
    echo "  ok  adv-diff: round-trip real diagnostics-json parses and self-diffs clean"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: round-trip of real compiler JSON should self-diff clean"
    echo "$adv_rt"
    FAIL=$((FAIL + 1))
fi

# Round-trip with a different program (more complex JSON)
rt_json2=$($COMPILER "$TESTDIR/report_integration.con" --report diagnostics-json 2>/dev/null)
echo "$rt_json2" > "$ADV_DIR/rt_c.json"
echo "$rt_json2" > "$ADV_DIR/rt_d.json"
adv_rt2=$($COMPILER diff "$ADV_DIR/rt_c.json" "$ADV_DIR/rt_d.json" 2>&1) && adv_rt2_exit=0 || adv_rt2_exit=$?
if echo "$adv_rt2" | grep -q "No trust-relevant changes" && [ "$adv_rt2_exit" -eq 0 ]; then
    echo "  ok  adv-diff: round-trip complex program JSON self-diffs clean"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: round-trip of complex program JSON should self-diff clean"
    echo "$adv_rt2"
    FAIL=$((FAIL + 1))
fi

# Cross-program diff on real compiler output (not hand-crafted)
adv_rt_cross=$($COMPILER diff "$ADV_DIR/rt_a.json" "$ADV_DIR/rt_c.json" 2>&1) && true || true
if echo "$adv_rt_cross" | grep -q "Summary:.*changes" && \
   echo "$adv_rt_cross" | grep -q "TRUST WEAKENED"; then
    echo "  ok  adv-diff: cross-program diff on real JSON detects drift"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: cross-program diff on real JSON should detect drift"
    echo "$adv_rt_cross"
    FAIL=$((FAIL + 1))
fi

# --- Registry miss → empty spec/proof in extraction ---

MISS_DIR="$TESTDIR/proof_registry_miss"
ext_miss=$(cached_output "$MISS_DIR/test_proof_registry.con" "--report extraction")
# pure_add should have no spec/proof since registry points to nonexistent_function
if echo "$ext_miss" | grep -A10 "main.pure_add" | grep -q "status: extracted"; then
    # Check that spec/proof lines are NOT present (registry miss)
    if echo "$ext_miss" | grep -A10 "main.pure_add" | grep -q "spec:.*PureAdd"; then
        echo "FAIL  adv-diff: registry miss should not show spec from unmatched registry"
        echo "$ext_miss"
        FAIL=$((FAIL + 1))
    else
        echo "  ok  adv-diff: registry miss → extraction has no spec/proof"
        PASS=$((PASS + 1))
    fi
else
    echo "FAIL  adv-diff: registry miss pure_add should still be extracted"
    echo "$ext_miss"
    FAIL=$((FAIL + 1))
fi

# Registry miss → empty spec/proof in extraction JSON
ext_miss_json=$(cached_output "$MISS_DIR/test_proof_registry.con" "--query extraction:pure_add")
if echo "$ext_miss_json" | grep -q '"spec": ""' || \
   ! echo "$ext_miss_json" | grep -q '"spec": "PureAdd'; then
    echo "  ok  adv-diff: registry miss → extraction JSON has empty spec"
    PASS=$((PASS + 1))
else
    echo "FAIL  adv-diff: registry miss extraction JSON should have empty spec"
    echo "$ext_miss_json"
    FAIL=$((FAIL + 1))
fi

# Clean up adversarial test files
rm -rf "$ADV_DIR"

echo ""
echo "=== Fact artifact snapshot tests ==="

SNAP_DIR="/tmp/concrete_snap_test"
mkdir -p "$SNAP_DIR"

# Basic snapshot generation
snap_out=$($COMPILER snapshot "$REGISTRY_DIR/test_proof_registry.con" -o "$SNAP_DIR/proved.facts.json" 2>&1)
if echo "$snap_out" | grep -q "Snapshot written" && [ -f "$SNAP_DIR/proved.facts.json" ]; then
    echo "  ok  snapshot: generates file with success message"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: should generate file"
    echo "$snap_out"
    FAIL=$((FAIL + 1))
fi

# Snapshot has correct structure (version, source, facts, summary)
if python3 -c "
import json, sys
with open('$SNAP_DIR/proved.facts.json') as f:
    s = json.load(f)
assert s['version'] == 1
assert 'source' in s
assert 'timestamp' in s
assert 'fact_count' in s
assert isinstance(s['facts'], list)
assert isinstance(s['summary'], dict)
assert s['fact_count'] == len(s['facts'])
" 2>/dev/null; then
    echo "  ok  snapshot: JSON has version, source, timestamp, fact_count, facts, summary"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: JSON structure should have all required fields"
    FAIL=$((FAIL + 1))
fi

# Snapshot includes traceability facts (requires backend pipeline)
if python3 -c "
import json, sys
with open('$SNAP_DIR/proved.facts.json') as f:
    s = json.load(f)
kinds = set(f['kind'] for f in s['facts'])
assert 'traceability' in kinds
assert 'proof_status' in kinds
assert 'obligation' in kinds
assert 'extraction' in kinds
assert 'effects' in kinds
assert 'capability' in kinds
" 2>/dev/null; then
    echo "  ok  snapshot: includes all fact kinds including traceability"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: should include all fact kinds"
    FAIL=$((FAIL + 1))
fi

# Summary counts match actual facts
if python3 -c "
import json, sys
with open('$SNAP_DIR/proved.facts.json') as f:
    s = json.load(f)
sm = s['summary']
facts = s['facts']
ps = [f for f in facts if f['kind'] == 'proof_status']
assert sm['total_functions'] == len(ps), f'{sm[\"total_functions\"]} != {len(ps)}'
proved = [f for f in ps if f['state'] == 'proved']
assert sm['proved'] == len(proved)
trace = [f for f in facts if f['kind'] == 'traceability']
assert sm['traceability_facts'] == len(trace)
" 2>/dev/null; then
    echo "  ok  snapshot: summary counts match actual fact counts"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: summary counts should match facts"
    FAIL=$((FAIL + 1))
fi

# Diff works with snapshot files (not just raw arrays)
$COMPILER snapshot "$STALE_DIR/test_proof_registry.con" -o "$SNAP_DIR/stale.facts.json" 2>/dev/null
snap_diff=$($COMPILER diff "$SNAP_DIR/proved.facts.json" "$SNAP_DIR/stale.facts.json" 2>&1) && snap_diff_exit=0 || snap_diff_exit=$?
if echo "$snap_diff" | grep -q "TRUST WEAKENED" && \
   echo "$snap_diff" | grep -q "state:.*proved.*stale" && \
   [ "$snap_diff_exit" -eq 1 ]; then
    echo "  ok  snapshot: diff works with snapshot files (detects proved→stale)"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: diff should work with snapshot files"
    echo "$snap_diff"
    FAIL=$((FAIL + 1))
fi

# Snapshot diff catches traceability boundary drift (only visible with snapshots)
if echo "$snap_diff" | grep -q "boundary:.*ProofCore.*source"; then
    echo "  ok  snapshot: diff catches traceability boundary drift"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: diff should catch traceability boundary changes"
    echo "$snap_diff"
    FAIL=$((FAIL + 1))
fi

# Self-diff on snapshot is clean
snap_self=$($COMPILER diff "$SNAP_DIR/proved.facts.json" "$SNAP_DIR/proved.facts.json" 2>&1) && snap_self_exit=0 || snap_self_exit=$?
if echo "$snap_self" | grep -q "No trust-relevant changes" && [ "$snap_self_exit" -eq 0 ]; then
    echo "  ok  snapshot: self-diff on snapshot is clean"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: self-diff on snapshot should be clean"
    echo "$snap_self"
    FAIL=$((FAIL + 1))
fi

# Mixed diff: snapshot file vs raw diagnostics-json array
raw_json=$($COMPILER "$REGISTRY_DIR/test_proof_registry.con" --report diagnostics-json 2>/dev/null)
echo "$raw_json" > "$SNAP_DIR/raw.json"
snap_vs_raw=$($COMPILER diff "$SNAP_DIR/proved.facts.json" "$SNAP_DIR/raw.json" 2>&1) && snap_vr_exit=0 || snap_vr_exit=$?
# Snapshot has traceability facts that raw doesn't → traceability facts appear as removed
if [ "$snap_vr_exit" -eq 0 ] || [ "$snap_vr_exit" -eq 1 ]; then
    echo "  ok  snapshot: diff handles snapshot vs raw array format"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: diff should handle mixed formats (snapshot vs raw)"
    echo "$snap_vs_raw"
    FAIL=$((FAIL + 1))
fi

# Default output path: <file>.facts.json
$COMPILER snapshot "$REGISTRY_DIR/test_proof_registry.con" 2>/dev/null
if [ -f "$REGISTRY_DIR/test_proof_registry.facts.json" ]; then
    echo "  ok  snapshot: default output path is <file>.facts.json"
    PASS=$((PASS + 1))
    rm -f "$REGISTRY_DIR/test_proof_registry.facts.json"
else
    echo "FAIL  snapshot: default output should be <file>.facts.json"
    FAIL=$((FAIL + 1))
fi

# Complex program snapshot
snap_complex=$($COMPILER snapshot "$TESTDIR/report_integration.con" -o "$SNAP_DIR/complex.facts.json" 2>&1)
if echo "$snap_complex" | grep -q "Snapshot written" && \
   python3 -c "
import json
with open('$SNAP_DIR/complex.facts.json') as f:
    s = json.load(f)
assert s['fact_count'] > 20
assert s['summary']['predictable_violations'] > 0
" 2>/dev/null; then
    echo "  ok  snapshot: complex program snapshot has violations and many facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  snapshot: complex program snapshot should have violations"
    echo "$snap_complex"
    FAIL=$((FAIL + 1))
fi

# Clean up
rm -rf "$SNAP_DIR"

# === Crypto verification core (flagship example #2) ===
echo ""
echo "=== Crypto verification core tests ==="

CRYPTO_DIR="$ROOT_DIR/examples/crypto_verify/src"
CRYPTO_SNAP_DIR=$(mktemp -d)

# --- Snapshot tests ---

# Snapshot generates correct fact count
snap_crypto=$($COMPILER snapshot "$CRYPTO_DIR/main.con" -o "$CRYPTO_SNAP_DIR/good.facts.json" 2>&1)
if echo "$snap_crypto" | grep -q "24 facts"; then
    echo "  ok  crypto_verify: snapshot produces 24 facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: expected 24 facts in snapshot"
    echo "$snap_crypto"
    FAIL=$((FAIL + 1))
fi

# All 3 core functions are proved
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/good.facts.json') as f:
    s = json.load(f)
assert s['summary']['proved'] == 3
assert s['summary']['stale'] == 0
assert s['summary']['no_proof'] == 1
assert s['summary']['total_functions'] == 4
" 2>/dev/null; then
    echo "  ok  crypto_verify: summary shows 3 proved, 1 unproved, 0 stale"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: summary proof counts incorrect"
    FAIL=$((FAIL + 1))
fi

# All 3 obligations proved
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/good.facts.json') as f:
    s = json.load(f)
assert s['summary']['obligations_proved'] == 3
assert s['summary']['obligations_missing'] == 1
assert s['summary']['obligations_stale'] == 0
" 2>/dev/null; then
    echo "  ok  crypto_verify: 3 obligations proved, 1 missing (main)"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: obligation counts incorrect"
    FAIL=$((FAIL + 1))
fi

# All 3 core functions extracted
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/good.facts.json') as f:
    s = json.load(f)
assert s['summary']['extracted'] == 3
assert s['summary']['excluded'] == 1
" 2>/dev/null; then
    echo "  ok  crypto_verify: 3 functions extracted, 1 excluded"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: extraction counts incorrect"
    FAIL=$((FAIL + 1))
fi

# Named specs present in facts
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/good.facts.json') as f:
    s = json.load(f)
facts = s['facts']
proof_statuses = [f for f in facts if f['kind'] == 'proof_status' and f.get('spec')]
assert len(proof_statuses) == 3
specs = {f['function']: f['spec'] for f in proof_statuses}
assert specs['main.compute_tag'] == 'Concrete.Proof.computeTagExpr'
assert specs['main.verify_tag'] == 'Concrete.Proof.verifyTagExpr'
assert specs['main.check_nonce'] == 'Concrete.Proof.checkNonceExpr'
" 2>/dev/null; then
    echo "  ok  crypto_verify: named specs present in proof_status facts"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: named specs missing from proof_status facts"
    FAIL=$((FAIL + 1))
fi

# ProofCore extraction content
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/good.facts.json') as f:
    s = json.load(f)
facts = s['facts']
extractions = {f['function']: f for f in facts if f['kind'] == 'extraction' and f.get('proof_core')}
assert '((key * message) + nonce)' in extractions['main.compute_tag']['proof_core']
assert 'compute_tag' in extractions['main.verify_tag']['proof_core']
assert 'nonce > 0' in extractions['main.check_nonce']['proof_core']
" 2>/dev/null; then
    echo "  ok  crypto_verify: ProofCore extraction content correct"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: ProofCore extraction content incorrect"
    FAIL=$((FAIL + 1))
fi

# All core functions are pure
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/good.facts.json') as f:
    s = json.load(f)
facts = s['facts']
effects = {f['function']: f for f in facts if f['kind'] == 'effects'}
for fn in ['compute_tag', 'verify_tag', 'check_nonce']:
    assert effects[fn]['is_pure'] == True
    assert effects[fn]['capabilities'] == []
    assert effects[fn]['crosses_ffi'] == False
" 2>/dev/null; then
    echo "  ok  crypto_verify: all core functions are pure with no capabilities"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: core functions should be pure with no capabilities"
    FAIL=$((FAIL + 1))
fi

# --- Report tests ---

# Proof status report shows 3 proved
report_out=$($COMPILER "$CRYPTO_DIR/main.con" --report proof-status 2>&1)
if echo "$report_out" | grep -q "3 proved" && echo "$report_out" | grep -q "1 unproved"; then
    echo "  ok  crypto_verify: proof-status report shows 3 proved, 1 unproved"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: proof-status report counts wrong"
    echo "$report_out"
    FAIL=$((FAIL + 1))
fi

# Each proved function shows checkmark
for fn in compute_tag verify_tag check_nonce; do
    if echo "$report_out" | grep -q "✓.*$fn"; then
        echo "  ok  crypto_verify: $fn shows proved checkmark"
        PASS=$((PASS + 1))
    else
        echo "FAIL  crypto_verify: $fn should show proved checkmark"
        FAIL=$((FAIL + 1))
    fi
done

# --- Drift detection tests ---

# Generate drifted snapshot
$COMPILER snapshot "$CRYPTO_DIR/main_drifted.con" -o "$CRYPTO_SNAP_DIR/drifted.facts.json" 2>/dev/null

# Diff detects trust weakening (exit 1)
diff_out=$($COMPILER diff "$CRYPTO_SNAP_DIR/good.facts.json" "$CRYPTO_SNAP_DIR/drifted.facts.json" 2>&1) && diff_exit=0 || diff_exit=$?
if [ "$diff_exit" = "1" ]; then
    echo "  ok  crypto_verify: drift detection exits 1 (trust weakened)"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: drift detection should exit 1, got $diff_exit"
    FAIL=$((FAIL + 1))
fi

# Diff reports proved → stale for compute_tag
if echo "$diff_out" | grep -q "proved.*stale" && echo "$diff_out" | grep -q "compute_tag"; then
    echo "  ok  crypto_verify: drift shows compute_tag proved → stale"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: drift should show compute_tag proved → stale"
    FAIL=$((FAIL + 1))
fi

# Diff reports proved → stale for check_nonce
if echo "$diff_out" | grep -q "check_nonce"; then
    echo "  ok  crypto_verify: drift shows check_nonce changed"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: drift should show check_nonce changed"
    FAIL=$((FAIL + 1))
fi

# verify_tag is NOT in the weakened list (unchanged)
if ! echo "$diff_out" | grep "TRUST WEAKENED" -A 100 | grep -q "verify_tag"; then
    echo "  ok  crypto_verify: verify_tag not flagged as weakened (unchanged)"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: verify_tag should not be weakened"
    FAIL=$((FAIL + 1))
fi

# JSON diff output works
$COMPILER diff "$CRYPTO_SNAP_DIR/good.facts.json" "$CRYPTO_SNAP_DIR/drifted.facts.json" --json > "$CRYPTO_SNAP_DIR/diff.json" 2>&1 && diff_json_exit=0 || diff_json_exit=$?
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/diff.json') as f:
    d = json.load(f)
assert isinstance(d, list)
weakened = [e for e in d if e.get('drift') == 'weakened']
assert len(weakened) > 0
assert len(d) > 0
" 2>/dev/null; then
    echo "  ok  crypto_verify: JSON diff output is valid with weakened entries"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: JSON diff output invalid"
    FAIL=$((FAIL + 1))
fi

# Self-diff is clean (exit 0)
self_diff=$($COMPILER diff "$CRYPTO_SNAP_DIR/good.facts.json" "$CRYPTO_SNAP_DIR/good.facts.json" 2>&1) && self_exit=0 || self_exit=$?
if [ "$self_exit" = "0" ]; then
    echo "  ok  crypto_verify: self-diff exits 0 (no drift)"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: self-diff should exit 0, got $self_exit"
    FAIL=$((FAIL + 1))
fi

# Drifted snapshot shows stale proofs
if python3 -c "
import json
with open('$CRYPTO_SNAP_DIR/drifted.facts.json') as f:
    s = json.load(f)
assert s['summary']['stale'] == 2
assert s['summary']['proved'] == 1
" 2>/dev/null; then
    echo "  ok  crypto_verify: drifted snapshot shows 2 stale, 1 proved"
    PASS=$((PASS + 1))
else
    echo "FAIL  crypto_verify: drifted snapshot stale counts wrong"
    FAIL=$((FAIL + 1))
fi

# Clean up
rm -rf "$CRYPTO_SNAP_DIR"

fi # end section: report

# === Codegen differential tests ===
echo ""
if section_active codegen; then
echo "=== Codegen differential tests ==="

# --- Category 1: SSA optimization verification ---

# Constant folding: 2 + 3 should be folded to 5
ssa_output=$(cached_emit "$TESTDIR/codegen_constfold.con" "--emit-ssa")
if echo "$ssa_output" | grep -q "ret i64 5"; then
    echo "  ok  codegen_constfold.con --emit-ssa constant folded to ret i64 5"
    PASS=$((PASS + 1))
else
    echo "FAIL  codegen_constfold.con --emit-ssa missing ret i64 5 (constant folding)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

if ! echo "$ssa_output" | grep -q "add i64"; then
    echo "  ok  codegen_constfold.con --emit-ssa no residual add i64"
    PASS=$((PASS + 1))
else
    echo "FAIL  codegen_constfold.con --emit-ssa still contains add i64 (folding missed)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Strength reduction: x * 8 should become shl x, 3
ssa_output=$(cached_emit "$TESTDIR/codegen_strength.con" "--emit-ssa")
if echo "$ssa_output" | grep -q "shl i64 %x, 3"; then
    echo "  ok  codegen_strength.con --emit-ssa strength-reduced *8 to shl 3"
    PASS=$((PASS + 1))
else
    echo "FAIL  codegen_strength.con --emit-ssa missing shl i64 %x, 3 (strength reduction)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

if ! echo "$ssa_output" | grep -q "mul i64"; then
    echo "  ok  codegen_strength.con --emit-ssa no residual mul i64"
    PASS=$((PASS + 1))
else
    echo "FAIL  codegen_strength.con --emit-ssa still contains mul i64 (reduction missed)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# --- Category 2: Codegen structure verification ---

# Struct field access: second field at offset 8
ssa_output=$(cached_emit "$TESTDIR/struct_basic.con" "--emit-ssa")
if echo "$ssa_output" | grep -q "gep i8 %p, i64 8"; then
    echo "  ok  struct_basic.con --emit-ssa second field GEP at offset 8"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_basic.con --emit-ssa missing gep i8 %p, i64 8"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Enum tag load and comparison
ssa_output=$(cached_emit "$TESTDIR/enum_basic.con" "--emit-ssa")
if echo "$ssa_output" | grep -q "load i32"; then
    echo "  ok  enum_basic.con --emit-ssa tag loaded as i32"
    PASS=$((PASS + 1))
else
    echo "FAIL  enum_basic.con --emit-ssa missing load i32 (tag load)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

if echo "$ssa_output" | grep -q "eq i1"; then
    echo "  ok  enum_basic.con --emit-ssa tag comparison with eq i1"
    PASS=$((PASS + 1))
else
    echo "FAIL  enum_basic.con --emit-ssa missing eq i1 (tag comparison)"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Monomorphization: identity<T> specialized for Int and i32
ssa_output=$(cached_emit "$TESTDIR/report_mono_check.con" "--emit-ssa")
if echo "$ssa_output" | grep -q "define i64 @identity_for_Int"; then
    echo "  ok  report_mono_check.con --emit-ssa has identity_for_Int"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_mono_check.con --emit-ssa missing define i64 @identity_for_Int"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

if echo "$ssa_output" | grep -q "define i32 @identity_for_i32"; then
    echo "  ok  report_mono_check.con --emit-ssa has identity_for_i32"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_mono_check.con --emit-ssa missing define i32 @identity_for_i32"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# LLVM struct type definition
llvm_output=$(cached_emit "$TESTDIR/struct_basic.con" "--emit-llvm")
if echo "$llvm_output" | grep -q "%struct.Point = type { i64, i64 }"; then
    echo "  ok  struct_basic.con --emit-llvm has %struct.Point = type { i64, i64 }"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_basic.con --emit-llvm missing %struct.Point = type { i64, i64 }"
    echo "$llvm_output" | head -40
    FAIL=$((FAIL + 1))
fi

# Mutable borrow generates store
ssa_output=$(cached_emit "$TESTDIR/borrow_mut.con" "--emit-ssa")
if echo "$ssa_output" | grep -q "store i64"; then
    echo "  ok  borrow_mut.con --emit-ssa mutable borrow generates store i64"
    PASS=$((PASS + 1))
else
    echo "FAIL  borrow_mut.con --emit-ssa missing store i64"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Struct-in-loop: aggregate promoted to stable alloca (no aggregate phi)
ssa_output=$(cached_emit "$TESTDIR/struct_loop_field_assign.con" "--emit-ssa")
if echo "$ssa_output" | grep -q "alloca %Point" && ! echo "$ssa_output" | grep -q "phi %Point"; then
    echo "  ok  struct_loop_field_assign.con --emit-ssa aggregate promoted to alloca (no phi %Point)"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_loop_field_assign.con --emit-ssa expected alloca %Point but no phi %Point"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Struct-in-if/else: aggregate merge via alloca (no aggregate phi)
ssa_output=$(cached_emit "$TESTDIR/struct_if_else_merge.con" "--emit-ssa")
if echo "$ssa_output" | grep -q "alloca %Pair" && ! echo "$ssa_output" | grep -q "phi %Pair"; then
    echo "  ok  struct_if_else_merge.con --emit-ssa aggregate if/else merged via alloca (no phi %Pair)"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_if_else_merge.con --emit-ssa expected alloca %Pair but no phi %Pair"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Struct-in-match: aggregate merge via alloca (no aggregate phi)
ssa_output=$(cached_emit "$TESTDIR/struct_match_merge.con" "--emit-ssa")
if echo "$ssa_output" | grep -q "alloca %Pair" && ! echo "$ssa_output" | grep -q "phi %Pair"; then
    echo "  ok  struct_match_merge.con --emit-ssa aggregate match merged via alloca (no phi %Pair)"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_match_merge.con --emit-ssa expected alloca %Pair but no phi %Pair"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

# Phase 3: ABI interop test (Concrete + C, verifies sizeof/offsetof match)
abi_ll="$TMPDIR/phase3_abi_interop.ll"
abi_bin="$TMPDIR/phase3_abi_interop"
if filter_match "$TESTDIR/phase3_abi_interop.con"; then
    if $COMPILER "$TESTDIR/phase3_abi_interop.con" --emit-llvm > "$abi_ll" 2>/dev/null; then
        if clang "$abi_ll" "$TESTDIR/phase3_abi_interop.c" -o "$abi_bin" -Wno-override-module 2>/dev/null; then
            abi_result=$("$abi_bin" 2>&1) || true
            if [ "$abi_result" = "42" ]; then
                echo "  ok  phase3_abi_interop.con C interop sizeof/offsetof match"
                PASS=$((PASS + 1))
            else
                echo "FAIL  phase3_abi_interop.con C interop expected 42, got '$abi_result'"
                FAIL=$((FAIL + 1))
            fi
        else
            echo "FAIL  phase3_abi_interop.con C interop clang link failed"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "FAIL  phase3_abi_interop.con C interop compilation failed"
        FAIL=$((FAIL + 1))
    fi
fi

fi # end section: codegen

# --- Category 2b: Optimized-build (-O2) regression for aggregate lowering ---
if section_active O2; then
echo "=== -O2 regression tests ==="
run_ok_O2 "$TESTDIR/struct_loop_field_assign.con" 42
run_ok_O2 "$TESTDIR/struct_loop_break.con"        42
run_ok_O2 "$TESTDIR/struct_nested_loop.con"        42
run_ok_O2 "$TESTDIR/struct_if_else_merge.con"      42
run_ok_O2 "$TESTDIR/struct_match_merge.con"        42

# O2 variants for optimization-sensitive codegen tests
run_ok_O2 "$TESTDIR/test_dead_code_after_return.con" 42
run_ok_O2 "$TESTDIR/test_branch_same_value.con" 42
run_ok_O2 "$TESTDIR/test_deeply_nested_return.con" 42
run_ok_O2 "$TESTDIR/test_loop_nested_three.con" 42
run_ok_O2 "$TESTDIR/test_early_return_loop.con" 42
run_ok_O2 "$TESTDIR/test_constant_fold_complex.con" 42
run_ok_O2 "$TESTDIR/test_loop_invariant.con" 42
run_ok_O2 "$TESTDIR/test_recursive_fibonacci.con" 42

# Phase 3: Expanded O2 differential testing
# Core computation
run_ok_O2 "$TESTDIR/fib.con" 55
run_ok_O2 "$TESTDIR/arithmetic.con" 65
run_ok_O2 "$TESTDIR/while_loop.con" 5050
run_ok_O2 "$TESTDIR/recursion.con" 479001600
run_ok_O2 "$TESTDIR/nested_calls.con" 42

# Struct/enum codegen
run_ok_O2 "$TESTDIR/struct_basic.con" 7
run_ok_O2 "$TESTDIR/struct_field_assign.con" 33
run_ok_O2 "$TESTDIR/struct_nested.con" 42
run_ok_O2 "$TESTDIR/struct_method_chain.con" 39
run_ok_O2 "$TESTDIR/enum_basic.con" 2
run_ok_O2 "$TESTDIR/enum_fields.con" 12
run_ok_O2 "$TESTDIR/enum_linear.con" 42
run_ok_O2 "$TESTDIR/nested_match_enum.con" 60

# Linearity and borrows
run_ok_O2 "$TESTDIR/linear_consume.con" 42
run_ok_O2 "$TESTDIR/linear_branch_agree.con" 42
run_ok_O2 "$TESTDIR/borrow_read.con" 10
run_ok_O2 "$TESTDIR/borrow_mut.con" 42
run_ok_O2 "$TESTDIR/sequential_mut_borrow.con" 43
run_ok_O2 "$TESTDIR/borrow_in_method.con" 67

# Generics and traits
run_ok_O2 "$TESTDIR/generic_fn.con" 42
run_ok_O2 "$TESTDIR/generic_struct.con" 30
run_ok_O2 "$TESTDIR/generic_pair.con" 42
run_ok_O2 "$TESTDIR/trait_basic.con" 30
run_ok_O2 "$TESTDIR/trait_dispatch_chain.con" 42
run_ok_O2 "$TESTDIR/trait_numeric_abs.con" 57

# Result/Option
run_ok_O2 "$TESTDIR/result_ok.con" 42
run_ok_O2 "$TESTDIR/result_generic_try.con" 42
run_ok_O2 "$TESTDIR/option_basic.con" 52
run_ok_O2 "$TESTDIR/option_heap.con" 42

# String operations
run_ok_O2 "$TESTDIR/string_basic.con" 5
run_ok_O2 "$TESTDIR/string_slice_basic.con" 5
run_ok_O2 "$TESTDIR/string_to_int_roundtrip.con" 42

# Break/continue/defer
run_ok_O2 "$TESTDIR/labeled_break.con" 42
run_ok_O2 "$TESTDIR/while_expr_basic.con" 5
run_ok_O2 "$TESTDIR/defer_basic.con" 10
run_ok_O2 "$TESTDIR/defer_lifo.con" 42
run_ok_O2 "$TESTDIR/defer_early_return.con" 10

# Heap/alloc
run_ok_O2 "$TESTDIR/alloc_basic.con" 30
run_ok_O2 "$TESTDIR/heap_arrow.con" 20
run_ok_O2 "$TESTDIR/heap_deref_basic.con" 30
run_ok_O2 "$TESTDIR/heap_deref_recursive.con" 42

# Vec
run_ok_O2 "$TESTDIR/vec_basic.con" 23
run_ok_O2 "$TESTDIR/vec_push_get.con" 500
run_ok_O2 "$TESTDIR/vec_pop.con" 42
run_ok_O2 "$TESTDIR/vec_stress_realloc.con" 249

# Complex programs
run_ok_O2 "$TESTDIR/complex_linked_list.con" 42
run_ok_O2 "$TESTDIR/complex_struct_methods.con" 42
run_ok_O2 "$TESTDIR/complex_generic_container.con" 42
run_ok_O2 "$TESTDIR/complex_state_machine.con" 42
run_ok_O2 "$TESTDIR/complex_recursive_list.con" 42
run_ok_O2 "$TESTDIR/complex_recursive_tree.con" 42

# Integration programs
run_ok_O2 "$TESTDIR/integration_generic_pipeline.con" 42
run_ok_O2 "$TESTDIR/integration_state_machine.con" 42
run_ok_O2 "$TESTDIR/integration_compiler_stress.con" 42
run_ok_O2 "$TESTDIR/integration_stress_workload.con" 42

# Bug regressions under O2
run_ok_O2 "$TESTDIR/bug_cross_module_struct_field.con" 42
run_ok_O2 "$TESTDIR/bug_i32_literal_type.con" 42
run_ok_O2 "$TESTDIR/bug_cross_module_mut_borrow.con" 42
run_ok_O2 "$TESTDIR/bug_array_var_index_assign.con" 42
run_ok_O2 "$TESTDIR/bug_if_expression.con" 0
run_ok_O2 "$TESTDIR/bug_print_builtins.con" "hello 42
0"
run_ok_O2 "$TESTDIR/bug_string_building.con" 0
## bug_clock_builtin excluded from O2: loop between clock calls gets optimized away
run_ok_O2 "$TESTDIR/bug_enum_in_struct.con" 0
run_ok_O2 "$TESTDIR/bug_stack_array_borrow_copy.con" 42

# Hardening tests under O2
run_ok_O2 "$TESTDIR/hardening_int_literal_inference.con" 42
run_ok_O2 "$TESTDIR/hardening_cross_module_enum.con" 42

# Phase 3 mixed-feature programs under O2
run_ok_O2 "$TESTDIR/phase3_expression_evaluator.con" 42
run_ok_O2 "$TESTDIR/phase3_task_scheduler.con" 42
run_ok_O2 "$TESTDIR/phase3_data_pipeline.con" 42
run_ok_O2 "$TESTDIR/phase3_type_checker.con" 42
run_ok_O2 "$TESTDIR/phase3_state_machine.con" 42

# Newtype/repr under O2
run_ok_O2 "$TESTDIR/newtype_basic.con" 42
run_ok_O2 "$TESTDIR/repr_c_basic.con" 42
run_ok_O2 "$TESTDIR/union_basic.con" 42

fi # end section: O2

# --- Category 3: Cross-representation consistency ---
if section_active codegen; then

# LLVM packed struct matches report layout
llvm_output=$(cached_emit "$TESTDIR/report_layout_check.con" "--emit-llvm")
if echo "$llvm_output" | grep -q "%struct.Packed = type <{"; then
    echo "  ok  report_layout_check.con --emit-llvm packed struct uses <{ syntax"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_layout_check.con --emit-llvm missing packed struct <{ syntax"
    echo "$llvm_output" | head -40
    FAIL=$((FAIL + 1))
fi

# LLVM enum payload size matches report layout max_payload
report_output=$(cached_output "$TESTDIR/report_layout_check.con" "--report layout")
layout_max_payload=$(echo "$report_output" | grep -o "max_payload: [0-9]*" | grep -o "[0-9]*")
if echo "$llvm_output" | grep -q "%enum.Shape = type { i32, \[$layout_max_payload x i8\] }"; then
    echo "  ok  report_layout_check.con --emit-llvm enum payload size matches --report layout max_payload ($layout_max_payload)"
    PASS=$((PASS + 1))
else
    echo "FAIL  report_layout_check.con --emit-llvm enum payload size does not match --report layout max_payload ($layout_max_payload)"
    echo "  LLVM: $(echo "$llvm_output" | grep '%enum.Shape')"
    echo "  Report: $(echo "$report_output" | grep 'max_payload')"
    FAIL=$((FAIL + 1))
fi

# Core-SSA consistency: function signature preserved across representations
core_output=$(cached_emit "$TESTDIR/struct_basic.con" "--emit-core")
ssa_output=$(cached_emit "$TESTDIR/struct_basic.con" "--emit-ssa")
if echo "$core_output" | grep -q "fn sum_point(p: Point) -> Int"; then
    echo "  ok  struct_basic.con --emit-core preserves fn sum_point(p: Point) -> Int"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_basic.con --emit-core missing fn sum_point(p: Point) -> Int"
    echo "$core_output"
    FAIL=$((FAIL + 1))
fi

if echo "$ssa_output" | grep -q "define i64 @sum_point"; then
    echo "  ok  struct_basic.con --emit-ssa maps sum_point to define i64 @sum_point"
    PASS=$((PASS + 1))
else
    echo "FAIL  struct_basic.con --emit-ssa missing define i64 @sum_point"
    echo "$ssa_output"
    FAIL=$((FAIL + 1))
fi

fi # end section: codegen (cross-representation)

# === Compiler bug regression tests ===
if section_active positive; then
run_ok "$TESTDIR/regress_deref_field_precedence.con"  42
run_ok "$TESTDIR/regress_mut_field_writeback.con"     42
run_ok "$TESTDIR/regress_char_bool_cast.con"          42
run_ok "$TESTDIR/regress_ref_no_spill.con"            42
run_ok "$TESTDIR/regress_string_field_access.con"     42
run_ok "$TESTDIR/regress_void_phi.con"                0
run_ok "$TESTDIR/test_linear_drop.con"                0
run_ok "$TESTDIR/test_typevar_copy_bound.con"         0
run_ok "$TESTDIR/test_generic_linearity.con"          0
run_ok "$TESTDIR/test_linear_if_return.con"            0
run_ok "$TESTDIR/test_trusted_loop_consume.con"       0
run_ok "$TESTDIR/test_generic_fnptr_map.con"          0

fi # end section: positive (regression tests)

# === Stdlib module tests ===
echo ""
flush_jobs
if section_active stdlib; then
echo "=== Stdlib module tests ==="
rm -f std/src/lib.con.test.ll std/src/lib.con.test

# Stdlib modules that have #[test] functions
STDLIB_TEST_MODULES="string vec bytes slice text path fmt parse hash map set deque heap ordered_map ordered_set bitset option result fs process net"

if [ -n "$STDLIB_MODULE" ]; then
    # Single module mode: only run the requested module
    echo "  (targeting module: std.$STDLIB_MODULE)"
    mod_output=$($COMPILER std/src/lib.con --test --module "std.$STDLIB_MODULE" 2>&1) && mod_exit=0 || mod_exit=$?
    mod_pass=$(echo "$mod_output" | grep -c "^PASS:" || true)
    mod_fail=$(echo "$mod_output" | grep -c "^FAIL:" || true)
    if [ "$mod_pass" -eq 0 ] && [ "$mod_fail" -eq 0 ]; then
        echo "  warn  std.$STDLIB_MODULE — no tests found (check module name)"
    elif [ "$mod_fail" -gt 0 ]; then
        echo "  FAIL  std.$STDLIB_MODULE — $mod_pass passed, $mod_fail failed"
        echo "$mod_output" | grep "^FAIL:"
    else
        echo "  ok    std.$STDLIB_MODULE — $mod_pass passed"
    fi
    PASS=$((PASS + mod_pass))
    FAIL=$((FAIL + mod_fail))
    # Capture for collection verification section
    stdlib_output="$mod_output"
else
    # Full stdlib run with per-module breakdown
    stdlib_output=$($COMPILER std/src/lib.con --test 2>&1) && stdlib_exit=0 || stdlib_exit=$?
    stdlib_pass=$(echo "$stdlib_output" | grep -c "^PASS:" || true)
    stdlib_fail=$(echo "$stdlib_output" | grep -c "^FAIL:" || true)

    echo "  Stdlib: $stdlib_pass passed, $stdlib_fail failed (exit $stdlib_exit)"
    echo "  (use --stdlib-module <name> to target a single module)"
    if [ "$stdlib_fail" -gt 0 ]; then
        echo "$stdlib_output" | grep "^FAIL:"
    fi
    PASS=$((PASS + stdlib_pass))
    FAIL=$((FAIL + stdlib_fail))
fi

fi # end section: stdlib

# === Per-collection test verification ===
# Verify each new collection's tests are present and passing in the stdlib run.
# This catches silent regressions where a collection's tests vanish or break.
echo ""
if section_active collection; then
echo "=== Collection test verification ==="

check_collection_tests() {
    local name="$1"
    shift
    local missing=0
    for test_name in "$@"; do
        if ! echo "$stdlib_output" | grep -qF "PASS: $test_name"; then
            echo "FAIL  collection/$name — missing or failing test: $test_name"
            missing=1
        fi
    done
    if [ "$missing" -eq 0 ]; then
        echo "  ok  collection/$name — all $# tests present and passing"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
}

check_collection_tests "Vec" \
    vec_test_vec_get_in_bounds vec_test_vec_get_out_of_bounds vec_test_vec_get_empty \
    vec_test_pop_some vec_test_pop_none \
    vec_test_vec_set vec_test_vec_clear_reuse vec_test_vec_push_growth vec_test_vec_pop_until_empty

check_collection_tests "Fs" \
    fs_test_file_exists fs_test_write_read_roundtrip \
    fs_test_fs_open_nonexistent fs_test_fs_create_bad_path \
    fs_test_read_file_nonexistent fs_test_write_to_readonly fs_test_write_file_bad_path \
    fs_test_read_file_empty fs_test_append_file fs_test_seek_tell \
    fs_test_read_to_string_nonexistent fs_test_read_to_string_roundtrip fs_test_append_file_bad_path \
    fs_test_read_past_eof fs_test_seek_past_end fs_test_read_to_string_empty

check_collection_tests "Process" \
    process_test_wait_invalid_pid process_test_kill_invalid_pid process_test_signal_constants \
    process_test_getpid process_test_kill_signal_zero \
    process_test_kill_invalid_signal process_test_wait_invalid_pid_negative process_test_kill_pid_zero_exists

check_collection_tests "Net" \
    net_test_connect_refused net_test_connect_bad_address net_test_bind_bad_address \
    net_test_connect_bad_address_ipv6 \
    net_test_bind_empty_address net_test_write_to_refused_connection \
    net_test_read_from_unconnected_socket net_test_bind_duplicate_port

check_collection_tests "Deque" \
    deque_test_push_back_pop_front deque_test_push_front_pop_back deque_test_deque_pop_empty \
    deque_test_get deque_test_growth_wrapping deque_test_mixed_push_pop \
    deque_test_deque_wrap_stress deque_test_deque_clear_reuse

check_collection_tests "BinaryHeap" \
    heap_test_max_heap_basic heap_test_min_heap_basic heap_test_heap_pop_empty heap_test_heap_stress \
    heap_test_heap_sorted_output heap_test_heap_push_pop_interleaved \
    heap_test_heap_peek_empty heap_test_heap_clear_reuse

check_collection_tests "OrderedMap" \
    ordered_map_test_insert_and_get ordered_map_test_sorted_order ordered_map_test_overwrite \
    ordered_map_test_omap_remove ordered_map_test_get_missing \
    ordered_map_test_omap_remove_empty ordered_map_test_omap_min_max_empty ordered_map_test_omap_clear_reuse \
    ordered_map_test_omap_insert_remove_stress

check_collection_tests "OrderedSet" \
    ordered_set_test_insert_contains ordered_set_test_oset_remove ordered_set_test_min_max \
    ordered_set_test_duplicate_insert \
    ordered_set_test_oset_insert_remove_stress ordered_set_test_oset_clear_reuse

check_collection_tests "BitSet" \
    bitset_test_set_and_test bitset_test_unset bitset_test_count bitset_test_union \
    bitset_test_intersect bitset_test_with_capacity \
    bitset_test_loop_set_small bitset_test_bitset_word_boundaries bitset_test_bitset_large_stress \
    bitset_test_len_is_logical_size bitset_test_beyond_logical_size bitset_test_unset_beyond_logical_size \
    bitset_test_non_monotonic_sets bitset_test_unset_preserves_len bitset_test_intersect_preserves_len \
    bitset_test_bitset_clear_reuse

check_collection_tests "Option" \
    option_test_option_some option_test_option_none option_test_option_match

check_collection_tests "Result" \
    result_test_result_ok result_test_result_err result_test_result_match

check_collection_tests "Text" \
    text_test_text_from_string text_test_text_get_unchecked text_test_text_eq text_test_text_empty

check_collection_tests "Slice" \
    slice_test_slice_len slice_test_slice_get_unchecked slice_test_slice_empty slice_test_mutslice_set_get

check_collection_tests "HashMap" \
    map_test_map_insert_len map_test_map_contains map_test_map_overwrite map_test_map_remove \
    map_test_map_remove_nonexistent map_test_map_get map_test_map_clear \
    map_test_map_insert_reinsert_after_remove map_test_map_for_each map_test_map_growth

check_collection_tests "HashSet" \
    set_test_set_insert_contains set_test_set_remove \
    set_test_set_duplicate_insert set_test_set_remove_nonexistent set_test_set_clear_reuse

fi # end section: collection

# --- Pass-level Lean tests (no clang, no I/O — exercises parse/check/elab/mono/lower directly) ---
if section_active passlevel; then
echo "=== Pass-level pipeline tests ==="
PIPELINE_TEST=".lake/build/bin/pipeline-test"
if [ -x "$PIPELINE_TEST" ]; then
    output=$("$PIPELINE_TEST" 2>&1) || true
    # Parse the summary line: "=== N/M passed, F failed ==="
    summary_line=$(echo "$output" | grep -E '^=== [0-9]+/[0-9]+ passed')
    if [ -n "$summary_line" ]; then
        pl_passed=$(echo "$summary_line" | sed 's/=== \([0-9]*\)\/.*/\1/')
        pl_total=$(echo "$summary_line" | sed 's/.*\/\([0-9]*\) passed.*/\1/')
        pl_failed=$(echo "$summary_line" | sed 's/.*, \([0-9]*\) failed.*/\1/')
        PASS=$((PASS + pl_passed))
        FAIL=$((FAIL + pl_failed))
        echo "  $pl_passed/$pl_total pass-level tests passed"
        if [ "$pl_failed" -gt 0 ]; then
            echo "$output" | grep "^FAIL:" >&2
        fi
    else
        echo "  WARNING: could not parse pipeline-test output"
        echo "$output"
    fi
else
    echo "  SKIP: $PIPELINE_TEST not built (run 'lake build pipeline-test')"
    SKIP=$((SKIP + 1))
fi
fi # end section: passlevel

# === Cross-target IR verification (full mode only) ===
if section_active xtarget; then
echo ""
echo "=== Cross-target IR verification (x86_64) ==="
XTARGET_PASS=0
XTARGET_FAIL=0
run_cross_check() {
    local file="$1"
    local base
    base=$(basename "$file" .con)
    local llpath="$TMPDIR/xtarget_${base}.ll"
    cached_output "$file" "--emit-llvm" > "$llpath" 2>/dev/null
    if [ ! -s "$llpath" ]; then
        return
    fi
    if clang -S --target=x86_64-unknown-linux-gnu -Wno-override-module "$llpath" -o /dev/null 2>/dev/null; then
        XTARGET_PASS=$((XTARGET_PASS + 1))
    else
        echo "FAIL  $base — x86_64 IR compilation failed"
        XTARGET_FAIL=$((XTARGET_FAIL + 1))
        FAIL=$((FAIL + 1))
    fi
}
# Representative subset: integration, stress, phase3, ABI, complex programs
for f in \
    "$TESTDIR/integration_stress_workload.con" \
    "$TESTDIR/integration_compiler_stress.con" \
    "$TESTDIR/integration_generic_pipeline.con" \
    "$TESTDIR/integration_state_machine.con" \
    "$TESTDIR/integration_recursive_structures.con" \
    "$TESTDIR/integration_multi_file_calculator.con" \
    "$TESTDIR/integration_type_registry.con" \
    "$TESTDIR/integration_pipeline_processor.con" \
    "$TESTDIR/phase3_expression_evaluator.con" \
    "$TESTDIR/phase3_task_scheduler.con" \
    "$TESTDIR/phase3_data_pipeline.con" \
    "$TESTDIR/phase3_type_checker.con" \
    "$TESTDIR/phase3_state_machine.con" \
    "$TESTDIR/complex_linked_list.con" \
    "$TESTDIR/complex_struct_methods.con" \
    "$TESTDIR/complex_generic_container.con" \
    "$TESTDIR/complex_state_machine.con" \
    "$TESTDIR/complex_recursive_list.con" \
    "$TESTDIR/complex_recursive_tree.con" \
    "$TESTDIR/repr_c_basic.con" \
    "$TESTDIR/vec_basic.con" \
    "$TESTDIR/vec_stress_realloc.con" \
    "$TESTDIR/trait_basic.con" \
    "$TESTDIR/generic_chain.con" \
    "$TESTDIR/test_recursive_fibonacci.con" \
    ; do
    [ -f "$f" ] && run_cross_check "$f"
done
PASS=$((PASS + XTARGET_PASS))
echo "  $XTARGET_PASS/$((XTARGET_PASS + XTARGET_FAIL)) cross-target checks passed"
fi # end section: xtarget

# === Performance regression check (full mode only) ===
if section_active perf; then
echo ""
echo "=== Performance regression check ==="
if [ -f "scripts/tests/test_perf.sh" ] && [ -f ".perf-baseline" ]; then
    perf_output=$(bash scripts/tests/test_perf.sh --compare 2>&1) || true
    perf_warns=$(echo "$perf_output" | grep -c "WARNING" || true)
    if [ "$perf_warns" -gt 0 ]; then
        echo "  $perf_warns performance regression warning(s):"
        echo "$perf_output" | grep "WARNING" | sed 's/^/    /'
    else
        echo "  No performance regressions detected"
    fi
    PASS=$((PASS + 1))
elif [ -f "scripts/tests/test_perf.sh" ] && [ ! -f ".perf-baseline" ]; then
    echo "  SKIP: no .perf-baseline file (run 'bash scripts/tests/test_perf.sh --save' to create)"
    SKIP=$((SKIP + 1))
else
    echo "  SKIP: scripts/tests/test_perf.sh not found"
    SKIP=$((SKIP + 1))
fi
fi # end section: perf

echo ""
flush_jobs

# --- Project-level tests (require Concrete.toml + std) ---
echo "=== Project-level tests ==="
for projdir in "$TESTDIR"/*/; do
    if [ -f "$projdir/Concrete.toml" ]; then
        projname=$(basename "$projdir")
        output=$( cd "$projdir" && "$ROOT_DIR/$COMPILER" build -o /tmp/test_proj_"$projname" 2>&1 ) && build_ok=true || build_ok=false
        if $build_ok; then
            run_result=$(/tmp/test_proj_"$projname" 2>&1) && run_exit=0 || run_exit=$?
            if [ "$run_exit" -eq 0 ]; then
                echo "  ok  $projname"
                PASS=$((PASS + 1))
            else
                echo "  FAIL $projname — exit $run_exit"
                FAIL=$((FAIL + 1))
            fi
        else
            echo "  FAIL $projname — build failed: $output"
            FAIL=$((FAIL + 1))
        fi
        rm -f /tmp/test_proj_"$projname"
    fi
done

# --- Summary ---
echo ""
echo "=== Results ==="
echo "  passed:  $PASS"
echo "  failed:  $FAIL"
if [ "$SKIP" -gt 0 ]; then
    echo "  skipped: $SKIP"
fi
echo "  mode:    $MODE"
if [ -n "$FILTER" ]; then
    echo "  filter:  $FILTER"
fi
CACHE_HITS=$(cat "$CACHE_HITS_FILE")
CACHE_MISSES=$(cat "$CACHE_MISSES_FILE")
CACHE_TOTAL=$((CACHE_HITS + CACHE_MISSES))
if [ "$CACHE_TOTAL" -gt 0 ]; then
    echo "  cache:   $CACHE_HITS/$CACHE_TOTAL hits ($CACHE_HITS compilations saved)"
fi
if [ "$MODE" != "full" ] || [ -n "$FILTER" ]; then
    echo ""
    echo "  NOTE: This was a partial run. Use './scripts/tests/run_tests.sh --full' for complete coverage."
fi
if [ -d "$FAILDIR" ] && [ "$(ls -A "$FAILDIR" 2>/dev/null)" ]; then
    echo ""
    echo "  Failure artifacts saved to $FAILDIR/"
    echo "  Rerun individual failures with the commands in each file."
fi
# Clean up any stray compiled binaries left in tests/programs/ (extensionless files)
find "$TESTDIR" -maxdepth 1 -type f ! -name '*.*' -delete 2>/dev/null || true

echo ""
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
