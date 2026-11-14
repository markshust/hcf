#!/usr/bin/env bash
# verify-tdd.sh and the TDD hooks: what counts as test-first, what does not.
#
# Transcripts are built from the same two record shapes Claude Code writes for a
# subagent: an assistant tool_use and a user tool_result. Projects live under
# mktemp so no real repo or plan is touched.

VT="$REPO_ROOT/hooks/verify-tdd.sh"
VPROJ="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hcf-verify.XXXXXX")" && pwd -P)"
VPLAN="$VPROJ/.claude/plans/demo"
mkdir -p "$VPLAN" "$VPROJ/src" "$VPROJ/tests"

TASK="$VPLAN/001-demo.md"
cat > "$TASK" <<'EOF'
# Task 001: Demo

## Requirements (Test Descriptions)
- [x] `it adds two numbers`
- [x] `it subtracts two numbers`
EOF

_n=0
# use <tool> <json-input>  /  res <is_error> <output>   (ids pair up in order)
tx_use() { _n=$((_n + 1)); jq -cn --arg id "t$_n" --arg name "$1" --argjson in "$2" --arg cwd "$VPROJ" \
  '{type:"assistant", cwd:$cwd, message:{content:[{type:"tool_use", id:$id, name:$name, input:$in}]}}'; }
tx_res() { jq -cn --arg id "t$_n" --argjson err "$1" --arg out "$2" \
  '{type:"user", message:{content:[{type:"tool_result", tool_use_id:$id, is_error:$err, content:$out}]}}'; }
add_test() { tx_use Edit "$(jq -cn --arg p "$VPROJ/tests/CalcTest.php" --arg s "it('$1', function () {});" '{file_path:$p, old_string:"", new_string:$s}')"; tx_res false "ok"; }
edit_src() { tx_use Edit "$(jq -cn --arg p "$VPROJ/src/Calc.php" '{file_path:$p, old_string:"a", new_string:"b"}')"; tx_res false "ok"; }
red() { tx_use Bash "$(jq -cn --arg c "./vendor/bin/pest --filter=\"$1\" --bail 2>&1 | tail -3" '{command:$c}')"; tx_res false "FAILED  CalcTest > $1  Tests: 1 failed"; }
green() { tx_use Bash '{"command":"./vendor/bin/pest tests --parallel"}'; tx_res false "Tests: 3 passed"; }

verify() { "$VT" "$TASK" "$1" > "$VPROJ/out" 2>&1; echo $?; }

# The method, followed: one test, red, code, green — twice.
T="$VPROJ/good.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green
  add_test "subtracts two numbers"; red "subtracts two"; edit_src; green; } > "$T"
assert_exit "it passes a transcript that goes red before green for each requirement" 0 "$(verify "$T")"

# Production code first.
T="$VPROJ/code-first.jsonl"
{ edit_src; add_test "adds two numbers"; red "adds two numbers"; green
  add_test "subtracts two numbers"; red "subtracts two"; edit_src; green; } > "$T"
assert_exit "it fails when production code changes before any failing test" 1 "$(verify "$T")"
assert_contains "it names the R2 violation for code written first" "$(cat "$VPROJ/out")" "R2 production file edited"

# Batch-written tests: both tests, then the runs.
T="$VPROJ/batch.jsonl"
{ add_test "adds two numbers"; add_test "subtracts two numbers"; red "adds two numbers"; edit_src; red "subtracts two"; edit_src; green; } > "$T"
assert_exit "it fails when several tests are written before a failing run" 1 "$(verify "$T")"
assert_contains "it names the R3 batch-writing violation" "$(cat "$VPROJ/out")" "R3 2 new tests"

# A requirement that never went red.
T="$VPROJ/never-red.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; add_test "subtracts two numbers"; green; } > "$T"
assert_exit "it fails when a requirement never had a failing run" 1 "$(verify "$T")"
assert_contains "it names the requirement that never failed" "$(cat "$VPROJ/out")" "R1 \`it subtracts two numbers\`"

# A crash is not red.
T="$VPROJ/oom.jsonl"
{ add_test "adds two numbers"; tx_use Bash '{"command":"./vendor/bin/pest --filter=\"adds two numbers\""}'
  tx_res true "PHP Fatal error: Allowed memory size of 134217728 bytes exhausted"; edit_src; green
  add_test "subtracts two numbers"; red "subtracts two"; edit_src; green; } > "$T"
assert_exit "it does not count an out-of-memory crash as a failing test" 1 "$(verify "$T")"

# An unfiltered failing run does not arm a requirement.
T="$VPROJ/unfiltered.jsonl"
{ add_test "adds two numbers"; tx_use Bash '{"command":"./vendor/bin/pest"}'; tx_res true "Tests: 1 failed"; edit_src; green
  add_test "subtracts two numbers"; red "subtracts two"; edit_src; green; } > "$T"
assert_exit "it does not count an unfiltered failing run as red" 1 "$(verify "$T")"

# A filter that fits more than one requirement names none of them.
T="$VPROJ/vague.jsonl"
{ add_test "adds two numbers"; red "two numbers"; edit_src; green
  add_test "subtracts two numbers"; red "subtracts two"; edit_src; green; } > "$T"
assert_exit "it does not count a filter that matches several requirements" 1 "$(verify "$T")"

# Production written from Bash is held to the same rule.
T="$VPROJ/bash-write.jsonl"
{ tx_use Bash "$(jq -cn --arg c "cat > src/Calc.php <<'E'
<?php return 1 -> 2;
E" '{command:$c}')"; tx_res false ""; add_test "adds two numbers"; red "adds two numbers"; green; } > "$T"
assert_exit "it fails a production file written from Bash" 1 "$(verify "$T")"
assert_contains "it reports the Bash write" "$(cat "$VPROJ/out")" "R4 project file changed from Bash"
assert_not_contains "it ignores arrows inside a heredoc body" "$(cat "$VPROJ/out")" "2;"

# A write through a variable is judged by where the variable points. The same
# command assigns it (shell state never survives between Bash calls).
OUTSIDE="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hcf-outside.XXXXXX")" && pwd -P)"
bash_use() { tx_use Bash "$(jq -cn --arg c "$1" '{command:$c}')"; tx_res false ""; }
T="$VPROJ/var-outside.jsonl"
{ bash_use "S=$OUTSIDE; mkdir -p \$S && cat > \$S/notes.txt <<'E'
scratch
E"
  add_test "adds two numbers"; red "adds two numbers"; edit_src; green
  add_test "subtracts two numbers"; red "subtracts two"; edit_src; green; } > "$T"
assert_exit "it ignores a write through a variable the same command points outside the project" 0 "$(verify "$T")"

T="$VPROJ/var-export.jsonl"
{ bash_use "export S=\"$OUTSIDE\"; printf x > \${S}/a.txt"
  add_test "adds two numbers"; red "adds two numbers"; edit_src; green
  add_test "subtracts two numbers"; red "subtracts two"; edit_src; green; } > "$T"
assert_exit "it expands an exported variable written as \${VAR}" 0 "$(verify "$T")"

T="$VPROJ/var-inside.jsonl"
{ bash_use "D=src; cat > \$D/Calc.php <<'E'
<?php return 1;
E"
  add_test "adds two numbers"; red "adds two numbers"; green; } > "$T"
assert_exit "it still fails a production file written through a variable that points into the project" 1 "$(verify "$T")"
assert_contains "it reports the expanded path of that write" "$(cat "$VPROJ/out")" "R4 project file changed from Bash (only Edit/Write may change files): $VPROJ/src/Calc.php"

T="$VPROJ/var-unset.jsonl"
{ bash_use "cat > \$NOT_SET/Calc.php <<'E'
<?php return 1;
E"
  add_test "adds two numbers"; red "adds two numbers"; green; } > "$T"
assert_exit "it still fails a write through a variable the command never assigns" 1 "$(verify "$T")"
rm -rf "$OUTSIDE"

# A (guard) requirement may pass on arrival, but must still be run on its own.
cp "$TASK" "$TASK.bak"
sed -i.tmp 's/`it subtracts two numbers`/`it subtracts two numbers` (guard)/' "$TASK"; rm -f "$TASK.tmp"
pass_run() { tx_use Bash "$(jq -cn --arg c "./vendor/bin/pest --filter=\"$1\"" '{command:$c}')"; tx_res false "Tests: 1 passed"; }
T="$VPROJ/guard-ok.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; add_test "subtracts two numbers"; pass_run "subtracts two"; green; } > "$T"
assert_exit "it accepts a guard requirement that passes on its first filtered run" 0 "$(verify "$T")"
T="$VPROJ/guard-unrun.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; add_test "subtracts two numbers"; green; } > "$T"
assert_exit "it fails a guard requirement never run on its own" 1 "$(verify "$T")"
assert_contains "it names the unrun guard" "$(cat "$VPROJ/out")" "guard \`it subtracts two numbers\` was never run"
mv "$TASK.bak" "$TASK"

# A first-run pass that no production code delivers (nothing to cut back) is
# justified with a no-code: reason, and needs review, not a silent pass.
cp "$TASK" "$TASK.bak"
printf '\nPASSED-FIRST: it subtracts two numbers — no-code: PHP integer arithmetic already does this\n' >> "$TASK"
T="$VPROJ/justified.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; add_test "subtracts two numbers"; green; } > "$T"
assert_exit "it asks for review when a first-run pass is justified as no-code" 2 "$(verify "$T")"
assert_contains "it tells the reviewer what to confirm" "$(cat "$VPROJ/out")" "no production code delivers it"
mv "$TASK.bak" "$TASK"
# Any other reason means code delivers it, so the answer is a cut-back.
cp "$TASK" "$TASK.bak"
printf '\nPASSED-FIRST: it subtracts two numbers — covered by the shared operator table\n' >> "$TASK"
assert_exit "it fails a first-run pass justified without a no-code: reason" 1 "$(verify "$T")"
assert_contains "it tells the worker to cut back instead" "$(cat "$VPROJ/out")" "R1 \`it subtracts two numbers\` passed on its first run and was not cut back"
mv "$TASK.bak" "$TASK"

# A worker that stops early: an unstarted requirement is not a method violation.
T="$VPROJ/unfinished.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; } > "$T"
assert_exit "it fails a task whose last requirement was never started" 1 "$(verify "$T")"
assert_contains "it reports the unstarted requirement as not attempted" "$(cat "$VPROJ/out")" "R1 \`it subtracts two numbers\` not attempted (no test written)"

# Modes used by the hooks and the orchestrator.
T="$VPROJ/good.jsonl"
assert_eq "it reports ARMED after a failing run" "ARMED" "$("$VT" --state "$TASK" "$T")"
T2="$VPROJ/disarmed.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; add_test "subtracts two numbers"; } > "$T2"
assert_eq "it reports DISARMED after a new test is added" "DISARMED" "$("$VT" --state "$TASK" "$T2")"
out="$(HCF_GATE_TOOL=Edit HCF_GATE_PATH="$VPROJ/src/Calc.php" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK" "$T2")"
assert_eq "it denies a production edit while disarmed" "DENY $VPROJ/src/Calc.php" "$out"
out="$(HCF_GATE_TOOL=Edit HCF_GATE_PATH="$VPROJ/tests/CalcTest.php" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK" "$T2")"
assert_eq "it allows a test edit while disarmed" "ALLOW" "$out"
out="$(HCF_GATE_TOOL=Bash HCF_GATE_CMD="echo x > src/Calc.php" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK" "$VPROJ/good.jsonl")"
assert_eq "it denies a Bash write into production even while armed" "DENY-BASH $VPROJ/src/Calc.php" "$out"
out="$(HCF_GATE_TOOL=Bash HCF_GATE_CMD="cat >> tests/CalcTest.php <<HEREDOC" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK" "$VPROJ/good.jsonl")"
assert_eq "it denies a Bash write into a test file" "DENY-BASH $VPROJ/tests/CalcTest.php" "$out"
out="$(HCF_GATE_TOOL=Bash HCF_GATE_CMD="./vendor/bin/pest --filter=x 2>&1 | tail -3 > /tmp/out.txt" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK" "$VPROJ/good.jsonl")"
assert_eq "it allows a test run that writes only outside the project" "ALLOW" "$out"
out="$(HCF_GATE_TOOL=Bash HCF_GATE_SCRIPTWRITES="src/Calc.php" HCF_GATE_CMD="python3 - <<HEREDOC" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK" "$VPROJ/good.jsonl")"
assert_eq "it denies an interpreter script that writes a project file" "DENY-BASH $VPROJ/src/Calc.php" "$out"
out="$(HCF_GATE_TOOL=Bash HCF_GATE_CMD="sed -i '' 's/^- \\[ \\]/- [x]/' .claude/plans/demo/001-demo.md" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK" "$VPROJ/good.jsonl")"
assert_eq "it denies ticking the task file from Bash" "DENY-BASH $TASK" "$out"
out="$(HCF_GATE_TOOL=Edit HCF_GATE_PATH="$TASK" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK" "$VPROJ/disarmed.jsonl")"
assert_eq "it allows editing the task file with Edit while disarmed" "ALLOW" "$out"
out="$("$VT" --touched "$TASK" "$VPROJ/good.jsonl" | sort | tr '\n' ' ')"
assert_eq "it lists the files a worker touched" "$VPROJ/src/Calc.php $VPROJ/tests/CalcTest.php " "$out"

# Real-time checks: one new test at a time, and an answer for a first-run pass.
gate() { HCF_GATE_TOOL="$1" HCF_GATE_PATH="$2" HCF_GATE_ADDED="$3" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK" "$4"; }
T="$VPROJ/one-unrun.jsonl"
{ add_test "adds two numbers"; } > "$T"
assert_eq "it denies a second new test before the first has run" "DENY-BATCH $VPROJ/tests/CalcTest.php" "$(gate Edit "$VPROJ/tests/CalcTest.php" 1 "$T")"
assert_eq "it allows editing an existing test while one is unrun" "ALLOW" "$(gate Edit "$VPROJ/tests/CalcTest.php" 0 "$T")"
assert_eq "it allows a new fixture file while one test is unrun" "ALLOW" "$(gate Write "$VPROJ/tests/Fixtures/Thing.php" 0 "$T")"
T="$VPROJ/pass-first.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; add_test "subtracts two numbers"; pass_run "subtracts two"; } > "$T"
assert_eq "it denies production code after an unexplained first-run pass" "DENY-PASSFIRST it subtracts two numbers" "$(gate Edit "$VPROJ/src/Calc.php" 0 "$T")"
assert_eq "it denies a new test after an unexplained first-run pass" "DENY-PASSFIRST it subtracts two numbers" "$(gate Edit "$VPROJ/tests/CalcTest.php" 1 "$T")"
assert_eq "it allows fixing the test after a first-run pass" "ALLOW" "$(gate Edit "$VPROJ/tests/CalcTest.php" 0 "$T")"
cp "$TASK" "$TASK.bak"; printf '\nPASSED-FIRST: it subtracts two numbers — shared operator table\n' >> "$TASK"
assert_eq "it keeps denying when the recorded first-run pass names code, not no-code" "DENY-PASSFIRST it subtracts two numbers" "$(gate Edit "$VPROJ/tests/CalcTest.php" 1 "$T")"
mv "$TASK.bak" "$TASK"
cp "$TASK" "$TASK.bak"; printf '\nPASSED-FIRST: it subtracts two numbers — no-code: PHP arithmetic\n' >> "$TASK"
assert_eq "it allows the next test once a no-code first-run pass is recorded" "ALLOW" "$(gate Edit "$VPROJ/tests/CalcTest.php" 1 "$T")"
mv "$TASK.bak" "$TASK"
T="$VPROJ/pass-then-red.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; add_test "subtracts two numbers"; pass_run "subtracts two"; red "subtracts two"; } > "$T"
assert_eq "it clears the question once the fixed test fails" "ALLOW" "$(gate Edit "$VPROJ/src/Calc.php" 0 "$T")"
T="$VPROJ/no-tests.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; tx_use Bash '{"command":"./vendor/bin/pest --filter=\"subtracts two\""}'; tx_res false "No tests found."; } > "$T"
assert_eq "it does not treat a run that found no tests as a first-run pass" "ALLOW" "$(gate Edit "$VPROJ/src/Calc.php" 0 "$T")"

T="$VPROJ/empty-out.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; tx_use Bash '{"command":"./vendor/bin/pest --filter=\"subtracts two\" | grep -E Tests:"}'; tx_res false "(Bash completed with no output)"; } > "$T"
assert_eq "it does not treat empty output as a first-run pass" "ALLOW" "$(gate Edit "$VPROJ/tests/CalcTest.php" 1 "$T")"
out="$(HCF_GATE_TOOL=Bash HCF_GATE_CMD="sed -i '' 's/a/b/' .claude/plans/demo/001-demo.md 2>&1 | head -1" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK" "$VPROJ/good.jsonl")"
assert_eq "it reads the sed target past a 2>&1 redirect" "DENY-BASH $TASK" "$out"
out="$(HCF_GATE_TOOL=Bash HCF_GATE_CMD="sed -i '' 's/a/b/' src/Calc.php 2>&1" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK" "$VPROJ/good.jsonl")"
assert_eq "it still denies sed -i on a project file followed by 2>&1" "DENY-BASH $VPROJ/src/Calc.php" "$out"

T="$VPROJ/run-before-write.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; pass_run "subtracts two"; } > "$T"
assert_eq "it ignores a run for a requirement whose test is not written yet" "ALLOW" "$(gate Edit "$VPROJ/tests/CalcTest.php" 1 "$T")"
T="$VPROJ/red-before-write.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; red "subtracts two"; edit_src; add_test "subtracts two numbers"; green; } > "$T"
assert_exit "it does not count a failing run from before the test was written" 1 "$(verify "$T")"

assert_eq "it denies one edit that adds two tests at once" "DENY-BATCH $VPROJ/tests/CalcTest.php" "$(gate Edit "$VPROJ/tests/CalcTest.php" 2 "$VPROJ/good.jsonl")"
fmt() { HCF_GATE_TOOL=Bash HCF_GATE_CMD="$1" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK" "$VPROJ/good.jsonl"; }
assert_eq "it allows a formatter on named files" "ALLOW" "$(fmt "./vendor/bin/php-cs-fixer fix src/Calc.php tests/CalcTest.php")"
assert_eq "it denies a formatter with no file list" "DENY-FORMAT $VPROJ" "$(fmt "./vendor/bin/php-cs-fixer fix")"
assert_eq "it denies a formatter fed by a substitution" "DENY-FORMAT $VPROJ" "$(fmt "./vendor/bin/php-cs-fixer fix \$(git status --porcelain | awk '{print \$2}')")"
T="$VPROJ/file-text.jsonl"
{ tx_use Write "$(jq -cn --arg p "$VPROJ/tests/CalcTest.php" '{file_path:$p, file_text:"<?php it(\u0027adds two numbers\u0027, function () {});"}')"; tx_res false "ok"
  red "adds two numbers"; edit_src; green; add_test "subtracts two numbers"; red "subtracts two"; edit_src; green; } > "$T"
assert_exit "it reads a Write that passes its content as file_text" 0 "$(verify "$T")"

# A runner HCF does not know: a loud hint, then testRunners in hcf.json fixes it.
custom() { tx_use Bash "$(jq -cn --arg c "bin/run-specs --filter=\"$1\"" '{command:$c}')"; tx_res true "FAILED $1  Tests: 1 failed"; }
T="$VPROJ/custom-runner.jsonl"
{ add_test "adds two numbers"; custom "adds two numbers"; edit_src; add_test "subtracts two numbers"; custom "subtracts two"; edit_src; } > "$T"
assert_exit "it fails when no test run is recognised" 1 "$(verify "$T")"
assert_contains "it says to add the runner to testRunners" "$(cat "$VPROJ/out")" "testRunners"
git -C "$VPROJ" init -q 2>/dev/null; mkdir -p "$VPROJ/.claude"; printf '{ "testRunners": ["bin/run-specs"] }\n' > "$VPROJ/.claude/hcf.json"
assert_exit "it recognises a runner declared in hcf.json" 0 "$(verify "$T")"
rm -f "$VPROJ/.claude/hcf.json"

# A task with no test requirements (docs, config) has nothing to verify.
DOCS="$VPLAN/014-docs.md"; printf '# Docs\n- [ ] update the concepts page\n' > "$DOCS"
"$VT" "$DOCS" "$VPROJ/good.jsonl" > /dev/null 2>&1
assert_exit "it reports a task with no test requirements as unchecked (exit 4)" 4 "$?"
printf '# Docs\n- [x] `concepts/dependency-injection.md` has an "Argument Substitution" section\n- [x] `packages/core.md`, `.claude/architecture.md` list the `arguments` key\n' > "$DOCS"
"$VT" "$DOCS" "$VPROJ/good.jsonl" > "$VPROJ/out" 2>&1
assert_exit "it ignores checklist items that only start with backticked code" 4 "$?"
assert_contains "it reports no test requirements for such a task" "$(cat "$VPROJ/out")" "no test requirements"

# The SubagentStop hook: verdict file, and a block only on the first stop.
SA="$REPO_ROOT/hooks/tdd-subagent-stop.sh"
prompt="$(jq -cn --arg t "## Task File Path
$TASK

## Your Task" '{type:"user", message:{content:$t}}')"
mk_worker() { { printf '%s\n' "$prompt"; cat "$1"; } > "$2"; }
mk_worker "$VPROJ/batch.jsonl" "$VPROJ/agent-batch.jsonl"
out="$(jq -cn --arg tp "$VPROJ/agent-batch.jsonl" --arg cwd "$VPROJ" '{agent_id:"x1", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, stop_hook_active:false}' | "$SA")"
assert_contains "it blocks a failed worker's first stop" "$out" '"decision":"block"'
assert_eq "it records a FAILED verdict" "FAILED" "$(head -n 1 "$VPLAN/.tdd/001-demo.md.verdict")"
assert_contains "it calls a method violation a TDD verification failure" "$out" "TASK_FAILED: TDD verification failed"
# A worker that stopped with requirements left (by design, or out of time) is
# unfinished, not in breach: still FAILED, but it is told so, and can resume.
mk_worker "$VPROJ/unfinished.jsonl" "$VPROJ/agent-unfinished.jsonl"
out="$(jq -cn --arg tp "$VPROJ/agent-unfinished.jsonl" --arg cwd "$VPROJ" '{agent_id:"x8", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, stop_hook_active:false}' | "$SA")"
assert_contains "it blocks an unfinished worker's first stop" "$out" '"decision":"block"'
assert_eq "it records an unfinished task as FAILED" "FAILED" "$(head -n 1 "$VPLAN/.tdd/001-demo.md.verdict")"
reason="$(printf '%s' "$out" | jq -r .reason)"
assert_contains "it says the task is unfinished" "$reason" "unfinished"
assert_contains "it lists the requirements not attempted" "$reason" "it subtracts two numbers"
assert_contains "it asks for the unfinished TASK_FAILED line" "$reason" "TASK_FAILED: unfinished — 1 requirement(s) not attempted"
assert_not_contains "it does not call an unfinished task a TDD failure" "$reason" "TDD verification failed"
out="$(jq -cn --arg tp "$VPROJ/agent-batch.jsonl" --arg cwd "$VPROJ" '{agent_id:"x1", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, stop_hook_active:true}' | "$SA")"
assert_empty "it never blocks a second stop" "$out"
out="$(jq -cn --arg tp "$VPROJ/agent-batch.jsonl" --arg cwd "$VPROJ" '{agent_id:"x1", agent_type:"general-purpose", agent_transcript_path:$tp, cwd:$cwd, stop_hook_active:false}' | "$SA")"
assert_empty "it ignores agents that are not tdd-workers" "$out"
mk_worker "$VPROJ/good.jsonl" "$VPROJ/agent-good.jsonl"
jq -cn --arg tp "$VPROJ/agent-good.jsonl" --arg cwd "$VPROJ" '{agent_id:"x2", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, stop_hook_active:false}' | "$SA" > /dev/null
assert_eq "it records an OK verdict for a clean worker" "OK" "$(head -n 1 "$VPLAN/.tdd/001-demo.md.verdict")"
# The orchestrator reads a worker's last line, so a clean worker must end with it.
say() { jq -cn --arg t "$1" '{type:"assistant", message:{content:[{type:"text", text:$t}]}}'; }
{ cat "$VPROJ/agent-good.jsonl"; say "All requirements done."; } > "$VPROJ/agent-no-line.jsonl"
out="$(jq -cn --arg tp "$VPROJ/agent-no-line.jsonl" --arg cwd "$VPROJ" '{agent_id:"x2", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, stop_hook_active:false}' | "$SA")"
assert_contains "it blocks a clean worker that stops without its terminal line" "$out" '"decision":"block"'
assert_contains "it asks for TASK_COMPLETE as the last line" "$(printf '%s' "$out" | jq -r .reason)" "TASK_COMPLETE"
{ cat "$VPROJ/agent-good.jsonl"; say "Summary of the work.

TASK_COMPLETE"; } > "$VPROJ/agent-line.jsonl"
out="$(jq -cn --arg tp "$VPROJ/agent-line.jsonl" --arg cwd "$VPROJ" '{agent_id:"x2", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, stop_hook_active:false}' | "$SA")"
assert_empty "it lets a clean worker that ends with TASK_COMPLETE stop" "$out"
{ cat "$VPROJ/agent-good.jsonl"; say "TASK_FAILED: Teachable sandbox unreachable"; } > "$VPROJ/agent-failed-line.jsonl"
out="$(jq -cn --arg tp "$VPROJ/agent-failed-line.jsonl" --arg cwd "$VPROJ" '{agent_id:"x2", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, stop_hook_active:false}' | "$SA")"
assert_empty "it lets a worker that ends with TASK_FAILED stop" "$out"
out="$(jq -cn --arg tp "$VPROJ/agent-no-line.jsonl" --arg cwd "$VPROJ" '{agent_id:"x2", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, stop_hook_active:true}' | "$SA")"
assert_empty "it never asks for the terminal line twice" "$out"

printf '# Docs\n- [ ] update the concepts page\n' > "$VPLAN/014-docs.md"
DPROMPT="$(jq -cn --arg t "## Task File Path
$VPLAN/014-docs.md

## Your Task" '{type:"user", message:{content:$t}}')"
printf '%s\n' "$DPROMPT" > "$VPROJ/agent-docs.jsonl"
jq -cn --arg tp "$VPROJ/agent-docs.jsonl" --arg cwd "$VPROJ" '{agent_id:"x9", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, stop_hook_active:false}' | "$SA" > /dev/null
assert_eq "it records a NONE verdict for a task with no test requirements" "NONE" "$(head -n 1 "$VPLAN/.tdd/014-docs.md.verdict")"

# The guard hook, end to end.
GD="$REPO_ROOT/hooks/tdd-guard.sh"
mk_worker "$VPROJ/disarmed.jsonl" "$VPROJ/agent-disarmed.jsonl"
out="$(jq -cn --arg tp "$VPROJ/agent-disarmed.jsonl" --arg cwd "$VPROJ" --arg p "$VPROJ/src/Calc.php" '{agent_id:"x3", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$p}}' | "$GD")"
assert_contains "it denies the edit through the PreToolUse hook" "$out" '"permissionDecision":"deny"'
out="$(jq -cn --arg tp "$VPROJ/agent-disarmed.jsonl" --arg cwd "$VPROJ" --arg p "$VPROJ/src/Calc.php" '{tool_name:"Edit", cwd:$cwd, tool_input:{file_path:$p}}' | "$GD")"
assert_empty "it leaves the main session alone" "$out"

# Files the prompt says to read IN FULL must be read before the first file change.
printf '# Standards\n' > "$VPROJ/standards.md"; printf '# Rules\n' > "$VPROJ/CLAUDE.md"
RPROMPT="$(jq -cn --arg t "## Task File Path
$TASK

## Code Standards
Read $VPROJ/standards.md and $VPROJ/CLAUDE.md IN FULL before writing any code.

## Your Task" '{type:"user", message:{content:$t}}')"
read_file() { tx_use Read "$(jq -cn --arg p "$1" '{file_path:$p}')"; tx_res false "contents"; }
{ printf '%s\n' "$RPROMPT"; read_file "$VPROJ/standards.md"; } > "$VPROJ/agent-unread.jsonl"
guard_edit() { jq -cn --arg tp "$1" --arg cwd "$VPROJ" --arg p "$2" '{agent_id:"x10", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$p, old_string:"", new_string:"x"}}' | "$GD"; }
out="$(guard_edit "$VPROJ/agent-unread.jsonl" "$VPROJ/tests/CalcTest.php")"
assert_contains "it denies a test edit before the required files are read" "$out" '"permissionDecision":"deny"'
assert_contains "it names the file still to read" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecisionReason)" "$VPROJ/CLAUDE.md"
assert_not_contains "it does not name a file already read" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecisionReason)" "standards.md"
out="$(guard_edit "$VPROJ/agent-unread.jsonl" "$TASK")"
assert_empty "it still allows editing the task file" "$out"
{ cat "$VPROJ/agent-unread.jsonl"; read_file "$VPROJ/CLAUDE.md"; } > "$VPROJ/agent-read.jsonl"
out="$(guard_edit "$VPROJ/agent-read.jsonl" "$VPROJ/tests/CalcTest.php")"
assert_empty "it allows a test edit once every required file is read" "$out"

# Cut-back: an earlier GREEN step over-built, so the next test passed on its
# first run. Deleting that code (an edit that adds no token) until the test
# fails, then rebuilding it, is red-before-green after all.
ternary_old="return \$format === 'short' ? self::SHORT_STAGES : self::LONG_STAGES;"
ternary_new="return self::LONG_STAGES;"
removal() { jq -cn --arg o "$2" --arg n "$3" '{old_string:$o, new_string:$n}' | "$VT" --removal-only "$1"; }
assert_eq "it counts deleting a ternary branch as removal-only" "yes" "$(removal Edit "$ternary_old" "$ternary_new")"
assert_eq "it does not count a rename as removal-only" "no" "$(removal Edit 'return $total;' 'return $sum;')"
assert_eq "it does not count a shorter edit that adds a token as removal-only" "no" "$(removal Edit 'return a + b + c;' 'return a + d;')"
assert_eq "it does not count an edit that only moves tokens as removal-only" "no" "$(removal Edit 'return a + b;' 'return b + a;')"
assert_eq "it does not count joining two words as removal-only" "no" "$(removal Edit 'return foo bar;' 'return foobar;')"
assert_eq "it does not count shortening a string literal as removal-only" "no" "$(removal Edit "return 'short long';" "return 'long';")"
assert_eq "it never counts a Write as removal-only" "no" "$(jq -cn '{content:"x"}' | "$VT" --removal-only Write)"
assert_eq "it counts a MultiEdit as removal-only when every edit is" "yes" "$(jq -cn --arg o "$ternary_old" --arg n "$ternary_new" '{edits:[{old_string:$o, new_string:$n}, {old_string:"a(); b();", new_string:"a();"}]}' | "$VT" --removal-only MultiEdit)"
assert_eq "it does not count a MultiEdit with one adding edit as removal-only" "no" "$(jq -cn --arg o "$ternary_old" --arg n "$ternary_new" '{edits:[{old_string:$o, new_string:$n}, {old_string:"a();", new_string:"a(); b();"}]}' | "$VT" --removal-only MultiEdit)"

cut_src() { tx_use Edit "$(jq -cn --arg p "$VPROJ/src/Calc.php" --arg o "$1" --arg n "$2" '{file_path:$p, old_string:$o, new_string:$n}')"; tx_res false "ok"; }
overbuilt() { add_test "adds two numbers"; red "adds two numbers"; edit_src; green; add_test "subtracts two numbers"; pass_run "subtracts two"; }
T="$VPROJ/cut-back.jsonl"
{ overbuilt; cut_src "$ternary_old" "$ternary_new"; red "subtracts two"; edit_src; green; } > "$T"
assert_exit "it accepts an over-built branch cut back until its test fails, then rebuilt" 0 "$(verify "$T")"
assert_not_contains "it needs no PASSED-FIRST warning after a cut-back" "$(cat "$VPROJ/out")" "WARNING"
T="$VPROJ/cut-back-twice.jsonl"
{ overbuilt; cut_src "$ternary_old" "$ternary_new"; pass_run "subtracts two"; cut_src "a(); b();" "a();"; red "subtracts two"; edit_src; green; } > "$T"
assert_exit "it accepts several removal-only edits before the failing run" 0 "$(verify "$T")"
T="$VPROJ/cut-back-no-red.jsonl"
{ overbuilt; cut_src "$ternary_old" "$ternary_new"; green; } > "$T"
assert_exit "it fails a cut-back never followed by a failing run" 1 "$(verify "$T")"
assert_contains "it names the requirement whose cut-back never went red" "$(cat "$VPROJ/out")" "R2 cut-back for \`it subtracts two numbers\` was never followed by a failing run naming it"
T="$VPROJ/cut-back-then-code.jsonl"
{ overbuilt; cut_src "$ternary_old" "$ternary_new"; pass_run "subtracts two"; edit_src; red "subtracts two"; green; } > "$T"
assert_exit "it fails a cut-back followed by new code before any failing run" 1 "$(verify "$T")"
assert_contains "it reports that cut-back as never followed by a failing run" "$(cat "$VPROJ/out")" "R2 cut-back for \`it subtracts two numbers\`"
T="$VPROJ/cut-back-adds.jsonl"
{ overbuilt; cut_src "return a + b + c;" "return a + d;"; red "subtracts two"; edit_src; green; } > "$T"
assert_exit "it fails a so-called cut-back that adds a token" 1 "$(verify "$T")"
assert_contains "it reports an adding cut-back as a plain R2 violation" "$(cat "$VPROJ/out")" "R2 production file edited with no failing test armed"
# A real worker: cut the code out entirely (empty new_string), saw the test
# fail, restored it, and only then wrote a PASSED-FIRST line about it. The guard
# allowed the cut-back when the line did not exist yet; the verifier must agree.
assert_eq "it counts deleting a whole block as removal-only" "yes" "$(removal Edit 'if (!$t->claim($id)) { return; }' '')"
T="$VPROJ/cut-back-then-noted.jsonl"
{ overbuilt; cut_src 'if (!$t->claim($id)) { return; }' ''; red "subtracts two"; edit_src; pass_run "subtracts two"; } > "$T"
cp "$TASK" "$TASK.bak"; printf '\nPASSED-FIRST: it subtracts two numbers — verified by cutting the claim out (test failed), then restoring it\n' >> "$TASK"
assert_exit "it accepts a cut-back whose requirement was noted as PASSED-FIRST afterwards" 0 "$(verify "$T")"
T="$VPROJ/cut-back-noted-no-red.jsonl"
{ overbuilt; cut_src 'if (!$t->claim($id)) { return; }' ''; green; } > "$T"
assert_exit "it still fails a noted cut-back that never went red" 1 "$(verify "$T")"
assert_contains "it names that cut-back" "$(cat "$VPROJ/out")" "R2 cut-back for \`it subtracts two numbers\`"
mv "$TASK.bak" "$TASK"

# The guard reads the worker's transcript while Claude Code is still writing it:
# tools from one streamed message run back to back, so an earlier call's result
# (or the last line itself) may not be on disk yet. That must not open the gate.
add_test_pending() { tx_use Edit "$(jq -cn --arg p "$VPROJ/tests/CalcTest.php" --arg s "it('$1', function () {});" '{file_path:$p, old_string:"", new_string:$s}')"; }
T="$VPROJ/lagging-result.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; add_test_pending "subtracts two numbers"; } > "$T"
assert_eq "it denies production code while a new test's edit has no result on disk yet" "DENY $VPROJ/src/Calc.php" "$(gate Write "$VPROJ/src/Calc.php" 0 "$T")"
assert_eq "it does not count the call being judged as an earlier test" "ALLOW" "$(HCF_GATE_ID="t$_n" gate Edit "$VPROJ/tests/CalcTest.php" 1 "$T")"
assert_eq "it does not count the call being judged when no id is given" "ALLOW" "$(gate Edit "$VPROJ/tests/CalcTest.php" 1 "$T")"
T="$VPROJ/partial-line.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; add_test "subtracts two numbers"; printf '{"type":"assistant","message":{"content":[{"type":"tool_u'; } > "$T"
assert_eq "it judges a transcript whose last line is still being written" "DENY $VPROJ/src/Calc.php" "$(gate Write "$VPROJ/src/Calc.php" 0 "$T")"
mk_worker "$T" "$VPROJ/agent-partial.jsonl"
out="$(jq -cn --arg tp "$VPROJ/agent-partial.jsonl" --arg cwd "$VPROJ" --arg p "$VPROJ/src/Calc.php" '{agent_id:"x5", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, tool_name:"Write", tool_use_id:"live1", tool_input:{file_path:$p, content:"<?php"}}' | "$GD")"
assert_contains "it denies through the hook while the transcript's last line is incomplete" "$out" '"permissionDecision":"deny"'

T="$VPROJ/pass-first.jsonl"
assert_eq "it allows a removal-only production edit after a first-run pass" "ALLOW" "$(HCF_GATE_REMOVAL=yes gate Edit "$VPROJ/src/Calc.php" 0 "$T")"
assert_eq "it denies a production edit that adds tokens after a first-run pass" "DENY-PASSFIRST it subtracts two numbers" "$(HCF_GATE_REMOVAL=no gate Edit "$VPROJ/src/Calc.php" 0 "$T")"
assert_eq "it denies a production Write after a first-run pass" "DENY-PASSFIRST it subtracts two numbers" "$(HCF_GATE_REMOVAL=yes gate Write "$VPROJ/src/Calc.php" 0 "$T")"
T="$VPROJ/cut-open.jsonl"
{ overbuilt; cut_src "$ternary_old" "$ternary_new"; } > "$T"
assert_eq "it still denies a new test while a cut-back has not gone red" "DENY-PASSFIRST it subtracts two numbers" "$(gate Edit "$VPROJ/tests/CalcTest.php" 1 "$T")"
{ overbuilt; cut_src "$ternary_old" "$ternary_new"; red "subtracts two"; } > "$T"
assert_eq "it allows rebuilding once the cut-back test fails" "ALLOW" "$(gate Edit "$VPROJ/src/Calc.php" 0 "$T")"
mk_worker "$VPROJ/pass-first.jsonl" "$VPROJ/agent-pass-first.jsonl"
guard_edit() { jq -cn --arg tp "$VPROJ/agent-pass-first.jsonl" --arg cwd "$VPROJ" --arg p "$VPROJ/src/Calc.php" --arg o "$1" --arg n "$2" '{agent_id:"x4", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$p, old_string:$o, new_string:$n}}' | "$GD"; }
assert_empty "it lets a removal-only cut-back through the PreToolUse hook" "$(guard_edit "$ternary_old" "$ternary_new")"
out="$(guard_edit "return a;" "return a + b;")"
assert_contains "it denies an adding edit through the hook after a first-run pass" "$out" '"permissionDecision":"deny"'
assert_contains "it offers the cut-back in the pass-first message" "$out" "removal-only"
assert_contains "it leads the pass-first message with the cut-back" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecisionReason | cut -c1-400)" "cut back"
assert_contains "it keeps PASSED-FIRST for code-free behaviour only" "$out" "no-code:"

# A test helper that calls test() (Pest's test()->markTestSkipped(), say) is
# not a new test: only it(/test( followed by a name string declares one. A
# real worker was blocked for good by such a helper and had to fake a red run.
helper_old="it('adds two numbers', function () {});"
helper_new="function skipUnlessLive(): void { test()->markTestSkipped('needs live'); }
$helper_old"
helper_edit() { tx_use Edit "$(jq -cn --arg p "$VPROJ/tests/CalcTest.php" --arg o "$helper_old" --arg n "$helper_new" '{file_path:$p, old_string:$o, new_string:$n}')"; tx_res false "ok"; }
T="$VPROJ/helper-test-call.jsonl"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; helper_edit; } > "$T"
assert_eq "it does not count a helper calling test() as a new test" "ALLOW" "$(gate Edit "$VPROJ/tests/CalcTest.php" 1 "$T")"
assert_eq "it keeps production armed after such a helper" "ARMED" "$("$VT" --state "$TASK" "$T")"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; helper_edit; add_test "subtracts two numbers"; red "subtracts two"; edit_src; green; } > "$T"
assert_exit "it verifies a task whose test file gained a helper calling test()" 0 "$(verify "$T")"
mk_worker "$VPROJ/one-unrun.jsonl" "$VPROJ/agent-one-unrun.jsonl"
guard_test_edit() { jq -cn --arg tp "$VPROJ/agent-one-unrun.jsonl" --arg cwd "$VPROJ" --arg p "$VPROJ/tests/CalcTest.php" --arg o "$1" --arg n "$2" '{agent_id:"x7", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$p, old_string:$o, new_string:$n}}' | "$GD"; }
assert_empty "it lets a helper calling test() through the hook while a test is unrun" "$(guard_test_edit "$helper_old" "$helper_new")"
out="$(guard_test_edit "" "it(
    'subtracts two numbers',
    function () {},
);")"
assert_contains "it still counts a test whose name starts on the next line" "$out" "refused to add another test"
counted="it(
    'x', fn () => 1); test()->skip(); \$this->test('y'); it('z', fn () => 2);"
assert_eq "it counts only it(/test( calls that name a test" "2" "$(jq -cn --arg n "$counted" '{new_string:$n, old_string:""}' | "$VT" --count-tests Edit)"
assert_eq "it counts a Write's tests over the file on disk" "1" "$(jq -cn --arg p "$VPROJ/tests/CalcTest.php" --arg c "$helper_new
it('subtracts', fn () => 1);" '{file_path:$p, content:$c}' | (printf '%s\n' "$helper_old" > "$VPROJ/tests/CalcTest.php"; "$VT" --count-tests Write))"

# The guard never lets a call through unchecked: an error refuses it.
BROKEN="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hcf-broken.XXXXXX")" && pwd -P)"
cp "$REPO_ROOT/hooks/tdd-guard.sh" "$REPO_ROOT/hooks/tdd-context.sh" "$BROKEN/"
printf '#!/usr/bin/env bash\necho "verify-tdd: error: boom" >&2\nexit 3\n' > "$BROKEN/verify-tdd.sh"; chmod +x "$BROKEN/verify-tdd.sh"
out="$(jq -cn --arg tp "$VPROJ/agent-pass-first.jsonl" --arg cwd "$VPROJ" --arg p "$VPROJ/src/Calc.php" '{agent_id:"x6", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$p, old_string:"a", new_string:"b"}}' | "$BROKEN/tdd-guard.sh")"
assert_contains "it refuses a call it could not check" "$out" '"permissionDecision":"deny"'
assert_contains "it says why it could not check the call" "$out" "boom"
rm -rf "$BROKEN"

# ---------------------------------------------------------------------------
# Hardening: a worker must not be able to skip or fake TDD and still get OK.
# ---------------------------------------------------------------------------
gate_cmd() { HCF_GATE_TOOL=Bash HCF_GATE_CMD="$1" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK" "${2:-$VPROJ/good.jsonl}"; }
state_of() { "$VT" --state "$TASK" "$1"; }
run_out() { tx_use Bash "$(jq -cn --arg c "$1" '{command:$c}')"; tx_res "$2" "$3"; }

# 1. Requirements come from the prompt, not from a file the worker can edit.
YPROMPT="$(jq -cn --arg t "## Task File Path
$TASK

## Your Task
$(cat "$TASK")" '{type:"user", message:{content:$t}}')"
mk_yworker() { { printf '%s\n' "$YPROMPT"; cat "$1"; } > "$2"; }
only_adds() { add_test "adds two numbers"; red "adds two numbers"; edit_src; green; }
cp "$TASK" "$TASK.bak"
printf '# Task 001: Demo\n\n## Requirements (Test Descriptions)\n- [x] `it adds two numbers`\n' > "$TASK"
{ only_adds; } > "$VPROJ/h-removed.jsonl"; mk_yworker "$VPROJ/h-removed.jsonl" "$VPROJ/agent-h-removed.jsonl"
assert_exit "it fails a worker that deleted a requirement from its task file" 1 "$(verify "$VPROJ/agent-h-removed.jsonl")"
assert_contains "it still holds the deleted requirement to account" "$(cat "$VPROJ/out")" "R1 \`it subtracts two numbers\` not attempted"
assert_contains "it reports the edited requirement list" "$(cat "$VPROJ/out")" "R5"
printf '# Task 001: Demo\n\n## Requirements (Test Descriptions)\n- [x] `it adds two numbers`\n- [x] `it subtracts two numbers` (guard)\n' > "$TASK"
{ only_adds; add_test "subtracts two numbers"; pass_run "subtracts two"; green; } > "$VPROJ/h-guard.jsonl"; mk_yworker "$VPROJ/h-guard.jsonl" "$VPROJ/agent-h-guard.jsonl"
assert_exit "it fails a worker that labelled its own requirement (guard)" 1 "$(verify "$VPROJ/agent-h-guard.jsonl")"
assert_contains "it names the relabelled requirement" "$(cat "$VPROJ/out")" "(guard)"
printf '# Task 001: Demo\n\nRequirements: adds, subtracts\n' > "$TASK"
{ edit_src; green; } > "$VPROJ/h-broken.jsonl"; mk_yworker "$VPROJ/h-broken.jsonl" "$VPROJ/agent-h-broken.jsonl"
assert_exit "it fails a worker that broke the requirement format instead of reporting NONE" 1 "$(verify "$VPROJ/agent-h-broken.jsonl")"
assert_eq "it keeps the gate shut when the task file lost its requirements" "DENY $VPROJ/src/Calc.php" "$(gate Edit "$VPROJ/src/Calc.php" 0 "$VPROJ/agent-h-broken.jsonl")"
mv "$TASK.bak" "$TASK"
{ add_test "adds two numbers"; red "adds two numbers"; edit_src; green; add_test "subtracts two numbers"; red "subtracts two"; edit_src; green; } > "$VPROJ/h-ok.jsonl"; mk_yworker "$VPROJ/h-ok.jsonl" "$VPROJ/agent-h-ok.jsonl"
assert_exit "it passes a clean worker whose prompt carries its requirements" 0 "$(verify "$VPROJ/agent-h-ok.jsonl")"
# The guard refuses the requirement edit live; ticking a box stays allowed.
task_edit() { jq -cn --arg tp "$VPROJ/agent-h-ok.jsonl" --arg cwd "$VPROJ" --arg p "$TASK" --arg o "$1" --arg n "$2" '{agent_id:"h1", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$p, old_string:$o, new_string:$n}}' | "$GD"; }
out="$(task_edit '- [x] `it subtracts two numbers`' '')"
assert_contains "it refuses removing a requirement line from the task file" "$out" '"permissionDecision":"deny"'
assert_contains "it tells the worker requirements are fixed" "$out" "only tick"
assert_contains "it refuses adding (guard) to a requirement" "$(task_edit '- [x] `it subtracts two numbers`' '- [x] `it subtracts two numbers` (guard)')" '"permissionDecision":"deny"'
assert_empty "it allows ticking a requirement's checkbox" "$(task_edit '- [ ] `it subtracts two numbers`' '- [x] `it subtracts two numbers`')"
assert_empty "it allows adding a requirement to the task file" "$(task_edit '- [x] `it subtracts two numbers`' '- [x] `it subtracts two numbers`
- [ ] `it multiplies two numbers`')"
cp "$TASK" "$TASK.bak"; printf -- '- [x] `it multiplies two numbers`\n' >> "$TASK"
assert_exit "it holds a requirement the worker added to the same rules" 1 "$(verify "$VPROJ/agent-h-ok.jsonl")"
assert_contains "it reports the added requirement as not attempted, not as R5" "$(cat "$VPROJ/out")" "R1 \`it multiplies two numbers\` not attempted"
assert_not_contains "it does not call an added requirement R5" "$(cat "$VPROJ/out")" "R5"
mv "$TASK.bak" "$TASK"

# 2. Fake red runs never arm the gate; honest reds do.
T="$VPROJ/h-fake.jsonl"
{ add_test "adds two numbers"; run_out 'echo FAILED; true # vendor/bin/pest --filter "adds two numbers"' false "FAILED"; } > "$T"
assert_eq "it ignores a runner that only appears in a comment" "DISARMED" "$(state_of "$T")"
{ add_test "adds two numbers"; run_out 'ls vendor/bin/pest --filter="adds two numbers"' true "FAILED"; } > "$T"
assert_eq "it ignores a runner passed as an argument to ls" "DISARMED" "$(state_of "$T")"
{ add_test "adds two numbers"; run_out 'docker compose exec phpfpm ./vendor/bin/pest --filter="adds two numbers"' true "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"; } > "$T"
assert_eq "it does not count a Docker daemon error as red" "DISARMED" "$(state_of "$T")"
{ add_test "adds two numbers"; run_out 'npx vitest run -t "adds two numbers"' true "No test files found, exiting with code 1
FAIL"; } > "$T"
assert_eq "it does not count Vitest's no test files as red" "DISARMED" "$(state_of "$T")"
{ add_test "adds two numbers"; run_out './vendor/bin/pest --filter="adds two numbers" | tail -1' false "Tests:  1 failed (1 assertions)"; } > "$T"
assert_eq "it counts a filtered run trimmed to its failure summary" "ARMED" "$(state_of "$T")"
{ add_test "adds two numbers"; run_out './vendor/bin/pest --filter="adds two numbers"; echo "Tests:  1 failed"' false "Tests:  1 passed
Tests:  1 failed"; } > "$T"
assert_eq "it does not count a failure summary the command echoed itself" "DISARMED" "$(state_of "$T")"
{ add_test "adds two numbers"; run_out './vendor/bin/pest --filter="adds two numbers"; echo "FAILED  Tests\\CalcTest > it adds two numbers"' false "  ✓ it adds two numbers
  Tests:  1 passed
FAILED  Tests\\CalcTest > it adds two numbers"; } > "$T"
assert_eq "it does not count a failure line the command echoed itself" "DISARMED" "$(state_of "$T")"
{ add_test "adds two numbers"; run_out './vendor/bin/pest --filter="adds two numbers"' false "  ✓ it adds two numbers when the status is FAILED
  Tests:  1 passed (1 assertions)"; } > "$T"
assert_eq "it does not count a passing test whose name contains FAILED" "DISARMED" "$(state_of "$T")"
{ add_test "adds two numbers"; run_out './vendor/bin/pest --filter="adds two numbers"' true "   FAILED  Tests\\CalcTest > it adds two numbers   ParseError
  syntax error, unexpected token \"}\" in src/Calc.php:4"; } > "$T"
assert_eq "it does not count a PHP parse error as red" "DISARMED" "$(state_of "$T")"
{ add_test "adds two numbers"; run_out 'docker compose exec -T -e XDEBUG_MODE=off phpfpm ./vendor/bin/pest --parallel --filter="adds two numbers" 2>&1 | tail -n 20' false "  FAILED  Tests\\Unit\\CalcTest > it adds two numbers   AssertionFailedError
  Failed asserting that 0 matches expected 3.
  Tests:    1 failed (1 assertions)"; } > "$T"
assert_eq "it counts an honest red through docker compose exec and tail" "ARMED" "$(state_of "$T")"
{ add_test "adds two numbers"; run_out 'docker compose exec -t phpfpm ./vendor/bin/pest --filter "adds two numbers"' true "  ⨯ it adds two numbers 0.02s
  Tests:  1 failed"; } > "$T"
assert_eq "it reads the filter after the runner, not docker's -t" "ARMED" "$(state_of "$T")"
{ add_test "adds two numbers"; run_out 'npx vitest run -t "adds two numbers"' true " × adds two numbers 3ms
 FAIL  tests/calc.test.js > calc > adds two numbers"; } > "$T"
assert_eq "it counts a Vitest failure naming the test" "ARMED" "$(state_of "$T")"
{ add_test "adds two numbers"; run_out 'bash -c "cd /app && vendor/bin/pest --filter=\"adds two numbers\" 2>&1 | tail -n 5"' true "FAILED  Tests\\CalcTest > it adds two numbers"; } > "$T"
assert_eq "it counts a run inside bash -c" "ARMED" "$(state_of "$T")"

# The shape of a real honest red: cd; docker compose exec -T -e; tail; ANSI;
# only Pest's source snippet and summary survive the tail.
real_out="$(printf '  at tests/Feature/CalcTest.php:12\n    8▕ it(\x27adds two numbers\x27, function () {\n  \033[90mTests:\033[39m    \033[31;1m1 failed\033[39;22m\033[90m (1 assertions)\033[39m')"
{ add_test "adds two numbers"; run_out "cd $VPROJ; docker compose exec -T -e WT_TEST_DB=w001 phpfpm ./vendor/bin/pest tests/Feature/CalcTest.php --filter \"adds two numbers\" 2>&1 | tail -15" false "$real_out"; } > "$T"
assert_eq "it counts the honest red shape seen in real runs" "ARMED" "$(state_of "$T")"
{ add_test "adds two numbers"; run_out "cd $VPROJ && ./vendor/bin/pest --filter \"adds two numbers\" 2>&1 | grep -E \"Tests:|FAIL|Expected\"" false "  FAIL  Tests\\Feature\\CalcTest
  Tests:    1 failed (1 assertions)"; } > "$T"
assert_eq "it counts an honest red filtered through grep" "ARMED" "$(state_of "$T")"

# Non-PHP stacks, named the way each framework names a test.
add_named() { tx_use Edit "$(jq -cn --arg p "$VPROJ/$1" --arg s "$2" '{file_path:$p, old_string:"", new_string:$s}')"; tx_res false "ok"; }
T="$VPROJ/h-pytest.jsonl"
{ add_named tests/test_calc.py "def test_adds_two_numbers():
    assert add(1, 2) == 3"
  run_out 'python -m pytest tests/test_calc.py -k test_adds_two_numbers' true "FAILED tests/test_calc.py::test_adds_two_numbers - NameError: name 'add' is not defined
1 failed in 0.02s"
  edit_src; run_out 'pytest' false "2 passed in 0.03s"
  add_named tests/test_calc.py "def test_subtracts_two_numbers():
    assert sub(3, 2) == 1"
  run_out 'pytest tests/test_calc.py::test_subtracts_two_numbers' true "FAILED tests/test_calc.py::test_subtracts_two_numbers - NameError
1 failed in 0.02s"
  edit_src; run_out 'pytest' false "3 passed in 0.03s"; } > "$T"
assert_exit "it verifies a pytest worker that names tests test_<requirement>" 0 "$(verify "$T")"
T="$VPROJ/h-go.jsonl"
{ add_named calc_test.go "func TestAddsTwoNumbers(t *testing.T) {
	if Add(1, 2) != 3 { t.Fail() }
}"
  run_out 'go test ./... -run TestAddsTwoNumbers' true "# example.com/calc [example.com/calc.test]
./calc_test.go:4:5: undefined: Add
FAIL	example.com/calc [build failed]"
  tx_use Edit "$(jq -cn --arg p "$VPROJ/calc.go" '{file_path:$p, old_string:"", new_string:"func Add(a, b int) int { return a + b }"}')"; tx_res false ok
  run_out 'go test ./...' false "ok  	example.com/calc	0.002s"
  add_named calc_test.go "func TestSubtractsTwoNumbers(t *testing.T) {}"
  run_out 'go test -run TestSubtractsTwoNumbers ./...' true "--- FAIL: TestSubtractsTwoNumbers (0.00s)
FAIL
FAIL	example.com/calc	0.002s"
  tx_use Edit "$(jq -cn --arg p "$VPROJ/calc.go" '{file_path:$p, old_string:"x", new_string:"y"}')"; tx_res false ok
  run_out 'go test ./...' false "ok  	example.com/calc	0.002s"; } > "$T"
assert_exit "it verifies a Go worker, a build failure on a missing symbol counting as red" 0 "$(verify "$T")"
T="$VPROJ/h-phpunit.jsonl"
{ add_named tests/CalcTest.php "public function testAddsTwoNumbers(): void {}"
  run_out 'vendor/bin/phpunit --filter testAddsTwoNumbers' true "There was 1 failure:

1) Tests\\CalcTest::testAddsTwoNumbers
Failed asserting that 0 matches expected 3."
  edit_src; green
  add_named tests/CalcTest.php "public function test_subtracts_two_numbers(): void {}"
  run_out 'vendor/bin/phpunit --filter=test_subtracts_two_numbers' true "1) Tests\\CalcTest::test_subtracts_two_numbers
Failed asserting that 0 matches expected 1."
  edit_src; green; } > "$T"
assert_exit "it verifies a PHPUnit worker using camelCase and snake_case method names" 0 "$(verify "$T")"

# 3. Bash writes the guard used to miss.
assert_eq "it denies a heredoc whose opening line redirects into a project file" "DENY-BASH $VPROJ/src/Calc.php" "$(gate_cmd "cat <<'EOF' > src/Calc.php
<?php return 1;
EOF")"
T="$VPROJ/h-heredoc.jsonl"
{ run_out "cat <<'EOF' > src/Calc.php
<?php return 1;
EOF" false ""; only_adds; } > "$T"
verify "$T" > /dev/null
assert_contains "it reports a heredoc redirect into a project file" "$(cat "$VPROJ/out")" "R4 project file changed from Bash (only Edit/Write may change files): $VPROJ/src/Calc.php"
assert_eq "it denies sh -c that redirects" "DENY-BASH $VPROJ/src/Calc.php" "$(gate_cmd 'sh -c "echo x > src/Calc.php"')"
assert_eq "it denies bash -c that touches a file" "DENY-BASH $VPROJ/src/New.php" "$(gate_cmd "bash -c 'touch src/New.php'")"
assert_contains "it denies eval that writes" "$(gate_cmd 'eval "echo x > src/Calc.php"')" "DENY-BASH"
assert_contains "it denies git apply" "$(gate_cmd 'git apply fix.diff')" "DENY-BASH"
assert_eq "it allows git apply --check" "ALLOW" "$(gate_cmd 'git apply --check fix.diff')"
assert_eq "it denies git checkout -- <file>" "DENY-BASH $VPROJ/src/Calc.php" "$(gate_cmd 'git checkout -- src/Calc.php')"
assert_eq "it denies git restore" "DENY-BASH $VPROJ/src/Calc.php" "$(gate_cmd 'git restore src/Calc.php')"
assert_contains "it denies patch" "$(gate_cmd 'patch -p1 < /tmp/fix.diff')" "DENY-BASH"
assert_eq "it denies touch" "DENY-BASH $VPROJ/src/New.php" "$(gate_cmd 'touch src/New.php')"
assert_eq "it denies ln" "DENY-BASH $VPROJ/src/Link.php" "$(gate_cmd 'ln -s /tmp/x.php src/Link.php')"
assert_eq "it denies install" "DENY-BASH $VPROJ/src/B.php" "$(gate_cmd 'install -m 644 /tmp/b.php src/B.php')"
assert_eq "it denies rsync" "DENY-BASH $VPROJ/src/" "$(gate_cmd 'rsync -a /tmp/x/ src/')"
assert_eq "it denies dd of=" "DENY-BASH $VPROJ/src/Calc.php" "$(gate_cmd 'dd if=/dev/zero of=src/Calc.php bs=1 count=1')"
assert_eq "it denies truncate" "DENY-BASH $VPROJ/src/Calc.php" "$(gate_cmd 'truncate -s 0 src/Calc.php')"
assert_contains "it denies a code generator such as artisan make:" "$(gate_cmd 'php artisan make:model Foo')" "DENY-BASH"
assert_eq "it allows a test run inside bash -c" "ALLOW" "$(gate_cmd 'bash -c "vendor/bin/pest --filter=x 2>&1 | tail -3"')"
assert_eq "it allows sh -c writing outside the project" "ALLOW" "$(gate_cmd 'sh -c "vendor/bin/pest > /tmp/out.txt"')"
assert_eq "it allows a read-only grep that mentions a formatter" "ALLOW" "$(gate_cmd 'grep -rn "php-cs-fixer fix" .')"
mkdir -p "$VPROJ/.claude"; printf '{ "fileGenerators": ["bin/gen"] }\n' > "$VPROJ/.claude/hcf.json"
assert_contains "it denies a generator declared in fileGenerators" "$(gate_cmd 'bin/gen model Foo')" "DENY-BASH"
printf '{ "commandWrappers": ["bin/in-app"] }\n' > "$VPROJ/.claude/hcf.json"
T="$VPROJ/h-wrapper.jsonl"
{ add_test "adds two numbers"; run_out 'bin/in-app --tty pytest -k "adds two numbers"' true "FAILED tests/test_calc.py::test_adds_two_numbers - assert 0 == 3"; } > "$T"
assert_eq "it unwraps a commandWrappers entry to find the runner" "ARMED" "$(state_of "$T")"
rm -f "$VPROJ/.claude/hcf.json"
T="$VPROJ/h-errored.jsonl"
{ only_adds; run_out 'echo x > src/Calc.php; false' true "Exit code 1"; } > "$T"
verify "$T" > /dev/null
assert_contains "it reports a Bash write even when the command errored" "$(cat "$VPROJ/out")" "R4 project file changed from Bash"
{ only_adds; run_out 'echo x > src/Calc.php' true "PreToolUse:Bash hook error: HCF TDD guard: refused a Bash command that changes $VPROJ/src/Calc.php."; } > "$T"
verify "$T" > /dev/null
assert_not_contains "it does not count a Bash write the guard refused" "$(cat "$VPROJ/out")" "R4"

# 4. Test files are classified relative to the project, by real conventions.
assert_eq "it treats a production class named Spec.php as production" "DENY $VPROJ/src/Sandbox/Spec.php" "$(gate Edit "$VPROJ/src/Sandbox/Spec.php" 0 "$VPROJ/disarmed.jsonl")"
assert_eq "it treats a production class named Test.php as production" "DENY $VPROJ/src/Test.php" "$(gate Edit "$VPROJ/src/Test.php" 0 "$VPROJ/disarmed.jsonl")"
assert_eq "it treats calc_test.go as a test file" "ALLOW" "$(gate Edit "$VPROJ/calc_test.go" 0 "$VPROJ/disarmed.jsonl")"
assert_eq "it treats calc.spec.ts as a test file" "ALLOW" "$(gate Edit "$VPROJ/src/calc.spec.ts" 0 "$VPROJ/disarmed.jsonl")"
SPROJ="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hcf-under.XXXXXX")" && pwd -P)/spec/app"
mkdir -p "$SPROJ/.claude/plans/demo" "$SPROJ/src"; cp "$TASK" "$SPROJ/.claude/plans/demo/001-demo.md"; : > "$SPROJ/empty.jsonl"
assert_eq "it classifies by the project-relative path when the project lives under spec/" "DENY $SPROJ/src/Calc.php" "$(HCF_GATE_TOOL=Edit HCF_GATE_PATH="$SPROJ/src/Calc.php" HCF_GATE_CWD="$SPROJ" "$VT" --gate "$SPROJ/.claude/plans/demo/001-demo.md" "$SPROJ/empty.jsonl")"

# 5. Matching normalises names; exact filters win; PASSED-FIRST is exact.
TASK5="$VPLAN/005-twice.md"
printf '# Task 005\n- [ ] `it adds two numbers`\n- [ ] `it adds two numbers twice`\n' > "$TASK5"
red5() { tx_use Bash "$(jq -cn --arg c "./vendor/bin/pest --filter=\"$1\"" '{command:$c}')"; tx_res true "FAILED  CalcTest > $2"; }
T="$VPROJ/h-twice.jsonl"
{ add_test "adds two numbers"; red5 "it adds two numbers" "it adds two numbers"; edit_src; green
  add_test "adds two numbers twice"; red5 "adds two numbers twice" "it adds two numbers twice"; edit_src; green; } > "$T"
"$VT" "$TASK5" "$T" > "$VPROJ/out" 2>&1
assert_exit "it credits an exact filter to the shorter of two overlapping requirements" 0 "$?"
T="$VPROJ/h-twice-pass.jsonl"
{ add_test "adds two numbers"; pass_run "it adds two numbers"; } > "$T"
printf 'PASSED-FIRST: it adds two numbers twice — no-code: x\n' >> "$TASK5"
assert_eq "it matches a PASSED-FIRST line on the exact requirement name" "DENY-PASSFIRST it adds two numbers" "$(HCF_GATE_TOOL=Edit HCF_GATE_PATH="$VPROJ/src/Calc.php" HCF_GATE_CWD="$VPROJ" "$VT" --gate "$TASK5" "$T")"
rm -f "$TASK5"

# 6. Inside a tdd-worker the hooks fail closed.
BPROMPT="$(jq -cn --arg t "## Task File Path

\`$TASK\`

## Your Task" '{type:"user", message:{content:$t}}')"
{ printf '%s\n' "$BPROMPT"; cat "$VPROJ/disarmed.jsonl"; } > "$VPROJ/agent-bt.jsonl"
out="$(jq -cn --arg tp "$VPROJ/agent-bt.jsonl" --arg cwd "$VPROJ" --arg p "$VPROJ/src/Calc.php" '{agent_id:"h6", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$p, old_string:"a", new_string:"b"}}' | "$GD")"
assert_contains "it reads a task path in backticks after a blank line" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecisionReason)" "No failing test is armed"
LPROMPT="$(jq -cn --arg t "## Context
$(i=0; while [ $i -lt 250 ]; do echo "line $i"; i=$((i + 1)); done)
## Task File Path
$TASK

## Your Task" '{type:"user", message:{content:$t}}')"
{ printf '%s\n' "$LPROMPT"; cat "$VPROJ/disarmed.jsonl"; } > "$VPROJ/agent-long.jsonl"
out="$(jq -cn --arg tp "$VPROJ/agent-long.jsonl" --arg cwd "$VPROJ" --arg p "$VPROJ/src/Calc.php" '{agent_id:"h7", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$p, old_string:"a", new_string:"b"}}' | "$GD")"
assert_contains "it finds the task path beyond line 200 of the prompt" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecisionReason)" "No failing test is armed"
MPROMPT="$(jq -cn --arg t "## Task File Path
$VPLAN/999-missing.md

## Your Task" '{type:"user", message:{content:$t}}')"
printf '%s\n' "$MPROMPT" > "$VPROJ/agent-missing.jsonl"
out="$(jq -cn --arg tp "$VPROJ/agent-missing.jsonl" --arg cwd "$VPROJ" --arg p "$VPROJ/src/Calc.php" '{agent_id:"h8", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$p}}' | "$GD")"
assert_contains "it denies a worker's change when its task file is missing" "$out" '"permissionDecision":"deny"'
assert_contains "it tells the worker how to end" "$out" "TASK_FAILED: TDD hooks could not run"
out="$(jq -cn --arg tp "$VPROJ/agent-missing.jsonl" --arg cwd "$VPROJ" '{agent_id:"h8", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, stop_hook_active:false}' | "$SA")"
assert_contains "it blocks the stop of a worker whose hooks could not run" "$out" "TASK_FAILED: TDD hooks could not run"
assert_eq "it writes an ERROR verdict where it can" "ERROR" "$(head -n 1 "$VPLAN/.tdd/999-missing.md.verdict" 2>/dev/null)"
out="$(jq -cn --arg tp "$VPROJ/nope.jsonl" --arg cwd "$VPROJ" --arg p "$VPROJ/src/Calc.php" '{agent_id:"h9", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, tool_name:"Write", tool_input:{file_path:$p}}' | "$GD")"
assert_contains "it denies a worker's change when its transcript is unreadable" "$out" '"permissionDecision":"deny"'
NOJQ="$VPROJ/nojq-bin"; mkdir -p "$NOJQ"
for c in bash cat dirname basename grep sed awk head tail tr mkdir mktemp rm printf env sort wc cut; do p="$(command -v "$c")" && [ -n "$p" ] && ln -sf "$p" "$NOJQ/$c"; done
in_nojq='{"agent_id":"h10","agent_type":"hcf:tdd-worker","agent_transcript_path":"'"$VPROJ/agent-good.jsonl"'","cwd":"'"$VPROJ"'","tool_name":"Edit","tool_input":{"file_path":"'"$VPROJ/src/Calc.php"'"},"stop_hook_active":false}'
out="$(printf '%s' "$in_nojq" | PATH="$NOJQ" "$NOJQ/bash" "$GD")"
assert_contains "it denies a worker's change when jq is missing" "$out" '"permissionDecision":"deny"'
assert_contains "it says jq is missing" "$out" "jq"
out="$(printf '%s' "$in_nojq" | PATH="$NOJQ" "$NOJQ/bash" "$SA")"
assert_contains "it blocks a worker's stop when jq is missing" "$out" '"decision":"block"'
out="$(printf '%s' "${in_nojq/hcf:tdd-worker/general-purpose}" | PATH="$NOJQ" "$NOJQ/bash" "$GD")"
assert_empty "it still leaves other agents alone without jq" "$out"

# 9. A plan directory symlinked into the main checkout.
LROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hcf-link.XXXXXX")" && pwd -P)"
mkdir -p "$LROOT/main/.claude/plans/demo" "$LROOT/wt/.claude/plans" "$LROOT/wt/src" "$LROOT/wt/tests"
cp "$TASK" "$LROOT/main/.claude/plans/demo/001-demo.md"
ln -s "$LROOT/main/.claude/plans/demo" "$LROOT/wt/.claude/plans/demo"
LTASK="$LROOT/wt/.claude/plans/demo/001-demo.md"
lnote() { tx_use Write "$(jq -cn --arg p "$LROOT/wt/.claude/plans/demo/notes.json" '{file_path:$p, content:"{}"}')"; tx_res false ok; }
ltest() { tx_use Edit "$(jq -cn --arg p "$LROOT/wt/tests/CalcTest.php" --arg s "it('$1', function () {});" '{file_path:$p, old_string:"", new_string:$s}')"; tx_res false ok; }
lsrc() { tx_use Edit "$(jq -cn --arg p "$LROOT/wt/src/Calc.php" '{file_path:$p, old_string:"a", new_string:"b"}')"; tx_res false ok; }
LT="$LROOT/agent.jsonl"
{ lnote; ltest "adds two numbers"; red "adds two numbers"; lsrc; green; ltest "subtracts two numbers"; red "subtracts two"; lsrc; green; } | sed "s#\"cwd\":\"$VPROJ\"#\"cwd\":\"$LROOT/wt\"#" > "$LT"
"$VT" "$LTASK" "$LT" > "$VPROJ/out" 2>&1
assert_exit "it ignores plan files written through a symlinked plan directory" 0 "$?"
lres() { jq -cn --arg p "$1" --arg cwd "$LROOT/wt" '{type:"user", cwd:$cwd, toolUseResult:{filePath:$p, originalFile:"# task\n", oldString:"# task\n", newString:"# task\n- [x] done\n", replaceAll:false}}'; }
printf '# task\n- [x] done\n' > "$LROOT/wt/.claude/plans/demo/scratch.md"
lres "$LROOT/wt/.claude/plans/demo/scratch.md" > "$LROOT/revert.jsonl"
"$REPO_ROOT/hooks/revert-task.sh" "$LTASK" "$LROOT/revert.jsonl" > /dev/null 2>&1
assert_contains "it never reverts plan files reached through a symlinked plan directory" "$(cat "$LROOT/main/.claude/plans/demo/scratch.md")" "- [x] done"
ln -s "$VPROJ" "$LROOT/projlink"
assert_eq "it checks a production path when cwd is a symlink to the project" "DENY $VPROJ/src/Calc.php" "$(HCF_GATE_TOOL=Edit HCF_GATE_PATH="$VPROJ/src/Calc.php" HCF_GATE_CWD="$LROOT/projlink" "$VT" --gate "$TASK" "$VPROJ/disarmed.jsonl")"
assert_eq "it still recognises a test file through that symlinked cwd" "ALLOW" "$(HCF_GATE_TOOL=Edit HCF_GATE_PATH="$VPROJ/tests/CalcTest.php" HCF_GATE_CWD="$LROOT/projlink" "$VT" --gate "$TASK" "$VPROJ/disarmed.jsonl")"
rm -rf "$LROOT" "$(dirname "$(dirname "$SPROJ")")"

# 12. The guard runs before an earlier call of the same streamed message is in
# the transcript: calls it already allowed are kept in a sidecar and count.
T="$VPROJ/h-lag.jsonl"
{ only_adds; } > "$T"
{ add_test "subtracts two numbers"; } | head -n 1 > "$VPROJ/h-lag.calls"
assert_eq "it allows the edit when the transcript lags and no sidecar is given (the old hole)" "ALLOW" "$(gate Edit "$VPROJ/src/Calc.php" 0 "$T")"
assert_eq "it counts a sidecar call missing from the transcript as done" "DENY $VPROJ/src/Calc.php" "$(HCF_GATE_SIDECAR="$VPROJ/h-lag.calls" gate Edit "$VPROJ/src/Calc.php" 0 "$T")"
mk_worker "$T" "$VPROJ/agent-lag.jsonl"
rm -f "$VPLAN/.tdd/001-demo.md.lag1.calls"
lag_edit() { jq -cn --arg tp "$VPROJ/agent-lag.jsonl" --arg cwd "$VPROJ" --arg p "$1" --arg n "$2" --arg id "$3" '{agent_id:"lag1", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, tool_name:"Edit", tool_use_id:$id, tool_input:{file_path:$p, old_string:"", new_string:$n}}' | "$GD"; }
assert_empty "it allows the new test through the hook" "$(lag_edit "$VPROJ/tests/CalcTest.php" "it('subtracts two numbers', function () {});" s1)"
assert_contains "it records the allowed call in a sidecar" "$(cat "$VPLAN/.tdd/001-demo.md.lag1.calls" 2>/dev/null)" '"id":"s1"'
assert_contains "it denies the production edit streamed right after it" "$(lag_edit "$VPROJ/src/Calc.php" "x" s2)" '"permissionDecision":"deny"'
rm -f "$VPLAN/.tdd/001-demo.md.lag1.calls"

# 13. Another checkout of the same repository is not "outside the project".
GROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hcf-wt.XXXXXX")" && pwd -P)"
mkdir -p "$GROOT/main/src" "$GROOT/main/.claude/plans/demo"
printf 'x\n' > "$GROOT/main/src/Calc.php"; cp "$TASK" "$GROOT/main/.claude/plans/demo/001-demo.md"
git -C "$GROOT/main" init -q && git -C "$GROOT/main" add -A && git -C "$GROOT/main" -c user.email=t@t -c user.name=t commit -qm init
git -C "$GROOT/main" worktree add -q "$GROOT/main/.claude/worktrees/wt" 2>/dev/null
GWT="$GROOT/main/.claude/worktrees/wt"; : > "$GROOT/empty.jsonl"
ggate() { HCF_GATE_TOOL="$1" HCF_GATE_PATH="${2:-}" HCF_GATE_CMD="${3:-}" HCF_GATE_CWD="$GWT" "$VT" --gate "$GWT/.claude/plans/demo/001-demo.md" "$GROOT/empty.jsonl"; }
assert_eq "it denies an edit to the main checkout from a worktree" "DENY-CHECKOUT $GROOT/main/src/Calc.php" "$(ggate Edit "$GROOT/main/src/Calc.php")"
assert_eq "it denies a Bash write to the main checkout from a worktree" "DENY-CHECKOUT $GROOT/main/src/Calc.php" "$(ggate Bash "" "echo x > $GROOT/main/src/Calc.php")"
assert_eq "it still allows a test file in the worker's own worktree" "ALLOW" "$(ggate Edit "$GWT/tests/CalcTest.php")"
assert_eq "it still allows scratch files outside the repository" "ALLOW" "$(ggate Edit "${TMPDIR:-/tmp}/scratch.php")"
{ tx_use Edit "$(jq -cn --arg p "$GROOT/main/src/Calc.php" '{file_path:$p, old_string:"x", new_string:"y"}')"; tx_res false ok; } | sed "s#\"cwd\":\"$VPROJ\"#\"cwd\":\"$GWT\"#" > "$GROOT/other.jsonl"
"$VT" --state "$GWT/.claude/plans/demo/001-demo.md" "$GROOT/other.jsonl" > /dev/null
"$VT" "$GWT/.claude/plans/demo/001-demo.md" "$GROOT/other.jsonl" > "$VPROJ/out" 2>&1
assert_contains "it reports an edit to another checkout" "$(cat "$VPROJ/out")" "R6"
out="$(jq -cn --arg tp "$VPROJ/agent-good.jsonl" --arg cwd "$GWT" --arg p "$GROOT/main/src/Calc.php" '{agent_id:"g1", agent_type:"hcf:tdd-worker", agent_transcript_path:$tp, cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$p, old_string:"x", new_string:"y"}}' | "$GD")"
assert_contains "it tells the worker to edit inside its own working directory" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecisionReason)" "you are working in $GWT"
rm -rf "$GROOT"

# Extra test declarations.
count() { jq -cn --arg n "$1" '{new_string:$n, old_string:""}' | "$VT" --count-tests Edit; }
assert_eq "it counts a /** @test */ method" "1" "$(count '/** @test */
public function adds_two_numbers(): void {}')"
assert_eq "it counts #[Test] on a test-prefixed method once" "1" "$(count '#[Test]
public function test_adds(): void {}')"
assert_eq "it counts a Go test function" "1" "$(count 'func TestAdds(t *testing.T) {}')"
assert_eq "it counts a Rust #[test]" "1" "$(count '#[test]
fn adds() {}')"
assert_eq "it counts it.each, it.only and test.skip" "3" "$(count "it.each([1, 2])('adds %i', (n) => {}); it.only('x', () => {}); test.skip('y', () => {});")"

rm -rf "$VPROJ"

# revert-task.sh: undo one worker's changes exactly, keeping earlier work.
RV="$REPO_ROOT/hooks/revert-task.sh"
RPROJ="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hcf-revert.XXXXXX")" && pwd -P)"
mkdir -p "$RPROJ/src" "$RPROJ/plan"
printf 'earlier task\n' > "$RPROJ/src/Shared.php"
printf '# task\n' > "$RPROJ/plan/001.md"
# res <path> create <content>  /  res <path> edit <originalFile> <oldString> <newString>
res() { jq -cn --arg p "$1" --arg t "$2" --arg o "$3" --arg os "${4:-}" --arg ns "${5:-}" --arg cwd "$RPROJ" '{type:"user", cwd:$cwd, toolUseResult:({filePath:$p} + (if $t == "create" then {type:"create", content:$o} else {originalFile:$o, oldString:$os, newString:$ns, replaceAll:false} end))}'; }
RT="$RPROJ/agent.jsonl"
{ res "$RPROJ/src/Shared.php" edit "earlier task
" "earlier task
" "earlier task
worker edit one
"; res "$RPROJ/src/Shared.php" edit "earlier task
worker edit one
" "worker edit one
" "worker edit one
worker edit two
"; res "$RPROJ/src/New.php" create "new
"; res "$RPROJ/plan/001.md" edit "# task
" "# task
" "# task
- [x] done
"; } > "$RT"
printf 'earlier task\nworker edit one\nworker edit two\n' > "$RPROJ/src/Shared.php"
printf 'new\n' > "$RPROJ/src/New.php"
printf '# task\n- [x] done\n' > "$RPROJ/plan/001.md"
"$RV" "$RPROJ/plan/001.md" "$RT" > /dev/null; code=$?
assert_exit "it reverts a worker's changes" 0 "$code"
assert_eq "it restores a shared file to before the worker's first change" "earlier task" "$(cat "$RPROJ/src/Shared.php")"
[ -e "$RPROJ/src/New.php" ]; assert_exit "it deletes a file the worker created" 1 "$?"
assert_contains "it leaves the plan directory alone" "$(cat "$RPROJ/plan/001.md")" "- [x] done"
printf 'changed\n' > "$RPROJ/src/Shared.php"
"$RV" "$RPROJ/plan/001.md" "$RT" --dry-run > /dev/null 2>&1
assert_eq "it changes nothing on a dry run" "changed" "$(cat "$RPROJ/src/Shared.php")"

# Parallel workers share a worktree: another worker may change the same file
# after this one. Restoring the snapshot would wipe that work, so the worker's
# own edits are undone instead, and only when that can be done exactly.
printf 'earlier task\nworker edit one\nworker edit two\nother worker\n' > "$RPROJ/src/Shared.php"
printf 'new\n' > "$RPROJ/src/New.php"
"$RV" "$RPROJ/plan/001.md" "$RT" > /dev/null 2>&1; code=$?
assert_exit "it reverts a file another worker changed afterwards" 0 "$code"
assert_eq "it keeps the other worker's later change" "$(printf 'earlier task\nother worker')" "$(cat "$RPROJ/src/Shared.php")"
printf 'earlier task\nworker edit one\nworker edit 2 (changed by another worker)\n' > "$RPROJ/src/Shared.php"
printf 'new\n' > "$RPROJ/src/New.php"
"$RV" "$RPROJ/plan/001.md" "$RT" > "$RPROJ/out" 2>&1; code=$?
assert_exit "it fails loudly when another worker changed the worker's own lines" 1 "$code"
assert_eq "it leaves that file untouched" "$(printf 'earlier task\nworker edit one\nworker edit 2 (changed by another worker)')" "$(cat "$RPROJ/src/Shared.php")"
printf 'earlier task\nworker edit one\nworker edit two\n' > "$RPROJ/src/Shared.php"
printf 'new\nadded by another worker\n' > "$RPROJ/src/New.php"
"$RV" "$RPROJ/plan/001.md" "$RT" > "$RPROJ/out" 2>&1; code=$?
assert_exit "it fails loudly when another worker changed a file this worker created" 1 "$code"
assert_eq "it keeps such a created file" "$(printf 'new\nadded by another worker')" "$(cat "$RPROJ/src/New.php")"

OUTSIDE="$(mktemp "${TMPDIR:-/tmp}/hcf-outside.XXXXXX")"; printf 'scratch\n' > "$OUTSIDE"
res "$OUTSIDE" create "" > "$RPROJ/agent3.jsonl"
"$RV" "$RPROJ/plan/001.md" "$RPROJ/agent3.jsonl" > /dev/null
assert_eq "it ignores files outside the project" "scratch" "$(cat "$OUTSIDE")"
rm -f "$OUTSIDE"

# No snapshot recorded (file too large for context): undo the edits instead.
printf 'top\nAAA\nmiddle\nBBB\nend\n' > "$RPROJ/src/Big.php"
edit_res() { jq -cn --arg p "$1" --arg o "$2" --arg n "$3" --arg cwd "$RPROJ" '{type:"user", cwd:$cwd, toolUseResult:{filePath:$p, originalFile:null, oldString:$o, newString:$n, replaceAll:false}}'; }
RT2="$RPROJ/agent2.jsonl"
{ edit_res "$RPROJ/src/Big.php" "AAA" "AAA-1"; edit_res "$RPROJ/src/Big.php" "AAA-1" "AAA-2"; edit_res "$RPROJ/src/Big.php" "BBB" "BBB-x"; } > "$RT2"
printf 'top\nAAA-2\nmiddle\nBBB-x\nend\n' > "$RPROJ/src/Big.php"
"$RV" "$RPROJ/plan/001.md" "$RT2" > /dev/null; code=$?
assert_exit "it reverts edits that have no recorded snapshot" 0 "$code"
assert_eq "it undoes them newest first" "$(printf 'top\nAAA\nmiddle\nBBB\nend')" "$(cat "$RPROJ/src/Big.php")"
assert_eq "it never deletes a file it did not see created" "yes" "$([ -f "$RPROJ/src/Big.php" ] && echo yes)"
printf 'someone else changed this\n' > "$RPROJ/src/Big.php"
"$RV" "$RPROJ/plan/001.md" "$RT2" > /dev/null 2>&1; code=$?
assert_exit "it fails loudly when an edit cannot be undone exactly" 1 "$code"
assert_eq "it leaves such a file untouched" "someone else changed this" "$(cat "$RPROJ/src/Big.php")"
# --dry-run is accepted in any position (an orchestrator writes it first).
printf 'top\nAAA-2\nmiddle\nBBB-x\nend\n' > "$RPROJ/src/Big.php"
"$RV" --dry-run "$RPROJ/plan/001.md" "$RT2" > "$RPROJ/out" 2>&1; code=$?
assert_exit "it accepts --dry-run before the task file" 0 "$code"
assert_contains "it lists what it would undo on a leading --dry-run" "$(cat "$RPROJ/out")" "undo"
assert_eq "it changes nothing on a leading --dry-run" "$(printf 'top\nAAA-2\nmiddle\nBBB-x\nend')" "$(cat "$RPROJ/src/Big.php")"

# A formatter the worker ran on its own files from Bash is the worker's write.
fmt_use() { jq -cn --arg c "$1" --arg cwd "$RPROJ" '{type:"assistant", cwd:$cwd, message:{content:[{type:"tool_use", id:"f1", name:"Bash", input:{command:$c}}]}}'; }
{ res "$RPROJ/src/Made.php" create "<?php  echo 1;
"; fmt_use "./vendor/bin/pint src/Made.php"; } > "$RPROJ/agent-fmt.jsonl"
printf '<?php echo 1;\n' > "$RPROJ/src/Made.php"
"$RV" "$RPROJ/plan/001.md" "$RPROJ/agent-fmt.jsonl" > /dev/null 2>&1; code=$?
assert_exit "it reverts a created file the worker then formatted" 0 "$code"
[ -e "$RPROJ/src/Made.php" ]; assert_exit "it deletes a created file the worker formatted" 1 "$?"
printf 'earlier task\n' > "$RPROJ/src/Kept.php"
{ res "$RPROJ/src/Kept.php" edit "earlier task
" "earlier task
" "earlier task
worker  edit
"; fmt_use "cd $RPROJ && vendor/bin/pint src/Kept.php"; } > "$RPROJ/agent-fmt2.jsonl"
printf 'earlier task\nworker edit\n' > "$RPROJ/src/Kept.php"
"$RV" "$RPROJ/plan/001.md" "$RPROJ/agent-fmt2.jsonl" > /dev/null 2>&1; code=$?
assert_exit "it reverts an edited file the worker then formatted" 0 "$code"
assert_eq "it restores that file's snapshot" "earlier task" "$(cat "$RPROJ/src/Kept.php")"
{ res "$RPROJ/src/Made.php" create "<?php  echo 1;
"; fmt_use "./vendor/bin/pint src/Other.php"; } > "$RPROJ/agent-fmt3.jsonl"
printf '<?php echo 1;\n' > "$RPROJ/src/Made.php"
"$RV" "$RPROJ/plan/001.md" "$RPROJ/agent-fmt3.jsonl" > /dev/null 2>&1; code=$?
assert_exit "it still refuses a created file changed by someone else" 1 "$code"

rm -rf "$RPROJ"
