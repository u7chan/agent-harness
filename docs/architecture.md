# Architecture

This repository keeps agent judgment in skills and implements only deterministic or safety-critical behavior as code.

```text
User intent
    ↓
SKILL.md
    ↓
Action catalog / schema
    ↓
Dispatcher / validation
    ↓
CLI / API
```

Not every skill needs every layer. Start with an instruction-only skill and add a tool harness only when the task requires deterministic validation, permission boundaries, or API handling.

## Responsibilities

Keep the following in `SKILL.md`:

- task decomposition;
- action or agent selection;
- context-dependent continue or stop decisions;
- review criteria;
- workflows.

Implement the following in scripts, schemas, or tests:

- input validation and permission classification;
- CLI and API argument construction;
- pagination;
- timeout and retry conditions;
- post-write verification;
- shared output contracts;
- protection against duplicate execution and unsafe operations.

## Repository structure

Every skill starts with a single required file:

```text
<skill>/
  SKILL.md
```

Add supporting files only when they have a concrete responsibility:

```text
<skill>/
  SKILL.md
  actions.json
  references/
  scripts/
  tests/
```

Instruction-only skills use natural-language judgment and existing tools directly. Tool harnesses add schemas, validation, and constrained dispatch for operations whose results must be predictable.

## Design constraints

- Keep `SKILL.md` minimal. Put deterministic validation and tool constraints in scripts or schemas.
- Keep one authoritative source for each definition; derive or validate every other representation from it.
- Prefer small, constrained actions over exposing raw CLI or API operations.
- Do not infer success or failure from an unknown execution result.
- Do not add a custom runtime, state machine, persistence layer, or broad dispatcher unless an Issue explicitly requires it.
- Prefer the smallest change that preserves existing contracts.
- Implement what can be maintained, not everything that could be automated.
