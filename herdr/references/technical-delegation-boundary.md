# Technical delegation boundary

This document is the authoritative design for the technical boundary in Issue
#131. It defines the threat model, guarantee scope, component responsibilities,
and the required upstream contract. `herdr/SKILL.md` remains authoritative for
agent-facing candidate resolution and stop decisions; `async-delegation.md`
and the helper scripts remain authoritative for the wrapper protocol. Those
documents do not provide the hard boundary described here.

## Decision summary

- A normal delegation edge is **same-workspace only**. This applies to a new
  parent-to-child prompt, a follow-up prompt to an existing child, and a
  child-to-parent result return.
- A pane ID, label, model, UI focus, `$HERDR_PANE_ID`, or
  `$HERDR_WORKSPACE_ID` is not caller authentication. In particular, an
  environment variable must never be used as the authorization identity.
- The hard boundary belongs in the Herdr server/API dispatch path, not in this
  repository's skill or shell wrappers. Every operation that can deliver text
  or keys must pass through the same target authorization check.
- Explicit cross-workspace work is unsupported by the normal delegation path.
  A future exception, if needed, must be a separate human-authorized and
  auditable upstream capability. There is no approval flag, prompt convention,
  or raw CLI fallback for it.
- Until that upstream contract exists, this repository provides operational
  guidance only. It must not describe the current wrapper or Herdr 0.8.2 as a
  hard permission boundary.

## Verified facts and assumptions

### Herdr 0.8.2 observations

The following facts were checked against the locally installed `herdr 0.8.2`
binary and its live server. The server reports API protocol 20.

- The JSON schema for `agent.prompt` contains `target`, `text`, and optional
  wait options, but no caller pane or workspace. `agent.send_keys` contains a
  target and keys. `pane.send_text`, `pane.send_keys`, and `pane.send_input`
  contain a target pane and input, but no caller identity. The CLI convenience
  command `pane run` is also an input-delivery route.
- The request envelope exposes an ID and method parameters, but no
  connection-bound caller identity. `pane.current` has an optional
  `caller_pane_id` parameter; that is a request value, not proof of who sent
  the request.
- With the normal environment, `herdr pane current` returned the invoking
  pane. With the values below, the same read-only command returned the
  self-declared pane `wV:pP`, even though the command was run from the
  `wR` workspace:

  ```bash
  HERDR_WORKSPACE_ID=wV HERDR_PANE_ID=wV:pP herdr pane current
  ```

  With both variables unset, `herdr pane current` fell back to the server's
  focused pane (`wR:p9`) rather than discovering the calling process. These
  observations establish that these variables and the focused pane are not a
  trustworthy authorization identity. They do not, by themselves, prove the
  implementation of every server handler; the upstream behavioral tests below
  are required for that claim.
- `herdr pane list --workspace <id>` can scope a read result, while an
  argument-less list can expose panes globally. A global result can therefore
  contain a label/model-perfect match in another workspace. Read-only
  discovery does not authorize a subsequent input operation.
- The current `parent-delegate-async.sh` checks pane-ID syntax and workspace
  prefixes, and then calls `herdr agent prompt`. It does not authenticate the
  source process or independently establish target membership. The child
  helper similarly uses the existing raw prompt command for result transport.

The schema and observations show why a wrapper-only design is insufficient.
They are not a claim that a future Herdr transport must use one particular
authentication mechanism. The required property is an authenticated source
context bound to the transport, rather than a caller-supplied parameter.

### Threat model

#### Assets

- workspace isolation: a prompt, key sequence, or command must not be
  delivered to a pane in another workspace through a normal delegation edge;
- the target agent's input and the parent/child task context; and
- the integrity of the delegation edge when panes are stale, moved, or
  ambiguously identified.

#### In scope

Assume an agent or same-user shell process can:

- read this repository, omit or manually reproduce a wrapper, and invoke the
  installed `herdr` CLI or connect through its local socket;
- set, unset, or spoof `HERDR_*` variables;
- inspect global panes, labels, models, UI focus, and layouts;
- retry a raw route after a wrapper is unavailable, predicts rejection, or
  actually rejects; and
- name a target that moved or that happens to have an exact label/model match
  in another workspace.

This is the accident/escape behavior from #130, not a claim that the process
has compromised the Herdr server itself.

#### Trusted for the proposed boundary

The Herdr server's authoritative pane/workspace state and a source identity
bound to the agent's Herdr transport are trusted. A same-user Unix socket
permission (currently mode 0600) is only an OS-user boundary; it does not
identify one pane among processes owned by that user. A future capability or
broker must therefore be unforgeable as a *different* pane, and must not be
represented solely by user-settable IDs.

#### Out of scope

This design does not defend against a compromised Herdr server, a user with
authority to deliberately administer all workspaces, or a stolen upstream
capability. It also does not define skill distribution, revision pinning, or
shared-checkout behavior; those remain the independent scope of #132.

## Guarantee scope

### What counts as a hard guarantee

Call the property a hard guarantee only when the Herdr server enforces it
before dispatching any input bytes, for every input-capable route, using the
current server-side source and target metadata. A wrapper, Pi tool, environment
variable, or instruction can be a useful operational control, but it is not a
hard guarantee while an agent can bypass it with raw `agent prompt`, pane input,
or an equivalent route.

The proposed authorization predicate for a normal edge is:

```text
source = authenticated pane context of this request
target = current pane resolved from the requested agent/pane target
allow iff source exists, target exists, source != target,
          and source.workspace_id == target.workspace_id
```

The check and the input dispatch must use one authoritative server state view
so that a target moved between lookup and send cannot turn a previously valid
same-workspace decision into a cross-workspace delivery. A rejected request
must produce no target input. Exact error names are an upstream API decision,
but the result must distinguish an authorization/scope rejection from a
transport failure.

The predicate deliberately does not select a target. Candidate selection and
the distinction between a new child and a follow-up remain in the skill. The
server re-authorizes every send; it does not need a persisted edge, queue,
retry loop, or delegation state machine.

### Parent-to-child

For both a new prompt and a follow-up prompt, the proposed hard guarantee is
that an authenticated source pane cannot deliver through a normal input route
to another workspace, to itself, or to a nonexistent/stale target. A target
that is in the same workspace is allowed by this isolation boundary even when
the request is a follow-up: this issue does not introduce relationship state or
prove that the target is the child previously chosen by the skill.

The current repository cannot provide any of these properties against a raw
Herdr call. The wrapper's prefix check is a preflight convenience, not the
authorization boundary.

### Child-to-parent

`child-return-result.sh` carries the parent pane ID in the delegation prompt
and uses the existing raw `agent prompt` transport. Under the proposed
upstream gate, a child return can receive the same **same-workspace isolation**
guarantee in the reverse direction: a child source cannot send the result to
another workspace, itself, or a missing target.

That does **not** prove that the target is the actual direct parent. The current
protocol has no authenticated edge token or persisted parent relation, and the
helper intentionally does not discover a parent. Direct-parent authenticity is
therefore not claimed by #131. If it becomes necessary, it requires a separate
upstream capability for a return edge; adding that relationship state is not
part of this minimal design.

### Cross-workspace policy

Normal parent-to-child, follow-up, and child-to-parent operations are denied
across workspace boundaries, including when a user explicitly supplies the
other pane ID or when its label, agent kind, provider, model, and status all
match. The current skill already treats such a direct-parent request as
unsupported; the technical contract must make a raw attempt fail the same way.

There is no supported exception in this repository. If a product requirement
later needs cross-workspace control, Herdr/Pi must expose a separate operation
with an explicit human grant, distinct capability/audit record, and a policy
that is not accepted by generic `agent.prompt`, `pane.send_text`, or their
aliases. An agent's statement that the operation was approved is not such a
grant. Until that operation exists, the correct result is blocked.

## Incident and bypass matrix

The exact wrapper CLI and failure contract remain in
[`async-delegation.md`](async-delegation.md). This table records what the
technical boundary must do in addition to those operational rules.

| Scenario | Current behavior / risk | Required result after the upstream change |
| --- | --- | --- |
| Wrapper not run | The agent can manually invoke raw `agent.prompt` and bypass the prefix check. | The server derives the source from the bound transport and rejects a cross-workspace target before input dispatch. |
| Wrapper unavailable | Missing `HERDR_ENV`, missing executable, or missing helper stops only the wrapper. A raw retry is still possible today. | A raw retry has the same server authorization outcome; missing wrapper is never a reason to weaken the server check. |
| Rejection predicted | The agent can read the wrapper and predict its workspace-prefix rejection without executing it, as in #130. | Prediction has no special status. A manually reconstructed raw request is checked and rejected; no prompt bytes are delivered. |
| Wrapper actually rejects | The current wrapper rejects before its `agent prompt` call for a mismatched prefix. Retrying through raw CLI would bypass that check. | Wrapper preflight remains a scope rejection with no child call. A separately attempted raw request is independently rejected by Herdr; it is not a fallback. |
| No current candidate, global exact match | `wV` can have only its parent while a global list exposes an exact-match agent in `wR`; labels/models can create false confidence. | Target resolution may report no candidate, but any explicit `wR` target is mechanically rejected because the authenticated source is in `wV`. No target input is sent. |
| Target is self, missing, stale, or moved | Prefix equality and a stale ID do not establish existence or current membership. | Herdr resolves current metadata and rejects self/missing/stale targets; a move is checked atomically or fails closed. Zero target input is the invariant. |
| Same-workspace wrapper transport fails or outcome is unknown | A retry can duplicate or misclassify delivery if the caller guesses. | Preserve the existing distinction between scope reject, observed transport failure, and unknown outcome. Do not add retry/state handling to the boundary. |

The cross-workspace exact-match row is the acceptance-critical case: it is
rejected by the server's source/target metadata comparison, not by a skill
instruction, a global search convention, or a wrapper having happened to run.

## Responsibility boundary

| Component | Owns | Cannot guarantee |
| --- | --- | --- |
| `agent-harness` `SKILL.md` | Candidate scope, stop/fallback decisions, and the rule not to use raw fallback. | It cannot stop an agent from running another command or authenticate a caller. |
| `parent-delegate-async.sh` / `child-return-result.sh` | Small argument/environment checks and the existing prompt/result transport contract. | Prefix checks do not prove pane membership, source identity, direct-parent identity, or prevent raw CLI/API use. |
| Pi tool exposure / agent loader | It may make a constrained delegation tool the convenient path and can participate in supplying bound source context. | Tool exposure alone cannot prevent a shell process from invoking Herdr's raw routes. Skill loading and #132's distribution boundary are separate. |
| Herdr CLI and API server | The CLI must preserve the bound context when invoking the server; the server must resolve live targets and centrally authorize every input route. | The server should not treat env vars, request `caller_pane_id`, UI focus, or display metadata as authentication. |

### Required implementation location

The hard boundary is outside this repository: the **Herdr server/API request
dispatcher**, in the daemon behind `HERDR_SOCKET_PATH`, with its agent-launcher
or Pi integration as the source of the authenticated pane context. The
affected Herdr 0.8.2 protocol-20 input surface is:

- `agent.prompt`;
- `agent.send_keys`;
- `pane.send_text`;
- `pane.send_keys`;
- `pane.send_input`; and
- the `pane run` CLI convenience route, plus any future alias that dispatches
  input to a pane.

The upstream change should bind a source pane/workspace to the client
connection or an equivalent Herdr/Pi broker capability. It must reject absent
or invalid source context rather than accepting a caller-supplied replacement.
After resolving an agent target to a pane, it should apply the predicate above
in one central gate before dispatch. Read-only inspection can remain broader;
the gate is for input delivery.

This is a deliberately small server-side authorization check, not a new
runtime: no persistent delegation graph, attempt IDs, queue, retry policy, or
cross-workspace state machine is required. A constrained dispatcher added only
to `agent-harness` or only to Pi would leave the raw Herdr routes as a bypass,
so it would not satisfy #131.

### Required upstream issue report (not filed)

This PR does not create an external issue. The required report is:

> **Herdr API/server: bind caller pane context and enforce same-workspace input authorization**
>
> In Herdr 0.8.2 (protocol 20), input methods accept target pane/agent data
> without an authenticated caller pane. Add a connection- or broker-bound
> source context, reject missing/invalid context, and apply a centralized
> source/target workspace check before dispatch for `agent.prompt`, both agent
> and pane key/text/input routes, `pane run`, and future aliases. Add tests for
> env/caller-parameter spoofing, self/missing/moved targets, and a different
> workspace with an exact label/model match. Rejection must dispatch zero
> target input. Advertise the capability/version so clients can fail closed.

The dependency is therefore a Herdr release that implements and advertises
this server contract, plus its Pi/agent launcher path if that path is needed to
bind source context. No Herdr version is selected in this repository; until a
release capability is present, no hard guarantee may be claimed.

## Migration and compatibility

1. **Before the upstream release:** keep the current wrapper syntax, result
   format, and operational rules unchanged. `bash herdr/tests/run.sh` remains
   the wrapper regression suite. Treat all protection as operational and stop
   on cross-workspace or uncertain requests; do not silently fall back to raw
   commands.
2. **Capability gate:** the upstream server must advertise the bound-caller
   authorization capability. A future caller may claim the hard guarantee only
   after checking that capability. An old Herdr 0.8.2 server remains usable for
   compatible operations, but it provides no hard isolation guarantee. A
   security-sensitive caller may fail closed when the capability is absent.
3. **After rollout:** existing wrapper arguments and child return messages can
   remain source-compatible. Herdr will authorize the prompt sent by the
   wrapper and the raw prompt used internally by the child helper using the
   caller context of the executing agent. Clients without bound context must
   receive an error rather than an unauthenticated compatibility path for
   input delivery.
4. **Intentional cross-workspace work:** existing generic input callers must
   not retain an implicit exception. They must use the separately designed,
   human-authorized upstream operation, or be blocked. This design does not
   migrate such callers automatically.
5. **No #132 coupling:** skill snapshot/distribution, reload, and rollback
   policy remain an independent follow-up and are not a prerequisite for this
   authorization predicate.

No wrapper, CLI, or helper behavior is changed by this issue's repository
implementation. The compatibility risk is the explicit upstream change from
unauthenticated input to required source context; that risk must be handled by
the upstream capability rollout, not hidden by weakening the boundary.

## Automatable test plan

The following tests belong in the Herdr upstream contract suite. They should
run against the real API dispatcher (or a faithful socket-level fake) with a
dispatch spy that records whether any target input bytes were emitted.

### Authorization and target matrix

Use source `A:p1` in workspace `A`, another pane `A:p2`, and target `B:p1` in
workspace `B`; give `B:p1` the same label, agent kind, provider, model, and
status as the requested child.

| Test | Expected result | Dispatch spy |
| --- | --- | --- |
| Authenticated `A:p1` -> existing `A:p2` | allow | exactly one input |
| Authenticated `A:p1` -> `A:p1` | reject self | zero |
| Authenticated `A:p1` -> `B:p1` exact match | reject scope | zero |
| `A:p1` -> missing/malformed target | reject target | zero |
| Target moves from `A` to `B` before dispatch | reject or re-evaluate against `B` | zero cross-workspace input |
| Missing or invalid source context | reject | zero |
| Source context is `A:p1`, env/optional caller field says `B:p1` | use bound source or reject | never dispatch to `B` |
| Child `B:p1` -> parent `B:p2` | allow same-workspace isolation case | exactly one input |
| Child `B:p1` -> claimed parent `A:p1` | reject scope | zero |

The exact-match test must be run even when the scoped candidate list for `A`
contains only the source pane. It proves that global discovery cannot turn
into cross-workspace delivery. Run the parent and child direction tests
separately; do not infer a direct-parent relationship from a same-workspace
allow.

### Route and bypass matrix

For every cross-workspace target, repeat the rejection test through each
available route: `agent.prompt`, `agent.send_keys`, `pane.send_text`,
`pane.send_keys`, `pane.send_input`, and the `pane run` CLI alias. Repeat with
the wrapper:

- wrapper executed successfully;
- wrapper not executed;
- wrapper unavailable;
- rejection predicted from its preflight; and
- wrapper rejection observed, followed by an attempted raw route.

Every raw attempt must hit the same server gate and produce zero target input.
The wrapper-not-run/unavailable cases must not be represented as successful
wrapper calls; the test is specifically checking that omission does not remove
server enforcement. Also assert that read-only global list/layout/focus data
does not change the authorization result.

### Compatibility and regression checks

- Assert that the capability is advertised and that a client does not claim a
  hard guarantee when it is absent.
- Assert that wrapper CLI arguments, one-call behavior, result status/body
  format, and the distinction between scope rejection, observed transport
  failure, and unknown outcome remain unchanged. The repository's current
  contract checks are:

  ```bash
  bash herdr/tests/run.sh
  bash -n herdr/scripts/parent-delegate-async.sh \
    herdr/scripts/child-return-result.sh herdr/tests/run.sh
  git diff --check
  ```

- Review this document against the #130 chain: global exact-match selection,
  invalid/current-pane investigation, wrapper bypass, and raw prompt delivery.
  Those are design-review assertions until the upstream server capability is
  available; they must not be reported as passing hard-boundary tests on
  Herdr 0.8.2.

## Non-goals

- changing either helper, adding a broad dispatcher, or adding persistence or
  delegation state;
- turning the current prefix check or skill instructions into a claimed
  permission boundary;
- implementing a cross-workspace exception; or
- absorbing #132's skill distribution boundary.

## References

- Issue [#131](https://github.com/u7chan/agent-harness/issues/131)
- Issue [#130](https://github.com/u7chan/agent-harness/issues/130) and merged
  PR [#133](https://github.com/u7chan/agent-harness/pull/133)
- [`herdr/SKILL.md`](../SKILL.md)
- [`async-delegation.md`](async-delegation.md)
- [`parent-delegate-async.sh`](../scripts/parent-delegate-async.sh)
- [`child-return-result.sh`](../scripts/child-return-result.sh)
- [`herdr/tests/run.sh`](../tests/run.sh)
- [`_docs/architecture.md`](../../_docs/architecture.md)
