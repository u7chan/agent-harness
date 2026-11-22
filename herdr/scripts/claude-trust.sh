#!/usr/bin/env bash
# Record one human trust decision for a Claude worktree.
#
# This is the writer behind the launcher's read-only trust check: it prints the
# normalized path, the state file, the current state, and the one key it would
# write, then merges exactly that key and re-reads the file to confirm. The
# command is meant for the person who owns the decision; an agent runs it only
# after a separate, target-specific consent (SKILL.md#claude-trust-approval).
#
# Vocabulary (lib/claude-trust.sh owns it): missing-file, unreadable,
# invalid-json, unexpected-shape, missing-key, false, true. Only missing-key
# and false are written, missing-file is created at 0600, and unreadable,
# invalid-json, and unexpected-shape stop without initializing anything. true
# is a no-op success, so a repeated run changes nothing.
#
# The write is exclusive in two ways. Approval commands serialize on a lock
# directory next to the state file, and the command refuses to write while a
# `claude` process sharing that state file is running (or while that cannot be
# confirmed), because the CLI does not take the lock itself. Atomic replacement
# alone does not preserve a concurrent CLI write: a change the CLI saves
# between this command's read and its replace is lost, so the lock and the
# no-running-CLI condition are the premise, and a later CLI overwrite that drops
# the record fails closed on the next launcher start.
#
# Output on stdout: `target:`, `trust-file:`, `state:`, `key:`, and a final
# `result:` line (already-approved, approved, or refused with reason=<token>).
# Guidance for the refusal is on stderr.
#
# Exit status: 0 approved or already approved; 1 refused or failed; 2 usage.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/claude-trust.sh
source "$script_dir/lib/claude-trust.sh"
# shellcheck source=lib/record.sh
source "$script_dir/lib/record.sh"

# Resolved from this script, never from the caller's cwd, so the trust file
# matches the launcher's when the command runs from another directory.
claude_auth="$script_dir/../../scripts/pi-development/claude-auth-status.sh"

usage() {
  printf 'Usage: %s <worktree-root>\n' "$0" >&2
  printf '\nRecords the trust decision for one git worktree root in the state file\n' >&2
  printf 'the shared launcher reads. The path must be an absolute path that\n' >&2
  printf 'resolves to the root of a git worktree; a subdirectory, a missing path,\n' >&2
  printf 'and a directory outside git are refused so nothing but the root of a\n' >&2
  printf 'worktree is ever approved.\n' >&2
  printf '\nThe command writes only projects[<path>].hasTrustDialogAccepted. It stops\n' >&2
  printf 'without writing when the state file is unreadable, invalid, or shaped\n' >&2
  printf 'unexpectedly, when another approval holds the lock, or when a claude\n' >&2
  printf 'process sharing the state file is running (or cannot be ruled out).\n' >&2
}

refuse() { # <reason> <guidance>
  printf 'result: refused reason=%s\n' "$1"
  printf 'claude-trust: %s\n' "$2" >&2
  exit 1
}

tui_fallback() {
  printf 'そのディレクトリで claude を一度起動し、TUI の trust ダイアログで承認してください。'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  '')
    usage
    exit 2
    ;;
esac
[ "$#" -eq 1 ] || {
  usage
  exit 2
}

path_arg="$1"
case "$path_arg" in
  /*) ;;
  *) refuse not-absolute "絶対パスを指定してください: $path_arg" ;;
esac
case "$path_arg" in
  *[[:cntrl:]]*) refuse unusable-path "パスに制御文字が含まれています: $path_arg" ;;
esac
command -v git >/dev/null 2>&1 || refuse git-missing 'git が必要です'
target="$(claude_trust_normalize_path "$path_arg")" ||
  refuse unresolvable-path "パスを正規化できません: $path_arg"
if [ ! -d "$target" ]; then
  refuse missing-path "$(printf '%s は存在するディレクトリではありません。' "$target")$(tui_fallback)"
fi
# Only a git worktree root can be approved: the launcher reads the pane's
# working directory, and a subdirectory would approve a path the agent never
# runs in. `git rev-parse --show-toplevel` is the same rule the launcher's
# exact-key check implies.
git_root="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" || git_root=''
if [ -z "$git_root" ]; then
  refuse not-worktree-root "$(printf '%s は git リポジトリの中ではありません。' "$target")$(tui_fallback)"
fi
git_root="$(claude_trust_normalize_path "$git_root")" || git_root=''
[ -n "$git_root" ] && [ "$git_root" = "$target" ] ||
  refuse not-worktree-root "$(printf '%s は git ワークツリーのルートではありません（ルート: %s）。' "$target" "${git_root:-unknown}")$(tui_fallback)"

# Resolve the state file with the launcher's rule. An explicit
# CLAUDE_CONFIG_DIR determines it by itself; without the variable the reported
# config directory comes from the same auth helper the launcher calls, so the
# default file is never guessed from $HOME.
auth_record=''
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  config_dir="$(claude_trust_config_dir '')" ||
    refuse config-dir-unusable "CLAUDE_CONFIG_DIR が使えません: ${CLAUDE_CONFIG_DIR}"
  trust_file="$(claude_trust_file_for explicit "$config_dir")"
else
  [ -x "$claude_auth" ] ||
    refuse auth-helper-missing 'scripts/pi-development/claude-auth-status.sh が必要です'
  auth_rc=0
  auth_record="$("$claude_auth" 2>/dev/null)" || auth_rc=$?
  [ "$auth_rc" -eq 0 ] ||
    refuse auth-not-ready "Claude の認証状態を確認できません: ${auth_record:-claude-auth-status.sh printed no record}"
  reported_config_dir="$(record_field "$auth_record" configDirectory)" || reported_config_dir=''
  config_dir="$(claude_trust_config_dir "$reported_config_dir")" ||
    refuse config-dir-unusable "Claude の設定ディレクトリが使えません: ${reported_config_dir:-<none>}"
  trust_file="$(claude_trust_file_for default "$config_dir")"
fi
trust_file="$(claude_trust_normalize_path "$trust_file")" ||
  refuse config-dir-unusable "信頼ファイルのパスを正規化できません: $trust_file"
config_dir="$(dirname -- "$trust_file")"
[ -d "$config_dir" ] ||
  refuse config-dir-missing "設定ディレクトリがありません: $config_dir"

command -v jq >/dev/null 2>&1 || refuse jq-missing 'jq が必要です'
state="$(claude_trust_state "$trust_file" "$target")"
printf 'target: %s\n' "$target"
printf 'trust-file: %s\n' "$trust_file"
printf 'state: %s\n' "$state"
printf 'key: projects["%s"].hasTrustDialogAccepted=true\n' "$target"

case "$state" in
  true)
    printf 'result: already-approved\n'
    printf 'claude-trust: %s は既に承認済みです。変更していません。\n' "$target" >&2
    exit 0
    ;;
  unreadable | invalid-json | unexpected-shape)
    # The writer is stricter than the reader: a file it cannot classify is
    # never reinitialized, because that would discard the rest of the user's
    # Claude configuration.
    refuse "$state" "$(printf '状態ファイルを初期化せずに停止しました（%s: %s）。' "$state" "$trust_file")$(tui_fallback)"
    ;;
esac

# Serialize approval commands on a lock beside the state file. The CLI does not
# take this lock, so this only orders writers of this command; the running
# process check below covers the CLI. A lock that cannot be taken is a stop,
# never a wait: a stale lock is removed by hand.
lock_dir="${trust_file}.lock"
if ! mkdir -- "$lock_dir" 2>/dev/null; then
  refuse lock-held "他の承認コマンドが実行中です（ロック: $lock_dir）。終了を待って再実行してください。実行中の承認がなければ、このディレクトリを削除してください。"
fi
lock_held=1
cleanup() {
  if [ "${lock_held:-0}" -eq 1 ]; then
    rmdir -- "$lock_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Re-read under the lock: the state may have changed between the display and
# this point, and an approval that finished first makes this run a no-op.
state="$(claude_trust_state "$trust_file" "$target")"
case "$state" in
  true)
    printf 'result: already-approved\n'
    printf 'claude-trust: %s は既に承認済みです。変更していません。\n' "$target" >&2
    exit 0
    ;;
  missing-file | missing-key | false) ;;
  *)
    refuse "$state" "$(printf 'ロック取得後に状態が %s へ変わりました。状態ファイルは変更していません（%s）。' "$state" "$trust_file")"
    ;;
esac

# The CLI rewrites this file without taking the lock, so a running session of
# the same state file can overwrite the record. Refuse while one exists, and
# refuse when the scan cannot rule one out.
default_trust_file() {
  local reported=''
  if [ -z "$auth_record" ]; then
    [ -x "$claude_auth" ] || return 1
    auth_record="$("$claude_auth" 2>/dev/null)" || return 1
  fi
  reported="$(record_field "$auth_record" configDirectory)" || return 1
  claude_trust_usable_dir "$reported" || return 1
  claude_trust_file_for default "$reported"
}

trust_file_compare="$(claude_trust_normalize_path "$trust_file")" || trust_file_compare="$trust_file"
processes=''
scan_rc=0
processes="$(claude_trust_claude_processes)" || scan_rc=$?
case "$scan_rc" in
  0)
    while IFS=$'\t' read -r pid process_mode process_dir; do
      [ -n "$pid" ] || continue
      case "$process_mode" in
        explicit)
          other_file="$(claude_trust_file_for explicit "$process_dir")"
          ;;
        default)
          other_file="$(default_trust_file)" ||
            refuse claude-unconfirmed "同じ設定先を使う claude がいるかを確認できません（pid $pid）。$(tui_fallback)"
          ;;
        *)
          refuse claude-unconfirmed "実行中の claude の設定先を判定できません（pid $pid）。$(tui_fallback)"
          ;;
      esac
      other_compare="$(claude_trust_normalize_path "$other_file")" || other_compare="$other_file"
      if [ "$other_compare" = "$trust_file_compare" ]; then
        refuse claude-running "同じ設定ファイルを使う claude が実行中です（pid $pid）。書き込みません。承認の間は claude を起動しないでください。終了後に同じコマンドを再実行してください。"
      fi
    done <<< "$processes"
    ;;
  1) ;;
  *)
    refuse claude-unconfirmed "実行中の claude を確認できません（ps を実行できないか、対象プロセスの環境を読めません）。書き込みません。$(tui_fallback)"
    ;;
esac

command -v python3 >/dev/null 2>&1 || refuse python3-missing 'python3 が必要です'
write_rc=0
write_output="$(python3 -I - "$trust_file" "$target" "$state" 2>/dev/null <<'PY'
import json
import os
import sys
import tempfile

path, target, state = sys.argv[1:4]


def fail(reason):
    sys.stdout.write("error:%s" % reason)
    sys.exit(1)


if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            document = json.load(handle)
    except Exception:
        fail("invalid-json")
    if not isinstance(document, dict):
        fail("unexpected-shape")
    projects = document.get("projects")
    if projects is None:
        projects = {}
    if not isinstance(projects, dict):
        fail("unexpected-shape")
else:
    if state != "missing-file":
        fail("state-changed")
    document = {"projects": {}}
    projects = document["projects"]

entry = projects.get(target)
if entry is None:
    entry = {}
if not isinstance(entry, dict):
    fail("unexpected-shape")
# The one change this command owns: every other project, key, and value is
# carried through the same document, serialized with the CLI's own two-space
# layout, so no other value is rewritten.
entry["hasTrustDialogAccepted"] = True
projects[target] = entry
document["projects"] = projects

directory = os.path.dirname(os.path.abspath(path)) or "."
try:
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=".claude.json.", suffix=".tmp")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
except Exception:
    fail("write-failed")

sys.stdout.write("written")
PY
)" || write_rc=$?
if [ "$write_rc" -ne 0 ]; then
  case "$write_output" in
    error:*) refuse "${write_output#error:}" "$(printf '信頼ファイルを書き換えられませんでした（%s）。' "${write_output#error:}")$(tui_fallback)" ;;
    *) refuse write-failed "$(printf '信頼ファイルを書き換えられませんでした（%s）。' "$trust_file")$(tui_fallback)" ;;
  esac
fi

verified="$(claude_trust_state "$trust_file" "$target")"
[ "$verified" = true ] ||
  refuse verify-failed "$(printf '書き込み後の再読み取りで true を確認できません（%s: %s）。' "$verified" "$trust_file")"

printf 'result: approved\n'
printf 'claude-trust: %s の trust を記録しました。この承認は、そのワークツリーの .claude/ にある hooks、settings、permission rules なども今後無人で適用されることを意味します。後から claude が同じファイルを書き換えて記録が落ちた場合、次回の起動は未承認で止まります。\n' "$target" >&2
