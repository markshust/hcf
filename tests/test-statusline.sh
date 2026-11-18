#!/usr/bin/env bash
# Plan-progress statusline: the progress segment, --wrap, the stable shim, and
# the one-time SessionStart tip.
#
# Fixtures live under mktemp, not tests/.tmp: this repo has its own .claude/,
# so a project nested inside it would resolve to the repo root.

STMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hcf-statusline.XXXXXX")" && pwd -P)"
SPLUGIN="$STMP/plugin"
mkdir -p "$SPLUGIN/hooks"
cp "$REPO_ROOT/hooks/statusline-progress.sh" "$REPO_ROOT/hooks/statusline-shim.sh" \
  "$REPO_ROOT/hooks/statusline-tip.sh" "$REPO_ROOT/hooks/resolve-project-dir.sh" \
  "$REPO_ROOT/hooks/resolve-plans-dir.sh" "$SPLUGIN/hooks/" 2>/dev/null
chmod +x "$SPLUGIN"/hooks/*.sh 2>/dev/null
SPROGRESS="$SPLUGIN/hooks/statusline-progress.sh"

# Statusline commands may inherit CLAUDE_PROJECT_DIR from the session; the
# segment must follow the statusline's current_dir instead.
sl_run() { # <stdin> [args...]
  local input="$1"; shift
  printf '%s' "$input" | env -u CLAUDE_PROJECT_DIR HOME="$STMP/home" bash "$SPROGRESS" "$@"
}

sl_json() { # <dir>
  printf '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"%s"},"cwd":"/nowhere"}' "$1"
}

# Writes <project>/.claude/plans/<plan>/_plan.md with the given status and
# task rows ("NNN:status" ...).
sl_plan() { # <project> <plan> <plan-status> [NNN:status ...]
  local proj="$1" plan="$2" status="$3"; shift 3
  local d="$proj/.claude/plans/$plan" row
  mkdir -p "$d"
  {
    printf '# Plan: %s\n\n## Status\n%s\n\n## Task Overview\n' "$plan" "$status"
    printf '| Task | Description | Depends On | Status |\n|------|-------------|------------|--------|\n'
    for row in "$@"; do
      printf '| %s | do it | - | %s |\n' "${row%%:*}" "${row#*:}"
    done
  } > "$d/_plan.md"
}

sl_task() { # <project> <plan> <NNN> <ticked> <total>
  local f="$1/.claude/plans/$2/$3-some-task.md" i
  {
    printf '# Task %s\n\n## Requirements (Test Descriptions)\n' "$3"
    i=1
    while [ "$i" -le "$5" ]; do
      # shellcheck disable=SC2016  # backticks are literal markdown
      if [ "$i" -le "$4" ]; then printf -- '- [x] `req %d`\n' "$i"; else printf -- '- [ ] `req %d`\n' "$i"; fi
      i=$((i + 1))
    done
  } > "$f"
}

sl_strip() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }

mkdir -p "$STMP/home"

# --- progress segment -------------------------------------------------------

P1="$STMP/p1"; mkdir -p "$P1/.claude"
sl_plan "$P1" feat in_progress 001:completed 002:pending 003:pending 004:pending
out="$(sl_run "$(sl_json "$P1")")"
assert_eq "it shows completed tasks as a share of all tasks" "Plan: 25%" "$(sl_strip "$out")"

sl_plan "$P1" feat in_progress 001:completed 002:in_progress
sl_task "$P1" feat 002 2 4
out="$(sl_run "$(sl_json "$P1")")"
assert_eq "it counts an in_progress task by its ticked checkboxes" "Plan: 75%" "$(sl_strip "$out")"

sl_task "$P1" feat 002 0 4
out="$(sl_run "$(sl_json "$P1")")"
assert_eq "it counts an in_progress task with nothing ticked as zero" "Plan: 50%" "$(sl_strip "$out")"

rm -f "$P1/.claude/plans/feat/002-some-task.md"
out="$(sl_run "$(sl_json "$P1")")"
assert_eq "it counts an in_progress task with no task file as zero" "Plan: 50%" "$(sl_strip "$out")"

sl_plan "$P1" feat ready 001:pending
out="$(sl_run "$(sl_json "$P1")")"
assert_empty "it prints nothing when no plan is in_progress" "$out"

out="$(sl_run "$(sl_json "$STMP/home")")"
assert_empty "it prints nothing outside a project" "$out"

sl_plan "$P1" feat in_progress
out="$(sl_run "$(sl_json "$P1")")"
assert_empty "it prints nothing for a plan with no task rows" "$out"

# Color: red at 0, yellow at 50, green at 100.
sl_plan "$P1" feat in_progress 001:pending
out="$(sl_run "$(sl_json "$P1")")"
assert_contains "it colors 0% full red" "$out" "$(printf '\033[38;2;255;0;0m')"
sl_plan "$P1" feat in_progress 001:completed 002:pending
out="$(sl_run "$(sl_json "$P1")")"
assert_contains "it colors 50% yellow" "$out" "$(printf '\033[38;2;255;255;0m')"
sl_plan "$P1" feat in_progress 001:completed
out="$(sl_run "$(sl_json "$P1")")"
assert_contains "it colors 100% full green" "$out" "$(printf '\033[38;2;0;255;0m')"
assert_contains "it resets the color after the segment" "$out" "$(printf '\033[0m')"

# A worktree nested in the main checkout: the statusline's current_dir wins,
# and so does the worktree's own .claude over the enclosing one.
WT="$P1/.claude/worktrees/feat"; mkdir -p "$WT/.claude"
sl_plan "$WT" feat in_progress 001:completed 002:completed 003:completed 004:pending
out="$(sl_run "$(sl_json "$WT")")"
assert_eq "it reads the plan of the checkout named by current_dir" "Plan: 75%" "$(sl_strip "$out")"

out="$(printf '%s' "$(sl_json "$WT")" | CLAUDE_PROJECT_DIR="$P1" HOME="$STMP/home" bash "$SPROGRESS")"
assert_eq "it ignores an inherited CLAUDE_PROJECT_DIR" "Plan: 75%" "$(sl_strip "$out")"

out="$(sl_run '' "$WT" </dev/null)"
assert_eq "it accepts the directory as an argument" "Plan: 75%" "$(sl_strip "$out")"

# Of two in_progress plans, the most recently modified one is shown.
P2="$STMP/p2"; mkdir -p "$P2/.claude"
sl_plan "$P2" old in_progress 001:pending
sleep 1
sl_plan "$P2" new in_progress 001:completed
out="$(sl_run "$(sl_json "$P2")")"
assert_eq "it shows the most recently modified in_progress plan" "Plan: 100%" "$(sl_strip "$out")"

# hcf.json plansDir is honored.
P3="$STMP/p 3"; mkdir -p "$P3/.claude/../docs/plans/x"
printf '{"plansDir": "docs/plans"}' > "$P3/.claude/hcf.json"
printf '## Status\nin_progress\n\n| 001 | a | - | completed |\n| 002 | b | - | pending |\n' > "$P3/docs/plans/x/_plan.md"
out="$(sl_run "$(sl_json "$P3")")"
assert_eq "it honors plansDir from hcf.json, in a path with spaces" "Plan: 50%" "$(sl_strip "$out")"

printf '{"plansDir": "/abs"}' > "$P3/.claude/hcf.json"
out="$(sl_run "$(sl_json "$P3")" 2>&1)"
assert_empty "it prints nothing (not an error) for an invalid plansDir" "$out"

# --- --wrap -----------------------------------------------------------------

sl_plan "$P1" feat in_progress 001:completed 002:pending
# shellcheck disable=SC2016  # expanded by the wrapped shell, not here
out="$(sl_run "$(sl_json "$P1")" --wrap 'input=$(cat); echo "[base] ${#input}"')"
assert_contains "it runs the wrapped command with the same stdin" "$(sl_strip "$out")" "[base] $(sl_json "$P1" | wc -c | tr -d ' ')"
assert_eq "it appends the segment to the wrapped command's line" "[base] $(sl_json "$P1" | wc -c | tr -d ' ') · Plan: 50%" "$(sl_strip "$out")"

out="$(sl_run "$(sl_json "$P1")" --wrap 'echo line1; echo line2')"
assert_eq "it appends to the first line and keeps the rest" "line1 · Plan: 50%
line2" "$(sl_strip "$out")"

out="$(sl_run "$(sl_json "$STMP/home")" --wrap 'echo base')"
assert_eq "it passes the wrapped output through untouched with no plan" "base" "$out"

out="$(sl_run "$(sl_json "$P1")" --wrap 'true')"
assert_eq "it shows the segment alone when the wrapped command prints nothing" "Plan: 50%" "$(sl_strip "$out")"

# The segment goes right after the wrapped statusline's "Context: N%", so it
# reads "Context: 15% · Plan: 50%" wherever context sits in the line.
out="$(sl_run "$(sl_json "$P1")" --wrap 'echo "[Opus] Context: 15% │ ⎇ main"')"
assert_eq "it places the segment right after Context: N%" "[Opus] Context: 15% · Plan: 50% │ ⎇ main" "$(sl_strip "$out")"

out="$(sl_run "$(sl_json "$P1")" --wrap 'echo "Context: 7%"')"
assert_eq "it places the segment after Context: N% at the end of the line" "Context: 7% · Plan: 50%" "$(sl_strip "$out")"

out="$(sl_run "$(sl_json "$P1")" --wrap 'printf "a & b \\\\1 Context: 9%% z\n"')"
assert_eq "it keeps & and backslashes in the wrapped line intact" 'a & b \1 Context: 9% · Plan: 50% z' "$(sl_strip "$out")"

# --- default statusline (no --wrap, no DIR): Context first, then Plan ---------

sl_ctx_json() { # <dir> <context_window json>
  printf '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"%s"},"context_window":%s}' "$1" "$2"
}

out="$(sl_run "$(sl_ctx_json "$P1" '{"context_window_size":200000,"used_percentage":15,"remaining_percentage":85}')" --default)"
assert_eq "the default statusline shows Context then Plan" "Context: 15% · Plan: 50%" "$(sl_strip "$out")"

out="$(sl_run "$(sl_ctx_json "$P1" '{"context_window_size":200000,"used_percentage":15.7}')" --default)"
assert_eq "the default statusline drops a fractional used_percentage" "Context: 15% · Plan: 50%" "$(sl_strip "$out")"

out="$(sl_run "$(sl_ctx_json "$P1" '{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":9000,"cache_read_input_tokens":30000,"output_tokens":5}}')" --default)"
assert_eq "the default statusline computes context from current_usage without used_percentage" "Context: 20% · Plan: 50%" "$(sl_strip "$out")"

out="$(sl_run "$(sl_ctx_json "$STMP/home" '{"context_window_size":200000,"used_percentage":3}')" --default)"
assert_eq "the default statusline shows only Context with no plan running" "Context: 3%" "$(sl_strip "$out")"

out="$(sl_run "$(sl_ctx_json "$STMP/home" '{"context_window_size":200000,"used_percentage":null,"current_usage":null}')" --default)"
assert_eq "the default statusline shows 0% before the first response" "Context: 0%" "$(sl_strip "$out")"

# --- shim -------------------------------------------------------------------

SHOME="$STMP/shimhome"
mkdir -p "$SHOME/.claude/plugins/cache/hcf/hcf/2.4.0/hooks" "$SHOME/.claude/plugins/cache/hcf/hcf/2.10.0/hooks"
printf '#!/usr/bin/env bash\necho "old $*"\n' > "$SHOME/.claude/plugins/cache/hcf/hcf/2.4.0/hooks/statusline-progress.sh"
printf '#!/usr/bin/env bash\ncat; echo " new $*"\n' > "$SHOME/.claude/plugins/cache/hcf/hcf/2.10.0/hooks/statusline-progress.sh"
out="$(printf 'IN' | HOME="$SHOME" bash "$SPLUGIN/hooks/statusline-shim.sh" --wrap 'x y')"
assert_eq "the shim runs the newest installed HCF version with stdin and args" "IN new --wrap x y" "$out"

out="$(printf 'IN' | HOME="$STMP/home" bash "$SPLUGIN/hooks/statusline-shim.sh" --wrap 'echo base' 2>&1)"; code=$?
assert_eq "the shim falls back to the wrapped command when HCF is not installed" "base" "$out"
assert_exit "the shim exits 0 when HCF is not installed" 0 "$code"

out="$(printf 'IN' | HOME="$STMP/home" bash "$SPLUGIN/hooks/statusline-shim.sh" 2>&1)"
assert_empty "the shim prints nothing when HCF is not installed and nothing is wrapped" "$out"

# The installed path end to end: the shim in front of the real hooks, laid out
# as the plugin cache lays them out.
IHOME="$STMP/installhome"
IHOOKS="$IHOME/.claude/plugins/cache/hcf/hcf/9.9.9/hooks"
mkdir -p "$IHOOKS"
cp "$SPLUGIN"/hooks/*.sh "$IHOOKS/"
sl_plan "$P1" feat in_progress 001:completed 002:pending
out="$(sl_json "$P1" | env -u CLAUDE_PROJECT_DIR HOME="$IHOME" bash "$SPLUGIN/hooks/statusline-shim.sh")"
assert_eq "the shim shows the real segment from an installed plugin" "Plan: 50%" "$(sl_strip "$out")"
out="$(sl_json "$P1" | env -u CLAUDE_PROJECT_DIR HOME="$IHOME" bash "$SPLUGIN/hooks/statusline-shim.sh" --wrap 'echo base')"
assert_eq "the shim wraps through an installed plugin" "base · Plan: 50%" "$(sl_strip "$out")"

# --- SessionStart tip -------------------------------------------------------

THOME="$STMP/tiphome"; mkdir -p "$THOME/.claude"
printf '{"statusLine":{"type":"command","command":"bash ~/x.sh"}}' > "$THOME/.claude/settings.json"
out="$(HOME="$THOME" bash "$SPLUGIN/hooks/statusline-tip.sh")"
assert_contains "the tip suggests /hcf:statusline when it is not configured" "$out" "/hcf:statusline"
assert_contains "the tip is SessionStart additionalContext" "$out" '"hookEventName":"SessionStart"'

out="$(HOME="$THOME" bash "$SPLUGIN/hooks/statusline-tip.sh")"
assert_empty "the tip is shown only once" "$out"

THOME2="$STMP/tiphome2"; mkdir -p "$THOME2/.claude"
printf '{"statusLine":{"type":"command","command":"bash ~/.claude/hcf-statusline.sh"}}' > "$THOME2/.claude/settings.json"
out="$(HOME="$THOME2" bash "$SPLUGIN/hooks/statusline-tip.sh")"
assert_empty "the tip is skipped when the HCF statusline is already configured" "$out"

THOME3="$STMP/tiphome3"; mkdir -p "$THOME3"
out="$(HOME="$THOME3" bash "$SPLUGIN/hooks/statusline-tip.sh")"; code=$?
assert_contains "the tip works with no settings.json at all" "$out" "/hcf:statusline"
assert_exit "the tip exits 0" 0 "$code"

rm -rf "$STMP"
