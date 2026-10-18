#!/usr/bin/env python3
"""Concrete frontend/SSA -> QBE adapter -> LCB -> actual native execution.

Compare exit status and stdout with the existing LLVM path, and reject unsupported
checked operations rather than silently weakening their runtime semantics.
Run with Nix and LCB_BIN set to the Nix-built backend executable.
"""
from pathlib import Path
import os
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CONCRETE = Path(os.environ.get('CONCRETE_BIN', ROOT / '.lake/build/bin/concrete'))


def run(args, expected=0):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, text=True, capture_output=True, timeout=120)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result


def main():
    assert platform.system() == 'Darwin' and platform.machine() == 'arm64', 'native ARM64 macOS required; no skip-as-pass'
    assert os.environ.get('LCB_BIN') and os.environ.get('CONCRETE_LCB_CC'), 'run inside nix develop with LCB_BIN supplied'
    programs = {
        'constant': ('fn main() -> Int { return 42; }', 42),
        'wrapping_branch': ((ROOT/'examples/lean_backend/src/main.con').read_text(), 42),
        'loop_phi': ('''fn main() -> Int {
 let mut s: Int = 0;
 let mut i: Int = 1;
 while i <= 10 { s = wrapping_add(s, i); i = wrapping_add(i, 1); }
 return s;
}''', 55),
        'signed_compare': ('''fn main() -> Int {
 let n: Int = wrapping_sub(0, 1);
 if n < 0 { return 17; } else { return 99; }
}''', 17),
        'wrap_boundary': ('fn main() -> Int { return wrapping_add(9223372036854775807, 1); }', 0),
        'unsigned_compare': ('''fn main() -> Int {
 let n: Uint = wrapping_sub(0, 1);
 if n > 1 { return 23; } else { return 99; }
}''', 23),
        'exit_mask': ('fn main() -> Int { return wrapping_sub(0, 1); }', 255),
    }
    negatives = {
        # Unknown parameters prevent SSA cleanup from safely folding literals
        # away before the adapter. Library emission does not require a main.
        'checked_add': ('fn checked(a: Int, b: Int) -> Int { return a + b; }', 'checked/saturating'),
        'checked_neg': ('fn checked(n: Int) -> Int { return -n; }', 'checked negation'),
        'checked_shift': ('fn checked(a: Int, b: Int) -> Int { return a << b; }', 'checked/saturating'),
        'checked_div': ('fn checked(a: Int, b: Int) -> Int { return a / b; }', 'checked/saturating'),
        'narrow': ('fn narrow(n: u8) -> Int { return n as Int; }', 'narrow integers'),
        'call': ('fn helper() -> Int { return 3; } fn main() -> Int { return helper(); }', 'calls are not supported'),
    }
    with tempfile.TemporaryDirectory(prefix='concrete-lcb-integration-') as directory:
        work = Path(directory)
        for name, (source, expected) in programs.items():
            path = work/f'{name}.con'
            path.write_text(source)
            emitted = run([CONCRETE, path, '--emit-qbe'])
            assert 'concrete_lcb_entry' in emitted.stdout and 'define i' not in emitted.stdout
            llvm, lcb = work/f'{name}-llvm', work/f'{name}-lcb'
            # Use the same LLVM emission as the default path, with Nix's C
            # wrapper supplying its pinned SDK rather than host xcrun.
            llvm_ir = run([CONCRETE,path,'--emit-llvm'])
            llvm_file = work/f'{name}.ll'
            llvm_file.write_text(llvm_ir.stdout)
            run([os.environ['CONCRETE_LCB_CC'],'-O2','-Wno-override-module',llvm_file,'-o',llvm])
            run(['bash',ROOT/'scripts/compile_with_lcb.sh',path,'-o',lcb])
            first, second = run([llvm],expected), run([lcb],expected)
            assert first.stdout == second.stdout == '', name
        for name, (source, diagnostic) in negatives.items():
            path, output = work/f'{name}.con', work/f'{name}-lcb'
            path.write_text(source)
            result = run(['bash',ROOT/'scripts/compile_with_lcb.sh',path,'-o',output],1)
            assert diagnostic in result.stderr and 'experimental-qbe' in result.stderr, (name,result.stderr)
            assert not output.exists(), name
    print(f'Concrete -> Lean backend integration: {len(programs)} native LLVM/LCB comparisons; {len(negatives)} unsupported-feature controls')


if __name__ == '__main__': main()
