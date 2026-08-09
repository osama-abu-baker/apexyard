#!/bin/bash
# Shared PR-number and repo extraction for the merge-gate hooks:
#   - block-unreviewed-merge.sh
#   - require-design-review-for-ui.sh
#   - require-architecture-review.sh
#   - block-merge-on-red-ci.sh
#
# Not a hook itself (prefixed with `_lib-` so it's never wired as one). Sourced
# by the hooks above via `. "$(dirname "$0")/_lib-extract-pr.sh"`.
#
# WHY THIS EXISTS
# ---------------
# The merge gates originally only matched `gh pr merge <N>`. Incident (#47):
# merges via `gh api repos/<owner>/<repo>/pulls/<N>/merge -X PUT` silently
# bypassed all three gates because neither the matcher nor the PR-number
# extraction knew about the API shape. This helper gives every gate a single,
# tested way to recognise both shapes:
#
#   1. `gh pr merge 42 --squash`                                  → PR is 42
#   2. `gh api repos/owner/repo/pulls/42/merge -X PUT`            → PR is 42
#
# Any tool that edits one of the three merge hooks MUST keep calling this
# helper, not re-implement the parsing inline. That's the whole point.
#
# USAGE
# -----
#   . "$(dirname "$0")/_lib-extract-pr.sh"
#   if ! is_merge_command "$COMMAND"; then exit 0; fi
#   PR_NUMBER=$(extract_pr_number "$COMMAND")

# Returns 0 if $1 looks like a merge command this gate should fire on.
# Matches EITHER:
#   - `gh pr merge ...`
#   - `gh api ... repos/<owner>/<repo>/pulls/<N>/merge ...`
is_merge_command() {
  local cmd="$1"
  if echo "$cmd" | grep -qE '\bgh\s+pr\s+merge\b'; then
    return 0
  fi
  # `gh api` with a `/pulls/<N>/merge` path anywhere in the command. The path
  # may be quoted, slash-separated, and may include query params.
  if echo "$cmd" | grep -qE '\bgh\s+api\b.*repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge\b'; then
    return 0
  fi
  return 1
}

# Echoes the PR number extracted from the command, or empty if none found.
# Tries (in order):
#   1. `gh api .../pulls/<N>/merge` URL path
#   2. `gh pr merge <N>` first numeric arg
#   3. falls back to `gh pr view --json number` (current branch's PR)
extract_pr_number() {
  local cmd="$1"
  local pr=""

  # 1. gh api path extraction — greps the /pulls/<N>/merge segment directly.
  pr=$(echo "$cmd" | grep -oE 'repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge' | grep -oE '/pulls/[0-9]+/' | grep -oE '[0-9]+' | head -1)

  # 2. gh pr merge positional arg — first bare number after `gh pr merge`,
  #    ignoring anything on the right side of a pipe / && / ; to avoid picking
  #    up a number from a follow-up command.
  if [ -z "$pr" ]; then
    pr=$(echo "$cmd" | grep -oE '\bgh\s+pr\s+merge\b[^|;&]*' | grep -oE '[0-9]+' | head -1)
  fi

  # 3. Last resort: ask gh which PR the current branch points at.
  if [ -z "$pr" ]; then
    pr=$(gh pr view --json number --jq '.number' 2>/dev/null)
  fi

  echo "$pr"
}

# Echoes the PR's HEAD SHA as reported by GitHub, or empty on failure.
#
# Why this exists (see #55): merge-gate hooks previously compared approval
# markers against `git rev-parse HEAD` (local HEAD). But `gh pr merge <N>`
# merges the PR's branch on GitHub's side, which is almost never equal to
# the local HEAD (local is usually `main` or a different feature branch).
# That meant every merge required a `gh pr checkout <N> && gh pr merge <N>`
# dance. Tedious and error-prone.
#
# This helper asks GitHub directly for the PR's HEAD via `gh pr view`.
# Works for both the `gh pr merge` and `gh api .../pulls/<N>/merge` shapes.
#
# Usage:
#   PR_HEAD=$(resolve_pr_head "$PR_NUMBER" "$CMD_REPO")
#   # Compare PR_HEAD against marker SHAs instead of git rev-parse HEAD.
#
# Failure modes (returns empty, caller should fall back):
#   - Network error / rate limit / gh auth expired
#   - PR doesn't exist (wrong number, closed, or wrong repo)
#   - GitHub API transient failure
#
# On failure the caller should fall back to `git rev-parse HEAD` with a
# visible warning — better to block a valid merge that the user can retry
# than silently allow a merge on the wrong SHA.
resolve_pr_head() {
  local pr_number="$1"
  local cmd_repo="$2"
  local sha=""

  if [ -z "$pr_number" ]; then
    echo ""
    return
  fi

  if [ -n "$cmd_repo" ]; then
    sha=$(gh pr view "$pr_number" --repo "$cmd_repo" --json headRefOid --jq '.headRefOid' 2>/dev/null)
  else
    sha=$(gh pr view "$pr_number" --json headRefOid --jq '.headRefOid' 2>/dev/null)
  fi

  echo "$sha"
}

# Echoes the number of reviews GitHub holds for a PR that are pinned to a
# specific commit, or "unknown" if the API could not be reached.
#
# WHY THIS EXISTS
#
# An approval marker is a bare SHA in a local, gitignored file. The merge
# gate compares that SHA to the PR's HEAD, which verifies "a file exists
# whose contents are this commit hash" — NOT "a review happened at this
# commit". Nothing links the marker to a review, so anything able to write
# a file satisfies the gate.
#
# GitHub already records the missing fact: every posted review carries a
# `commit_id`. Requiring one review pinned to the PR's HEAD means forging
# an approval needs a review published to a public tracker — visible,
# timestamped, auditable — rather than a silent local file write.
#
# NOT an author-independence check. AgDR-0062 deferred that because Rex
# posts from the same account that opened the PR, so an independence rule
# would block every merge in a single-maintainer setup. This checks
# EXISTENCE only, and works unchanged on one account. It also cannot rely
# on review state: GitHub forces self-reviews to COMMENTED and refuses
# APPROVED, so state is not a usable signal here. The marker still carries
# the verdict; this only corroborates that a review was really posted.
#
# Usage:
#   n=$(count_reviews_at_commit "$PR_NUMBER" "$CMD_REPO" "$SHA")
#   [ "$n" = "unknown" ] && : # API unreachable — caller decides
#
# Returns "unknown" (not 0) when gh is missing or the API call fails, so a
# caller can distinguish "no review exists" from "could not tell".
count_reviews_at_commit() {
  local pr_number="$1"
  local cmd_repo="$2"
  local commit="$3"
  local repo="$cmd_repo"
  local out=""

  if [ -z "$pr_number" ] || [ -z "$commit" ]; then
    echo "unknown"
    return
  fi
  command -v gh >/dev/null 2>&1 || { echo "unknown"; return; }

  if [ -z "$repo" ]; then
    # Derive from the ORIGIN remote, not `gh repo view`. In a fork, gh resolves
    # to the parent (`me2resh/apexyard` rather than `<you>/apexyard`), so the
    # query would count reviews on somebody else's PR of the same number and
    # return a confident wrong answer instead of `unknown`. PRs live where we
    # push, which is origin.
    repo=$(git remote get-url origin 2>/dev/null \
             | sed -E 's#^git@[^:]+:#https://x/#' \
             | sed -E 's#^[a-z]+://[^/]+/##' \
             | sed -E 's#\.git$##')
    case "$repo" in
      */*) : ;;
      *)   repo="" ;;
    esac
    # No origin remote (bare checkout, test sandbox) — fall back to gh's own
    # resolution. Less accurate in a fork, but better than refusing to check.
    [ -z "$repo" ] && repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)
    [ -z "$repo" ] && { echo "unknown"; return; }
  fi

  # --paginate: a long-lived PR can exceed one page of reviews, and the
  # review at HEAD is the newest — i.e. the one a single-page fetch drops.
  out=$(gh api --paginate "repos/${repo}/pulls/${pr_number}/reviews" \
          --jq "[.[] | select(.commit_id == \"${commit}\")] | length" 2>/dev/null) || { echo "unknown"; return; }

  # --paginate emits one count per page; sum them.
  out=$(echo "$out" | awk 'BEGIN{s=0} /^[0-9]+$/{s+=$1; seen=1} END{if(seen) print s; else print "unknown"}')
  [ -z "$out" ] && out="unknown"
  echo "$out"
}

# Echoes the owner/repo extracted from the merge command, or empty if not found.
#
# This is a SIBLING function to extract_pr_number — same parsing approach,
# repo-extraction only. Kept separate so the existing extract_pr_number
# contract is not disturbed (it is used widely; callers that don't need the
# repo are unaffected).
#
# Recognises:
#   1. `gh api repos/<owner>/<repo>/pulls/<N>/merge ...`  — repo from URL path
#   2. `gh pr merge ... --repo <owner>/<repo> ...`        — repo from --repo flag
#   3. Falls back to `gh pr view --json headRepository`   — current branch's PR
#
# Returns empty if the repo cannot be determined.
extract_repo_from_command() {
  local cmd="$1"
  local repo=""

  # 1. gh api path extraction.
  repo=$(echo "$cmd" | grep -oE 'repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge' \
    | sed -nE 's|repos/([^/]+/[^/]+)/pulls/.*|\1|p' | head -1)

  # 2. --repo flag on gh pr merge.
  if [ -z "$repo" ]; then
    repo=$(echo "$cmd" | sed -nE 's/.*--repo[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
  fi

  # 3. Last resort: ask gh which repo the current branch's PR belongs to.
  if [ -z "$repo" ]; then
    repo=$(gh pr view --json headRepository --jq '.headRepository.nameWithOwner' 2>/dev/null)
  fi

  echo "$repo"
}
