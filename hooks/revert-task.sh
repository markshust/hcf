#!/usr/bin/env bash
# HCF exact revert: undo one tdd-worker's file changes, and only those.
#
#   revert-task.sh [--dry-run] <task-file> <agent-transcript.jsonl> [--dry-run]
#
# Claude Code records every Edit/Write/MultiEdit result in the worker's
# transcript (toolUseResult). For each project file the worker changed:
#
#   created by the worker (type "create")   -> delete it, but only if it still
#                                              holds exactly what the worker
#                                              left in it
#   a pre-change snapshot was recorded      -> restore the content from just
#     (originalFile on its first change)       before the worker's first change,
#     and the file is still exactly what       since nobody else touched it
#     the worker left it as
#   anything else: no snapshot (the file    -> undo the worker's edits in
#     was too large to be held in context),    reverse order (newString back to
#     or another writer changed the file       oldString), each one exact
#     after the worker (parallel tasks share
#     a worktree)
#
# Changes other tasks made earlier to the same file survive; `git checkout`
# would not keep them. Changes another worker made to the same file AFTER this
# one survive too: a snapshot restore would wipe them, so it is used only when
# the file is byte for byte what this worker left (worked out from its last
# recorded change). When the worker's own edits cannot be undone exactly
# around someone else's, the file is left as it is and reported (exit 1). A file is never deleted unless the transcript says the
# worker created it, and a file that cannot be reverted exactly is left as it
# is and reported (exit 1). Files under the task file's own directory (the
# plan; compared as given and with symlinks resolved) are left alone: the
# orchestrator resets the task file itself. A formatter the worker ran from
# Bash on files it named (the guard allows that) counts as the worker's own
# change: such a file is still deleted or restored.
#
# Workers may only change files with Edit/Write/MultiEdit (the guard enforces
# it), so the transcript holds every change. Run it before any other worker
# touches the same files again.
#
# Exit codes: 0 reverted (or nothing to do), 1 a file could not be reverted
# exactly (left untouched), 3 usage error or a missing jq / python3.

set -u

# --dry-run may come anywhere on the command line.
dry_run=""
args=()
for a in "$@"; do
  if [ "$a" = "--dry-run" ]; then dry_run="--dry-run"; else args+=("$a"); fi
done
task_file="${args[0]:-}"
transcript="${args[1]:-}"

if [ -z "$task_file" ] || [ -z "$transcript" ] || [ ! -r "$transcript" ]; then
  printf 'usage: revert-task.sh <task-file> <agent-transcript.jsonl> [--dry-run]\n' >&2
  exit 3
fi
command -v python3 >/dev/null 2>&1 || { printf 'revert-task: error: python3 is required\n' >&2; exit 3; }

# The task directory as given and with symlinks resolved: a plan directory is
# often a symlink from a worktree into the main checkout.
task_dir="$(cd "$(dirname "$task_file")" && pwd)" || exit 3

python3 - "$transcript" "$task_dir" "$dry_run" <<'PY'
import json, os, re, shlex, sys

transcript, task_dir, dry_run = sys.argv[1], sys.argv[2], sys.argv[3] == "--dry-run"
task_dirs = {task_dir.rstrip("/"), os.path.realpath(task_dir).rstrip("/")}

def under(path, dirs):
    return any(d and (path == d or path.startswith(d + "/")) for d in dirs)

def in_task_dir(path):
    return under(path, task_dirs) or under(os.path.realpath(path), task_dirs)

# Formatters the guard lets a worker run on files it names. Their rewrite of
# those files is the worker's own change, not another writer's.
FORMATTERS = re.compile(r"(^|/)(pint|php-cs-fixer|phpcbf|prettier|eslint|rector|black|ruff|isort|autopep8|gofmt|goimports|rustfmt|rubocop|standardrb|clang-format|stylua|swiftformat|ktlint|biome)$")

def formatted_paths(command, cwd):
    """Files named on a formatter command line, resolved against cwd."""
    out = []
    for segment in re.split(r"&&|\|\||;|\||\n", command):
        try:
            words = shlex.split(segment)
        except ValueError:
            continue
        if words and words[0] == "cd" and len(words) > 1:
            cwd = os.path.join(cwd, words[1])
            continue
        if not any(FORMATTERS.search(w) for w in words):
            continue
        for w in words:
            if not w.startswith("-") and re.search(r"\.[A-Za-z0-9]+$", w) and not FORMATTERS.search(w):
                out.append(os.path.normpath(os.path.join(cwd, w)))
    return out

# Every successful file change the worker made inside its project, per file,
# in order. Scratch files outside the project are none of the plan's business.
changes = {}
order = []
formatted = {}  # path -> sequence number of the worker's last formatter run on it
last_change = {}
project = None
seq = 0
with open(transcript, encoding="utf-8") as fh:
    for line in fh:
        seq += 1
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if project is None and rec.get("cwd"):
            project = rec["cwd"].rstrip("/")
        if rec.get("type") == "assistant":
            content = (rec.get("message") or {}).get("content")
            if isinstance(content, list):
                for item in content:
                    if isinstance(item, dict) and item.get("type") == "tool_use" and item.get("name") == "Bash":
                        cmd = (item.get("input") or {}).get("command") or ""
                        for p in formatted_paths(cmd, rec.get("cwd") or project or "."):
                            formatted[p] = seq
                            formatted[os.path.realpath(p)] = seq
            continue
        res = rec.get("toolUseResult")
        if rec.get("type") != "user" or not isinstance(res, dict) or not res.get("filePath"):
            continue
        path = res["filePath"]
        if in_task_dir(path):
            continue
        if project and not (under(path, {project, os.path.realpath(project)}) or under(os.path.realpath(path), {project, os.path.realpath(project)})):
            continue
        if path not in changes:
            changes[path] = []
            order.append(path)
        changes[path].append(res)
        last_change[path] = seq

def edits_of(res):
    """(old, new, replace_all) pairs a result applied, in application order."""
    if "edits" in res and isinstance(res["edits"], list):
        return [(e.get("old_string", e.get("oldString")), e.get("new_string", e.get("newString")), bool(e.get("replace_all", e.get("replaceAll"))))
                for e in res["edits"]]
    if res.get("oldString") is not None and res.get("newString") is not None:
        return [(res["oldString"], res["newString"], bool(res.get("replaceAll")))]
    return None

def after(res):
    """The file's content just after this change, or None when unknown."""
    if res.get("type") in ("create", "update") and isinstance(res.get("content"), str):
        return res["content"]
    content, pairs = res.get("originalFile"), edits_of(res)
    if content is None or pairs is None:
        return None
    for old, new, replace_all in pairs:
        if old is None or new is None or (old and old not in content):
            return None
        content = content.replace(old, new) if replace_all else content.replace(old, new, 1)
    return content

def current(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return None

status = 0
for path in order:
    recs = changes[path]
    first = recs[0]
    # What the worker left the file as, and what it holds now. They differ when
    # another writer (a parallel task) changed the file after this worker.
    left, now = after(recs[-1]), current(path)
    untouched_since = left is not None and now == left
    # The worker itself ran a formatter on the file after its last change:
    # the file is still only this worker's work.
    if formatted.get(path, formatted.get(os.path.realpath(path), 0)) > last_change[path]:
        untouched_since = True
    if first.get("type") == "create":
        if now is None:
            continue
        if not untouched_since:
            print("revert-task: error: %s was created by this worker but changed by another writer since (or its last content is unknown); left untouched" % path, file=sys.stderr)
            status = 1
            continue
        print("delete  " + path)
        if not dry_run:
            os.remove(path)
        continue
    if first.get("originalFile") is not None and untouched_since:
        print("restore " + path)
        if not dry_run:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(first["originalFile"])
        continue
    # No snapshot, or another writer changed the file after this worker: undo
    # this worker's edits, newest first, from the file as it is now.
    try:
        with open(path, encoding="utf-8") as fh:
            content = fh.read()
    except OSError:
        print("revert-task: error: %s is missing and has no snapshot; cannot revert it" % path, file=sys.stderr)
        status = 1
        continue
    ok = True
    for res in reversed(recs):
        pairs = edits_of(res)
        if pairs is None:
            print("revert-task: error: %s was rewritten without a snapshot; left untouched" % path, file=sys.stderr)
            ok = False
            break
        for old, new, replace_all in reversed(pairs):
            count = content.count(new) if new else 0
            if count == 0 or (count > 1 and not replace_all):
                print("revert-task: error: cannot locate an edit to undo exactly in %s; left untouched" % path, file=sys.stderr)
                ok = False
                break
            content = content.replace(new, old) if replace_all else content.replace(new, old, 1)
        if not ok:
            break
    if not ok:
        status = 1
        continue
    print("undo    " + path)
    if not dry_run:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)

sys.exit(status)
PY
