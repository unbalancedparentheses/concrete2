#!/usr/bin/env bash
# THE SUPERVISOR'S DECISION, AS A PURE FUNCTION.
#
# A process cannot safely publish a verdict about its own exit. The campaign therefore runs as a
# child that may only propose a candidate record, and a supervisor that observes the child's exit,
# re-reconciles the tree itself, and installs the authoritative artifact. This file holds the part
# that DECIDES, separated from the part that spawns and writes, for one reason: a decision embedded
# in a 2,000-line driver can only be tested by running a full campaign, and a control that expensive
# does not get run. Here it is a pure string-in, string-out function that a gate can attack directly
# with hostile inputs.
#
# PURE: no filesystem writes, no process state, no globals. It reads one candidate file and returns
# a refusals string. Everything it needs is an argument, so a test can construct any situation —
# including ones that are hard to produce for real, like a child that exits zero after corrupting the
# tree.
#
# Empty output means "nothing refused". Any non-empty output means qualification must be denied.

# The keys that must be present for a candidate to be a record at all. A truncated file parses as a
# valid record with missing fields, and every one of these is load-bearing for what gets published.
CAMPAIGN_CANDIDATE_KEYS="completed mode discovered selected executed reported killed integrity_ok qualified"

# supervisor_refusals <child_rc> <candidate-path> <head0> <head1> <tracked0> <tracked1> <untracked0> <untracked1>
supervisor_refusals() {
  local rc="$1" cand="$2" h0="$3" h1="$4" t0="$5" t1="$6" u0="$7" u1="$8"
  local out="" k

  # THE CHILD'S EXIT IS EVIDENCE, NOT A FORMALITY. This is the case the boundary exists for: the
  # child can print a verdict and then die, and only something outside it can notice.
  [ "$rc" = "0" ] || out="$out child_exit($rc)"

  if [ ! -s "$cand" ]; then
    out="$out candidate_missing"
  else
    for k in $CAMPAIGN_CANDIDATE_KEYS; do
      grep -qE "^$k=" "$cand" || out="$out candidate_malformed($k)"
    done
  fi

  # THE SUPERVISOR'S OWN OBSERVATION, not a re-read of what the child claimed. These are captured
  # before spawning and after reaping, so a child that lied about its own reconciliation — or died
  # between reconciling and exiting — is still caught.
  [ "$h0" = "$h1" ] || out="$out supervisor_head_changed"
  [ "$t0" = "$t1" ] || out="$out supervisor_tracked_changed"
  [ "$u0" = "$u1" ] || out="$out supervisor_untracked_changed"

  # A TREE STATE THAT COULD NOT BE READ IS NOT AN UNCHANGED TREE. Comparing two unavailable values
  # for equality would agree with itself and publish.
  case "$h1$t1$u1" in
    *TREESTATE-UNAVAILABLE*) out="$out supervisor_tree_state_unavailable" ;;
  esac
  [ -n "$h1" ] && [ -n "$t1" ] && [ -n "$u1" ] || out="$out supervisor_tree_state_empty"

  printf '%s' "${out# }"
}

# candidate_incoherent <candidate-path>  -> reasons a candidate's OWN fields contradict qualified=1
#
# KEY PRESENCE IS NOT COHERENCE. Checking only that the fields exist and then trusting `qualified=1`
# accepts a record that contradicts itself: completed=0 with qualified=1, integrity_ok=0 with
# qualified=1, a single-family mode claiming full-campaign qualification, or counts that do not
# reconcile. A supervisor that exists BECAUSE it does not trust the child cannot then take the
# child's headline field at face value.
candidate_incoherent() {
  local c="$1" out="" v
  _f() { sed -n "s/^$1=//p" "$c" | head -1; }
  [ "$(_f qualified)" = "1" ] || { printf ''; return 0; }   # only qualification needs justifying
  [ "$(_f completed)"    = "1" ]        || out="$out qualified_without_completed"
  [ "$(_f integrity_ok)" = "1" ]        || out="$out qualified_without_integrity"
  [ "$(_f mode)"         = "campaign" ] || out="$out qualified_in_$(_f mode)_mode"
  # EVERY SELECTED UNIT REPORTED, AND EVERY ONE OF THEM KILLED. These are the counts the artifact
  # itself publishes; if they do not reconcile, the headline is not describing this run.
  local d s e r k
  d="$(_f discovered)"; s="$(_f selected)"; e="$(_f executed)"; r="$(_f reported)"; k="$(_f killed)"
  [ -n "$d" ] && [ "$d" = "$s" ] && [ "$s" = "$e" ] && [ "$e" = "$r" ] \
    || out="$out qualified_with_counts($d/$s/$e/$r)"
  [ "$k" = "$r" ] || out="$out qualified_with_unkilled($k/$r)"
  for v in survived invalid could_not_apply; do
    case "$(_f $v)" in ''|0) ;; *) out="$out qualified_with_$v($(_f $v))" ;; esac
  done
  printf '%s' "${out# }"
}

# supervisor_qualification <candidate-path> <refusals>  -> the qualified= line to publish
# Only a clean candidate, under a clean reconciliation, whose OWN fields justify it.
supervisor_qualification() {
  local cand="$1" refusals="$2"
  if [ -n "$refusals" ] || [ ! -s "$cand" ]; then printf 'qualified=0'; return 0; fi
  grep -qE '^qualified=1$' "$cand" || { printf 'qualified=0'; return 0; }
  [ -z "$(candidate_incoherent "$cand")" ] && printf 'qualified=1' || printf 'qualified=0'
}
