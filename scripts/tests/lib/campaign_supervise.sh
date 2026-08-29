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
# THE DISPOSITION FIELDS ARE MANDATORY. Treating a MISSING survived/invalid/could_not_apply as zero
# is fail-open in the one direction that matters: a truncated record loses exactly the fields that
# would have denied qualification, and then qualifies.
CAMPAIGN_CANDIDATE_KEYS="completed mode discovered selected executed reported killed invalid survived could_not_apply integrity_ok qualified"

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
      # EXACTLY ONE VALUE PER KEY. A record carrying `survived=0` AND `survived=1` is not a record;
      # every reader picks whichever its parser reaches first, and this one takes the head — so an
      # appended contradiction reads as the benign value and qualifies.
      case "$(grep -cE "^$k=" "$cand")" in
        1) ;;
        0) out="$out candidate_malformed($k)" ;;
        *) out="$out candidate_duplicate($k)" ;;
      esac
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
candidate_incoherent() { # candidate [expected-family-count]
  local c="$1" expected="${2:-}" out="" v
  _f() { sed -n "s/^$1=//p" "$c" | head -1; }
  [ "$(_f qualified)" = "1" ] || { printf ''; return 0; }   # only qualification needs justifying
  [ "$(_f completed)"    = "1" ]        || out="$out qualified_without_completed"
  [ "$(_f integrity_ok)" = "1" ]        || out="$out qualified_without_integrity"
  [ "$(_f mode)"         = "campaign" ] || out="$out qualified_in_$(_f mode)_mode"
  # EVERY SELECTED UNIT REPORTED, AND EVERY ONE OF THEM KILLED. These are the counts the artifact
  # itself publishes; if they do not reconcile, the headline is not describing this run.
  # STRING EQUALITY IS NOT RECONCILIATION. Comparing the counts as text lets five identical
  # non-numeric values — or five empty strings — satisfy every equality and qualify. Each must be a
  # number first, and a qualifying campaign must have discharged a POSITIVE number of families.
  local d s e r k v
  d="$(_f discovered)"; s="$(_f selected)"; e="$(_f executed)"; r="$(_f reported)"; k="$(_f killed)"
  # NEGATIVE, NONCANONICAL AND OVERSIZED VALUES ARE NOT NUMBERS EITHER. `-1` and `007` both survive a
  # naive digit test in one direction or the other, and a value too large to be a family count is a
  # corrupted field rather than a big campaign.
  for v in "$d" "$s" "$e" "$r" "$k"; do
    case "$v" in
      ''|*[!0-9]*) out="$out qualified_with_nonnumeric_counts"; break ;;
      0) ;;
      0*) out="$out qualified_with_noncanonical_count($v)"; break ;;
    esac
    [ "${#v}" -le 6 ] || { out="$out qualified_with_implausible_count($v)"; break; }
  done
  case "$out" in *nonnumeric*) ;; *)
    [ "$d" -gt 0 ] || out="$out qualified_with_zero_families"
    # SELF-AGREEMENT IS NOT ENOUGH. Five counts that agree with each other say nothing about whether
    # they describe the CORPUS: a candidate reporting 1/1/1/1/1 satisfies every internal equality
    # while eighty-four families went unexamined. The child compares its kill count against the
    # pinned inventory; a supervisor that did not was strictly LOOSER than the process it audits,
    # which makes it a rubber stamp rather than a check.
    if [ -n "$expected" ]; then
      [ "$d" = "$expected" ] || out="$out qualified_against_wrong_population($d vs pinned $expected)"
    else
      out="$out qualified_without_a_pinned_population"
    fi
    { [ "$d" = "$s" ] && [ "$s" = "$e" ] && [ "$e" = "$r" ]; } \
      || out="$out qualified_with_counts($d/$s/$e/$r)"
    [ "$k" = "$r" ] || out="$out qualified_with_unkilled($k/$r)"
    # THE DISPOSITIONS MUST ACCOUNT FOR THE REPORTED FAMILIES. Checking each disposition is zero and
    # that killed equals reported leaves the ledger unbalanced if a family is reported under no
    # disposition at all; this is the identity that makes the four numbers describe one population.
    local iv sv ca sum
    iv="$(_f invalid)"; sv="$(_f survived)"; ca="$(_f could_not_apply)"
    case "$iv$sv$ca" in
      ''|*[!0-9]*) ;;   # the per-field checks below name the offender
      *) sum=$(( k + iv + sv + ca ))
         [ "$sum" = "$r" ] || out="$out qualified_with_unbalanced_ledger($k+$iv+$sv+$ca=$sum vs reported=$r)" ;;
    esac
  esac
  # A MISSING DISPOSITION IS NOT A ZERO ONE. It is absent evidence, and absence must not qualify.
  for v in survived invalid could_not_apply; do
    case "$(_f $v)" in
      0) ;;
      '') out="$out qualified_without_$v" ;;
      *[!0-9]*) out="$out qualified_with_nonnumeric_$v" ;;
      *) out="$out qualified_with_$v($(_f $v))" ;;
    esac
  done
  printf '%s' "${out# }"
}

# supervisor_qualification <candidate-path> <refusals>  -> the qualified= line to publish
# Only a clean candidate, under a clean reconciliation, whose OWN fields justify it.
supervisor_qualification() { # candidate refusals [expected-family-count]
  local cand="$1" refusals="$2" expected="${3:-}"
  if [ -n "$refusals" ] || [ ! -s "$cand" ]; then printf 'qualified=0'; return 0; fi
  grep -qE '^qualified=1$' "$cand" || { printf 'qualified=0'; return 0; }
  [ -z "$(candidate_incoherent "$cand" "$expected")" ] && printf 'qualified=1' || printf 'qualified=0'
}

# evidence_root_digest <evidence-dir> -> digest over canonical (family id, record digest) pairs
#
# ONE PRODUCER, USED BY BOTH ROLES. The child computes this over the evidence it just published; the
# supervisor recomputes it after the child exits, over the same tree. If the two disagree, the bytes
# changed under the verdict — which is the race that "validate one object, publish a later-mutated
# object" describes. Two implementations could differ and agree with themselves, so there is one.
evidence_root_digest() { # evidence-dir -> digest, or a marker; nonzero on producer failure
  local root="$1" d n f out="" rec
  [ -d "$root" ] || { printf 'no-evidence-dir'; return 0; }
  for d in "$root"/*/; do
    [ -e "$d" ] || continue
    n="$(basename "$d")"
    rec=""
    # THE LISTING IS PRODUCED FIRST, WITH ITS STATUS CHECKED. Inside the here-doc the substitution's
    # status is discarded, so an unreadable directory yielded an empty listing and a confident digest
    # over nothing — a hash that agrees with itself while describing no evidence at all.
    local listing
    listing="$(cd "$d" 2>/dev/null && find . -type f 2>/dev/null | LC_ALL=C sort)" || return 1
    # NAMES AND BOUNDARIES ARE PART OF THE EVIDENCE. Hashing concatenated CONTENTS alone let a
    # required transcript be RENAMED — gate.log to gate2.log, same sort position — without moving the
    # digest, even though the file the census demands had disappeared. Each file contributes its
    # path, its byte length and its own digest, so a rename, a truncation and a swap are all visible.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      local sz dg
      sz="$(wc -c < "$d$f" 2>/dev/null)" || return 1
      dg="$({ sha256sum "$d$f" 2>/dev/null || shasum -a 256 "$d$f"; } | cut -d' ' -f1)" || return 1
      [ -n "$dg" ] || return 1
      rec="$rec$f $sz $dg
"
    done <<EOF
$listing
EOF
    # A PRODUCER FAILURE IS NOT AN EMPTY DIRECTORY. Ignoring the status of find/sort/cat produced a
    # confident digest over partial or empty data — a hash that agrees with itself while describing
    # nothing. `find` failing here returns nonzero to the caller instead.
    [ -d "$d" ] || return 1
    out="$out$n
$rec"
  done
  printf '%s' "$out" | LC_ALL=C sort | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1
}

# family_set_digest <newline-separated family ids> -> canonical digest of the SET
#
# A COUNT CANNOT SEE A SUBSTITUTION. Pinning only the population size lets one family be swapped for
# another — the total stays 85 while a mutation silently leaves the corpus and a foreign one joins
# it. The identity of the set is what the campaign's evidence is about.
family_set_digest() {
  printf '%s' "$1" | grep -v '^$' | LC_ALL=C sort -u \
    | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1
}

# family_set_from_driver <driver-path> -> the declared family ids, one per line
#
# READ FROM THE SOURCE, not from the arrays the child built. The point is double entry: the child
# derives its set from what it RAN, the supervisor from what the driver DECLARES, and a disagreement
# means one of them is describing a different corpus. Two readings of the same array would agree with
# themselves and prove nothing.
family_set_from_driver() {
  grep -oE '^add "[^"]+"' "$1" 2>/dev/null | sed 's/^add "//; s/"$//'
}

# records_disposition_totals <evidence-dir> -> "killed invalid survived could_not_apply other"
#
# THE RECORDS ARE THE EVIDENCE; THE SUMMARY IS A CLAIM ABOUT THEM. Deriving the totals from the
# per-family records and comparing them with the summary is what stops a summary asserting that
# every family was killed while a record on disk says `survived`. A summary may never override a
# record, so the record side is computed first and independently.
records_disposition_totals() {
  local root="$1" d k=0 i=0 sv=0 c=0 o=0 disp
  [ -d "$root" ] || { printf '0 0 0 0 0'; return 0; }
  for d in "$root"/*/; do
    [ -e "$d" ] || continue
    [ "$(basename "$d")" != "_baseline" ] || continue
    [ -s "$d/verdict.txt" ] || { o=$((o+1)); continue; }
    # EXACTLY ONE disposition line, or the record does not state one.
    if [ "$(grep -cE '^disposition=' "$d/verdict.txt")" != "1" ]; then o=$((o+1)); continue; fi
    disp="$(sed -n 's/^disposition=//p' "$d/verdict.txt")"
    case "$disp" in
      killed)          k=$((k+1)) ;;
      invalid)         i=$((i+1)) ;;
      survived)        sv=$((sv+1)) ;;
      could_not_apply) c=$((c+1)) ;;
      *)               o=$((o+1)) ;;
    esac
  done
  printf '%s %s %s %s %s' "$k" "$i" "$sv" "$c" "$o"
}

# records_unkilled_or_unevidenced <evidence-dir> -> family ids that cannot support qualification
#
# QUALIFICATION IS A CLAIM ABOUT EVERY FAMILY. It requires each record to say `killed` AND to carry
# the transcripts that make that kill checkable — a gate kill needs its red, its restored green and
# its reapplied red, because without the green leg the red is not attributable to the mutation.
records_unkilled_or_unevidenced() {
  local root="$1" d n bad="" disp route
  [ -d "$root" ] || { printf 'no-evidence-dir'; return 0; }
  for d in "$root"/*/; do
    [ -e "$d" ] || continue
    n="$(basename "$d")"; [ "$n" != "_baseline" ] || continue
    disp="$(sed -n 's/^disposition=//p' "$d/verdict.txt" 2>/dev/null | head -1)"
    route="$(sed -n 's/^expected_route=//p' "$d/verdict.txt" 2>/dev/null | head -1)"
    [ "$disp" = "killed" ] || { bad="$bad $n(${disp:-no-disposition})"; continue; }
    if [ "$route" = "gate" ]; then
      for f in gate.log confirm_clean.log confirm_red.log; do
        [ -s "$d/$f" ] || bad="$bad $n(missing-$f)"
      done
    elif [ "$route" = "build" ]; then
      [ -s "$d/build.log" ] || bad="$bad $n(missing-build.log)"
    else
      bad="$bad $n(unknown-route-${route:-none})"
    fi
  done
  printf '%s' "${bad# }"
}
