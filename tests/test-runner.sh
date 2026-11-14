#!/usr/bin/env bash
# run-tests.sh itself: --filter runs only the assertions whose description
# contains the filter, so one test can be run on its own (HCF's TDD verifier
# needs a run filtered to a requirement's name).
#
# The runner wipes tests/.tmp, so it runs from a copy in its own directory.

RT_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hcf-runner.XXXXXX")" && pwd -P)"
mkdir -p "$RT_DIR/tests"
cp "$REPO_ROOT/tests/run-tests.sh" "$REPO_ROOT/tests/lib.sh" "$RT_DIR/tests/"
cat > "$RT_DIR/tests/test-demo.sh" <<'EOF'
assert_eq "it adds two numbers" 2 2
assert_eq "it subtracts two numbers" 0 1
EOF
_esc="$(printf '\033')"
rt() { "$RT_DIR/tests/run-tests.sh" "$@" 2>&1 | sed "s/${_esc}\[[0-9;]*m//g"; }

out="$(rt --filter "adds two numbers")"
assert_contains "it runs only the assertions whose description contains the filter" "$out" "1 passed"
assert_not_contains "it leaves out the assertions the filter does not name" "$out" "subtracts"
out="$(rt test-demo --filter "it subtracts two numbers")"
assert_contains "it reports a filtered failure with the failure count" "$out" "1 failed"
assert_contains "it marks the failing assertion at the start of its line" "$out" "✗ it subtracts two numbers"
out="$(rt --filter="ADDS TWO")"
assert_contains "it matches the filter in any case" "$out" "1 passed"
out="$(rt --filter "multiplies")"
assert_contains "it says no tests were found when the filter matches nothing" "$out" "No tests found"
"$RT_DIR/tests/run-tests.sh" --filter "multiplies" > /dev/null 2>&1
assert_exit "it exits non-zero when the filter matches nothing" 1 "$?"
rm -rf "$RT_DIR"
