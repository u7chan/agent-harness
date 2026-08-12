#!/usr/bin/env bash
set -euo pipefail

# Durable bounded state:
#   $PWD/.playwright-cli/agent-harness/state/<session>/{lock,owner.json,ledger.json,requests/<id>.json}

PW_LOCK_FD=9

pw_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

pw_new_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    uuidgen
  fi
}

pw_uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

pw_sha256() {
  sha256sum | cut -d' ' -f1
}

pw_harness_root() {
  printf '%s/.playwright-cli/agent-harness' "$PWD"
}

pw_state_root() {
  printf '%s/state' "$(pw_harness_root)"
}

pw_artifact_root() {
  printf '%s/artifacts' "$(pw_harness_root)"
}

# Normalize a session/request segment into a safe artifact path component.
pw_artifact_sanitize_segment() {
  local value="$1"
  if [[ "$value" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; then
    printf '%s' "$value"
  else
    printf 'invalid'
  fi
}

pw_cache_dir() {
  printf '%s/cache' "$(pw_harness_root)"
}

# The canonical working directory must resolve to itself (no symlinked PWD),
# and the harness root below it must not contain symlinks.
pw_workspace_check() {
  if [ "$(realpath "$PWD" 2>/dev/null || true)" != "$PWD" ]; then
    return 1
  fi
  pw_reject_symlinks "$(pw_harness_root)" || return 1
  return 0
}

# Reject symlinks in any path component below $PWD.
pw_reject_symlinks() {
  local path="$1"
  local rel="${path#$PWD/}"
  if [ "$rel" = "$path" ]; then
    return 1
  fi
  local current="$PWD"
  local part
  IFS='/' read -ra parts <<< "$rel"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    current="$current/$part"
    if [ -L "$current" ]; then
      return 1
    fi
  done
  return 0
}

pw_ensure_dir() {
  install -d -m 0700 "$1"
}

pw_session_dir() {
  printf '%s/%s' "$(pw_state_root)" "$1"
}

pw_ensure_session_dirs() {
  local session="$1"
  pw_ensure_dir "$(pw_state_root)"
  pw_ensure_dir "$(pw_session_dir "$session")"
  pw_ensure_dir "$(pw_session_dir "$session")/requests"
  touch "$(pw_session_dir "$session")/lock"
  chmod 0600 "$(pw_session_dir "$session")/lock"
}

# Atomic durable write: exclusive temp file in the same directory, full JSON
# and mode validation, fsync, atomic rename, directory sync.
pw_durable_write() {
  local file="$1"
  local content="$2"
  local dir
  dir="$(dirname "$file")"
  pw_reject_symlinks "$dir" || return 1
  pw_ensure_dir "$dir"
  local tmp
  tmp="$(mktemp "$dir/.pwcli-tmp-XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  chmod 0600 "$tmp"
  if ! jq empty "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  sync -f "$tmp"
  mv -f "$tmp" "$file"
  sync -f "$dir"
}

# Remove orphaned temp files while holding the session lock. Refuses to
# descend through symlinks, so deletion can never reach outside the state tree.
pw_cleanup_orphan_temps() {
  local session="$1"
  local dir
  dir="$(pw_session_dir "$session")"
  pw_reject_symlinks "$dir" || return 0
  local f
  find "$dir" -name '.pwcli-tmp-*' -type f -delete 2>/dev/null || true
}

pw_owner_path() {
  printf '%s/owner.json' "$(pw_session_dir "$1")"
}

pw_ledger_path() {
  printf '%s/ledger.json' "$(pw_session_dir "$1")"
}

pw_journal_path() {
  printf '%s/requests/%s.json' "$(pw_session_dir "$1")" "$2"
}

pw_owner_read() {
  local file
  file="$(pw_owner_path "$1")"
  pw_reject_symlinks "$file" || { printf ''; return 0; }
  if [ -f "$file" ]; then
    cat "$file"
  else
    printf ''
  fi
}

pw_ledger_read() {
  local file
  file="$(pw_ledger_path "$1")"
  pw_reject_symlinks "$file" || { printf ''; return 0; }
  if [ -f "$file" ]; then
    cat "$file"
  else
    printf ''
  fi
}

pw_journals_read() {
  local session="$1"
  local dir
  dir="$(pw_session_dir "$session")/requests"
  pw_reject_symlinks "$dir" || { printf '[]'; return 0; }
  local files=()
  local f
  shopt -s nullglob
  for f in "$dir"/*.json; do
    pw_reject_symlinks "$f" || { printf '[]'; return 0; }
    files+=("$f")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    printf '[]'
    return 0
  fi
  jq -s -c . "${files[@]}"
}

pw_owner_write() {
  local session="$1"
  local content="$2"
  pw_durable_write "$(pw_owner_path "$session")" "$content"
}

pw_ledger_write() {
  local session="$1"
  local content="$2"
  pw_durable_write "$(pw_ledger_path "$session")" "$content"
}

pw_journal_write() {
  local session="$1"
  local content="$2"
  local request_id
  request_id="$(jq -r '.request_id' <<< "$content")"
  pw_durable_write "$(pw_journal_path "$session" "$request_id")" "$content"
}

# JSON builders for state files.
pw_build_owner() {
  local session="$1" generation="$2" phase="$3" workspace="$4" compatibility_id="$5" created_request_id="$6"
  jq -cn \
    --arg session "$session" \
    --arg generation "$generation" \
    --arg phase "$phase" \
    --arg workspace "$workspace" \
    --arg compat "$compatibility_id" \
    --arg created "$created_request_id" \
    --arg updated "$(pw_now)" \
    '{
      schema_version: 1,
      session: $session,
      current_generation: $generation,
      phase: $phase,
      workspace: $workspace,
      compatibility_id: $compat,
      created_request_id: $created,
      updated: $updated
    }'
}

pw_build_ledger() {
  local session="$1" generation="$2" latest_observation_id="${3:-null}" recovery="${4:-null}"
  jq -cn \
    --arg session "$session" \
    --arg generation "$generation" \
    --argjson latest "$latest_observation_id" \
    --argjson recovery "$recovery" \
    --arg updated "$(pw_now)" \
    '{
      schema_version: 1,
      session: $session,
      generation: $generation,
      latest_observation_id: $latest,
      recovery: $recovery,
      updated: $updated
    }'
}

pw_build_journal() {
  local session="$1" request_id="$2" generation="$3" action="$4" permission="$5" digest="$6" state="$7" resolution="${8:-null}" error="${9:-null}"
  jq -cn \
    --arg session "$session" \
    --arg request_id "$request_id" \
    --arg generation "$generation" \
    --arg action "$action" \
    --arg permission "$permission" \
    --arg digest "$digest" \
    --arg state "$state" \
    --arg resolution "$resolution" \
    --argjson error "$error" \
    --arg updated "$(pw_now)" \
    '{
      schema_version: 1,
      session: $session,
      request_id: $request_id,
      generation: $generation,
      action: $action,
      permission: $permission,
      digest: $digest,
      state: $state,
      resolution: (if $resolution == "null" then null else $resolution end),
      error: $error,
      updated: $updated
    }'
}

pw_journal_set_state() {
  local session="$1" journal="$2" state="$3" resolution="${4:-null}" error="${5:-null}"
  local updated
  updated="$(pw_now)"
  jq -c \
    --arg state "$state" \
    --arg resolution "$resolution" \
    --argjson error "$error" \
    --arg updated "$updated" \
    '(.state = $state)
     | (.resolution = (if $resolution == "null" then null else $resolution end))
     | (.error = $error)
     | (.updated = $updated)' \
    <<< "$journal"
}

# Acquire the exclusive session lock. Returns 0 on success; 1 on busy.
# Symlinks anywhere under the session path are rejected before any directory
# creation or file open, so the lock fd can never point outside the state tree.
pw_acquire_lock() {
  local session="$1"
  local session_dir lock_file
  session_dir="$(pw_session_dir "$session")"
  lock_file="$(pw_lock_file "$session")"
  pw_reject_symlinks "$session_dir" || return 1
  pw_reject_symlinks "$lock_file" || return 1
  pw_ensure_session_dirs "$session"
  pw_reject_symlinks "$session_dir" || return 1
  pw_reject_symlinks "$lock_file" || return 1
  exec 9>&-
  exec 9>"$lock_file"
  if ! flock -n "$PW_LOCK_FD" 2>/dev/null; then
    return 1
  fi
  return 0
}

pw_release_lock() {
  flock -u "$PW_LOCK_FD" || true
  exec 9>&-
}

pw_lock_file() {
  printf '%s/lock' "$(pw_session_dir "$1")"
}

# Role-specific structural validation of all state files for a session.
# Returns 0 when valid; 1 with PW_STATE_ERROR set to a JSON error object.
pw_state_validate() {
  local session="$1"
  PW_STATE_ERROR=""

  local fail
  fail() {
    PW_STATE_ERROR="$(jq -nc --arg code "$1" --arg message "$2" '{code: $code, message: $message}')"
  }

  # Symlink rejection runs BEFORE any read or write and covers every
  # component from the canonical root to the leaf: session dir, lock,
  # owner.json, ledger.json, requests dir, each journal leaf, and the
  # artifact session dir. A symlink anywhere lets reads/writes escape the
  # canonical root, so it is always treated as corrupt state.
  local session_dir
  session_dir="$(pw_session_dir "$session")"
  if ! pw_reject_symlinks "$session_dir" \
    || ! pw_reject_symlinks "$(pw_lock_file "$session")" \
    || ! pw_reject_symlinks "$(pw_owner_path "$session")" \
    || ! pw_reject_symlinks "$(pw_ledger_path "$session")"; then
    fail "STATE_CORRUPT" "state path contains symlinks"
    return 1
  fi
  local requests_dir
  requests_dir="$session_dir/requests"
  if ! pw_reject_symlinks "$requests_dir"; then
    fail "STATE_CORRUPT" "requests directory contains symlinks"
    return 1
  fi
  if [ -d "$requests_dir" ]; then
    local jf
    for jf in "$requests_dir"/*.json; do
      # -L catches dangling symlinks that -e would skip.
      if { [ -e "$jf" ] || [ -L "$jf" ]; } && ! pw_reject_symlinks "$jf"; then
        fail "STATE_CORRUPT" "request journal path contains symlinks"
        return 1
      fi
    done
  fi
  if ! pw_reject_symlinks "$(pw_artifact_root)/$(pw_artifact_sanitize_segment "$session")"; then
    fail "STATE_CORRUPT" "artifact directory contains symlinks"
    return 1
  fi

  local owner ledger
  owner="$(pw_owner_read "$session")"
  ledger="$(pw_ledger_read "$session")"

  if [ -n "$owner" ]; then
    if ! jq empty <<< "$owner" >/dev/null 2>&1; then fail "STATE_CORRUPT" "owner.json is not valid JSON"; return 1; fi
    local owner_ok
    owner_ok="$(jq -e '
      .schema_version == 1 and
      .session == $session and
      (.current_generation | test($uuid)) and
      (.phase == "opening" or .phase == "active" or .phase == "closed" or .phase == "quarantined") and
      .workspace == $pwd and
      (.compatibility_id | type == "string") and (.compatibility_id | length > 0) and
      (.created_request_id | test($uuid))
    ' --arg session "$session" --arg pwd "$PWD" --arg uuid "$pw_uuid_re" <<< "$owner" 2>/dev/null)"
    if [ "$owner_ok" != "true" ]; then
      fail "STATE_CORRUPT" "owner.json failed role-specific validation"
      return 1
    fi
  fi

  if [ -n "$ledger" ]; then
    if ! jq empty <<< "$ledger" >/dev/null 2>&1; then fail "STATE_CORRUPT" "ledger.json is not valid JSON"; return 1; fi
    local ledger_ok
    ledger_ok="$(jq -e '
      .schema_version == 1 and
      .session == $session and
      (.generation | test($uuid)) and
      (.latest_observation_id == null or (.latest_observation_id | test($uuid))) and
      (.recovery == null or (
        (.recovery | type == "object") and
        (.recovery.observation_id | test($uuid)) and
        (.recovery.generation | test($uuid)) and
        (.recovery.owner_phase | type == "string") and
        (.recovery.live_session | type == "boolean") and
        (.recovery.cli_available | type == "boolean") and
        (.recovery.state_corrupt | type == "boolean") and
        (.recovery.journals | type == "array")
      ))
    ' --arg session "$session" --arg uuid "$pw_uuid_re" <<< "$ledger" 2>/dev/null)"
    if [ "$ledger_ok" != "true" ]; then
      fail "STATE_CORRUPT" "ledger.json failed role-specific validation"
      return 1
    fi
  fi

  local journals
  journals="$(pw_journals_read "$session")"
  local journal_ok
  journal_ok="$(jq -e '
    (. | length) as $total |
    . as $all |
    all(.[];
      .schema_version == 1 and
      .session == $session and
      (.request_id | test($uuid)) and
      (.generation | test($uuid)) and
      (.action | type == "string") and (.action | length > 0) and
      (.permission == "read" or .permission == "write" or .permission == "sensitive-write") and
      (.digest | test("^[0-9a-f]{64}$")) and
      (.state == "prepared" or .state == "dispatched" or .state == "ok" or
       .state == "failed" or .state == "unknown" or .state == "resolved") and
      ((.state == "resolved" and (.resolution == "applied" or .resolution == "not_applied" or .resolution == "indeterminate")) or
       (.state != "resolved" and (.resolution == null or .resolution == "unknown")))
    ) and
    (([.[].request_id] | unique | length) == $total)
  ' --arg session "$session" --arg uuid "$pw_uuid_re" <<< "$journals" 2>/dev/null)"
  if [ "$journal_ok" != "true" ]; then
    fail "STATE_CORRUPT" "request journal failed role-specific validation"
    return 1
  fi

  # Journal filenames must equal their internal request_id.
  local dir
  dir="$(pw_session_dir "$session")/requests"
  if [ -d "$dir" ]; then
    local f
    for f in "$dir"/*.json; do
      [ -f "$f" ] || continue
      local base
      base="$(basename "$f" .json)"
      local inner
      inner="$(jq -r '.request_id // ""' "$f")"
      if [ "$inner" != "$base" ]; then
        fail "STATE_CORRUPT" "journal filename does not match request_id"
        return 1
      fi
    done
  fi

  # active owner requires a ledger bound to the current generation
  if [ -n "$owner" ]; then
    local phase generation
    phase="$(jq -r '.phase' <<< "$owner")"
    generation="$(jq -r '.current_generation' <<< "$owner")"
    if [ "$phase" = "active" ]; then
      if [ -z "$ledger" ]; then
        fail "STATE_CORRUPT" "active owner has no ledger"
        return 1
      fi
      local ledger_gen
      ledger_gen="$(jq -r '.generation // ""' <<< "$ledger")"
      if [ "$ledger_gen" != "$generation" ]; then
        fail "STATE_CORRUPT" "ledger generation does not match active owner generation"
        return 1
      fi
    fi
  fi

  return 0
}

# Check whether a request journal is finalized history.
pw_journal_finalized() {
  local journal="$1"
  jq -e '
    (.state == "ok" or .state == "failed") or
    (.state == "resolved" and (.resolution == "applied" or .resolution == "not_applied"))
  ' <<< "$journal" >/dev/null 2>&1
}

# Startup recovery: finalize crash residue safe-side and verify that no
# unresolved state remains. Must run while holding the session lock.
# Returns 0 on success; 1 with PW_STATE_ERROR set to a JSON error object.
pw_startup_recovery() {
  local session="$1"
  PW_STATE_ERROR=""
  local owner
  owner="$(pw_owner_read "$session")"

  local fail
  fail() {
    PW_STATE_ERROR="$(jq -nc --arg code "$1" --arg message "$2" '{code: $code, message: $message}')"
  }

  pw_cleanup_orphan_temps "$session"

  local journals
  journals="$(pw_journals_read "$session")"

  if [ -z "$owner" ]; then
    # Ownerless session: prepared journals never spawned -> failed.
    # Any other journal requires an owner -> corrupt.
    local ownerless_ok
    ownerless_ok="$(jq -e 'all(.[]; .state == "prepared")' <<< "$journals" 2>/dev/null || true)"
    if [ "$ownerless_ok" != "true" ]; then
      fail "STATE_CORRUPT" "session has journals without an owner marker"
      return 1
    fi
    local i journal new_journal
    i=0
    while jq -e ".[$i]" <<< "$journals" >/dev/null 2>&1; do
      journal="$(jq -c ".[$i]" <<< "$journals")"
      new_journal="$(pw_journal_set_state "$session" "$journal" "failed" "null" "$(jq -nc --arg c "RECOVERY_FINALIZED" --arg p "recovery" '{code: $c, phase: $p}')")"
      pw_journal_write "$session" "$new_journal"
      i=$((i + 1))
    done
    return 0
  fi

  local phase generation
  phase="$(jq -r '.phase' <<< "$owner")"
  generation="$(jq -r '.current_generation' <<< "$owner")"

  # A reopen writes its new-generation browser.open/prepared journal before
  # replacing the closed owner with an opening reservation. If the process
  # stops in that interval, the new generation never spawned and is safe to
  # finalize as failed while preserving the closed owner generation.
  if [ "$phase" = "closed" ]; then
    local foreign_reopen_prepared
    foreign_reopen_prepared="$(jq -c '[.[] | select(.generation != $gen and .action == "browser.open" and .state == "prepared")]' --arg gen "$generation" <<< "$journals")"
    local reopen_i reopen_journal reopen_failed
    reopen_i=0
    while jq -e ".[$reopen_i]" <<< "$foreign_reopen_prepared" >/dev/null 2>&1; do
      reopen_journal="$(jq -c ".[$reopen_i]" <<< "$foreign_reopen_prepared")"
      reopen_failed="$(pw_journal_set_state "$session" "$reopen_journal" "failed" "null" "$(jq -nc --arg code "RECOVERY_FINALIZED" --arg phase "recovery" '{code: $code, phase: $phase}')")"
      pw_journal_write "$session" "$reopen_failed"
      reopen_i=$((reopen_i + 1))
    done
    journals="$(pw_journals_read "$session")"
  fi

  # Best-effort live-session refresh for the opening+ok recovery branch.
  # Recovery runs before preflight, so resolve the CLI here if needed.
  if [ "$phase" = "opening" ]; then
    if pw_resolve_cli 2>/dev/null && pw_read_versions 2>/dev/null; then
      pw_session_list 2>/dev/null || true
    fi
  fi

  local current_ok other_ok current_unknown current_prepared
  current_ok="$(jq -c "[.[] | select(.generation == \$gen and .state == \"ok\")]" --arg gen "$generation" <<< "$journals")"
  current_unknown="$(jq -c "[.[] | select(.generation == \$gen and (.state == \"unknown\" or .state == \"dispatched\"))]" --arg gen "$generation" <<< "$journals")"
  current_prepared="$(jq -c "[.[] | select(.generation == \$gen and .state == \"prepared\")]" --arg gen "$generation" <<< "$journals")"

  # Finalize prepared journals (never spawned) -> failed.
  local i journal new_journal
  i=0
  while jq -e ".[$i]" <<< "$current_prepared" >/dev/null 2>&1; do
    journal="$(jq -c ".[$i]" <<< "$current_prepared")"
    new_journal="$(pw_journal_set_state "$session" "$journal" "failed" "null" "$(jq -nc --arg code "RECOVERY_FINALIZED" --arg phase "recovery" '{code: $code, phase: $phase}')")"
    pw_journal_write "$session" "$new_journal"
    i=$((i + 1))
  done

  if [ "$phase" = "opening" ]; then
    # opening owner: dispatch residue -> unknown + quarantine; success -> active/closed
    if [ "$(jq -r 'length' <<< "$current_ok")" != "0" ]; then
      if pw_session_is_live "$session" && pw_session_compatible "$session" 2>/dev/null; then
        local ledger
        ledger="$(pw_ledger_read "$session")"
        local ledger_gen
        ledger_gen="$(jq -r '.generation // ""' <<< "$ledger" 2>/dev/null || true)"
        if [ -z "$ledger" ] || [ "$ledger_gen" != "$generation" ]; then
          pw_ledger_write "$session" "$(pw_build_ledger "$session" "$generation")"
        fi
        pw_owner_write "$session" "$(pw_build_owner "$session" "$generation" "active" "$PWD" "$(pw_default_runtime_id)" "$(jq -r '.created_request_id' <<< "$owner")")"
      else
        pw_owner_write "$session" "$(pw_build_owner "$session" "$generation" "closed" "$PWD" "$(pw_default_runtime_id)" "$(jq -r '.created_request_id' <<< "$owner")")"
      fi
    elif [ "$(jq -r 'length' <<< "$current_unknown")" != "0" ]; then
      local i2 journal2 new_journal2
      i2=0
      while jq -e ".[$i2]" <<< "$current_unknown" >/dev/null 2>&1; do
        journal2="$(jq -c ".[$i2]" <<< "$current_unknown")"
        if [ "$(jq -r '.state' <<< "$journal2")" = "dispatched" ]; then
          new_journal2="$(pw_journal_set_state "$session" "$journal2" "unknown" "null" "$(jq -nc --arg code "RECOVERY_UNKNOWN" --arg phase "recovery" '{code: $code, phase: $phase}')")"
          pw_journal_write "$session" "$new_journal2"
        fi
        i2=$((i2 + 1))
      done
      pw_owner_write "$session" "$(pw_build_owner "$session" "$generation" "quarantined" "$PWD" "$(pw_default_runtime_id)" "$(jq -r '.created_request_id' <<< "$owner")")"
    else
      # opening owner with only prepared journals (now failed) -> closed
      pw_owner_write "$session" "$(pw_build_owner "$session" "$generation" "closed" "$PWD" "$(pw_default_runtime_id)" "$(jq -r '.created_request_id' <<< "$owner")")"
    fi
  elif [ "$phase" != "quarantined" ]; then
    # active/closed owner: dispatch residue -> unknown + quarantine
    if [ "$(jq -r 'length' <<< "$current_unknown")" != "0" ]; then
      local i3 journal3 new_journal3
      i3=0
      while jq -e ".[$i3]" <<< "$current_unknown" >/dev/null 2>&1; do
        journal3="$(jq -c ".[$i3]" <<< "$current_unknown")"
        if [ "$(jq -r '.state' <<< "$journal3")" = "dispatched" ]; then
          new_journal3="$(pw_journal_set_state "$session" "$journal3" "unknown" "null" "$(jq -nc --arg code "RECOVERY_UNKNOWN" --arg phase "recovery" '{code: $code, phase: $phase}')")"
          pw_journal_write "$session" "$new_journal3"
        fi
        i3=$((i3 + 1))
      done
      pw_owner_write "$session" "$(pw_build_owner "$session" "$generation" "quarantined" "$PWD" "$(pw_default_runtime_id)" "$(jq -r '.created_request_id' <<< "$owner")")"
    fi
  fi

  # Final consistency checks.
  local journals2
  journals2="$(pw_journals_read "$session")"
  local final_ok
  final_ok="$(jq -e '
    (all(.[]; (.state != "prepared" and .state != "dispatched"))) and
    (all(.[];
      (.generation == $gen) or
      (.state == "ok" or .state == "failed" or
       (.state == "resolved" and (.resolution == "applied" or .resolution == "not_applied"))))
    )
  ' --arg gen "$generation" <<< "$journals2" 2>/dev/null || true)"
  if [ "$final_ok" != "true" ]; then
    fail "STATE_CORRUPT" "unresolved journals remain after startup recovery"
    return 1
  fi

  local owner2
  owner2="$(pw_owner_read "$session")"
  local phase2
  phase2="$(jq -r '.phase // ""' <<< "$owner2")"
  if [ "$phase2" = "opening" ]; then
    fail "STATE_CORRUPT" "owner remained in opening phase after startup recovery"
    return 1
  fi

  return 0
}

# Gate a write request against the cross-generation request journal.
# Returns:
#   "ok"          - no journal entry; proceed (PW_JOURNAL_GATE_RESULT)
#   "already"     - already applied; envelope data in PW_JOURNAL_GATE_DATA
#   "unknown"     - outcome unknown; error in PW_JOURNAL_GATE_ERROR
#   "conflict"    - request id reused with a different binding
#   "retired"     - request id retired
#   "corrupt"     - journal path contains symlinks; error in PW_JOURNAL_GATE_ERROR
pw_journal_gate() {
  local session="$1" request_id="$2" action="$3" permission="$4" digest="$5"
  PW_JOURNAL_GATE_RESULT=""
  PW_JOURNAL_GATE_DATA="null"
  PW_JOURNAL_GATE_ERROR=""
  # Reject symlinked journal leaves (dangling included) before reading any
  # journal: otherwise a finalized history entry could be hidden and the same
  # request_id would pass the gate as if it had never run.
  local requests_dir
  requests_dir="$(pw_session_dir "$session")/requests"
  if ! pw_reject_symlinks "$requests_dir"; then
    PW_JOURNAL_GATE_RESULT="corrupt"
    PW_JOURNAL_GATE_ERROR="STATE_CORRUPT"
    return 0
  fi
  if [ -d "$requests_dir" ]; then
    local jf
    for jf in "$requests_dir"/*.json; do
      if { [ -e "$jf" ] || [ -L "$jf" ]; } && ! pw_reject_symlinks "$jf"; then
        PW_JOURNAL_GATE_RESULT="corrupt"
        PW_JOURNAL_GATE_ERROR="STATE_CORRUPT"
        return 0
      fi
    done
  fi
  local journals
  journals="$(pw_journals_read "$session")"
  local match
  match="$(jq -c --arg id "$request_id" '[.[] | select(.request_id == $id)] | if length > 0 then .[0] else null end' <<< "$journals")"
  if [ "$match" = "null" ]; then
    PW_JOURNAL_GATE_RESULT="ok"
    return 0
  fi
  local binding_ok
  binding_ok="$(jq -e --arg session "$session" --arg action "$action" --arg permission "$permission" --arg digest "$digest" '
    .session == $session and .action == $action and .permission == $permission and .digest == $digest
  ' <<< "$match" 2>/dev/null || true)"
  if [ "$binding_ok" != "true" ]; then
    PW_JOURNAL_GATE_RESULT="conflict"
    PW_JOURNAL_GATE_ERROR="REQUEST_ID_CONFLICT"
    return 0
  fi
  local state resolution generation
  state="$(jq -r '.state' <<< "$match")"
  resolution="$(jq -r '.resolution // "null"' <<< "$match")"
  generation="$(jq -r '.generation' <<< "$match")"
  case "$state" in
    ok)
      PW_JOURNAL_GATE_RESULT="already"
      PW_JOURNAL_GATE_DATA="$(jq -nc --arg gen "$generation" '{original_generation: $gen}')"
      ;;
    resolved)
      if [ "$resolution" = "applied" ]; then
        PW_JOURNAL_GATE_RESULT="already"
        PW_JOURNAL_GATE_DATA="$(jq -nc --arg gen "$generation" '{original_generation: $gen}')"
      elif [ "$resolution" = "indeterminate" ]; then
        PW_JOURNAL_GATE_RESULT="unknown"
        PW_JOURNAL_GATE_ERROR="REQUEST_OUTCOME_UNKNOWN"
      else
        PW_JOURNAL_GATE_RESULT="retired"
        PW_JOURNAL_GATE_ERROR="REQUEST_ID_RETIRED"
      fi
      ;;
    unknown|dispatched)
      PW_JOURNAL_GATE_RESULT="unknown"
      PW_JOURNAL_GATE_ERROR="REQUEST_OUTCOME_UNKNOWN"
      ;;
    prepared|failed)
      PW_JOURNAL_GATE_RESULT="retired"
      PW_JOURNAL_GATE_ERROR="REQUEST_ID_RETIRED"
      ;;
  esac
  return 0
}

# Digest of the normalized request input (common fields excluded).
pw_input_digest() {
  local action="$1" input="$2"
  jq -cS --arg action "$action" '{action: $action, fields: (del(.grant, .request_id))}' <<< "$input" | pw_sha256
}
