#!/usr/bin/env bash
# HCF SessionStart hook — surfaces a legacy .claude/pipeline.md and urges migration.
# Self-silences (exit 0, no output) when there is no legacy file, so it goes quiet
# the moment /hcf:project-update removes the file. Enforcement of the block lives in the
# PreToolUse / UserPromptExpansion gates; this hook is the up-front heads-up.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/pipeline-status.sh"

status="$(pipeline_status)"
[ "$status" = "none" ] && exit 0

if [ "$status" = "custom" ]; then
  note="A legacy .claude/pipeline.md with CUSTOM pipeline configuration was found. HCF no longer reads it (agents enroll via frontmatter), so those customizations are currently INACTIVE. HCF planning is gated until you migrate: plan-create and plan-orchestrate are BLOCKED while this file exists. Strongly urge the user to run /hcf:project-update now (it is command-only, so they type it themselves) to migrate the customizations into agent frontmatter and remove the stale file. Surface this immediately, not as a passing note. Include this link so they can read about the change: https://github.com/markshust/hcf#pipeline"
else
  note="A legacy .claude/pipeline.md was found — a stale file from an older HCF version. HCF now enrolls agents via frontmatter and no longer reads it. HCF planning is gated until you migrate: plan-create and plan-orchestrate are BLOCKED while this file exists. Strongly urge the user to run /hcf:project-update now (it is command-only, so they type it themselves) to remove the stale file and bring the project onto the current model. Surface this immediately, not as a passing note. Include this link so they can read about the change: https://github.com/markshust/hcf#pipeline"
fi

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"HCF migration required: %s"}}\n' "$note"
