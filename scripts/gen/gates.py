#!/usr/bin/env python3
"""Generate the gate views from the gate manifest, scripts/tests/gates.tsv.

  gates.py --write      validate the manifest (workflow included), then rewrite every generated view
  gates.py --check      validate the manifest and exit 1 when a generated view differs from what it
                        would generate (stale or hand-edited); check_gate_registration.sh runs this
  gates.py --list-via   print "<script path>\t<via>" for every row (the registration gate's
                        reachability walk cross-checks it)

Generated views:
  scripts/tests/ci_gate_inventory.txt   the cmd of every via=step row, LC_ALL=C sorted, unique
  mk/gates.mk                           a .PHONY make target for every row with a `make` cell
                                        (included from the Makefile): `<make>: [build] ## <claim>` running
                                        `$(NIX_DEVELOP[_PROVERS]) <cmd>`, the script spelled ./scripts/

FAIL-CLOSED: an invalid manifest (wrong column line, wrong cell count, an empty cell, a duplicate id
or make target, a value outside a column's vocabulary, a spec key that is not live in
docs/spec/ids.tsv, rows out of id order, a script without a row, a step row whose job or step the
workflow does not have or whose step does not run its cmd, a make row whose cmd is not a plain
`bash`/`python3` invocation, a make target the Makefile also defines by hand, a Makefile that does not
include mk/gates.mk) is reported row by row and exits 1;
nothing is written. Unreadable inputs exit 2.

--root runs against another tree (the registration gate's negative controls use a planted copy).
The column vocabulary is documented in the manifest's header; this file enforces it.
"""
import argparse
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
MANIFEST = "scripts/tests/gates.tsv"
INVENTORY = "scripts/tests/ci_gate_inventory.txt"
WORKFLOW = ".github/workflows/lean_action_ci.yml"
HOOK = ".githooks/pre-push"
SPEC_IDS = "docs/spec/ids.tsv"
AREA_MAP = "docs/bugs/area_map.tsv"
MAKEFILE = "Makefile"
MK = "mk/gates.mk"
MK_INCLUDE = "include mk/gates.mk"

COLS = ["id", "cmd", "job", "step", "via", "area", "owner", "claim", "tier", "spec", "make",
        "shell", "build", "gen", "kind"]
TIERS = {"prepush", "pr", "campaign", "weekly", "manual", "skip"}
SHELLS = {"gates", "provers"}
YN = {"y", "n"}
KINDS = {"-"}  # test-suite kinds arrive with the test-suite rows (a later slice)
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
TARGET_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
SCRIPT_RE = re.compile(r"(?:\./)?(scripts/[A-Za-z0-9_./-]+\.(?:sh|py))(?=$|[\s\"'])")
VIA_RE = re.compile(r"^(step|ci-only:.+|agg:[A-Za-z0-9_.-]+\.(?:sh|py)|tool:[A-Za-z0-9_.-]+\.(?:sh|py)|skip:.+)$")
# Every script of these shapes must have a row (the unlisted-script rule).
LISTED_DIRS = [("scripts/tests", re.compile(r"^(check|test|run)_[A-Za-z0-9_]+\.sh$")),
               ("scripts/tests", re.compile(r"^check_[A-Za-z0-9_]+\.py$")),
               ("scripts/ci", re.compile(r"^[A-Za-z0-9_]+\.sh$"))]
AGG_DIRS = ["scripts/tests", "scripts/ci", "scripts/gen"]
# A make row's cmd: optional VAR=value words, then bash or python3 and the script. Its recipe spells
# the script ./scripts/... (the Makefile's form; the workflow's steps mostly omit the ./).
MAKE_CMD_RE = re.compile(r"^((?:[A-Z_][A-Z0-9_]*=\S+\s+)*)(bash|python3) (?:\./)?(scripts/\S+)(.*)$")
DEVSHELL_VAR = {"gates": "NIX_DEVELOP", "provers": "NIX_DEVELOP_PROVERS"}


class Refuse(Exception):
    pass


def read(root, rel):
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        raise Refuse(f"cannot read {rel}: {e}")


def load(root):
    lines = read(root, MANIFEST).split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    body = [(n, ln) for n, ln in enumerate(lines, 1) if not ln.startswith("#")]
    errs = []
    if not body or body[0][1].split("\t") != COLS:
        raise Refuse(f"{MANIFEST}: the column line must be exactly: {' '.join(COLS)} (tab-separated)")
    rows = []
    for n, ln in body[1:]:
        cells = ln.split("\t")
        if len(cells) != len(COLS):
            errs.append(f"{MANIFEST}:{n}: {len(cells)} cells, expected {len(COLS)}")
            continue
        r = dict(zip(COLS, cells))
        r["_line"] = n
        empty = [k for k in COLS if not r[k].strip() or r[k] != r[k].strip()]
        if empty:
            errs.append(f"{MANIFEST}:{n}: empty or space-padded cell(s) {', '.join(empty)} (use - for none)")
            continue
        rows.append(r)
    return rows, errs


def script_of(cmd):
    found = SCRIPT_RE.findall(cmd)
    return found[0] if len(set(found)) == 1 else None


def live_spec_ids(root):
    ids = set()
    for ln in read(root, SPEC_IDS).split("\n"):
        if ln and not ln.startswith("#"):
            c = ln.split("\t")
            if len(c) >= 2 and c[1] == "live":
                ids.add(c[0])
    return ids


def area_vocab(root):
    """The stage column's vocabulary, read from area_map.tsv's header (its one owner)."""
    lines = read(root, AREA_MAP).split("\n")
    for i, ln in enumerate(lines):
        if re.match(r"^#\s+stage\s", ln):
            text = ln.split("stage", 1)[1]
            j = i + 1
            while ", or" not in text and j < len(lines) and re.match(r"^#\s{6,}\S", lines[j]):
                text += " " + lines[j].lstrip("#")
                j += 1
            words = re.findall(r"[A-Z][A-Za-z]+", text.split(", or")[0])
            if words:
                return set(words)
    raise Refuse(f"{AREA_MAP}: the stage vocabulary line (#   stage ...) is missing")


def uncommented(text):
    """Shell text without its comments: a '#' that starts a word ends the line (`.#provers` stays).
    A command named only in a comment is not run, so it must not satisfy a step row."""
    return "\n".join(re.sub(r"(^|\s)#.*$", r"\1", ln) for ln in text.split("\n"))


def workflow_steps(root):
    """{job: {step name: [run text without comments]}} from the workflow (the YAML values GitHub shows)."""
    try:
        import yaml
    except ImportError:
        raise Refuse("pyyaml is not importable; run inside the gate shell (nix develop .#gates)")
    try:
        wf = yaml.safe_load(read(root, WORKFLOW))
    except yaml.YAMLError as e:
        raise Refuse(f"{WORKFLOW} does not parse: {e}")
    out = {}
    for job, jd in (wf.get("jobs") or {}).items():
        steps = {}
        for st in (jd or {}).get("steps") or []:
            if isinstance(st, dict) and st.get("run") is not None:
                steps.setdefault(str(st.get("name", "")), []).append(uncommented(str(st["run"])))
        out[job] = steps
    return out


def listed_scripts(root):
    out = []
    for d, rx in LISTED_DIRS:
        try:
            names = os.listdir(os.path.join(root, d))
        except OSError as e:
            raise Refuse(f"cannot list {d}: {e}")
        out += [f"{d}/{n}" for n in names if rx.match(n) and os.path.isfile(os.path.join(root, d, n))]
    return sorted(set(out))


def validate(root, rows, with_workflow):
    errs = []
    spec = live_spec_ids(root)
    areas = area_vocab(root)
    # The hook's unconditional selections: unindented, uncommented `SEL+=(--first "<cmd>")` lines.
    # An indented one sits inside a conditional, and a commented one runs nothing.
    hook_first = set(re.findall(r'^SEL\+=\(--first "([^"]+)"\)[ \t]*$', read(root, HOOK), re.M))
    ids, targets, triples = {}, {}, set()
    prev = None
    for r in rows:
        at = f"{MANIFEST}:{r['_line']} ({r['id']})"
        if not ID_RE.match(r["id"]):
            errs.append(f"{at}: id must be lowercase letters, digits and '-'")
        if r["id"] in ids:
            errs.append(f"{at}: duplicate id (also line {ids[r['id']]})")
        ids.setdefault(r["id"], r["_line"])
        if prev is not None and r["id"] < prev:
            errs.append(f"{at}: rows are not sorted by id (LC_ALL=C); '{r['id']}' follows '{prev}'")
        prev = r["id"]
        s = script_of(r["cmd"])
        if s is None:
            errs.append(f"{at}: cmd must name exactly one scripts/... .sh or .py file")
        elif not os.path.isfile(os.path.join(root, s)):
            errs.append(f"{at}: cmd names {s}, which does not exist")
        via = r["via"]
        if not VIA_RE.match(via):
            errs.append(f"{at}: via '{via}' is not step | ci-only:<reason> | agg:<script> | tool:<script> | skip:<reason>")
        kind = via.split(":", 1)[0]
        if kind in ("step", "ci-only"):
            if r["job"] == "-" or r["step"] == "-":
                errs.append(f"{at}: via={kind} needs the workflow job and step")
            key = (r["cmd"], r["job"], r["step"])
            if key in triples:
                errs.append(f"{at}: duplicate (cmd, job, step)")
            triples.add(key)
        elif r["job"] != "-" or r["step"] != "-":
            errs.append(f"{at}: via={kind} is not a workflow step, so job and step must be -")
        if kind == "agg":
            name = via.split(":", 1)[1]
            if not any(os.path.isfile(os.path.join(root, d, name)) for d in AGG_DIRS):
                errs.append(f"{at}: via names aggregator {name}, which is not in {', '.join(AGG_DIRS)}")
        if kind == "tool" and not os.path.isfile(os.path.join(root, "scripts/tools", via.split(":", 1)[1])):
            errs.append(f"{at}: via names tool {via.split(':', 1)[1]}, which is not in scripts/tools")
        if r["area"] != "-" and r["area"] not in areas:
            errs.append(f"{at}: area '{r['area']}' is not a stage of {AREA_MAP}")
        tier = r["tier"]
        if tier not in TIERS:
            errs.append(f"{at}: tier '{tier}' is not one of {' '.join(sorted(TIERS))}")
        if tier == "skip" and kind != "skip":
            errs.append(f"{at}: tier skip needs via=skip:<reason>")
        if kind == "skip" and tier in ("prepush", "pr"):
            errs.append(f"{at}: a via=skip row cannot be tier {tier} (CI never runs it)")
        if kind == "ci-only" and tier != "campaign":
            errs.append(f"{at}: a ci-only step runs only in the campaign tier; tier must be campaign")
        if tier == "prepush" and r["cmd"] not in hook_first:
            errs.append(f"{at}: tier prepush, but {HOOK} has no unconditional line SEL+=(--first \"{r['cmd']}\")")
        if r["spec"] != "-":
            for k in r["spec"].split(","):
                if k not in spec:
                    errs.append(f"{at}: spec key '{k}' is not live in {SPEC_IDS}")
        if r["make"] != "-":
            if not TARGET_RE.match(r["make"]):
                errs.append(f"{at}: make target '{r['make']}' is not a plain target name")
            if r["make"] in targets:
                errs.append(f"{at}: make target '{r['make']}' is also on line {targets[r['make']]}")
            targets.setdefault(r["make"], r["_line"])
        if r["shell"] not in SHELLS:
            errs.append(f"{at}: shell '{r['shell']}' is not one of {' '.join(sorted(SHELLS))}")
        for c in ("build", "gen"):
            if r[c] not in YN:
                errs.append(f"{at}: {c} must be y or n")
        if r["kind"] not in KINDS:
            errs.append(f"{at}: kind '{r['kind']}' is not one of {' '.join(sorted(KINDS))}")
    hand = set(re.findall(r"^([A-Za-z0-9_.-]+)\s*:(?!=)", read(root, MAKEFILE), re.M))
    if MK_INCLUDE not in read(root, MAKEFILE).split("\n"):
        errs.append(f"{MAKEFILE} does not have the line '{MK_INCLUDE}'; the generated gate targets would not exist")
    for r in rows:
        if r["make"] == "-":
            continue
        at = f"{MANIFEST}:{r['_line']} ({r['id']})"
        if not MAKE_CMD_RE.match(r["cmd"]):
            errs.append(f"{at}: make target {r['make']}: cmd is not 'bash|python3 [./]scripts/...', so no recipe is generated for it")
        if r["make"] in hand:
            errs.append(f"{at}: make target {r['make']} is also written by hand in {MAKEFILE}; remove one")
        if "##" in r["claim"]:
            errs.append(f"{at}: claim of a make row cannot contain '##' (it is the target's ## help text)")
    covered = {script_of(r["cmd"]) for r in rows}
    for s in listed_scripts(root):
        if s not in covered:
            errs.append(f"{s} has no row in {MANIFEST}: add one (a gate nobody lists is a gate nobody runs)")
    if with_workflow:
        wf = workflow_steps(root)
        for r in rows:
            if r["via"].split(":", 1)[0] not in ("step", "ci-only"):
                continue
            at = f"{MANIFEST}:{r['_line']} ({r['id']})"
            if r["job"] not in wf:
                errs.append(f"{at}: the workflow has no job '{r['job']}'")
            elif r["step"] not in wf[r["job"]]:
                errs.append(f"{at}: job '{r['job']}' has no step named '{r['step']}'")
            elif not any(r["cmd"] in run for run in wf[r["job"]][r["step"]]):
                errs.append(f"{at}: step '{r['step']}' of job '{r['job']}' does not run '{r['cmd']}'")
    return errs


def render_inventory(rows):
    cmds = sorted({r["cmd"] for r in rows if r["via"] == "step"})
    return "".join(c + "\n" for c in cmds)


def recipe(r):
    m = MAKE_CMD_RE.match(r["cmd"])
    return f"$({DEVSHELL_VAR[r['shell']]}) {m.group(1)}{m.group(2)} ./{m.group(3)}{m.group(4)}"


def render_mk(rows):
    out = [f"# GENERATED from {MANIFEST} by scripts/gen/gates.py; do not edit. Change a row's make, claim,",
           "# build, shell or cmd cell and run: python3 scripts/gen/gates.py --write. The Makefile includes this",
           "# file; `make help` lists these targets under the heading below.",
           "",
           f"##@ Gates (generated from {MANIFEST})",
           ""]
    for r in sorted((r for r in rows if r["make"] != "-"), key=lambda r: r["make"]):
        pre = " build" if r["build"] == "y" else ""
        out += [f".PHONY: {r['make']}", f"{r['make']}:{pre} ## {r['claim']}", "\t" + recipe(r), ""]
    return "\n".join(out)


def views(rows):
    return {INVENTORY: render_inventory(rows), MK: render_mk(rows)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true")
    g.add_argument("--check", action="store_true")
    g.add_argument("--list-via", action="store_true")
    ap.add_argument("--root", default=ROOT)
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    try:
        rows, errs = load(root)
        if a.list_via:
            for r in rows:
                print(f"{script_of(r['cmd']) or '-'}\t{r['via']}")
            return 1 if errs else 0
        errs += validate(root, rows, with_workflow=True)
        if errs:
            for e in errs:
                print(f"gates.py: {e}", file=sys.stderr)
            print(f"gates.py: {len(errs)} manifest error(s); nothing written", file=sys.stderr)
            return 1
        stale = []
        for rel, text in views(rows).items():
            path = os.path.join(root, rel)
            try:
                cur = open(path, encoding="utf-8").read()
            except OSError:
                cur = None
            if cur == text:
                continue
            if a.write:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text)
                print(f"gates.py: wrote {rel}")
            else:
                stale.append(rel)
        for rel in stale:
            print(f"gates.py: {rel} is stale or hand-edited; run python3 scripts/gen/gates.py --write", file=sys.stderr)
        return 1 if stale else 0
    except Refuse as e:
        print(f"gates.py: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
