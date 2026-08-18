#!/usr/bin/env bash
# Project-root resolution: the anchor, the boundary, and the refusal.
#
# These fixtures deliberately live under mktemp rather than tests/.tmp. The HCF
# repo has its own .claude/, so a fixture nested inside it would resolve to the
# repo root and the "no project here" cases would silently pass for the wrong
# reason — the exact class of false-positive this suite exists to catch.

# pwd -P, not pwd: $TMPDIR often carries a trailing slash, and on macOS it sits
# under /var, a symlink to /private/var. The resolver answers in physical form,
# so the expectations here must be physical too.
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hcf-projdir.XXXXXX")" && pwd -P)"
PLUGIN="$(make_plugin_root "$TMP/plugin" alpha.md)"

# A project root is a directory containing .claude/. Local agents live under
# .claude/agents; a project may have the former without the latter.
PROJ="$TMP/proj"
mkdir -p "$PROJ/.claude/agents" "$PROJ/src/deep/nested"
cp "$FIXTURES/defaults.md" "$PROJ/.claude/agents/"

out="$(cd "$PROJ" && run_script_cwd "$PLUGIN" --hook=pre-batch 2>/dev/null)"
assert_contains "it resolves the project from the cwd when CLAUDE_PROJECT_DIR is unset" "$out" "defaults"

out="$(cd "$PROJ/src/deep/nested" && run_script_cwd "$PLUGIN" --hook=pre-batch 2>/dev/null)"
assert_contains "it resolves the same project from a nested subdirectory" "$out" "defaults"

# The regression. Before this, running from outside the project emitted a
# plugin-only enrollment and a valid-looking digest, and the omission of every
# project-local agent surfaced hours later as a bogus drift halt.
OUTSIDE="$TMP/outside"; mkdir -p "$OUTSIDE"
err="$(cd "$OUTSIDE" && run_script_cwd "$PLUGIN" --hook=pre-batch 2>&1 >/dev/null)"; code=$?
assert_exit "it exits 1 rather than guessing when no project can be resolved" 1 "$code"
assert_contains "it names the directory it could not resolve from" "$err" "$OUTSIDE"
assert_contains "it names the remedy in the resolution error" "$err" "set CLAUDE_PROJECT_DIR"

# A refusal is only useful if it also stops the digest. A fingerprint captured
# outside the project is the artifact that poisons a later drift check.
out="$(cd "$OUTSIDE" && run_script_cwd "$PLUGIN" --fingerprint 2>/dev/null)"; code=$?
assert_exit "it exits 1 for --fingerprint when no project can be resolved" 1 "$code"
assert_empty "it emits no digest when no project can be resolved" "$out"

# The digest must not depend on where the caller happened to be standing.
root_fp="$(cd "$PROJ" && run_script_cwd "$PLUGIN" --fingerprint 2>/dev/null)"
nested_fp="$(cd "$PROJ/src/deep/nested" && run_script_cwd "$PLUGIN" --fingerprint 2>/dev/null)"
assert_eq "it produces the same fingerprint from the root and a subdirectory" "$root_fp" "$nested_fp"

# $HOME is a boundary, not a candidate: ~/.claude is user-level Claude config,
# and resolving to it would enroll a user's personal agents into any repo they
# happened to be near.
FAKEHOME="$TMP/home"
mkdir -p "$FAKEHOME/.claude/agents" "$FAKEHOME/work"
cp "$FIXTURES/defaults.md" "$FAKEHOME/.claude/agents/"
err="$(cd "$FAKEHOME/work" && HOME="$FAKEHOME" && run_script_cwd "$PLUGIN" --hook=pre-batch 2>&1 >/dev/null)"; code=$?
assert_exit "it stops at \$HOME instead of treating ~/.claude as a project" 1 "$code"
assert_contains "it reports no project when only ~/.claude is above the cwd" "$err" "cannot determine the project root"

# A repo that has not created .claude/ yet is still a project. plan-create has
# no prerequisite on project-setup, so it can be the first HCF command run in a
# fresh repo; refusing there would block first use to prevent an answer that
# was never wrong.
FRESH="$TMP/freshrepo"
mkdir -p "$FRESH/sub"
(cd "$FRESH" && git init -q .) 2>/dev/null
out="$(cd "$FRESH/sub" && env -u CLAUDE_PROJECT_DIR "$PLUGIN/hooks/resolve-project-dir.sh" 2>/dev/null)"; code=$?
assert_exit "it falls back to the git root for a repo with no .claude yet" 0 "$code"
assert_eq "it resolves the git root, not the subdirectory" "$FRESH" "$out"

(cd "$FRESH/sub" && run_script_cwd "$PLUGIN" --hook=post-plan) >/dev/null 2>&1
assert_exit "it enumerates rather than halting in a fresh repo" 0 "$?"

# The git fallback must not rescue the case the walk is meant to refuse.
assert_exit "it still refuses a directory that is neither a repo nor under .claude" 1 \
  "$(cd "$OUTSIDE" && env -u CLAUDE_PROJECT_DIR "$PLUGIN/hooks/resolve-project-dir.sh" >/dev/null 2>&1; echo $?)"

# A dotfiles repo at $HOME is not the project you are working in.
HOMEREPO="$TMP/homerepo"
mkdir -p "$HOMEREPO/work"
(cd "$HOMEREPO" && git init -q .) 2>/dev/null
code="$(cd "$HOMEREPO/work" && HOME="$HOMEREPO" && env -u CLAUDE_PROJECT_DIR "$PLUGIN/hooks/resolve-project-dir.sh" >/dev/null 2>&1; echo $?)"
assert_exit "it does not resolve a git repository rooted at \$HOME" 1 "$code"

# Set but pointing nowhere is the same silent-degradation trap one level up:
# enumeration finds no local agents and reports a well-formed answer.
err="$(run_script "$PLUGIN" "$TMP/does-not-exist" --fingerprint 2>&1 >/dev/null)"; code=$?
assert_exit "it exits 1 when CLAUDE_PROJECT_DIR is not a directory" 1 "$code"
assert_contains "it names the bad CLAUDE_PROJECT_DIR value" "$err" "$TMP/does-not-exist"
assert_contains "it says how to recover from a bad CLAUDE_PROJECT_DIR" "$err" "unset it"

out="$(run_script "$PLUGIN" "$TMP/does-not-exist" --fingerprint 2>/dev/null)"
assert_empty "it emits no digest when CLAUDE_PROJECT_DIR is not a directory" "$out"

# CLAUDE_PROJECT_DIR still wins, and still needs no .claude/ of its own — a
# project that has not created one yet is still that project.
PROJ2="$(make_project "$TMP/proj2" defaults.md)"
out="$(cd "$OUTSIDE" && run_script "$PLUGIN" "$PROJ2" --hook=pre-batch 2>/dev/null)"
assert_contains "it prefers CLAUDE_PROJECT_DIR over the cwd walk" "$out" "defaults"

NOCLAUDE="$TMP/noclaude"; mkdir -p "$NOCLAUDE"
run_script "$PLUGIN" "$NOCLAUDE" --hook=post-plan >/dev/null 2>&1
assert_exit "it accepts a CLAUDE_PROJECT_DIR with no .claude directory" 0 "$?"

# Real project paths contain spaces, and so does the walk that finds them.
SPACED="$TMP/dir with spaces/my project"
mkdir -p "$SPACED/.claude/agents" "$SPACED/nested dir"
cp "$FIXTURES/defaults.md" "$SPACED/.claude/agents/"
out="$(cd "$SPACED/nested dir" && run_script_cwd "$PLUGIN" --hook=pre-batch 2>/dev/null)"
assert_contains "it walks up through a path containing spaces" "$out" "defaults"

# The resolver is a sibling of discover-hooks.sh; a partial install must say so
# rather than fall back to a guess.
NORESOLVER="$TMP/noresolver"; mkdir -p "$NORESOLVER/hooks" "$NORESOLVER/agents"
cp "$FIXTURES/alpha.md" "$NORESOLVER/agents/"
cp "$REPO_ROOT/hooks/discover-hooks.sh" "$NORESOLVER/hooks/"
chmod +x "$NORESOLVER/hooks/discover-hooks.sh"
err="$(cd "$PROJ" && run_script_cwd "$NORESOLVER" --hook=post-plan 2>&1 >/dev/null)"; code=$?
assert_exit "it exits 1 when the project resolver is missing from the install" 1 "$code"
assert_contains "it names the missing resolver" "$err" "project resolver not found"

# Run directly, the resolver prints the root it found and nothing else.
out="$(cd "$PROJ/src/deep" && env -u CLAUDE_PROJECT_DIR "$PLUGIN/hooks/resolve-project-dir.sh" 2>/dev/null)"; code=$?
assert_exit "it exits 0 when run standalone inside a project" 0 "$code"
assert_eq "it prints the project root when run standalone" "$PROJ" "$out"

out="$(cd "$OUTSIDE" && env -u CLAUDE_PROJECT_DIR "$PLUGIN/hooks/resolve-project-dir.sh" 2>/dev/null)"; code=$?
assert_exit "it exits 1 when run standalone outside a project" 1 "$code"
assert_empty "it prints nothing on stdout when run standalone outside a project" "$out"

rm -rf "$TMP"
