#!/usr/bin/env bash
# HCF test suite. Zero dependencies: bash 3.2+, awk, sed, sort, grep.
#
#   ./tests/run-tests.sh              # all suites
#   ./tests/run-tests.sh test-parse   # one suite (with or without .sh)

set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$DIR/lib.sh"

rm -rf "$DIR/.tmp"

if [ $# -gt 0 ]; then
  suites=""
  for arg in "$@"; do
    name="${arg%.sh}"
    if [ -f "$DIR/$name.sh" ]; then
      suites="$suites $DIR/$name.sh"
    else
      printf 'run-tests: no such suite: %s\n' "$name" >&2
      exit 2
    fi
  done
else
  shopt -s nullglob
  suites=""
  for f in "$DIR"/test-*.sh; do
    suites="$suites $f"
  done
  shopt -u nullglob
fi

if [ -z "$suites" ]; then
  printf 'run-tests: no suites found in %s\n' "$DIR" >&2
  exit 2
fi

for suite in $suites; do
  printf '\n\033[1m%s\033[0m\n' "$(basename "$suite" .sh)"
  # Sourced, not executed, so counters accumulate across suites.
  # shellcheck source=/dev/null
  . "$suite"
done

rm -rf "$DIR/.tmp"

printf '\n'
if [ "$TESTS_FAILED" -eq 0 ]; then
  printf '\033[32m%d passed\033[0m\n' "$TESTS_RUN"
  exit 0
fi
printf '\033[31m%d failed\033[0m, %d passed, %d total\n' \
  "$TESTS_FAILED" "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
exit 1
