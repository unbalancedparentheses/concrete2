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

WHAT THIS PROVES, AND WHAT IT DOES NOT.

`killpg(pgid, 0)` establishes exactly one fact: no process remains in the campaign's ORIGINAL
process group. It does NOT establish that no campaign work remains anywhere. A descendant may call
setpgid(2), or start a session of its own, and outlive the group it was born into. Measured, not
assumed: a grandchild started with start_new_session leaves this check reporting an empty group
while it is still running.

That escape is OUT OF THE THREAT MODEL, deliberately and narrowly. The processes this campaign
starts are its own gates, `lake` and the compiler; none of them leave their process group, and the
hazard being defended against is an ACCIDENTAL survivor — a backgrounded build, an orphaned worker —
not a descendant deliberately hiding from its supervisor. Containment against a hostile child needs
a cgroup or a jail, neither of which is portable across the platforms this repository supports.

So the field is named `process_group_empty`, not `descendants_empty`, and the supervisor refuses with
`campaign_group_not_empty`. Whoever reads the artifact learns which question was answered.

Report fields, one per line, exactly once each, in this order:
    child_rc=<int>              exit status; for a signalled child, 128+signal
    child_signalled=<0|1>       1 iff the child was terminated by a signal
    child_signal=<int>          the signal number, or 0
    process_group_empty=<0|1>   1 iff no member of the child's ORIGINAL process group survives
    pgid=<int>                  the group that was checked
"""
import os
import signal
import subprocess
import sys


def process_group_is_empty(pgid: int) -> bool:
    """True iff no process remains in the ORIGINAL process group `pgid`.

    Not "no descendants remain": a process that changed group is no longer counted. See the module
    docstring for why that escape is out of scope rather than silently implied.

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

    # A SIGNALLED CHILD IS NOT AN EXIT STATUS. Popen.wait() returns -N for signal N, which a shell
    # comparison reads as a strange negative or coerces silently — measured: a SIGTERM produced
    # child_rc=-15. It is now reported explicitly, and child_rc carries the conventional 128+N so a
    # consumer reading only that field still sees a failure.
    signalled = child_rc < 0
    signum = -child_rc if signalled else 0
    rc_field = 128 + signum if signalled else child_rc

    empty = process_group_is_empty(pgid)
    with open(report_path, "w", encoding="utf-8") as fh:
        fh.write(
            f"child_rc={rc_field}\n"
            f"child_signalled={1 if signalled else 0}\n"
            f"child_signal={signum}\n"
            f"process_group_empty={1 if empty else 0}\n"
            f"pgid={pgid}\n"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
