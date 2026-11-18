#!/usr/bin/env bash
# HCF SessionStart hook — a one-time tip that /hcf:statusline exists.
#
# Plugins cannot set the user's statusLine and have no post-install step, so
# this is how a new install hears about it. It shows once per user (a marker in
# ~/.claude), and never when the HCF statusline is already configured.

settings="$HOME/.claude/settings.json"
marker="$HOME/.claude/.hcf-statusline-tip-shown"

[ -f "$marker" ] && exit 0
if [ -f "$settings" ] && grep -q 'hcf-statusline' "$settings" 2>/dev/null; then
  exit 0
fi

mkdir -p "$HOME/.claude" 2>/dev/null
: > "$marker" 2>/dev/null

note="HCF tip (shown once): HCF can show the running plan's progress in the Claude Code statusline as a colored 'Plan: N%' that updates while TDD workers tick off requirements. Mention briefly, once, that the user can type /hcf:statusline to install it (it keeps any existing statusline and appends to it). Do not install it unprompted."

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$note"
