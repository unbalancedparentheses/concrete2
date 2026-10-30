# bugaudit: the code units of tests/cases/bugaudit.tsv (its `suite` rows), sourced by run_cases() in
# scripts/tests/run_tests.sh. Each function is a run of statements moved verbatim from the runner.
# shellcheck shell=bash

suite_bugaudit_1() {
# `|| audit_exit=$?`, not a bare capture: this script runs under `set -e`, so a
# failing audit killed run_tests.sh AT THIS ASSIGNMENT — before the code below
# that exists specifically to print every audited bug. The trust gate reported
# failure with the section header and nothing after it, so the one diagnostic
# designed for this path never ran. Same family as the `| head` SIGPIPE bug
# noted below: careful failure reporting that the shell disposes of first.
audit_exit=0
audit_out=$(bash "$ROOT_DIR/scripts/tests/audit_bug_corpus.sh" 2>&1) || audit_exit=$?
# Count pass/fail from audit output
audit_pass=$(grep <<<"$audit_out" -c "^  ok " || true)
audit_fail=$(grep <<<"$audit_out" -c "^  FAIL" || true)
# Print EVERY audited bug, and never through `| head`. This script runs under
# `set -euo pipefail`, so a `head -N` that closes the pipe while grep is still
# writing kills the whole trust gate with grep's exit 2 ("write error: Broken
# pipe") — a race that depends on whether grep's writes fit the pipe buffer, so
# it passes on one commit and fails on the next. It also truncated the report:
# 55 bug entries with `head -30` hid 25 of them, FAIL lines included, while the
# pass/fail counts above were computed from the full output. Evidence that is
# silently cut is worse than verbose evidence.
grep <<<"$audit_out" -E "^  (ok|FAIL|skip|warn)" || true
if [ "$audit_exit" -eq 0 ]; then
    echo "  bug corpus audit passed ($audit_pass mapped, 0 failures)"
    PASS=$((PASS + 1))
else
    echo "  FAIL bug corpus audit: $audit_fail bug(s) missing regression coverage"
    FAIL=$((FAIL + 1))
fi
:
}
