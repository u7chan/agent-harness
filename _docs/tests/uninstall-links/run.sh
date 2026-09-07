#!/usr/bin/env bash
# Safety verification for the documented Uninstall procedure in README.md.
#
# Builds an isolated temporary HOME whose skill layout mixes parent skill
# directories, parent symlinks, other harnesses' content, and `agent-harness`
# links created by this package, then executes the exact link-removal snippet
# extracted from the README Uninstall section. It asserts that only the
# package's own links disappear and that parent directories, parent symlinks,
# and every other skill survive. All fixtures are synthetic; nothing outside
# the temporary directory is touched (HOME is redirected for the run).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
README="$SCRIPT_DIR/../../../README.md"
TEST_TMP="$(mktemp -d /tmp/uninstall-links-XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

pass_count=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_ok() {
  local name="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    echo "FAIL: $name" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

expect_dir() {
  local name="$1" path="$2"
  if [ ! -d "$path" ]; then
    echo "FAIL: $name: $path is not a directory" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

expect_symlink() {
  local name="$1" path="$2"
  if [ ! -L "$path" ]; then
    echo "FAIL: $name: $path is not a symlink" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

expect_absent() {
  local name="$1" path="$2"
  if [ -e "$path" ] || [ -L "$path" ]; then
    echo "FAIL: $name: $path still exists" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

# --- Extract the documented link-removal snippet from the README Uninstall
# --- section. The test stays coupled to the documented procedure: if the
# --- README no longer has exactly one such block, this fails loudly.
SECTION="$TEST_TMP/section.md"
awk '/^## Uninstall$/{insec=1; next} insec && /^## /{exit} insec{print}' "$README" > "$SECTION"
awk -v RS='```' -v out="$TEST_TMP" 'NR%2==0 {f=sprintf("%s/block-%02d.sh", out, NR/2); print > f}' "$SECTION"

UNLINK_BLOCK=""
for f in "$TEST_TMP"/block-*.sh; do
  if grep -q 'unlink' "$f"; then
    if [ -n "$UNLINK_BLOCK" ]; then
      fail "README Uninstall section has more than one block mentioning unlink"
    fi
    UNLINK_BLOCK="$f"
  fi
done
if [ -z "$UNLINK_BLOCK" ]; then
  fail "README Uninstall section has no block mentioning unlink"
fi
grep -q 'agent-harness' "$UNLINK_BLOCK" || fail "README uninstall block does not cover agent-harness links"
grep -q '\[ -L ' "$UNLINK_BLOCK" || fail "README uninstall block lost the -L guard"
if grep -q 'pi remove' "$UNLINK_BLOCK"; then
  fail "README uninstall block mixes 'pi remove' into the link-removal snippet"
fi
pass_count=$((pass_count + 1))

# Run the extracted README snippet against an isolated HOME.
run_documented_uninstall() {
  local home="$1"
  (cd "$TEST_TMP" && env HOME="$home" bash "$UNLINK_BLOCK")
}

# --- Fixture: shared skill layout modeled on the reference machine.
# --- Mixed content: package leaf link (dangling, as after `pi remove`),
# --- other skill directories, a foreign symlink, a parent symlink for
# --- Claude, and a real Codex directory with its own content.
make_shared_layout() {
  local root="$1"
  mkdir -p "$root/.agents/skills" "$root/.claude" "$root/.codex/skills/.system"
  ln -s "$root/no-such-clone" "$root/.agents/skills/agent-harness"
  mkdir -p "$root/.agents/skills/other-skill"
  echo x > "$root/.agents/skills/other-skill/SKILL.md"
  ln -s "$root/foreign-target" "$root/.agents/skills/other-link"
  ln -s ../.agents/skills "$root/.claude/skills"
  echo x > "$root/.codex/skills/.system/marker"
  mkdir -p "$root/.codex/skills/other-codex-skill"
  ln -s ../../.agents/skills "$root/.codex/skills/skills"
}

# Scenario 1: full mixed layout; the documented procedure removes only the
# package's own link and keeps everything else. A re-run is a quiet no-op.
HOME1="$TEST_TMP/home-main"
make_shared_layout "$HOME1"
expect_symlink "precondition: agent-harness link present" "$HOME1/.agents/skills/agent-harness"
out="$(run_documented_uninstall "$HOME1" 2>&1)" || fail "documented uninstall failed: $out"
if [ -n "$out" ]; then
  fail "documented uninstall produced unexpected output: $out"
fi
pass_count=$((pass_count + 1))
expect_absent "package leaf link removed" "$HOME1/.agents/skills/agent-harness"
expect_absent "package leaf link removed through claude alias" "$HOME1/.claude/skills/agent-harness"
expect_dir "shared parent directory kept" "$HOME1/.agents/skills"
expect_symlink "claude parent symlink kept" "$HOME1/.claude/skills"
expect_ok "claude parent symlink target unchanged" test "$(readlink "$HOME1/.claude/skills")" = "../.agents/skills"
expect_dir "other skill directory kept" "$HOME1/.agents/skills/other-skill"
expect_ok "other skill content kept" test -f "$HOME1/.agents/skills/other-skill/SKILL.md"
expect_symlink "foreign symlink kept" "$HOME1/.agents/skills/other-link"
expect_dir "codex skill directory kept" "$HOME1/.codex/skills"
expect_ok "codex own content kept" test -f "$HOME1/.codex/skills/.system/marker"
expect_symlink "codex nested skills symlink kept" "$HOME1/.codex/skills/skills"
out="$(run_documented_uninstall "$HOME1" 2>&1)" || fail "second run failed: $out"
if [ -n "$out" ]; then
  fail "second run produced unexpected output: $out"
fi
pass_count=$((pass_count + 1))
expect_absent "still absent after second run" "$HOME1/.agents/skills/agent-harness"
expect_dir "other skill directory kept after second run" "$HOME1/.agents/skills/other-skill"

# Scenario 2: no package links present (fresh machine or already uninstalled).
# Missing links are skipped; nothing else changes.
HOME2="$TEST_TMP/home-clean"
make_shared_layout "$HOME2"
rm "$HOME2/.agents/skills/agent-harness"
out="$(run_documented_uninstall "$HOME2" 2>&1)" || fail "clean-layout run failed: $out"
if [ -n "$out" ]; then
  fail "clean-layout run produced unexpected output: $out"
fi
pass_count=$((pass_count + 1))
expect_dir "shared parent directory kept (clean)" "$HOME2/.agents/skills"
expect_symlink "claude parent symlink kept (clean)" "$HOME2/.claude/skills"
expect_dir "other skill directory kept (clean)" "$HOME2/.agents/skills/other-skill"
expect_symlink "foreign symlink kept (clean)" "$HOME2/.agents/skills/other-link"
expect_ok "codex content kept (clean)" test -f "$HOME2/.codex/skills/.system/marker"

# Scenario 3: no shared ~/.agents/skills at all; the package link lives in a
# real ~/.claude/skills directory next to an unrelated skill. The absent
# parent path is skipped quietly and the leaf under ~/.claude is removed.
HOME3="$TEST_TMP/home-claude-only"
mkdir -p "$HOME3/.claude/skills"
ln -s "$HOME3/no-such-clone" "$HOME3/.claude/skills/agent-harness"
mkdir -p "$HOME3/.claude/skills/unrelated-skill"
echo x > "$HOME3/.claude/skills/unrelated-skill/SKILL.md"
out="$(run_documented_uninstall "$HOME3" 2>&1)" || fail "claude-only run failed: $out"
if [ -n "$out" ]; then
  fail "claude-only run produced unexpected output: $out"
fi
pass_count=$((pass_count + 1))
expect_absent "leaf under claude removed" "$HOME3/.claude/skills/agent-harness"
expect_dir "claude skills directory kept" "$HOME3/.claude/skills"
expect_ok "unrelated skill kept" test -f "$HOME3/.claude/skills/unrelated-skill/SKILL.md"
if [ -e "$HOME3/.agents" ]; then
  fail "missing shared parent directory was created"
fi
pass_count=$((pass_count + 1))

# Scenario 4: legacy layout where ~/.codex/skills itself is a symlink to the
# shared directory (created by the pre-package install). The documented
# procedure must keep that parent symlink and remove only the leaf link.
HOME4="$TEST_TMP/home-legacy-codex"
mkdir -p "$HOME4/.agents/skills" "$HOME4/.claude" "$HOME4/.codex"
ln -s "$HOME4/no-such-clone" "$HOME4/.agents/skills/agent-harness"
ln -s ../.agents/skills "$HOME4/.codex/skills"
ln -s ../.agents/skills "$HOME4/.claude/skills"
out="$(run_documented_uninstall "$HOME4" 2>&1)" || fail "legacy-codex run failed: $out"
pass_count=$((pass_count + 1))
expect_absent "package leaf link removed (legacy)" "$HOME4/.agents/skills/agent-harness"
expect_symlink "codex parent symlink kept (legacy)" "$HOME4/.codex/skills"
expect_ok "codex parent symlink target unchanged" test "$(readlink "$HOME4/.codex/skills")" = "../.agents/skills"
expect_symlink "claude parent symlink kept (legacy)" "$HOME4/.claude/skills"
expect_dir "shared parent directory kept (legacy)" "$HOME4/.agents/skills"

# Scenario 5: the leaf position holds a real directory (for example a plain
# clone), not a symlink. The -L guard must leave it untouched.
HOME5="$TEST_TMP/home-real-dir"
mkdir -p "$HOME5/.agents/skills/agent-harness"
echo keep > "$HOME5/.agents/skills/agent-harness/SKILL.md"
out="$(run_documented_uninstall "$HOME5" 2>&1)" || fail "real-dir run failed: $out"
if [ -n "$out" ]; then
  fail "real-dir run produced unexpected output: $out"
fi
pass_count=$((pass_count + 1))
expect_dir "real agent-harness directory kept" "$HOME5/.agents/skills/agent-harness"
expect_ok "real directory content untouched" test -f "$HOME5/.agents/skills/agent-harness/SKILL.md"

echo "PASS: $pass_count uninstall-link safety cases"
