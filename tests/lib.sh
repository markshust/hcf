#!/usr/bin/env bash
# Shared assertions and fixture helpers for the HCF test suite.
#
# Zero dependencies beyond bash/awk/sed/sort/grep, and must run under bash 3.2
# (stock macOS /bin/bash) as well as modern Linux bash.

TESTS_RUN=0
TESTS_FAILED=0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_ROOT/tests/fixtures"

# Every invocation runs through here. The suite executes inside a Claude Code
# session where CLAUDE_PROJECT_DIR and CLAUDE_PLUGIN_ROOT may be exported; if
# they leaked in, the script would resolve a real project instead of the
# fixture sandbox and the tests would silently test the wrong thing.
run_script() {
  local plugin_root="$1"; shift
  local project_dir="$1"; shift
  env -u CLAUDE_PLUGIN_ROOT \
    CLAUDE_PROJECT_DIR="$project_dir" \
    "$plugin_root/hooks/discover-hooks.sh" "$@"
}

# Build a throwaway plugin root containing a copy of the real script plus an
# agents/ dir composed from the named fixture files. The script self-locates
# from ${BASH_SOURCE[0]}, so copying it in is how tests point it at fixture
# agents — there is deliberately no --target flag to override that path.
#
#   make_plugin_root <dest> [fixture-file ...]
make_plugin_root() {
  local dest="$1"; shift
  mkdir -p "$dest/hooks" "$dest/agents"
  cp "$REPO_ROOT/hooks/discover-hooks.sh" "$dest/hooks/"
  chmod +x "$dest/hooks/discover-hooks.sh"
  local f
  for f in "$@"; do
    cp "$FIXTURES/$f" "$dest/agents/"
  done
  printf '%s' "$dest"
}

#   make_project <dest> [fixture-file ...]   -> project root with .claude/agents
make_project() {
  local dest="$1"; shift
  mkdir -p "$dest/.claude/agents"
  local f
  for f in "$@"; do
    cp "$FIXTURES/$f" "$dest/.claude/agents/"
  done
  printf '%s' "$dest"
}

new_tmpdir() {
  mkdir -p "$REPO_ROOT/tests/.tmp"
  mktemp -d "$REPO_ROOT/tests/.tmp/t.XXXXXX"
}

_pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '  \033[32m✓\033[0m %s\n' "$1"
}

_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  \033[31m✗\033[0m %s\n' "$1"
  shift
  local line
  for line in "$@"; do
    printf '      %s\n' "$line"
  done
}

assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    _pass "$1"
  else
    _fail "$1" "expected: [$2]" "actual:   [$3]"
  fi
}

assert_exit() { # <desc> <expected-code> <actual-code>
  if [ "$2" = "$3" ]; then
    _pass "$1"
  else
    _fail "$1" "expected exit $2, got $3"
  fi
}

assert_contains() { # <desc> <haystack> <needle>
  case "$2" in
    *"$3"*) _pass "$1" ;;
    *) _fail "$1" "expected to contain: [$3]" "actual: [$2]" ;;
  esac
}

assert_not_contains() { # <desc> <haystack> <needle>
  case "$2" in
    *"$3"*) _fail "$1" "expected NOT to contain: [$3]" "actual: [$2]" ;;
    *) _pass "$1" ;;
  esac
}

assert_empty() { # <desc> <actual>
  if [ -z "$2" ]; then
    _pass "$1"
  else
    _fail "$1" "expected empty output" "actual: [$2]"
  fi
}

# Collapses runs of whitespace so assertions describe fields rather than column
# padding. The exact alignment of the human table is cosmetic; what it *says*
# is not.
normalize_ws() {
  printf '%s' "$1" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}
