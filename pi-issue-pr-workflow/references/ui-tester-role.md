# ui-tester role

Record formats for the optional `ui-tester` role: the body it receives, the
return it writes, and the environment separation values it uses. The rules are
in [Team specification](../SKILL.md#team-specification) and
[ui-tester verification](../SKILL.md#ui-tester-verification); this file fixes shapes
only and adds no rule or condition of its own.

## Delegation body

The body uses the delegation contract that applies to every role and records:

- the task approved at the Kickoff gate;
- the target PR and its head SHA;
- the scope the task names (the user-visible surface for a default E2E task);
- the environment separation block below;
- the expected return: one line per verification item.

## Return report

The return states the head SHA and one line per item:

```text
item: <verification item>
head: <head SHA>
result: pass | fail | unverified
evidence: <command or observation>
reason: <required for unverified>
```

After a fix push, the same block is used for the re-verified items; the
re-verification scope is fixed in
[ui-tester verification](../SKILL.md#ui-tester-verification). Per-item findings stay
in the report for the orchestrator's triage, and the mandatory-check rule for
`completed` is the one that applies to every role
([Delegation contract](../SKILL.md#delegation-contract)).

## Environment separation

Take the values from the target repository's conventions. Keep the ui-tester's
state away from the implementation agent's state:

| State | Variable | Note |
|---|---|---|
| pi session storage | `PI_CODING_AGENT_SESSION_DIR` | `--session-dir` wins over the environment variable |
| Playwright session | `PW_SESSION` | named session; `playwright` by default |
| Playwright artifacts | `PW_ARTIFACT_DIR` | screenshots, traces, downloads |
| application state | the application's own variables | follow the application's README or implementation |
| application ports | the application's own variables | bind a port the implementation agent does not use |
