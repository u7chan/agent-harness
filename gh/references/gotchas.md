# Gotchas

Behaviors observed in the field, one entry per line, appended in the order they
were found and never sorted. Each entry names the action or command, what it
does with the input, and the exact error code or resolved target it produces, so
the next reader recognizes the case instead of rediscovering it.

Keep an entry to one line and write it from what the dispatcher returned, not
from what would have sufficed. `gh/actions.json` stays the authority for an
action's field list, and a missing field or an unknown one is answered there
before it is answered here.

## Entries

- `comments.create` accepts only the fields its schema declares — `number`, `body`, `attachments`, and `grant`; adding `reference` or `reason` fails with `UNKNOWN_FIELDS` before any API call.
- `issue.create` declares no `reference` input, so it targets the repository resolved from the current working directory; adding a `reference` key fails with `UNKNOWN_FIELDS` instead of redirecting the write.
- `pr.read` returns `mergeable` as `true`, `false`, or `null`; `null` comes back while GitHub is still computing it and after the PR is merged, so read it as a tri-state rather than a boolean the caller can rely on.
