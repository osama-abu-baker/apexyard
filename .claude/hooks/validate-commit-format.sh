#!/bin/bash
# PreToolUse hook on `git commit`: validates the commit message subject line
# against the conventional commit format defined in
# .claude/rules/git-conventions.md:
#
#   type: subject
#
# Where type is one of: feat, fix, refactor, test, docs, chore, style, perf
#
# Note: the PR *title* format is `type(TICKET): description` (with scope in
# parens) — that's enforced by validate-pr-create.sh. Commit messages use
# the simpler `type: subject` form without the scope because commits often
# don't correspond 1:1 to tickets.
#
# Multi-line -m messages are handled by flattening newlines before parsing
# (same pattern as verify-commit-refs.sh). Interactive commits (no -m / -F)
# are skipped.
#
# ApexStack also accepts the scoped form `type(scope): subject` as a valid
# superset — if a project wants to use scopes in commits, that's fine, but
# the scope is not required.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

if ! echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  exit 0
fi

# Extract commit message (multi-line safe)
COMMAND_FLAT=$(echo "$COMMAND" | tr '\n' ' ')
MSG=""
MSG=$(echo "$COMMAND_FLAT" | sed -nE "s/.*-m[[:space:]]+'([^']*)'.*/\1/p" | head -1)
if [ -z "$MSG" ]; then
  MSG=$(echo "$COMMAND_FLAT" | sed -nE 's/.*-m[[:space:]]+"([^"]*)".*/\1/p' | head -1)
fi
if [ -z "$MSG" ]; then
  MSG_FILE=$(echo "$COMMAND_FLAT" | sed -nE 's/.*(-F|--file)[[:space:]]+([^[:space:]]+).*/\2/p' | head -1)
  if [ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ]; then
    MSG=$(cat "$MSG_FILE")
  fi
fi

if [ -z "$MSG" ]; then
  # Interactive commit — skip (accepted gap, matches sibling hooks)
  exit 0
fi

# Get the first line of the message (the subject)
SUBJECT=$(echo "$MSG" | head -1)

if [ -z "$SUBJECT" ]; then
  exit 0
fi

# Validate:
#   type: subject         (no scope)
#   type(scope): subject  (with scope — superset)
#
# Types per .claude/rules/git-conventions.md:
#   feat, fix, refactor, test, docs, chore, style, perf
#
# ApexStack also accepts (build, ci, revert) since those types appear in the
# PR-title regex in git-conventions.md — staying consistent prevents commit
# messages from being valid in PR titles but not commits.
TYPE_REGEX='^(feat|fix|refactor|test|docs|chore|style|perf|build|ci|revert)(\([^)]+\))?:[[:space:]]+.+'

if ! echo "$SUBJECT" | grep -qE "$TYPE_REGEX"; then
  cat >&2 <<MSG_END
BLOCKED: Commit subject doesn't match the conventional commit format.

Subject was:
  ${SUBJECT}

Expected format (from .claude/rules/git-conventions.md):
  type: subject
  type(scope): subject

Where type is one of:
  feat, fix, refactor, test, docs, chore, style, perf, build, ci, revert

Examples:
  feat: add user avatar upload
  fix(auth): handle expired refresh tokens
  refactor: split order service into read/write sides
  docs(#42): update deployment runbook

The scope in parens is optional for commits (but REQUIRED for PR titles
with a ticket reference — that's enforced by validate-pr-create.sh).

To unblock:
  1. Amend the commit: git commit --amend -m "type: your subject"
  2. Or write a new commit with a conforming subject

If you think this rule is too strict for your project, customize the type
list in .claude/hooks/validate-commit-format.sh or file a ticket to add
\`.commit_types\` as a project-config option.
MSG_END
  exit 2
fi

exit 0
