---
name: kabeuchi
description: Refine an idea, plan, or decision one question at a time and converge on the smallest sufficient design. Use when asked to kabeuchi, grill an idea, brainstorm, or make a plan.
---

# Kabeuchi

Drive shared understanding by challenging only the decisions needed to achieve the requested outcome. Resolve dependent decisions from upstream to downstream while keeping the agreed scope as small as practical.

## Language

Use the response language required by active instructions or explicitly requested by the user. If neither specifies a language, use the primary language of the conversation. Treat skill names, commands, and short trigger phrases such as `kabeuchi` and `grill start` as language-neutral.

## Rules

- Ask exactly one question at a time and wait for the user's answer before continuing.
- Include concrete options, a recommended option, and a brief reason for the recommendation with every question.
- Mark the recommended option with a natural translation of `(Recommended 💡)` in the response language.
- Ask only questions whose answers can materially change the agreed outcome, implementation scope, or proof of completion.
- Resolve upstream dependencies before asking about downstream decisions.
- Investigate facts available in files, code, tools, and the conversation yourself instead of asking the user for discoverable facts.
- Separate facts from decisions. Present one decision at a time, give a recommendation, and leave the choice to the user.
- After each answer, update the settled decisions, open questions, contradictions, deferred ideas, and next branch.
- Do not implement, edit files, or make external changes until the user confirms the shared understanding.

## Scope discipline

Kabeuchi is a convergence process, not an exhaustive design exercise.

- Optimize for the smallest design that satisfies the agreed goal, completion evidence, and constraints.
- Before exploring a decision or proposing work, ask: `Would omitting this prevent the agreed completion evidence from being satisfied?` If not, omit or defer it.
- Do not explore a branch merely because it could matter in the future.
- Do not introduce extensibility, configurability, indirection, generalization, plugin systems, or new abstractions without a concrete current requirement.
- Prefer existing project conventions and mechanisms over inventing new ones.
- Prioritize irreversible or expensive-to-change decisions. Defer reversible implementation details unless they block progress.
- Treat every additional component, layer, configuration option, dependency, and extension point as complexity that must justify itself against the current goal.
- If an answer expands the agreed scope, call out the scope increase explicitly and ask whether it belongs in the current task instead of silently incorporating it.
- If the resulting change no longer looks focused, first remove or defer nonessential scope. Split work only when the remaining required scope is inherently separable.
- Stop as soon as there is enough shared understanding to implement and verify the agreed scope. Do not continue because additional design choices still exist.

## Question format

Use this format, adapting its language to the user:

```text
Question {number}: {question}

Options:

1. {option A} (Recommended 💡)
2. {option B}
3. {option C}

Recommendation:
{brief reason}
```

Offer only the options needed for a meaningful choice; do not add filler options. When the options materially differ in implementation scope, briefly state the scope impact in the recommendation.

## Workflow

1. Establish the minimum framing needed for the task:
   - Goal: what must become true.
   - Done: observable evidence that proves the goal is met.
   - Constraints: boundaries that must be respected.
   - Non-goals: work explicitly outside the current task.
   Use known context first and ask only for missing information that can change the outcome.
2. Identify only unresolved decisions required to reach Done. Order them by dependency and prioritize irreversible or costly decisions.
3. Ask the highest-impact unresolved question. Recommend the simplest option that satisfies the current requirements.
4. Incorporate the user's answer and reassess:
   - Is each remaining question required for Done?
   - Did the answer expand scope?
   - Can any remaining decision be safely deferred?
5. Repeat only while a required decision remains. Do not attempt to eliminate all uncertainty.
6. Before finalizing, run a scope check:
   - Does every included element directly support Goal, Done, or a stated constraint?
   - Is speculative future-proofing present?
   - Can the scope be reduced without weakening Done?
   Remove or defer anything unnecessary.
7. Summarize the shared understanding as:
   - Goal
   - Done
   - In scope
   - Non-goals
   - Decisions
   - Deferred ideas
   - Remaining risks or uncertainty
8. Ask the user to confirm the shared understanding. After confirmation, return the agreed understanding and stop. Wait for a separate request before executing it.
