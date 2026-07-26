#!/usr/bin/env bash
# Human table and --json rendering.

TMP="$(new_tmpdir)"
PLUGIN="$(make_plugin_root "$TMP/plugin" alpha.md quoted.md)"
PROJECT="$(make_project "$TMP/project")"

# --- filtered ---------------------------------------------------------------
out="$(run_script "$PLUGIN" "$PROJECT" --hook=post-plan 2>/dev/null)"
assert_contains "it prints a header naming the hook" "$out" "# hook: post-plan"
assert_contains "it prints name order and mode for each resolved agent" \
  "$(normalize_ws "$out")" "order=10 name=alpha mode=single"

# A Bash call's stdout is visible in the transcript, so a filtered empty result
# must be ABSOLUTELY silent or the empty-hook rule is violated by the fix.
out="$(run_script "$PLUGIN" "$PROJECT" --hook=pre-batch 2>/dev/null)"; code=$?
assert_empty "it prints nothing for a filtered hook with no enrolled agents" "$out"
assert_exit "it exits 0 when a filtered hook resolves empty" 0 "$code"

# --- unfiltered (by-hand debugging view) ------------------------------------
all="$(run_script "$PLUGIN" "$PROJECT" 2>/dev/null)"
hooks="$(printf '%s\n' "$all" | grep -c '^# hook: ')"
assert_eq "it prints all 8 hooks when no hook filter is given" "8" "$hooks"
assert_contains "it prints an explicit empty marker in the unfiltered view" "$all" "(empty — no agents enrolled at this hook)"
assert_eq "it prints the hooks in canonical HOOKS.md order" \
  "pre-plan post-plan pre-implementation pre-batch post-batch post-implementation pre-commit post-commit" \
  "$(printf '%s\n' "$all" | sed -n 's/^# hook: //p' | tr '\n' ' ' | sed 's/ $//')"

out="$(run_script "$PLUGIN" "$PROJECT" --hook=post-plan 2>/dev/null)"
assert_eq "it prints only the requested hook when --hook is given" "1" \
  "$(printf '%s\n' "$out" | grep -c '^# hook: ')"

# --- json -------------------------------------------------------------------
json="$(run_script "$PLUGIN" "$PROJECT" --json --hook=post-plan 2>/dev/null)"
assert_eq "it emits the expected json for a resolved hook" \
  '{"hooks":{"post-plan":[{"name":"alpha","order":10,"mode":"single"}]}}' "$json"

empty_json="$(run_script "$PLUGIN" "$PROJECT" --json --hook=pre-batch 2>/dev/null)"
assert_eq "it emits an empty json array for a hook with no enrolled agents" \
  '{"hooks":{"pre-batch":[]}}' "$empty_json"

full_json="$(run_script "$PLUGIN" "$PROJECT" --json 2>/dev/null)"
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$full_json" | python3 -m json.tool >/dev/null 2>&1; then
    _pass "it emits valid json for all 8 hooks"
  else
    _fail "it emits valid json for all 8 hooks" "python3 -m json.tool rejected: $full_json"
  fi
  keys="$(printf '%s' "$full_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["hooks"]))')"
  assert_eq "it includes all 8 hooks in unfiltered json" "8" "$keys"
else
  _pass "it emits valid json for all 8 hooks (skipped: no python3)"
  _pass "it includes all 8 hooks in unfiltered json (skipped: no python3)"
fi

assert_not_contains "it omits the md extension from agent names in json output" "$full_json" ".md"

# Agent names come from user-authored frontmatter, so a quote in a name must
# not produce malformed JSON.
QUOTE="$TMP/quote"
make_plugin_root "$QUOTE" >/dev/null
cat > "$QUOTE/agents/tricky.md" <<'EOF'
---
name: "he said \"hi\" \\ then left"
phase: post-plan
order: 5
mode: single
---
EOF
qjson="$(run_script "$QUOTE" "$PROJECT" --json --hook=post-plan 2>/dev/null)"
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$qjson" | python3 -m json.tool >/dev/null 2>&1; then
    _pass "it escapes quotes and backslashes in json output"
  else
    _fail "it escapes quotes and backslashes in json output" "rejected: $qjson"
  fi
else
  _pass "it escapes quotes and backslashes in json output (skipped: no python3)"
fi

rm -rf "$TMP"
