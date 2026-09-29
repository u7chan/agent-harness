# Tester role

Delegation body, re-verification report, completion report, and environment
separation for the optional `tester` role. The rules for the role are in
[Team specification](../SKILL.md#team-specification) and
[Tester verification](../SKILL.md#tester-verification); this file fixes the
shapes a run writes down.

## Delegation body

The body uses the delegation contract that applies to every role and adds:

- the target PR and its head SHA;
- the user-visible surface the Issue makes verifiable;
- the environment separation block below;
- the expected return: one line per verification item with `pass`, `fail`, or
  `unverified`.

The default task subject is E2E verification of the Issue's user-visible
surface through the Playwright skill. When that skill is unavailable, the
approved substitute is the target application's existing tests plus a smoke
check.

## Re-verification report

One block per reported item, on the latest head:

```text
item: <reported finding or verification item>
head: <head SHA>
result: pass | fail | unverified
evidence: <command or observation>
reason: <required for unverified>
```

An item outside the reported set and the affected scope is not re-opened in
the pass.

## Completion report

The return states the head SHA and every item it took on as `pass`, `fail`, or
`unverified` with its reason. Verification that could not run at all is
returned as `blocked` with the command and observation; per-item findings stay
in the report for the orchestrator's triage.

## Environment separation

Take the values from the target repository's conventions. Keep the tester's
state away from the implementation agent's state:

| State | Variable | Note |
|---|---|---|
| pi session storage | `PI_CODING_AGENT_SESSION_DIR` | `--session-dir` wins over the environment variable |
| Playwright session | `PW_SESSION` | named session; `playwright` by default |
| Playwright artifacts | `PW_ARTIFACT_DIR` | screenshots, traces, downloads |
| application state | the application's own variables | follow the application's README or implementation |
| application ports | the application's own variables | bind a port the implementation agent does not use |
