#!/usr/bin/env python3
"""The dead-code ratchet: compare the compiler's unreachable declarations with the baseline.

Input is the inventory scripts/tools/dead_code_inventory.lean prints from the elaborated
environment (decl, kind, module, line, reached-without-allowlist, reached-with-allowlist), one
file per walk (the gate runs two: Main and Concrete.Pipeline.PipelineTest both declare `main`).
A declaration is reachable when ANY walk reaches it. Data:

  docs/compiler/dead_code_baseline.tsv   every known unreachable compiler declaration, with the
                                         reason it is still there; it may only shrink
  docs/compiler/dead_code_allowlist.tsv  declarations referenced only BY NAME from outside the
                                         Lean environment (a script greps `def X`, generated Lean
                                         text names it): live by declaration, with the file that
                                         references them

Commands:
  roots                       print the identifiers the environment cannot show as references:
                              the text of `#guard` / `#eval` / `#check` / `#print` / `#reduce` /
                              `example` commands in the Lean libraries (commands leave no
                              declaration behind), and every Lean file outside the libraries
                              (scripts/**/*.lean, which import the compiler). The inventory tool takes them as roots.
  allow-names                 print the allowlist's declaration names (the tool's --allow input)
  check --walk F [--walk F]... [--base-baseline FILE]
                              exit 1 on any finding (the gate):
                                an unreachable declaration not in the baseline (NEW dead code);
                                a baseline row now reachable or gone (delete it: shrink only);
                                a baseline row the base revision's baseline lacks (ADDED);
                                an allowlist row whose declaration is reachable without it, does
                                not exist, or whose file does not mention its name;
                                two declarations with one key (decl, file).
  generate --walk F [--walk F]...
                              rewrite the baseline from the inventory; an existing row keeps its
                              reason, a new row gets `unreviewed`. Use it to seed or to SHRINK the
                              baseline; the diff is reviewed.
  seed-allow --walk F [--walk F]...
                              print candidate allowlist rows: each unreachable declaration whose
                              short name occurs as a word in scripts/, tests/ or a string literal
                              of a compiler source. A candidate is a lead for review, not a verdict.
"""
import argparse
import collections
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASELINE = "docs/compiler/dead_code_baseline.tsv"
ALLOWLIST = "docs/compiler/dead_code_allowlist.tsv"
BASE_HEADER = ["decl", "kind", "file", "reason"]
ALLOW_HEADER = ["decl", "file", "reason"]

# A reason is `unreviewed` (seeded, pending review), `dead` (reviewed: remove it), or
# `keep: <why>` (reviewed: kept on purpose, e.g. an API a VERIFIED_PIPELINE step plans to use).
REASON = re.compile(r"^(unreviewed|dead|keep: .+)$")

COMMAND = re.compile(r"^\s*(?:@\[[^\]]*\]\s*)?(?:#guard_msgs\b.*\bin\s*)?(#guard|#eval|#check|#print|#reduce|example)\b")
IDENT = re.compile(r"[A-Za-z_α-ω][A-Za-z0-9_'!?₀-₉]*")


def git_ls(*patterns):
    out = subprocess.run(["git", "ls-files", *patterns], cwd=ROOT, capture_output=True, text=True,
                         check=True).stdout
    return [l for l in out.split("\n") if l]


def lib_sources():
    return git_ls("Concrete.lean", "Concrete/*.lean", "Main.lean", "Browser.lean", "proofs/*.lean")


def outside_sources():
    lib = set(lib_sources())
    return [f for f in git_ls("*.lean") if f not in lib]


def command_texts(text):
    """The text of each top-level command the environment does not keep: from its first line to
    the next line that starts in column 0 (the next command)."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        if COMMAND.match(lines[i]):
            j = i + 1
            while j < len(lines) and (lines[j] == "" or lines[j][0].isspace()):
                j += 1
            yield "\n".join(lines[i:j])
            i = j
        else:
            i += 1


def strip_comments(text):
    text = re.sub(r"/-.*?-/", " ", text, flags=re.S)
    return re.sub(r"--[^\n]*", " ", text)


def cmd_roots(_args):
    words = set()
    for f in lib_sources():
        with open(os.path.join(ROOT, f)) as fh:
            for cmd in command_texts(strip_comments(fh.read())):
                words.update(IDENT.findall(cmd))
    for f in outside_sources():
        with open(os.path.join(ROOT, f)) as fh:
            words.update(IDENT.findall(fh.read()))
    for w in sorted(words):
        print(w)
    return 0


def read_tsv(path, header):
    rows = []
    full = path if os.path.isabs(path) else os.path.join(ROOT, path)
    with open(full) as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != len(header):
                raise SystemExit(f"{path}:{lineno}: expected {len(header)} tab-separated columns, got {len(cols)}")
            if cols == header:
                continue
            rows.append(cols)
    return rows


def header_lines(path):
    out = []
    with open(os.path.join(ROOT, path)) as f:
        for line in f:
            if line.startswith("#"):
                out.append(line.rstrip("\n"))
            else:
                break
    return out


def module_file(module):
    return module.replace(".", "/") + ".lean"


def load_walks(paths):
    """Merge the walks: one row per (decl, file); reachable if any walk reaches it.
    Two declarations of one walk with one key (generated, private or macro-scoped names) merge
    harmlessly while all are reachable without the allowlist; when one is not, the key cannot say
    which (and an allowlist row naming the key would root both), so it is returned in `dup` and the
    check refuses it."""
    rows = {}
    dup = set()
    for p in paths:
        seen_here = collections.defaultdict(list)
        with open(p) as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                cols = line.split("\t")
                if len(cols) != 6:
                    raise SystemExit(f"inventory {p}: malformed row {line!r}")
                decl, kind, module, lineno, r0, r1 = cols
                k = (decl, module_file(module))
                seen_here[k].append(r0 == "1")
                if k in rows:
                    old = rows[k]
                    old["r0"] |= r0 == "1"
                    old["r1"] |= r1 == "1"
                else:
                    rows[k] = {"decl": decl, "kind": kind, "file": k[1], "line": int(lineno),
                               "r0": r0 == "1", "r1": r1 == "1"}
        dup |= {k for k, rs in seen_here.items() if len(rs) > 1 and not all(rs)}
    return rows, sorted(dup)


def mentions(path, name):
    try:
        with open(os.path.join(ROOT, path)) as f:
            text = f.read()
    except OSError:
        return False
    return re.search(r"(?<![A-Za-z0-9_'])" + re.escape(name) + r"(?![A-Za-z0-9_'!?])", text) is not None


def short(decl):
    return decl.split(".")[-1]


def cmd_check(args):
    inv, dup = load_walks(args.walk)
    base = read_tsv(args.baseline or BASELINE, BASE_HEADER)
    allow = read_tsv(args.allowlist or ALLOWLIST, ALLOW_HEADER)
    fails = []
    for k in dup:
        fails.append(f"two declarations of {k[1]} share the name {k[0]} once private prefixes and macro "
                     f"scopes are removed; the baseline cannot tell them apart. Rename one.")

    base_keys = {}
    for decl, kind, path, reason in base:
        k = (decl, path)
        if k in base_keys:
            fails.append(f"baseline lists {decl} ({path}) twice")
        base_keys[k] = (decl, kind, path, reason)
        if not REASON.match(reason):
            fails.append(f"baseline row {decl}: reason {reason!r} is not `unreviewed`, `dead` or `keep: <why>`")

    allow_keys = {}
    tracked = set(git_ls("scripts", "tests"))
    by_decl = collections.defaultdict(list)
    for r in inv.values():
        by_decl[r["decl"]].append(r)
    for decl, path, reason in allow:
        if decl in allow_keys:
            fails.append(f"allowlist lists {decl} twice")
        allow_keys[decl] = (decl, path, reason)
        if not reason.strip() or reason == "-":
            fails.append(f"allowlist row {decl}: give the reason it is referenced by name")
        found = by_decl.get(decl, [])
        if not found:
            fails.append(f"allowlist row {decl}: no such compiler declaration (renamed or deleted: update {ALLOWLIST})")
            continue
        if len(found) > 1:
            fails.append(f"allowlist row {decl} names {len(found)} declarations "
                         f"({', '.join(r['file'] for r in found)}); a root by name would keep all of them. Rename one.")
        if all(r["r0"] for r in found):
            fails.append(f"allowlist row {decl} is reachable without the allowlist: delete the row, so the "
                         f"allowlist only holds what the environment cannot see")
        if (os.path.normpath(path) != path or not path.startswith(("scripts/", "tests/"))
                or path.startswith("scripts/tools/dead_code") or path not in tracked):
            fails.append(f"allowlist row {decl}: {path} is not a script or test; only a reference the Lean "
                         f"environment cannot see (a gate, a generator, a test) is a reason to allowlist")
        elif not mentions(path, short(decl)):
            fails.append(f"allowlist row {decl}: {path} does not mention {short(decl)!r}, so nothing references "
                         f"it by name there")
        if any((decl, r["file"]) in base_keys for r in found):
            fails.append(f"{decl} is both allowlisted (live) and in the baseline (dead)")

    unreachable = sorted((r for r in inv.values() if not r["r1"]), key=lambda r: (r["file"], r["decl"]))
    for r in unreachable:
        k = (r["decl"], r["file"])
        if k not in base_keys:
            fails.append(f"NEW unreachable declaration: {r['kind']} {r['decl']} ({r['file']}:{r['line']}). "
                         f"Use it, delete it, or (if a script or generated text names it) allowlist it in "
                         f"{ALLOWLIST}; the baseline only shrinks.")
        elif base_keys[k][1] != r["kind"]:
            fails.append(f"baseline row {r['decl']}: kind {base_keys[k][1]!r}, inventory says {r['kind']!r}")
    for k, row in base_keys.items():
        r = inv.get(k)
        if r is None:
            fails.append(f"baseline row {row[0]} ({row[2]}) no longer exists: delete the row")
        elif r["r1"]:
            fails.append(f"baseline row {row[0]} ({row[2]}) is reachable now: delete the row, so the baseline "
                         f"only shrinks")

    if args.base_baseline:
        before = set()
        if os.path.getsize(args.base_baseline):
            before = {(r[0], r[2]) for r in read_tsv(os.path.abspath(args.base_baseline), BASE_HEADER)}
        for k, row in base_keys.items():
            if k not in before:
                fails.append(f"baseline row ADDED: {row[0]} ({row[2]}) is not in the base revision's baseline. "
                             f"The baseline only shrinks; delete the declaration instead")

    for f in fails:
        print(f"  FAIL {f}")
    reasons = collections.Counter(r[3].split(":")[0] for r in base)
    print(f"DEAD-CODE: {len(inv)} declarations, {len(unreachable)} unreachable, baseline {len(base)} rows "
          f"({', '.join(f'{k} {v}' for k, v in sorted(reasons.items()))}), allowlist {len(allow)} rows")
    return 1 if fails else 0


def cmd_generate(args):
    inv, _ = load_walks(args.walk)
    if not inv:
        raise SystemExit("refusing to generate from an empty inventory (did the inventory tool fail?)")
    old = {(r[0], r[2]): r for r in read_tsv(BASELINE, BASE_HEADER)} if os.path.exists(
        os.path.join(ROOT, BASELINE)) else {}
    heads = header_lines(BASELINE) if os.path.exists(os.path.join(ROOT, BASELINE)) else []
    rows = []
    for r in inv.values():
        if r["r1"]:
            continue
        k = (r["decl"], r["file"])
        rows.append([r["decl"], r["kind"], r["file"], old[k][3] if k in old else "unreviewed"])
    rows.sort(key=lambda r: (r[2], r[0]))
    with open(os.path.join(ROOT, BASELINE), "w") as f:
        for line in heads:
            f.write(line + "\n")
        f.write("\t".join(BASE_HEADER) + "\n")
        for r in rows:
            f.write("\t".join(r) + "\n")
    print(f"wrote {BASELINE}: {len(rows)} rows")
    return 0


def cmd_allow_names(_args):
    for r in read_tsv(ALLOWLIST, ALLOW_HEADER):
        print(r[0])
    return 0


def cmd_seed_allow(args):
    inv, _ = load_walks(args.walk)
    files = [f for f in git_ls("scripts", "tests") if not f.endswith((".con", ".golden", ".out", ".expected"))]
    lib = git_ls("Concrete.lean", "Concrete/*.lean", "Main.lean", "Browser.lean")
    texts = {}
    for f in files:
        try:
            with open(os.path.join(ROOT, f), errors="replace") as fh:
                texts[f] = fh.read()
        except OSError:
            pass
    for f in lib:
        with open(os.path.join(ROOT, f)) as fh:
            texts[f] = "\n".join(re.findall(r'"(?:[^"\\\n]|\\.)*"', fh.read()))
    for r in sorted(inv.values(), key=lambda r: (r["file"], r["decl"])):
        if r["r0"]:
            continue
        name = short(r["decl"])
        pat = re.compile(r"(?<![A-Za-z0-9_'])" + re.escape(name) + r"(?![A-Za-z0-9_'!?])")
        hits = [f for f, t in texts.items() if pat.search(t)]
        if hits:
            print(f"{r['decl']}\t{hits[0]}\t{len(hits)} files: {' '.join(hits[:4])}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["roots", "allow-names", "check", "generate", "seed-allow"])
    ap.add_argument("--walk", action="append", default=[])
    ap.add_argument("--base-baseline")
    ap.add_argument("--baseline", help="check: read this baseline instead (the gate's negative controls)")
    ap.add_argument("--allowlist", help="check: read this allowlist instead (the gate's negative controls)")
    args = ap.parse_args()
    if args.command in ("check", "generate", "seed-allow") and not args.walk:
        ap.error("--walk is required")
    return {"roots": cmd_roots, "allow-names": cmd_allow_names, "check": cmd_check,
            "generate": cmd_generate, "seed-allow": cmd_seed_allow}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
