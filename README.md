# git-worktrees-clean

Removes each git worktree whose branch's work has reached `origin`'s default branch, then deletes that branch. It uses git only, so it works the same on GitHub, GitLab or any other host.

## Install

With Homebrew:

```bash
brew install justinkek/tap/git-worktrees-clean
```

Without Homebrew, put the script in any folder on your `PATH`:

```bash
curl -fsSL https://raw.githubusercontent.com/justinkek/git-worktrees-clean/main/git-worktrees-clean -o ~/.local/bin/git-worktrees-clean && chmod +x ~/.local/bin/git-worktrees-clean
```

Git runs any `git-<name>` on your `PATH` as `git <name>`, so no alias is needed. It needs bash and git 2.38 or later.

## Use

```bash
git worktrees-clean
```

```bash
git worktrees-clean ../my-feature
```

```bash
git worktrees-clean --include-locked ../my-feature
```

With no argument it checks every linked worktree of the current repository. With a path it checks only that worktree. `--include-locked` also removes that one worktree when it is locked, for a tool that locks its own worktrees while it works in them. Every other check still applies, and a worktree that is kept keeps its lock. It first fetches the default branch from `origin`, then prints what it did:

```
removed 2
  /code/app-feature-a (feature-a)
  /code/app-feature-b (feature-b) - directory was already gone
kept 2
  /code/app-feature-c (feature-c) - work not on origin/main
  /code/app-feature-d (feature-d) - uncommitted changes or untracked files
```

## What counts as merged

| How the branch reached the default branch | Removed |
| --- | --- |
| Normal merge, rebase or fast-forward | yes |
| Squash merge | yes |
| Squash merge, then later commits changed the same lines | yes |
| Squash merge whose diff was edited while merging, then later commits changed the same lines | no, kept as "work not on origin/main" |
| Never merged | no |

A branch counts as merged when either check passes:

1. Merging it into `origin/<default>` would change nothing (`git merge-tree`).
2. A commit on `origin/<default>` since the branch started has the same diff as the whole branch (`git patch-id`). This finds squash merges.

## What keeps a worktree

1. It is locked (`git worktree lock`), unless it was named with `--include-locked`.
2. It has no branch checked out.
3. It has uncommitted changes or untracked files. Files matched by ignore rules, such as `node_modules/`, do not keep it.
4. Its branch's work is not on the default branch.

A worktree whose directory was already deleted has git's record of it pruned (`git worktree prune`). Its branch is deleted only if its work is on the default branch.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | finished. With a path: the worktree and its branch were removed |
| 1 | with a path: the worktree was kept, and the reason is printed |
| 2 | usage error, or the path is not a linked worktree of this repository |
| 3 | not in a git repository, `origin`'s default branch is missing, or git is older than 2.38 |

## Test

```bash
bash tests/test-git-worktrees-clean.sh
```
