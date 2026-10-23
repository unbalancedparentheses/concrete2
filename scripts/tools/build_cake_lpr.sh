#!/usr/bin/env bash
# Opt-in experiment: assemble upstream's pinned CakeML output; do not regenerate its proof.
set -euo pipefail
if [ "$#" -ne 1 ] || [ -e "$1" ]; then
  echo "usage: $0 NEW_OUTPUT_DIRECTORY (run inside nix develop)" >&2
  exit 2
fi
for v in $(git rev-parse --local-env-vars); do unset "$v"; done
mkdir -p "$1"
OUT=$(cd "$1" && pwd)
REV=a36874a8b750b43fe4b385b8ddbf5b033e46a3fa
git clone https://github.com/tanyongkiam/cake_lpr.git "$OUT/source"
git -C "$OUT/source" checkout --detach "$REV"
case "$(uname -m)" in
  arm64|aarch64) ASM=cake_lpr_arm8.S ;;
  x86_64) ASM=cake_lpr.S ;;
  *) echo 'unsupported architecture' >&2; exit 2 ;;
esac
# Upstream's checksum list predates a36874a's wrapper change. Pin the actual inputs
# at this revision here, rather than ignoring a failed upstream checksum.
(cd "$OUT/source" && shasum -a 256 -c <<'HASHES'
8e30d84fdcb2177aa5571d7fa6661a2fae5ecfd56baa0ce49c65f9233a9f87cb  basis_ffi.c
2f3af32d55083839b3fa0e693afd817679c0b8944bef41def05a8b0ec72b7d4a  cake_lpr.S
95b64883edc0cb09feedbcb1ebec233e2490f5b458fdda9dc29c212ed916f00c  cake_lpr_arm8.S
HASHES
)
clang "$OUT/source/basis_ffi.c" "$OUT/source/$ASM" -std=c99 -o "$OUT/cake_lpr"
python3 - "$OUT" "$REV" "$ASM" <<'PY'
import hashlib, json, pathlib, subprocess, sys
p = pathlib.Path(sys.argv[1])
def sha(f): return hashlib.sha256(f.read_bytes()).hexdigest()
record = {"upstream": "https://github.com/tanyongkiam/cake_lpr", "revision": sys.argv[2],
          "assembly": sys.argv[3], "assembly_sha256": sha(p / "source" / sys.argv[3]),
          "wrapper_sha256": sha(p / "source/basis_ffi.c"), "binary_sha256": sha(p / "cake_lpr"),
          "cc": subprocess.check_output(["clang", "--version"], text=True)}
(p / "build.json").write_text(json.dumps(record, indent=2) + "\n")
PY
echo "Built $OUT/cake_lpr (host assembler, linker and C wrapper remain trusted)."
