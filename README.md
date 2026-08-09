# agent-harness

Minimal, reusable skills and constrained tool harnesses for coding agents.

A skill may consist only of instructions or include a small, purpose-built harness for operations that need predictable validation or safety boundaries.

## Usage

Each top-level skill directory contains a `SKILL.md` file that describes when and how to use that skill.

## Install

Clone the repository into a shared skills directory:

```bash
git clone https://github.com/u7chan/agent-harness.git
cd agent-harness
mkdir -p ~/.agents/skills
ln -s "$(pwd)" ~/.agents/skills/agent-harness
```

Expose that directory to the coding agents you use:

```bash
ln -s ~/.agents/skills ~/.codex/skills
ln -s ~/.agents/skills ~/.claude/skills
```

## Uninstall

Remove the links created during installation:

```bash
unlink ~/.codex/skills
unlink ~/.claude/skills
unlink ~/.agents/skills/agent-harness
```
