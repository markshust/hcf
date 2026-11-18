#!/usr/bin/env bash
# HCF statusline segment — "Plan: N%" for the plan running in this checkout.
#
# Claude Code pipes the statusline JSON to stdin. The checkout is the one named
# by its workspace.current_dir, not $PWD or an inherited CLAUDE_PROJECT_DIR: a
# session that moved into a worktree runs its plan there, and the worktree's
# copy of _plan.md is the only one plan-orchestrate keeps current.
#
# Progress: a completed task counts fully; an in_progress task counts by the
# share of "- [x]" requirements its TDD worker has ticked in its task file. The
# segment is colored red (0%) through yellow (50%) to green (100%). It prints
# nothing when no plan is in_progress, and never fails the statusline.
#
# Usage:
#   statusline-progress.sh [DIR]          # the segment alone
#   statusline-progress.sh --default      # "Context: N% · Plan: N%", for
#                                         # users with no statusline of their own
#   statusline-progress.sh --wrap CMD     # CMD's statusline, segment placed
#                                         # after its "Context: N%" if it has
#                                         # one, else at the end of line 1
#
# Installed by /hcf:statusline through statusline-shim.sh, which keeps the
# settings.json command stable across plugin versions.

_hcf_sl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

wrap=""
dir=""
default=""
while [ $# -gt 0 ]; do
  case "$1" in
    --wrap) wrap="${2:-}"; shift 2 || shift ;;
    --default) default=1; shift ;;
    *) dir="$1"; shift ;;
  esac
done

input=""
[ -t 0 ] || input="$(cat)"

if [ -z "$dir" ]; then
  dir="$(printf '%s' "$input" | sed -n 's/.*"current_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$dir" ]; then
  dir="$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi
[ -n "$dir" ] || dir="$PWD"

# Prints the segment, or nothing.
hcf_plan_segment() {
  local plans_dir plan f status score total num tstatus task boxes ticked pct r g

  [ -d "$dir" ] || return 0
  plans_dir="$(cd "$dir" && env -u CLAUDE_PROJECT_DIR "$_hcf_sl_dir/resolve-plans-dir.sh" 2>/dev/null)" || return 0
  [ -d "$plans_dir" ] || return 0

  plan=""
  shopt -s nullglob
  for f in "$plans_dir"/*/_plan.md; do
    status="$(LC_ALL=C awk '/^## Status/ { getline; gsub(/[[:space:]]/, ""); print; exit }' "$f")"
    [ "$status" = "in_progress" ] || continue
    if [ -z "$plan" ] || [ "$f" -nt "$plan" ]; then
      plan="$f"
    fi
  done
  shopt -u nullglob
  [ -n "$plan" ] || return 0

  score=0  # thousandths of a task
  total=0
  while read -r num tstatus; do
    [ -n "$num" ] || continue
    total=$((total + 1))
    case "$tstatus" in
      completed) score=$((score + 1000)) ;;
      in_progress)
        task=""
        shopt -s nullglob
        for f in "$(dirname "$plan")/$num"-*.md; do task="$f"; break; done
        shopt -u nullglob
        [ -n "$task" ] || continue
        boxes="$(grep -cE '^[[:space:]]*- \[[ xX]\]' "$task")"
        ticked="$(grep -cE '^[[:space:]]*- \[[xX]\]' "$task")"
        [ "$boxes" -gt 0 ] && score=$((score + ticked * 1000 / boxes))
        ;;
    esac
  done <<EOF
$(LC_ALL=C awk -F'|' '
  /^\|[[:space:]]*[0-9]+[[:space:]]*\|/ {
    n = $2; s = $(NF-1)
    gsub(/[[:space:]]/, "", n); gsub(/[[:space:]`*]/, "", s)
    print n, s
  }' "$plan")
EOF
  [ "$total" -gt 0 ] || return 0

  pct=$((score * 100 / (total * 1000)))
  if [ "$pct" -le 50 ]; then
    r=255; g=$((pct * 255 / 50))
  else
    r=$(((100 - pct) * 255 / 50)); g=255
  fi
  printf '\033[38;2;%d;%d;0mPlan: %d%%\033[0m' "$r" "$g" "$pct"
}

# First numeric value of "key" in the input JSON, integer part only; empty for
# null or absent. Line-oriented, like hcf_read_plans_dir_key: no jq dependency.
hcf_json_int() {
  printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -1
}

# "Context: N%" from context_window.used_percentage, or computed from
# current_usage on Claude Code versions that do not send it.
hcf_context_segment() {
  local pct size fresh created cached used
  pct="$(hcf_json_int used_percentage)"
  if [ -z "$pct" ]; then
    size="$(hcf_json_int context_window_size)"
    fresh="$(hcf_json_int input_tokens)"
    created="$(hcf_json_int cache_creation_input_tokens)"
    cached="$(hcf_json_int cache_read_input_tokens)"
    used=$(( ${fresh:-0} + ${created:-0} + ${cached:-0} ))
    if [ -n "$size" ] && [ "$size" -gt 0 ]; then
      pct=$((used * 100 / size))
    else
      pct=0
    fi
  fi
  printf 'Context: %d%%' "$pct"
}

segment="$(hcf_plan_segment)"

# No statusline of the user's own: HCF's default is context, then plan.
if [ -n "$default" ]; then
  line="$(hcf_context_segment)"
  [ -n "$segment" ] && line="$line · $segment"
  printf '%s\n' "$line"
  exit 0
fi

if [ -z "$wrap" ]; then
  [ -n "$segment" ] && printf '%s\n' "$segment"
  exit 0
fi

base="$(printf '%s' "$input" | bash -c "$wrap")"
if [ -z "$segment" ]; then
  [ -n "$base" ] && printf '%s\n' "$base"
elif [ -z "$base" ]; then
  printf '%s\n' "$segment"
else
  first="${base%%$'\n'*}"
  # Right after the user's "Context: N%" when the line has one, so progress
  # reads beside context; otherwise at the end of the line.
  context_re='^(.*Context: [0-9]+%)(.*)$'
  if [[ "$first" =~ $context_re ]]; then
    printf '%s · %s%s\n' "${BASH_REMATCH[1]}" "$segment" "${BASH_REMATCH[2]}"
  else
    printf '%s · %s\n' "$first" "$segment"
  fi
  [ "$first" != "$base" ] && printf '%s\n' "${base#*$'\n'}"
fi
exit 0
