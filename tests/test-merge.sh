#!/usr/bin/env bash
# Local-overrides-plugin merge, fatal validation, and the deterministic sort.

TMP="$(new_tmpdir)"

# --- merge keyed on frontmatter name, not filename --------------------------
PLUGIN="$(make_plugin_root "$TMP/plugin" shadow-plugin.md alpha.md)"
PROJECT="$(make_project "$TMP/project" shadow-local.md)"
all="$(run_script "$PLUGIN" "$PROJECT" 2>/dev/null)"

assert_contains "it keys the override on the frontmatter name rather than the filename" \
  "$(normalize_ws "$all")" "order=90 name=shared-agent mode=batch"
assert_not_contains "it discards the plugin version entirely rather than merging fields" \
  "$(run_script "$PLUGIN" "$PROJECT" --hook=post-plan 2>/dev/null)" "shared-agent"
assert_contains "it keeps plugin agents whose name is not shadowed locally" "$all" "alpha"

count="$(printf '%s\n' "$all" | grep -c 'name=shared-agent')"
assert_eq "it yields exactly one entry for an overridden name" "1" "$count"

# --- duplicate name inside one directory ------------------------------------
DUP="$(make_plugin_root "$TMP/dup" dup-a.md dup-b.md)"
err="$(run_script "$DUP" "$PROJECT" 2>&1 >/dev/null)"; code=$?
assert_exit "it does not fail on a duplicate name in one directory" 0 "$code"
assert_contains "it warns about a duplicate name in one directory" "$err" "duplicate name 'dupe'"
dupcount="$(run_script "$DUP" "$PROJECT" 2>/dev/null | grep -c 'name=dupe')"
assert_eq "it picks a single deterministic winner for a duplicate name" "1" "$dupcount"

# --- fatal validation -------------------------------------------------------
BADP="$(make_plugin_root "$TMP/badphase" alpha.md bad-phase-1.md bad-phase-2.md)"
out="$(run_script "$BADP" "$PROJECT" --hook=post-plan 2>/dev/null)"; code=$?
assert_exit "it exits 3 when an agent declares a phase outside the 8 known hooks" 3 "$code"
assert_empty "it writes nothing to stdout when validation fails" "$out"

err="$(run_script "$BADP" "$PROJECT" --hook=post-plan 2>&1 >/dev/null)"
assert_contains "it names the offending file in the unknown-phase error" "$err" "bad-phase-1.md"
assert_contains "it names the offending value in the unknown-phase error" "$err" "unknown phase 'execution'"
assert_contains "it lists the valid phases in the unknown-phase error" "$err" "valid phases: pre-plan post-plan"
assert_contains "it names the remove-the-phase-key remedy" "$err" "remove its 'phase' key entirely"
assert_contains "it reports every invalid file before exiting rather than only the first" "$err" "bad-phase-2"

# Validation is global: a bad value in a post-commit agent must abort a
# pre-plan query, because the earliest report is the cheapest fix.
BADM="$(make_plugin_root "$TMP/badmode" alpha.md bad-mode.md)"
run_script "$BADM" "$PROJECT" --hook=pre-plan >/dev/null 2>&1
assert_exit "it aborts on an invalid agent belonging to a hook other than the one queried" 3 "$?"
err="$(run_script "$BADM" "$PROJECT" 2>&1 >/dev/null)"
assert_contains "it exits 3 when an agent declares a mode other than single or batch" "$err" "unknown mode 'batched'"
assert_contains "it lists the valid modes in the unknown-mode error" "$err" "valid modes: single batch"

# --- sort and tie-break -----------------------------------------------------
# A clean project: $PROJECT carries shadow-local.md, which also enrolls at
# pre-commit and would otherwise join the rows under test.
SORT="$(make_plugin_root "$TMP/sort" apple.md banana.md quoted.md)"
SORTPROJ="$(make_project "$TMP/sortproject")"
rows="$(run_script "$SORT" "$SORTPROJ" --hook=pre-commit 2>/dev/null | grep 'order=')"
assert_eq "it sorts by order ascending" \
  "quoted # not-a-comment" \
  "$(printf '%s\n' "$rows" | head -1 | sed 's/.*name=//; s/  *mode=.*//')"
assert_eq "it tie-breaks equal order by name case-insensitively" \
  "Apple banana" \
  "$(printf '%s\n' "$rows" | tail -2 | sed 's/.*name=//; s/  *mode=.*//' | tr '\n' ' ' | sed 's/ $//')"

# Tie-break must not depend on the ambient locale, or a macOS en_US.UTF-8 user
# and a Linux C user disagree about the pipeline.
c_order="$(LC_ALL=C run_script "$SORT" "$SORTPROJ" --hook=pre-commit 2>/dev/null)"
u_order="$(LC_ALL=en_US.UTF-8 run_script "$SORT" "$SORTPROJ" --hook=pre-commit 2>/dev/null)"
assert_eq "it produces the same tie-break order regardless of the ambient locale" "$c_order" "$u_order"

rm -rf "$TMP"
