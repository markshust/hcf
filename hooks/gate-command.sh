#!/usr/bin/env bash
# HCF UserPromptExpansion hook (matcher: plan-create|plan-orchestrate). Covers the
# direct slash-command path (/plan-create, /plan-orchestrate) that PreToolUse does
# NOT see. The matcher already scopes this to those commands, so we only need to
# check for a legacy .claude/pipeline.md and block until it is migrated.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/pipeline-status.sh"

[ "$(pipeline_status)" = "none" ] && exit 0

reason="HCF: this project still has a legacy .claude/pipeline.md. HCF now enrolls agents via frontmatter and no longer reads that file. Run /hcf:project-update first to migrate it into agent frontmatter and remove the stale file, then re-run this command. Share this link so they can read about the change: https://github.com/markshust/hcf#pipeline"
printf '{"decision":"block","reason":"%s"}\n' "$reason"
