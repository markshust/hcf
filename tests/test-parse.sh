#!/usr/bin/env bash
# Frontmatter parsing and enrollment.

TMP="$(new_tmpdir)"
PLUGIN="$(make_plugin_root "$TMP/plugin" \
  alpha.md dormant.md no-phase.md documented-example.md quoted.md \
  defaults.md nonnumeric-order.md body-phase.md no-frontmatter.md \
  unterminated.md empty.md noname.md crlf.md)"
PROJECT="$(make_project "$TMP/project")"

all="$(run_script "$PLUGIN" "$PROJECT" 2>/dev/null)"
json="$(run_script "$PLUGIN" "$PROJECT" --json 2>/dev/null)"

assert_contains "it extracts name phase order and mode from the first frontmatter block" \
  "$(normalize_ws "$(run_script "$PLUGIN" "$PROJECT" --hook=post-plan 2>/dev/null)")" \
  "order=10 name=alpha mode=single"

# The single most important assertion in the suite: the bundled
# standards-enforcer ships with its phase commented out and was made opt-in
# deliberately. An unanchored match would enable it for every HCF user.
assert_not_contains "it does not enroll an agent whose phase key is commented out" "$all" "dormant"
assert_not_contains "it does not match a phase key appearing after the frontmatter block" "$all" "body-phase"
assert_not_contains "it skips an agent that declares no phase key" "$all" "no-phase"
assert_not_contains "it skips a file with no frontmatter block" "$all" "no-frontmatter"
assert_not_contains "it skips a file with an unterminated frontmatter block" "$all" "unterminated"

# A user copy-pasting the documented example must get a working agent.
assert_contains "it parses the frontmatter example documented in HOOKS.md and README.md" \
  "$(normalize_ws "$all")" "order=100 name=documented-example mode=single"

assert_contains "it strips surrounding quotes from frontmatter values" "$all" "quoted"
assert_contains "it preserves a hash character inside a quoted value" "$all" "quoted # not-a-comment"
assert_contains "it parses an agent file written with CRLF line endings" \
  "$(normalize_ws "$all")" "order=40 name=crlf mode=single"
assert_contains "it defaults a missing order to 100 and a missing mode to single" \
  "$(normalize_ws "$all")" "order=100 name=defaults mode=single"
assert_contains "it falls back to the filename when no name key is declared" "$all" "noname"

err="$(run_script "$PLUGIN" "$PROJECT" --hook=post-batch 2>&1 >/dev/null)"; code=$?
assert_exit "it does not fail on a non-numeric order" 0 "$code"
assert_contains "it warns about a non-numeric order" "$err" "non-numeric order 'high'"
assert_contains "it treats a non-numeric order as 100" \
  "$(normalize_ws "$(run_script "$PLUGIN" "$PROJECT" --hook=post-batch 2>/dev/null)")" \
  "order=100 name=nonnumeric-order"

# Only top-level *.md participates.
mkdir -p "$PLUGIN/agents/nested"
cp "$FIXTURES/alpha.md" "$PLUGIN/agents/nested/nested-agent.md"
cp "$FIXTURES/alpha.md" "$PLUGIN/agents/not-markdown.txt"
after="$(run_script "$PLUGIN" "$PROJECT" 2>/dev/null)"
assert_not_contains "it ignores markdown files in subdirectories" "$after" "nested"
assert_eq "it ignores files that are not markdown" "$all" "$after"

# JSON is a separate rendering path; the dormant case must hold there too.
assert_not_contains "it keeps a commented-out phase unenrolled in json output too" "$json" "dormant"

rm -rf "$TMP"
