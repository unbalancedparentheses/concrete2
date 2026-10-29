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
  .github/workflows/lean_action_ci.yml  the steps between each pair of markers
                                          # BEGIN GENERATED: gates <job> from <id> (...)
                                          # END GENERATED: gates <job>
                                        one `- name: <step>` / `run: <cmd>` step per gen=y row of <job>,
                                        in manifest order, starting at row <id> and running until a
                                        gen=n row of the job, the start of the job's next block, or
                                        the job's last row. Everything outside the markers is the
                                        workflow's own text and is never touched.

FAIL-CLOSED: an invalid manifest (wrong column line, wrong cell count, an empty cell, a duplicate id
or make target, a value outside a column's vocabulary, a spec key that is not live in
docs/spec/ids.tsv, rows out of order (workflow rows in workflow order, then the rest by id), a script
without a row, a step row whose job or step the workflow does not have or whose step does not run its
cmd, a gen=y row no block generates or that is not a plain one-command step, a make row whose cmd is not a plain
`bash`/`python3` invocation, a make target the Makefile also defines by hand, a Makefile that does not
include mk/gates.mk) is reported row by row and exits 1;
nothing is written. Unreadable inputs exit 2.

--root runs against another tree (the registration gate's negative controls use a planted copy).
The column vocabulary is documented in the manifest's header; this file enforces it.
"""
import argparse
import json
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
# Workflow block markers. They name no scripts/... .sh/.py path: run_ci_gates_local.sh extracts gate
# commands from the whole workflow text, comments included.
BEGIN_RE = re.compile(r"^( *)# BEGIN GENERATED: gates ([a-z0-9-]+) from ([a-z0-9-]+) \(.*\)$")
END_RE = re.compile(r"^ *# END GENERATED: gates ([a-z0-9-]+)$")

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
# A generated workflow step runs exactly one command: no list, pipe, redirection or substitution.
GEN_CMD_BAD = re.compile(r"[;&|<>`\n]|\$\(")


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


def yaml_mod():
    try:
        import yaml
    except ImportError:
        raise Refuse("pyyaml is not importable; run inside the gate shell (nix develop .#gates)")
    return yaml


def workflow_steps(text):
    """{job: [(step name, run text without comments)]} in workflow order, from the workflow text as
    it will be written (the YAML values GitHub shows)."""
    yaml = yaml_mod()
    try:
        wf = yaml.safe_load(text)
    except yaml.YAMLError as e:
        raise Refuse(f"{WORKFLOW} does not parse (after regenerating its blocks): {e}")
    out = {}
    for job, jd in (wf.get("jobs") or {}).items():
        out[job] = [(str(st.get("name", "")), uncommented(str(st["run"])))
                    for st in (jd or {}).get("steps") or []
                    if isinstance(st, dict) and st.get("run") is not None]
    return out


def yaml_scalar(value):
    """A plain scalar only when it starts with a letter and PyYAML reads it back unchanged, else a
    double-quoted one. The letter rule is for GitHub's YAML 1.2 parser, which PyYAML (YAML 1.1) does
    not speak: `1e3` or `0o17` are strings to PyYAML and numbers to 1.2. A name starting with a letter
    can still be a 1.1 keyword (yes, on, null), and those PyYAML does not read back as strings."""
    yaml = yaml_mod()
    try:
        plain = bool(re.match(r"[A-Za-z]", value)) and yaml.safe_load("k: " + value) == {"k": value}
    except yaml.YAMLError:
        plain = False
    return value if plain else json.dumps(value, ensure_ascii=False)


def render_workflow(root, rows):
    """(workflow text with every generated block rewritten, errors)."""
    lines = read(root, WORKFLOW).split("\n")
    errs = []
    byjob = {}
    for r in rows:
        if r["job"] != "-":
            byjob.setdefault(r["job"], []).append(r)
    starts = {}
    for ln in lines:
        m = BEGIN_RE.match(ln)
        if m:
            starts.setdefault(m.group(2), set()).add(m.group(3))
    used = {}
    out, i = [], 0
    while i < len(lines):
        m = BEGIN_RE.match(lines[i])
        if not m:
            if END_RE.match(lines[i]):
                errs.append(f"{WORKFLOW}:{i + 1}: END GENERATED with no BEGIN")
            out.append(lines[i]); i += 1
            continue
        ind, job, start = m.group(1), m.group(2), m.group(3)
        j = i + 1
        while j < len(lines) and not END_RE.match(lines[j]) and not BEGIN_RE.match(lines[j]):
            j += 1
        if j == len(lines) or BEGIN_RE.match(lines[j]) or END_RE.match(lines[j]).group(1) != job:
            raise Refuse(f"{WORKFLOW}:{i + 1}: BEGIN GENERATED gates {job} has no matching END GENERATED gates {job}")
        seq = byjob.get(job, [])
        k = next((n for n, r in enumerate(seq) if r["id"] == start), None)
        block = []
        if k is None:
            errs.append(f"{WORKFLOW}:{i + 1}: block starts at row '{start}', which is not a row of job {job}")
        elif seq[k]["gen"] != "y":
            errs.append(f"{WORKFLOW}:{i + 1}: block starts at row '{start}', which is gen=n")
        else:
            while k < len(seq) and seq[k]["gen"] == "y" and (not block or seq[k]["id"] not in starts[job]):
                block.append(seq[k]); k += 1
        content = []
        for r in block:
            if r["id"] in used:
                errs.append(f"row {r['id']} is generated by two blocks ({WORKFLOW}:{used[r['id']]} and :{i + 1})")
            used[r["id"]] = i + 1
            if content:
                content.append("")
            content += [f"{ind}- name: {yaml_scalar(r['step'])}", f"{ind}  run: {r['cmd']}"]
        out += [lines[i]] + content + [lines[j]]
        i = j + 1
    for r in rows:
        if r["gen"] == "y" and r["id"] not in used:
            errs.append(f"{MANIFEST}:{r['_line']} ({r['id']}): gen=y, but no generated block of job {r['job']} reaches it")
    return "\n".join(out), errs


def listed_scripts(root):
    out = []
    for d, rx in LISTED_DIRS:
        try:
            names = os.listdir(os.path.join(root, d))
        except OSError as e:
            raise Refuse(f"cannot list {d}: {e}")
        out += [f"{d}/{n}" for n in names if rx.match(n) and os.path.isfile(os.path.join(root, d, n))]
    return sorted(set(out))


def validate(root, rows, wf_text):
    errs = []
    spec = live_spec_ids(root)
    areas = area_vocab(root)
    # The hook's unconditional selections: unindented, uncommented `SEL+=(--first "<cmd>")` lines.
    # An indented one sits inside a conditional, and a commented one runs nothing.
    hook_first = set(re.findall(r'^SEL\+=\(--first "([^"]+)"\)[ \t]*$', read(root, HOOK), re.M))
    ids, targets, triples = {}, {}, set()
    for r in rows:
        at = f"{MANIFEST}:{r['_line']} ({r['id']})"
        if not ID_RE.match(r["id"]):
            errs.append(f"{at}: id must be lowercase letters, digits and '-'")
        if r["id"] in ids:
            errs.append(f"{at}: duplicate id (also line {ids[r['id']]})")
        ids.setdefault(r["id"], r["_line"])
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
        if r["gen"] == "y":
            if kind != "step":
                errs.append(f"{at}: gen=y generates a workflow step, so via must be step")
            elif GEN_CMD_BAD.search(r["cmd"]):
                errs.append(f"{at}: gen=y, but cmd is not one plain command (no ; & | < > ` $( or newline); keep the step hand-written")
            else:
                try:
                    plain = yaml_mod().safe_load("k: " + r["cmd"]) == {"k": r["cmd"]}
                except yaml_mod().YAMLError:
                    plain = False
                if not plain:
                    errs.append(f"{at}: gen=y, but cmd is not a plain YAML scalar; keep the step hand-written")
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
    wf = workflow_steps(wf_text)
    for r in rows:
        if r["via"].split(":", 1)[0] not in ("step", "ci-only"):
            continue
        at = f"{MANIFEST}:{r['_line']} ({r['id']})"
        if r["job"] not in wf:
            errs.append(f"{at}: the workflow has no job '{r['job']}'")
        elif r["step"] not in [n for n, _ in wf[r["job"]]]:
            errs.append(f"{at}: job '{r['job']}' has no step named '{r['step']}'")
        elif not any(r["cmd"] in run for n, run in wf[r["job"]] if n == r["step"]):
            errs.append(f"{at}: step '{r['step']}' of job '{r['job']}' does not run '{r['cmd']}'")
    # ORDER: the workflow's rows in workflow order (job, step, position of the cmd in the step), so a
    # generated block reads its steps straight off the manifest; the rest sorted by id.
    jobs = {j: n for n, j in enumerate(wf)}

    def key(r):
        if r["job"] == "-":
            return (1, 0, 0, 0, r["id"])
        for si, (n, run) in enumerate(wf.get(r["job"], [])):
            if n == r["step"] and r["cmd"] in run:
                return (0, jobs[r["job"]], si, run.index(r["cmd"]), r["id"])
        return (0, jobs.get(r["job"], len(jobs)), 1 << 30, 0, r["id"])
    want = sorted(rows, key=key)
    for got, exp in zip(rows, want):
        if got["id"] != exp["id"]:
            errs.append(f"{MANIFEST}:{got['_line']} ({got['id']}): out of order; '{exp['id']}' belongs here "
                        "(workflow rows in workflow job/step order, then the others by id)")
            break
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


def views(rows, wf_text):
    return {INVENTORY: render_inventory(rows), MK: render_mk(rows), WORKFLOW: wf_text}


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
        wf_text, wf_errs = render_workflow(root, rows)
        errs += wf_errs + validate(root, rows, wf_text)
        if errs:
            for e in errs:
                print(f"gates.py: {e}", file=sys.stderr)
            print(f"gates.py: {len(errs)} manifest error(s); nothing written", file=sys.stderr)
            return 1
        stale = []
        for rel, text in views(rows, wf_text).items():
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
