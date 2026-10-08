#!/usr/bin/env bash
#
# Test: git-worktrees-clean removes each worktree whose work reached main,
# however it got there, and keeps every other one with its reason.
#
# Every repository is built with plain git in a temporary directory, and
# "origin" is a bare repository beside it, so nothing leaves the machine.

CLEAN="$(cd "$(dirname "$0")/.." && pwd)/git-worktrees-clean"
TMPDIR="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL="$TMPDIR/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null

# Builds "$1/checkout" with "$1/origin.git" as origin, each with one commit on main.
make_repository() {
  local root="$1"
  git init --quiet --bare --initial-branch=main "$root/origin.git"
  git init --quiet --initial-branch=main "$root/checkout"
  git -C "$root/checkout" remote add origin "$root/origin.git"
  printf 'node_modules/\n' > "$root/checkout/.gitignore"
  git -C "$root/checkout" add .gitignore
  git -C "$root/checkout" commit --quiet --message "initial"
  git -C "$root/checkout" push --quiet --set-upstream origin main
  git -C "$root/checkout" remote set-head origin main
}

# Each case edits its own file of 20 lines, so cases never touch each other's lines.
make_worktree() {
  local root="$1" branch="$2"
  git -C "$root/checkout" branch "$branch" main
  git -C "$root/checkout" worktree add --quiet "$root/$branch" "$branch"
  seq 1 20 > "$root/$branch/$branch.txt"
  git -C "$root/$branch" add "$branch.txt"
  git -C "$root/$branch" commit --quiet --message "$branch work"
}

on_main() {
  local root="$1"
  shift
  git -C "$root/checkout" "$@"
}

repo="$TMPDIR/all"
make_repository "$repo"

make_worktree "$repo" merged
on_main "$repo" merge --quiet --no-edit merged

make_worktree "$repo" squashed
on_main "$repo" merge --quiet --squash squashed > /dev/null
on_main "$repo" commit --quiet --message "squashed work"

make_worktree "$repo" squashed-then-edited
on_main "$repo" merge --quiet --squash squashed-then-edited > /dev/null
on_main "$repo" commit --quiet --message "squashed-then-edited work"
sed -i.bak 's/^5$/five/' "$repo/checkout/squashed-then-edited.txt" && rm "$repo/checkout/squashed-then-edited.txt.bak"
on_main "$repo" commit --quiet --all --message "later edit to the same lines"

make_worktree "$repo" ignored-files
mkdir -p "$repo/ignored-files/node_modules"
printf 'cache\n' > "$repo/ignored-files/node_modules/cache"
on_main "$repo" merge --quiet --no-edit ignored-files

make_worktree "$repo" vanished
on_main "$repo" merge --quiet --no-edit vanished
rm -rf "$repo/vanished"

make_worktree "$repo" vanished-unmerged
rm -rf "$repo/vanished-unmerged"

make_worktree "$repo" ahead

make_worktree "$repo" dirty
on_main "$repo" merge --quiet --no-edit dirty
printf 'edited\n' >> "$repo/dirty/dirty.txt"

make_worktree "$repo" untracked
on_main "$repo" merge --quiet --no-edit untracked
printf 'new\n' > "$repo/untracked/new.txt"

make_worktree "$repo" locked
on_main "$repo" merge --quiet --no-edit locked
on_main "$repo" worktree lock "$repo/locked"

on_main "$repo" worktree add --quiet --detach "$repo/detached" main

on_main "$repo" push --quiet origin main

output="$(cd "$repo/checkout" && "$CLEAN" 2>&1)"
status=$?

ok() {
  printf "  OK  %s\n" "$1"
  pass=$((pass + 1))
}

ko() {
  printf "  KO  %s\n" "$1"
  fail=$((fail + 1))
}

branch_exists() {
  git -C "$1/checkout" rev-parse --verify --quiet "refs/heads/$2" > /dev/null
}

assert_gone() {
  local label="$1" root="$2" branch="$3"
  if [ ! -e "$root/$branch" ] && ! branch_exists "$root" "$branch"; then
    ok "$label"
  else
    ko "$label - worktree or branch still there"
  fi
}

assert_stays() {
  local label="$1" root="$2" branch="$3"
  if [ -e "$root/$branch" ] && branch_exists "$root" "$branch"; then
    ok "$label"
  else
    ko "$label - worktree or branch was taken"
  fi
}

assert_reports() {
  local label="$1" expected="$2" text="$3"
  if printf '%s' "$text" | grep --quiet --fixed-strings -- "$expected"; then
    ok "$label"
  else
    ko "$label - '$expected' not in:"
    printf '%s\n' "$text"
  fi
}

printf "Test group: a run over every worktree\n"

if [ "$status" -eq 0 ]; then ok "exits 0"; else ko "exits $status"; printf '%s\n' "$output"; fi

assert_gone "a normal merge goes" "$repo" merged
assert_gone "a squash merge goes" "$repo" squashed
assert_gone "a squash merge whose lines main changed later goes" "$repo" squashed-then-edited
assert_gone "ignored files do not keep a merged worktree" "$repo" ignored-files

if ! branch_exists "$repo" vanished && ! on_main "$repo" worktree list --porcelain | grep --quiet "$repo/vanished$"; then
  ok "a merged worktree whose directory is gone loses its record and its branch"
else
  ko "a merged worktree whose directory is gone loses its record and its branch - still there"
fi

if branch_exists "$repo" vanished-unmerged && ! on_main "$repo" worktree list --porcelain | grep --quiet "$repo/vanished-unmerged$"; then
  ok "an unmerged worktree whose directory is gone loses its record but keeps its branch"
else
  ko "an unmerged worktree whose directory is gone loses its record but keeps its branch"
fi

assert_stays "a branch never merged stays" "$repo" ahead
assert_stays "uncommitted changes keep a merged worktree" "$repo" dirty
assert_stays "untracked files keep a merged worktree" "$repo" untracked
assert_stays "a lock keeps a merged worktree" "$repo" locked

if [ -e "$repo/detached" ]; then ok "a worktree with no branch stays"; else ko "a worktree with no branch was taken"; fi
if [ -e "$repo/checkout/.gitignore" ]; then ok "the main checkout is never a candidate"; else ko "the main checkout was taken"; fi

assert_reports "counts what went" "removed 5" "$output"
assert_reports "counts what stayed" "kept 6" "$output"
assert_reports "says why a never-merged branch stayed" "(ahead) - work not on origin/main" "$output"
assert_reports "says why an unmerged vanished branch stayed" "(vanished-unmerged) - directory already gone, branch kept" "$output"
assert_reports "says why uncommitted changes stayed" "(dirty) - uncommitted changes or untracked files" "$output"
assert_reports "says why untracked files stayed" "(untracked) - uncommitted changes or untracked files" "$output"
assert_reports "says why a locked worktree stayed" "(locked) - locked" "$output"
assert_reports "says why a detached worktree stayed" "detached - no branch checked out" "$output"

printf "\nTest group: a run over one worktree\n"

one="$TMPDIR/one"
make_repository "$one"
make_worktree "$one" first
make_worktree "$one" second
make_worktree "$one" unmerged
make_worktree "$one" locked
make_worktree "$one" locked-dirty
on_main "$one" merge --quiet --no-edit first
on_main "$one" merge --quiet --no-edit second
on_main "$one" merge --quiet --no-edit locked
on_main "$one" merge --quiet --no-edit locked-dirty
on_main "$one" worktree lock --reason "claude session" "$one/locked"
on_main "$one" worktree lock --reason "claude session" "$one/locked-dirty"
printf 'edited\n' >> "$one/locked-dirty/locked-dirty.txt"
on_main "$one" push --quiet origin main

(cd "$one/second" && "$CLEAN" ../first > /dev/null 2>&1)
status=$?
if [ "$status" -eq 0 ]; then ok "exits 0 when it removes the worktree"; else ko "exits $status when it removes the worktree"; fi
assert_gone "a relative path removes that worktree" "$one" first
assert_stays "other merged worktrees are left alone" "$one" second

output="$(cd "$one/checkout" && "$CLEAN" "$one/unmerged" 2>&1)"
status=$?
if [ "$status" -eq 1 ]; then ok "exits 1 when it keeps the worktree"; else ko "exits $status when it keeps the worktree"; fi
assert_reports "says why it kept the worktree" "(unmerged) - work not on origin/main" "$output"

(cd "$one/checkout" && "$CLEAN" "$TMPDIR" > /dev/null 2>&1)
status=$?
if [ "$status" -eq 2 ]; then ok "exits 2 for a path that is not a worktree"; else ko "exits $status for a path that is not a worktree"; fi

(cd "$one/checkout" && "$CLEAN" "$one/checkout" > /dev/null 2>&1)
status=$?
if [ "$status" -eq 2 ]; then ok "exits 2 for the main checkout"; else ko "exits $status for the main checkout"; fi

(cd "$one/checkout" && "$CLEAN" "$one/locked" > /dev/null 2>&1)
status=$?
if [ "$status" -eq 1 ]; then ok "a path alone keeps a locked worktree"; else ko "exits $status for a locked worktree without --include-locked"; fi

(cd "$one/checkout" && "$CLEAN" --include-locked "$one/locked" > /dev/null 2>&1)
status=$?
if [ "$status" -eq 0 ]; then ok "exits 0 with --include-locked"; else ko "exits $status with --include-locked"; fi
assert_gone "--include-locked removes a locked merged worktree" "$one" locked

(cd "$one/checkout" && "$CLEAN" --include-locked "$one/locked-dirty" > /dev/null 2>&1)
status=$?
if [ "$status" -eq 1 ]; then ok "--include-locked still keeps uncommitted changes"; else ko "exits $status for a locked worktree with uncommitted changes"; fi
if on_main "$one" worktree list --porcelain | grep --quiet "^locked claude session$"; then
  ok "a kept worktree keeps its lock and its reason"
else
  ko "a kept worktree lost its lock"
fi

(cd "$one/checkout" && "$CLEAN" --include-locked > /dev/null 2>&1)
status=$?
if [ "$status" -eq 2 ]; then ok "exits 2 for --include-locked without a path"; else ko "exits $status for --include-locked without a path"; fi

printf "\n%d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
