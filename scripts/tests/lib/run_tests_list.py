#!/usr/bin/env python3
"""run_tests.sh --list: the tests a mode runs, read from the suite's source without running anything.

  run_tests_list.py RUNNER SECTIONS MODE    one line per test: id, kind, section(s), mode

The suite is read structurally: its top-level `if section_active ...` blocks (and the unconditional
code between them), the statements inside each, and which statements are a single call of an
assertion helper with literal arguments. Such a call is one test, identified by the helper and its
first argument (`run_ok:fib.con`; a repeat gets `#2`, `#3` in run order). Any other run of
statements is one test named `script:<block>.<n>`. Blocks are named by their section (a repeated
section gets `.2`; unconditional code is `always.<n>`). The ids are the baseline the move of the
suite into data (tests/cases) is compared against.
"""
import os, re, subprocess, sys

KW_OPEN = {'if': 'if', 'for': 'loop', 'while': 'loop', 'until': 'loop', 'select': 'loop', 'case': 'case'}
KW_CLOSE = {'fi': 'if', 'done': 'loop', 'esac': 'case'}


def lex_lines(lines):
    """Per line: (code text with quoted content blanked, starts inside a string/substitution, heredoc body)."""
    out = []
    q = None
    hd = []
    in_hd = None
    paren = 0
    for raw in lines:
        if in_hd is not None:
            word, strip = in_hd
            t = raw.lstrip('\t') if strip else raw
            out.append(('', False, True))
            if t == word:
                in_hd = hd.pop(0) if hd else None
            continue
        starts_in_string = q is not None or paren > 0
        code = []
        i = 0
        n = len(raw)
        while i < n:
            c = raw[i]
            if q == "'":
                if c == "'":
                    q = None; code.append("'")
                else:
                    code.append(' ')
                i += 1; continue
            if q == '"':
                if c == '\\' and i + 1 < n:
                    code.append('  '); i += 2; continue
                if c == '"':
                    q = None; code.append('"')
                else:
                    code.append(' ')
                i += 1; continue
            if c == '\\' and i + 1 < n:
                code.append('  '); i += 2; continue
            if c == '#' and (i == 0 or raw[i - 1] in ' \t;&|('):
                break
            if c in "'\"":
                q = c; code.append(c); i += 1; continue
            if raw.startswith('<<<', i):
                code.append('<<<'); i += 3; continue
            m = re.match(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", raw[i:])
            if m:
                hd.append((m.group(3), m.group(1) == '-'))
                code.append(' ' * len(m.group(0))); i += len(m.group(0)); continue
            if raw.startswith('$(', i) and not raw.startswith('$((', i):
                paren += 1; code.append('$('); i += 2; continue
            if c == ')' and paren > 0:
                paren -= 1; code.append(')'); i += 1; continue
            code.append(c); i += 1
        out.append((''.join(code), starts_in_string, False))
        if hd and in_hd is None:
            in_hd = hd.pop(0)
    return out


def structure(lines):
    lx = lex_lines(lines)
    stack = []
    depths = []
    sections = []
    cur = None
    for idx, (code, in_str, in_hd) in enumerate(lx):
        depths.append(len(stack))
        if not in_hd and not in_str:
            code = re.sub(r'\b([A-Za-z_][A-Za-z0-9_:-]*)\s*\(\)', r'\1__FN', code)
            for seg in re.split(r'(?:;;|;|&&|\|\||\||\(|\bthen\b|\bdo\b|\belse\b)', code):
                w = seg.strip().split()
                if not w:
                    continue
                if stack and stack[-1] == 'case' and w[0] != 'esac' and ')' in seg:
                    seg = re.sub(r'^\s*\(?[^()]*\)', '', seg, count=1)
                    w = seg.strip().split()
                j = 0
                while j < len(w):
                    k = w[j]
                    if k in ('!', 'time', 'elif'):
                        j += 1; continue
                    if k in KW_OPEN:
                        stack.append(KW_OPEN[k])
                        if k in ('if', 'while', 'until'):
                            j += 1; continue
                        break
                    if k in KW_CLOSE:
                        if stack and stack[-1] == KW_CLOSE[k]:
                            stack.pop()
                        else:
                            raise SystemExit(f'line {idx + 1}: unbalanced {k} (stack {stack})')
                        break
                    if k == '{' or (k.endswith('__FN') and w[j + 1:j + 2] == ['{']):
                        stack.append('{')
                        break
                    if k == '}':
                        if stack and stack[-1] == '{':
                            stack.pop()
                        else:
                            raise SystemExit(f'line {idx + 1}: unbalanced }} (stack {stack})')
                        break
                    break
        if cur is None and depths[-1] == 0 and re.match(r'^if section_active .*; then\s*$', lines[idx]):
            cur = [lines[idx], idx]
        elif cur is not None and len(stack) == 0:
            sections.append((cur[0], cur[1], idx)); cur = None
    if stack:
        raise SystemExit(f'unbalanced at EOF: {stack}')
    return lx, depths, sections



ROW_HELPERS = {
    'run_ok': 'run-value', 'run_ok_O2': 'run-value', 'run_err': 'reject-diagnostic',
    'run_abort': 'trap', 'run_test': 'test-flag', 'policy_err': 'reject-diagnostic',
    'check_report': 'report', 'check_report_multi': 'report', 'ext_check': 'report',
    'norm_check': 'report', 'check_profile': 'profile', 'check_profile_multi': 'profile',
    'check_collection_tests': 'run-value',
}
NONTEST_HELPERS = {'echo', 'flush_jobs'}
BODY_START_RE = re.compile(r'^if section_active positive; then$')
SUMMARY_RE = re.compile(r'^# --- Summary ---$')


def section_names(cond):
    return re.findall(r'section_active ([A-Za-z0-9_-]+)', cond)


def blocks(lines):
    """[(name, sections or None for unconditional, header_idx or None, first_body_idx, end_idx_exclusive)]"""
    lx, depths, secs = structure(lines)
    start = next(i for i, l in enumerate(lines) if BODY_START_RE.match(l))
    end = next(i for i, l in enumerate(lines) if SUMMARY_RE.match(l))
    out, seen, pos, gap_n = [], {}, start, 0

    def name_for(secnames):
        base = '+'.join(secnames)
        seen[base] = seen.get(base, 0) + 1
        return base if seen[base] == 1 else f'{base}.{seen[base]}'
    for cond, a, b in secs:
        if a < start or b >= end:
            continue
        if a > pos:
            gap_n += 1
            out.append((f'always.{gap_n}', None, None, pos, a))
        sn = section_names(cond)
        out.append((name_for(sn), sn, a, a + 1, b))
        pos = b + 1
    if pos < end:
        gap_n += 1
        out.append((f'always.{gap_n}', None, None, pos, end))
    return lx, depths, out, start, end


def statements(lines, lx, depths, a, b, base_depth):
    """Split lines[a:b] into items: ('blank'|'comment', [idx]) or ('stmt', [idx...])."""
    items = []
    i = a
    while i < b:
        code, in_str, in_hd = lx[i]
        s = lines[i].strip()
        if depths[i] == base_depth and not in_str and not in_hd and (s == '' or s.startswith('#')):
            items.append(('blank' if s == '' else 'comment', [i])); i += 1; continue
        j = i + 1
        while j < b:
            cj, sj, hj = lx[j]
            prev = lines[j - 1]
            cont = re.search(r'(?<!\\)\\$', prev) and not lx[j - 1][2]
            if depths[j] > base_depth or sj or hj or cont:
                j += 1; continue
            break
        items.append(('stmt', list(range(i, j))))
        i = j
    return items


PURE_CODE_BAD = re.compile(r'[;&|<>()`*?\[\]{}~]')


def is_pure(lines, lx, idxs):
    """A single simple command whose only expansion is $TESTDIR (checked lexically)."""
    first = lines[idxs[0]].strip().split()
    if not first or first[0] not in ROW_HELPERS and first[0] not in NONTEST_HELPERS:
        return False
    for i in idxs:
        code, in_str, in_hd = lx[i]
        if in_hd:
            return False
        if PURE_CODE_BAD.search(code.replace('$(', '((')):
            return False
    text = '\n'.join(lines[i] for i in idxs)
    rest = re.sub(r'\$\{?TESTDIR\}?(?![A-Za-z0-9_])', '', text)
    if '$' in rest or '`' in rest:
        return False
    # a trailing comment after the command is not data
    if re.search(r'(^|\s)#', lx[idxs[-1]][0]):
        return False
    return True


def argv_of(stmts):
    """Exact argv of each pure statement, as bash expands it."""
    prog = ['TESTDIR=tests/programs',
            "_p() { printf '%s' \"$1\"; shift; for a in \"$@\"; do printf '\\037%s' \"$a\"; done; printf '\\036'; }"]
    for h in list(ROW_HELPERS) + list(NONTEST_HELPERS):
        prog.append(f'{h}() {{ _p {h} "$@"; }}')
    prog += stmts
    r = subprocess.run(['bash', '--noprofile', '--norc', '-c', '\n'.join(prog)], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'bash could not evaluate the pure statements: {r.stderr[:500]}')
    recs = r.stdout.split('\036')[:-1]
    if len(recs) != len(stmts):
        raise SystemExit(f'argv count {len(recs)} != statements {len(stmts)}')
    return [rec.split('\037') for rec in recs]


def analyse(path):
    lines = open(path).read().split('\n')
    lx, depths, bl, start, end = blocks(lines)
    plan = []          # per block: (name, sections, header, items) item = ('row', argv, idxs) | ('code', idxs) | ('comment'|'blank', idxs)
    pure_texts = []
    for name, sn, hdr, a, b in bl:
        base = 1 if sn is not None else 0
        items = []
        for kind, idxs in statements(lines, lx, depths, a, b, base):
            if kind == 'stmt' and is_pure(lines, lx, idxs):
                items.append(['row', None, idxs]); pure_texts.append('\n'.join(lines[i] for i in idxs))
            elif kind == 'stmt':
                items.append(['code', idxs])
            else:
                items.append([kind, idxs])
        plan.append([name, sn, hdr, a, b, items])
    argvs = argv_of(pure_texts)
    k = 0
    for blk in plan:
        for it in blk[5]:
            if it[0] == 'row':
                it[1] = argvs[k]; k += 1
    return lines, plan, start, end


def units(plan):
    """The listed tests, in run order: (id, kind, block, sections). Comments, blank lines, echo and
    flush_jobs are not tests; consecutive code statements (with the comments between them) form one
    script unit."""
    out, counts = [], {}
    for name, sn, hdr, a, b, items in plan:
        secs = ','.join(sn) if sn else '*'
        chunk = 0
        prev_code = False
        for it in items:
            if it[0] == 'row':
                prev_code = False
                h = it[1][0]
                if h in NONTEST_HELPERS:
                    continue
                arg1 = it[1][1] if len(it[1]) > 1 else ''
                base = f'{h}:{arg1.replace("tests/programs/", "", 1)}'
                counts[base] = counts.get(base, 0) + 1
                tid = base if counts[base] == 1 else f'{base}#{counts[base]}'
                out.append((tid, ROW_HELPERS[h], name, secs))
            elif it[0] == 'code':
                if not prev_code:
                    chunk += 1
                    kind = 'gate-fixture' if name.startswith('gatesmoke') else 'script'
                    out.append((f'script:{name}.{chunk}', kind, name, secs))
                prev_code = True
            # comments and blank lines neither start nor end a script unit
    return out




if __name__ == '__main__':
    runner, active, mode = sys.argv[1], sys.argv[2], sys.argv[3]
    act = set(a for a in active.split(',') if a)
    _lines, plan, _s, _e = analyse(runner)
    for tid, kind, blk, secs in units(plan):
        if secs == '*' or act & set(secs.split(',')):
            print(f'{tid}\t{kind}\t{secs}\t{mode}')
