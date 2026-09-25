#!/usr/bin/env bash
# Phase 7 item 14a gate: the Writer IO spine discipline (option A: fn-pointer handle).
#
#  1. the fixed-buffer writer writes without Alloc
#  2. file/console writers require the right acquisition capability
#  3. nothing returning a Writer hides allocation (caps visible at acquisition)
#  4. (next slice) std.fmt writes through Writer — placeholder assert: no second
#     sink interface exists for it to bypass
#  5. no closed sink enum, no dyn/trait-object writer, exactly one handle shape

set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
M="docs/stdlib/STDLIB_SURFACE_MANIFEST.tsv"
PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# 1. fixed_writer: allocates=no, and the write/flush/close METHODS are cap-free
row=$(grep -P "^io\tfixed_writer\t" "$M")
echo "$row" | awk -F'\t' '$3=="no"' | grep -q . && ok "fixed_writer allocates: no" || no "fixed_writer must not allocate ($row)"
# THE RULE IS ABOUT OPERATIONAL AUTHORITY, and the two axes must not be conflated here.
# `Writer` methods carry no File/Console/Network/Alloc/... because authority was settled
# at ACQUISITION and travels with the handle — that is the ocap model and it is what this
# checks. It is NOT a claim that they impose nothing on the caller: `write_raw` and `read`
# take a CALLER-SUPPLIED raw pointer and will dereference it, so the caller owes validity,
# which is a memory obligation on a different axis. This gate already accepts exactly that
# reasoning one section below, where `fixed_writer requires Unsafe (caller-owned raw
# region)` — the same justification, applied to a constructor rather than a method.
#
# So: no method may carry operational authority; the pointer-taking ones may carry
# `Unsafe` and NOTHING else; the rest must be entirely capability-free.
OPERATIONAL='File|Console|Network|Alloc|Env|Time|Process|Random'
for m in write write_str flush close; do
  r=$(grep -P "^io\t$m\t" "$M")
  echo "$r" | awk -F'\t' '$6=="none"' | grep -q . && ok "Writer.$m capability-free (authority was at acquisition)" \
    || no "Writer.$m carries caps ($r)"
done
for m in write_raw read; do
  r=$(grep -P "^io\t$m\t" "$M")
  if echo "$r" | awk -F'\t' -v op="$OPERATIONAL" '$6 ~ op' | grep -q .; then
    no "Writer/Reader.$m carries OPERATIONAL authority — acquisition already settled that ($r)"
  elif echo "$r" | awk -F'\t' '$6=="Unsafe"' | grep -q .; then
    ok "Writer/Reader.$m declares Unsafe only (caller supplies the raw buffer), no operational authority"
  else
    no "Writer/Reader.$m should declare exactly Unsafe for its caller-supplied pointer ($r)"
  fi
done

# 2. acquisition capabilities
grep -P "^io\twriter_from_file\t" "$M" | awk -F'\t' '$6 ~ /File/' | grep -q . \
  && ok "writer_from_file requires File" || no "writer_from_file missing File cap"
grep -P "^io\tconsole_writer\t" "$M" | awk -F'\t' '$6 ~ /Console/' | grep -q . \
  && ok "console_writer requires Console" || no "console_writer missing Console cap"
grep -P "^io\tfixed_writer\t" "$M" | awk -F'\t' '$6 ~ /Unsafe/' | grep -q . \
  && ok "fixed_writer requires Unsafe (caller-owned raw region)" || no "fixed_writer missing Unsafe cap"

# 3. every Writer-returning pub fn declares SOME acquisition authority (no silent sinks)
bad=$(grep -nE 'pub (trusted )?fn [a-z_]+.*-> *Writer' std/src/io.con | grep -v "with(" || true)
[ -z "$bad" ] && ok "every Writer constructor declares acquisition authority" || no "silent Writer constructor: $bad"

# 5. one handle shape; no closed sink enum; no dyn
[ "$(grep -c 'struct Writer' std/src/io.con)" -eq 1 ] && ok "exactly one Writer handle struct" || no "multiple Writer shapes"
grep -qE 'enum +Writer|dyn +Writer' std/src/*.con && no "closed sink enum / dyn Writer found" || ok "no closed sink enum, no dyn Writer"
n=$(grep -l "write_fn" std/src/*.con | wc -l | tr -d ' ')
[ "$n" -eq 1 ] && ok "the fn-pointer sink shape lives only in std.io" || no "parallel sink interfaces in $n files"

echo "=== Reader (symmetric contract) ==="
grep -P "^io\tfixed_reader\t" "$M" | awk -F'\t' '$3=="no" && $6 ~ /Unsafe/' | grep -q . \
  && ok "fixed_reader: no Alloc, Unsafe at acquisition" || no "fixed_reader facts wrong"
grep -P "^io\treader_from_file\t" "$M" | awk -F'\t' '$6 ~ /File/' | grep -q . \
  && ok "reader_from_file requires File" || no "reader_from_file missing File"
# Same two-axis split as the Writer methods above: the RESULT shape and the absence of
# OPERATIONAL authority are the contract; the `Unsafe` is the caller-supplied buffer.
r=$(grep -P "^io\tread\t" "$M")
if echo "$r" | awk -F'\t' '$5!="result"' | grep -q .; then
  no "Reader.read must return a recoverable Result ($r)"
elif echo "$r" | awk -F'\t' -v op="$OPERATIONAL" '$6 ~ op' | grep -q .; then
  no "Reader.read carries OPERATIONAL authority — acquisition already settled that ($r)"
elif echo "$r" | awk -F'\t' '$6=="Unsafe"' | grep -q .; then
  ok "Reader.read: recoverable Result, no operational authority, Unsafe for the caller's buffer"
else
  no "Reader.read should declare exactly Unsafe for its caller-supplied pointer ($r)"
fi
[ "$(grep -c 'struct Reader' std/src/io.con)" -eq 1 ] && ok "exactly one Reader handle" || no "multiple Readers"

echo
echo "IO-WRITER: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
