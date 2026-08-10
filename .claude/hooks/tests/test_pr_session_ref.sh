#!/bin/bash
# Guards the fork-local `## Ref` PR convention (.claude/rules/pr-session-ref.md).
#
# WHAT PROPAGATES AND WHAT DOES NOT — the reason this test is shaped oddly:
#
#   tracked   .claude/rules/pr-session-ref.md   the rule itself
#   tracked   CLAUDE.md                          the import every session loads
#   IGNORED   .claude/project-config.json        the hook-level enforcement
#
# `.claude/project-config.json` is gitignored upstream by design (it holds
# deploy URLs and sensitive notes). This portfolio's sessions run on separate
# machines, so hook enforcement configured there exists only on the machine that
# configured it. The rule therefore propagates; the gate does not.
#
# So this test asserts the propagating half unconditionally, and the local half
# only when the file is present. A machine without the local config is not
# broken — it is unenforced, which is a different and openly-stated thing.

set -u
cd "$(dirname "$0")/../../.." || exit 1
RULE=".claude/rules/pr-session-ref.md"
CFG=".claude/project-config.json"
pass=0; fail=0

ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== rule is present and loaded (propagates to every machine) =="
[ -f "$RULE" ] && ok "$RULE exists" || bad "$RULE missing"

if grep -q "@.claude/rules/pr-session-ref.md" CLAUDE.md 2>/dev/null; then
  ok "CLAUDE.md imports the rule"
else
  bad "CLAUDE.md does not import the rule — sessions will not load it"
fi

if grep -qi "## Ref" "$RULE" 2>/dev/null; then
  ok "rule documents the '## Ref' section"
else
  bad "rule does not document the section heading"
fi

echo "== local hook enforcement (optional, per-machine) =="
if [ ! -f "$CFG" ]; then
  echo "  SKIP  $CFG absent — rule is documented but NOT gate-enforced on this machine"
else
  if jq -e '.pr.required_sections | index("Ref")' "$CFG" >/dev/null 2>&1; then
    ok "Ref is in .pr.required_sections"
  else
    bad "local config exists but omits Ref — gate will not ask for it"
  fi
  for s in Testing Glossary; do
    jq -e --arg s "$s" '.pr.required_sections | index($s)' "$CFG" >/dev/null 2>&1 \
      && ok "$s still required" || bad "$s dropped by the override"
  done
  # `has`, not `-e`: allow_multiple_closes is `false` and `jq -e false` exits 1
  # even though the key is present. Presence is the intent — the merge is
  # shallow, so a dropped key silently reverts to the default.
  for k in title_type_whitelist skip_marker allow_multiple_closes multi_close_skip_marker; do
    jq -e --arg k "$k" '.pr | has($k)' "$CFG" >/dev/null 2>&1 \
      && ok ".pr.$k reproduced (shallow-merge safe)" || bad ".pr.$k dropped"
  done
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
