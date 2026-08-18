#!/usr/bin/env bash
# Plans-directory resolution: the default, the override, and what it refuses.
#
# Fixtures live under mktemp for the same reason as test-project-dir.sh: this
# repo has its own .claude/, so a fixture nested inside it would resolve to the
# repo root and the negative cases would pass for the wrong reason.

PTMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hcf-plansdir.XXXXXX")" && pwd -P)"
PPLUGIN="$(make_plugin_root "$PTMP/plugin" alpha.md)"
RESOLVE="$PPLUGIN/hooks/resolve-plans-dir.sh"

# A project with no hcf.json is the normal case, not a configured one.
PLAIN="$PTMP/plain"; mkdir -p "$PLAIN/.claude" "$PLAIN/sub"
out="$(cd "$PLAIN" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" 2>/dev/null)"; code=$?
assert_exit "it exits 0 for a project with no hcf.json" 0 "$code"
assert_eq "it defaults to .claude/plans" "$PLAIN/.claude/plans" "$out"

# The whole point of resolving from an anchor: the answer cannot depend on
# where the caller was standing.
out="$(cd "$PLAIN/sub" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" 2>/dev/null)"
assert_eq "it returns the same directory from a subdirectory" "$PLAIN/.claude/plans" "$out"

# The feature itself.
CONF="$PTMP/configured"; mkdir -p "$CONF/.claude" "$CONF/nested/deeper"
printf '{\n  "plansDir": "docs/plans"\n}\n' > "$CONF/.claude/hcf.json"
out="$(cd "$CONF" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" 2>/dev/null)"; code=$?
assert_exit "it exits 0 for a configured plansDir" 0 "$code"
assert_eq "it honors plansDir from hcf.json" "$CONF/docs/plans" "$out"

out="$(cd "$CONF/nested/deeper" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" 2>/dev/null)"
assert_eq "it honors plansDir from a subdirectory too" "$CONF/docs/plans" "$out"

# hcf.json is user-authored, so formatting varies.
printf '{"plansDir":"plans"}' > "$CONF/.claude/hcf.json"
out="$(cd "$CONF" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" 2>/dev/null)"
assert_eq "it reads a minified single-line hcf.json" "$CONF/plans" "$out"

printf '{\n  "somethingElse": true,\n  "plansDir"  :   "docs/plans"  ,\n  "other": 1\n}\n' > "$CONF/.claude/hcf.json"
out="$(cd "$CONF" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" 2>/dev/null)"
assert_eq "it reads plansDir amid other keys and loose spacing" "$CONF/docs/plans" "$out"

# A file with no plansDir key is not a configured project.
printf '{\n  "somethingElse": true\n}\n' > "$CONF/.claude/hcf.json"
out="$(cd "$CONF" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" 2>/dev/null)"; code=$?
assert_exit "it exits 0 when hcf.json omits plansDir" 0 "$code"
assert_eq "it falls back to the default when hcf.json omits plansDir" "$CONF/.claude/plans" "$out"

# Refusals. A bad value writes plan folders somewhere the project never asked
# for, so it stops rather than falling back — the same call 2.1.0 made for an
# invalid `phase`.
printf '{"plansDir": "/etc/plans"}' > "$CONF/.claude/hcf.json"
err="$(cd "$CONF" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" 2>&1 >/dev/null)"; code=$?
assert_exit "it exits 1 on an absolute plansDir" 1 "$code"
assert_contains "it says an absolute plansDir must be relative" "$err" "must be relative to the project root"

out="$(cd "$CONF" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" 2>/dev/null)"
assert_empty "it prints no path on an absolute plansDir" "$out"

printf '{"plansDir": "../outside/plans"}' > "$CONF/.claude/hcf.json"
err="$(cd "$CONF" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" 2>&1 >/dev/null)"; code=$?
assert_exit "it exits 1 on a plansDir that escapes the project" 1 "$code"
assert_contains "it names the .. segment as the problem" "$err" "must not contain a '..' segment"

printf '{"plansDir": "docs/../../plans"}' > "$CONF/.claude/hcf.json"
code="$(cd "$CONF" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" >/dev/null 2>&1; echo $?)"
assert_exit "it exits 1 on a .. segment in the middle of the path" 1 "$code"

printf '{"plansDir": ""}' > "$CONF/.claude/hcf.json"
err="$(cd "$CONF" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" 2>&1 >/dev/null)"; code=$?
assert_exit "it exits 1 on an empty plansDir" 1 "$code"
assert_contains "it distinguishes an empty plansDir from an absent one" "$err" "sets an empty plansDir"

# A directory named with spaces is ordinary on macOS, and was the bug Michiel's
# original `mkdir -p $PLANS_DIR/...` would have hit unquoted.
printf '{"plansDir": "my docs/my plans"}' > "$CONF/.claude/hcf.json"
out="$(cd "$CONF" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" 2>/dev/null)"; code=$?
assert_exit "it exits 0 for a plansDir containing spaces" 0 "$code"
assert_eq "it returns a plansDir containing spaces intact" "$CONF/my docs/my plans" "$out"

# Resolution inherits the project anchor, so it inherits its refusal too.
OUT2="$PTMP/outside"; mkdir -p "$OUT2"
err="$(cd "$OUT2" && env -u CLAUDE_PROJECT_DIR "$RESOLVE" 2>&1 >/dev/null)"; code=$?
assert_exit "it exits 1 when no project root can be resolved" 1 "$code"
assert_contains "it reports the unresolvable project root" "$err" "cannot determine the project root"

# CLAUDE_PROJECT_DIR names the project; the config is read from there, not cwd.
out="$(cd "$OUT2" && env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$PLAIN" "$RESOLVE" 2>/dev/null)"
assert_eq "it reads the config from CLAUDE_PROJECT_DIR, not the cwd" "$PLAIN/.claude/plans" "$out"

err="$(cd "$PLAIN" && env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$PTMP/nope" "$RESOLVE" 2>&1 >/dev/null)"; code=$?
assert_exit "it exits 1 when CLAUDE_PROJECT_DIR is not a directory" 1 "$code"
assert_contains "it names the bad CLAUDE_PROJECT_DIR" "$err" "not a directory"

# A partial install must say so rather than guess.
NOPROJ="$PTMP/noproj"; mkdir -p "$NOPROJ/hooks" "$NOPROJ/agents"
cp "$REPO_ROOT/hooks/resolve-plans-dir.sh" "$NOPROJ/hooks/"
chmod +x "$NOPROJ/hooks/resolve-plans-dir.sh"
err="$(cd "$PLAIN" && env -u CLAUDE_PROJECT_DIR "$NOPROJ/hooks/resolve-plans-dir.sh" 2>&1 >/dev/null)"; code=$?
assert_exit "it exits 1 when resolve-project-dir.sh is missing" 1 "$code"
assert_contains "it names the missing project resolver" "$err" "resolve-project-dir.sh not found"

rm -rf "$PTMP"
