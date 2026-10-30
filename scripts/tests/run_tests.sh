#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/gate_env.sh" || exit 2

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ============================================================================
# COMPLETION IS ASSERTED, NOT INFERRED FROM OUTPUT.
#
# This suite runs under `set -e`, so any unhandled failure ends it mid-run — and when that happened
# (a fixture moved and two paths went stale), the run simply STOPPED. No summary, no error banner,
# and a reader grepping for `passed:` and `^FAIL` saw exactly what a clean run looks like: nothing.
# An absent summary is a louder signal than a failing test, and it was being read as silence. I
# reported "1699 passed" from a stale run for several rounds because of it.
#
# Two mechanisms, because output alone cannot be trusted:
#   1. A machine-readable summary FILE, written only on normal completion. Consumers read the file,
#      not the stream — stdout/stderr interleaving can corrupt a PASS line mid-word, which has
#      already produced phantom failures in another sandbox.
#   2. An EXIT trap that fires when the file was never written, printing an unmistakable banner and
#      exiting 97 — a code no assertion produces, so "died early" cannot be confused with "failed".
SUMMARY_FILE="${TEST_SUMMARY_FILE:-$ROOT_DIR/.test-summary}"
# Removed first, before anything can exit, so no exit path leaves the previous run's summary to be
# read as this one's. --list runs nothing and replaces nothing, so it keeps the summary (and, below,
# the failure artifacts) of the last real run.
_rt_listing=0; for _a in "$@"; do [ "$_a" = "--list" ] && _rt_listing=1; done
[ "$_rt_listing" = "1" ] || rm -f "$SUMMARY_FILE"
SUMMARY_WRITTEN=0
on_exit() {
  local rc=$?
  # The suite's scratch directory is removed HERE, not by a second `trap ... EXIT`: a later trap
  # REPLACES this one, and one did — `trap 'rm -rf "$TMPDIR"' EXIT` further down silently
  # disabled the banner and exit 97 for every abort after it, so a `set -e` death mid-suite exited
  # with the failing command's code and no "did not complete" notice. Found because a mutant made
  # an unguarded compile fail and the campaign could only report "never reached the end".
  # SUITE_TMPDIR, never the inherited TMPDIR: before it is assigned this must remove nothing.
  [ -z "${SUITE_TMPDIR:-}" ] || rm -rf "$SUITE_TMPDIR"
  command -v heavy_slot_release >/dev/null 2>&1 && heavy_slot_release
  if [ "$SUMMARY_WRITTEN" -ne 1 ]; then
    echo "" >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    echo "!! TEST RUN DID NOT COMPLETE — no summary was produced (exit $rc)." >&2
    echo "!! The suite ended before its final tally, so PASS lines above cover" >&2
    echo "!! only the tests that ran. This is NOT a passing run and must never" >&2
    echo "!! be read as one." >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    exit 97
  fi
}
trap on_exit EXIT
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/selfprint.sh"
cd "$ROOT_DIR"

# --- CLI argument parsing ---
MODE="fast"           # fast (default) | full | stdlib | O2 | codegen | report | affected
FILTER=""             # glob pattern to match test file paths
SECTION=""            # internal: which sections to run
STDLIB_MODULE=""      # single stdlib module to target (e.g., "string", "map")
AFFECTED_FILES=""     # comma-separated list of changed files for --affected mode
LIST_ONLY=0           # --list: print the tests the selected mode runs, run nothing

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
  --trust-gate        Correctness contracts only: determinism, consistency, terminology, verify, evidence, apiversioning, taxonomy, workflow, bundle, proofgate, fixedcap, parsevalidate, serviceerrors, stackdepth
  --affected          Auto-detect changed files (git diff) and run affected tests
  --affected FILES    Run tests affected by specific files (comma-separated)
  --manifest          List all test files with categories (no execution)
  --list              Print one line per test the selected mode runs (id, kind, section, mode); run nothing

Options:
  -j N                Override parallelism (default: number of CPU cores; --full: fair share, R-0543)
  --no-wait           --full only: exit 75 instead of waiting for a machine-wide heavy slot
  -h, --help          Show this help

Environment:
  TEST_JOBS=N         Same as -j N
  LLI_PATH=/path/lli  Use lli (LLVM interpreter) for ~15x faster tests
  SKIP_NETWORK_TESTS=1   Skip tests that need loopback networking

Recommended workflows:
  ./scripts/tests/run_tests.sh                        # daily driver — fast parallel
  ./scripts/tests/run_tests.sh --filter struct_loop   # iterate on one area
  ./scripts/tests/run_tests.sh --stdlib               # after touching std/src/
  ./scripts/tests/run_tests.sh --stdlib-module map    # iterate on one stdlib module
  ./scripts/tests/run_tests.sh --O2                   # after lowering changes
  ./scripts/tests/run_tests.sh --trust-gate            # correctness contracts only
  ./scripts/tests/run_tests.sh --full                 # pre-merge — complete coverage
  ./scripts/tests/run_tests.sh -j 1                   # debug ordering issues
  ./scripts/tests/run_tests.sh --affected             # run tests for uncommitted changes
  ./scripts/tests/run_tests.sh --affected Concrete/IR/Lower.lean,Concrete/IR/SSA.lean
USAGE
    exit 0
}

TEST_JOBS_EXPLICIT=0; [ -n "${TEST_JOBS:-}" ] && TEST_JOBS_EXPLICIT=1
HEAVY_NO_WAIT="${CONCRETE_HEAVY_NO_WAIT:-0}"
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
        --trust-gate) MODE="trust-gate"; shift ;;
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
        --list)    LIST_ONLY=1; shift ;;
        -j)        TEST_JOBS="$2"; TEST_JOBS_EXPLICIT=1; shift 2 ;;
        --no-wait) HEAVY_NO_WAIT=1; shift ;;
        -h|--help) usage ;;
        *)         echo "Unknown option: $1"; usage ;;
    esac
done

# --- Machine-wide load control (R-0543, scripts/tests/lib/heavy_slots.sh) ---
# --full is a heavy run: it waits for one of CONCRETE_HEAVY_SLOTS machine-wide slots (default 2), or
# with --no-wait exits 75. Every other mode is unaffected. A killed run's slot is reclaimed by the
# next waiter because its pid is dead; on_exit releases it on every normal path.
if [ "$MODE" = "full" ] && [ "$LIST_ONLY" = "0" ]; then
    source "$ROOT_DIR/scripts/tests/lib/heavy_slots.sh"
    _hargs=(); [ "$HEAVY_NO_WAIT" = "1" ] && _hargs=(--no-wait)
    _hrc=0; heavy_slot_acquire "run_tests.sh --full" ${_hargs[@]+"${_hargs[@]}"} || _hrc=$?
    if [ "$_hrc" -ne 0 ]; then
        SUMMARY_WRITTEN=1   # not an aborted suite: it never started
        echo "run_tests.sh --full: no heavy slot (exit $_hrc); nothing was run." >&2
        exit "$_hrc"
    fi
    if [ "$TEST_JOBS_EXPLICIT" = "0" ] && [ "$(heavy_slots_n)" -gt 1 ]; then
        TEST_JOBS="$(heavy_jobs_default)"
    fi
fi

# --- Manifest mode: list all tests and exit ---
if [ "$MODE" = "manifest" ]; then
    echo "# Concrete test manifest (auto-generated)"
    echo "# category | kind | file"
    echo "#"
    # Pass-level Lean tests
    echo "passlevel | lean_pass | Concrete/Pipeline/PipelineTest.lean (32 tests)"
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
    full)    SECTION="passlevel,positive,negative,testflag,report,codegen,O2,stdlib,collection,xtarget,perf,determinism,consistency,terminology,verify,evidence,malformed,query,desync,bugaudit,apiversioning,errorcodes,policy,taxonomy,workflow,bundle,proofgate,fixedcap,parsevalidate,serviceerrors,stackdepth,interp" ;;
    fast)    SECTION="passlevel,positive,negative,testflag,report,codegen,O2,stdlib,collection" ;;
    stdlib)  SECTION="stdlib,collection" ;;
    stdlib-module) SECTION="stdlib" ;;
    O2)      SECTION="O2" ;;
    codegen) SECTION="codegen,O2" ;;
    report)  SECTION="report" ;;
    trust-gate) SECTION="determinism,consistency,terminology,verify,evidence,malformed,query,desync,bugaudit,apiversioning,errorcodes,policy,taxonomy,workflow,bundle,proofgate,fixedcap,parsevalidate,serviceerrors,stackdepth,interp" ;;
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
SUITE_TMPDIR="$TMPDIR"   # removed by on_exit; do not add another EXIT trap (it would replace on_exit)
# The bounded runner (lib/bounded.sh) is sourced here, before any section uses it: bug 184's legs
# run early, and a call before the old late `source` would have been "command not found".
BOUNDED_PARENT="$SUITE_TMPDIR"
source "$ROOT_DIR/scripts/tests/lib/bounded.sh"
JOBDIR="$TMPDIR/jobs"
mkdir -p "$JOBDIR"
# TEST SCRATCH IS PRIVATE TO THE RUN (bug 191). A program that touches the filesystem builds its
# paths from CONCRETE_TEST_TMPDIR, never a fixed /tmp name: a fixed name is owned by whichever user
# ran first on a shared host (fopen then fails for everyone else) and is shared by concurrent runs.
# This default covers every program the suite runs; run_ok / run_ok_O2 workers narrow it to a
# directory per job, so the same program run twice in one pass cannot collide either.
export CONCRETE_TEST_TMPDIR="$SUITE_TMPDIR/scratch"
mkdir -p "$CONCRETE_TEST_TMPDIR"

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
        # Tolerate non-zero exit: some tests (e.g. proof-status with a
        # corrupt registry) intentionally exercise reports that exit 1.
        # The assertions below grep the captured output, so the exit
        # code itself is not the signal here. Without `|| true`,
        # `set -e` + `$(...)` would abort the whole runner.
        { $COMPILER "$file" $flags 2>&1 || true; } | tee "$cache_file"
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
[ "$LIST_ONLY" = "1" ] || rm -rf "$FAILDIR"

# --- Call trace (RUN_TESTS_TRACE=FILE) ---
# Every call of a shared assertion helper appends one line to FILE: the helper and its arguments,
# shell-quoted, in call order. Two runs that make the same calls write the same trace, which is how
# the suite's move into data (tests/cases) is shown not to change what runs.
_rt_trace() {
    [ -n "${RUN_TESTS_TRACE:-}" ] || return 0
    printf '%q ' "$@" >> "$RUN_TESTS_TRACE"
    printf '\n' >> "$RUN_TESTS_TRACE"
}

# --- Report assertion helper ---
# check_report FILE MODE GREP_PATTERN OK_MSG FAIL_MSG [NEGATE]
# Compiles FILE with --report MODE (cached), greps for PATTERN.
# If NEGATE is "!" then the pattern must NOT match.
check_report() {
    _rt_trace "${FUNCNAME[0]}" "$@"
    local file="$1" mode="$2" pattern="$3" ok_msg="$4" fail_msg="$5"
    local negate="${6:-}"
    local output
    output=$(cached_output "$file" "--report $mode")
    local matched=0
    if grep <<<"$output" -q "$pattern"; then
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
    _rt_trace "${FUNCNAME[0]}" "$@"
    local file="$1" mode="$2" ok_msg="$3" fail_msg="$4"
    shift 4
    local output
    output=$(cached_output "$file" "--report $mode")
    local all_match=1
    for pattern in "$@"; do
        if ! grep <<<"$output" -q "$pattern"; then
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
    _rt_trace "${FUNCNAME[0]}" "$@"
    local file="$1" profile="$2" pattern="$3" ok_msg="$4" fail_msg="$5"
    local negate="${6:-}"
    local output
    output=$($COMPILER "$file" --check "$profile" 2>&1 || true)
    local matched=0
    if grep <<<"$output" -q "$pattern"; then
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
    _rt_trace "${FUNCNAME[0]}" "$@"
    local file="$1" profile="$2" ok_msg="$3" fail_msg="$4"
    shift 4
    local output
    output=$($COMPILER "$file" --check "$profile" 2>&1 || true)
    local all_match=1
    for pattern in "$@"; do
        if ! grep <<<"$output" -q "$pattern"; then
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

# --- lli FUNCTIONAL probe (added 2026-08-04) ---
# Being on PATH is not the same as working. Measured on LLVM 21.1.8: `lli` runs a trivial
# hand-written module fine, but fails on the IR this compiler emits with
#
#     lli: Symbol "orc_rt_alt_UnwindInfoManager_register" not found in bootstrap symbols map
#
# exiting 1 with empty stdout. The harness discards lli's stderr, so every affected test
# reported the generic "expected printed '...', got rc 1 ''" and 49 of them looked like
# compiler bugs. They were not: verified against origin/main in a clean worktree, which
# emits byte-identical IR and fails identically, with the same 1653/49/2 split.
#
# The cost of not detecting this is worse than a confusing message. The harness ALREADY has
# a native-clang fallback for when lli is absent, so a broken lli silently converted 49 real
# tests into 49 that check nothing — while still reporting a failure count that looked like
# a baseline. Probe once, and on failure fall back to the path that works.
if [ -n "$LLI" ] && [ -x "$COMPILER" ] && [ "$LIST_ONLY" = "0" ]; then
    _probe_dir="$(mktemp -d)"
    cat > "$_probe_dir/probe.con" <<'PROBE_EOF'
pub fn main() with(Std) -> Int {
    print_int(7);
    return 0;
}
PROBE_EOF
    if "$COMPILER" "$_probe_dir/probe.con" --emit-llvm > "$_probe_dir/probe.ll" 2>/dev/null; then
        _probe_err="$("$LLI" "$_probe_dir/probe.ll" 2>&1 >/dev/null)" || true
        _probe_rc=$?
        if has_match "not found in bootstrap symbols map" <<<"$_probe_err"; then
            echo ""
            echo "  WARNING: '$LLI' cannot execute this compiler's IR on this machine."
            echo "           $(printf '%s' "$_probe_err" | awk 'NR<=1')"
            echo "           This is an LLVM/ORC toolchain issue, NOT a compiler bug — it"
            echo "           reproduces on origin/main with byte-identical IR."
            echo "           Falling back to native clang so these tests actually run."
            echo "           (Without this fallback ~49 tests fail with 'rc 1' and empty output.)"
            echo ""
            LLI=""
        fi
    fi
    rm -rf "$_probe_dir"
fi

PASS=0
FAIL=0
SKIP=0
# A timeout is INCOMPLETE, never a failure and never a pass (lib/bounded.sh): it is re-run once alone
# with a larger budget, and a second timeout is counted here. The run exits nonzero when any is.
INCOMPLETE=0
JOB_SEQ=0
declare -a JOB_PIDS=()
declare -a JOB_FILES=()

LLI_STATUS="off"
[ -n "$LLI" ] && LLI_STATUS="on ($LLI)"
if [ "$LIST_ONLY" = "0" ]; then
    echo "Mode: $MODE | Jobs: $TEST_JOBS | Filter: ${FILTER:-<none>} | lli: $LLI_STATUS"
    echo ""
fi

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
        fail_name=$(echo "$message" | awk "NR==1" | sed 's/FAIL  //' | sed 's/[^a-zA-Z0-9_.-]/_/g' | head -c 120)
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
    local expected_rc_raw="${4:-}"
    local expected_rc="${expected_rc_raw:-0}"
    local name
    name=$(path_key "${file%.con}")
    local out="$TMPDIR/$name"
    # Per-job scratch directory (bug 191); see CONCRETE_TEST_TMPDIR above.
    local -x CONCRETE_TEST_TMPDIR="$out.scratch"
    mkdir -p "$CONCRETE_TEST_TMPDIR"

    # MAIN_EXIT_MODEL stage 2.1: a numeric expectation in 0-255 is compared as
    # the PROCESS EXIT CODE (compiled without the legacy echo knob; stdout must
    # be empty). Out-of-range / string expectations keep the knob path until
    # their fixtures self-print (stage 2.2).
    local rc_mode=0
    case "$expected" in
        ''|*[!0-9]*) rc_mode=0 ;;
        *) if [ "$expected" -le 255 ]; then rc_mode=1; fi ;;
    esac
    # An EXPLICIT expected_rc argument means "printed output + this exit code"
    # — never reinterpret the expected string as an exit code.
    if [ -n "$expected_rc_raw" ]; then rc_mode=0; fi
    local actual actual_rc=0
    if [ -n "$LLI" ]; then
        # Fast path: emit LLVM IR and interpret directly (no clang)
        local llpath="$out.ll"
        local emit_ok=1
        $COMPILER "$file" --emit-llvm > "$llpath" 2>/dev/null || emit_ok=0
        if [ "$emit_ok" = "0" ]; then
            {
                echo "FAIL"
                echo "FAIL  $file — compilation failed (expected success)"
                echo "# Rerun: $COMPILER $file --emit-llvm"
            } > "$result_file"
            return
        fi
        # Capture program stdout only; LLVM 21's lli sometimes prints a
        # signal-handler crash dump on stderr during process teardown
        # even when the program exited cleanly with the correct output.
        actual=$($LLI "$llpath" 2>/dev/null) && actual_rc=0 || actual_rc=$?
    else
        # Fallback: compile to native binary via clang
        local comp_ok=1
        $COMPILER "$file" -o "$out" > /dev/null 2>&1 || comp_ok=0
        if [ "$comp_ok" = "0" ]; then
            {
                echo "FAIL"
                echo "FAIL  $file — compilation failed (expected success)"
                echo "# Rerun: $COMPILER $file -o /tmp/test_rerun && /tmp/test_rerun"
            } > "$result_file"
            return
        fi
        actual=$("$out" 2>/dev/null) && actual_rc=0 || actual_rc=$?
    fi
    if [ "$rc_mode" = "1" ]; then
        # lli's teardown signal-handler quirk can corrupt the EXIT CODE the
        # same way it corrupts stderr (see comment above): on a mismatch from
        # the lli path, confirm via a native build before failing — only
        # mismatches pay the clang cost.
        if [ -n "$LLI" ] && [ "$actual_rc" != "$expected" ] && ! { [ "$actual" = "$expected" ] && [ "$actual_rc" = "0" ]; }; then
            if $COMPILER "$file" -o "$out" > /dev/null 2>&1; then
                actual=$("$out" 2>/dev/null) && actual_rc=0 || actual_rc=$?
            fi
        fi
        # Two unambiguous shapes under no-echo: a value-returning fixture
        # (rc == expected, clean stdout) or a self-printing one (prints the
        # value, returns success).
        if { [ "$actual_rc" = "$expected" ] && [ -z "$actual" ]; } || \
           { [ "$actual" = "$expected" ] && [ "$actual_rc" = "0" ]; }; then
            { echo "PASS"; echo "  ok  $file => $expected"; } > "$result_file"
        else
            {
                echo "FAIL"
                echo "FAIL  $file — expected rc $expected (clean stdout) or printed '$expected' (rc 0); got rc $actual_rc stdout '$actual'"
                echo "# Rerun: $COMPILER $file -o /tmp/test_rerun && /tmp/test_rerun"
            } > "$result_file"
        fi
        return
    fi
    # Printed-shape expectation (string / multi-line / numeric beyond the
    # 8-bit status range): the fixture prints its result and exits 0.
    if [ "$actual" = "$expected" ] && [ "$actual_rc" = "$expected_rc" ]; then
        {
            echo "PASS"
            echo "  ok  $file => $expected (rc $expected_rc)"
        } > "$result_file"
    else
        {
            echo "FAIL"
            echo "FAIL  $file — expected printed '$expected' + rc $expected_rc, got rc $actual_rc '$actual'"
            echo "# Rerun: $COMPILER $file -o /tmp/test_rerun && /tmp/test_rerun"
        } > "$result_file"
    fi
}

run_ok() {
    _rt_trace "${FUNCNAME[0]}" "$@"
    local file="$1"
    local expected="$2"
    local expected_rc="${3:-}"
    if ! filter_match "$file"; then SKIP=$((SKIP + 1)); return; fi
    if [ "$TEST_JOBS" -le 1 ]; then
        JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
        run_ok_worker "$file" "$expected" "$result_file" "$expected_rc"
        record_result "$result_file"
        return
    fi
    JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
    throttle_jobs
    (run_ok_worker "$file" "$expected" "$result_file" "$expected_rc") &
    JOB_PIDS+=("$!")
    JOB_FILES+=("$result_file")
}

# Compile to LLVM IR then link with clang -O2 and check output
run_ok_O2_worker() {
    local file="$1"
    local expected="$2"
    local result_file="$3"
    local expected_rc_raw="${4:-}"
    local expected_rc="${expected_rc_raw:-0}"
    local name
    name=$(path_key "${file%.con}")
    local llpath="$TMPDIR/${name}.ll"
    local out="$TMPDIR/${name}_O2"
    # Per-job scratch directory (bug 191); see CONCRETE_TEST_TMPDIR above.
    local -x CONCRETE_TEST_TMPDIR="$out.scratch"
    mkdir -p "$CONCRETE_TEST_TMPDIR"

    local rc_mode=0
    case "$expected" in
        ''|*[!0-9]*) rc_mode=0 ;;
        *) if [ "$expected" -le 255 ]; then rc_mode=1; fi ;;
    esac
    if [ -n "$expected_rc_raw" ]; then rc_mode=0; fi
    local llvm_ir
    llvm_ir=$($COMPILER "$file" --emit-llvm 2>&1) || { echo "FAIL"; echo "FAIL  $file -O2 — emit-llvm failed"; } > "$result_file"
    [ -s "$result_file" ] && return
    echo "$llvm_ir" > "$llpath"
    if ! clang "$llpath" -o "$out" -O2 -Wno-override-module > /dev/null 2>&1; then
        { echo "FAIL"; echo "FAIL  $file -O2 — clang -O2 failed"; } > "$result_file"
        return
    fi
    local actual actual_rc=0
    actual=$("$out" 2>&1) && actual_rc=0 || actual_rc=$?
    if [ "$rc_mode" = "1" ]; then
        if { [ "$actual_rc" = "$expected" ] && [ -z "$actual" ]; } || \
           { [ "$actual" = "$expected" ] && [ "$actual_rc" = "0" ]; }; then
            { echo "PASS"; echo "  ok  $file -O2 => $expected"; } > "$result_file"
        else
            { echo "FAIL"; echo "FAIL  $file -O2 — expected rc $expected (clean stdout) or printed '$expected' (rc 0); got rc $actual_rc stdout '$actual'"; } > "$result_file"
        fi
        return
    fi
    if [ "$actual" = "$expected" ] && [ "$actual_rc" = "$expected_rc" ]; then
        { echo "PASS"; echo "  ok  $file -O2 => $expected (rc $expected_rc)"; } > "$result_file"
    else
        { echo "FAIL"; echo "FAIL  $file -O2 — expected printed '$expected' + rc $expected_rc, got rc $actual_rc '$actual'"; } > "$result_file"
    fi
}

run_ok_O2() {
    _rt_trace "${FUNCNAME[0]}" "$@"
    local file="$1"
    local expected="$2"
    local expected_rc="${3:-}"
    if ! filter_match "$file"; then SKIP=$((SKIP + 1)); return; fi
    if [ "$TEST_JOBS" -le 1 ]; then
        JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
        run_ok_O2_worker "$file" "$expected" "$result_file" "$expected_rc"
        record_result "$result_file"
        return
    fi
    JOB_SEQ=$((JOB_SEQ + 1)); local result_file="$JOBDIR/$JOB_SEQ.result"
    throttle_jobs
    (run_ok_O2_worker "$file" "$expected" "$result_file" "$expected_rc") &
    JOB_PIDS+=("$!")
    JOB_FILES+=("$result_file")
}

# Negative tests: should fail to compile with a specific error substring
# Uses --emit-llvm to skip clang (error is detected before codegen linking).
source "$ROOT_DIR/scripts/tests/lib/diagnostic_codes.sh"

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
    # Bug 206: every refusal names its code. A rendered error without one fails the fixture even
    # when the expected text matched (scripts/tests/lib/diagnostic_codes.sh).
    local codeless
    codeless="$(codeless_error_lines <<<"$stderr")"
    if [ -n "$codeless" ]; then
        {
            echo "FAIL"
            echo "FAIL  $file — an error diagnostic has no code: $(head -1 <<<"$codeless")"
        } > "$result_file"
    elif grep -Fq -- "$expected_err" <<<"$stderr"; then
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
    _rt_trace "${FUNCNAME[0]}" "$@"
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


# ============================================================================
# THE TEST BODY IS DATA. Each block of the suite below is tests/cases/<block>.tsv, read by run_cases:
# one row per test or step, in run order. Columns (tab-separated): id, kind, section, helper, then the
# helper's arguments, one per column (a backslash, tab or newline inside an argument is written \\,
# \t, \n). A row calls `helper args...` exactly as an inline call would. Helper `suite` runs code
# unit N of the block, the function suite_<block>_N in scripts/tests/suite/<block>.sh: statements that
# are not one helper call (loops, bespoke assertions, project directories), moved verbatim. `echo`
# and `flush_jobs` rows are steps, not tests (id -). Blank lines and lines starting with # are
# comments. kind is what the test asserts: run-value, reject-diagnostic, trap, report, profile,
# test-flag, gate-fixture, or script (a code unit). A block is named by its section (a repeated
# section gets .2; unconditional code is always.<n>), and the `if section_active` lines below decide
# which blocks a mode runs. Files are not moved: tests keep their paths under tests/.
#
# --list prints `id<TAB>kind<TAB>section<TAB>mode` for every test row of the blocks the mode runs,
# in run order, and runs nothing.
CASES_DIR="tests/cases"            # relative: the suite runs from ROOT_DIR (cd above)
_case_fields() { # TSV line -> CASE_F, split on tabs with empty fields kept
    local __rc_s="$1"
    CASE_F=()
    while [[ "$__rc_s" == *$'\t'* ]]; do
        CASE_F+=("${__rc_s%%$'\t'*}")
        __rc_s="${__rc_s#*$'\t'}"
    done
    CASE_F+=("$__rc_s")
}
# The locals are prefixed __rc_ because the code units run inside this function and bash scopes
# dynamically: a unit assigning `file` or `i` must reach the global it always reached.
run_cases() {
    local __rc_block="$1" __rc_line __rc_i __rc_a
    local -a __rc_args
    local __rc_file="$CASES_DIR/$__rc_block.tsv"
    if [ ! -f "$__rc_file" ]; then
        echo "run_cases: $__rc_file is missing; the suite cannot be read" >&2
        exit 2
    fi
    # The path is spelled out, not built from a variable: the impact selector and the registration
    # walk read a `source` of scripts/tests/suite/ as running every unit file there.
    if [ "$LIST_ONLY" = "0" ] && [ -f "scripts/tests/suite/$__rc_block.sh" ]; then
        source "scripts/tests/suite/$__rc_block.sh"
    fi
    while IFS= read -r -u 9 __rc_line || [ -n "$__rc_line" ]; do
        case "$__rc_line" in ''|'#'*|$'id\t'*) continue ;; esac
        _case_fields "$__rc_line"
        if [ "$LIST_ONLY" = "1" ]; then
            [ "${CASE_F[0]}" = "-" ] || printf '%s\t%s\t%s\t%s\n' "${CASE_F[0]}" "${CASE_F[1]}" "${CASE_F[2]}" "$MODE"
            continue
        fi
        __rc_args=()
        for ((__rc_i = 4; __rc_i < ${#CASE_F[@]}; __rc_i++)); do
            __rc_a="${CASE_F[__rc_i]}"
            if [[ "$__rc_a" == *\\* ]]; then printf -v __rc_a '%b' "$__rc_a"; fi
            __rc_args+=("$__rc_a")
        done
        if [ "${CASE_F[3]}" = "suite" ]; then
            "suite_${__rc_block//[^A-Za-z0-9]/_}_${__rc_args[0]}"
        else
            "${CASE_F[3]}" "${__rc_args[@]}"
        fi
    done 9< "$__rc_file"
    return 0
}

if section_active positive; then
run_cases positive
fi # end section: positive
run_cases always.1
if section_active negative; then
run_cases negative
fi # end section: negative
run_cases always.2
if section_active testflag; then
run_cases testflag
fi # end section: testflag
run_cases always.3
run_cases always.4
if section_active report; then
run_cases report
fi # end section: report
run_cases always.5
if section_active codegen; then
run_cases codegen
fi # end section: codegen

# --- Category 2b: Optimized-build (-O2) regression for aggregate lowering ---
if section_active O2; then
run_cases O2
fi # end section: O2

# --- Category 3: Cross-representation consistency ---
if section_active codegen; then
run_cases codegen.2
fi # end section: codegen (cross-representation)

# === Compiler bug regression tests ===
if section_active positive; then
run_cases positive.2
fi # end section: positive (regression tests)
run_cases always.9
if section_active stdlib; then
run_cases stdlib
fi # end section: stdlib
run_cases always.10
if section_active collection; then
run_cases collection
fi # end section: collection

# --- Pass-level Lean tests (no clang, no I/O — exercises parse/check/elab/mono/lower directly) ---
if section_active passlevel; then
run_cases passlevel
fi # end section: passlevel

# === Cross-target IR verification (full mode only) ===
if section_active xtarget; then
run_cases xtarget
fi # end section: xtarget

# === Performance regression check (full mode only) ===
if section_active perf; then
run_cases perf
fi # end section: perf

# === Determinism regression check (full mode only) ===
if section_active determinism; then
run_cases determinism
fi # end section: determinism

# === Self-consistency checks (full mode only) ===
if section_active consistency; then
run_cases consistency
fi # end section: consistency

# === Terminology gate (full mode only) ===
if section_active terminology; then
run_cases terminology
fi # end section: terminology

# === Verifier passes (full mode only) ===
if section_active verify; then
run_cases verify
fi # end section: verify

# === Evidence gates (CI/CD evidence for proof, predictable, stale, reports) ===
if section_active malformed; then
run_cases malformed
fi # end section: malformed

# === Invalid-query diagnostic tests ===
if section_active query; then
run_cases query
fi # end section: query

if section_active bugaudit; then
run_cases bugaudit
fi # end section: bugaudit

if section_active evidence; then
run_cases evidence
fi # end section: evidence

# === API versioning envelope tests ===
if section_active apiversioning; then
run_cases apiversioning
fi # end section: apiversioning

# === Error code taxonomy tests ===
if section_active errorcodes; then
run_cases errorcodes
fi # end section: errorcodes
run_cases always.24
if section_active policy; then
run_cases policy
fi # end section: policy
run_cases always.25
if section_active taxonomy; then
run_cases taxonomy
fi # end section: taxonomy
run_cases always.26
if section_active workflow; then
run_cases workflow
fi # end section: workflow
run_cases always.27
if section_active bundle; then
run_cases bundle
fi # end section: bundle
run_cases always.28
if section_active proofgate; then
run_cases proofgate
fi # end section: proofgate

# ============================================================
# Fixed-capacity validation tests (Phase 3, item 23)
# ============================================================

if section_active fixedcap; then
run_cases fixedcap
fi # end section: fixedcap

if section_active parsevalidate; then
run_cases parsevalidate
fi # end section: parsevalidate

if section_active serviceerrors; then
run_cases serviceerrors
fi # end section: serviceerrors

if section_active stackdepth; then
run_cases stackdepth
fi # end section: stackdepth

if section_active interp; then
run_cases interp
fi # end section: interp
run_cases always.34
if section_active evidence || section_active trust-gate; then
run_cases evidence+trust-gate
fi # end workflow tests

# --- User-package scoping tests (item 12) ---
if section_active evidence || section_active trust-gate; then
run_cases evidence+trust-gate.2
fi # end scoping tests

# --list stops here: every block has printed its rows.
if [ "$LIST_ONLY" = "1" ]; then
    SUMMARY_WRITTEN=1   # nothing was meant to run, so the incomplete-run banner does not apply
    exit 0
fi

# --- Summary ---
echo ""
bounded_summary
echo "=== Results ==="
echo "  passed:  $PASS"
echo "  failed:  $FAIL"
if [ "$INCOMPLETE" -gt 0 ]; then
    echo "  incomplete: $INCOMPLETE (timed out twice: not passed, not failed; a qualifying run has none)"
fi
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

# THE SUMMARY FILE IS THE AUTHORITATIVE RESULT. Written last, so its presence means the run reached
# the end; its contents are key=value so no consumer needs to parse prose.
{
  echo "completed=1"
  echo "passed=$PASS"
  echo "failed=$FAIL"
  echo "skipped=${SKIP:-0}"
  echo "incomplete=$INCOMPLETE"
  echo "mode=$MODE"
} > "$SUMMARY_FILE"
SUMMARY_WRITTEN=1

echo ""
echo "  summary written to $SUMMARY_FILE (completed=1 passed=$PASS failed=$FAIL incomplete=$INCOMPLETE)"
if [ "$FAIL" -gt 0 ] || [ "$INCOMPLETE" -gt 0 ]; then
    exit 1
fi
