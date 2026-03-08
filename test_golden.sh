#!/bin/bash
# Verify golden test baselines for --emit-core and --emit-ssa
set -e

COMPILER=".lake/build/bin/concrete"
SRC_DIR="golden_tests/src"
CORE_DIR="golden_tests/core"
SSA_DIR="golden_tests/ssa"

if [ ! -x "$COMPILER" ]; then
  echo "Error: compiler not found at $COMPILER. Run 'lake build' first."
  exit 1
fi

passed=0
failed=0
errors=""

for src in "$SRC_DIR"/*.con; do
  name=$(basename "$src" .con)

  # Test Core IR
  core_expected="$CORE_DIR/$name.expected"
  if [ -f "$core_expected" ]; then
    core_actual=$("$COMPILER" "$src" --emit-core 2>&1) || true
    core_expected_content=$(cat "$core_expected")
    if [ "$core_actual" = "$core_expected_content" ]; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      errors="$errors\n  FAIL core/$name"
      echo "FAIL: core/$name"
      diff -u "$core_expected" <(echo "$core_actual") | head -20
      echo "---"
    fi
  fi

  # Test SSA IR
  ssa_expected="$SSA_DIR/$name.expected"
  if [ -f "$ssa_expected" ]; then
    ssa_actual=$("$COMPILER" "$src" --emit-ssa 2>&1) || true
    ssa_expected_content=$(cat "$ssa_expected")
    if [ "$ssa_actual" = "$ssa_expected_content" ]; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      errors="$errors\n  FAIL ssa/$name"
      echo "FAIL: ssa/$name"
      diff -u "$ssa_expected" <(echo "$ssa_actual") | head -20
      echo "---"
    fi
  fi
done

echo ""
echo "=== Golden Tests: $passed passed, $failed failed ==="
if [ $failed -gt 0 ]; then
  echo -e "Failures:$errors"
  exit 1
fi
