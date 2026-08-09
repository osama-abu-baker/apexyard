# Corroborate approval markers against a review posted at the PR HEAD

> In the context of a merge gate whose only evidence is a local file containing a commit hash, facing the fact that a forged marker is byte-identical to a legitimate one, I decided to additionally require that GitHub holds at least one review pinned to the PR's HEAD commit, to achieve a gate that verifies a review happened rather than that a file exists, accepting that the check fails open when the API is unreachable and that it proves existence rather than independence.

## Context

`block-unreviewed-merge.sh` requires two markers under `.claude/session/reviews/`: `<pr>-rex.approved` (a bare 40-char SHA) and `<pr>-ceo.approved` (structured key/value). It compares each marker's SHA against the PR's HEAD.

That comparison establishes **"a file exists whose contents are this commit hash."** It does not establish **"a review happened at this commit."** Nothing in the system links a marker to a review. Any process able to write a file satisfies the gate, and a fabricated marker is indistinguishable from a real one by inspection — same length, same format, same contents.

The structured CEO marker (me2resh/apexyard#48) raised the bar for *that* half by requiring `approved_by=user` and `skill_version=2`, making a forgery a deliberate act rather than a one-line accident. The Rex marker got no equivalent treatment: it is still a bare SHA, and the bar for producing one is `echo <sha> > file`.

**How this surfaced.** A code-review subagent tripped a security warning for writing the marker files directly with `printf` instead of the sanctioned path. Auditing five merged PRs found **no forged markers** — GitHub held a substantive review pinned to each merged commit, posted before the merge.

The audit was only possible because GitHub happened to hold those reviews. That evidence was **incidental to the gate, not required by it**. Had the reviews never been posted, the merges would have proceeded identically and there would have been nothing to audit afterwards. The gap is that the gate never asks for the one artifact that would settle the question.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Structured Rex marker (mirror #48)** | Consistent with the CEO marker; no network dependency | Raises the *effort* of forgery without changing its *nature* — still a locally-authored file asserting its own truth. Does not make the claim checkable. **Rejected.** |
| **B. Require an `APPROVED` review state on GitHub** | Strongest possible signal | Unachievable: GitHub refuses `APPROVED` on your own PR and downgrades it to `COMMENTED`. In the single-maintainer default the reviewer posts from the account that opened the PR, so this blocks every merge. **Not possible.** |
| **C. Require author independence (AgDR-0062)** | Real adversarial guarantee | Same single-account problem, which is exactly why 0062 deferred it behind a config flag pending a separate bot identity. Unchanged here. **Still deferred.** |
| **D. Require ≥1 review pinned to the PR HEAD, any author (chosen)** | Makes the marker's claim checkable against an independent record; works on one account today; forging requires publishing to a public tracker | Network dependency; proves existence not quality; fails open when unreachable |
| **E. Sign markers (commit-signing, HMAC)** | Cryptographic provenance | Needs key distribution and a trusted signer that does not exist. The signer would be the same agent that writes the marker. **Rejected as circular.** |

## Decision

Chosen: **Option D**.

`count_reviews_at_commit()` in `_lib-extract-pr.sh` queries `repos/<owner>/<repo>/pulls/<N>/reviews` and counts reviews whose `commit_id` equals a given SHA. `block-unreviewed-merge.sh` calls it with the resolved PR HEAD, after the existing marker checks, and blocks when the count is zero.

**Existence, not independence.** This deliberately does not check *who* reviewed. A review from the PR author's own account satisfies it. That is what makes it deployable today on the single-maintainer default, and it is the reason this does not supersede AgDR-0062 — independence remains deferred and remains the stronger guarantee.

**Review state is deliberately ignored** for the reason in Option B: GitHub will not let a self-review be `APPROVED`, so state carries no information in the default setup. The marker still carries the verdict; this only corroborates that a review was genuinely posted at the commit being merged.

**Returns `unknown`, not `0`, on failure.** A caller must be able to distinguish "no review exists" from "could not tell". Collapsing them would either block every merge during an outage or silently skip the check.

**Fails open with a loud warning.** Matching `resolve_pr_head`'s existing fallback (me2resh/apexyard#55): a transient network or auth failure must not brick merging entirely. `APEXYARD_SKIP_REVIEW_CORROBORATION=1` is the documented hatch for a genuinely offline or mirrored tracker.

**`--paginate`.** A long-lived PR can exceed one page of reviews, and the review at HEAD is the newest — precisely the one a single-page fetch would drop.

## Consequences

- Forging an approval now requires publishing a review to a public tracker: visible, timestamped, attributable, and hard to do by accident. The failure mode moves from invisible to obvious.
- **The real residual is not fail-open — it is that the two artifacts never name each other.** Fail-open is the obvious weakness, and an attacker who can write a marker can often also break the API call. But that framing overstates fail-open's importance: anyone holding `gh` can post a one-line review far more cheaply than they can induce an outage. What actually remains is that the marker and the review are **two independent facts that happen to name the same SHA**. Nothing binds one to the other, so "a review exists at this commit" and "this marker was written because of that review" are still separate claims.

  Recording the review's `id` in the marker would close it: the marker would name the specific artifact it stands behind, and the gate could verify that artifact exists rather than that *something* does. Deferred rather than built here — it needs a marker-format change, a `skill_version` bump, a change to what the reviewer writes, migration for in-flight markers, and the same work in `require-architecture-review.sh`. Same scope reasoning that keeps that hook out of this change. This change only ever *increases* the evidence demanded, so it never has to be undone to get there.
- **Existence is not quality.** A one-line junk review satisfies this. It closes the case that actually occurred — a marker standing behind nothing — and no more.
- Every gated merge now makes one additional API call. Negligible against the merge itself, but merges now fail differently when GitHub is down (warn-and-proceed rather than proceed-silently).
- **Timing asymmetry with the marker.** A review posted at HEAD *after* the marker was written still satisfies the check. The gate verifies both artifacts point at the same commit, not that they were produced in a particular order.
- `require-architecture-review.sh` has the same marker-only shape and is unchanged. It should reuse `count_reviews_at_commit()` — deliberately out of scope here to keep the change reviewable.
- **Repo resolution when no `--repo` flag is present.** The first cut fell back to `gh repo view`, which in a fork resolves to the **parent** (`me2resh/apexyard`, not `<owner>/apexyard`). That would count reviews on a stranger's PR of the same number and return a confident wrong answer rather than `unknown` — the worst failure shape for a check like this. It now derives from the `origin` remote, which is where PRs are pushed, and falls back to `gh repo view` only when there is no origin (bare checkout, test sandbox) so the check degrades instead of refusing. Found in review of PR #4; latent today because both merge shapes carry an explicit repo, but live the moment another caller omits it.

## Verification

Against live GitHub data in **`ithbatiam/ithbat-backend`**: `0` at a HEAD pushed after its last review (would block), `1` at the commit that was reviewed, `1` and `3` at two merged PRs' HEADs, `unknown` for an unreachable repo and for empty arguments.

**This gate would not have passed all history, and the earlier claim that it would was wrong.** It held for `ithbat-backend`, which is where the numbers above were measured, and was then overgeneralised. In **this** repo `GET /pulls/1/reviews` returns `[]` — PR #1 is merged with zero reviews and would have been blocked. Corrected after review of PR #4.

That is the correct behaviour, not a defect: a merge with no review is exactly what the gate exists to stop. But it means **adopting this on a repo with unreviewed history will block re-merges of old branches**, and adopters should expect that rather than be surprised by it.

Hook suite 29 → 34.

The four in-test `gh` shims initially answered the reviews query with a **constant**, which meant the `commit_id` filter — the entire point of the change — was never executed. Review of PR #4 proved it: deleting the filter (`select(true)`) left the suite at 31/0. The shims now emit a JSON fixture and apply the caller's `--jq` through real `jq`, and the discriminating case is *reviews exist but none at HEAD* (a fixture of zero reviews blocks even with the filter deleted; only a non-empty fixture at the wrong commit distinguishes them).

Neuter results at 34 cases:

| Neuter | Suite |
|---|---|
| commit pinning deleted (`select(true)`) | 33/1 |
| gate trigger `-eq 0` → `-eq 999` | 32/2 |
| `unknown` fallback removed from the awk sum | 33/1 |
| `--paginate` removed | **34/0 — not covered** |

`--paginate` behaviour was verified against the live API (forcing `?per_page=1` yields one count per page, summing correctly; without it the later page is dropped) but is **not** pinned by a unit test. Stated rather than papered over.

## Artifacts

- `.claude/hooks/_lib-extract-pr.sh` — `count_reviews_at_commit()`
- `.claude/hooks/block-unreviewed-merge.sh` — corroboration block
- `.claude/hooks/tests/test_block_unreviewed_merge.sh` — two new cases
