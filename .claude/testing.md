# Testing Configuration

## Test Framework

A home-grown bash harness: `tests/run-tests.sh` sources every `tests/test-*.sh`
suite into one process, and the assertions in `tests/lib.sh` (`assert_eq`,
`assert_exit`, `assert_contains`, `assert_not_contains`, `assert_empty`) count
and print each check. No dependencies beyond bash 3.2, jq, awk, sed, grep, sort.

**A test is one assertion; its name is the assertion's description** (the first
argument). A plan requirement such as `it warns about a production edit before
red` is satisfied by an assertion whose description is exactly that text:

```bash
assert_contains "it warns about a production edit before red" "$out" '"additionalContext"'
```

## TDD Methodology

Each task follows strict Red → Green → Refactor, one requirement at a time:

1. Write ONE assertion for the next requirement, described with the
   requirement's exact name.
2. Run it alone with the filtered RED command below and see it FAIL (the
   output shows `✗ <name>` and `1 failed`).
3. Write the minimum change in `hooks/` (or elsewhere) to make it pass; run it
   filtered again and see it pass.
4. Refactor while the suite stays green.
5. Repeat for the next requirement.

HCF's TDD verifier reads the worker's transcript and accepts a run as RED only
when the runner is the executed command, `--filter` names the requirement, and
the output shows the failure. Keep at least the summary line (`1 failed`) if
you trim the output with `tail`.

## Commands

```bash
# Run all tests (there is no parallel runner; this is the full suite, ~1 min)
./tests/run-tests.sh

# Run one suite (file name with or without .sh)
./tests/run-tests.sh test-verify-tdd

# Run one test (RED / GREEN): only assertions whose description contains the
# filter (any case) run and count; nothing matching prints "No tests found"
./tests/run-tests.sh test-verify-tdd --filter "it warns about a production edit before red"

# Lint shell
shellcheck -S warning hooks/*.sh tests/*.sh
```

## Parallel Execution

- Not supported: suites share counters in one process. Always use
  `./tests/run-tests.sh` (optionally one suite and `--filter`).

## Test File Locations

- Suites: `tests/test-<area>.sh`, auto-discovered by the runner.
- Helpers and assertions: `tests/lib.sh`.
- Fixture agent files: `tests/fixtures/`.
- Scratch: `tests/.tmp/` (cleared by the runner) or `mktemp -d` under
  `${TMPDIR:-/tmp}`. Never write into the repo outside those.

## Coverage Requirements

- No coverage tool. Every change to shell behaviour needs an assertion in a
  `tests/test-*.sh` suite.

## Test Naming Convention

- Suite files: `tests/test-<area>.sh`.
- Assertion descriptions start with `it` and state one behaviour:
  `it refuses a commit`, `it allows a test edit while disarmed`.
- Descriptions are unique across the suite, so a `--filter` of the full name
  runs exactly one assertion.

## Hook tests: how they are built

- `tests/test-verify-tdd.sh` builds transcripts from the two record shapes
  Claude Code writes (`tx_use` = assistant tool_use, `tx_res` = user
  tool_result) and runs `hooks/verify-tdd.sh` on them (`verify`), its `--gate`
  mode (`gate`, `gate_cmd`), and the PreToolUse hook end to end by piping a hook
  input JSON into `hooks/tdd-guard.sh` (`$GD`), with `mk_worker` adding a worker
  prompt to a transcript.
- Projects live under `mktemp -d`; no real repo or plan is touched.
