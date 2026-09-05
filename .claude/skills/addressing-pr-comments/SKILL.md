---
name: addressing-pr-comments
description: >-
  Workflow for addressing reviewer comments on a GitHub pull request (or a stack
  of PRs): scan every review thread, walk the user through each one one-at-a-time
  (surrounding code + the reviewer's comment verbatim + your interpretation and a
  recommended response), collect their per-comment decisions, then batch all
  edits, replies, and thread resolutions. Use whenever the user asks to address /
  handle / respond to / go through / reply to PR or code-review comments.
---

# Addressing PR review comments

The user reviews each comment before any change is made. Default flow: surface →
they decide per comment → you batch-execute. Do not edit or reply until the user
has decided.

## 1. Scope the comments

Feedback arrives on **three independent channels**, and only the first has a
resolution state. Do not equate "actionable feedback" with "unresolved threads"
— that silently drops the other two.

1. **Inline review threads** — line-anchored; carry `isResolved`. The thread scan
   finds these.
2. **Review-submission bodies** — the top-level comment a reviewer attaches when
   submitting a review (`reviews.nodes[].body`). A human who leaves a `COMMENTED`
   review with only a body and no line comment produces one of these with **no
   inline thread and no `isResolved` field** — it can *never* appear in a thread
   scan. Bot summaries also land here.
3. **Conversation / issue comments** — `comments.nodes[].body`; also **no**
   resolution state.

- Confirm which PR(s). If it's a stack, cover all of them.
- Pull all three channels. Use GraphQL — one query gives thread node ids,
  resolution state, author, the first comment's `databaseId` (which equals the
  REST comment id), plus the review and conversation bodies:

  ```graphql
  query($pr: Int!) {
    repository(owner:"OWNER", name:"REPO") {
      pullRequest(number: $pr) {
        reviewThreads(first:100){ nodes {
          id isResolved
          comments(first:10){ nodes { databaseId author{login} path line body createdAt } }
        }}
        reviews(first:50){ nodes { author{login} state createdAt body } }
        comments(first:50){ nodes { author{login} createdAt body } }
      }
    }
  }
  ```
  Run with `gh api graphql -F pr=<n> -f query='…'`.
- **Print the actual bodies of all three channels — never just thread counts.**
  A count of unresolved threads tells you nothing about channels 2 and 3. Filter
  out empty `reviews.nodes[].body` (those are the containers for a review's inline
  comments) and bot-noise conversation comments (CI/deploy bots), then read every
  remaining non-empty body. Save each PR's query result to `pr_<n>.json`, then:

  ```bash
  # channel 2 (review bodies) + channel 3 (conversation comments), non-empty only
  jq -r '.data.repository.pullRequest as $p |
    ([$p.reviews.nodes[]  | select(.body != "") | "[REVIEW-BODY] @\(.author.login) (\(.state))\n\(.body)"] +
     [$p.comments.nodes[] | select(.body != "") | select(.author.login != "github-actions")
        | "[CONV-COMMENT] @\(.author.login)\n\(.body)"]) | .[]' pr_<n>.json
  ```

  Do this for every PR in the stack (loop over the numbers). Channel 1 (unresolved
  threads) is a separate pass over `.reviewThreads.nodes[] | select(.isResolved==false)`.
- Triage: separate human reviewers from bots. For channel 1, note which threads
  are resolved or already carry your reply. For channels 2 and 3 there is no
  resolution flag — each human review body / conversation comment is **open until
  a later reply or comment demonstrably addresses it**; scan the thread of replies
  and later comments to decide, and when unsure treat it as open. Bot re-reviews
  post a *summary* here plus inline threads — read the summary to catch findings
  dedup'd out of the inline set.

## 2. Walk through each comment sequentially

For each unresolved/unaddressed comment, present — one at a time, in order:

1. **The surrounding code** — `path:line` plus a short snippet (read the file at
   the comment's line; the REST/GraphQL comment carries `path` + `line` /
   `original_line`).
2. **The reviewer's comment**, verbatim.
3. **Your interpretation + recommendation** — what they're asking, and your
   recommended response: edit (describe it), reply-only, decline-with-reason, or
   **defer to a follow-up issue**. Recommend the follow-up issue when the
   suggestion is sound but doesn't belong in *this* PR — out of the PR's scope,
   not a correctness fix, or a change large enough to risk destabilising a
   tested/approved PR or creep its scope. The point is to bank the (usually good)
   idea in a tracked issue rather than either dropping it or bloating the PR. If
   you think the reviewer is wrong or the change is worse, say so with reasoning;
   the user makes the final call per comment.

Then stop for the user's decision. Don't dump all comments as one wall of text —
go one at a time, or a tight numbered list they can answer point-by-point. Make
no edits in this phase.

## 3. Batch-execute after all decisions are in

- Apply all code edits.
- **Validate** the touched area (build / lint / typecheck / tests) before
  committing. Report failures honestly.
- Commit with **explicit paths** (never `git add -A`); a **new commit on top**
  (don't amend a pushed branch); push.
- **Stacked PRs — restack the whole chain when the author wants it.** Default is
  a plain commit on top of each affected branch (fast-forward, no force). If the
  author wants the stack kept properly rebased — they'll say so ("restack
  properly", "rebase the stack") — or a lower branch's history moved, cascade
  **bottom-up**: for each child, `git rebase --onto <new-parent-tip> <old-parent-tip>`
  then `git push --force-with-lease`.
  - **Record each branch's old origin tip before you rewrite anything.** A plain
    `git rebase <parent>` re-replays the parent's *old* commits (orphaned by the
    parent's rewrite) and conflicts on every one; `--onto <new> <old>` replays
    only the child's own commits.
  - **Conflicts** appear where the same fix landed at two levels (parent and
    child both edit the same lines). Squash-merge makes intermediate commit
    structure irrelevant, so resolve straight to the known *final* file content
    (write the whole file) and `git add`; git then drops any now-redundant child
    commit as "already upstream".
  - The auto-mode classifier **blocks the force-push until the user names the
    restack** — "restack" / "rebase the stack" is that authorization; without it,
    prefer the commit-on-top default and leave children "behind" (cosmetic; it
    resolves at squash-merge).
- **Update the PR description** to stay in sync with the revised content: when
  edits change what the PR does, revise the body so it still describes the
  current end state (end state only, no "changed X in response to review"
  narration). Do this for every PR whose content the revisions touched,
  including a restacked child.
- **File the agreed follow-up issues.** For every comment the user chose to
  defer, open one GitHub issue capturing the suggestion, with a link back to the
  originating PR and review comment. Record the issue number so the reply and any
  tracking stay consistent. This is a commitment, not a deferral to nowhere — the
  work is now tracked and must actually be followed through.
- Post one **reply** per thread. For a deferred comment, the reply agrees with
  the reviewer, states it's out of scope for this PR, and links the follow-up
  issue (e.g. "good call — out of scope here, tracked in #\<issue\>").
- **Resolve** the threads the user agreed are addressed (a deferred comment whose
  reply links its follow-up issue counts as addressed).
- **A push can trigger a fresh bot re-review** that posts new threads (often
  continuations of the same themes as your fixes). Re-scan after pushing, but
  don't chase them in an unbounded loop — surface the new findings with a
  recommendation and let the user gate another round.

## Mechanics (gh + GraphQL)

- **Reply to a thread (REST):**
  `gh api --method POST repos/OWNER/REPO/pulls/<n>/comments/<comment_id>/replies -F body=@reply.txt`
  Always write the body to a file and pass `-F body=@file` — never inline a body
  containing backticks / quotes / `$()`; the shell mangles it.
- **Reply fallback (GraphQL)** — if the REST reply 404s on the comment id (seen
  for some bot / re-review comments), reply by thread node id:
  ```graphql
  mutation($threadId: ID!, $body: String!) {
    addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId, body:$body}){ comment{ url } }
  }
  ```
  `gh api graphql -F body=@reply.txt -f threadId="PRRT_…" -f query='…'`.
- **Update the PR description (gh):**
  `gh pr edit <n> --body-file body.md` — write the revised body to a file, same
  reason as replies: an inline body with backticks / quotes / `$()` gets mangled
  by the shell.
- **File a follow-up issue (gh):**
  `gh issue create --title "…" --body-file issue.md` (add `--label` / `--assignee`
  where apt). Write the body to a file, same shell-mangling reason. The body
  should link the originating PR and the specific review comment; capture the
  issue URL / number it prints and reference it back in the thread reply. Do this
  only for comments the user chose to defer — filing an issue is not a substitute
  for a decision.
- **Resolve threads (GraphQL)** — thread node id comes from the §1 query
  (`reviewThreads.nodes[].id`); match it to a comment via its first comment's
  `databaseId`. Resolve several in one mutation with aliases:
  ```graphql
  mutation {
    t1: resolveReviewThread(input:{threadId:"PRRT_…"}){ thread{ isResolved } }
    t2: resolveReviewThread(input:{threadId:"PRRT_…"}){ thread{ isResolved } }
  }
  ```
- **Verify at the end:** re-run the §1 thread query and confirm `unresolved == 0`
  (or only the threads the user chose to leave open), and that branch tips are
  synced with origin. After a restack, also confirm the ancestry chain holds
  (`git merge-base --is-ancestor origin/<parent> origin/<child>` for each link)
  and that PR base branches are unchanged (`gh pr view <n> --json baseRefName`).

## Conventions

Defer to the repo's CLAUDE.md. In this repo specifically: explicit staging,
pre-commit must pass (no `--no-verify`), commit/PR text describes the end state
only (no "switched from / removed X" narration), correct a pushed branch with a
new commit rather than amend+force.
