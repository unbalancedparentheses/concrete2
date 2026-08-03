#!/usr/bin/env bash
# Hole-status consistency gate.
#
# WHY THIS EXISTS. On 2026-07-31 three files said "H23 closed as a compile-time fact"  HOLE-STATUS-OK: quoting the wrong claim
# while docs/KNOWN_HOLES.md said "H23 — OPEN, reproduced" and
# check_known_wrong_corpus.sh ASSERTED it still reproduces. Every gate was green. The
# contradiction survived because the claims live in different files and nothing compared
# them: check_docs_drift.sh verifies that referenced artifacts EXIST, not that statements
# agree, and a passing corpus gate says nothing about what the prose next to it claims.
#
# That is the same cross-document blindness recorded in 5a0c4e3e, and it had already been
# named as a class before it recurred. This gate closes it for the one kind of statement
# where being wrong is worst: whether a known soundness hole is open.
#
# THREE CHECKS, strongest first:
#   1. behaviour vs status — a hole with a live counterexample fixture must be OPEN
#   2. authority          — every hole heading carries exactly one parseable status
#   3. prose              — no other file asserts a status contradicting KNOWN_HOLES
#
# Check 1 is the one with teeth: it ties documented status to OBSERVED behaviour rather
# than to other prose. Check 3 is heuristic by nature (English), so it has an explicit
# escape hatch — see HOLE-STATUS-OK below — rather than pretending to be exact.

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
KH="docs/KNOWN_HOLES.md"
CORPUS="scripts/tests/check_known_wrong_corpus.sh"
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

[ -f "$KH" ] || { echo "FAIL $KH missing"; exit 1; }

# --- parse the authority -----------------------------------------------------------
# KNOWN_HOLES.md is the single source of truth for hole status. Everything else is a
# reference to it, and a reference that disagrees is a bug in the reference.
OPEN_HOLES=""; CLOSED_HOLES=""
while IFS= read -r line; do
  id="$(printf '%s' "$line" | grep -oE '^### (H[0-9]+)' | awk '{print $2}')"
  [ -n "$id" ] || continue
  if printf '%s' "$line" | grep -q "OPEN"; then OPEN_HOLES="$OPEN_HOLES $id"
  elif printf '%s' "$line" | grep -q "CLOSED"; then CLOSED_HOLES="$CLOSED_HOLES $id"
  else no "hole heading has no parseable status: $line"; fi
done < <(grep -E '^### H[0-9]+\.' "$KH")

echo "=== 2. every hole heading carries exactly one status ==="
# Ambiguity here would make checks 1 and 3 silently vacuous, so it is asserted before
# they run rather than assumed.
DUP=0
for h in $OPEN_HOLES; do
  case " $CLOSED_HOLES " in *" $h "*) no "$h is marked BOTH open and closed"; DUP=1;; esac
done
[ "$DUP" -eq 0 ] && ok "no hole is marked both open and closed"
[ -n "$OPEN_HOLES" ] && ok "open holes parsed:$OPEN_HOLES" || no "no open holes parsed — regex drift?"
[ -n "$CLOSED_HOLES" ] && ok "closed holes parsed:$CLOSED_HOLES" || no "no closed holes parsed — regex drift?"

echo "=== 1. behaviour vs status: a hole with a live fixture must be OPEN ==="
# The strong check. check_known_wrong_corpus.sh asserts these fixtures still REPRODUCE
# their hole; if one is reproducing, the hole is by definition not closed, whatever any
# document says. This is the check that would have caught the H23 contradiction.
if [ -f "$CORPUS" ]; then
  # A corpus block is one of two kinds, and its heading must say which:
  #   `=== Hnn: ...`                  the fixture REPRODUCES the hole      -> must be OPEN
  #   `=== Hnn (CLOSED <date>): ...`  the fixture GUARDS the fix           -> must be CLOSED
  # Both are legitimate — a closed hole keeps its fixture precisely so a regression is red.
  #
  # Every hole id mentioned in a corpus heading must match one of the two forms. The
  # earlier version parsed only the first, so renaming H23's block to `=== H23 (CLOSED ...)`
  # silently removed it from this check: the gate went green because it stopped looking, not
  # because it verified anything. Unclassifiable headings are therefore a FAILURE, not a skip.
  HEADINGS="$(grep -oE '^echo "=== H[0-9]+[^"]*' "$CORPUS")"
  ALL_IDS="$(printf '%s' "$HEADINGS" | grep -oE 'H[0-9]+' | sort -u)"
  REPRO="$(printf '%s\n' "$HEADINGS" | grep -E '^echo "=== H[0-9]+:' | grep -oE 'H[0-9]+' | sort -u)"
  GUARD="$(printf '%s\n' "$HEADINGS" | grep -E '^echo "=== H[0-9]+ \(CLOSED [0-9]{4}-[0-9]{2}-[0-9]{2}\):' \
           | grep -oE 'H[0-9]+' | sort -u)"
  if [ -z "$ALL_IDS" ]; then
    no "could not parse hole ids from $CORPUS — the link between behaviour and status is broken"
  else
    for h in $ALL_IDS; do
      IS_REPRO=0; IS_GUARD=0
      case " $REPRO " in *" $h "*) IS_REPRO=1 ;; esac
      case " $GUARD " in *" $h "*) IS_GUARD=1 ;; esac
      if [ "$IS_REPRO" = 1 ] && [ "$IS_GUARD" = 1 ]; then
        no "$h has BOTH a reproducing and a regression-guard block in $CORPUS — which is it?"
      elif [ "$IS_REPRO" = 1 ]; then
        case " $OPEN_HOLES " in
          *" $h "*) ok "$h has a reproducing fixture and is marked OPEN" ;;
          *) no "$h has a REPRODUCING fixture in $CORPUS but is not marked OPEN in $KH" ;;
        esac
      elif [ "$IS_GUARD" = 1 ]; then
        case " $CLOSED_HOLES " in
          *" $h "*) ok "$h has a regression-guard fixture and is marked CLOSED" ;;
          *) no "$h's fixture claims the hole is CLOSED but $KH does not mark it closed" ;;
        esac
      else
        no "$h appears in a $CORPUS heading that matches neither form — coverage is silently lost;\
 use '=== $h: ...' (reproduces) or '=== $h (CLOSED YYYY-MM-DD): ...' (guards the fix)"
      fi
    done
  fi
else
  no "$CORPUS missing — cannot tie hole status to observed behaviour"
fi

echo "=== 3. no other file contradicts the authority ==="
# Heuristic and deliberately so: this greps English. A line may opt out with the marker
# HOLE-STATUS-OK, which exists for the legitimate case of QUOTING a wrong claim in order
# to correct it — the correction of the H23 overclaim does exactly that, and a gate that
# forbade it would punish the fix rather than the defect.
SCAN="$(git ls-files 'docs/*.md' 'research/*.md' 'research/**/*.md' '*.md' 'scripts/tests/*.sh' 'Concrete/**/*.lean' 'Main.lean' 2>/dev/null | grep -v "^$KH$")"
VIOL=0
for h in $OPEN_HOLES; do
  # Only INDICATIVE claims count. A roadmap task legitimately says "closes H23" as its
  # objective, a gate legitimately says "H24 may be FIXED — update the docs" as a future
  # condition, and a merge bar legitimately says "H23 must be closed first". None of
  # those assert the hole IS closed, so modal and conditional phrasing is filtered out
  # rather than marked one line at a time. What remains is the assertive form, which is
  # the form that misleads.
  HITS="$(grep -rniE "\b$h\b[^.]{0,40}(is )?(now )?(closed|fixed|resolved)" $SCAN 2>/dev/null \
          | grep -viE "(must|may|should|will|would|could|once|until|pending|before|when|if) (be |it |the )?(closed|fixed|resolved)" \
          | grep -viE "must be closed|may be fixed|to be (closed|fixed)" \
          | grep -v "HOLE-STATUS-OK" || true)"
  if [ -n "$HITS" ]; then
    VIOL=1
    no "$h is OPEN in $KH but claimed closed elsewhere:"
    printf '%s\n' "$HITS" | head -4 | sed 's/^/         /'
  fi
done
[ "$VIOL" -eq 0 ] && ok "no file claims an OPEN hole is closed"

echo ""
echo "HOLE-STATUS-CONSISTENCY: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
