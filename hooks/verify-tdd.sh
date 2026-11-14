#!/usr/bin/env bash
# HCF TDD verifier. Proves, from a tdd-worker's own transcript, that a task was
# built test-first, one requirement at a time. The worker cannot edit or skip
# the transcript, so this is evidence, not self-report.
#
# Usage:
#   verify-tdd.sh <task-file> <agent-transcript.jsonl>            # verify
#   verify-tdd.sh --state <task-file> <agent-transcript.jsonl>    # ARMED | DISARMED
#   verify-tdd.sh --touched <task-file> <agent-transcript.jsonl>  # files the worker changed
#   verify-tdd.sh --gate <task-file> <agent-transcript.jsonl>     # ALLOW | DENY <path> | DENY-BASH <path>
#   verify-tdd.sh --removal-only <Edit|MultiEdit>  < tool-input.json  # yes | no
#   verify-tdd.sh --count-tests <Edit|MultiEdit|Write> < tool-input.json  # tests the call adds
#
# --gate judges a pending tool call described by the environment:
#   HCF_GATE_TOOL (Edit|Write|MultiEdit|NotebookEdit|Bash), HCF_GATE_PATH,
#   HCF_GATE_CMD (for Bash, the raw command), HCF_GATE_CWD, HCF_GATE_ADDED
#   (tests the call adds), HCF_GATE_REMOVAL (yes when the call is a
#   removal-only Edit or MultiEdit, see --removal-only) and HCF_GATE_ID (the
#   call's tool_use_id), and HCF_GATE_SIDECAR (calls the guard already
#   allowed, as transcript tool_use lines, read after the transcript: they
#   count even before the transcript holds them). The transcript is still
#   being written while the guard reads it: tools from one streamed message run back to back, so an earlier
#   call's result, or the last line itself, may not be on disk yet. --gate
#   therefore skips lines that do not parse and counts every earlier file edit
#   that has no result yet as done (all but the call being judged), so a
#   half-written transcript never opens the gate. Besides DENY and DENY-BASH it
#   can print DENY-CHECKOUT <path> (a path in another checkout of the same
#   repository), DENY-FORMAT <cwd> (a formatter run without a file list),
#   DENY-BATCH <path> (a new test while the last new test has not been run) and
#   DENY-PASSFIRST <name> (a filtered run passed for a requirement that never
#   failed, and the task file has no no-code PASSED-FIRST line for it).
#
# --state prints whether a production edit would be allowed right now (a
# failing test has armed it and no new test has disarmed it since). --touched
# lists, one per line, every project file the worker edited or wrote, so the
# orchestrator can revert exactly that task's work. --removal-only reads an
# Edit or MultiEdit tool input (JSON) on stdin and says whether it only deletes
# code (see "Cut-back" below). --count-tests reads a tool input on stdin and
# prints how many tests the call adds (Edit/MultiEdit: new minus old; Write:
# content minus the file on disk). The edit guard uses both, so the guard and
# the verifier always count the same way.
#
# Requirements: "- [ ] `name`" / "- [x] `name`" lines, optionally followed by
# (guard). They are read from the worker's FIRST prompt, under its
# "## Your Task" heading (plan-orchestrate pastes the task file there), so a
# worker cannot change what it is held to by editing its task file. Only when
# the prompt has no such list are they read from the task file. When both
# exist and the task file drops or renames a requirement, or labels one
# (guard), that is violation R5; requirements the worker added there are
# verified too. PASSED-FIRST lines are
# read from the task file: the worker writes them.
#
# Names are compared normalised: camelCase and snake_case split into words,
# lowercased, punctuation dropped, and a leading "it"/"test" removed, so
# "it creates a user", test_creates_a_user, testCreatesAUser and
# TestCreatesAUser are the same name.
#
# A test declaration is it( or test( (optionally .only/.skip/.todo/...)
# followed by a string (the test's name, possibly on the next line),
# it.each(...)/test.each(...), function test...( , def test_...( , Go's
# func TestX( , #[Test] / @test on a method not named test..., @Test, or
# Rust's #[test]. it/test after ->, ::, . or $ is a method call, and test()
# with no name (Pest's test()->markTestSkipped()) is a helper call: neither
# counts.
#
# A test run is a Bash segment (split on ; && || |, outside quotes, comments
# removed) whose EXECUTED command is a test runner: the first word, after
# common wrappers (VAR=x, env, time, nice, timeout, xargs, npx/bunx,
# npm/pnpm/yarn exec, uv/poetry/pipenv run, bundle exec, an interpreter such as
# php/python -m/node, docker [compose] exec|run [options] <service>, sh -c
# "...", and any "commandWrappers" listed in .claude/hcf.json). Runners are
# recognised by name (pest, phpunit, jest, vitest, pytest, rspec, mocha,
# go test, cargo test, npm/yarn/pnpm/bun test, composer/mix/artisan test, ...)
# or listed under "testRunners" in .claude/hcf.json. A runner named inside a
# comment or as an argument (echo, ls, grep) is not a run. The filter is read
# only after the runner: --filter, -t, -k, --testNamePattern, -run, -e,
# --grep, a path::name node id, or cargo test's positional name.
#
# A run is RED for requirement N only when the runner is the executed program,
# its filter names N, and its output shows a test failure: a failing-test line
# as Pest/PHPUnit/Vitest/Jest/pytest/Go/Rust/RSpec print it, a failure count
# ("Tests: 1 failed", "1 failed in 0.02s", FAILURES!), an assertion failure
# message, or a compile/collection failure (Go [build failed], pytest
# collection errors, a suite that failed to load, a missing module). A run
# trimmed with tail or grep usually keeps only the count, which is enough. A
# line counts only at the start of an output line, so a passing test whose
# name contains FAILED is not a failure, and never when the command itself
# printed it (echo "FAILED ...").
# Infrastructure errors never count: Docker daemon down, connection refused,
# command not found, no tests found/executed, Killed, out of memory, and a
# parse/syntax error.
#
# Rules, checked in transcript order:
#   R1  Every requirement has at least one RED run. A requirement whose test
#       was never written is reported as "not attempted (no test written)": an
#       unfinished task, still a violation.
#   R2  No production file is edited before a red run has armed it. After a
#       red run, production edits are allowed (GREEN and REFACTOR) until a test
#       edit adds a new test, which disarms until the next red.
#   R3  At most one new test is added between failing runs. Writing several
#       tests and then running them is batch-writing, not TDD.
#   R4  Project files change only through Edit/Write/MultiEdit/NotebookEdit.
#       A Bash write (redirect, heredoc into a file, tee, sed -i, cp/mv/ln/
#       install/rsync/touch/truncate/dd of=, patch, git apply/checkout/restore
#       and other tree-changing git commands, a code generator such as
#       artisan make: or any "fileGenerators" entry, sh -c/bash -c/eval or a
#       script piped into a shell that writes, or an interpreter script that
#       writes files) is a violation in itself, whether or not the command
#       errored, unless the guard refused it.
#   R5  No requirement in the prompt is removed or renamed in the task file, or
#       labelled (guard) there. A requirement the worker adds is allowed and
#       verified like the others.
#   R6  No file in another checkout of the same repository (the main worktree
#       or another linked worktree, from `git worktree list`) is changed: the
#       worker works only in its own cwd. Paths outside the repository (/tmp)
#       stay exempt.
#
# A requirement labelled (guard) is expected to pass on its first run: it only
# needs a filtered run naming it.
#
# Any other requirement whose test passes on its first run is answered by a
# cut-back (below): whatever production code makes it pass, an earlier test's
# or an over-built one, deleting it must turn the test red, which proves the
# test detects that code. Only when NO production code delivers the behaviour
# (a language or framework guarantee: there is nothing to delete) may it be
# justified in the task file instead, with a line:
#   PASSED-FIRST: <requirement name> — no-code: <reason>
# The name must be the requirement's exact name. That is reported as a warning
# (REVIEW). A PASSED-FIRST line without "no-code:" is not an answer: the guard
# keeps refusing, and the verifier reports "R1 `N` passed on its first run and
# was not cut back".
#
# Cut-back (THE answer to a first-run pass): while a filtered run naming
# requirement N has passed, N has never failed and the task file has no
# no-code PASSED-FIRST line for N, the worker may make REMOVAL-ONLY production
# edits to delete the over-built code, then run N filtered and see it FAIL.
# That failing run makes N red-before-green (R1, no warning) and the cut-back
# edits are not R2 violations. If a non-removal production edit, a new test,
# or the end of the transcript comes first, every cut-back edit for N is
# reported as "R2 cut-back for `N` was never followed by a failing run naming
# it". A PASSED-FIRST line written after a cut-back does not turn it back into
# a plain R2 edit, so the verifier agrees with what the guard allowed live.
#
# Removal-only: an Edit, or a MultiEdit whose every edit, where the tokens of
# new_string are a subsequence of the tokens of old_string and there are
# strictly fewer of them. Tokens, whitespace ignored: a single-line string
# literal is one token, a run of [A-Za-z0-9_] is one token, and every other
# non-space character is its own token. Write, NotebookEdit and Bash are never
# removal-only, and deleting a whole file is not a cut-back.
#
# Files are classified by their path relative to the project (the worker's
# cwd, or the same directory through a symlink). A "test file" is under a
# tests/, test/, spec/, specs/ or __tests__/ directory, or follows a test
# naming convention: <Name>Test.<ext>, <Name>Tests.<ext>, <name>.test.<ext>,
# <name>.spec.<ext>, <name>_test.<ext>, <name>_spec.<ext>, <Name>Spec.rb (also
# .groovy/.scala/.kt/.swift) or test_<name>.py, always with something before
# the suffix (a file named Spec.php or Test.php is production). Markdown and
# files outside the project or inside the task file's own directory (compared
# both as given and with symlinks resolved) are ignored. Every other edited
# file is production.
#
# Exit codes:
#   0  verified
#   1  violations found (listed on stdout)
#   2  no violations, but warnings need review
#   3  usage error, unreadable input, or jq missing
#   4  the task has no test requirements (docs, config): nothing was checked

set -u

mode="verify"
case "${1:-}" in
  --state) mode="state"; shift ;;
  --touched) mode="touched"; shift ;;
  --gate) mode="gate"; shift ;;
  --removal-only) mode="removal"; shift ;;
  --count-tests) mode="count"; shift ;;
esac

# jq definitions for test counting and removal-only edits, shared by the
# --count-tests and --removal-only modes (the edit guard) and the transcript
# reader below.
# shellcheck disable=SC2016  # jq variables, not shell ones
removal_defs='
  def ntests: [match("(^|[^A-Za-z0-9_$>:.])(it|test)(\\.(only|skip|todo|concurrent|fails|failing|sequential))?\\s*\\(\\s*[\"\u0027`]|(^|[^A-Za-z0-9_$>:.])(it|test)\\.each\\b|function\\s+test[A-Za-z0-9_]*\\s*\\(|def\\s+test_[A-Za-z0-9_]*\\s*\\(|func\\s+Test[A-Z0-9_][A-Za-z0-9_]*\\s*\\(|(#\\[Test\\]|@test\\b)(?:(?!function)[\\s\\S])*function\\s+(?!test)|@Test\\b|#\\[(tokio::)?test\\]"; "g")] | length;
  def added_tests($tool; $disk): if $tool == "Edit" then ((.new_string // "") | ntests) - ((.old_string // "") | ntests)
    elif $tool == "MultiEdit" then ([(.edits // [])[] | ((.new_string // "") | ntests) - ((.old_string // "") | ntests)] | add // 0)
    elif $tool == "Write" then (((.content // .file_text) // "") | ntests) - ($disk | ntests)
    else 0 end;
  def toks: [scan("\"(?:\\\\.|[^\"\\\\\n])*\"|\u0027(?:\\\\.|[^\u0027\\\\\n])*\u0027|[A-Za-z0-9_]+|[^\\s]")];
  def subseq($small; $big): (reduce $big[] as $t (0; if . < ($small | length) and $small[.] == $t then . + 1 else . end)) == ($small | length);
  def removal_only: ((.old_string // "") | toks) as $o | ((.new_string // "") | toks) as $n
    | ($n | length) < ($o | length) and subseq($n; $o);
  def removal_edit($tool): if $tool == "Edit" then removal_only
    elif $tool == "MultiEdit" then ((.edits // []) | length > 0 and all(.[]; removal_only))
    else false end;
'
if [ "$mode" = "count" ]; then
  command -v jq >/dev/null 2>&1 || { echo 0; exit 3; }
  input="$(cat)"
  target="$(printf '%s' "$input" | jq -r '.file_path // .notebook_path // empty' 2>/dev/null)"
  disk=/dev/null
  [ "${1:-}" = "Write" ] && [ -n "$target" ] && [ -f "$target" ] && disk="$target"
  out="$(printf '%s' "$input" | jq -r --arg tool "${1:-}" --rawfile disk "$disk" "$removal_defs"'added_tests($tool; $disk)' 2>/dev/null)"
  case "$out" in -[0-9]*|[0-9]*) echo "$out" ;; *) echo 0 ;; esac
  exit 0
fi
if [ "$mode" = "removal" ]; then
  command -v jq >/dev/null 2>&1 || { echo no; exit 3; }
  out="$(jq -r --arg tool "${1:-}" "$removal_defs"'removal_edit($tool) | if . then "yes" else "no" end' 2>/dev/null)"
  [ "$out" = "yes" ] && echo yes || echo no
  exit 0
fi

task_file="${1:-}"
transcript="${2:-}"

if [ -z "$task_file" ] || [ -z "$transcript" ]; then
  printf 'usage: verify-tdd.sh <task-file> <agent-transcript.jsonl>\n' >&2
  exit 3
fi
for f in "$task_file" "$transcript"; do
  if [ ! -r "$f" ]; then
    printf 'verify-tdd: error: cannot read %s\n' "$f" >&2
    exit 3
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  # Loud, never a silent pass: an unverified task must not count as verified.
  printf 'verify-tdd: error: jq is required to read the transcript and was not found\n' >&2
  exit 3
fi

# Command and name helpers shared by the transcript reader and --gate.
# shellcheck disable=SC2016  # jq variables, not shell ones
cmd_defs='
  def oneline: gsub("[\n\r]"; " ; ") | gsub("\t"; " ");
  # Heredoc bodies are data, not shell: drop them, keeping the rest of the
  # opening line (cat <<EOF > file still redirects).
  def noheredoc: gsub("<<-?\\s*[\"\u0027]?(?<tag>[A-Za-z_][A-Za-z0-9_]*)[\"\u0027]?(?<rest>[^\n]*)\n(?s:.*?)\n\\s*\\k<tag>(?=\n|$)"; "<<HEREDOC\(.rest)");
  # Comments are not commands: drop an unquoted # (at a word start) to the end of its line.
  def nocomment: if test("#") | not then . else split("\n") | map(. as $l | reduce ($l | explode)[] as $c ({o: [], q: null, p: 32, done: false, e: false};
      if .done then .
      elif .e then .o += [$c] | .p = $c | .e = false
      elif $c == 92 and .q != 39 then .o += [$c] | .p = $c | .e = true
      elif .q != null then .o += [$c] | .p = $c | (if $c == .q then .q = null else . end)
      elif $c == 34 or $c == 39 then .o += [$c] | .q = $c | .p = $c
      elif $c == 35 and (.p == 32 or .p == 9 or .p == 59 or .p == 38 or .p == 124 or .p == 40) then .done = true
      else .o += [$c] | .p = $c end) | .o | implode) | join("\n") end;
  def writey: test("(^|[^0-9&>=-])>>?\\s*[^\\s&>]|(^|[\\s;&|(])(tee|touch|cp|mv|ln|install|rsync|dd|truncate|patch)\\s|(sed|perl)\\s+(-\\S+\\s+)*-i|git\\s+(apply|checkout|restore|stash|reset|clean|switch)");
  # A heredoc fed to a shell (bash <<EOF) is a script: does it write?
  def shellbody: [scan("(?:^|[\\s;&|(])(?:ba|z|da|k)?sh\\b[^\\n]*<<-?\\s*[\"\u0027]?(?<tag>[A-Za-z_][A-Za-z0-9_]*)[\"\u0027]?[^\\n]*\\n((?s:.*?))\\n\\s*\\k<tag>(?=\\n|$)") | .[1] | select(writey)] | if length > 0 then "1" else "" end;
  # Interpreter one-offs (python3 - <<EOF ... open(p, "w")) also write files.
  # Their targets are usually variables, so every file-like string literal in
  # a writing script is treated as written: over-reporting beats a blind spot.
  def scriptwrites: if test("(^|[^A-Za-z])(python3?|php|node|ruby|perl)([^A-Za-z]|$)") and test("open\\(|write_text|write_bytes|file_put_contents|writeFile|File\\.write|IO\\.write")
      then [scan("[\"\u0027]([A-Za-z0-9_./-]+\\.(php|py|js|mjs|ts|tsx|jsx|rb|go|rs|java|kt|json|ya?ml|xml|neon|ini|toml|twig|latte|blade\\.php))[\"\u0027]") | .[0]] | unique | join(" ")
      else "" end;
  def norm: gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a) \(.b)") | gsub("(?<a>[A-Z])(?<b>[A-Z][a-z])"; "\(.a) \(.b)")
    | gsub("(?<a>[A-Za-z])(?<b>[0-9])"; "\(.a) \(.b)") | gsub("(?<a>[0-9])(?<b>[A-Za-z])"; "\(.a) \(.b)")
    | ascii_downcase | gsub("[^a-z0-9]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
  def name_norm: (" " + norm) | until(test("^ (it|test)( |$)") | not; sub("^ (it|test)"; "")) | sub("^ +"; "");
  # The first prompt: the first user message that carries text.
  def prompt_text: .message.content | if type == "string" then . elif type == "array" then (map(select(.type == "text") | .text) | join("\n")) else "" end;
'

# The worker's first prompt, and the "## Your Task" section of it.
first_prompt="$(jq -Rrn 'first(inputs | fromjson? | select(.type == "user") | (.message.content | if type == "string" then . elif type == "array" then (map(select(.type == "text") | .text) | join("\n")) else "" end) | select(length > 0)) // ""' "$transcript" 2>/dev/null)"
prompt_task="$(printf '%s\n' "$first_prompt" | awk 'f { print } /^##[[:space:]]+Your Task[[:space:]]*$/ { f = 1 }')"

# Requirement names, in order, one per line (backticks stripped). A test
# requirement is a checklist item that is ONLY a backticked test name,
# optionally labelled (guard). Descriptive checklist items that merely start
# with code ("- [x] `docs/page.md` gains a section") are not tests.
req_names() { sed -n 's/^[[:space:]]*- \[[ xX]\] `\([^`]*\)`[[:space:]]*\((guard)\)\{0,1\}[[:space:]]*$/\1/p'; }
req_guards() { sed -n 's/^[[:space:]]*- \[[ xX]\] `\([^`]*\)`[[:space:]]*(guard)[[:space:]]*$/\1/p'; }

file_requirements="$(req_names < "$task_file")"
prompt_requirements="$(printf '%s\n' "$prompt_task" | req_names)"
req_change=""
if [ -n "$prompt_requirements" ]; then
  # The prompt's list is authoritative. A requirement the worker added to its
  # task file is held to the same rules (verified too); one removed or
  # renamed, or newly labelled (guard), is violation R5.
  guards="$(printf '%s\n' "$prompt_task" | req_guards)"
  file_guards="$(req_guards < "$task_file")"
  removed="$(comm -23 <(printf '%s\n' "$prompt_requirements" | sort -u) <(printf '%s\n' "$file_requirements" | sort -u) | awk 'NF { printf "%s`%s`", (n++ ? ", " : ""), $0 }')"
  relabelled="$(comm -12 <(printf '%s\n' "$file_guards" | sort -u) <(comm -23 <(printf '%s\n' "$prompt_requirements" | sort -u) <(printf '%s\n' "$guards" | sort -u)) | awk 'NF { printf "%s`%s`", (n++ ? ", " : ""), $0 }')"
  added="$(printf '%s\n' "$file_requirements" | awk 'NR == FNR { if (NF) seen[$0] = 1; next } NF && !seen[$0]' <(printf '%s\n' "$prompt_requirements") -)"
  requirements="$prompt_requirements"
  if [ -n "$added" ]; then
    requirements="$(printf '%s\n%s' "$prompt_requirements" "$added")"
    guards="$(printf '%s\n%s' "$guards" "$(printf '%s\n' "$file_guards" | grep -Fx -f <(printf '%s\n' "$added") || true)")"
  fi
  if [ -n "$removed$relabelled" ]; then
    req_change="R5 the task file's requirement list no longer matches the one in your prompt (requirements are fixed by the orchestrator; only tick their checkboxes, or add new ones):"
    [ -n "$removed" ] && req_change="$req_change removed or renamed $removed;"
    [ -n "$relabelled" ] && req_change="$req_change labelled (guard) $relabelled;"
  fi
else
  requirements="$file_requirements"
  guards="$(req_guards < "$task_file")"
fi
if [ -z "$requirements" ] && [ "$mode" != "touched" ] && [ "$mode" != "state" ]; then
  # A task with no test requirements (docs, config) has nothing to arm.
  [ "$mode" = "gate" ] && { echo ALLOW; exit 0; }
  printf 'verify-tdd: no test requirements in %s; nothing to verify\n' "$task_file"
  exit 4
fi

# The task directory, as given and with symlinks resolved: a plan directory is
# often a symlink from a worktree into the main checkout.
task_dir_l="$(cd "$(dirname "$task_file")" && pwd)"
task_dir_r="$(cd "$(dirname "$task_file")" && pwd -P)"
task_file_r="$task_dir_r/$(basename "$task_file")"

# The project: the cwd the worker ran in (the gate's, or the transcript's).
if [ "$mode" = "gate" ]; then
  first_cwd="${HCF_GATE_CWD:-}"
else
  first_cwd="$(jq -Rrn 'first(inputs | fromjson? | .cwd // empty | select(length > 0)) // ""' "$transcript" 2>/dev/null)"
fi
project_root=""
[ -n "$first_cwd" ] && [ -d "$first_cwd" ] && project_root="$(git -C "$first_cwd" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$project_root" ] || project_root="$(git -C "$task_dir_l" rev-parse --show-toplevel 2>/dev/null || true)"

# Project settings in .claude/hcf.json, for what HCF cannot know on its own:
#   testRunners      commands that run tests      ["bin/run-specs", "make check"]
#   commandWrappers  prefixes that run a command  ["bin/dc exec app"]
#   fileGenerators   commands that write files    ["bin/gen", "plop"]
# Each entry is a literal prefix of a command (or of what a wrapper runs).
conf_list() {
  [ -n "$project_root" ] && [ -r "$project_root/.claude/hcf.json" ] || return 0
  jq -r --arg k "$1" '(.[$k] // []) | if type == "array" then .[] | select(type == "string" and length > 0) else empty end' \
    "$project_root/.claude/hcf.json" 2>/dev/null || true
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/hcf-verify.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$requirements" > "$tmp/reqs"
printf '%s\n' "$guards" > "$tmp/guards"
conf_list testRunners > "$tmp/runners"
conf_list commandWrappers > "$tmp/wrappers"
conf_list fileGenerators > "$tmp/generators"
# Other checkouts of the same repository (the main worktree and every linked
# one but the worker's own): a path in one of them is not "outside the
# project" but another copy of it, and changing it is refused.
own_root=""
[ -n "$first_cwd" ] && [ -d "$first_cwd" ] && own_root="$(git -C "$first_cwd" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$own_root" ]; then
  own_real="$(cd "$own_root" && pwd -P)"
  git -C "$first_cwd" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    wr="$(cd "$wt" 2>/dev/null && pwd -P)" || wr="$wt"
    [ "$wr" = "$own_real" ] && continue
    printf '%s\n' "$wt"; [ "$wr" != "$wt" ] && printf '%s\n' "$wr"
  done > "$tmp/checkouts"
else
  : > "$tmp/checkouts"
fi
# Normalised requirement names, line for line with $tmp/reqs.
jq -Rr "$cmd_defs"'name_norm' < "$tmp/reqs" > "$tmp/reqnorm"

# Flatten the transcript into one tab-separated event per line, in order:
#   USE  <id> <tool> <path> <added-tests> <command> <cwd> <script-writes>
#        <names> <R if removal-only> <shell-body-writes> <raw command>
#   RES  <id> <is_error> <infra-error> <pass-evidence> <failure lines>
#        <load-failure lines> <refused by the guard>
# Lines are joined with \036. Load-failure lines also carry failure summaries. "added-tests" counts test declarations added by
# an Edit/MultiEdit (new minus old) or present in a Write's content (W prefix:
# baseline resolved below). --gate reads a transcript that is still being
# written, so it parses line by line and skips a line that does not parse;
# every other mode reads a finished transcript and rejects a broken one.
jq_raw=""; jq_parse=""
if [ "$mode" = "gate" ]; then jq_raw="-R"; jq_parse="fromjson? | "; fi
# shellcheck disable=SC2086  # $jq_raw is empty or one flag
events="$(jq $jq_raw -r --rawfile reqnorm "$tmp/reqnorm" "$removal_defs$cmd_defs"'
  # A normalised name as a regex over source text: its words in order, in any
  # case, joined by nothing (camelCase) or by non-word characters (snake_case,
  # prose), starting and ending at a word boundary. Matching source this way
  # avoids normalising whole files, which is slow.
  def wordre: explode | map([.] | implode | if test("[a-z]") then "[" + . + ascii_upcase + "]" else . end) | join("");
  def name_re: . as $n | split(" ") | map(wordre) | join("[^A-Za-z0-9]*")
    | "(?:^|(?<=[^A-Za-z0-9])|(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Za-z])(?=[0-9])|(?<=[0-9])(?=[A-Za-z]))" + .
      + (if ($n | test("[0-9]$")) then "(?![0-9])" else "(?![a-z])" end);
  def reqres: [$reqnorm | split("\n")[] | select(length > 0) | name_re];
  # 1-based indices of requirements whose name appears in a test edit.
  def names_in: . as $c | [reqres | to_entries[] | select(.value as $re | $c | test($re)) | (.key + 1 | tostring)] | join(",");
  def failline: (test("^(✓|✔|√|PASS|PASSED|ok)(\\s|$)") | not) and
    (test("^(FAILED|FAIL|ERROR|✕|×|⨯|✗|✘|●)\\s") or test("^---\\s+FAIL:") or test("^[0-9]+\\)\\s+\\S")
     or test("^(FAIL|ERROR):\\s") or test("\\s\\.\\.\\.\\s+(FAILED|FAIL|ERROR)$") or test("^rspec\\s+\\S+\\s+#\\s")
     or test("\\s(FAILED|ERROR)(\\s+\\[\\s*[0-9]+%\\])?$"));
  '"$jq_parse"'select(.type == "assistant" or .type == "user")
  | .cwd as $cwd
  | (.message.content // []) | if type == "array" then .[] else empty end
  | if .type == "tool_use" then
      (.input // {}) as $in
      | ( if .name == "Edit" then (($in.new_string // "") | ntests) - (($in.old_string // "") | ntests) | tostring
          elif .name == "MultiEdit" then ([($in.edits // [])[] | ((.new_string // "") | ntests) - ((.old_string // "") | ntests)] | add // 0) | tostring
          elif .name == "Write" then "W" + (((($in.content // $in.file_text) // "") | ntests) | tostring)
          else "0" end ) as $added
      | ($in.command // "") as $c
      | ["USE", .id, .name, ($in.file_path // $in.notebook_path // ""), $added, ($c | noheredoc | nocomment | oneline), ($cwd // ""), ($c | scriptwrites),
         (if (.name | test("^(Edit|MultiEdit|Write)$")) then ((($in.new_string // "") + "\n" + (($in.content // $in.file_text) // "") + "\n" + ([($in.edits // [])[] | .new_string // ""] | join("\n"))) | names_in) else "" end),
         (.name as $tn | if ($in | removal_edit($tn)) then "R" else "" end),
         ($c | shellbody), ($c | oneline)] | @tsv
    elif .type == "tool_result" then
      ((.content // "") | if type == "array" then map(.text // "") | join("\n") else tostring end
        | gsub("\u001b\\[[0-9;]*m"; "")) as $out
      # Candidate lines found with one scan each (splitting large outputs into
      # lines is slow), then checked line by line.
      | [$out | match("(?:^|\n)[ \t]*((?:[0-9]+\\)|rspec |[✕×⨯✗✘●]|[^\n]*(?:FAIL|ERROR))[^\n]*)"; "g") | .captures[0].string | sub("\\s+$"; "")] as $lines
      | "\\[build failed\\]|\\[setup failed\\]|ERROR collecting|errors? during collection|Test suite failed to run|Failed to load url|Failed to resolve import|Cannot find module|could not compile|error\\[E[0-9]+\\]|ModuleNotFoundError|ImportError|NameError: name|undefined: [A-Za-z_]|cannot find (?:value|function|type)" as $loadre
      | (if ($out | test($loadre)) then [$out | match("(?:^|\n)([^\n]*(?:" + $loadre + ")[^\n]*)"; "g") | .captures[0].string | sub("^\\s+"; "") | sub("\\s+$"; "")] else [] end) as $loadlines
      # Failure summaries and assertion messages: a run trimmed with tail or
      # grep often keeps only these, without the line naming the failing test.
      | "\\b[1-9][0-9]* (?:failed|failing|failures?|errors?)\\b|FAILURES!|Failed asserting|AssertionError|AssertionFailedError|ExpectationFailedException" as $sumre
      | (if ($out | test($sumre)) then [$out | match("(?:^|\n)([^\n]*(?:" + $sumre + ")[^\n]*)"; "g") | .captures[0].string | sub("^\\s+"; "") | sub("\\s+$"; "")] else [] end) as $sumlines
      | ["RES", .tool_use_id,
          (if .is_error == true then "1" else "0" end),
          (if ($out | test("Allowed memory size of [0-9]+ bytes exhausted|Segmentation fault|(^|\\s)Killed(\\s|$)|command not found|No tests found|No test files found|No tests executed|[Nn]o tests ran|No tests were found|no tests to run|Cannot connect to the Docker daemon|Error response from daemon|OCI runtime|Connection refused|[Oo]ut of memory|ParseError|Parse error:|syntax error, unexpected|SyntaxError:|IndentationError")) then "1" else "0" end),
          (if ($out | test("Tests:[^\\n]*\\b[1-9][0-9]* passed|\\bOK \\([1-9]|✓|✔|\\bPASS\\b|\\b[1-9][0-9]* (passed|passing)\\b|(^|\\n)ok\\s|test result: ok")) then "1" else "0" end),
          ([$lines[] | select(failline)] | join("\u001e")),
          ($loadlines + $sumlines | join("\u001e")),
          (if .is_error == true and ($out | test("HCF TDD guard: refused")) then "1" else "0" end)
        ] | @tsv
    else empty end
' < <(
  cat "$transcript"
  # --gate: calls the guard already allowed may not be in the transcript yet
  # (it lags behind tools streamed in one message). They follow, as the
  # latest calls; one already in the transcript is the same call again.
  if [ "$mode" = "gate" ] && [ -n "${HCF_GATE_SIDECAR:-}" ] && [ -r "${HCF_GATE_SIDECAR:-}" ]; then
    printf '\n'; cat "$HCF_GATE_SIDECAR"
  fi) 2>/dev/null)"
if [ $? -ne 0 ]; then
  printf 'verify-tdd: error: %s is not a readable JSONL transcript\n' "$transcript" >&2
  exit 3
fi

# The pending call, normalised the same way (the guard passes it raw).
gate_cmd=""; gate_scripts=""; gate_shellbody=""
if [ "$mode" = "gate" ] && [ "${HCF_GATE_TOOL:-}" = "Bash" ]; then
  gate_cmd="$(jq -rn --arg c "${HCF_GATE_CMD:-}" "$cmd_defs"'$c | noheredoc | nocomment | oneline')"
  gate_scripts="$(jq -rn --arg c "${HCF_GATE_CMD:-}" "$cmd_defs"'$c | scriptwrites') ${HCF_GATE_SCRIPTWRITES:-}"
  gate_shellbody="$(jq -rn --arg c "${HCF_GATE_CMD:-}" "$cmd_defs"'$c | shellbody')"
fi

# A Write to an existing test file replaces it: count only the tests it adds
# over what the file held at HEAD (or over the previous Write in this run).
# Resolved here in bash because the baseline needs git.
baseline_tests() {
  local path="$1" root rel
  root="$(git -C "$(dirname "$path")" rev-parse --show-toplevel 2>/dev/null)" || { echo 0; return; }
  rel="${path#"$root"/}"
  git -C "$root" show "HEAD:$rel" 2>/dev/null \
    | jq -Rs "$removal_defs"'ntests' 2>/dev/null \
    || true
}
# A path with symlinks in its directory resolved, or nothing when it is the same.
real_of() {
  local d
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 0
  [ "$d/$(basename "$1")" != "$1" ] && printf '%s/%s' "$d" "$(basename "$1")"
  return 0
}
real_dir() { (cd "$1" 2>/dev/null && pwd -P) || true; }

LC_ALL=C awk -F'\t' \
  -v tmp="$tmp" \
  -v mode="$mode" \
  -v task_dir_l="$task_dir_l" \
  -v task_dir_r="$task_dir_r" \
  -v task_file="$task_file" \
  -v task_file_r="$task_file_r" \
  -v project_root="$project_root" \
  -v req_change="$req_change" \
  -v gate_cmd="$gate_cmd" \
  -v gate_scripts="$gate_scripts" \
  -v gate_shellbody="$gate_shellbody" '
function lc(s) { return tolower(s) }
# Undoes the @tsv escaping of jq (\\ \t \n \r).
function untsv(s,   out, i, c, n) {
  if (index(s, "\\") == 0) return s
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\" && i < n) {
      c = substr(s, ++i, 1)
      if (c == "t") c = "\t"; else if (c == "n") c = "\n"; else if (c == "r") c = "\r"
    }
    out = out c
  }
  return out
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function base(w) { w = unquote(w); sub(/.*\//, "", w); return w }
function unquote(w) {
  if (w ~ /^".*"$/ && length(w) > 1) { w = substr(w, 2, length(w) - 2); gsub(/\\"/, "\"", w); return w }
  if (w ~ /^\047.*\047$/ && length(w) > 1) return substr(w, 2, length(w) - 2)
  return w
}
# Normalised name: camelCase, digits and punctuation split into words,
# lowercased (must match the jq norm above).
function norm(s,   out, i, n, c, p, nx) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1); p = (i > 1) ? substr(s, i - 1, 1) : ""; nx = (i < n) ? substr(s, i + 1, 1) : ""
    if ((c ~ /[A-Z]/ && p ~ /[a-z0-9]/) || (c ~ /[A-Z]/ && p ~ /[A-Z]/ && nx ~ /[a-z]/) || (c ~ /[0-9]/ && p ~ /[A-Za-z]/) || (c ~ /[A-Za-z]/ && p ~ /[0-9]/)) out = out " "
    out = out c
  }
  out = tolower(out); gsub(/[^a-z0-9]+/, " ", out)
  return trim(out)
}
function name_norm(s) { s = " " norm(s); while (s ~ /^ (it|test)( |$)/) sub(/^ (it|test)/, "", s); return trim(s) }
# Text compared loosely: quotes and backslashes dropped, whitespace collapsed.
function loose(s) { gsub(/\\[tn]/, " ", s); gsub(/["\047\\]/, "", s); gsub(/[ \t]+/, " ", s); return trim(s) }
function in_dir(p, d) { return d != "" && (p == d || index(p, d "/") == 1) }
function realp(p) { return (p in REAL) ? REAL[p] : p }
function in_project(p, cwd) {
  if (cwd == "") return 1
  return in_dir(p, cwd) || in_dir(p, CWDREAL[cwd]) || in_dir(realp(p), cwd) || in_dir(realp(p), CWDREAL[cwd])
}
function relpath(p, cwd,   d) {
  if (cwd != "" && in_dir(p, cwd)) return substr(p, length(cwd) + 2)
  d = CWDREAL[cwd]; if (d != "" && in_dir(p, d)) return substr(p, length(d) + 2)
  if (cwd != "" && in_dir(realp(p), cwd)) return substr(realp(p), length(cwd) + 2)
  if (d != "" && in_dir(realp(p), d)) return substr(realp(p), length(d) + 2)
  if (project_root != "" && in_dir(p, project_root)) return substr(p, length(project_root) + 2)
  return p
}
function is_test_file(p, cwd,   r, b) {
  r = relpath(p, cwd)
  if (r ~ /(^|\/)(tests?|specs?|__tests__)\//) return 1
  b = r; sub(/.*\//, "", b)
  if (b ~ /^.+Tests?\.[A-Za-z0-9]+$/) return 1
  if (b ~ /^.+Spec\.(rb|groovy|scala|kt|kts|swift)$/) return 1
  if (b ~ /^.+[._-](test|spec)\.[A-Za-z0-9]+$/) return 1
  if (b ~ /^test_.+\.py$/) return 1
  return 0
}
function is_task_dir(p) { return in_dir(p, task_dir_l) || in_dir(p, task_dir_r) || in_dir(realp(p), task_dir_r) }
function is_task_file(p) { return p == task_file || p == task_file_r || realp(p) == task_file_r }
# The other checkout of this repository that path p is in, or "". The worker
# own tree wins: its worktree may live inside the main checkout.
function other_checkout(p, cwd,   i) {
  if (nco == 0 || p == "" || in_project(p, cwd) || is_task_dir(p)) return ""
  for (i = 1; i <= nco; i++) if (in_dir(p, checkout[i]) || in_dir(realp(p), checkout[i])) return checkout[i]
  return ""
}
function ignored(p, cwd) {
  if (p == "") return 1
  if (p ~ /\.md$/) return 1
  if (is_task_dir(p)) return 1
  if (!in_project(p, cwd)) return 1
  return 0
}
# Splits a command into segments on ; & && || | and newlines, outside quotes.
function split_cmd(c, arr,   n, i, ch, q, cur, L) {
  n = 0; cur = ""; q = ""; L = length(c)
  for (i = 1; i <= L; i++) {
    ch = substr(c, i, 1)
    if (q != "") {
      cur = cur ch
      if (ch == "\\" && q == "\"") { i++; cur = cur substr(c, i, 1); continue }
      if (ch == q) q = ""
      continue
    }
    if (ch == "\"" || ch == "\047") { q = ch; cur = cur ch; continue }
    if (ch == "\\") { cur = cur ch substr(c, i + 1, 1); i++; continue }
    if (ch == "&" && (substr(c, i - 1, 1) == ">" || substr(c, i - 1, 1) == "<" || substr(c, i + 1, 1) == ">")) { cur = cur ch; continue }
    if (ch == "|" && substr(c, i - 1, 1) == ">") { cur = cur ch; continue }
    if (ch == ";" || ch == "|" || ch == "&" || ch == "\n") { arr[++n] = cur; cur = ""; continue }
    cur = cur ch
  }
  arr[++n] = cur
  return n
}
# Splits a segment into words on blanks, outside quotes (quotes kept).
function split_words(s, arr,   n, i, ch, q, cur, L) {
  n = 0; cur = ""; q = ""; L = length(s)
  for (i = 1; i <= L; i++) {
    ch = substr(s, i, 1)
    if (q != "") { cur = cur ch; if (ch == "\\" && q == "\"") { i++; cur = cur substr(s, i, 1) } else if (ch == q) q = ""; continue }
    if (ch == "\"" || ch == "\047") { q = ch; cur = cur ch; continue }
    if (ch == " " || ch == "\t") { if (cur != "") { arr[++n] = cur; cur = "" } continue }
    cur = cur ch
  }
  if (cur != "") arr[++n] = cur
  return n
}
function join_from(w, nw, k,   s, i) { s = ""; for (i = k; i <= nw; i++) s = s (i > k ? " " : "") w[i]; return s }
function prefix_at(w, nw, k, p,   s) { s = join_from(w, nw, k); return (index(s, p) == 1 && (length(s) == length(p) || substr(s, length(p) + 1, 1) == " ")) }
function nwords(p,   a) { return split(p, a, / +/) }
# Options of docker/podman (global, compose, exec/run) that take a value.
function skip_opts(w, nw, i) {
  while (i <= nw && w[i] ~ /^-/) {
    if (w[i] ~ /^(-e|--env|-u|--user|-w|--workdir|--env-file|--index|--name|-v|--volume|--entrypoint|-p|--publish|-l|--label|-f|--file|--project-name|--project-directory|--profile|-c|--context|-H|--host|--log-level|--network|--mount|--platform)$/) i += 2
    else i++
  }
  return i
}
# Index of the first argument after a test runner starting at word k, or 0.
function runner_at(w, nw, k,   b, n1, n2, j) {
  RKIND = ""
  for (j = 1; j <= nrunners; j++) if (prefix_at(w, nw, k, runner[j])) return k + nwords(runner[j])
  b = base(w[k]); n1 = (k + 1 <= nw) ? w[k + 1] : ""; n2 = (k + 2 <= nw) ? w[k + 2] : ""
  if (b ~ /^(pest|phpunit|paratest|jest|vitest|pytest|py\.test|rspec|mocha|ava|phpspec|codecept|karma|jasmine|tape|nosetests|unittest|ward|minitest|kaocha|busted|bats|testem)$/) return k + 1
  if (b == "go" && n1 == "test") return k + 2
  if (b == "cargo" && n1 == "test") { RKIND = "cargo"; return k + 2 }
  if (b == "cargo" && n1 == "nextest") { RKIND = "cargo"; return (n2 == "run") ? k + 3 : k + 2 }
  if (b ~ /^(npm|pnpm|yarn|bun)$/ && (n1 == "test" || n1 == "t")) return k + 2
  if (b ~ /^(npm|pnpm|yarn|bun)$/ && n1 == "run" && n2 ~ /^test/) return k + 3
  if (b ~ /^(yarn|pnpm)$/ && n1 ~ /^test[:-]/) return k + 2
  if (b ~ /^(deno|composer|mix|artisan|dotnet|mvn|gradle|gradlew|make|rails|rake|swift|zig|flutter|dart|lein|sbt|julia)$/ && n1 ~ /^test/) return k + 2
  if (b == "rake" && n1 == "spec") return k + 2
  if (b ~ /^(node|nodejs)$/ && n1 == "--test") return k + 2
  return 0
}
# Index of the word a segment executes once wrappers are peeled off, or 0.
# Stops at a test runner. Sets XARGS when an xargs wrapper fed it.
function cmd_index(w, nw,   k, b, g, i, j, hit) {
  k = 1; XARGS = 0
  for (g = 0; g < 40; g++) {
    while (k <= nw && w[k] ~ /^[({!]+$/) k++
    if (k > nw) return 0
    if (runner_at(w, nw, k)) return k
    hit = 0
    for (j = 1; j <= nwrappers; j++) if (prefix_at(w, nw, k, wrapper[j])) { k += nwords(wrapper[j]); while (k <= nw && w[k] ~ /^-/) k++; hit = 1; break }
    if (hit) continue
    if (w[k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { k++; continue }
    b = base(w[k])
    if (b == "env") { k++; while (k <= nw && (w[k] ~ /^-/ || w[k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) { if (w[k] ~ /^-(u|C|S)$/) k++; k++ } continue }
    if (b ~ /^(time|nice|nohup|command|exec|sudo|stdbuf|caffeinate|unbuffer)$/) { k++; while (k <= nw && w[k] ~ /^-/) { if (b != "time" && w[k] ~ /^-(n|u|g|o|e|i)$/) k++; k++ } continue }
    if (b == "timeout") { k++; while (k <= nw && w[k] ~ /^-/) { if (w[k] ~ /^-(s|k)$/) k++; k++ } k++; continue }
    if (b == "xargs") { XARGS = 1; k++; while (k <= nw && w[k] ~ /^-/) { if (w[k] ~ /^-[InPLsdEa]$/) k++; k++ } continue }
    if (b ~ /^(docker|podman|docker-compose|nerdctl)$/) {
      i = skip_opts(w, nw, k + 1)
      if (b != "docker-compose" && w[i] == "compose") i = skip_opts(w, nw, i + 1)
      if (w[i] != "exec" && w[i] != "run") return k
      i = skip_opts(w, nw, i + 1)
      k = i + 1
      continue
    }
    if (b ~ /^(npx|bunx|pnpx)$/) { k++; while (k <= nw && w[k] ~ /^-/) { if (w[k] ~ /^(-p|--package)$/) k++; k++ } continue }
    if (b ~ /^(npm|pnpm|yarn)$/ && w[k + 1] ~ /^(exec|dlx|x)$/) { k += 2; while (k <= nw && w[k] ~ /^-/) k++; continue }
    if (b ~ /^(uv|poetry|pipenv|pdm|hatch|rye)$/ && w[k + 1] == "run") { k += 2; while (k <= nw && w[k] ~ /^-/) k++; continue }
    if (b == "bundle" && w[k + 1] == "exec") { k += 2; continue }
    if (b ~ /^(php[0-9.]*|python[0-9.]*|ruby|node|nodejs|bun|deno|perl)$/) {
      k++
      while (k <= nw && w[k] ~ /^-/) {
        if (w[k] == "-m") { k++; break }
        if (w[k] ~ /^-(c|r|e|E)$/ && b !~ /^php/ || w[k] ~ /^-(r|B|R|E|F)$/ && b ~ /^php/) return 0
        if (w[k] ~ /^(-d|-c|-W|-X|-I|--require|-n|-z)$/) k++
        k++
      }
      continue
    }
    return k
  }
  return k
}
# The filter of a test run whose arguments start at word a, or "".
function run_filter(w, nw, a,   i, v) {
  for (i = a; i <= nw; i++) {
    if (w[i] ~ /^(--filter|--testNamePattern|--test-name-pattern|-t|-k|-run|--run|-e|--example|--grep|-g|--match|--tests)$/ && i < nw) return unquote(w[i + 1])
    if (w[i] ~ /^(--filter|--testNamePattern|--test-name-pattern|-t|-k|-run|--run|--example|--grep|--match|--tests)=/) { v = w[i]; sub(/^[^=]*=/, "", v); return unquote(v) }
  }
  for (i = a; i <= nw; i++) if (w[i] !~ /^-/ && w[i] ~ /::/) { v = unquote(w[i]); sub(/.*::/, "", v); return v }
  if (RKIND == "cargo") for (i = a; i <= nw; i++) if (w[i] !~ /^-/ && w[i] !~ /^[0-9>&]/) return unquote(w[i])
  return ""
}
# Is segment s a test run? Sets RUN_FILTER. A shell -c "..." is looked into once.
function seg_run(s,   w, nw, k, a, j, inner, ni, ii, w2, n2, k2) {
  RUN_FILTER = ""
  nw = split_words(s, w); if (nw == 0) return 0
  k = cmd_index(w, nw); if (k == 0) return 0
  a = runner_at(w, nw, k)
  if (a) { RUN_FILTER = run_filter(w, nw, a); return 1 }
  if (base(w[k]) ~ /^(ba|z|da|k)?sh$/) {
    for (j = k + 1; j <= nw && w[j] ~ /^-/; j++) if (w[j] ~ /^-[A-Za-z]*c[A-Za-z]*$/) {
      ni = split_cmd(unquote(w[j + 1]), inner)
      for (ii = 1; ii <= ni; ii++) {
        n2 = split_words(inner[ii], w2); if (n2 == 0) continue
        k2 = cmd_index(w2, n2); if (k2 == 0) continue
        a = runner_at(w2, n2, k2)
        if (a) { RUN_FILTER = run_filter(w2, n2, a); return 1 }
      }
      return 0
    }
  }
  return 0
}
# The filter of the last test-run segment of command c ("" when unfiltered).
function test_run(c,   n, k, segs, found, f) {
  n = split_cmd(c, segs); found = 0; f = ""
  for (k = 1; k <= n; k++) if (seg_run(segs[k])) { found = 1; f = RUN_FILTER }
  RUN_FILTER = f
  return found
}
function resolve(p, dir) {
  p = unquote(p)
  if (p ~ /^\//) return p
  if (p ~ /^~\//) return p
  sub(/^\.\//, "", p)
  return dir "/" p
}
function add_write(p) { wrote[++NW] = p }
# A code formatter run. It rewrites layout, not behaviour, so formatting files
# named on the command line is allowed; a run without a literal file list
# (none, a directory, or a $(...) substitution) can rewrite the whole project.
function formatter_kind(w, nw, k,   b, n1, s) {
  b = base(w[k]); n1 = w[k + 1]; s = " " join_from(w, nw, k + 1) " "
  if (s ~ / (--check|--test|--dry-run|--diff|--list-different|-l|--verify) /) return 0
  if (b == "php-cs-fixer" && n1 == "fix") return 1
  if (b ~ /^(phpcbf|pint|black|rustfmt|stylua|swiftformat|autopep8|isort|standardrb)$/) return 1
  if (b == "prettier" && s ~ / (--write|-w) /) return 1
  if (b ~ /^(eslint|rubocop|ktlint)$/ && s ~ / (--fix|-a|-A|--autocorrect|-F|--format) /) return 1
  if (b == "rector" && n1 == "process") return 1
  if (b == "ruff" && (n1 == "format" || s ~ / --fix /)) return 1
  if (b ~ /^(gofmt|goimports|clang-format)$/ && s ~ / (-w|-i) /) return 1
  if (b ~ /^(cargo|go)$/ && n1 == "fmt") return 1
  if (b == "dotnet" && n1 == "format") return 1
  if (b == "biome" && s ~ / (--write|--apply) /) return 1
  return 0
}
function formatter_explicit(s, w, nw, k,   i, n) {
  if (s ~ /\$\(|`|\$/) return 0
  n = 0
  for (i = k + 1; i <= nw; i++) if (w[i] ~ /\.[A-Za-z0-9]+$/ && w[i] !~ /^-/) n++
  return n > 0
}
function has_write_words(t) {
  return (t ~ /(^|[^0-9&>=-])>>?[ \t]*[^ \t&>]/ || t ~ /(^|[ \t;&|(])(tee|touch|cp|mv|ln|install|rsync|dd|truncate|patch)[ \t]/ || t ~ /(sed|perl)[ \t]+(-[^ \t]+[ \t]+)*-i/ || t ~ /git[ \t]+(apply|checkout|restore|stash|reset|clean|switch)/)
}
# Non-option words after index k, with redirections (and their targets) removed.
function plain_args(w, nw, k, out,   i, n) {
  n = 0
  for (i = k + 1; i <= nw; i++) {
    if (w[i] ~ /^[0-9]*[<>]+&?$/) { i++; continue }
    if (w[i] ~ /^[0-9]*[<>]/ || w[i] ~ /^[0-9]*>&/) continue
    if (w[i] ~ /^-/) continue
    out[++n] = w[i]
  }
  return n
}
# Writes of one segment, appended to wrote[]. depth 1 = inside sh -c/eval.
function seg_writes(raw, dir, depth, full,   s, m, w, nw, k, b, a, na, i, j, g, gdir, sub_, inner, ni, opts, dd, kk) {
  # Redirects, read with quoted text blanked ("a -> b" is not a redirect).
  s = raw; gsub(/"[^"]*"/, "\"\"", s); gsub(/\047[^\047]*\047/, "\047\047", s)
  while (match(s, /(^|[^0-9&>=-])>>?[ \t]*[^ \t&>|]+/)) {
    m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    sub(/^[^>]*>>?[ \t]*/, "", m)
    if (m !~ /^\/dev\/(null|stdout|stderr|tty)$/ && m !~ /^&/ && m != "" && m != "\"\"" && m != "\047\047") add_write(resolve(m, dir))
  }
  nw = split_words(raw, w); if (nw == 0) return
  k = cmd_index(w, nw); if (k == 0) return
  if (runner_at(w, nw, k)) return
  b = base(w[k])
  for (j = 1; j <= ngenerators; j++) if (prefix_at(w, nw, 1, generator[j]) || prefix_at(w, nw, k, generator[j])) { add_write(dir "/*"); return }
  if (formatter_kind(w, nw, k)) { if (!formatter_explicit(raw, w, nw, k)) add_write("FORMAT-ALL"); return }
  if ((b == "artisan" || b == "console") && w[k + 1] ~ /^make:/) { add_write(dir "/*"); return }
  if (b == "rails" && w[k + 1] ~ /^(generate|g|destroy|d|new)$/) { add_write(dir "/*"); return }
  if (b ~ /^(django-admin|manage\.py)$/ && w[k + 1] ~ /^start(app|project)$/) { add_write(dir "/*"); return }
  if (b ~ /^(ng|nest)$/ && w[k + 1] ~ /^(generate|g|new)$/) { add_write(dir "/*"); return }
  if (b == "eval" || b ~ /^(ba|z|da|k)?sh$/) {
    inner = ""
    if (b == "eval") { for (i = k + 1; i <= nw; i++) inner = inner " " unquote(w[i]) }
    else {
      for (j = k + 1; j <= nw && w[j] ~ /^-/; j++) if (w[j] ~ /^-[A-Za-z]*c[A-Za-z]*$/) { inner = unquote(w[j + 1]); break }
      # A shell reading a script from stdin (cmd | sh): judge the whole command.
      if (inner == "" && (j > nw || w[j] ~ /^[0-9]*[<>]/)) { if (has_write_words(full)) add_write(dir "/*"); return }
    }
    if (inner == "") return
    if (depth > 0) { if (has_write_words(inner)) add_write(dir "/*"); return }
    ni = split_cmd(inner, nested)
    for (i = 1; i <= ni; i++) nestedc[i] = nested[i]
    for (i = 1; i <= ni; i++) {
      if (match(nestedc[i], /^[ \t]*cd[ \t]+[^ \t]+/)) { m = substr(nestedc[i], RSTART, RLENGTH); sub(/^[ \t]*cd[ \t]+/, "", m); dir = resolve(m, dir); continue }
      seg_writes(nestedc[i], dir, 1, inner)
    }
    return
  }
  if (b == "tee") { na = plain_args(w, nw, k, a); for (i = 1; i <= na; i++) add_write(resolve(a[i], dir)); return }
  if (b ~ /^(sed|perl)$/) {
    for (i = k + 1; i <= nw; i++) if (w[i] ~ /^-[A-Za-z]*i/ || w[i] ~ /^--in-place/) { na = plain_args(w, nw, k, a); if (na > 0) add_write(resolve(a[na], dir)); break }
    return
  }
  if (b ~ /^(cp|mv|ln|install|rsync|gcp|gmv)$/) {
    na = plain_args(w, nw, k, a)
    if (na > 0) add_write(resolve(a[na], dir)); else if (XARGS) add_write(dir "/*")
    return
  }
  if (b ~ /^(touch|truncate)$/) {
    na = 0
    for (i = k + 1; i <= nw; i++) {
      if (w[i] ~ /^-(s|r|d|t)$/ || w[i] ~ /^--(size|reference|date)$/) { i++; continue }
      if (w[i] ~ /^-/ || w[i] ~ /^[0-9]*[<>]/) continue
      add_write(resolve(w[i], dir)); na++
    }
    if (na == 0 && XARGS) add_write(dir "/*")
    return
  }
  if (b == "dd") { for (i = k + 1; i <= nw; i++) if (w[i] ~ /^of=/) { dd = w[i]; sub(/^of=/, "", dd); add_write(resolve(dd, dir)) } return }
  if (b == "patch") {
    if ((" " join_from(w, nw, k + 1) " ") ~ / (--dry-run|-C|--check) /) return
    for (i = k + 1; i < nw; i++) if (w[i] == "-o" || w[i] == "--output") { add_write(resolve(w[i + 1], dir)); return }
    add_write(dir "/*"); return
  }
  if (b == "git") {
    gdir = dir; i = k + 1
    while (i <= nw && w[i] ~ /^-/) { if (w[i] == "-C") { gdir = resolve(w[i + 1], dir); i += 2 } else if (w[i] == "-c") i += 2; else i++ }
    sub_ = w[i]; opts = " " join_from(w, nw, i + 1) " "
    if (sub_ == "apply") { if (opts ~ / --(check|stat|numstat|summary) / && opts !~ / --apply /) return; add_write(gdir "/*"); return }
    if (sub_ == "checkout" || sub_ == "restore") {
      g = 0
      for (j = i + 1; j <= nw; j++) if (w[j] == "--") { for (kk = j + 1; kk <= nw; kk++) if (w[kk] !~ /^[0-9]*[<>]/) { add_write(resolve(w[kk], gdir)); g++ } break }
      if (g > 0) return
      if (sub_ == "restore") {
        for (j = i + 1; j <= nw; j++) { if (w[j] ~ /^(-s|--source)$/) { j++; continue } if (w[j] ~ /^-/ || w[j] ~ /^[0-9]*[<>]/) continue; add_write(resolve(w[j], gdir)); g++ }
        if (g == 0) add_write(gdir "/*")
        return
      }
      if (i < nw) add_write(gdir "/*")
      return
    }
    if (sub_ ~ /^(switch|merge|rebase|cherry-pick|revert|pull|am)$/) { add_write(gdir "/*"); return }
    if (sub_ == "stash" && w[i + 1] !~ /^(list|show)$/) { add_write(gdir "/*"); return }
    if (sub_ == "reset" && opts ~ / --(hard|merge|keep) /) { add_write(gdir "/*"); return }
    if (sub_ == "clean" && opts ~ / (-[A-Za-z]*f[A-Za-z]*|--force) / && opts !~ / (-n|--dry-run) /) { add_write(gdir "/*"); return }
    return
  }
}
# Shell variables a command assigns for itself, so a write through one
# ("S=/tmp/x; cat > $S/notes") is judged by where it points. Shell state never
# survives between Bash calls, so a variable is either assigned earlier in the
# same command or comes from the environment; HOME is taken from it and PWD is
# the directory the call ran in. Anything else stays unexpanded, so a write through it
# is still reported (over-report rather than miss).
function expand_vars(s, dir,   out, m, name) {
  out = ""
  while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*/)) {
    m = substr(s, RSTART, RLENGTH)
    name = m; gsub(/^\$\{?|\}$/, "", name)
    out = out substr(s, 1, RSTART - 1)
    if (name in SHV) out = out SHV[name]
    else if (name == "PWD") out = out dir
    else if (name == "HOME" && ENVIRON["HOME"] != "") out = out ENVIRON["HOME"]
    else out = out m
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}
# A segment that only assigns variables (optionally after export) records them
# in SHV and returns 1. "VAR=x cmd" sets VAR for cmd alone and records nothing.
function set_vars(seg,   t, w, nw, i, k, name, val) {
  t = seg; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
  if (t == "") return 0
  nw = split_words(t, w); if (nw == 0) return 0
  i = 1; if (w[1] == "export") i = 2
  if (i > nw) return 0
  for (k = i; k <= nw; k++) if (w[k] !~ /^[A-Za-z_][A-Za-z0-9_]*=/) return 0
  for (k = i; k <= nw; k++) {
    name = w[k]; sub(/=.*/, "", name)
    val = w[k]; sub(/^[^=]*=/, "", val)
    SHV[name] = unquote(val)
  }
  return 1
}
# Files a Bash command writes, as absolute paths in wrote[1..NW] (or
# "<dir>/*" when it may write anywhere under dir, or FORMAT-ALL). Best
# effort, not a parser: it over-reports rather than miss a write.
function bash_writes(c, cwd, scripts, shellbody,   n, i, dir, sdir, m, sp, ns, segs) {
  NW = 0; dir = cwd; sdir = ""
  split("", SHV)
  n = split_cmd(c, segs)
  for (i = 1; i <= n; i++) {
    segs[i] = expand_vars(segs[i], dir)
    if (set_vars(segs[i])) continue
    # A script resolves its relative paths against the directory it ran in.
    if (sdir == "" && segs[i] ~ /(^|[^A-Za-z])(python3?|php|node|ruby|perl)([^A-Za-z]|$)/) sdir = dir
    if (match(segs[i], /^[ \t]*cd[ \t]+[^ \t]+/)) { m = substr(segs[i], RSTART, RLENGTH); sub(/^[ \t]*cd[ \t]+/, "", m); dir = resolve(m, dir); continue }
    seg_writes(segs[i], dir, 0, c)
  }
  if (scripts != "") {
    ns = split(scripts, sp, / /)
    if (sdir == "") sdir = dir
    for (i = 1; i <= ns; i++) if (sp[i] != "") add_write(resolve(sp[i], sdir))
  }
  if (shellbody == "1") add_write(cwd "/*")
  return NW
}
# Index of the requirement a filter names, or 0. An exact name wins; otherwise
# a filter that fits several requirements names none of them.
function match_req(f,   i, nf, hit, n) {
  if (f == "") return 0
  sub(/.*::/, "", f)
  nf = name_norm(f)
  if (nf == "") return 0
  for (i = 1; i <= nreq; i++) if (reqn[i] == nf) return i
  n = 0; hit = 0
  for (i = 1; i <= nreq; i++) if (index(reqn[i], nf) > 0) { n++; hit = i }
  return (n == 1) ? hit : 0
}
# Failure lines in the output of call id that the command did not print itself.
function real_fails(id,   n, ls, i, c, lc_) {
  lc_ = loose(rawcmd[id]); c = 0
  n = split(fails[id] "\036" loads[id], ls, "\036")
  for (i = 1; i <= n; i++) if (ls[i] != "" && !(length(loose(ls[i])) >= 6 && index(lc_, loose(ls[i])) > 0)) c++
  return c
}
# A successful Edit/Write/MultiEdit/NotebookEdit, in transcript order.
function file_edit(id,   p, nn, wn, k, n) {
  p = path[id]
  if (other_checkout(p, cwdof[id]) != "") { violation("R6 file in another checkout of this repository changed (work only in " cwdof[id] "): " p); return }
  if (ignored(p, cwdof[id])) return
  touched[p] = 1
  if (is_test_file(p, cwdof[id])) {
    nn = split(wnames[id], wn, ",")
    for (k = 1; k <= nn; k++) if (wn[k] != "") written[wn[k] + 0] = 1
    n = added[id]
    if (n ~ /^W/) { n = substr(n, 2) - (p in seen_tests ? seen_tests[p] : base_tests[p]); }
    if (added[id] ~ /^W/) seen_tests[p] = substr(added[id], 2)
    if (n > 0) { flush_cuts(); new_since_red += n; armed = 0 }
    return
  }
  # Cut-back: removal-only edits answering a first-run pass wait for a
  # failing run of that requirement (see the header), judged from the
  # transcript alone so the verifier agrees with what the guard allowed live.
  if (!armed && pending > 0 && rem[id] == "R") {
    if (cut_req != pending) flush_cuts()
    cut_req = pending; cut_path[++ncut] = p
    return
  }
  flush_cuts()
  if (!armed) violation("R2 production file edited with no failing test armed: " p)
}
function is_file_tool(t) { return (t == "Edit" || t == "MultiEdit" || t == "Write" || t == "NotebookEdit") }
function violation(msg) { nviol++; viol[nviol] = msg }
# Cut-back edits that never reached a failing run for their requirement.
function flush_cuts(   k) {
  for (k = 1; k <= ncut; k++) violation("R2 cut-back for `" req[cut_req] "` was never followed by a failing run naming it: " cut_path[k])
  ncut = 0; cut_req = 0
}
# A PASSED-FIRST line for requirement i, matched on its exact name: 2 with a
# "no-code:" reason (the only accepted justification), 1 without, 0 when none.
function noted(i,   j, best) {
  best = 0
  for (j = 1; j <= njust; j++) if (just_name[j] == reqn[i]) {
    if (just_nocode[j]) return 2
    best = 1
  }
  return best
}
function is_justified(i) { return noted(i) == 2 }
BEGIN {
  nreq = 0
  while ((getline line < (tmp "/reqs")) > 0) if (line != "") req[++nreq] = line
  i = 0; while ((getline line < (tmp "/reqnorm")) > 0) reqn[++i] = line
  while ((getline line < (tmp "/guards")) > 0) if (line != "") is_guard[line] = 1
  nrunners = 0; while ((getline line < (tmp "/runners")) > 0) if (line != "") runner[++nrunners] = line
  nwrappers = 0; while ((getline line < (tmp "/wrappers")) > 0) if (line != "") wrapper[++nwrappers] = line
  ngenerators = 0; while ((getline line < (tmp "/generators")) > 0) if (line != "") generator[++ngenerators] = line
  nco = 0; while ((getline line < (tmp "/checkouts")) > 0) if (line != "") checkout[++nco] = line
  armed = 0; new_since_red = 0; nviol = 0; nwarn = 0; ncut = 0; cut_req = 0; njust = 0
  while ((getline line < task_file) > 0) {
    if ((p = index(line, "PASSED-FIRST:")) == 0) continue
    t = substr(line, p + 13)
    nc = index(lc(t), "no-code:") > 0
    # The name runs up to the reason: " — ", " – ", " -- ", " - " or "no-code:".
    cut = length(t) + 1
    if ((q = index(t, " \342\200\224 ")) > 0 && q < cut) cut = q
    if ((q = index(t, " \342\200\223 ")) > 0 && q < cut) cut = q
    if ((q = index(t, " -- ")) > 0 && q < cut) cut = q
    if ((q = index(t, " - ")) > 0 && q < cut) cut = q
    if ((q = index(lc(t), "no-code:")) > 0 && q < cut) cut = q
    nm = substr(t, 1, cut - 1); gsub(/`/, "", nm)
    njust++; just_name[njust] = name_norm(nm); just_nocode[njust] = nc
  }
}
$1 == "BASE" { base_tests[$2] = $3; next }
$1 == "REAL" { REAL[$2] = $3; next }
$1 == "CWD" { CWDREAL[$2] = $3; next }
$1 == "USE" {
  if (!($2 in tool)) useorder[++nuse] = $2
  tool[$2] = $3; path[$2] = untsv($4); added[$2] = $5; cmd[$2] = untsv($6); cwdof[$2] = untsv($7); scr[$2] = $8; wnames[$2] = $9; rem[$2] = $10; sbody[$2] = $11; rawcmd[$2] = untsv($12)
  next
}
$1 == "RES" {
  id = $2; err = ($3 == "1"); infra = ($4 == "1"); fails[id] = untsv($6); loads[id] = untsv($7); blocked = ($8 == "1"); resolved[id] = 1
  t = tool[id]
  # A Bash write counts whether or not the command errored: only a call the
  # guard refused never ran.
  if (t == "Bash" && !blocked) {
    nw = bash_writes(cmd[id], cwdof[id], scr[id], sbody[id])
    for (k = 1; k <= nw; k++) {
      p = wrote[k]
      # Formatting is layout, not behaviour: the guard refuses bare formatter
      # runs live, and the verifier does not judge them.
      if (p == "FORMAT-ALL") continue
      if (other_checkout(p, cwdof[id]) != "") { violation("R6 file in another checkout of this repository changed from Bash (work only in " cwdof[id] "): " p); continue }
      if (ignored(p, cwdof[id])) continue
      if (p !~ /\/\*$/) touched[p] = 1
      violation("R4 project file changed from Bash (only Edit/Write may change files): " p)
    }
  }
  if (t == "Bash" && test_run(cmd[id])) {
    nruns++
    f = RUN_FILTER
    r = match_req(f)
    # A run only speaks for a requirement whose test this worker has written;
    # before that, the filter can only match some other, older test.
    if (r > 0 && !written[r]) r = 0
    # Any run filtered to a requirement means the tests written so far were run;
    # more than one new test before it is batch-writing, pass or fail.
    if (r > 0) {
      if (new_since_red > 1) violation("R3 " new_since_red " new tests were written before the run for `" req[r] "` (batch-writing)")
      new_since_red = 0
      ran[r] = 1
    }
    failed = (r > 0 && !infra && real_fails(id) > 0)
    # A pass needs positive evidence: empty or filtered-away output proves nothing.
    passed = (!err && !infra && real_fails(id) == 0 && $5 == "1")
    if (failed) { red[r] = 1; armed = 1; if (pending == r) pending = 0; if (cut_req == r) { ncut = 0; cut_req = 0 } }
    # A filtered run that passes for a requirement that never failed leaves an
    # open question: make the test fail, or record why it already passes.
    if (r > 0 && passed && !red[r] && !(req[r] in is_guard)) pending = r
    next
  }
  if (is_file_tool(t) && !err) file_edit(id)
  next
}
END {
  if (mode == "state") { print (armed ? "ARMED" : "DISARMED"); exit 0 }
  if (mode == "gate") {
    gt = ENVIRON["HCF_GATE_TOOL"]; gcwd = ENVIRON["HCF_GATE_CWD"]
    # Earlier file edits whose result is not on disk yet count as done (see
    # the header). The call being judged is skipped: by its id, or, with no
    # id, as the last unresolved edit when it has the same tool and path.
    gid = ENVIRON["HCF_GATE_ID"]; lastu = 0
    for (u = 1; u <= nuse; u++) if (!(useorder[u] in resolved) && is_file_tool(tool[useorder[u]])) lastu = u
    for (u = 1; u <= nuse; u++) {
      id = useorder[u]
      if ((id in resolved) || !is_file_tool(tool[id])) continue
      if (gid != "" && id == gid) continue
      if (gid == "" && u == lastu && tool[id] == gt && path[id] == ENVIRON["HCF_GATE_PATH"]) continue
      file_edit(id)
    }
    if (gt == "Bash") {
      nw = bash_writes(gate_cmd, gcwd, gate_scripts, gate_shellbody)
    } else { nw = 1; wrote[1] = ENVIRON["HCF_GATE_PATH"] }
    gadd = ENVIRON["HCF_GATE_ADDED"] + 0
    # Only an Edit or MultiEdit can be a removal-only cut-back.
    grem = (ENVIRON["HCF_GATE_REMOVAL"] == "yes" && (gt == "Edit" || gt == "MultiEdit"))
    open_q = (pending > 0 && !is_justified(pending)) ? pending : 0
    for (k = 1; k <= nw; k++) {
      p = wrote[k]
      if (p == "FORMAT-ALL") { print "DENY-FORMAT " gcwd; exit 0 }
      # The task file is ignored as production, but ticking it from Bash hides
      # when each requirement was marked done: Edit only, like any project file.
      if (gt == "Bash" && is_task_file(p)) { print "DENY-BASH " p; exit 0 }
      if (other_checkout(p, gcwd) != "") { print "DENY-CHECKOUT " p; exit 0 }
      if (ignored(p, gcwd)) continue
      if (gt == "Bash") { print "DENY-BASH " p; exit 0 }
      if (is_test_file(p, gcwd)) {
        # One new test at a time: run the last one before writing the next.
        if (gadd > 1 || (gadd > 0 && new_since_red > 0)) { print "DENY-BATCH " p; exit 0 }
        if (gadd > 0 && open_q) { print "DENY-PASSFIRST " req[open_q]; exit 0 }
        continue
      }
      if (open_q) {
        # A removal-only edit cuts over-built code back until the test fails.
        if (grem) continue
        print "DENY-PASSFIRST " req[open_q]; exit 0
      }
      if (!armed) { print "DENY " p; exit 0 }
    }
    print "ALLOW"; exit 0
  }
  if (mode == "touched") { for (p in touched) print p; exit 0 }
  flush_cuts()
  if (req_change != "") violation(req_change)
  # Nothing recognised as a test run at all: say how to fix it, not just R1.
  if (nreq > 0 && nruns == 0) violation("R0 no test run was recognised in this transcript. If the project uses a runner HCF does not know, add its command to \"testRunners\" (or a wrapper that runs it to \"commandWrappers\") in .claude/hcf.json")
  for (i = 1; i <= nreq; i++) {
    if (red[i]) continue
    # A guard may pass on its first run, but it must still have been run alone.
    if (req[i] in is_guard) {
      if (!ran[i]) violation("R1 guard `" req[i] "` was never run on its own (filtered to it)")
      continue
    }
    # An unstarted requirement means an unfinished task, not a broken method.
    if (!written[i]) { violation("R1 `" req[i] "` not attempted (no test written)"); continue }
    if (noted(i) == 2) { nwarn++; warn[nwarn] = "W1 `" req[i] "` never failed; PASSED-FIRST says no-code — confirm no production code delivers it (deleting code would make its test fail)"; continue }
    if (noted(i) == 1) { violation("R1 `" req[i] "` passed on its first run and was not cut back: its PASSED-FIRST line has no no-code: reason, so production code delivers it. Delete that code with removal-only Edits until the test fails, then rebuild it"); continue }
    violation("R1 `" req[i] "` never had a failing test run naming it (a red run is the runner itself, filtered to it, with output showing a test failure)")
  }
  for (i = 1; i <= nviol; i++) print "VIOLATION " viol[i]
  for (i = 1; i <= nwarn; i++) print "WARNING " warn[i]
  if (nviol > 0) { printf "verify-tdd: FAILED (%d violation(s), %d warning(s))\n", nviol, nwarn; exit 1 }
  if (nwarn > 0) { printf "verify-tdd: REVIEW (%d warning(s))\n", nwarn; exit 2 }
  printf "verify-tdd: OK (%d requirement(s) verified)\n", nreq
  exit 0
}
' < <(
  # Prepend HEAD baselines for every test file written with Write, so the awk
  # pass can subtract tests the file already had; and the symlink-resolved
  # form of every edited path and cwd, so a path reached through a symlink is
  # still recognised as the project's or the plan's.
  printf '%s\n' "$events" | awk -F'\t' '$1 == "USE" && $3 == "Write" { print $4 }' | sort -u | while IFS= read -r p; do
    [ -n "$p" ] && printf 'BASE\t%s\t%s\n' "$p" "$(baseline_tests "$p")"
  done
  { printf '%s\n' "$events" | awk -F'\t' '$1 == "USE" && $4 != "" { print $4 }'
    [ -n "${HCF_GATE_PATH:-}" ] && printf '%s\n' "$HCF_GATE_PATH"; } | sort -u | while IFS= read -r p; do
    r="$(real_of "$p")"; [ -n "$r" ] && printf 'REAL\t%s\t%s\n' "$p" "$r"
  done
  { printf '%s\n' "$events" | awk -F'\t' '$1 == "USE" && $7 != "" { print $7 }'
    [ -n "${HCF_GATE_CWD:-}" ] && printf '%s\n' "$HCF_GATE_CWD"; } | sort -u | while IFS= read -r c; do
    r="$(real_dir "$c")"; [ -n "$r" ] && [ "$r" != "$c" ] && printf 'CWD\t%s\t%s\n' "$c" "$r"
  done
  printf '%s\n' "$events"
)
