#!/usr/bin/env bash
# HCF project-root resolution — the one answer to "which project are we in?"
#
# Why this exists: hook discovery used to resolve the project as
# "${CLAUDE_PROJECT_DIR:-$PWD}" and then silently skip a missing
# .claude/agents. CLAUDE_PROJECT_DIR is not exported to a skill's Bash calls,
# so in practice that was $PWD alone — and the Bash tool's working directory
# persists across calls, so one stray `cd` earlier in a session was enough to
# make every project-local agent invisible. The resulting enrollment was wrong
# but perfectly well-formed: a fingerprint captured that way looks valid and
# only surfaces hours later, as a drift halt naming a change that never
# happened. That is issue #4's failure class — a silent false-empty enrollment
# — reached by a second route.
#
# Two rules follow from that, and both matter more than convenience:
#   1. Resolve from an anchor, not from wherever the shell happens to sit.
#   2. When no anchor can be found, say so and stop. Never guess, because a
#      guess here is indistinguishable from a correct answer.
#
# Usage:
#   resolve-project-dir.sh        # print the resolved project root, or fail
#   . resolve-project-dir.sh      # define hcf_resolve_project_dir for reuse
#
# Exit codes:
#   0  resolved; the path is on stdout
#   1  no project root could be determined
#   2  CLAUDE_PROJECT_DIR is set but is not a directory

# Prints the project root on stdout. Returns 1 without printing when there is
# none, leaving the caller to phrase its own error — callers have better
# context about what the resolution was for.
hcf_resolve_project_dir() {
  # Claude Code exports this to hooks, and it is authoritative when present:
  # it names the project even when the shell sits somewhere else entirely.
  # Deliberately not validated against a .claude/ directory — a project that
  # has not created one yet is still that project.
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    # Set but pointing nowhere is the same silent-degradation trap one level up:
    # enumeration would find no local agents and report a well-formed answer.
    if [ ! -d "$CLAUDE_PROJECT_DIR" ]; then
      return 2
    fi

    printf '%s\n' "$CLAUDE_PROJECT_DIR"
    return 0
  fi

  # Everything below is compared in physical form. $PWD and $HOME are logical
  # while `git rev-parse` answers physical, and on macOS /var is a symlink to
  # /private/var — so mixing the two silently defeats the $HOME boundary for
  # anyone whose home is reached through a symlink.
  local start home_boundary
  start="$(cd "$PWD" 2>/dev/null && pwd -P)" || start="$PWD"
  home_boundary=""
  if [ -n "${HOME:-}" ]; then
    home_boundary="$(cd "$HOME" 2>/dev/null && pwd -P)" || home_boundary="$HOME"
  fi

  # Walk up for the .claude/ that marks a project root, so running from a
  # subdirectory resolves exactly as running from the root does.
  local dir="$start"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    # $HOME is a boundary, not a candidate. ~/.claude holds user-level Claude
    # config; treating it as a project root would silently enroll a user's
    # personal agents into whichever repo they happened to be standing near.
    if [ -n "$home_boundary" ] && [ "$dir" = "$home_boundary" ]; then
      break
    fi

    if [ -d "$dir/.claude" ]; then
      printf '%s\n' "$dir"
      return 0
    fi

    dir="$(dirname "$dir")"
  done

  # Secondary anchor: a repository root is a real project boundary, and a
  # project that has not created .claude/ yet is still a project — plan-create
  # has no prerequisite on project-setup, so it can legitimately be the first
  # HCF command run in a fresh repo. Refusing there would block first use to
  # prevent a wrong answer that was never wrong: no .claude/ means no local
  # agents, so plugin-only is simply correct. Bounded by $HOME as above, since
  # a dotfiles repo at $HOME is not the project you are working in.
  if command -v git >/dev/null 2>&1; then
    local git_root
    git_root="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [ -n "$git_root" ] && { [ -z "$home_boundary" ] || [ "$git_root" != "$home_boundary" ]; }; then
      printf '%s\n' "$git_root"
      return 0
    fi
  fi

  return 1
}

# Executed rather than sourced: resolve, print, and phrase the error here.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  hcf_resolve_project_dir
  _status=$?
  if [ "$_status" -eq 2 ]; then
    printf 'resolve-project-dir: error: CLAUDE_PROJECT_DIR is set to '\''%s'\'', which is not a directory\n' "$CLAUDE_PROJECT_DIR" >&2
    printf 'resolve-project-dir: error:   correct it, or unset it to resolve from the working directory\n' >&2
    exit 1
  elif [ "$_status" -ne 0 ]; then
    printf 'resolve-project-dir: error: cannot determine the project root from '\''%s'\''\n' "$PWD" >&2
    printf 'resolve-project-dir: error:   no ancestor holds a .claude/ directory, and this is not a git repository\n' >&2
    printf 'resolve-project-dir: error:   run from inside the project, or set CLAUDE_PROJECT_DIR to its path\n' >&2
    exit 1
  fi
fi
