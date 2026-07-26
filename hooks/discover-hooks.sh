#!/usr/bin/env bash
# HCF hook discovery — deterministic enumeration of hook-enrolled agents.
#
# Why this exists: HCF's discovery routine used to be prose instructions that
# the in-session model executed by improvising a bash glob loop. Different
# sessions wrote different scripts, and a syntax error in one of them crashed
# mid-enumeration; the partial output was consumed as complete, every hook
# resolved empty, and the empty-hook silence rule made the failure invisible.
# See https://github.com/markshust/hcf/issues/4.
#
# This script is the single implementation of HOOKS.md's Discovery Routine.
# Callers run it and read its output; nobody enumerates agent files by hand.
#
# Usage:
#   discover-hooks.sh                     # all 8 hooks (by-hand debugging view)
#   discover-hooks.sh --hook=<name>       # one hook; empty prints nothing
#   discover-hooks.sh --json              # machine-readable
#   discover-hooks.sh --fingerprint       # stable enrollment digest
#   discover-hooks.sh --expect=<value>    # halt if enrollment drifted
#
# Exit codes:
#   0  success (including a legitimately empty hook)
#   1  runtime error (plugin agents/ dir unresolvable)
#   2  bad arguments (incl. a malformed --expect value)
#   3  enrollment validation failure (invalid phase or mode in an agent file)
#   4  enrollment drift (--expect mismatch)

set -o pipefail

PROG="discover-hooks"
VALID_HOOKS="pre-plan post-plan pre-implementation pre-batch post-batch post-implementation pre-commit post-commit"
VALID_MODES="single batch"
FP_PREFIX="discover-hooks-fingerprint"
FP_VERSION="1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_AGENTS="$SCRIPT_DIR/../agents"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
LOCAL_AGENTS="$PROJECT_DIR/.claude/agents"

HOOK_FILTER=""
WANT_JSON=""
WANT_FINGERPRINT=""
EXPECT=""
HAVE_EXPECT=""

warn() { printf '%s: warning: %s\n' "$PROG" "$1" >&2; }
err()  { printf '%s: error: %s\n'   "$PROG" "$1" >&2; }

usage() {
  cat <<'EOF'
discover-hooks.sh — resolve which agents run at an HCF hook point.

  --hook=<name>     Restrict output to one hook. Prints nothing when the hook
                    resolves empty (callers treat exit 0 + empty stdout as
                    "empty hook"). Omit to print all 8 hooks with explicit
                    empty markers, which is the by-hand debugging view.
  --json            Emit JSON instead of the human table.
  --fingerprint     Print a stable digest of the full resolved enrollment
                    across all 8 hooks, then exit.
  --expect=<value>  Compare current enrollment against a previously captured
                    fingerprint. Exits 4 if it changed. Accepts either the
                    full versioned line or the bare 64-hex digest.
  -h, --help        Show this help.

Exit codes: 0 success, 1 runtime error, 2 bad arguments,
            3 enrollment validation failure, 4 enrollment drift.
EOF
}

is_valid_hook() {
  case " $VALID_HOOKS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

is_valid_mode() {
  case " $VALID_MODES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hook=*)
      HOOK_FILTER="${1#*=}"
      if [ -z "$HOOK_FILTER" ]; then
        err "--hook requires a value; use --hook=<name>"
        exit 2
      fi
      if ! is_valid_hook "$HOOK_FILTER"; then
        err "unknown hook '$HOOK_FILTER'"
        err "  valid hooks: $VALID_HOOKS"
        exit 2
      fi
      ;;
    --hook)
      err "--hook must be given as --hook=<name>, not as two arguments"
      exit 2
      ;;
    --expect=*)
      EXPECT="${1#*=}"
      HAVE_EXPECT=1
      ;;
    --expect)
      err "--expect must be given as --expect=<value>, not as two arguments"
      exit 2
      ;;
    --json)        WANT_JSON=1 ;;
    --fingerprint) WANT_FINGERPRINT=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)
      err "unknown argument '$1'"
      err "  run with --help for usage"
      exit 2
      ;;
  esac
  shift
done

if [ -n "$WANT_FINGERPRINT" ] && [ -n "$HAVE_EXPECT" ]; then
  err "--fingerprint and --expect are mutually exclusive"
  exit 2
fi

# --- frontmatter parsing ----------------------------------------------------
#
# Anchored at start-of-line inside the FIRST `---` block only, so a commented
# `# phase:` key never enrolls an agent. This matters concretely: the bundled
# standards-enforcer ships dormant with its phase commented out, and an
# unanchored match would silently enable it for every HCF user.

has_frontmatter() {
  # NOTE: awk's `exit` runs the END block, so the result is carried in a flag
  # rather than as an exit status from inside the body.
  LC_ALL=C awk '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") { bad = 1; exit } ; next }
    /^---$/ { found = 1; exit }
    END { if (found && !bad) exit 0; exit 1 }
  ' "$1"
}

# fm_get <file> <key> — echoes the trimmed, unquoted, comment-stripped value.
fm_get() {
  LC_ALL=C awk -v key="$2" '
    { sub(/\r$/, "") }
    NR == 1 { next }
    /^---$/ { exit }
    index($0, key ":") == 1 {
      val = substr($0, length(key) + 2)
      sub(/^[ \t]+/, "", val)
      first = substr(val, 1, 1)
      if (first == "\"" || first == "'"'"'") {
        val = substr(val, 2)
        i = index(val, first)
        if (i > 0) val = substr(val, 1, i - 1)
      } else {
        # Strip a trailing inline comment. HOOKS.md and README.md both document
        # enrollment as `phase: post-plan   # enrolls this agent...`, so this is
        # the shape a copy-pasting user actually produces.
        sub(/[ \t]*#.*$/, "", val)
      }
      sub(/[ \t]+$/, "", val)
      print val
      exit
    }
  ' "$1"
}

# --- enumeration ------------------------------------------------------------

names=()
phases=()
orders=()
modes=()
origins=()

VALIDATION_ERRORS=0

index_of_name() {
  local target="$1" i=0 n=${#names[@]}
  while [ "$i" -lt "$n" ]; do
    if [ "${names[$i]}" = "$target" ]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

scan_dir() {
  local dir="$1" origin="$2" f base name phase order mode existing seen_here
  seen_here=""

  shopt -s nullglob
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    has_frontmatter "$f" || continue

    name="$(fm_get "$f" name)"
    phase="$(fm_get "$f" phase)"
    order="$(fm_get "$f" order)"
    mode="$(fm_get "$f" mode)"

    base="$(basename "$f")"
    [ -n "$name" ] || name="${base%.md}"

    # No phase key means the agent is not enrolled anywhere. Normal, not a
    # warning — tdd-worker is spawned directly and never via a hook.
    [ -n "$phase" ] || continue

    if ! is_valid_hook "$phase"; then
      err "$f: agent '$name' declares unknown phase '$phase'"
      err "  valid phases: $VALID_HOOKS"
      err "  to unenroll this agent instead, remove its 'phase' key entirely"
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      continue
    fi

    if [ -n "$mode" ] && ! is_valid_mode "$mode"; then
      err "$f: agent '$name' declares unknown mode '$mode'"
      err "  valid modes: $VALID_MODES"
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      continue
    fi
    [ -n "$mode" ] || mode="single"

    if [ -n "$order" ]; then
      case "$order" in
        ''|*[!0-9]*)
          warn "agent '$name' declares non-numeric order '$order'; using 100"
          order="100"
          ;;
      esac
    else
      order="100"
    fi

    case " $seen_here " in
      *" $name "*)
        warn "duplicate name '$name' in $dir; '$base' wins over the earlier file"
        ;;
    esac
    seen_here="$seen_here $name"

    if existing="$(index_of_name "$name")"; then
      # Local overrides plugin entirely — no field-level merge. Within one
      # directory, last wins (warned about above).
      phases[existing]="$phase"
      orders[existing]="$order"
      modes[existing]="$mode"
      origins[existing]="$origin"
    else
      names[${#names[@]}]="$name"
      phases[${#phases[@]}]="$phase"
      orders[${#orders[@]}]="$order"
      modes[${#modes[@]}]="$mode"
      origins[${#origins[@]}]="$origin"
    fi
  done
  shopt -u nullglob
}

if [ ! -d "$PLUGIN_AGENTS" ]; then
  err "plugin agents directory not found at '$PLUGIN_AGENTS'"
  err "  the script must stay in the plugin's hooks/ directory alongside agents/"
  exit 1
fi

scan_dir "$PLUGIN_AGENTS" plugin

plugin_md_count=0
shopt -s nullglob
for _f in "$PLUGIN_AGENTS"/*.md; do plugin_md_count=$((plugin_md_count + 1)); done
shopt -u nullglob
if [ "$plugin_md_count" -eq 0 ]; then
  warn "plugin agents dir '$PLUGIN_AGENTS' contains no .md files"
fi

# A missing project-local .claude/agents/ is normal — most projects have none.
if [ -d "$LOCAL_AGENTS" ]; then
  scan_dir "$LOCAL_AGENTS" local
fi

if [ "$VALIDATION_ERRORS" -gt 0 ]; then
  err "enrollment validation failed; fix the file(s) above and re-run"
  exit 3
fi

# --- fingerprint ------------------------------------------------------------

canonical_lines() {
  local i=0 n=${#names[@]}
  while [ "$i" -lt "$n" ]; do
    printf '%s|%s|%s|%s|%s\n' \
      "${origins[$i]}" "${names[$i]}" "${phases[$i]}" "${orders[$i]}" "${modes[$i]}"
    i=$((i + 1))
  done
}

compute_fingerprint() {
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest="$(canonical_lines | LC_ALL=C sort | shasum -a 256)"
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(canonical_lines | LC_ALL=C sort | sha256sum)"
  else
    err "neither shasum nor sha256sum is available; cannot compute a fingerprint"
    exit 1
  fi
  # Both print "<hash>  -"; take field 1 identically from either.
  printf '%s' "${digest%% *}"
}

if [ -n "$WANT_FINGERPRINT" ]; then
  printf '%s-v%s %s\n' "$FP_PREFIX" "$FP_VERSION" "$(compute_fingerprint)"
  exit 0
fi

if [ -n "$HAVE_EXPECT" ]; then
  expect_hash=""
  expect_version=""
  case "$EXPECT" in
    "$FP_PREFIX"-v*\ *)
      expect_version="${EXPECT#"$FP_PREFIX"-v}"
      expect_version="${expect_version%% *}"
      expect_hash="${EXPECT##* }"
      ;;
    *)
      expect_hash="$EXPECT"
      expect_version="$FP_VERSION"
      ;;
  esac

  valid_hash=1
  case "$expect_hash" in
    *[!0-9a-f]*) valid_hash="" ;;
    *) [ "${#expect_hash}" -eq 64 ] || valid_hash="" ;;
  esac
  case "$expect_version" in
    ''|*[!0-9]*) valid_hash="" ;;
  esac

  if [ -z "$valid_hash" ]; then
    # A botched write must not masquerade as drift — that would halt the run
    # with a message pointing at entirely the wrong cause.
    err "malformed --expect value '$EXPECT'"
    err "  expected '$FP_PREFIX-v$FP_VERSION <64-hex>' or a bare 64-hex digest"
    exit 2
  fi

  if [ "$expect_version" != "$FP_VERSION" ]; then
    # The hash algorithm changed, not the enrollment. Treat like a missing
    # fingerprint so a format bump does not brick every existing plan.
    warn "fingerprint version v$expect_version predates this script (v$FP_VERSION); skipping the drift check"
  else
    actual="$(compute_fingerprint)"
    if [ "$actual" != "$expect_hash" ]; then
      err "hook enrollment changed since this run started"
      err "  expected fingerprint: $expect_hash"
      err "  current fingerprint:  $actual"
      err "  current enrollment:"
      if [ "${#names[@]}" -eq 0 ]; then
        err "    (no agents enrolled at any hook)"
      else
        canonical_lines | LC_ALL=C sort | while IFS='|' read -r o n p ord m; do
          err "    $n ($p, order=$ord, mode=$m, $o)"
        done
      fi
      err "HCF halted. Re-run the plan to pick up the new configuration."
      err "if this change was intentional, delete"
      err "  .claude/plans/<plan-name>/.hook-fingerprint and re-run to re-baseline."
      exit 4
    fi
  fi
fi

# --- output -----------------------------------------------------------------

# Emits "order|name|mode" for one hook, sorted by order asc then name
# case-insensitively. LC_ALL=C keeps the tie-break identical on a macOS
# en_US.UTF-8 box and a Linux C one.
rows_for_hook() {
  local hook="$1" i=0 n=${#names[@]}
  while [ "$i" -lt "$n" ]; do
    if [ "${phases[$i]}" = "$hook" ]; then
      printf '%s|%s|%s\n' "${orders[$i]}" "${names[$i]}" "${modes[$i]}"
    fi
    i=$((i + 1))
  done | LC_ALL=C sort -t'|' -k1,1n -k2,2f
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

if [ -n "$WANT_JSON" ]; then
  printf '{"hooks":{'
  hook_sep=""
  for hook in ${HOOK_FILTER:-$VALID_HOOKS}; do
    printf '%s"%s":[' "$hook_sep" "$hook"
    row_sep=""
    while IFS='|' read -r ord nm md; do
      [ -n "$nm" ] || continue
      printf '%s{"name":"%s","order":%s,"mode":"%s"}' \
        "$row_sep" "$(json_escape "$nm")" "$ord" "$(json_escape "$md")"
      row_sep=","
    done <<EOF
$(rows_for_hook "$hook")
EOF
    printf ']'
    hook_sep=","
  done
  printf '}}\n'
  exit 0
fi

if [ -n "$HOOK_FILTER" ]; then
  # Filtered and empty prints ABSOLUTELY NOTHING. A Bash call's stdout is
  # visible in the transcript, so any marker here would violate HOOKS.md's rule
  # that an empty hook is completely invisible to the user.
  rows="$(rows_for_hook "$HOOK_FILTER")"
  [ -n "$rows" ] || exit 0
  printf '# hook: %s\n' "$HOOK_FILTER"
  printf '%s\n' "$rows" | while IFS='|' read -r ord nm md; do
    printf '  order=%-5s name=%-40s mode=%s\n' "$ord" "$nm" "$md"
  done
  exit 0
fi

# Unfiltered: the by-hand debugging view, where explicit empty markers ARE
# wanted. Nothing consumes this programmatically.
first=1
for hook in $VALID_HOOKS; do
  [ "$first" -eq 1 ] || printf '\n'
  first=0
  printf '# hook: %s\n' "$hook"
  rows="$(rows_for_hook "$hook")"
  if [ -z "$rows" ]; then
    printf '  (empty — no agents enrolled at this hook)\n'
  else
    printf '%s\n' "$rows" | while IFS='|' read -r ord nm md; do
      printf '  order=%-5s name=%-40s mode=%s\n' "$ord" "$nm" "$md"
    done
  fi
done
exit 0
