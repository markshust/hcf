#!/usr/bin/env bash
# Argument parsing, directory resolution, and the exit-code contract.

TMP="$(new_tmpdir)"
PLUGIN="$(make_plugin_root "$TMP/plugin" alpha.md)"
PROJECT="$(make_project "$TMP/project")"

out="$(run_script "$PLUGIN" "$PROJECT" --help 2>&1)"; code=$?
assert_exit "it exits 0 for --help" 0 "$code"
assert_contains "it prints usage for --help" "$out" "--hook=<name>"

run_script "$PLUGIN" "$PROJECT" --bogus >/dev/null 2>&1
assert_exit "it exits 2 on an unrecognized flag" 2 "$?"

run_script "$PLUGIN" "$PROJECT" --hook=not-a-hook >/dev/null 2>&1
assert_exit "it exits 2 when --hook names a value outside the 8 known hooks" 2 "$?"

run_script "$PLUGIN" "$PROJECT" --hook= >/dev/null 2>&1
assert_exit "it exits 2 when --hook is given an empty value" 2 "$?"

out="$(run_script "$PLUGIN" "$PROJECT" --hook post-plan 2>&1)"; code=$?
assert_exit "it exits 2 when --hook is given in the space-separated form" 2 "$code"
assert_contains "it names the accepted form in the space-separated error" "$out" "--hook=<name>"

run_script "$PLUGIN" "$PROJECT" --fingerprint --expect=deadbeef >/dev/null 2>&1
assert_exit "it exits 2 when --fingerprint and --expect are both given" 2 "$?"

# A project with no .claude/agents at all is the common case, not an error.
NOLOCAL="$TMP/nolocal"; mkdir -p "$NOLOCAL"
run_script "$PLUGIN" "$NOLOCAL" --hook=post-plan >/dev/null 2>&1
assert_exit "it exits 0 when the project has no local agents directory" 0 "$?"

# Plugin agents/ missing entirely: the script cannot do its job.
BROKEN="$TMP/broken"; mkdir -p "$BROKEN/hooks"
cp "$REPO_ROOT/hooks/discover-hooks.sh" "$BROKEN/hooks/"
chmod +x "$BROKEN/hooks/discover-hooks.sh"
out="$(run_script "$BROKEN" "$PROJECT" --hook=post-plan 2>&1)"; code=$?
assert_exit "it exits 1 when the plugin agents directory cannot be resolved" 1 "$code"
assert_contains "it names the missing plugin agents dir" "$out" "plugin agents directory not found"

# Plugin agents/ present but empty: every hook resolving empty because the
# bundled agents vanished is the original bug reached by another route.
EMPTYP="$TMP/emptyplugin"; make_plugin_root "$EMPTYP" >/dev/null
err="$(run_script "$EMPTYP" "$PROJECT" --hook=post-plan 2>&1 >/dev/null)"; code=$?
assert_exit "it exits 0 when the plugin agents dir has no md files" 0 "$code"
assert_contains "it warns when the plugin agents dir has no md files" "$err" "contains no .md files"

# Self-location: the plugin dir must come from the script's own path, never cwd.
out="$(cd / && run_script "$PLUGIN" "$PROJECT" --hook=post-plan 2>/dev/null)"
assert_contains "it resolves the plugin agents dir relative to the script not the cwd" "$out" "alpha"

# CLAUDE_PROJECT_DIR is how the script finds project-local agents.
PROJ2="$(make_project "$TMP/proj2" defaults.md)"
out="$(run_script "$PLUGIN" "$PROJ2" --hook=pre-batch 2>/dev/null)"
assert_contains "it honors CLAUDE_PROJECT_DIR when locating local agents" "$out" "defaults"

# Real plugin install roots contain spaces.
SPACED="$TMP/dir with spaces"
make_plugin_root "$SPACED/plugin" alpha.md >/dev/null
make_project "$SPACED/project" defaults.md >/dev/null
out="$(run_script "$SPACED/plugin" "$SPACED/project" 2>/dev/null)"
assert_contains "it resolves both directories when their paths contain spaces" "$out" "alpha"
assert_contains "it reads local agents from a path containing spaces" "$out" "defaults"

rm -rf "$TMP"
