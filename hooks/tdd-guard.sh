#!/usr/bin/env bash
# HCF PreToolUse hook (matcher: Edit|Write|MultiEdit|NotebookEdit|Bash).
#
# Inside a tdd-worker, refuses any change to a production file unless a failing
# test run has armed it (see verify-tdd.sh --gate). Test files, markdown, plan
# files and paths outside the project are allowed through Edit/Write (the task
# file never from Bash, and never with an edit that removes or renames a
# requirement line or labels one (guard)). Until every file the prompt says to read IN
# FULL has been read, it refuses every file change but the task file.
# Everywhere else (the main session, other agents) it does nothing.
#
# A refusal is a PreToolUse "deny" with the reason fed back to the worker, so it
# learns why and what to do instead. It fails closed: inside a tdd-worker whose
# context cannot be established (no jq, an unreadable transcript, no or an
# unreadable task file), or when verify-tdd.sh errors or gives no verdict, the
# call is refused, never allowed unchecked.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks/tdd-context.sh
. "$DIR/tdd-context.sh"

input="$(cat)"

if [ -n "${HCF_TDD_PROBE_LOG:-}" ]; then
  printf '%s\n' "$input" >> "$HCF_TDD_PROBE_LOG"
fi

hcf_tdd_context "$input"
case $? in
  0) ;;
  2)
    # A tdd-worker the hooks cannot check: refuse every change (no jq may be
    # available, so the JSON is written by hand).
    reason="HCF TDD guard: refused, because the TDD hooks could not run for this worker: $HCF_TDD_ERROR. No file can be changed while the TDD method cannot be checked. Do no more work: end now with exactly: TASK_FAILED: TDD hooks could not run — $HCF_TDD_ERROR"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$(hcf_json_escape "$reason")"
    exit 0 ;;
  *) exit 0 ;;
esac

deny() { jq -cn --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'; exit 0; }

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"

# The project's rules (testing.md, code standards, CLAUDE.md) reach a worker
# only as paths to read IN FULL. Hold every file change but the task file until
# each existing one has been opened with the Read tool: a worker that skips them
# skips the project's own TDD commands and rules.
case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    if [ -n "$HCF_TDD_REQUIRED_READS" ] && [ "$path" != "$HCF_TDD_TASK_FILE" ]; then
      read_paths="$(jq -R -r 'fromjson? | select(.type == "assistant") | .message.content[]?
        | select(.type == "tool_use" and .name == "Read") | .input.file_path // empty' "$HCF_TDD_TRANSCRIPT" 2>/dev/null)"
      unread=""
      while IFS= read -r req; do
        [ -n "$req" ] && [ -r "$req" ] || continue
        printf '%s\n' "$read_paths" | grep -qxF -- "$req" || unread="$unread $req"
      done <<EOF
$HCF_TDD_REQUIRED_READS
EOF
      if [ -n "$unread" ]; then
        deny "HCF TDD guard: refused this change because your prompt says to read these files IN FULL before writing any code, and you have not opened them yet:$unread. Read each one with the Read tool (in parts with offset/limit if it is too large for one read), then make this change again."
      fi
    fi ;;
esac
# The task file's requirement lines are fixed by the orchestrator: an edit may
# tick a checkbox or add a requirement, never remove, rename or label one (guard).
task_real="$(cd "$(dirname "$HCF_TDD_TASK_FILE")" && pwd -P)/$(basename "$HCF_TDD_TASK_FILE")"
path_real=""
[ -n "$path" ] && path_real="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")"
if [ -n "$path" ] && { [ "$path" = "$HCF_TDD_TASK_FILE" ] || [ "$path_real" = "$task_real" ]; }; then
  case "$tool" in
    Edit|MultiEdit|Write)
      changed="$(printf '%s' "$input" | jq -r --rawfile disk "$HCF_TDD_TASK_FILE" '
        # Requirement lines, name -> guard label. An edit may tick a box or add
        # a requirement; it may not drop or rename one, or label one (guard).
        def reqs: [split("\n")[] | capture("^\\s*- \\[[ xX]\\] `(?<n>[^`]*)`\\s*(?<g>\\(guard\\))?\\s*$")? | {(.n): (.g != null)}] | add // {};
        def broken($old; $new): ($old | reqs) as $o | ($new | reqs) as $n
          | any($o | to_entries[]; (.key as $k | ($n | has($k) | not)) or (.value == false and $n[.key] == true));
        .tool_name as $t | (.tool_input // {}) as $in
        | if $t == "Edit" then broken($in.old_string // ""; $in.new_string // "")
          elif $t == "MultiEdit" then broken([($in.edits // [])[] | .old_string // ""] | join("\n"); [($in.edits // [])[] | .new_string // ""] | join("\n"))
          else broken($disk; ($in.content // $in.file_text) // "") end' 2>/dev/null)"
      if [ "$changed" = "true" ]; then
        deny "HCF TDD guard: refused this edit to your task file because it removes or renames a requirement line (- [ ] \`name\`) or labels one (guard). The requirements are fixed by the orchestrator: only tick their checkboxes ([ ] to [x]), add Implementation Notes or PASSED-FIRST lines, or add a new requirement (it is then verified like the others). If a requirement is wrong or impossible, finish what you can and end with TASK_FAILED: <why>."
      fi ;;
  esac
fi

# The raw command: verify-tdd.sh --gate normalises it (heredoc bodies,
# comments) the same way it reads the transcript.
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

# How many test declarations this call adds (Edit/MultiEdit: new minus old;
# Write: new content minus the file as it is on disk now). Counted by
# verify-tdd.sh, so the guard and the verifier always agree on what a test is.
added=0
case "$tool" in
  Edit|MultiEdit|Write)
    added="$(printf '%s' "$input" | jq -c '.tool_input // {}' | "$DIR/verify-tdd.sh" --count-tests "$tool" 2>/dev/null)"
    case "$added" in -[0-9]*|[0-9]*) ;; *) added=0 ;; esac ;;
esac

# Whether an Edit/MultiEdit only deletes code: the cut-back answer to a test
# that passed on its first run (verify-tdd.sh --removal-only).
removal=no
case "$tool" in
  Edit|MultiEdit)
    removal="$(printf '%s' "$input" | jq -c '.tool_input // {}' | "$DIR/verify-tdd.sh" --removal-only "$tool" 2>/dev/null)" ;;
esac

# The call's own id: the transcript may already hold it, with no result yet.
tool_use_id="$(printf '%s' "$input" | jq -r '.tool_use_id // empty')"

# Calls this guard has allowed, for this worker: the transcript can lag behind
# them (see verify-tdd.sh --gate), so the gate reads them too.
sidecar="$(dirname "$HCF_TDD_TASK_FILE")/.tdd/$(basename "$HCF_TDD_TASK_FILE").${HCF_TDD_AGENT_ID:-worker}.calls"

errf="$(mktemp "${TMPDIR:-/tmp}/hcf-guard.XXXXXX")"
trap 'rm -f "$errf"' EXIT
verdict="$(HCF_GATE_ID="$tool_use_id" HCF_GATE_REMOVAL="$removal" HCF_GATE_ADDED="$added" HCF_GATE_TOOL="$tool" HCF_GATE_PATH="$path" HCF_GATE_CMD="$cmd" HCF_GATE_CWD="$HCF_TDD_CWD" HCF_GATE_SIDECAR="$sidecar" \
  "$DIR/verify-tdd.sh" --gate "$HCF_TDD_TASK_FILE" "$HCF_TDD_TRANSCRIPT" 2>"$errf")"

case "$verdict" in
  DENY-FORMAT\ *)
    reason="HCF TDD guard: refused a formatter run without an explicit file list. Formatting is allowed, but only on files named literally on the command line (no directories, no \$(...) substitutions): a bare run rewrites files that belong to other tasks. List the files you changed, e.g. ./vendor/bin/php-cs-fixer fix path/One.php path/Two.php"
    jq -cn --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    ;;
  DENY-CHECKOUT\ *)
    target="${verdict#DENY-CHECKOUT }"
    reason="HCF TDD guard: refused a change to $target: it is in another checkout of this repository, but you are working in $HCF_TDD_CWD. Make every change inside your own working directory ($HCF_TDD_CWD), at the same path relative to it; never edit the main checkout or another worktree."
    jq -cn --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    ;;
  DENY-BATCH\ *)
    reason="HCF TDD guard: refused to add another test to ${verdict#DENY-BATCH }. You added a new test that has not been run yet. One test at a time: run the test you just wrote, filtered to its name, and see it fail before writing the next one."
    jq -cn --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    ;;
  DENY-PASSFIRST\ *)
    name="${verdict#DENY-PASSFIRST }"
    reason="HCF TDD guard: the test for \`$name\` passed on its first filtered run, and that needs an answer before you change production code or add another test. The answer is almost always to cut back: some production code already makes this test pass (an earlier GREEN step that built more than its test needed, or code an earlier test needed). Delete that code with removal-only Edits (each new_string keeps only tokens of its old_string, in the same order, and adds none: no new names, values, operators or rewording) until this test fails; run it filtered to its name and see it FAIL; then rebuild the code in GREEN. Until then only removal-only Edits to production files are allowed. If instead the test is wrong: edit it so it fails for the reason the requirement describes, and run it again. Only when NO production code delivers this behaviour (nothing to delete: a language or framework guarantee) add to the task file's Implementation Notes, exactly: PASSED-FIRST: $name — no-code: <what guarantees it>. The orchestrator checks that claim, and a PASSED-FIRST line without no-code: is not accepted. From here on build only what each test needs."
    jq -cn --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    ;;
  DENY-BASH\ *)
    target="${verdict#DENY-BASH }"
    reason="HCF TDD guard: refused a Bash command that changes $target. In a tdd-worker, project files (tests, production code and your task file alike) may only be changed with the Edit, Write or MultiEdit tools, so each change can be checked against the TDD method. Use Bash only to run tests, linters and read-only commands; that includes git commands that change the working tree (checkout, restore, apply, stash), patch, touch, ln, generators such as artisan make:, and sh -c / bash -c / eval wrapping any of these. Make this change with Edit or Write instead (for a generator, write the file it would create yourself)."
    jq -cn --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    ;;
  DENY\ *)
    target="${verdict#DENY }"
    reason="HCF TDD guard: refused to change production file $target. No failing test is armed: either no test has failed yet, or you added a new test since the last failing run. Follow the method: write ONE test for the next requirement, run it alone with the filtered RED command and see it FAIL, then make the minimal production change. A run counts as failing only when the runner itself is the command (not inside a comment or an echo), it is filtered to the requirement's test name, and its output shows the failure (keep at least the runner's summary line if you trim it with tail or grep); an infrastructure error (Docker or the database not reachable, no tests found, a parse or syntax error, out of memory) is not a failing test: fix it and run again. If this is a refactor, run the suite green first and do not add a new test before refactoring."
    jq -cn --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    ;;
  ALLOW)
    # Record an allowed file change as a transcript-shaped tool_use line,
    # appended under a lock so parallel hook runs never interleave.
    case "$tool" in
      Edit|Write|MultiEdit|NotebookEdit)
        if mkdir -p "$(dirname "$sidecar")" 2>/dev/null; then
          line="$(printf '%s' "$input" | jq -c --arg id "${tool_use_id:-hcf-$$-$(date +%s)}" '{type: "assistant", cwd: .cwd, message: {content: [{type: "tool_use", id: $id, name: .tool_name, input: (.tool_input // {})}]}}')"
          n=0
          while ! mkdir "$sidecar.lock" 2>/dev/null && [ $n -lt 50 ]; do n=$((n + 1)); sleep 0.1; done
          printf '%s\n' "$line" >> "$sidecar"
          rmdir "$sidecar.lock" 2>/dev/null
        fi ;;
    esac ;;
  *)
    # No verdict: the check itself failed. Refuse rather than let it through.
    why="$(head -n 3 "$errf" | tr '\n' ' ')"
    reason="HCF TDD guard: could not check this call, so it is refused rather than allowed unchecked (${why:-no verdict from verify-tdd.sh}). Retry it once. If it is refused again for the same reason, stop and end with exactly: TASK_FAILED: TDD guard error — <this message>."
    jq -cn --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    ;;
esac
exit 0
