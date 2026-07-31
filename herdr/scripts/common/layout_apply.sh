#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR_LAYOUT_APPLY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR_LAYOUT_APPLY/herdr_cli.sh"

herdr_layout_apply_persist() {
  local team_id="$1" status="$2" refs="$3" steps="$4" created_panes="$5"
  [ -n "$team_id" ] || return 0
  declare -F herdr_manifest_read >/dev/null 2>&1 || return 0
  declare -F herdr_manifest_write >/dev/null 2>&1 || return 0
  local manifest
  manifest="$(herdr_manifest_read "$team_id" 2>/dev/null || echo '{}')"
  [ "$manifest" != "{}" ] || return 0
  manifest="$(jq -c --arg status "$status" --argjson refs "$refs" --argjson steps "$steps" --argjson created "$created_panes" \
    '.layout.status = $status | .layout.refs = $refs | .layout.steps = $steps | .layout.created_panes = $created' <<< "$manifest")"
  herdr_manifest_write "$team_id" "$manifest" || true
}

herdr_layout_snapshot_normalize() {
  local list_raw="$1"
  local layout_raw="$2"
  local panes
  panes="$(jq -c '.result.panes // []' <<< "$list_raw")"
  if [ "$(jq -r 'type' <<< "$panes")" != "array" ]; then
    echo '{"status":"failed","error":{"code":"LAYOUT_SNAPSHOT_INVALID","message":"pane list did not contain an array"}}'
    return 0
  fi

  local layout_pane
  layout_pane="$(jq -c '.result.layout // .result.pane // null' <<< "$layout_raw")"
  local layout_panes
  layout_panes="$(jq -c '.result.layout.panes // .result.panes // []' <<< "$layout_raw")"
  if [ "$(jq -r 'type' <<< "$layout_panes")" = "array" ] && [ "$(jq -r 'length' <<< "$layout_panes")" -gt 0 ]; then
    panes="$(jq -c --argjson layout_panes "$layout_panes" '
      . as $listed
      | reduce $layout_panes[] as $layout_pane ($listed;
          map(if .pane_id == ($layout_pane.pane_id // $layout_pane.id) then . * $layout_pane else . end))
    ' <<< "$panes")"
  fi
  if [ "$layout_pane" != "null" ] && [ "$(jq -r 'type' <<< "$layout_pane")" = "object" ]; then
    local layout_pane_id
    layout_pane_id="$(jq -r '.pane_id // .id // empty' <<< "$layout_pane")"
    if [ -n "$layout_pane_id" ]; then
      if jq -e --arg id "$layout_pane_id" 'any(.[]; .pane_id == $id)' <<< "$panes" >/dev/null; then
        panes="$(jq -c --arg id "$layout_pane_id" --argjson pane "$layout_pane" 'map(if .pane_id == $id then . * $pane else . end)' <<< "$panes")"
      else
        panes="$(jq -c --argjson pane "$layout_pane" '. + [$pane]' <<< "$panes")"
      fi
    fi
  fi

  local normalized
  normalized="$(jq -c '
    map({
      pane_id: (.pane_id // .id // ""),
      x: (.x // .left // 0),
      y: (.y // .top // 0),
      cols: (.cols // .width // 0),
      rows: (.rows // .height // 0),
      split_direction: (.split_direction // .direction // null),
      split_ratio: (.split_ratio // .ratio // null)
    })
    | if any(.[]; (.pane_id | type) != "string" or length == 0 or (.x|type) != "number" or (.y|type) != "number" or (.cols|type) != "number" or (.rows|type) != "number" or .cols <= 0 or .rows <= 0)
      then error("invalid pane geometry") else . end
  ' <<< "$panes" 2>/dev/null || true)"
  if [ -z "$normalized" ]; then
    echo '{"status":"failed","error":{"code":"LAYOUT_SNAPSHOT_INVALID","message":"pane snapshot contained invalid geometry"}}'
    return 0
  fi
  jq -nc --argjson panes "$normalized" '{status:"ok",panes:$panes}'
}

herdr_layout_snapshot() {
  local deadline_ms="$1"
  local workspace_id="$2"
  local pane_id="$3"
  local list_raw list_outcome layout_raw layout_outcome
  list_raw="$(herdr_cli_pane_list_before_deadline "$deadline_ms" "$workspace_id")"
  list_outcome="$(herdr_cli_outcome "$list_raw")"
  if [ "$list_outcome" != "ok" ]; then
    jq -nc --arg status "$list_outcome" '{status:$status,phase:"pane.list"}'
    return 0
  fi
  layout_raw="$(herdr_cli_pane_layout_before_deadline "$deadline_ms" "$pane_id")"
  layout_outcome="$(herdr_cli_outcome "$layout_raw")"
  if [ "$layout_outcome" != "ok" ]; then
    jq -nc --arg status "$layout_outcome" '{status:$status,phase:"pane.layout"}'
    return 0
  fi
  herdr_layout_snapshot_normalize "$list_raw" "$layout_raw"
}

herdr_layout_validate_split() {
  local before="$1"
  local after="$2"
  local target_id="$3"
  local response_id="$4"
  local direction="$5"
  local expected="$6"

  jq -e \
    --arg target_id "$target_id" --arg response_id "$response_id" \
    --arg direction "$direction" --argjson expected "$expected" '
    def geom($p): {x:$p.x,y:$p.y,cols:$p.cols,rows:$p.rows};
    def close_enough($a; $b):
      (($a.x - $b.x) | fabs) <= 1
      and (($a.y - $b.y) | fabs) <= 1
      and (($a.cols - $b.cols) | fabs) <= 1
      and (($a.rows - $b.rows) | fabs) <= 1;
    ($before | map(.pane_id) | sort) as $before_ids
    | ($after | map(.pane_id) | sort) as $after_ids
    | ($before | map(select(.pane_id == $target_id)) | first) as $target_before
    | ($after | map(select(.pane_id == $target_id)) | first) as $target_after
    | ($after | map(select(.pane_id == $response_id)) | first) as $created_after
    | ($before | map(select(.pane_id != $target_id)) | map(geom(.)) | sort_by(.x,.y,.cols,.rows)) as $before_other
    | ($after | map(select(.pane_id != $target_id and .pane_id != $response_id)) | map(geom(.)) | sort_by(.x,.y,.cols,.rows)) as $after_other
    | ($after_ids | length) == (($before_ids | length) + 1)
    and (($before_ids - $after_ids) | length) == 0
    and (($after_ids - $before_ids) | length) == 1
    and (($after_ids - $before_ids)[0] == $response_id)
    and ($target_before != null and $target_after != null and $created_after != null)
    and ($before_other == $after_other)
    and close_enough($target_before; $expected.target)
    and close_enough($target_after; $expected.retained)
    and close_enough($created_after; $expected.created)
    and (if $direction == "right" then
      $target_after.x == $target_before.x
      and $target_after.y == $target_before.y
      and $target_after.rows == $target_before.rows
      and $created_after.y == $target_before.y
      and $created_after.rows == $target_before.rows
      and $created_after.x == ($target_after.x + $target_after.cols + 1)
    elif $direction == "down" then
      $target_after.x == $target_before.x
      and $target_after.y == $target_before.y
      and $target_after.cols == $target_before.cols
      and $created_after.x == $target_before.x
      and $created_after.cols == $target_before.cols
      and $created_after.y == ($target_after.y + $target_after.rows + 1)
    else false end)
  ' --argjson before "$(jq -c '.panes' <<< "$before")" \
    --argjson after "$(jq -c '.panes' <<< "$after")" \
    <<< '{}'
}

herdr_layout_apply() {
  local plan="$1"
  local root_pane_id="$2"
  local workspace_id="$3"
  local deadline_ms="$4"
  local team_id="${5:-}"

  if [ "$(jq -r '.status' <<< "$plan")" != "ok" ]; then
    jq -c '.' <<< "$plan"
    return 0
  fi

  local refs='{}' steps='[]' created_panes='[]'
  refs="$(jq -c --arg pane_id "$root_pane_id" '.orch = $pane_id' <<< "$refs")"
  local split_count
  split_count="$(jq -r '.splits | length' <<< "$plan")"

  local index
  for ((index = 0; index < split_count; index++)); do
    local split target_ref retained_ref created_ref direction ratio expected target_id
    split="$(jq -c --argjson i "$index" '.splits[$i]' <<< "$plan")"
    target_ref="$(jq -r '.target_ref' <<< "$split")"
    retained_ref="$(jq -r '.retained_ref' <<< "$split")"
    created_ref="$(jq -r '.created_ref' <<< "$split")"
    direction="$(jq -r '.direction' <<< "$split")"
    ratio="$(jq -r '.ratio' <<< "$split")"
    expected="$(jq -c '.expected' <<< "$split")"
    target_id="$(jq -r --arg ref "$target_ref" '.[$ref] // empty' <<< "$refs")"
    if [ -z "$target_id" ]; then
      jq -nc --argjson steps "$steps" --argjson refs "$refs" --argjson created "$created_panes" \
        '{status:"failed",code:"LAYOUT_PLAN_INVALID",message:"target logical ref is not bound",steps:$steps,refs:$refs,created_panes:$created}'
      return 0
    fi

    local before_result before_status before after_result after_status split_result split_outcome response_id
    before_result="$(herdr_layout_snapshot "$deadline_ms" "$workspace_id" "$target_id")"
    before_status="$(jq -r '.status' <<< "$before_result")"
    if [ "$before_status" != "ok" ]; then
      jq -nc --arg status "$before_status" --arg phase "before.split" --argjson steps "$steps" \
        --argjson refs "$refs" --argjson created "$created_panes" \
        '{status:"unknown",phase:$phase,transport_status:$status,steps:$steps,refs:$refs,created_panes:$created}'
      return 0
    fi

    local planned_step
    planned_step="$(jq -nc --argjson sequence "$(jq -r '.sequence' <<< "$split")" \
      --arg target_pane_id "$target_id" --argjson before "$(jq -c '.panes' <<< "$before_result")" \
      --argjson expected "$expected" \
      '{sequence:$sequence,status:"in_flight",target_pane_id:$target_pane_id,created_pane_id:null,recovered_from_unknown:false,before:$before,after:null,expected:$expected}')"
    local planned_steps
    planned_steps="$(jq -c --argjson step "$planned_step" '. + [$step]' <<< "$steps")"
    herdr_layout_apply_persist "$team_id" applying "$refs" "$planned_steps" "$created_panes"

    split_result="$(herdr_cli_pane_split_before_deadline "$deadline_ms" "$target_id" "$direction" "$ratio")"
    split_outcome="$(herdr_cli_outcome "$split_result")"
    response_id="$(jq -r '.result.pane.pane_id // empty' <<< "$split_result")"
    if [ "$split_outcome" = "failed" ]; then
      local failed_step
      failed_step="$(jq -nc --argjson sequence "$(jq -r '.sequence' <<< "$split")" --arg status "failed" \
        --arg target_pane_id "$target_id" --argjson before "$(jq -c '.panes' <<< "$before_result")" \
        --argjson expected "$expected" '{sequence:$sequence,status:$status,target_pane_id:$target_pane_id,created_pane_id:null,recovered_from_unknown:false,before:$before,after:null,expected:$expected}')"
      steps="$(jq -c --argjson step "$failed_step" '. + [$step]' <<< "$steps")"
      herdr_layout_apply_persist "$team_id" failed "$refs" "$steps" "$created_panes"
      jq -nc --arg herdr_error "$(herdr_cli_error_code "$split_result")" --argjson steps "$steps" \
        --argjson refs "$refs" --argjson created "$created_panes" \
        '{status:"failed",code:"PANE_CREATE_FAILED",herdr_error:$herdr_error,message:"pane split returned an explicit failure",steps:$steps,refs:$refs,created_panes:$created}'
      return 0
    fi

    after_result="$(herdr_layout_snapshot "$deadline_ms" "$workspace_id" "$target_id")"
    after_status="$(jq -r '.status' <<< "$after_result")"
    if [ "$after_status" != "ok" ]; then
      jq -nc --arg phase "after.split" --arg status "$after_status" --argjson steps "$planned_steps" \
        --argjson refs "$refs" --argjson created "$created_panes" \
        '{status:"unknown",phase:$phase,transport_status:$status,steps:$steps,refs:$refs,created_panes:$created}'
      return 0
    fi
    if [ -z "$response_id" ] && [ "$split_outcome" = "unknown" ]; then
      response_id="$(jq -r --argjson before "$(jq -c '.panes' <<< "$before_result")" \
        --argjson after "$(jq -c '.panes' <<< "$after_result")" \
        '([$after[].pane_id] - [$before[].pane_id]) | if length == 1 then .[0] else empty end' <<< '{}')"
    fi
    if [ -z "$response_id" ]; then
      jq -nc --arg phase "verify.split" --arg status "unknown" --argjson steps "$planned_steps" \
        --argjson refs "$refs" --argjson created "$created_panes" \
        '{status:"unknown",phase:$phase,transport_status:$status,steps:$steps,refs:$refs,created_panes:$created}'
      return 0
    fi

    local validation_rc=0
    herdr_layout_validate_split "$before_result" "$after_result" "$target_id" "$response_id" "$direction" "$expected" >/dev/null || validation_rc=$?
    if [ "$validation_rc" -ne 0 ]; then
      jq -nc --arg phase "verify.split" --arg status "failed" --argjson steps "$planned_steps" \
        --argjson refs "$refs" --argjson created "$created_panes" \
        '{status:"unknown",phase:$phase,transport_status:$status,steps:$steps,refs:$refs,created_panes:$created}'
      return 0
    fi

    local applied_step
    applied_step="$(jq -nc --argjson sequence "$(jq -r '.sequence' <<< "$split")" \
      --arg target_pane_id "$target_id" --arg created_pane_id "$response_id" \
      --argjson before "$(jq -c '.panes' <<< "$before_result")" \
      --argjson after "$(jq -c '.panes' <<< "$after_result")" --argjson expected "$expected" \
      --argjson recovered "$([ "$split_outcome" = "unknown" ] && echo true || echo false)" \
      '{sequence:$sequence,status:"applied",target_pane_id:$target_pane_id,created_pane_id:$created_pane_id,recovered_from_unknown:$recovered,before:$before,after:$after,expected:$expected}')"
    steps="$(jq -c --argjson step "$applied_step" '. + [$step]' <<< "$steps")"
    refs="$(jq -c --arg retained_ref "$retained_ref" --arg target_id "$target_id" \
      --arg created_ref "$created_ref" --arg response_id "$response_id" \
      '.[$retained_ref] = $target_id | .[$created_ref] = $response_id' <<< "$refs")"
    created_panes="$(jq -c --arg pane_id "$response_id" '. + [$pane_id]' <<< "$created_panes")"
    herdr_layout_apply_persist "$team_id" applying "$refs" "$steps" "$created_panes"
  done

  local binding member_ref source_ref source_id
  while IFS=$'\t' read -r member_ref source_ref; do
    [ -n "$member_ref" ] || continue
    source_id="$(jq -r --arg ref "$source_ref" '.[$ref] // empty' <<< "$refs")"
    [ -n "$source_id" ] || continue
    refs="$(jq -c --arg ref "$member_ref" --arg pane_id "$source_id" '.[$ref] = $pane_id' <<< "$refs")"
  done < <(jq -r '(.member_bindings // {}) | to_entries[] | [.key,.value] | @tsv' <<< "$plan")

  jq -nc --argjson steps "$steps" --argjson refs "$refs" --argjson created "$created_panes" \
    '{status:"ok",refs:$refs,steps:$steps,created_panes:$created}'
}

herdr_layout_apply_main() {
  local input="${1:-}"
  if [ -n "$input" ] && [ -f "$input" ]; then
    input="$(cat "$input")"
  elif [ -z "$input" ]; then
    input="$(cat)"
  fi
  local plan root_pane_id workspace_id deadline_ms timeout_ms
  plan="$(jq -c '.plan' <<< "$input")"
  root_pane_id="$(jq -r '.root_pane_id' <<< "$input")"
  workspace_id="$(jq -r '.workspace_id' <<< "$input")"
  deadline_ms="$(jq -r '.deadline_ms // empty' <<< "$input")"
  if [ -z "$deadline_ms" ]; then
    timeout_ms="$(jq -r '.timeout_ms // 30000' <<< "$input")"
    deadline_ms="$(herdr_cli_deadline_from_timeout "$timeout_ms")"
  fi
  herdr_layout_apply "$plan" "$root_pane_id" "$workspace_id" "$deadline_ms" "$(jq -r '.team_id // ""' <<< "$input")"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  herdr_layout_apply_main "${1:-}"
fi
