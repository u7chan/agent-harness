# Technical delegation boundary

This document defines the minimal technical contract required to enforce
workspace isolation for normal Herdr delegation.

`herdr/SKILL.md` remains authoritative for candidate selection and stop
conditions. [`async-delegation.md`](async-delegation.md) remains authoritative
for the wrapper protocol. Those operational rules reduce mistakes, but they do
not form a hard permission boundary by themselves.

## Decision

Normal delegation is **same-workspace only**.

This applies to:

- a new parent-to-child delegation;
- a follow-up sent to an existing child; and
- a child-to-parent result return.

A hard guarantee must be enforced by the component that ultimately dispatches
input or mutates the target. A skill instruction, wrapper, environment
variable, pane label, model name, or UI focus is not caller authentication.

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
  source.workspace_id == target.workspace_id
```

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
- UI focus or foreground state.

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
workspace. Self, missing, stale, or cross-workspace targets are rejected.

This isolation guarantee does not prove that the selected target is the
intended child. The skill remains responsible for candidate selection.

### Child to parent

A result return receives the same workspace-isolation guarantee in the reverse
direction.

This does not prove a direct-parent relationship. Introducing persisted
parent/child relationship state is outside this minimal boundary.

### Cross-workspace operations

Normal delegation has no cross-workspace exception.

If cross-workspace control is required later, it must be a separately designed
capability with explicit authorization and must not weaken the normal
delegation invariant. Human intent expressed in a prompt or environment
variable is not such a capability.

## Responsibility boundary

| Component | Responsibility |
| --- | --- |
| `herdr/SKILL.md` | Resolve candidates within the current workspace and stop safely when no valid candidate exists. |
| Delegation wrappers | Provide the normal operational path and lightweight preflight checks. |
| Herdr or a trusted broker | Bind authenticated source context, resolve the live target, and enforce the authorization invariant for every write-capable path. |

The wrappers may reject obvious workspace mismatches early, but that is a
convenience check. Raw access must receive the same authorization outcome as
the wrapper path.

## Minimal upstream contract

The enforcing component must provide these properties:

1. Bind an unforgeable source pane/workspace context to each write-capable
   request or connection.
2. Resolve the effective target to its current owning pane from authoritative
   state.
3. Apply the authorization invariant before any target input or mutation.
4. Cover all writable transports and future writable aliases by semantic
   policy, not by a repository-maintained allowlist of method names.
5. Fail closed when source context, target resolution, or authorization is
   unavailable.
6. Keep authorization/scope rejection distinguishable from transport failure.

Until these properties are provided by the enforcing runtime, this repository
must describe its skill and wrappers as operational safeguards rather than a
hard permission boundary.

## Compatibility and migration

The repository-side wrappers do not need new delegation state, retries,
queues, or relationship persistence for this boundary.

A compatible rollout should preserve their current calling contract while the
runtime begins requiring trusted source context for write-capable operations.
Clients that cannot provide trusted source context must fail rather than gain
an unauthenticated compatibility path.

Read-only discovery may remain broader than write authorization. Seeing a pane
in another workspace never authorizes writing to it.

## Acceptance examples

| Scenario | Required result |
| --- | --- |
| Source and target are distinct panes in the same workspace | allow |
| Target is in another workspace | reject with zero target write |
| Target is the source pane | reject with zero target write |
| Target is missing, stale, or moved across workspaces | reject or re-resolve; never cross-workspace write |
| Caller spoofs environment or request IDs | bound source identity wins or request is rejected |
| Wrapper is skipped and an equivalent raw write is attempted | same authorization decision applies |
| Destination is selected indirectly rather than supplied explicitly | resolve effective target and apply the same invariant |
| Child returns to a pane in another workspace | reject with zero target write |

These cases are sufficient to prove the isolation property. Route-specific
coverage belongs with the runtime implementation so that its tests evolve with
its actual writable surface.

## Non-goals

- adding a broad dispatcher to this repository;
- adding persistent delegation graphs, queues, retries, or state machines;
- authenticating a direct parent/child relationship;
- defining a cross-workspace delegation capability;
- maintaining a version-specific inventory of runtime methods or internal
  implementation symbols; and
- treating skill compliance or wrapper usage as a hard permission boundary.
