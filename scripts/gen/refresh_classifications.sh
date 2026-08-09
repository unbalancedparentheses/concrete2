#!/usr/bin/env bash
# Regenerate Concrete/Proof/ClassificationTable.lean from the live Lean environment.
#
# Two-step because the name set spans two worlds: source-linked proof names live in `.con`
# files (grep), and classification lives in Lean (elaboration). Splicing the first into the
# second keeps ONE list rather than two that drift.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
grep -rhoE '#\[(proof_by|ensures_proof)\(([A-Za-z0-9_.]+)\)\]' examples/ \
  | sed -E 's/.*\(([^)]*)\)\]/\1/' | sort -u > /tmp/srcthms.txt
python3 - <<'PY'
names = [l.strip() for l in open('/tmp/srcthms.txt') if l.strip()]
lits = ",\n    ".join(f'`{n}' for n in names)
p='scripts/gen/classifications.lean'; s=open(p).read()
import re
s = re.sub(r'(def sourceLinkedThms : List Name :=\n  \[ )[^\]]*(\n  \])', lambda m: m.group(1)+lits+m.group(2), s, flags=re.S)
open(p,'w').write(s)
PY
echo "regenerated name set: $(wc -l < /tmp/srcthms.txt) source-linked theorems"
