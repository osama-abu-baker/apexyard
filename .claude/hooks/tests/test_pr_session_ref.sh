#!/bin/bash
# Guards the fork-local `## Ref` PR convention (.claude/rules/pr-session-ref.md).
#
# THIS TEST DRIVES THE REAL GATE. An earlier version asserted that
# `.pr.required_sections` in the nearest project-config.json contained "Ref" —
# and passed while the gate was switched off, because the hooks resolve config
# from the OPS ROOT (_config_repo_root -> resolve_ops_root -> .apexyard-fork)
# while the test resolved from its own checkout. In a worktree those are
# different directories holding different untracked configs, so the test was
# asserting a file with no causal relationship to the behaviour it claimed to
# guard. Caught in review of PR #6.
#
# The lesson generalises: assert on the gate's OUTPUT, not on the input you
# believe it reads. Config location is exactly the thing that goes wrong.

set -u
cd "$(dirname "$0")/../../.." || exit 1
HOOK=".claude/hooks/validate-pr-create.sh"
RULE=".claude/rules/pr-session-ref.md"
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

# Drive the hook and report whether it blocked on a missing `## Ref`.
# Ticket-existence is checked before the section check, but short-circuits when
# tracker.kind = "none" — so this needs no fixture and no network on this fork.
probe() { # probe <body> -> echoes "BLOCKED" | "ALLOWED"
  local body="$1" out rc
  out=$(jq -nc --arg c "gh pr create --repo ithbatiam/ithbat-backend --title \"fix(ITH-1): t\" --body \"$body\"" \
        '{tool_input:{command:$c}}' | bash "$HOOK" 2>&1); rc=$?
  if echo "$out" | grep -qi "required '## Ref' section"; then echo "BLOCKED"
  elif [ "$rc" -ne 0 ]; then echo "OTHER:$(echo "$out" | head -1)"
  else echo "ALLOWED"; fi
}

BODY_OK='## Summary
s
## Testing
t
## Glossary
| a | b |
## Ref
Ithbat IAM v0.2 | Orchestrator'
BODY_NO_REF='## Summary
s
## Testing
t
## Glossary
| a | b |'

echo "== the gate itself =="
r=$(probe "$BODY_NO_REF")
case "$r" in
  BLOCKED) ok "a PR without '## Ref' is blocked" ;;
  ALLOWED) bad "GATE IS OFF — a PR without '## Ref' was allowed.
        The hook reads project-config.json from the OPS ROOT, not this checkout.
        Add \"Ref\" to .pr.required_sections in the ops-root config, reproducing
        the whole .pr subtree (the merge is shallow)." ;;
  *)       bad "gate blocked for an unrelated reason, so this is unproven: $r" ;;
esac

r=$(probe "$BODY_OK")
case "$r" in
  ALLOWED) ok "a PR with '## Ref' passes" ;;
  BLOCKED) bad "a compliant PR was blocked on the Ref section" ;;
  *)       bad "unrelated block on the compliant case: $r" ;;
esac

echo "== rule is present and loaded (this half propagates) =="
[ -f "$RULE" ] && ok "$RULE exists" || bad "$RULE missing"
grep -q "@.claude/rules/pr-session-ref.md" CLAUDE.md 2>/dev/null \
  && ok "CLAUDE.md imports the rule" || bad "CLAUDE.md does not import the rule"
# The non-propagation limit must live in the rule, not only in a commit message
# — the rule is the artifact a future reader finds.
grep -qi "gitignored" "$RULE" 2>/dev/null \
  && ok "rule states the gate does not propagate" \
  || bad "rule omits the non-propagation limit — a reader will over-trust it"

echo "== ops-root config integrity (shallow merge drops what it omits) =="
# Use the framework's own resolver, never a reimplementation. A hand-rolled
# walk-up here stopped at the worktree (which also carries onboarding.yaml)
# while the hooks resolved to the real fork root — so the test inspected a
# different file from the one the gate reads. That is the same defect this
# test exists to catch, reproduced one layer down. Source the canonical lib.
if [ -f ".claude/hooks/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . ".claude/hooks/_lib-ops-root.sh"
fi
if command -v resolve_ops_root >/dev/null 2>&1; then
  OPS=$(resolve_ops_root "$PWD")
else
  echo "  WARN  _lib-ops-root.sh unavailable — cannot resolve the ops root the"
  echo "        hooks actually use; config assertions below are unreliable."
  OPS="$(pwd)"
fi
CFG="$OPS/.claude/project-config.json"
if [ ! -f "$CFG" ]; then
  echo "  SKIP  no ops-root config at $CFG"
else
  echo "  (ops root: $OPS)"
  # Guard every subtree the fork depends on, not just .pr — these configs have
  # historically held disjoint halves, and a partial override silently reverts
  # tracker.kind to `gh` and portfolio.registry to a nonexistent path.
  for k in pr portfolio tracker; do
    jq -e --arg k "$k" 'has($k)' "$CFG" >/dev/null 2>&1 \
      && ok ".$k present" || bad ".$k absent — defaults apply, reverting fork setup"
  done
  # `has` alone passes on an empty array, which would reject every PR title.
  jq -e '(.pr.title_type_whitelist // []) | length > 0' "$CFG" >/dev/null 2>&1 \
    && ok ".pr.title_type_whitelist is non-empty" \
    || bad ".pr.title_type_whitelist missing or empty — every PR title would be rejected"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
