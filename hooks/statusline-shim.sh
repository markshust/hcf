#!/usr/bin/env bash
# Stable entry point for the HCF statusline. /hcf:statusline copies this file to
# ~/.claude/hcf-statusline.sh and points settings.json at the copy.
#
# The plugin lives in a versioned cache path (.../hcf/hcf/2.4.0/), so a command
# naming that path directly breaks on the next update. This shim finds the
# newest installed HCF at run time and hands it stdin and its arguments. With
# HCF uninstalled it still runs a --wrap'ed command, so the user's own
# statusline keeps working.

best=""
best_key=""
shopt -s nullglob
for f in "$HOME"/.claude/plugins/cache/*/hcf/*/hooks/statusline-progress.sh; do
  version="$(basename "$(dirname "$(dirname "$f")")")"
  # Zero-padded major.minor.patch, so plain string comparison orders versions.
  key="$(printf '%s' "$version" | LC_ALL=C awk -F. '{ printf "%06d%06d%06d", $1, $2, $3 }')"
  if [ -z "$best" ] || [[ "$key" > "$best_key" ]]; then
    best="$f"
    best_key="$key"
  fi
done
shopt -u nullglob

if [ -n "$best" ]; then
  exec bash "$best" "$@"
fi

if [ "${1:-}" = "--wrap" ] && [ -n "${2:-}" ]; then
  exec bash -c "$2"
fi
exit 0
