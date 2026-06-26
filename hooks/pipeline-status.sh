#!/usr/bin/env bash
# Shared helper for HCF hooks. Classifies a project's legacy .claude/pipeline.md.
# Sourced by the other hook scripts (no exec bit needed).
#
# pipeline_status echoes exactly one of:
#   none    - no .claude/pipeline.md present
#   default - present but only enrolls the shipped default (devils-advocate, or
#             nothing active); frontmatter already reproduces it, so nothing is lost
#   custom  - present with custom enrollment; those customizations are INACTIVE
#             because HCF now enrolls agents via frontmatter

pipeline_status() {
  local project_dir pipeline names count
  project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
  pipeline="$project_dir/.claude/pipeline.md"

  [ -f "$pipeline" ] || { echo none; return; }

  # "Active" agents = non-commented "- name" bullets (HTML-commented lines inactive).
  names="$(grep -E '^[[:space:]]*-[[:space:]]+[^[:space:]]' "$pipeline" 2>/dev/null \
    | grep -v '<!--' \
    | sed -E 's/^[[:space:]]*-[[:space:]]+//; s/[[:space:]].*$//')"
  count="$(printf '%s\n' "$names" | grep -c '[^[:space:]]')"

  if [ "$count" = "0" ] || { [ "$count" = "1" ] && printf '%s' "$names" | grep -qx 'devils-advocate'; }; then
    echo default
  else
    echo custom
  fi
}
