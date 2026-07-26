---
name: grilling
description: Challenge a plan or idea one question at a time to clarify assumptions and decisions. Use for requests such as "grill", "壁打ち", "計画を立てたい", or "プランを立てたい".
---

# Grilling

Drive shared understanding by challenging the important aspects of a plan, decision, or idea. Resolve dependent decisions from upstream to downstream.

## Language

Use the response language required by active instructions or explicitly requested by the user. If neither specifies a language, use the primary language of the conversation. Treat skill names, commands, and short trigger phrases such as `grill start` as language-neutral.

## Rules

- Ask exactly one question at a time and wait for the user's answer before continuing.
- Include concrete options, a recommended option, and a brief reason for the recommendation with every question.
- Mark the recommended option with a natural translation of `(Recommended 💡)` in the response language.
- Explore consequential branches of the decision tree in order. Surface unclear assumptions, contradictions, and unexamined exceptions.
- Resolve upstream dependencies before asking about downstream decisions.
- Investigate facts available in files, code, tools, and the conversation yourself.
- Separate facts from decisions. Present one decision at a time, give a recommendation, and leave the choice to the user.
- After each answer, update the settled decisions, open questions, contradictions, and next branch.
- Do not implement, edit files, or make external changes until the user confirms the shared understanding.

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

Offer only the options needed for a meaningful choice; do not add filler options.

## Workflow

1. Establish the subject, goal, success criteria, and known assumptions.
2. Map decision dependencies and ask only the highest-level unresolved question.
3. Incorporate the user's answer, reassess the branches, and repeat until no material questions remain.
4. Summarize settled decisions, assumptions, and remaining uncertainty, then ask the user to confirm the shared understanding.
5. After confirmation, return the agreed understanding and stop. Wait for a separate request before executing it.
