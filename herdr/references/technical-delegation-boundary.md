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
- The hard boundary belongs in the Herdr server's API **and client-protocol**
  dispatch paths, not in this repository's skill or shell wrappers. Every
  operation that can deliver text, keys, or terminal input must pass through
  the same target authorization check.
- Explicit cross-workspace work is unsupported by the normal delegation path.
  A future exception, if needed, must be a separate human-authorized and
  auditable upstream capability. Human interactive attach/control may remain a
  separate capability only when its provenance makes it unavailable to an
  agent process; Herdr 0.8.2 does not provide that isolation. There is no
  approval flag, prompt convention, or raw CLI fallback for normal delegation.
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
  command `pane run` is also an input-delivery route. This is only the API
  socket inventory; it is not the complete writable surface.
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
- The same Herdr 0.8.2 installation exposes writable client-protocol commands
  outside the JSON API: `herdr agent attach <target>`, `herdr terminal attach
  <terminal-id>`, and `herdr terminal session control <target>`. The latter
  resolves a pane/agent target to a terminal session and can send
  `terminal.input` to its PTY; attach is also an interactive writable stream.
  These commands use the observed `/home/u7dev/.config/herdr/herdr-client.sock`
  (mode 0600), separate from the API socket at `$HERDR_SOCKET_PATH`.
- The 0.8.2 client protocol represents the relevant control flow as
  `ClientMessage::ControlTerminal`; the installed binary exports
  `HeadlessServer::attach_terminal_client` and
  `apply_terminal_attach_input`. This confirms that a gate placed only in the
  API request dispatcher would leave a second input path. `terminal session
  observe` is read-only unless it is upgraded into a control/attach path;
  future writable aliases must be covered too.
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
  installed `herdr` CLI or connect through either its API or client-protocol
  socket;
- set, unset, or spoof `HERDR_*` variables;
- inspect global panes, labels, models, UI focus, and layouts;
- retry a raw route after a wrapper is unavailable, predicts rejection, or
  actually rejects; and
- name a target that moved or that happens to have an exact label/model match
  in another workspace, including through an attach/control target that is
  resolved to a terminal rather than directly to a pane.

This is the accident/escape behavior from #130, not a claim that the process
has compromised the Herdr server itself.

#### Trusted for the proposed boundary

The Herdr server's authoritative pane/workspace state and a source identity
bound to the agent's Herdr transport are trusted. A same-user Unix socket
permission (currently mode 0600 for both observed sockets) is only an OS-user
boundary; it does not identify one pane among processes owned by that user. A
future capability or broker must therefore be unforgeable as a *different*
pane, and must not be represented solely by user-settable IDs. This applies to
the client-protocol socket as well as the API socket.

#### Out of scope

This design does not defend against a compromised Herdr server, a user with
authority to deliberately administer all workspaces, or a stolen upstream
capability. It also does not define skill distribution, revision pinning, or
shared-checkout behavior; those remain the independent scope of #132.

## Guarantee scope

### What counts as a hard guarantee

Call the property a hard guarantee only when the Herdr server enforces it
before dispatching any input bytes, for every input-capable route on both
sockets, using the current server-side source and target metadata. A wrapper,
Pi tool, environment variable, or instruction can be a useful operational
control, but it is not a hard guarantee while an agent can bypass it with raw
`agent prompt`, pane input, terminal attach/control, or an equivalent route.

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

For a client-protocol request, `target` means the current owning pane after
resolving an agent target, terminal ID, or terminal session target. The gate
must run before `attach_terminal_client` accepts a writable session and again
before `apply_terminal_attach_input` applies `terminal.input`, or be factored
so that no input can reach either function without the same decision. A
human-only attach/control capability is not an agent bypass: it must be a
separately authenticated client principal that an agent process cannot invoke
or inherit. On Herdr 0.8.2, that distinction is absent, so these commands are
agent-capable routes for threat-model purposes and cannot be called safe.

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
| Client-protocol attach/control bypass | `agent attach`, `terminal attach`, or `terminal session control` can use `herdr-client.sock`; `ControlTerminal` can reach a PTY through `terminal.input` without entering the JSON API gate. | The same source/target decision covers attach and control before session/input handling. A cross-workspace terminal target receives zero PTY input. |
| Human interactive attach/control | A 0.8.2 agent process can invoke the same writable client commands; socket mode 0600 distinguishes only OS users, not agent versus human. | Only a separately authenticated human capability may bypass normal delegation scope. If provenance cannot prove it is unavailable to agents, the route is not an exception and must be denied or same-workspace gated. |
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
| Herdr CLI, API server, and client-protocol server | The clients must preserve the bound context on both sockets. The server must resolve live pane ownership for agent, pane, terminal, and session targets, then centrally authorize every input route before API dispatch or PTY attach/input. | The server should not treat env vars, request `caller_pane_id`, UI focus, display metadata, terminal IDs, or a generic same-user socket as authentication. |

### Required implementation location

The hard boundary is outside this repository: the **Herdr server's shared
authorization decision point**, called by both the API request dispatcher in
the daemon behind `HERDR_SOCKET_PATH` and the client-protocol server behind
`herdr-client.sock`, with its agent-launcher or Pi integration as the source of
the authenticated pane context. In the 0.8.2 binary, the client-protocol
handler is in the upstream `src/server/headless.rs` implementation. The
affected Herdr 0.8.2 protocol-20 API input surface is:

- `agent.prompt`;
- `agent.send_keys`;
- `pane.send_text`;
- `pane.send_keys`;
- `pane.send_input`; and
- the `pane run` CLI convenience route, plus any future alias that dispatches
  input to a pane.

The affected client-protocol surface is:

- `herdr agent attach <target>`;
- `herdr terminal attach <terminal-id>`;
- `herdr terminal session control <target>`; and
- the programmatic `ClientMessage::ControlTerminal` /
  `terminal.input` flow through `attach_terminal_client` and
  `apply_terminal_attach_input`, plus any future writable client-protocol
  alias.

The upstream change should bind a source pane/workspace to the client
connection or an equivalent Herdr/Pi broker capability on **both** sockets. It
must reject absent or invalid source context rather than accepting a
caller-supplied replacement. After resolving an agent, pane, terminal, or
session target to its owning pane, it should apply the predicate above in one
shared gate before API dispatch, writable terminal attach, or PTY input.
Read-only inspection can remain broader; the gate is for machine-writable
input delivery.

If human interactive attach/control must remain able to cross workspaces, it
must use a separate client capability with human-session provenance that is not
available to an agent process. This is an upstream exception, not a normal
delegation route. Herdr 0.8.2 has no such agent/human isolation, so its current
attach/control commands provide no hard guarantee and cannot be treated as the
exception.

This is a deliberately small server-side authorization check, not a new
runtime: no persistent delegation graph, attempt IDs, queue, retry policy, or
cross-workspace state machine is required. A constrained dispatcher added only
to `agent-harness` or only to Pi would leave the raw Herdr routes as a bypass,
so it would not satisfy #131.

### Required upstream issue report (not filed)

This PR does not create an external issue. The required report is:

> **Herdr API/server: bind caller pane context and enforce same-workspace input authorization**
>
> In Herdr 0.8.2 (protocol 20), API input methods and the separate writable
> client protocol accept target pane/agent/terminal data without an
> authenticated caller pane. Add a connection- or broker-bound source context,
> reject missing/invalid context, and apply one centralized source/target
> workspace check before dispatch on both `$HERDR_SOCKET_PATH` and
> `herdr-client.sock`. Cover `agent.prompt`, agent/pane key/text/input routes,
> `pane run`, `agent attach`, `terminal attach`, `terminal session control`,
> and the `ClientMessage::ControlTerminal` -> `attach_terminal_client` ->
> `apply_terminal_attach_input` / `terminal.input` path, plus future aliases.
> The client-protocol handler currently lives in `src/server/headless.rs`; the
> API and client-protocol ingress must call the same authorization decision
> point before any PTY or agent input is applied.
> Add tests for env/caller-parameter spoofing, self/missing/moved targets, and a
> different workspace with an exact label/model match. Rejection must dispatch
> zero target/PTY input. If human cross-workspace attach/control is retained,
> make it a separate human-only capability that an agent process cannot invoke;
> the current 0.8.2 client socket does not provide that isolation. Advertise
> coverage for both protocols so clients can fail closed.

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
   caller context of the executing agent. The same gate must cover client
   protocol attach/control and `terminal.input`; a capability that covers only
   the API socket is insufficient. Clients without bound context must receive
   an error rather than an unauthenticated compatibility path for input
   delivery.
4. **Intentional cross-workspace work:** existing generic input callers must
   not retain an implicit exception. They must use the separately designed,
   human-authorized upstream operation, or be blocked. If interactive attach or
   control is kept for humans, its client capability must not be inherited by
   an agent process. This design does not migrate such callers automatically.
5. **No #132 coupling:** skill snapshot/distribution, reload, and rollback
   policy remain an independent follow-up and are not a prerequisite for this
   authorization predicate.

No wrapper, CLI, or helper behavior is changed by this issue's repository
implementation. The compatibility risk is the explicit upstream change from
unauthenticated input to required source context; that risk must be handled by
the upstream capability rollout, not hidden by weakening the boundary.

## Automatable test plan

The following tests belong in the Herdr upstream contract suite. They should
run against both the real API and client-protocol dispatchers (or faithful
socket-level fakes) with a dispatch spy that records whether any target input
bytes were emitted.

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
| `A:p1` -> terminal owned by `A:p2` through client protocol | allow | exactly one PTY input |
| `A:p1` -> terminal owned by `B:p1` through `ControlTerminal` | reject scope | zero PTY input |
| Child `B:p1` -> parent `B:p2` | allow same-workspace isolation case | exactly one input |
| Child `B:p1` -> claimed parent `A:p1` | reject scope | zero |

The exact-match test must be run even when the scoped candidate list for `A`
contains only the source pane. It proves that global discovery cannot turn
into cross-workspace delivery. Run the parent and child direction tests
separately; do not infer a direct-parent relationship from a same-workspace
allow.

### Route and bypass matrix

For every cross-workspace target, repeat the rejection test through each
available API route: `agent.prompt`, `agent.send_keys`, `pane.send_text`,
`pane.send_keys`, `pane.send_input`, and the `pane run` CLI alias. Repeat it
through the separate client-protocol socket using `agent attach`, `terminal
attach`, `terminal session control`, and a programmatic
`ClientMessage::ControlTerminal` carrying `terminal.input`. Resolve terminal
IDs and session targets back to their owning panes before applying the same
matrix. Repeat with the wrapper:

- wrapper executed successfully;
- wrapper not executed;
- wrapper unavailable;
- rejection predicted from its preflight; and
- wrapper rejection observed, followed by an attempted raw route.

Every raw attempt must hit the same server gate and produce zero target input.
The wrapper-not-run/unavailable cases must not be represented as successful
wrapper calls; the test is specifically checking that omission does not remove
server enforcement. Also assert that read-only global list/layout/focus data
does not change the authorization result. Instrument the PTY/input sink so the
client-protocol rejection is verified as zero bytes, not merely an error after
an attach was established. Add a separate provenance test showing that an
agent source cannot acquire the human-only attach/control capability; on
Herdr 0.8.2 this test should fail as an explicit compatibility finding rather
than being reported as a passing hard-boundary test.

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
