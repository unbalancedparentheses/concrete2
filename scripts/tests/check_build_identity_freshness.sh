#!/usr/bin/env bash
# IS THE EMBEDDED BUILD IDENTITY STILL WHAT THE SOURCES SAY? (R-0004 package 3.)
#
# `Concrete.buildIdentity` is a constant compiled into the binary, and every receipt binds it to name
# the compiler that produced the evidence. A STALE constant is the failure that matters: the binary
# would keep claiming the identity of an older build while running different code, which is precisely
# the false-provenance the value exists to prevent.
#
# So it is re-derived here and compared. This is the same discipline `ClassificationTable` is held to,
# and for the same reason: nothing else in R-0004 rests on a value nobody re-derives.
#
# BEHAVIOURAL, NOT SHAPE-CHECKING. An earlier control for compiler identity asserted only that three
# strings were still present in `Main.lean` — it never made identification fail and never observed
# whether issuance refused, so the production branch could have become unreachable while the strings
# remained. This compares VALUES: what the binary reports against what the sources produce.
set -uo pipefail
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "${GATE_DONE:-0}" -ne 1 ]; then
  echo "FATAL: unexpected shell failure (exit $rc) — the verdict below is not trustworthy" >&2; exit "$rc"; fi' ERR
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source "scripts/tests/lib/fresh.sh"
require_fresh_binary || exit 1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$ROOT_DIR/.lake/build/bin/concrete"

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

echo "=== the binary reports the identity its sources produce ==="

# What the COMPILER says, read off the production surface rather than out of the source file.
REPORTED="$("$BIN" examples/elf_header/src/main.con --report receipts 2>/dev/null \
            | grep -oE 'build:[0-9a-f]+' | head -1 | cut -d: -f2)"
# What the SOURCES say, re-derived now.
cp "Concrete/BuildIdentity.lean" "$TMP/committed.lean"
bash scripts/gen/build_identity.sh >/dev/null 2>&1
FRESH="$(grep -oE 'buildIdentity : String := "[0-9a-f]+"' Concrete/BuildIdentity.lean \
         | grep -oE '[0-9a-f]{32}' | head -1)"
COMMITTED="$(grep -oE 'buildIdentity : String := "[0-9a-f]+"' "$TMP/committed.lean" \
             | grep -oE '[0-9a-f]{32}' | head -1)"
cp "$TMP/committed.lean" "Concrete/BuildIdentity.lean"

if [ -n "$REPORTED" ] && [ -n "$FRESH" ] && [ -n "$COMMITTED" ]; then
  ok "all three values were readable (reported, committed, freshly derived)"
else
  no "a value was missing — reported='$REPORTED' committed='$COMMITTED' fresh='$FRESH'; every comparison below would be vacuous"
  GATE_DONE=1; echo "BUILD-IDENTITY-FRESHNESS: PASS=$PASS FAIL=$FAIL"; exit 1
fi

# 128 BITS, the project standard. An earlier compiler identity kept 64, and rehashing a truncated
# digest downstream cannot recover the entropy it discarded.
if [ "${#COMMITTED}" = "32" ]; then
  ok "the identity is 32 hex characters (128 bits), not a truncated digest"
else
  no "the identity is ${#COMMITTED} hex characters — an evidence identity must not be truncated"
fi
if grep -qE '^[0-9a-f]{32}$' <<<"$COMMITTED"; then
  ok "the identity is well-formed lowercase hex"
else
  no "the identity is not canonical hex: '$COMMITTED'"
fi

if [ "$COMMITTED" = "$FRESH" ]; then
  ok "the committed build identity matches a fresh derivation from the sources"
else
  no "STALE build identity: committed $COMMITTED, sources produce $FRESH — regenerate with scripts/gen/build_identity.sh. A receipt would name a compiler build that is not the one running."
fi
if [ "$REPORTED" = "$COMMITTED" ]; then
  ok "the running binary reports the committed identity (the constant reached the executable)"
else
  no "the binary reports $REPORTED but the source constant is $COMMITTED — the binary is older than the constant"
fi

echo "=== the identity moves when the compiler's sources move ==="

# NON-VACUITY. Without this, a generator that emitted a fixed string would satisfy every assertion
# above. A file the digest covers is perturbed, the value re-derived, and the file restored.
PROBE="Concrete/Proof/Replay.lean"
cp "$PROBE" "$TMP/probe.orig"
printf -- '-- transient probe for check_build_identity_freshness.sh\n' >> "$PROBE"
bash scripts/gen/build_identity.sh >/dev/null 2>&1
MOVED="$(grep -oE '[0-9a-f]{32}' Concrete/BuildIdentity.lean | head -1)"
cp "$TMP/probe.orig" "$PROBE"
cp "$TMP/committed.lean" "Concrete/BuildIdentity.lean"
if [ "$MOVED" != "$COMMITTED" ]; then
  ok "changing a compiler source changes the build identity ($MOVED)"
else
  no "the build identity did not move when a compiler source changed — it is not content-derived"
fi
# ...and restoring the source restores the value, so the digest is a function of content and not of
# how many times the generator has run.
bash scripts/gen/build_identity.sh >/dev/null 2>&1
RESTORED="$(grep -oE '[0-9a-f]{32}' Concrete/BuildIdentity.lean | head -1)"
cp "$TMP/committed.lean" "Concrete/BuildIdentity.lean"
if [ "$RESTORED" = "$COMMITTED" ]; then
  ok "restoring the source restores the identity — it is a function of content alone"
else
  no "the identity did not return to $COMMITTED after restoring the source (got $RESTORED)"
fi

echo "=== nothing at run time depends on a non-portable tool ==="

# THE PORTABILITY REGRESSION THIS REPLACED. An earlier identity shelled out to `sha256sum` on
# `/proc/self/exe`; macOS has neither, and it is an active CI platform, so receipt issuance refused
# there outright. Asserted against the compiled BINARY rather than against the source text, because
# what matters is what the shipped artifact needs at run time.
if [ "$(strings "$BIN" 2>/dev/null | grep -c '/proc/self/exe' || true)" = "0" ]; then
  ok "the binary contains no /proc/self/exe reference"
else
  no "the binary still references /proc/self/exe — receipt issuance would refuse on macOS"
fi

GATE_DONE=1
echo "BUILD-IDENTITY-FRESHNESS: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
