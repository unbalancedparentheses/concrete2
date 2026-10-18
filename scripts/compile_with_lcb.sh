#!/usr/bin/env bash
# Experimental consumer of the general-purpose Lean Compiler Backend.
# See research/compiler/lean-backend-integration.md. Run inside nix develop.
set -euo pipefail
if [[ $# -ne 3 || $2 != -o ]]; then
  echo 'usage: bash scripts/compile_with_lcb.sh INPUT.con -o OUTPUT' >&2
  exit 1
fi
concrete_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
concrete_bin=${CONCRETE_BIN:-$concrete_root/.lake/build/bin/concrete}
lcb_bin=${LCB_BIN:-lcb}
concrete_cc=${CONCRETE_LCB_CC:?run inside the Concrete Nix development shell}
integration_tmp=$(mktemp -d "${TMPDIR:-/tmp}/concrete-lcb.XXXXXX")
trap 'rm -rf "$integration_tmp"' EXIT
"$concrete_bin" "$1" --emit-qbe > "$integration_tmp/program.ssa"
if ! grep -F 'export function l $concrete_lcb_entry()' "$integration_tmp/program.ssa" >/dev/null; then
  echo 'error[experimental-qbe]: executable requires a no-argument Int/Uint main' >&2
  exit 1
fi
"$lcb_bin" "$integration_tmp/program.ssa" --target aarch64-macos -o "$integration_tmp/program.s"
# Same exit-status masking as Concrete's LLVM main wrapper. No Lean runtime.
cat > "$integration_tmp/main.c" <<'EOF'
extern unsigned long long concrete_lcb_entry(void);
int main(void) { return (int)(concrete_lcb_entry() & 255ULL); }
EOF
"$concrete_cc" -O2 "$integration_tmp/program.s" "$integration_tmp/main.c" -o "$3"
printf 'Compiled %s -> %s with experimental Lean Compiler Backend\n' "$1" "$3"
