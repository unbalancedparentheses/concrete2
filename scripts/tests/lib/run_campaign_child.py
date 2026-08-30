#!/usr/bin/env python3
"""Launch the campaign child in its own session, and report whether its process group emptied.

PROCESS IDENTITY BY CONSTRUCTION, NOT BY PATTERN.

The supervisor must know that nothing from the campaign is still running before it publishes a
verdict, because evidence written after the census would be described by an artifact that never saw
it. Three earlier attempts asked the wrong question:

  * `pgrep -P $$` sees one generation, and the campaign child has already been reaped by then, so a
    surviving grandchild is reparented away and never appears.
  * matching command lines for the repository path also matched the LAUNCHER that started the run.
  * matching them for the workspace path also matched the supervisor itself, which literally runs
    `bash /tmp/concrete-mut.<pid>.../driver.sh` — and any shell whose command line merely CONTAINED
    the search string.

All three refused clean runs. A check that always fires carries no more information than one that
never does.

The fourth attempt used /proc ancestry, which is correct on Linux and ABSENT on macOS. This
repository has already taken a macOS outage from /proc/self/exe; putting /proc in the path that
decides qualification would reintroduce that defect exactly where it does the most damage.

So the child is launched into a NEW SESSION. Its process group id equals its pid, the supervisor and
every ancestor are outside that group by construction, and "is any campaign work still running" is
answered by asking the kernel whether that group still has members — `killpg(pgid, 0)`. No pattern,
no exclusion list, and nothing that depends on how a worker spells its command line: a process that
rewrites argv is still in the group, and an unrelated process with a similar name never was.

POSIX, so it behaves the same on Linux and macOS.

Usage:
    run_campaign_child.py --report <path> -- <command> [args...]

The report goes to <path>, NOT to stdout: the child's stdout and stderr are inherited untouched,
because they are the campaign transcript and a launcher that swallowed them would destroy the
evidence it exists to protect.

Report fields, one per line:
    child_rc=<int>       the child's exit status
    group_empty=<0|1>    1 iff no member of the child's process group survives
    pgid=<int>           the group that was checked, for diagnostics
"""
import os
import signal
import subprocess
import sys


def group_is_empty(pgid: int) -> bool:
    """True iff no process remains in `pgid`.

    Signal 0 performs the permission and existence checks without delivering anything. ESRCH means
    the group is gone; EPERM means it exists but is not ours to signal, which is still ALIVE and
    must not be read as empty — a permission error is not evidence of absence.
    """
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def main() -> int:
    argv = sys.argv[1:]
    if len(argv) < 4 or argv[0] != "--report" or argv[2] != "--":
        print("usage: run_campaign_child.py --report <path> -- <command> [args...]", file=sys.stderr)
        return 2
    report_path, cmd = argv[1], argv[3:]

    # start_new_session=True calls setsid() in the child: it becomes session and group leader, so its
    # pgid is its pid and no ancestor shares the group.
    proc = subprocess.Popen(cmd, start_new_session=True)
    pgid = proc.pid

    try:
        child_rc = proc.wait()
    except KeyboardInterrupt:
        # Interruption must not leave the group running behind a supervisor that has stopped
        # watching it; the caller still learns the group was not clean.
        try:
            os.killpg(pgid, signal.SIGINT)
        except (ProcessLookupError, PermissionError):
            pass
        child_rc = 130

    empty = group_is_empty(pgid)
    with open(report_path, "w", encoding="utf-8") as fh:
        fh.write(f"child_rc={child_rc}\ngroup_empty={1 if empty else 0}\npgid={pgid}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
