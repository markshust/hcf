#!/usr/bin/env bash
# Fingerprint stability and drift detection.

TMP="$(new_tmpdir)"
PLUGIN="$(make_plugin_root "$TMP/plugin" alpha.md defaults.md)"
PROJECT="$(make_project "$TMP/project")"

fp() { run_script "$1" "$2" --fingerprint 2>/dev/null; }

base="$(fp "$PLUGIN" "$PROJECT")"
assert_contains "it prints a versioned fingerprint line" "$base" "discover-hooks-fingerprint-v1 "
hash="${base##* }"
assert_eq "it prints a 64-hex digest" "64" "${#hash}"
assert_eq "it prints the same fingerprint across runs when nothing changed" "$base" "$(fp "$PLUGIN" "$PROJECT")"

# Editing an agent's prose is deliberately NOT drift — hashing bodies would
# fire on every typo fix and on any plugin upgrade that touches prose.
printf '\nAn extra paragraph of prose.\n' >> "$PLUGIN/agents/alpha.md"
assert_eq "it prints the same fingerprint when only an agent body changed" "$base" "$(fp "$PLUGIN" "$PROJECT")"

cp "$FIXTURES/apple.md" "$PLUGIN/agents/"
added="$(fp "$PLUGIN" "$PROJECT")"
assert_eq "it prints a different fingerprint when an agent is added" "1" \
  "$([ "$added" != "$base" ] && echo 1 || echo 0)"

rm -f "$PLUGIN/agents/apple.md"
assert_eq "it returns to the original fingerprint when the addition is reverted" "$base" "$(fp "$PLUGIN" "$PROJECT")"

rm -f "$PLUGIN/agents/defaults.md"
removed="$(fp "$PLUGIN" "$PROJECT")"
assert_eq "it prints a different fingerprint when an agent is removed" "1" \
  "$([ "$removed" != "$base" ] && echo 1 || echo 0)"
cp "$FIXTURES/defaults.md" "$PLUGIN/agents/"

sed 's/^order: 10$/order: 20/' "$FIXTURES/alpha.md" > "$PLUGIN/agents/alpha.md"
reordered="$(fp "$PLUGIN" "$PROJECT")"
assert_eq "it prints a different fingerprint when an order changed" "1" \
  "$([ "$reordered" != "$base" ] && echo 1 || echo 0)"
cp "$FIXTURES/alpha.md" "$PLUGIN/agents/"

# Origin is in the hash: shadowing a plugin agent with a local file carrying
# identical enrollment keys but a different prompt body would otherwise be a
# silent agent swap that drift detection never reports.
SHADOW_P="$(make_plugin_root "$TMP/sp" shadow-plugin.md)"
SHADOW_L="$(make_project "$TMP/sl")"
before_shadow="$(fp "$SHADOW_P" "$SHADOW_L")"
cat > "$SHADOW_L/.claude/agents/shadow-plugin.md" <<'EOF'
---
name: shared-agent
description: "Same enrollment keys, completely different instructions."
phase: post-plan
order: 10
mode: single
---
Do something entirely different.
EOF
assert_eq "it prints a different fingerprint when a local agent shadows a plugin agent with identical keys" "1" \
  "$([ "$(fp "$SHADOW_P" "$SHADOW_L")" != "$before_shadow" ] && echo 1 || echo 0)"

# An enrollment set that resolves empty everywhere has a defined fingerprint.
EMPTY="$(make_plugin_root "$TMP/empty" no-phase.md)"
efp="$(fp "$EMPTY" "$PROJECT")"
assert_contains "it produces a defined fingerprint for an empty enrollment set" "$efp" "discover-hooks-fingerprint-v1 "
assert_eq "it produces a stable fingerprint for an empty enrollment set" "$efp" "$(fp "$EMPTY" "$PROJECT")"

# Path independence: two checkouts of identical content at different paths must
# agree, or two developers halt each other's runs.
COPY="$TMP/elsewhere/deeper"
mkdir -p "$COPY"
cp -R "$PLUGIN" "$COPY/plugin"
assert_eq "it produces the same fingerprint for identical content at a different path" \
  "$base" "$(fp "$COPY/plugin" "$PROJECT")"

# --- --expect ---------------------------------------------------------------
run_script "$PLUGIN" "$PROJECT" --expect="$base" --hook=post-plan >/dev/null 2>&1
assert_exit "it exits 0 when expect matches" 0 "$?"

out="$(run_script "$PLUGIN" "$PROJECT" --expect="$hash" --hook=post-plan 2>/dev/null)"; code=$?
assert_exit "it accepts a bare 64-hex digest for expect" 0 "$code"
assert_contains "it produces normal output when expect matches" "$out" "alpha"

json="$(run_script "$PLUGIN" "$PROJECT" --expect="$base" --json --hook=post-plan 2>/dev/null)"
assert_contains "it composes expect with json output" "$json" '"name":"alpha"'

stale="0000000000000000000000000000000000000000000000000000000000000000"
out="$(run_script "$PLUGIN" "$PROJECT" --expect="$stale" --hook=post-plan 2>/dev/null)"; code=$?
assert_exit "it exits 4 when expect does not match" 4 "$code"
assert_empty "it writes nothing to stdout when drift is detected" "$out"

err="$(run_script "$PLUGIN" "$PROJECT" --expect="$stale" --hook=post-plan 2>&1 >/dev/null)"
assert_contains "it says enrollment changed in the drift message" "$err" "hook enrollment changed since this run started"
assert_contains "it lists the current enrollment in the drift message" "$err" "alpha (post-plan"
assert_contains "it names the re-baseline escape hatch in the drift message" "$err" ".hook-fingerprint and re-run to re-baseline"

# A botched write must not masquerade as drift — that halts the run pointing at
# entirely the wrong cause.
for bad in "" "not-a-hash" "abc123" "$(printf 'zz%060d' 0)"; do
  run_script "$PLUGIN" "$PROJECT" --expect="$bad" --hook=post-plan >/dev/null 2>&1
  assert_exit "it exits 2 rather than 4 for a malformed expect value [$bad]" 2 "$?"
done

# A future hash-format bump must not brick every existing plan.
err="$(run_script "$PLUGIN" "$PROJECT" --expect="discover-hooks-fingerprint-v2 $stale" --hook=post-plan 2>&1 >/dev/null)"; code=$?
assert_exit "it exits 0 on a fingerprint version mismatch instead of reporting drift" 0 "$code"
assert_contains "it warns that the drift check was skipped on a version mismatch" "$err" "skipping the drift check"

# An invalid agent file is a more urgent report than a changed one.
BADV="$(make_plugin_root "$TMP/badv" alpha.md bad-mode.md)"
run_script "$BADV" "$PROJECT" --expect="$stale" --hook=post-plan >/dev/null 2>&1
assert_exit "it reports an invalid agent file as exit 3 even when drift is also present" 3 "$?"

rm -rf "$TMP"
