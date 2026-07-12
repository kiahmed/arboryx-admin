#!/usr/bin/env bash
# ============================================================================
# worktree-clean.sh — tear down MERGED worktrees everywhere.
#
# For each target worktree under .claude/worktrees/, once its branch is merged
# into origin/main, remove (1) the worktree dir, (2) the local branch, and
# (3) the remote branch. Refuses to touch a branch that still has commits not
# in origin/main, so you can't delete unmerged work by accident.
#
# "Merged" is true if the branch is an ancestor of origin/main (normal merge)
# OR — for SQUASH merges, which look unmerged to git — if `gh` reports its PR
# as MERGED.
#
# Companion to `make ship`: with no <name>, if the primary working tree is
# parked on a non-main branch (because `make ship` cut one there), it first
# returns you to an up-to-date main, then deletes that branch — so your hands
# only ever touch `make ship` and `make worktree-clean`.
#
# Usage:
#   dev-utils/worktree-clean.sh                  # return to main + delete parked branch;
#                                                #   also clean ALL merged worktrees/branches
#   dev-utils/worktree-clean.sh <name>           # clean one worktree (dir under .claude/worktrees/)
#   dev-utils/worktree-clean.sh <name> FORCE=1   # skip the merged check, force-remove
#   FORCE=1 dev-utils/worktree-clean.sh          # clean-all, skipping merged checks
# ============================================================================
set -uo pipefail

NAME="${1:-}"
# FORCE may arrive as positional "FORCE=1" (from the Makefile) or the env var.
_f="${2:-}"; _f="${_f#FORCE=}"; [ -z "$_f" ] && _f="${FORCE:-0}"
[ "$_f" = "1" ] && FORCE=1 || FORCE=0

INVOKE_PWD="$(pwd -P)"

# Always operate from the MAIN working tree — never from inside a target worktree.
MAIN="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
cd "$MAIN" || { echo "can't locate main worktree"; exit 1; }
git fetch origin --quiet || true

# Companion to `make ship`: if the primary tree is parked on a non-main branch
# (and no explicit NAME was given), return it to an up-to-date main and remember
# that branch so we can delete it once we're off it.
PARKED=""
if [ -z "$NAME" ]; then
  pb="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  if [ "$pb" != "main" ]; then
    PARKED="$pb"
    echo "[worktree-clean] primary tree parked on '$pb' — returning to main"
    git checkout main && { git pull --ff-only origin main 2>/dev/null || true; }
  fi
fi

_is_merged() {
  local branch="$1"
  git merge-base --is-ancestor "$branch" origin/main 2>/dev/null && return 0
  # Squash-merge: ancestor check fails; ask GitHub whether the PR merged.
  if command -v gh >/dev/null 2>&1; then
    [ "$(gh pr view "$branch" --json state -q .state 2>/dev/null || true)" = "MERGED" ] && return 0
  fi
  return 1
}

_clean_one() {
  local dir="$1" branch ahead
  # Don't remove the worktree the caller is standing in.
  case "$INVOKE_PWD" in "$dir"|"$dir"/*)
    echo "[worktree-clean] skip $dir (you're inside it)"; return 0;; esac

  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    branch="worktree-$(basename "$dir")"
  fi
  echo "[worktree-clean] dir=$dir branch=$branch"

  if [ "$FORCE" = "1" ]; then
    echo "  FORCE set — skipping merged check"
  elif ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
    echo "  local branch $branch not found — cleaning dir/remote only"
  elif _is_merged "$branch"; then
    echo "  ✓ $branch is merged into origin/main"
  else
    ahead="$(git rev-list --count origin/main.."$branch" 2>/dev/null || echo '?')"
    echo "  ✗ SKIP: $branch has $ahead commit(s) not in origin/main. Merge its PR, or pass FORCE=1."
    return 0
  fi

  # 1. worktree dir + registration
  if [ -d "$dir" ]; then
    if [ "$FORCE" = "1" ]; then
      git worktree remove --force "$dir" && echo "  removed worktree $dir"
    else
      git worktree remove "$dir" && echo "  removed worktree $dir" \
        || echo "  (worktree has local changes — commit them or re-run with FORCE=1)"
    fi
  fi
  git worktree prune

  # 2. local branch
  if git rev-parse --verify "$branch" >/dev/null 2>&1; then
    git branch -D "$branch" >/dev/null 2>&1 && echo "  deleted local branch $branch"
  fi

  # 3. remote branch
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    git push origin --delete "$branch" >/dev/null 2>&1 && echo "  deleted remote branch $branch"
  else
    echo "  remote branch $branch already gone"
  fi
}

# Branch(es) currently checked out in SOME worktree — never delete these.
_checked_out() { git worktree list --porcelain | awk '/^branch /{sub("refs/heads/","",$2); print $2}'; }

_sweep_orphan_branches() {
  # In clean-all mode, also remove MERGED `worktree-*` branches that no longer
  # have a worktree dir (e.g. a reused worktree left the old branch behind).
  local co ref
  co=" $(_checked_out | tr '\n' ' ') "
  # local worktree-*/ship-* branches with no worktree dir
  for ref in $(git for-each-ref --format='%(refname:short)' 'refs/heads/worktree-*' 'refs/heads/ship/*' 2>/dev/null); do
    case "$co" in *" $ref "*) continue ;; esac
    if [ "$FORCE" = "1" ] || _is_merged "$ref"; then
      git branch -D "$ref" >/dev/null 2>&1 && echo "  swept merged local branch $ref"
      git ls-remote --exit-code --heads origin "$ref" >/dev/null 2>&1 \
        && git push origin --delete "$ref" >/dev/null 2>&1 && echo "  deleted remote branch $ref"
    fi
  done
  # remote-only worktree-*/ship-* branches (no local ref)
  for ref in $(git ls-remote --heads origin 'worktree-*' 'ship/*' 2>/dev/null | awk '{sub("refs/heads/","",$2); print $2}'); do
    git show-ref --verify --quiet "refs/heads/$ref" && continue
    case "$co" in *" $ref "*) continue ;; esac
    if [ "$FORCE" = "1" ] || _is_merged "origin/$ref"; then
      git push origin --delete "$ref" >/dev/null 2>&1 && echo "  deleted remote-only branch $ref"
    fi
  done
}

_delete_parked() {
  # Delete the branch we just stepped off of (from `make ship`), if it merged.
  [ -n "$PARKED" ] || return 0
  if [ "$FORCE" = "1" ] || _is_merged "$PARKED"; then
    git branch -D "$PARKED" >/dev/null 2>&1 && echo "  deleted branch $PARKED"
    git ls-remote --exit-code --heads origin "$PARKED" >/dev/null 2>&1 \
      && git push origin --delete "$PARKED" >/dev/null 2>&1 && echo "  deleted remote branch $PARKED"
  else
    echo "  ⚠ '$PARKED' isn't merged into origin/main — returned you to main but KEPT the branch (use FORCE=1 to delete)."
  fi
}

if [ -n "$NAME" ]; then
  _clean_one "$MAIN/.claude/worktrees/$NAME"
else
  # Clean-all: every registered worktree except the main one, then sweep any
  # orphaned merged worktree-*/ship-* branches, then drop the parked branch.
  found=0
  while IFS= read -r wt; do
    case "$wt" in
      */.claude/worktrees/*) found=1; _clean_one "$wt" ;;
    esac
  done < <(git worktree list --porcelain | awk '/^worktree /{print $2}' | tail -n +2)
  [ "$found" = "0" ] && echo "[worktree-clean] no managed worktree dirs under .claude/worktrees/"
  _sweep_orphan_branches
  _delete_parked
fi
echo "[worktree-clean] done."
