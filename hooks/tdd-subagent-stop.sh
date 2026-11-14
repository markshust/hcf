#!/usr/bin/env bash
# HCF SubagentStop hook. When a tdd-worker finishes, verify from its transcript
# that the task was built test-first (verify-tdd.sh) and record the verdict at
#   <task dir>/.tdd/<task file name>.verdict
# (e.g. .claude/plans/demo/.tdd/001-foo.md.verdict). The first line is OK,
# REVIEW, FAILED, NONE (no test requirements, so nothing was checked) or ERROR
# (the check could not run); a "transcript: <path>" line names the transcript
# it judged, and the verifier's report follows. Inside a tdd-worker the hook
# fails closed: when the context cannot be established (no jq, an unreadable
# transcript or task file) or the verifier errors, it writes ERROR where it
# can and stops the worker once, telling it to end with
# "TASK_FAILED: TDD hooks could not run — <why>".
# plan-orchestrate reads it before accepting TASK_COMPLETE.
#
# On FAILED the worker is stopped once more with the violations, so its final
# message reports TASK_FAILED instead of claiming success. When the only
# violations are requirements never started (R1 "not attempted"), the task is
# unfinished, not in breach: the verdict file gets an "unfinished: <n> ..."
# line after the transcript line, and the worker is told to end with
# "TASK_FAILED: unfinished — <n> requirement(s) not attempted", so the
# orchestrator resumes it instead of reverting its finished work. Any other
# verdict still needs the worker's terminal line: a final message whose last
# line is not TASK_COMPLETE or TASK_FAILED: <reason> is stopped once and asked
# for it. stop_hook_active
# guards the second stop, so a worker can never be trapped in a loop.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks/tdd-context.sh
. "$DIR/tdd-context.sh"

input="$(cat)"

if [ -n "${HCF_TDD_PROBE_LOG:-}" ]; then
  printf '%s\n' "$input" >> "$HCF_TDD_PROBE_LOG"
fi

# Without jq the input is read with grep, and JSON is written by hand.
stop_active=false
printf '%s' "$input" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true' && stop_active=true

# Records an ERROR verdict where the task file's directory is known, and stops
# the worker once, telling it to report that the hooks could not run.
fail_closed() {
  local why="$1" vdir
  if [ -n "$HCF_TDD_TASK_FILE" ] && [ -d "$(dirname "$HCF_TDD_TASK_FILE")" ]; then
    vdir="$(dirname "$HCF_TDD_TASK_FILE")/.tdd"
    mkdir -p "$vdir" 2>/dev/null && { printf 'ERROR\ntranscript: %s\nerror: %s\n' "$HCF_TDD_TRANSCRIPT" "$why" > "$vdir/$(basename "$HCF_TDD_TASK_FILE").verdict"; } 2>/dev/null
  fi
  [ "$stop_active" = "true" ] && exit 0
  printf '{"decision":"block","reason":"%s"}\n' "$(hcf_json_escape "HCF TDD verification could not run for this task: $why. Your work cannot be accepted unverified. Do no more work: end now with exactly: TASK_FAILED: TDD hooks could not run — $why")"
  exit 0
}

hcf_tdd_context "$input"
case $? in
  0) ;;
  2) fail_closed "$HCF_TDD_ERROR" ;;
  *) exit 0 ;;
esac

verdict_dir="$(dirname "$HCF_TDD_TASK_FILE")/.tdd"
verdict_file="$verdict_dir/$(basename "$HCF_TDD_TASK_FILE").verdict"
mkdir -p "$verdict_dir" || fail_closed "cannot create $verdict_dir"

report="$("$DIR/verify-tdd.sh" "$HCF_TDD_TASK_FILE" "$HCF_TDD_TRANSCRIPT" 2>&1)"
code=$?
case "$code" in
  0) status="OK" ;;
  2) status="REVIEW" ;;
  1) status="FAILED" ;;
  4) status="NONE" ;;
  *) status="ERROR" ;;
esac
# A FAILED verdict whose only violations are requirements never started (no
# test written) is an unfinished task, not a broken method: the worker stopped
# early, by design or out of time. Still FAILED, but said so, so the
# orchestrator resumes it instead of reverting finished work.
violations="$(printf '%s\n' "$report" | grep '^VIOLATION ' || true)"
unattempted="$(printf '%s\n' "$violations" | grep -E '^VIOLATION R1 `.*` not attempted \(no test written\)$' || true)"
unfinished=""
if [ "$status" = "FAILED" ] && [ -n "$violations" ] && [ "$violations" = "$unattempted" ]; then
  unfinished="$(printf '%s\n' "$unattempted" | grep -c .)"
fi
{ printf '%s\n' "$status"; printf 'transcript: %s\n' "$HCF_TDD_TRANSCRIPT"
  [ -n "$unfinished" ] && printf 'unfinished: %s requirement(s) not attempted\n' "$unfinished"
  printf '%s\n' "$report"; } > "$verdict_file"

if [ "$status" = "ERROR" ]; then
  [ "$stop_active" = "true" ] && exit 0
  why="$(printf '%s\n' "$report" | grep -v '^[[:space:]]*$' | head -n 1)"
  reason="HCF TDD verification could not run for this task: ${why:-verify-tdd.sh failed}. Your work cannot be accepted unverified. Do no more work: end now with exactly: TASK_FAILED: TDD hooks could not run — ${why:-verify-tdd.sh failed}"
  jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
elif [ -n "$unfinished" ] && [ "$stop_active" != "true" ]; then
  names="$(printf '%s\n' "$unattempted" | sed -E 's/^VIOLATION R1 (`.*`) not attempted.*/- \1/')"
  reason="HCF TDD verification: this task is unfinished. These requirements were not attempted (no test written for them):
$names
Everything you did finish follows the TDD method. Do not start them now. End now with exactly: TASK_FAILED: unfinished — $unfinished requirement(s) not attempted"
  jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
elif [ "$status" = "FAILED" ] && [ "$stop_active" != "true" ]; then
  reason="HCF TDD verification FAILED for this task. Your transcript shows the TDD method was not followed:
$report
Do not try to repair it. End now with exactly: TASK_FAILED: TDD verification failed"
  jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
elif [ "$stop_active" != "true" ]; then
  # A clean verdict still needs the worker's own terminal line: the
  # orchestrator reads it, and a missing one leaves it guessing.
  last_line="$(jq -R -r 'fromjson? | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' \
    "$HCF_TDD_TRANSCRIPT" 2>/dev/null | LC_ALL=C awk 'NF { last = $0 } END { print last }')"
  last_line="$(printf '%s' "$last_line" | sed -E 's/^[[:space:]`*]+|[[:space:]`*]+$//g')"
  case "$last_line" in
    TASK_COMPLETE|TASK_FAILED:*) ;;
    *)
      reason="HCF: your final message must end with the terminal line on its own, so the orchestrator can read the outcome. If every requirement is done and the suite is green, end with exactly: TASK_COMPLETE. Otherwise end with exactly: TASK_FAILED: <brief reason>. Do not do any more work."
      jq -cn --arg r "$reason" '{decision: "block", reason: $r}' ;;
  esac
fi
exit 0
