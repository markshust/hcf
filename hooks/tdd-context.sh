#!/usr/bin/env bash
# shellcheck disable=SC2034  # the HCF_TDD_* variables are read by the hooks that source this
# Shared by the TDD hooks (tdd-guard.sh, tdd-subagent-stop.sh). Sourced, not run.
#
#   hcf_tdd_context "<hook input json>"
#
# Returns
#   0  the hook fired inside a tdd-worker and its context is known:
#        HCF_TDD_TRANSCRIPT  the worker's own transcript (JSONL)
#        HCF_TDD_TASK_FILE   the task file named under "## Task File Path" in its prompt
#        HCF_TDD_CWD         the working directory the hook reported
#        HCF_TDD_AGENT_ID    the worker's agent id
#        HCF_TDD_REQUIRED_READS  absolute paths the prompt says to read IN FULL, one per line
#   1  not a tdd-worker (the main session, another agent): stay out of the way
#   2  a tdd-worker whose context cannot be established (no jq, an unreadable
#      transcript, no or an unreadable task file). HCF_TDD_ERROR says why, and
#      HCF_TDD_TASK_FILE / HCF_TDD_TRANSCRIPT hold whatever could be found. The
#      hooks fail closed: the guard refuses file changes and the stop hook
#      writes an ERROR verdict.
#
# A worker is an agent whose agent_type ends in tdd-worker. With no
# agent_type, a subagent whose first prompt has a "## Task File Path" heading
# is treated as one too.

# The task file path from a prompt: the first non-blank line after the
# "## Task File Path" heading, with backticks, quotes and a list marker removed.
hcf_task_path_from_prompt() {
  LC_ALL=C awk '
    f && NF { gsub(/^[[:space:]]*(- )?[`"\047]*|[`"\047]*[[:space:]]*$/, ""); print; exit }
    /^#+[[:space:]]*Task File Path[[:space:]:]*$/ { f = 1 }'
}

# Best effort without jq: the task path from the escaped JSON of the first prompt.
hcf_task_path_raw() {
  head -c 2000000 "$1" 2>/dev/null | grep -o 'Task File Path[^"]*' | head -n 1 \
    | sed -e 's/\\n/\
/g' | hcf_task_path_from_prompt
}

# The prompt the orchestrator wrote: the first user message of a transcript
# that carries text. Needs jq.
hcf_first_prompt() {
  jq -Rrn 'first(inputs | fromjson? | select(.type == "user") | (.message.content
      | if type == "string" then . elif type == "array" then (map(select(.type == "text") | .text) | join("\n")) else "" end)
      | select(length > 0)) // ""' "$1" 2>/dev/null
}

hcf_json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t' '  '; }

hcf_tdd_context() {
  local input="$1" agent_id agent_type transcript first_prompt is_worker=0
  HCF_TDD_TRANSCRIPT=""; HCF_TDD_TASK_FILE=""; HCF_TDD_CWD=""; HCF_TDD_REQUIRED_READS=""; HCF_TDD_ERROR=""; HCF_TDD_AGENT_ID=""

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | grep -Eq '"agent_type"[[:space:]]*:[[:space:]]*"[^"]*tdd-worker"' || return 1
    HCF_TDD_ERROR="jq is not installed, so the TDD hooks cannot read your transcript"
    HCF_TDD_TRANSCRIPT="$(printf '%s' "$input" | sed -n 's/.*"agent_transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    [ -r "$HCF_TDD_TRANSCRIPT" ] && HCF_TDD_TASK_FILE="$(hcf_task_path_raw "$HCF_TDD_TRANSCRIPT")"
    return 2
  fi

  agent_id="$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)"
  agent_type="$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)"
  HCF_TDD_AGENT_ID="$agent_id"
  case "$agent_type" in
    *tdd-worker) is_worker=1 ;;
    "") [ -n "$agent_id" ] || return 1 ;;
    *) return 1 ;;
  esac

  transcript="$(printf '%s' "$input" | jq -r '.agent_transcript_path // empty')"
  if [ -z "$transcript" ]; then
    transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
    if [ -n "$transcript" ] && [ -n "$agent_id" ]; then
      transcript="${transcript%.jsonl}/subagents/agent-${agent_id}.jsonl"
    else
      transcript=""
    fi
  fi
  HCF_TDD_TRANSCRIPT="$transcript"
  HCF_TDD_CWD="$(printf '%s' "$input" | jq -r '.cwd // empty')"
  if [ -z "$transcript" ] || [ ! -r "$transcript" ]; then
    [ "$is_worker" = 1 ] || return 1
    HCF_TDD_ERROR="cannot read your transcript (${transcript:-no transcript path in the hook input})"
    return 2
  fi

  first_prompt="$(hcf_first_prompt "$transcript")"
  HCF_TDD_TASK_FILE="$(printf '%s\n' "$first_prompt" | hcf_task_path_from_prompt)"
  if [ -z "$HCF_TDD_TASK_FILE" ]; then
    [ "$is_worker" = 1 ] || return 1
    HCF_TDD_ERROR="your prompt has no task file under a \"## Task File Path\" heading"
    return 2
  fi
  if [ ! -r "$HCF_TDD_TASK_FILE" ]; then
    HCF_TDD_ERROR="cannot read your task file $HCF_TDD_TASK_FILE"
    return 2
  fi

  # Absolute paths the prompt tells the worker to read IN FULL (testing.md,
  # code-standards.md, CLAUDE.md...), one per line. The guard holds every file
  # change until each has been opened with the Read tool. A path in backticks
  # is taken whole, so it may hold spaces; a bare one ends at the first blank.
  HCF_TDD_REQUIRED_READS="$(printf '%s\n' "$first_prompt" | grep 'IN FULL' | LC_ALL=C awk '{
      line = $0
      while (match(line, /`\/[^`]+`/)) { print substr(line, RSTART + 1, RLENGTH - 2); line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH) }
      while (match(line, /\/[^ \t`"]+/)) { p = substr(line, RSTART, RLENGTH); sub(/[.,;:)]+$/, "", p); print p; line = substr(line, RSTART + RLENGTH) }
    }' | LC_ALL=C awk '!seen[$0]++')"
  return 0
}
