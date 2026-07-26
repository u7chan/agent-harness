---
name: gh-pr-feedback
description: Check or reply to GitHub PR comments and feedback with the GitHub CLI. Use when asked in English to "check the PR comments", "review the feedback", "handle the feedback", or reply to PR review comments.
---

# GH PR Feedback

Fetch and organize PR feedback. Reply only when the user explicitly asks to reply; do not edit code, commit, push, approve, or resolve threads.

## Fetch

Run `gh auth status`, then fetch the specified PR. If none is specified, use the PR for the current branch.

```bash
scripts/fetch.sh <pr-number-or-url>
```

Review conversation comments, review bodies, and unresolved inline threads first. Summarize each actionable point with its author, location, and thread status. Do not treat feedback as a request to change code.

## Reply

Choose the reply language in this order: applicable higher-priority instruction, the user's explicit language choice, then the conversation's primary language.

Post only after an explicit user request to reply. Prepare the reply in a file.

```bash
# Reply in the same inline review thread.
scripts/reply.sh <pr-number-or-url> --inline <comment-id> <body-file>

# Reply in the PR conversation.
scripts/reply.sh <pr-number-or-url> --conversation <body-file>
```

Include the action taken and the result checked, concisely. Verify the returned URL and report it. Stop if the target comment or reply intent is ambiguous.
