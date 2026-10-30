# always.34: the code units of tests/cases/always.34.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_always_34_1() {

# examples/project: main.con declares the package's top-level module
# (sees all 3 user functions); sibling files scope to their own count.
ep_main=$($COMPILER examples/project/src/main.con --check predictable 2>&1 || true)
if grep <<<"$ep_main" -q "pass (3 functions checked)"; then
    echo "  ok  scoping: main.con sees all 3 package functions"
    PASS=$((PASS + 1))
else
    echo "FAIL  scoping: main.con should see 3 functions, got: $ep_main"
    FAIL=$((FAIL + 1))
fi

ep_other=$($COMPILER examples/project/src/other.con --check predictable 2>&1 || true)
if grep <<<"$ep_other" -q "pass (1 functions checked)"; then
    echo "  ok  scoping: other.con scopes to its 1 function"
    PASS=$((PASS + 1))
else
    echo "FAIL  scoping: other.con should see 1 function, got: $ep_other"
    FAIL=$((FAIL + 1))
fi

ep_sub=$($COMPILER examples/project/src/mymod/submodule.con --check predictable 2>&1 || true)
if grep <<<"$ep_sub" -q "pass (1 functions checked)"; then
    echo "  ok  scoping: nested submodule.con (3 levels deep) finds project + scopes to its 1 function"
    PASS=$((PASS + 1))
else
    echo "FAIL  scoping: submodule.con should see 1 function, got: $ep_sub"
    FAIL=$((FAIL + 1))
fi

# duplicate_basename: src/a/foo.con and src/b/foo.con both declare
# `mod foo`. Path-derived scoping must distinguish them — bare-name
# matching merges both into 2 functions per file (regression).
db_a=$($COMPILER tests/programs/duplicate_basename/src/a/foo.con --check predictable 2>&1 || true)
if grep <<<"$db_a" -q "pass (1 functions checked)"; then
    echo "  ok  scoping: a/foo.con disambiguates from b/foo.con (1 function)"
    PASS=$((PASS + 1))
else
    echo "FAIL  scoping: a/foo.con should disambiguate to 1 function, got: $db_a"
    FAIL=$((FAIL + 1))
fi

db_b=$($COMPILER tests/programs/duplicate_basename/src/b/foo.con --check predictable 2>&1 || true)
if grep <<<"$db_b" -q "pass (1 functions checked)"; then
    echo "  ok  scoping: b/foo.con disambiguates from a/foo.con (1 function)"
    PASS=$((PASS + 1))
else
    echo "FAIL  scoping: b/foo.con should disambiguate to 1 function, got: $db_b"
    FAIL=$((FAIL + 1))
fi
:
}

suite_always_34_2() {
for projdir in "$TESTDIR"/*/; do
    if [ -f "$projdir/Concrete.toml" ]; then
        projname=$(basename "$projdir")
        # Skip adversarial policy projects — they are tested in the policy section
        case "$projname" in adversarial_policy_*) continue ;; esac
        # Exit 2i: bug 087's borrow-block shadow is now refused at the source (SCOPE-1@1,
        # E0301); its renamed twin regress_2i_scope1_087_borrow_renamed/ runs here instead.
        if [ "$projname" = "regress_087_borrow_shadow_uaf" ]; then
            if output=$( cd "$projdir" && "$ROOT_DIR/$COMPILER" build -o "$TMPDIR/test_proj_""$projname" 2>&1 ); then
                echo "  FAIL $projname — now a SCOPE-1 rejection, but it COMPILED"
                FAIL=$((FAIL + 1))
            elif grep -qF "(E0301)" <<<"$output"; then
                echo "  ok  $projname (rejected: E0301, SCOPE-1@1)"
                PASS=$((PASS + 1))
            else
                echo "  FAIL $projname — rejected, but not with E0301"
                FAIL=$((FAIL + 1))
            fi
            rm -f "$TMPDIR/test_proj_""$projname"
            continue
        fi
        # error_* projects are NEGATIVE fixtures: they must FAIL to build.
        case "$projname" in
        error_*)
            if ( cd "$projdir" && "$ROOT_DIR/$COMPILER" build -o "$TMPDIR/test_proj_""$projname" ) >/dev/null 2>&1; then
                echo "  FAIL $projname — negative project fixture COMPILED"
                FAIL=$((FAIL + 1))
            else
                echo "  ok  $projname (rejected as required)"
                PASS=$((PASS + 1))
            fi
            rm -f "$TMPDIR/test_proj_""$projname"
            continue ;;
        esac
        output=$( cd "$projdir" && "$ROOT_DIR/$COMPILER" build -o "$TMPDIR/test_proj_""$projname" 2>&1 ) && build_ok=true || build_ok=false
        if $build_ok; then
            # Watchdog: a fixture that HANGS must fail, not stall the suite.
            # Bug 048 was exactly this shape — a probe loop that never returned —
            # and with no timeout anywhere in this script it would have taken the
            # whole run (and the CI job) down with it rather than reporting.
            # A timeout is re-run once alone (120 s); a second one is INCOMPLETE, which still fails
            # the run's exit status.
            run_result=$(bounded_run -i /dev/null 60 -- "$TMPDIR/test_proj_""$projname" 2>&1) && run_exit=0 || run_exit=$?
            if bounded_is_incomplete "$run_exit"; then
                echo "  INCOMPLETE $projname — timed out twice (60 s, then 120 s alone): did not terminate, or the machine is overloaded"
                INCOMPLETE=$((INCOMPLETE + 1))
                rm -f "$TMPDIR/test_proj_""$projname"
                continue
            fi
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
        rm -f "$TMPDIR/test_proj_""$projname"
    fi
done
:
}
