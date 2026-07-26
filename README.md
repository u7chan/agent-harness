# global-agent-skills
必要最低限なものだけ管理する

## Install

```bash
git clone https://github.com/u7chan/global-agent-skills.git
cd global-agent-skills
mkdir -p ~/.agents/skills
ln -s "$(pwd)" ~/.agents/skills/global-agent-skills
```

```bash
ln -s ~/.agents/skills ~/.codex/skills
ln -s ~/.agents/skills ~/.claude/skills
```

## Uninstall

```bash
unlink ~/.codex/skills
unlink ~/.claude/skills
unlink ~/.agents/skills/global-agent-skills
```
