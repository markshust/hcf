#!/usr/bin/env bash
# HCF plans-directory resolution — where this project keeps its plan folders.
#
# Defaults to <project>/.claude/plans. A project may override it with an
# optional, user-owned .claude/hcf.json:
#
#   { "plansDir": "docs/plans" }
#
# No skill creates or modifies that file. Its absence is the normal case.
#
# Two deliberate departures from a naive one-liner, both the same lesson this
# repo keeps relearning (see issue #4 and the 2.1.1 fix):
#
#   1. No `jq`. A `jq ... || echo <default>` pipeline turns a missing jq — the
#      norm on Debian minimal and Alpine — into a silent fallback: you set
#      plansDir, you get .claude/plans, and nothing says why.
#   2. A malformed plansDir is an error, not a fallback. Writing plans to a
#      directory the project did not ask for is worse than refusing, and it
#      matches how an invalid `phase` already aborts discovery.
#
# The project root comes from resolve-project-dir.sh, so the answer does not
# depend on the working directory. Output is absolute for the same reason:
# callers pass it to subagents whose cwd is not knowable from here.
#
# Usage:
#   resolve-plans-dir.sh          # print the absolute plans directory
#   . resolve-plans-dir.sh        # define hcf_resolve_plans_dir
#
# Exit codes:
#   0  resolved; the absolute path is on stdout
#   1  unresolvable project root, or an invalid plansDir value

HCF_PLANS_DIR_DEFAULT=".claude/plans"

_hcf_plans_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$_hcf_plans_script_dir/resolve-project-dir.sh" ]; then
  printf 'resolve-plans-dir: error: resolve-project-dir.sh not found alongside this script\n' >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=hooks/resolve-project-dir.sh
. "$_hcf_plans_script_dir/resolve-project-dir.sh"

# Reads the plansDir value out of a flat JSON object without a JSON parser.
# Deliberately narrow: one key, a string value, no escapes. Anything it cannot
# read is reported by the caller as absent, which falls back to the default.
#
# Line-oriented, so it does not understand nesting: a plansDir buried inside
# another object would be read as if top-level. hcf.json is a flat file the user
# writes by hand and nesting this key means nothing, so that is a documented
# limit rather than a reason to put a JSON parser in bash. Duplicate keys take
# the last, and a padded value keeps its padding — both match what `jq` returns.
hcf_read_plans_dir_key() {
  sed -n 's/.*"plansDir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}

# Prints the absolute plans directory on stdout. Returns non-zero with a
# message on stderr when the project root or the configured value is unusable.
hcf_resolve_plans_dir() {
  local project status config value

  project="$(hcf_resolve_project_dir)"
  status=$?
  if [ "$status" -eq 2 ]; then
    printf 'resolve-plans-dir: error: CLAUDE_PROJECT_DIR is set to '\''%s'\'', which is not a directory\n' "${CLAUDE_PROJECT_DIR:-}" >&2
    return 1
  elif [ "$status" -ne 0 ]; then
    printf 'resolve-plans-dir: error: cannot determine the project root from '\''%s'\''\n' "$PWD" >&2
    printf 'resolve-plans-dir: error:   run from inside the project, or set CLAUDE_PROJECT_DIR to its path\n' >&2
    return 1
  fi

  config="$project/.claude/hcf.json"
  value=""

  if [ -f "$config" ]; then
    # Absent key and unreadable value are the same case on purpose: fall back
    # quietly. A present-but-empty value is a typo, and is reported below.
    if grep -q '"plansDir"' "$config" 2>/dev/null; then
      value="$(hcf_read_plans_dir_key "$config")"
      if [ -z "$value" ]; then
        printf 'resolve-plans-dir: error: '\''%s'\'' sets an empty plansDir\n' "$config" >&2
        printf 'resolve-plans-dir: error:   give it a relative path, or remove the key to use %s\n' "$HCF_PLANS_DIR_DEFAULT" >&2
        return 1
      fi
    fi
  fi

  if [ -z "$value" ]; then
    value="$HCF_PLANS_DIR_DEFAULT"
  fi

  # Containment: the plans directory belongs to the project. Escaping it would
  # scatter plan folders outside the repo they document.
  case "$value" in
    /*)
      printf 'resolve-plans-dir: error: plansDir '\''%s'\'' must be relative to the project root, not absolute\n' "$value" >&2
      printf 'resolve-plans-dir: error:   set it in %s\n' "$config" >&2
      return 1
      ;;
    ..|../*|*/..|*/../*)
      printf 'resolve-plans-dir: error: plansDir '\''%s'\'' must not contain a '\''..'\'' segment\n' "$value" >&2
      printf 'resolve-plans-dir: error:   set it in %s\n' "$config" >&2
      return 1
      ;;
  esac

  printf '%s\n' "$project/$value"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  hcf_resolve_plans_dir || exit 1
fi
