#!/usr/bin/env bash
# Hermetic tests for the harness-neutral distribution command.
#
# Each case builds throwaway git repositories under a temporary directory and
# drives dist.sh against them through file:// URLs.  Nothing touches the real
# distribution root, the network, or any harness CLI.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$SCRIPT_DIR/../skill-distribution/dist.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/skill-distribution-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# The default link directory is $HOME/.agents/skills, so HOME stays inside the
# temporary tree: a case that omits --link-dir must not touch the caller's own
# skill directories.
export HOME="$WORK/home"
mkdir -p "$HOME/.agents/skills"

PASS=0
FAIL=0

ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
ng() { printf 'FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

check_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$name"; else ng "$name" "got '$got', want '$want'"; fi
}

check_contains() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) ok "$name" ;;
    *) ng "$name" "expected to find '$needle' in: $hay" ;;
  esac
}

check_absent_path() {
  local name="$1" path="$2"
  if [ -e "$path" ] || [ -L "$path" ]; then ng "$name" "$path exists"; else ok "$name"; fi
}

command -v git >/dev/null 2>&1 || {
  printf 'FAIL: git is required\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'FAIL: jq is required\n' >&2
  exit 1
}

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

seed_repo() {
  local repo="$1"
  mkdir -p "$repo/alpha" "$repo/beta" "$repo/_docs" "$repo/scripts"
  printf '# alpha\n' >"$repo/alpha/SKILL.md"
  printf '# beta\n' >"$repo/beta/SKILL.md"
  printf 'notes\n' >"$repo/_docs/notes.md"
  printf '#!/usr/bin/env bash\necho hi\n' >"$repo/scripts/tool.sh"
  chmod +x "$repo/scripts/tool.sh"
  printf '{"schema_version":1,"skills":["alpha","beta"]}\n' >"$repo/skills.json"
}

new_origin() {
  local name="$1"
  ORIGIN="$WORK/$name.git"
  SOURCE="$WORK/$name-src"
  git init -q --bare "$ORIGIN"
  git init -q -b main "$SOURCE"
  git -C "$SOURCE" remote add origin "$ORIGIN"
  seed_repo "$SOURCE"
  git -C "$SOURCE" add -A
  git -C "$SOURCE" commit -q -m 'fixture: initial skills'
  git -C "$SOURCE" push -q origin main
  FIRST_SHA="$(git -C "$SOURCE" rev-parse HEAD)"
}

run_dist() {
  OUT="$(AGENT_HARNESS_HOME="$ROOT_DIR" AGENT_HARNESS_REPO_URL="$REPO_URL" \
    bash "$DIST" "$@" 2>&1)"
  STATUS=$?
}

# --- 1. First install -------------------------------------------------------
new_origin first
ROOT_DIR="$WORK/dist-first"
LINKS="$WORK/links-first"
mkdir -p "$LINKS"
REPO_URL="file://$ORIGIN"

run_dist update --link-dir "$LINKS" --pr https://example.invalid/pr/1
check_eq "first install exits 0" "$STATUS" 0
check_contains "first install reports the revision" "$OUT" "revision=$FIRST_SHA"
check_contains "first install reports a new release" "$OUT" "release=created"
check_eq "current points at the release" "$(readlink -f "$ROOT_DIR/current")" "$ROOT_DIR/releases/$FIRST_SHA"
check_absent_path "release tree carries no .git" "$ROOT_DIR/releases/$FIRST_SHA/.git"
check_eq "release keeps the executable bit" \
  "$([ -x "$ROOT_DIR/releases/$FIRST_SHA/scripts/tool.sh" ] && echo yes)" "yes"
check_eq "link target is stable across releases" "$(readlink "$LINKS/alpha")" "$ROOT_DIR/current/alpha"
check_eq "linked skill resolves" "$([ -f "$LINKS/alpha/SKILL.md" ] && echo yes)" "yes"
check_eq "relative ../ reference resolves through the link" \
  "$([ -f "$LINKS/alpha/../_docs/notes.md" ] && echo yes)" "yes"
check_eq "record has one line" "$(wc -l <"$ROOT_DIR/rollout.jsonl" | tr -d ' ')" "1"
check_eq "first record line has no previous" \
  "$(jq -r '.previous' "$ROOT_DIR/rollout.jsonl")" "null"
check_eq "first record keeps the PR URL" \
  "$(jq -r '.pr' "$ROOT_DIR/rollout.jsonl")" "https://example.invalid/pr/1"
check_eq "record mode is 0600" "$(stat -c '%a' "$ROOT_DIR/rollout.jsonl")" "600"

run_dist status --link-dir "$LINKS"
check_eq "status exits 0 after install" "$STATUS" 0
check_contains "status reports installed" "$OUT" "installed=yes"
check_contains "status matches the record" "$OUT" "record-match=yes"
check_contains "status reports consistent links" "$OUT" "links=ok"

run_dist verify --expect "$FIRST_SHA" --link-dir "$LINKS"
check_eq "verify exits 0 after install" "$STATUS" 0
check_contains "verify reports the expected revision" "$OUT" "revision=$FIRST_SHA"

# --- 2. Same revision re-run ------------------------------------------------
run_dist update --link-dir "$LINKS"
check_eq "re-run exits 0" "$STATUS" 0
check_contains "re-run is idempotent" "$OUT" "state=already-current"
check_eq "re-run appends no record line" "$(wc -l <"$ROOT_DIR/rollout.jsonl" | tr -d ' ')" "1"

# --- 3. New revision --------------------------------------------------------
mkdir -p "$SOURCE/gamma"
printf '# gamma\n' >"$SOURCE/gamma/SKILL.md"
printf '{"schema_version":1,"skills":["alpha","beta","gamma"]}\n' >"$SOURCE/skills.json"
git -C "$SOURCE" add -A
git -C "$SOURCE" commit -q -m 'fixture: add gamma'
git -C "$SOURCE" push -q origin main
SECOND_SHA="$(git -C "$SOURCE" rev-parse HEAD)"

run_dist update --link-dir "$LINKS"
check_eq "new revision exits 0" "$STATUS" 0
check_contains "new revision is served" "$OUT" "revision=$SECOND_SHA"
check_contains "new revision names the previous one" "$OUT" "previous=$FIRST_SHA"
check_eq "new revision creates a link" "$([ -f "$LINKS/gamma/SKILL.md" ] && echo yes)" "yes"
check_eq "old release is retained for rollback" \
  "$([ -d "$ROOT_DIR/releases/$FIRST_SHA" ] && echo yes)" "yes"
check_eq "record has two lines" "$(wc -l <"$ROOT_DIR/rollout.jsonl" | tr -d ' ')" "2"

# --- 4. Offline rollback ----------------------------------------------------
# The fetch source is unreachable: the release already on disk must be enough.
REPO_URL="file://$WORK/unreachable.git"
run_dist rollback "$FIRST_SHA" --link-dir "$LINKS"
check_eq "offline rollback exits 0" "$STATUS" 0
check_contains "offline rollback reports the state" "$OUT" "state=rolled-back"
check_contains "offline rollback serves the old revision" "$OUT" "revision=$FIRST_SHA"
check_eq "rollback drops the link of a removed skill" \
  "$(readlink "$LINKS/gamma" 2>/dev/null || echo absent)" "absent"
check_eq "record has three lines" "$(wc -l <"$ROOT_DIR/rollout.jsonl" | tr -d ' ')" "3"
check_eq "rollback line keeps the chain" \
  "$(jq -r 'select(.sha != null) | .sha' "$ROOT_DIR/rollout.jsonl" | sed -n '3p')" "$FIRST_SHA"

run_dist verify --expect "$FIRST_SHA" --link-dir "$LINKS"
check_eq "verify exits 0 after offline rollback" "$STATUS" 0

# --- 5. Network failure -----------------------------------------------------
# The fetch source stays the same but disappears: this is an outage, not a
# configuration change.
new_origin outage
ROOT_DIR="$WORK/dist-outage"
LINKS="$WORK/links-outage"
mkdir -p "$LINKS"
REPO_URL="file://$ORIGIN"
run_dist update --link-dir "$LINKS"
check_eq "install before the outage exits 0" "$STATUS" 0
mv "$ORIGIN" "$ORIGIN.offline"
run_dist update --link-dir "$LINKS"
check_eq "unreachable fetch fails" "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
check_contains "unreachable fetch reports the cause" "$OUT" "fetch failed"
check_eq "failed fetch keeps the served revision" "$(readlink -f "$ROOT_DIR/current")" \
  "$ROOT_DIR/releases/$FIRST_SHA"
check_eq "failed fetch appends no record line" \
  "$(wc -l <"$ROOT_DIR/rollout.jsonl" | tr -d ' ')" "1"
run_dist verify --expect "$FIRST_SHA" --link-dir "$LINKS"
check_eq "failed fetch leaves a verifiable install" "$STATUS" 0

FRESH_ROOT="$WORK/dist-fresh"
ROOT_DIR="$FRESH_ROOT"
run_dist update
check_eq "first install without reachable source fails" \
  "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
check_absent_path "failed first install serves nothing" "$FRESH_ROOT/current"
check_absent_path "failed first install writes no record" "$FRESH_ROOT/rollout.jsonl"

# --- 6. Verification failure ------------------------------------------------
new_origin broken
git -C "$SOURCE" rm -q beta/SKILL.md
git -C "$SOURCE" commit -q -m 'fixture: drop SKILL.md but keep the manifest'
git -C "$SOURCE" push -q origin main
BROKEN_SHA="$(git -C "$SOURCE" rev-parse HEAD)"

ROOT_DIR="$WORK/dist-broken"
LINKS="$WORK/links-broken"
mkdir -p "$LINKS"
REPO_URL="file://$ORIGIN"
run_dist update --link-dir "$LINKS"
check_eq "broken release fails" "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
check_contains "broken release names the cause" "$OUT" "release verification failed"
check_absent_path "broken release is not served" "$ROOT_DIR/current"
check_eq "broken release leaves no release directory" \
  "$([ -d "$ROOT_DIR/releases/$BROKEN_SHA" ] && echo yes || echo no)" "no"

# --- 7. Main-ancestry gate --------------------------------------------------
new_origin gated
git -C "$SOURCE" checkout -q -b side
printf 'side\n' >"$SOURCE/alpha/SIDE"
git -C "$SOURCE" add -A
git -C "$SOURCE" commit -q -m 'fixture: side commit'
git -C "$SOURCE" push -q origin side
SIDE_SHA="$(git -C "$SOURCE" rev-parse HEAD)"

ROOT_DIR="$WORK/dist-gated"
REPO_URL="file://$ORIGIN"
run_dist update --no-link
check_eq "install from main succeeds" "$STATUS" 0
# Make the side commit resolvable in the mirror, then try to serve it.
git -C "$ROOT_DIR/git" fetch -q origin '+refs/heads/side:refs/remotes/origin/side'
run_dist update --sha "$SIDE_SHA" --no-link
check_eq "side commit is rejected" "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
check_contains "side commit is rejected by the gate" "$OUT" "gate failed"
check_eq "gate failure keeps the served revision" \
  "$(readlink -f "$ROOT_DIR/current")" "$ROOT_DIR/releases/$(git -C "$SOURCE" rev-parse main)"
run_dist update --sha "$(git -C "$SOURCE" rev-parse main | cut -c1-12)" --no-link
check_eq "abbreviated revision is rejected" "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
check_contains "abbreviated revision names the cause" "$OUT" "invalid revision"

# --- 8. Link conflicts ------------------------------------------------------
ROOT_DIR="$WORK/dist-links"
LINKS="$WORK/links-conflict"
mkdir -p "$LINKS"
mkdir -p "$WORK/foreign-target"
ln -s "$WORK/foreign-target" "$LINKS/alpha"
REPO_URL="file://$WORK/first.git"
run_dist update --link-dir "$LINKS"
check_eq "foreign symlink is refused" "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
check_contains "foreign symlink names the cause" "$OUT" "foreign symlink"
check_eq "foreign symlink is untouched" "$(readlink "$LINKS/alpha")" "$WORK/foreign-target"
check_absent_path "refused install serves nothing" "$ROOT_DIR/current"

run_dist update --link-dir "$LINKS" --replace-links
check_eq "migration flag replaces the symlink" "$STATUS" 0
check_eq "migration flag rewrites the target" "$(readlink "$LINKS/alpha")" "$ROOT_DIR/current/alpha"

REAL_LINKS="$WORK/links-real"
mkdir -p "$REAL_LINKS/beta"
printf 'keep\n' >"$REAL_LINKS/beta/SKILL.md"
run_dist update --link-dir "$REAL_LINKS" --replace-links
check_eq "real skill directory is refused" "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
check_contains "real skill directory names the cause" "$OUT" "real path"
check_eq "real skill directory is untouched" "$(cat "$REAL_LINKS/beta/SKILL.md")" "keep"

# --- 9. Drift detection and repair -----------------------------------------
ROOT_DIR="$WORK/dist-links"
LINKS="$WORK/links-conflict"
rm "$LINKS/alpha"
run_dist status --link-dir "$LINKS"
check_eq "drifted links fail status" "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
check_contains "status reports the drift" "$OUT" "links=drift"
run_dist verify --link-dir "$LINKS"
check_eq "drifted links fail verify" "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
run_dist update --link-dir "$LINKS"
check_eq "re-run repairs the link" "$STATUS" 0
check_eq "repaired link resolves" "$([ -f "$LINKS/alpha/SKILL.md" ] && echo yes)" "yes"

# A same-named symlink to a foreign tree that does contain a SKILL.md must not
# pass verification: the link has to resolve to the served release.
FOREIGN_SKILL="$WORK/foreign-skill"
mkdir -p "$FOREIGN_SKILL"
printf '# foreign\n' >"$FOREIGN_SKILL/SKILL.md"
ln -snf "$FOREIGN_SKILL" "$LINKS/beta"
run_dist verify --link-dir "$LINKS"
check_eq "foreign tree with SKILL.md fails verify" "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
check_contains "foreign tree names the cause" "$OUT" "does not resolve to"
run_dist update --link-dir "$LINKS"
check_eq "foreign tree is not replaced without the flag" \
  "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
run_dist update --link-dir "$LINKS" --replace-links
check_eq "migration flag repairs a wrong target" "$STATUS" 0
check_eq "repaired target points at the release" "$(readlink "$LINKS/beta")" \
  "$ROOT_DIR/current/beta"

# --- 10. Development checkout is never served ------------------------------
new_origin dev
ROOT_DIR="$WORK/dist-dev"
LINKS="$WORK/links-dev"
mkdir -p "$LINKS"
REPO_URL="file://$ORIGIN"
git -C "$SOURCE" worktree add -q "$WORK/dev-worktree" -b dev-side
printf '\nDEV-ONLY-MARKER\n' >>"$WORK/dev-worktree/alpha/SKILL.md"
run_dist update --link-dir "$LINKS"
check_eq "install succeeds beside a dirty worktree" "$STATUS" 0
check_eq "uncommitted worktree edit is not served" \
  "$(grep -c 'DEV-ONLY-MARKER' "$LINKS/alpha/SKILL.md" 2>/dev/null || true)" "0"

# --- 11. No harness CLI on PATH --------------------------------------------
new_origin nopi
ROOT_DIR="$WORK/dist-nopi"
REPO_URL="file://$ORIGIN"
PATH_SAVED="$PATH"
PATH="/usr/local/bin:/usr/bin:/bin"
command -v git >/dev/null 2>&1 || PATH="/usr/bin:/bin"
run_dist update --no-link
PATH="$PATH_SAVED"
check_eq "install works without pi, claude, or codex on PATH" "$STATUS" 0
check_contains "PATH-restricted install serves the revision" "$OUT" "revision=$FIRST_SHA"

# --- 12. Root contract ------------------------------------------------------
ROOT_DIR="relative/root"
REPO_URL="file://$WORK/first.git"
run_dist update --no-link
check_eq "relative AGENT_HARNESS_HOME is rejected" "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
check_contains "relative root names the cause" "$OUT" "absolute path"

ROOT_DIR="$WORK/dist-mismatch"
mkdir -p "$ROOT_DIR"
git init -q --bare "$ROOT_DIR/git"
git -C "$ROOT_DIR/git" remote add origin "file://$WORK/nopi.git"
run_dist update --no-link
check_eq "changed fetch source is rejected" "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
check_contains "changed fetch source names the cause" "$OUT" "origin mismatch"

# --- 13. Missing link directory --------------------------------------------
new_origin nolink
ROOT_DIR="$WORK/dist-nolink"
REPO_URL="file://$ORIGIN"
run_dist update --link-dir "$WORK/no-such-link-dir"
check_eq "missing link directory is rejected" "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
check_contains "missing link directory names the cause" "$OUT" "no link directory exists"
check_absent_path "missing link directory leaves nothing served" "$ROOT_DIR/current"
check_absent_path "missing link directory writes no record" "$ROOT_DIR/rollout.jsonl"
run_dist update --no-link
check_eq "--no-link prepares the release alone" "$STATUS" 0
run_dist verify
check_eq "verify requires a link directory" "$([ "$STATUS" -ne 0 ] && echo yes)" "yes"
run_dist verify --no-link
check_eq "verify --no-link skips the links" "$STATUS" 0
run_dist status --link-dir "$WORK/no-such-link-dir"
check_eq "status tolerates a missing link directory" "$STATUS" 0
check_contains "status reports the absent links" "$OUT" "links=absent"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
