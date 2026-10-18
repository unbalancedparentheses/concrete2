#!/usr/bin/env python3
"""Runtime baseline: one Concrete factorial, LLVM vs Lean backend vs QBE 1.3.

All tools come from Nix. The timed loop calls a separately compiled function
with changing inputs in 1..20. No LTO; printed checksums prevent dead-code removal.
Correctness for 0!..20! is checked before each timed run. This is a local
microbenchmark, not an estimate of general compiler or application performance.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import shutil
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run(args, *, cwd=ROOT):
    result = subprocess.run([str(a) for a in args], cwd=cwd, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise AssertionError(f'{args}: exit {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result.stdout


def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def driver(symbol):
    expected = ','.join(f'UINT64_C({math.factorial(n)})' for n in range(21))
    return f'''#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
extern uint64_t {symbol}(uint64_t);
static const uint64_t expected[21] = {{{expected}}};
int main(int argc, char **argv) {{
  if (argc != 3) return 1;
  uint64_t iterations = strtoull(argv[1], 0, 10);
  uint64_t state = strtoull(argv[2], 0, 10), checksum = 0;
  for (uint64_t n=0; n<=20; ++n) {{
    if ({symbol}(n) != expected[n]) {{ fprintf(stderr,"incorrect factorial at %llu\\n",(unsigned long long)n); return 2; }}
  }}
  struct timespec start, end;
  if (clock_gettime(CLOCK_MONOTONIC, &start)) return 3;
  for (uint64_t i=0; i<iterations; ++i) {{
    state = state * UINT64_C(6364136223846793005) + UINT64_C(1442695040888963407);
    uint64_t n = 1 + state % 20;
    checksum ^= {symbol}(n) + i;
  }}
  if (clock_gettime(CLOCK_MONOTONIC, &end)) return 3;
  double elapsed = (double)(end.tv_sec-start.tv_sec) + (double)(end.tv_nsec-start.tv_nsec)*1e-9;
  printf("{{\\"seconds\\":%.9f,\\"checksum\\":%" PRIu64 "}}\\n",elapsed,checksum);
  return 0;
}}
'''


def expected_checksum(iterations, seed):
    values, mask, checksum, state = [math.factorial(n) for n in range(21)], (1 << 64) - 1, 0, seed
    for index in range(iterations):
        state = (state * 6364136223846793005 + 1442695040888963407) & mask
        checksum ^= (values[1 + state % 20] + index) & mask
    return checksum


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iterations', type=int, default=1000000)
    parser.add_argument('--trials', type=int, default=9)
    parser.add_argument('--seed', type=int, default=20261018)
    parser.add_argument('--qbe-source', type=Path, default=os.environ.get('QBE_SOURCE'))
    parser.add_argument('--out', type=Path, required=True)
    options = parser.parse_args()
    assert platform.system() == 'Darwin' and platform.machine() == 'arm64', 'native ARM64 macOS required'
    assert 1 <= options.iterations <= 100000000 and 3 <= options.trials <= 99
    cc, lcb = os.environ['CONCRETE_LCB_CC'], Path(os.environ['LCB_BIN'])
    concrete = Path(os.environ.get('CONCRETE_BIN', ROOT/'.lake/build/bin/concrete'))
    source = ROOT/'tests/perf/lean_backend/factorial.con'
    assert options.qbe_source and options.qbe_source.is_dir(), '--qbe-source must name retained QBE 1.3 source'
    upstream_root = options.qbe_source.parents[1]
    lock = json.loads((upstream_root/'upstream-lock.json').read_text())
    assert lock['qbe']['version'] == '1.3'
    for name, expected in lock['vendored_files'].items():
        if name.startswith('third_party/qbe/'):
            assert digest(upstream_root/name) == expected, name
    print('Building three variants from the same Concrete source with Nix tools...',flush=True)
    build_times, samples, checksums = {}, {name:[] for name in ('LLVM','LCB','QBE')}, {}
    with tempfile.TemporaryDirectory(prefix='concrete-lcb-factorial-') as directory:
        work = Path(directory)
        compile_source = work/'factorial.con'
        compile_source.write_text(source.read_text())
        qbe_input, llvm_input = work/'factorial.ssa',work/'factorial.ll'
        qbe_input.write_text(run([concrete,compile_source,'--emit-qbe']))
        llvm_input.write_text(run([concrete,compile_source,'--emit-llvm']))
        qbe_symbols = re.findall(r'^export function l \$([A-Za-z_][A-Za-z_0-9]*)\(l ',qbe_input.read_text(),re.M)
        llvm_symbols = re.findall(r'^define i64 @([A-Za-z_][A-Za-z_0-9]*factorial|factorial)\(i64 ',llvm_input.read_text(),re.M)
        assert len(qbe_symbols) == len(llvm_symbols) == 1, (qbe_symbols,llvm_symbols)
        oracle = work/'qbe-source'
        shutil.copytree(options.qbe_source,oracle)
        run(['make','-j2',f'CC={cc}'],cwd=oracle)
        binaries = {}
        for name in samples:
            kernel = llvm_input if name == 'LLVM' else work/f'{name}.s'
            started = time.perf_counter()
            if name == 'LCB': run([lcb,qbe_input,'--target','aarch64-macos','-o',kernel])
            elif name == 'QBE': run([oracle/'qbe','-t','arm64_apple','-o',kernel,qbe_input])
            cfile, exe = work/f'{name}-driver.c',work/name
            cfile.write_text(driver(llvm_symbols[0] if name == 'LLVM' else qbe_symbols[0]))
            run([cc,'-O2','-fno-lto','-Wno-override-module',kernel,cfile,'-o',exe])
            build_times[name] = time.perf_counter()-started
            binaries[name] = exe
            # Warm up separately from timing trials; every invocation validates 0!..20!.
            json.loads(run([exe,min(options.iterations,100000),options.seed]))
        expected = expected_checksum(options.iterations,options.seed)
        order = list(samples)
        for trial in range(options.trials):
            random.Random(options.seed+trial).shuffle(order)
            for name in order:
                measured = json.loads(run([binaries[name],options.iterations,options.seed]))
                assert measured['checksum'] == expected, (name,measured['checksum'],expected)
                samples[name].append(measured['seconds'])
                checksums[name] = measured['checksum']
            print(f'trial {trial+1}/{options.trials}: checksums agree',flush=True)
        medians = {name:statistics.median(values) for name,values in samples.items()}
        report = {
            'timestamp_utc':datetime.now(timezone.utc).isoformat(),
            'kind':'local factorial runtime microbenchmark; not general performance or correctness proof',
            'platform':platform.platform(),'architecture':platform.machine(),'cpu_count':os.cpu_count(),
            'load_average':os.getloadavg(),'iterations_per_trial':options.iterations,'trials':options.trials,
            'input_domain':'varying n in 1..20; preflight checks 0!..20!', 'seed':options.seed,
            'measurement':'monotonic clock inside C caller; excludes startup/preflight; includes external call and input/checksum loop',
            'flags':['-O2','-fno-lto'], 'cc_version':run([cc,'--version']).strip(),
            'source_sha256':digest(source),'concrete_binary_sha256':digest(concrete),'lcb_binary_sha256':digest(lcb),
            'adapter_sha256':digest(ROOT/'Concrete/Backend/EmitQBE.lean'),
            'concrete_flake_lock_sha256':digest(ROOT/'flake.lock'),
            'qbe_version':lock['qbe']['version'],'qbe_source_commit':lock['qbe']['commit'],
            'qbe_archive_sha256':lock['qbe']['archive_sha256'],
            'input_ir_sha256':{'LLVM':digest(llvm_input),'QBE':digest(qbe_input)},
            'samples_seconds':samples,'median_seconds':medians,
            'min_seconds':{name:min(values) for name,values in samples.items()},
            'max_seconds':{name:max(values) for name,values in samples.items()},
            'relative_to_llvm':{name:value/medians['LLVM'] for name,value in medians.items()},
            'checksums':checksums,'single_build_wall_seconds_not_comparable_across_ir_scopes':build_times,
        }
    options.out.parent.mkdir(parents=True,exist_ok=True)
    options.out.write_text(json.dumps(report,indent=2)+'\n')
    for name in samples:
        print(f'{name}: {medians[name]*1000:.3f} ms median; {report["relative_to_llvm"][name]:.2f}x LLVM elapsed time')
    print(f'Raw measurements: {options.out}')


if __name__ == '__main__': main()
