# Technical delegation boundary

This document defines the minimal technical contract required to enforce
workspace isolation within one Herdr server for normal Herdr delegation.

`herdr/SKILL.md` remains authoritative for candidate selection and stop
conditions. [`async-delegation.md`](async-delegation.md) remains authoritative
for the wrapper protocol. Those operational rules reduce mistakes, but they do
not form a hard permission boundary by themselves.

## Decision

Normal delegation is **same-server, same-workspace only**: the source and the
target belong to one Herdr server, and within it to one workspace.

This applies to:

- a new parent-to-child delegation;
- a follow-up sent to an existing child; and
- a child-to-parent result return.

A hard guarantee must be enforced by the component that ultimately dispatches
input or mutates the target. A skill instruction, wrapper, environment
variable, pane label, model name, or UI focus is not caller authentication.

## Threat model

Assume a same-user agent process can bypass the wrapper, invoke a raw writable
transport directly, spoof caller-controlled environment or request values, and
retry through an equivalent raw path when the wrapper is unavailable or
rejects. The boundary trusts the enforcing server's authoritative pane/workspace
state and an authenticated source identity bound to the transport or a trusted
broker; that identity includes the server the source pane belongs to. A
compromised enforcing server, or a user intentionally exercising
administrative authority over all workspaces, is outside this boundary.

## Authorization invariant

Every normal write-capable operation must be authorized from trusted,
server-side state immediately before the target mutation or input dispatch.

```text
source = authenticated pane context bound to this request or connection
target = current pane resolved from authoritative server state

allow iff
  source exists
  target exists
  source != target
  source.server_id == target.server_id
  source.workspace_id == target.workspace_id
```

The invariant compares server identity before workspace identity. The current
Herdr transport is server-local: one server owns and dispatches both panes, so
the enforcing server can evaluate `source.server_id == target.server_id`
against its own identity. The comparison is still part of the invariant. An
enforcing component that can act on more than one server, such as a trusted
broker, must represent server identity explicitly and keep it separate from
workspace identity, because different servers can expose the same workspace
ID. A workspace ID match alone never authorizes a write.

The invariant is semantic rather than API-name based. It applies regardless of
which command, API method, protocol message, alias, explicit target, implicit
focus, terminal mapping, or future writable route reaches the target.

A rejected request must produce no target input or target-side mutation.

## Source identity

The authorization source must be bound to the transport or to an equivalent
trusted broker capability. Caller-controlled values are hints at most and must
not establish identity.

In particular, the boundary must not trust these values as proof of the caller:

- `HERDR_WORKSPACE_ID` or `HERDR_PANE_ID`;
- a caller-supplied pane or workspace ID;
- a target ID or terminal ID;
- labels, agent metadata, or model names;
- UI focus or foreground state, including the machine selected in the Herdr
  TUI.

If trusted source context is absent or invalid, a write-capable operation must
fail closed rather than fall back to unauthenticated behavior.

## Target resolution and atomicity

The target must be resolved from current authoritative state at dispatch time.
A successful earlier lookup is not sufficient authorization if the target can
move, disappear, or resolve differently before the write.

Authorization and dispatch must therefore observe a consistent source/target
state. For operations whose destination is implicit, such as focus-based
input, resolve the effective destination as part of the same authorization
step.

The boundary does not choose a delegation target. Candidate selection remains
an agent-facing responsibility in `herdr/SKILL.md`.

## Guarantee scope

### Parent to child

A normal parent request may write only to another existing pane in the same
workspace on the same server. Self, missing, stale, cross-workspace, and
cross-server targets are rejected.

This isolation guarantee does not prove that the selected target is the
intended child. The skill remains responsible for candidate selection.

### Child to parent

A result return receives the same server-and-workspace isolation guarantee in
the reverse direction.

This does not prove a direct-parent relationship. Introducing persisted
parent/child relationship state is outside this minimal boundary.

### Cross-workspace and cross-server operations

Normal delegation has no cross-workspace exception and no cross-server
exception. A target on another server is outside normal delegation even when
its workspace ID matches the source's.

If cross-workspace or cross-machine control is required later, it must be a
separately designed capability with explicit authorization and must not weaken
the normal delegation invariant. It must be separately authenticated and must
not be invocable or inheritable by an agent process. Human intent expressed in
a prompt or environment variable is not such a capability.

## Responsibility boundary

| Component | Responsibility |
| --- | --- |
| `herdr/SKILL.md` | Resolve candidates within the current server's current workspace and stop safely when no valid candidate exists. |
| Delegation wrappers | Provide the normal operational path and lightweight preflight checks. |
| Herdr or a trusted broker | Bind authenticated source context, resolve the live target, and enforce the authorization invariant for every write-capable path. |

The wrappers may reject obvious workspace mismatches early, but that is a
convenience check. Raw access must receive the same authorization outcome as
the wrapper path.

## Minimal upstream contract

The enforcing component must provide these properties:

1. Bind an unforgeable source server/pane/workspace context to each
   write-capable request or connection.
2. Resolve the effective target — its server and current owning pane — from
   authoritative state.
3. Apply the authorization invariant before any target input or mutation.
4. Cover all writable transports and future writable aliases by semantic
   policy, not by a repository-maintained allowlist of method names.
5. Fail closed when source context, target resolution, or authorization is
   unavailable.
6. Keep authorization/scope rejection distinguishable from transport failure.

Until these properties are provided by the enforcing runtime, this repository
must describe its skill and wrappers as operational safeguards rather than a
hard permission boundary.

## Upstream dependency

The enforcing runtime is upstream Herdr (github.com/herdrdev/herdr). Items 1
and 3 of u7chan/agent-harness#208 — delegation from a parent workspace into a
worktree workspace team, and enforcement of the workspace boundary by the
runtime rather than by model compliance — cannot be satisfied in this
repository until the runtime provides two capabilities:

1. **An authorized delegation scope evaluated from trusted source context.**
   The scope must come from server-side state, not from the caller's
   environment: for example, worktree-creator ownership recorded server-side,
   or a human-only `herdr scope grant` / `herdr scope revoke` that an agent
   process cannot invoke or inherit. Scope rejection must also stay
   distinguishable from transport failure (property 6 of [Minimal upstream
   contract](#minimal-upstream-contract)). This is what items 1 and 3 of #208
   require together: with a scope evaluated from trusted source context, the
   runtime can allow the authorized parent-to-worktree-team edge and reject a
   raw bypass by the same rule.
2. **`herdr worktree remove --path <path>`.** A closed worktree workspace
   currently has to be reopened before it can be removed, because removal
   keys on a live workspace ID.

Verified upstream state as of herdr 0.9.0 (measured 2026-09-14 against the
installed `herdr` 0.9.0 binary, API protocol 22):

- No server-side scope or authorization surface exists. `herdr --help` lists
  no scope or authorization command, and the 0.9.0 API schema
  (`herdr api schema --json`, protocol 22) defines no caller-identity or
  delegation-scope parameter for the write-capable routes normal delegation
  uses: `AgentPromptParams` carries only `target`, `text`, and `wait`, and
  `AgentStartParams` only `args`, `kind`, `name`, `pane_id`, and `timeout_ms`.
  Upstream `src/app/api/agents.rs` at tag `v0.9.0` resolves the prompt target
  from the request alone and consults no caller or source workspace identity
  (https://github.com/herdrdev/herdr/blob/v0.9.0/src/app/api/agents.rs).
- `herdr agent start` rejects a multi-line AGENT_ARG with
  `{"error":{"code":"invalid_agent_argument","message":"agent arguments cannot be encoded safely for the target shell"},"id":"cli:agent:start"}`.
- `herdr agent prompt` accepts `<TARGET> <TEXT>` only; it has no file or stdin
  input. The upstream request to add one (herdrdev/herdr#3367) was closed as
  not planned on 2026-08-29, with the response that the required `<text>`
  argument stays the accepted input and the proposal belongs in Ideas
  discussions, so prompt text must travel as a shell argument
  (https://github.com/herdrdev/herdr/issues/3367).
- `herdr worktree remove` accepts `--workspace <ID>` but not `--path`
  (`unknown option: --path`, exit status 2). Closing the linked workspace
  makes `herdr worktree list` omit `open_workspace_id`, and removal by the old
  workspace ID fails with `workspace_not_found`; `herdr worktree open` then
  assigns a new workspace ID.

Until those capabilities exist, this repository remains an operational
safeguard, not a permission boundary: its wrapper checks stop a conforming
agent only, and a raw cross-workspace write still succeeds. Worktree
workspaces are therefore outside normal delegation, and the interim procedure
in [worktree-workspace-teams.md](worktree-workspace-teams.md) starts and
drives those teams through the user and GitHub comments instead of
cross-workspace prompts.

## Compatibility and migration

The repository-side wrappers do not need new delegation state, retries,
queues, or relationship persistence for this boundary.

A compatible rollout should preserve their current calling contract while the
runtime begins requiring trusted source context for write-capable operations.
Clients that cannot provide trusted source context must fail rather than gain
an unauthenticated compatibility path.

Read-only discovery may remain broader than write authorization. Seeing a pane
in another workspace, or a matching pane or workspace ID on another server,
never authorizes writing to it.

## Acceptance examples

| Scenario | Required result |
| --- | --- |
| Source and target are distinct panes in the same workspace on the same server | allow |
| Target is in another workspace on the same server | reject with zero target write |
| Same workspace ID, different server | reject with zero target write |
| Target is the source pane | reject with zero target write |
| Target is missing, stale, or moved across workspaces | reject or re-resolve; never cross-workspace write |
| Caller spoofs environment or request IDs | bound source identity wins or request is rejected |
| Wrapper is skipped, unavailable, or its rejection is followed by an equivalent raw write | same authorization decision applies |
| Destination is selected indirectly rather than supplied explicitly | resolve effective target and apply the same invariant |
| Child returns to a pane in another workspace | reject with zero target write |

These cases are sufficient to prove the isolation property. Route-specific
coverage belongs with the runtime implementation so that its tests evolve with
its actual writable surface.

## Non-goals

- adding a broad dispatcher to this repository;
- adding persistent delegation graphs, queues, retries, or state machines;
- authenticating a direct parent/child relationship;
- defining a cross-workspace or cross-server delegation capability;
- maintaining a version-specific inventory of runtime methods or internal
  implementation symbols; and
- treating skill compliance or wrapper usage as a hard permission boundary.
