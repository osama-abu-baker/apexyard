#!/bin/bash
# Guards the fork-local `## Ref` PR convention (.claude/rules/pr-session-ref.md).
#
# THIS TEST DRIVES THE REAL GATE, but does so inside a HERMETIC SANDBOX for
# the "gate itself" probes below — not against whatever config this host
# happens to carry. Two independent, previously-reproduced defects made an
# earlier version of this test lie about the gate's state (caught in review
# of PR #6):
#
#   Cause A: probe() claimed ticket-existence "short-circuits when
#   tracker.kind = none ... so this needs no fixture and no network" — but
#   tracker.kind = none lives ONLY in this fork's gitignored, machine-local
#   .claude/project-config.json. In a fresh checkout that file doesn't exist,
#   tracker.kind falls back to the shipped default "gh", and the hook then
#   tries to verify ITH-1 against a real tracker BEFORE ever reaching the
#   required-sections check. Fixed here by installing a fake `gh` on PATH
#   (_lib-mock-gh.sh) that answers OPEN for any ticket number, so the probe
#   never depends on a real ticket existing anywhere.
#
#   Cause B: driving the REAL hook against the REAL host's config meant the
#   probes' pass/fail depended on whether THIS machine happened to have opted
#   into the fork-local Ref rule (.pr.required_sections containing "Ref").
#   A fresh checkout with no local override resolves required_sections to the
#   shipped default (["Testing", "Glossary"]) — Ref is absent from it, so a
#   PR missing "## Ref" is legitimately ALLOWED by the hook, and the old test
#   treated that correct-for-its-config behaviour as a hard failure.
#
# The fix for both: assert on the gate's OUTPUT, but drive it inside a
# sandbox this test fully controls — its own git repo, its own
# `.apexyard-fork` anchor, its own `.claude/project-config.json` that opts
# into "Ref" (reproducing the WHOLE `.pr` subtree, since the hook's merge is
# shallow — see pr-session-ref.md's own warning about this). Mirrors
# test_validate_pr_required_sections.sh's make_sandbox(), which exists for
# this exact hook (me2resh/apexyard#154).
#
# What stays genuinely non-hermetic, on purpose: whether "## Ref" is ACTUALLY
# enforced on the machine this test is running on right now. That can only be
# answered by reading the real, live, per-machine config — so that check (the
# second section below) reports SKIP when the opt-in isn't present, rather
# than asserting PASS or FAIL against a fact the test has no control over.
# This mirrors the honesty pr-session-ref.md itself asks for: "enforcement is
# per-machine opt-in... never a guarantee."

set -u
cd "$(dirname "$0")/../../.." || exit 1
REPO_ROOT="$(pwd)"
HOOK_SRC="$REPO_ROOT/.claude/hooks/validate-pr-create.sh"
RULE="$REPO_ROOT/.claude/rules/pr-session-ref.md"
# shellcheck source=_lib-mock-gh.sh
source "$REPO_ROOT/.claude/hooks/tests/_lib-mock-gh.sh"

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }
skip() { echo "  SKIP  $1"; }

if [ ! -f "$HOOK_SRC" ]; then
  echo "FAIL: hook not found at $HOOK_SRC" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# make_sandbox — an isolated git repo the "gate itself" probes drive the real
# hook inside of. Deliberately reproduces the WHOLE .pr subtree with "Ref"
# added, standing in for "a machine that has opted into the fork-local Ref
# rule" — the same shallow-merge caveat pr-session-ref.md documents for real
# adopters applies to this fixture too.
# ---------------------------------------------------------------------------
make_sandbox() {
  local sb; sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git checkout -q -b chore/GH-113-test 2>/dev/null || git checkout -q -B chore/GH-113-test
    touch onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
  )
  # v2 ops-root anchor. Presence-only — resolve_ops_root's walk-up finds this
  # BEFORE it ever reaches any anchor further up the real filesystem, so the
  # sandbox always resolves to itself regardless of where mktemp put it.
  touch "$sb/.apexyard-fork"

  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/validate-pr-create.sh"
  chmod +x "$sb/.claude/hooks/validate-pr-create.sh"
  local lib
  for lib in _lib-read-config.sh _lib-ops-root.sh _lib-tracker.sh _lib-pr-repo.sh _lib-resolution-cache.sh; do
    if [ -f "$REPO_ROOT/.claude/hooks/$lib" ]; then
      cp "$REPO_ROOT/.claude/hooks/$lib" "$sb/.claude/hooks/$lib"
    fi
  done
  cp "$REPO_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"

  # The fixture opting into Ref. Reproduces the whole .pr subtree (not just
  # required_sections) — a partial override would silently drop
  # title_type_whitelist and skip_marker, per pr-session-ref.md's own
  # "because the merge is shallow" warning.
  jq '{pr: (.pr + {required_sections: (.pr.required_sections + ["Ref"])})}' \
    "$REPO_ROOT/.claude/project-config.defaults.json" > "$sb/.claude/project-config.json"

  echo "$sb"
}

# Drive the REAL hook inside a fresh hermetic sandbox and report whether it
# blocked on a missing `## Ref`. Each probe gets its own sandbox so the two
# assertions can't leak state into each other.
#
#   - mock_gh_install fakes ticket existence: the probe title references
#     ITH-1, which does not exist anywhere real, and the sandbox's
#     tracker.kind resolves to the shipped default "gh" — without the mock
#     this would depend on network + a real tracker (Cause A above).
#   - APEXYARD_OPS_DISABLE_PIN=1 forces _lib-ops-root.sh's resolvers to
#     walk up from the sandbox's OWN cwd instead of first consulting this
#     session's ops-root pin file (~/.claude/apexyard/ops-root-<session-id>).
#     Without it, a session that already has a valid pin for the REAL fork
#     root would have the sandboxed hook read the REAL fork's config instead
#     of the sandbox's — reproducing Cause B one layer up, inside the very
#     fix meant to close it.
probe() { # probe <body> -> echoes "BLOCKED" | "ALLOWED" | "OTHER:..."
  local body="$1" sb out rc
  sb=$(make_sandbox)
  mock_gh_install "$sb"
  local cmd="gh pr create --repo example-org/example-repo --title \"fix(ITH-1): t\" --body \"$body\""
  local input; input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  out=$( (cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 bash .claude/hooks/validate-pr-create.sh <<<"$input") 2>&1 )
  rc=$?
  rm -rf "$sb"
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

echo "== the gate itself (hermetic sandbox — a machine that HAS opted into Ref) =="
r=$(probe "$BODY_NO_REF")
case "$r" in
  BLOCKED) ok "a PR without '## Ref' is blocked when the local config opts in" ;;
  ALLOWED) bad "the hook did not block a missing '## Ref' even inside a sandbox
        whose .claude/project-config.json explicitly adds \"Ref\" to
        .pr.required_sections — the gate mechanism itself is broken, not a
        config-propagation gap. Check validate-pr-create.sh's required-
        sections logic." ;;
  *)       bad "gate blocked for an unrelated reason, so this is unproven: $r" ;;
esac

r=$(probe "$BODY_OK")
case "$r" in
  ALLOWED) ok "a PR with '## Ref' passes when the local config opts in" ;;
  BLOCKED) bad "a compliant PR (has '## Ref') was still blocked on the Ref section" ;;
  *)       bad "unrelated block on the compliant case: $r" ;;
esac

echo "== rule is present and loaded (this half propagates via git) =="
[ -f "$RULE" ] && ok "$RULE exists" || bad "$RULE missing"
grep -q "@.claude/rules/pr-session-ref.md" "$REPO_ROOT/CLAUDE.md" 2>/dev/null \
  && ok "CLAUDE.md imports the rule" || bad "CLAUDE.md does not import the rule"
# The non-propagation limit must live in the rule, not only in a commit message
# — the rule is the artifact a future reader finds.
grep -qi "gitignored" "$RULE" 2>/dev/null \
  && ok "rule states the gate does not propagate" \
  || bad "rule omits the non-propagation limit — a reader will over-trust it"

echo "== is '## Ref' actually enforced on THIS machine right now? (best-effort — SKIP, never a false PASS or FAIL) =="
# This is the one check in this file that legitimately needs the REAL,
# live, per-machine config — there is no way to answer "is the gate active
# HERE" from a sandbox. Per pr-session-ref.md, enforcement is per-machine
# opt-in: a machine with no local override, or a local override that
# doesn't happen to list "Ref", is not a broken machine — it just hasn't
# opted in. Report that state as SKIP, not as a hard PASS or FAIL, so this
# test can never assert a false positive (config exists → gate is live) or a
# false negative (config absent → gate is broken) about a fact it cannot
# control. See me2resh/apexyard#6 review discussion (Rex) for why the
# earlier version's PASS/FAIL here was itself part of the defect.
if [ -f "$REPO_ROOT/.claude/hooks/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.claude/hooks/_lib-ops-root.sh"
fi
if command -v resolve_ops_root >/dev/null 2>&1; then
  OPS=$(resolve_ops_root "$PWD")
else
  echo "  WARN  _lib-ops-root.sh unavailable — cannot resolve the ops root the"
  echo "        hooks actually use; this check is skipped rather than guessed."
  OPS=""
fi
CFG="${OPS:-$REPO_ROOT}/.claude/project-config.json"
if [ -z "$OPS" ] || [ ! -f "$CFG" ]; then
  skip "no local .claude/project-config.json at ${CFG} — Ref enforcement is not active on this machine (that is expected, not a failure — see pr-session-ref.md § per-machine opt-in)"
else
  if jq -e '(.pr.required_sections // []) | index("Ref")' "$CFG" >/dev/null 2>&1; then
    ok "this machine's local config opts into '## Ref' (.pr.required_sections includes \"Ref\")"
  else
    skip "local config at ${CFG} exists but .pr.required_sections does not include \"Ref\" — enforcement is not active on this machine"
  fi

  # Broader integrity check, still real-machine and still best-effort: when
  # a local override DOES exist, guard every subtree the fork depends on —
  # these configs have historically held disjoint halves, and a partial
  # override silently reverts tracker.kind to `gh` and portfolio.registry to
  # a nonexistent path. This part intentionally stays PASS/FAIL (not SKIP):
  # unlike "did this machine opt into Ref", a MALFORMED local config that
  # exists is an actionable problem on the machine running this test, not a
  # legitimate not-yet-opted-in state.
  for k in pr portfolio tracker; do
    jq -e --arg k "$k" 'has($k)' "$CFG" >/dev/null 2>&1 \
      && ok ".$k present in local config" || bad ".$k absent from local config — defaults apply, reverting fork setup"
  done
  jq -e '(.pr.title_type_whitelist // []) | length > 0' "$CFG" >/dev/null 2>&1 \
    && ok ".pr.title_type_whitelist is non-empty" \
    || bad ".pr.title_type_whitelist missing or empty — every PR title would be rejected"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
