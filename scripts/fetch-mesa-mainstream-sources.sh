#!/bin/sh
# Rebase the Xclipse patch stack on top of the latest upstream Mesa.
#
# usage: ./fetch-mesa-mainstream-sources.sh [upstream-url]
#   The upstream URL can also come from MESA_UPSTREAM_URL. The remote name
#   defaults to "upstream" (MESA_UPSTREAM_REMOTE changes it) and the branch
#   to "main" (MESA_UPSTREAM_BRANCH changes it). The current branch is
#   rebased, so run it on the branch holding the Xclipse commits.
# Requires: git.
set -eu

cd "$(dirname "$0")/.."

UPSTREAM_URL="${1:-${MESA_UPSTREAM_URL:-https://gitlab.freedesktop.org/mesa/mesa.git}}"
REMOTE="${MESA_UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${MESA_UPSTREAM_BRANCH:-main}"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
   echo "error: not inside a git repository" >&2
   exit 1
fi

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
   echo "adding remote $REMOTE -> $UPSTREAM_URL"
   git remote add "$REMOTE" "$UPSTREAM_URL"
fi

echo "fetching $REMOTE/$UPSTREAM_BRANCH ..."
git fetch "$REMOTE" "$UPSTREAM_BRANCH"

echo "rebasing onto $REMOTE/$UPSTREAM_BRANCH ..."
if git rebase "$REMOTE/$UPSTREAM_BRANCH"; then
   echo "rebase complete: $(git log --oneline "$REMOTE/$UPSTREAM_BRANCH..HEAD" | wc -l) Xclipse commit(s) on top of $REMOTE/$UPSTREAM_BRANCH."
   echo "review with: git log --oneline $REMOTE/$UPSTREAM_BRANCH..HEAD"
   echo "then publish with: git push --force-with-lease"
else
   echo "error: rebase stopped, resolve the conflicts in these files and update the Xclipse code in them:" >&2
   git diff --name-only --diff-filter=U >&2
   echo "when done: git rebase --continue (or git rebase --abort to cancel everything)" >&2
   exit 1
fi
