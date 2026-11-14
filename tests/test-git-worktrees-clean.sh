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

printf "\nTest group: a dry run\n"

dry="$TMPDIR/dry"
make_repository "$dry"
make_worktree "$dry" merged
on_main "$dry" merge --quiet --no-edit merged
make_worktree "$dry" squashed
on_main "$dry" commit --quiet --allow-empty --message "main moves on, so the squash cannot fast-forward"
on_main "$dry" merge --quiet --squash squashed > /dev/null
on_main "$dry" commit --quiet --message "squashed work"
# Rewriting every line makes merging the branch conflict, so only the
# squash check can find it.
seq 1 20 | sed 's/$/ edited/' > "$dry/checkout/squashed.txt"
on_main "$dry" commit --quiet --all --message "later edit to every line"
make_worktree "$dry" vanished
on_main "$dry" merge --quiet --no-edit vanished
rm -rf "$dry/vanished"
make_worktree "$dry" ahead
make_worktree "$dry" dirty
on_main "$dry" merge --quiet --no-edit dirty
printf 'edited\n' >> "$dry/dirty/dirty.txt"
on_main "$dry" push --quiet origin main

# Everything a run could change: worktree records, branches, and each index.
dry_state() {
  on_main "$dry" worktree list --porcelain
  on_main "$dry" for-each-ref --format='%(refname) %(objectname)' refs/heads
  ls -lT "$dry/checkout/.git/worktrees"/*/index 2>/dev/null || ls -l --time-style=full-iso "$dry/checkout/.git/worktrees"/*/index
  cat "$dry/checkout/.git/worktrees"/*/index | cksum
}
before="$(dry_state)"
sleep 1
output="$(cd "$dry/checkout" && "$CLEAN" --dry-run 2>&1)"
status=$?
after="$(dry_state)"

if [ "$status" -eq 0 ]; then ok "exits 0"; else ko "exits $status"; printf '%s\n' "$output"; fi
if [ "$before" = "$after" ]; then
  ok "changes no worktree, branch or index"
else
  ko "changed something:"
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after")
fi
assert_stays "a merged worktree stays" "$dry" merged
assert_stays "a squash-merged worktree stays" "$dry" squashed
if branch_exists "$dry" vanished; then ok "the branch of a vanished worktree stays"; else ko "the branch of a vanished worktree was deleted"; fi
assert_reports "counts what would go" "would remove 3" "$output"
assert_reports "says a merge is why it would go" "(merged) - " "$output"
assert_reports "gives the reason for a merge" "- merged into origin/main" "$output"
assert_reports "gives the reason for a squash merge" "(squashed) - " "$output"
assert_reports "names the squash merge" "- squash merged into origin/main" "$output"
assert_reports "says a vanished directory's branch would be deleted" "(vanished) - directory was already gone, branch would be deleted" "$output"
assert_reports "counts what would stay" "kept 2" "$output"
assert_reports "says why a never-merged branch would stay" "(ahead) - work not on origin/main" "$output"
assert_reports "says why uncommitted changes would stay" "(dirty) - uncommitted changes or untracked files" "$output"
assert_reports "prints the total size" "would free " "$output"
if printf '%s\n' "$output" | grep --quiet -E '^  .*\(merged\) - [0-9.]+[KMGT] - merged'; then
  ok "prints the size of each worktree"
else
  ko "no size for the merged worktree:"
  printf '%s\n' "$output"
fi

(cd "$dry/checkout" && "$CLEAN" --dry-run "$dry/merged" > /dev/null 2>&1)
status=$?
if [ "$status" -eq 0 ]; then ok "exits 0 for a path it would remove"; else ko "exits $status for a path it would remove"; fi
assert_stays "a dry run with a path removes nothing" "$dry" merged

(cd "$dry/checkout" && "$CLEAN" --dry-run "$dry/ahead" > /dev/null 2>&1)
status=$?
if [ "$status" -eq 1 ]; then ok "exits 1 for a path it would keep"; else ko "exits $status for a path it would keep"; fi

printf "\nTest group: the worktree the command runs from\n"

(cd "$dry/merged" && "$CLEAN" > /dev/null 2>&1)
assert_stays "a run from inside a merged worktree keeps it" "$dry" merged
assert_gone "and still removes the other merged worktrees" "$dry" squashed

printf "\nTest group: every repository on the Mac\n"

# HOME is a temp folder, so only the repositories built here are found.
# A git wrapper logs where each git command ran and what it named, to show
# nothing reads an SMBC-Leaf folder.
home="$TMPDIR/home"
origins="$TMPDIR/origins"
mkdir -p "$home" "$origins" "$TMPDIR/bin"
real_git="$(command -v git)"
export GIT_LOG="$TMPDIR/git.log"
cat > "$TMPDIR/bin/git" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\$PWD" "\$*" >> "\$GIT_LOG"
exec "$real_git" "\$@"
STUB
chmod +x "$TMPDIR/bin/git"

# Builds a checkout at $1 whose origin is a bare repository named $2.
make_checkout() {
  local checkout="$1" name="$2"
  git init --quiet --bare --initial-branch=main "$origins/$name.git"
  mkdir -p "$(dirname "$checkout")"
  git init --quiet --initial-branch=main "$checkout"
  git -C "$checkout" remote add origin "$origins/$name.git"
  git -C "$checkout" commit --quiet --allow-empty --message "initial"
  git -C "$checkout" push --quiet --set-upstream origin main
  git -C "$checkout" remote set-head origin main
}

# Adds a worktree of checkout $1 at $2 on branch $3, merged into main and pushed.
merged_worktree() {
  local checkout="$1" worktree="$2" branch="$3"
  mkdir -p "$(dirname "$worktree")"
  git -C "$checkout" worktree add --quiet -b "$branch" "$worktree" main
  printf '%s\n' "$branch" > "$worktree/$branch.txt"
  git -C "$worktree" add "$branch.txt"
  git -C "$worktree" commit --quiet --message "$branch work"
  git -C "$checkout" merge --quiet --no-edit "$branch"
  git -C "$checkout" push --quiet origin main
}

# Makes a worktree look unused for a long time.
age() {
  local git_dir
  git_dir="$(git -C "$1" rev-parse --absolute-git-dir)"
  touch -t 202001010000 "$git_dir/index" "$git_dir/HEAD"
}

alpha="$home/Desktop/Repositories/group/alpha"
make_checkout "$alpha" alpha
merged_worktree "$alpha" "$alpha/.claude/worktrees/done" alpha-done
merged_worktree "$alpha" "$alpha/.claude/worktrees/fresh" alpha-fresh
merged_worktree "$alpha" "$alpha/.claude/worktrees/here" alpha-here
age "$alpha/.claude/worktrees/done"
age "$alpha/.claude/worktrees/here"

dotfiles="$home/dotfiles"
make_checkout "$dotfiles" dotfiles
merged_worktree "$dotfiles" "$home/git-worktrees/dotfiles/done" dotfiles-done
age "$home/git-worktrees/dotfiles/done"

# Lives outside every folder that is scanned, so it is found only through its
# worktree in ~/git-worktrees.
beta="$TMPDIR/elsewhere/beta"
make_checkout "$beta" beta
merged_worktree "$beta" "$home/git-worktrees/beta/done" beta-done
age "$home/git-worktrees/beta/done"

leaf="$home/Desktop/Repositories/group/SMBC-Leaf"
make_checkout "$leaf" leaf
merged_worktree "$leaf" "$leaf/.claude/worktrees/done" leaf-done
merged_worktree "$leaf" "$home/git-worktrees/SMBC-Leaf.worktrees/done" leaf-elsewhere
age "$leaf/.claude/worktrees/done"
age "$home/git-worktrees/SMBC-Leaf.worktrees/done"

worktree_there() {
  [ -d "$1" ] && git -C "$1" rev-parse --verify --quiet HEAD > /dev/null
}

: > "$GIT_LOG"
output="$(cd "$alpha/.claude/worktrees/here" && HOME="$home" PATH="$TMPDIR/bin:$PATH" "$CLEAN" --all-repos --dry-run 2>&1)"
status=$?
if [ "$status" -eq 0 ]; then ok "a dry run exits 0"; else ko "a dry run exits $status"; printf '%s\n' "$output"; fi
assert_reports "a dry run counts merged worktrees in every repository" "would remove 3" "$output"
if worktree_there "$alpha/.claude/worktrees/done" && worktree_there "$home/git-worktrees/beta/done"; then
  ok "a dry run removes nothing"
else
  ko "a dry run removed a worktree"
fi

: > "$GIT_LOG"
output="$(cd "$alpha/.claude/worktrees/here" && HOME="$home" PATH="$TMPDIR/bin:$PATH" "$CLEAN" --all-repos 2>&1)"
status=$?
if [ "$status" -eq 0 ]; then ok "exits 0"; else ko "exits $status"; printf '%s\n' "$output"; fi

if ! worktree_there "$alpha/.claude/worktrees/done"; then ok "removes a worktree under <repo>/.claude/worktrees"; else ko "kept alpha's merged worktree"; fi
if ! worktree_there "$home/git-worktrees/dotfiles/done"; then ok "removes a worktree of ~/dotfiles under ~/git-worktrees"; else ko "kept dotfiles' merged worktree"; fi
if ! worktree_there "$home/git-worktrees/beta/done"; then ok "finds a repository only through its worktree in ~/git-worktrees"; else ko "kept beta's merged worktree"; fi
assert_reports "counts what went across repositories" "removed 3" "$output"

if worktree_there "$alpha/.claude/worktrees/fresh"; then ok "keeps a worktree used in the last 24 hours"; else ko "removed a recently used worktree"; fi
assert_reports "says why a recent worktree stayed" "(alpha-fresh) - used in the last 24 hours" "$output"
if worktree_there "$alpha/.claude/worktrees/here"; then ok "keeps the worktree it runs from"; else ko "removed the worktree it runs from"; fi
assert_reports "says why the current worktree stayed" "(alpha-here) - this command runs from it" "$output"

if worktree_there "$leaf/.claude/worktrees/done" && worktree_there "$home/git-worktrees/SMBC-Leaf.worktrees/done"; then
  ok "leaves SMBC-Leaf worktrees alone"
else
  ko "removed an SMBC-Leaf worktree"
fi
if printf '%s' "$output" | grep --quiet SMBC-Leaf; then ko "names SMBC-Leaf in its output"; else ok "never names SMBC-Leaf"; fi
if grep --quiet SMBC-Leaf "$GIT_LOG"; then
  ko "ran git in or on an SMBC-Leaf folder:"
  grep SMBC-Leaf "$GIT_LOG"
elif [ -s "$GIT_LOG" ]; then
  ok "never runs git in or on an SMBC-Leaf folder"
else
  ko "the git wrapper logged nothing, so the check proves nothing"
fi

(cd "$alpha" && HOME="$home" "$CLEAN" --all-repos "$alpha/.claude/worktrees/fresh" > /dev/null 2>&1)
status=$?
if [ "$status" -eq 2 ]; then ok "exits 2 for --all-repos with a path"; else ko "exits $status for --all-repos with a path"; fi

printf "\n%d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
