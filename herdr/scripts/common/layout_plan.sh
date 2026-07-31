#!/usr/bin/env bash
set -euo pipefail

# This file deliberately has no Herdr dependency.  It only turns a geometry
# request into a deterministic BSP plan.

herdr_layout_plan_round_ratio() {
  local numerator="$1"
  local denominator="$2"
  awk -v n="$numerator" -v d="$denominator" 'BEGIN { if (d == 0) exit 1; printf "%.6f", n / d }'
}

HERDR_LAYOUT_PLAN_OFFSET_X=0
HERDR_LAYOUT_PLAN_OFFSET_Y=0

herdr_layout_plan_offset_x() { echo $(($1 + HERDR_LAYOUT_PLAN_OFFSET_X)); }
herdr_layout_plan_offset_y() { echo $(($1 + HERDR_LAYOUT_PLAN_OFFSET_Y)); }

herdr_layout_plan_add_geometry() {
  local ref="$1" x="${2:-0}" y="${3:-0}" cols="$4" rows="$5"
  local ox oy
  ox="$(herdr_layout_plan_offset_x "$x")"
  oy="$(herdr_layout_plan_offset_y "$y")"
  HERDR_LAYOUT_PLAN_GEOMETRY="$(jq -c \
    --arg ref "$ref" --argjson x "$ox" --argjson y "$oy" \
    --argjson cols "$cols" --argjson rows "$rows" \
    '. + {($ref): {x:$x,y:$y,cols:$cols,rows:$rows}}' \
    <<< "$HERDR_LAYOUT_PLAN_GEOMETRY")"
}

herdr_layout_plan_add_split() {
  local target_ref="$1"
  local retained_ref="$2"
  local created_ref="$3"
  local direction="$4"
  local ratio="$5"
  local target_x="$6"
  local target_y="$7"
  local target_cols="$8"
  local target_rows="$9"
  local retained_x="${10}"
  local retained_y="${11}"
  local retained_cols="${12}"
  local retained_rows="${13}"
  local created_x="${14}"
  local created_y="${15}"
  local created_cols="${16}"
  local created_rows="${17}"

  local otx oty orx ory ocx ocy
  otx="$(herdr_layout_plan_offset_x "$target_x")"
  oty="$(herdr_layout_plan_offset_y "$target_y")"
  orx="$(herdr_layout_plan_offset_x "$retained_x")"
  ory="$(herdr_layout_plan_offset_y "$retained_y")"
  ocx="$(herdr_layout_plan_offset_x "$created_x")"
  ocy="$(herdr_layout_plan_offset_y "$created_y")"

  local sequence=$(( $(jq -r 'length' <<< "$HERDR_LAYOUT_PLAN_SPLITS") + 1 ))
  local expected
  expected="$(jq -nc \
    --argjson target_x "$otx" --argjson target_y "$oty" \
    --argjson target_cols "$target_cols" --argjson target_rows "$target_rows" \
    --argjson retained_x "$orx" --argjson retained_y "$ory" \
    --argjson retained_cols "$retained_cols" --argjson retained_rows "$retained_rows" \
    --argjson created_x "$ocx" --argjson created_y "$ocy" \
    --argjson created_cols "$created_cols" --argjson created_rows "$created_rows" \
    '{target:{x:$target_x,y:$target_y,cols:$target_cols,rows:$target_rows},retained:{x:$retained_x,y:$retained_y,cols:$retained_cols,rows:$retained_rows},created:{x:$created_x,y:$created_y,cols:$created_cols,rows:$created_rows}}')"
  HERDR_LAYOUT_PLAN_SPLITS="$(jq -c \
    --argjson sequence "$sequence" --arg target_ref "$target_ref" \
    --arg retained_ref "$retained_ref" --arg created_ref "$created_ref" \
    --arg direction "$direction" --argjson ratio "$ratio" \
    --argjson expected "$expected" \
    '. + [{sequence:$sequence,target_ref:$target_ref,retained_ref:$retained_ref,created_ref:$created_ref,direction:$direction,ratio:$ratio,expected:$expected}]' \
    <<< "$HERDR_LAYOUT_PLAN_SPLITS")"
}

herdr_layout_plan_generate() {
  local input="$1"
  local member_count max_cols target_cols target_rows

  if ! jq -e '
    type == "object"
    and (.member_count | type == "number" and floor == . and . >= 1)
    and (.max_cols | type == "number" and floor == . and . >= 1 and . <= 3)
    and (.target_cols | type == "number" and floor == . and . >= 1)
    and (.target_rows | type == "number" and floor == . and . >= 1)
  ' <<< "$input" >/dev/null 2>&1; then
    jq -nc '{status:"failed",error:{code:"INVALID_LAYOUT_INPUT",message:"member_count, max_cols, target_cols and target_rows must be positive integers; max_cols must be 1..3"}}'
    return 0
  fi

  member_count="$(jq -r '.member_count' <<< "$input")"
  max_cols="$(jq -r '.max_cols' <<< "$input")"
  target_cols="$(jq -r '.target_cols' <<< "$input")"
  target_rows="$(jq -r '.target_rows' <<< "$input")"
  local target_x target_y
  target_x="$(jq -r '.target_x // 0' <<< "$input")"
  target_y="$(jq -r '.target_y // 0' <<< "$input")"
  HERDR_LAYOUT_PLAN_OFFSET_X="$target_x"
  HERDR_LAYOUT_PLAN_OFFSET_Y="$target_y"

  local sqrt_cols=1
  while [ $((sqrt_cols * sqrt_cols)) -lt "$member_count" ]; do
    sqrt_cols=$((sqrt_cols + 1))
  done
  local preferred_cols="$max_cols"
  [ "$preferred_cols" -le "$sqrt_cols" ] || preferred_cols="$sqrt_cols"
  [ "$preferred_cols" -le "$member_count" ] || preferred_cols="$member_count"
  [ "$preferred_cols" -le 3 ] || preferred_cols=3

  local candidates='[]'
  local resolved_cols=0 resolved_rows=0 c r required_member_cols required_total_cols required_total_rows
  for ((c = preferred_cols; c >= 1; c--)); do
    r=$(( (member_count + c - 1) / c ))
    required_member_cols=$((c * 60 + (c - 1)))
    required_total_cols=$((48 + 1 + required_member_cols))
    required_total_rows=$((r * 12 + (r - 1)))
    candidates="$(jq -c \
      --argjson cols "$c" --argjson rows "$r" --argjson required_cols "$required_total_cols" \
      --argjson required_rows "$required_total_rows" --argjson feasible "$([ "$target_cols" -ge "$required_total_cols" ] && [ "$target_rows" -ge "$required_total_rows" ] && echo true || echo false)" \
      '. + [{cols:$cols,rows:$rows,required_total_cols:$required_cols,required_total_rows:$required_rows,feasible:$feasible}]' \
      <<< "$candidates")"
    if [ "$resolved_cols" -eq 0 ] && [ "$target_cols" -ge "$required_total_cols" ] && [ "$target_rows" -ge "$required_total_rows" ]; then
      resolved_cols="$c"
      resolved_rows="$r"
    fi
  done

  if [ "$resolved_cols" -eq 0 ]; then
    jq -nc \
      --argjson target_cols "$target_cols" --argjson target_rows "$target_rows" \
      --argjson member_count "$member_count" --argjson max_cols "$max_cols" \
      --argjson candidates "$candidates" \
      '{status:"failed",error:{code:"LAYOUT_NOT_FEASIBLE",message:"No Grid candidate satisfies the minimum pane geometry"},geometry:{target_cols:$target_cols,target_rows:$target_rows,member_count:$member_count,max_cols:$max_cols},candidates:$candidates}'
    return 0
  fi

  local root_usable_cols=$((target_cols - 1))
  local member_min_cols=$((resolved_cols * 60 + (resolved_cols - 1)))
  local max_orch_cols=$((root_usable_cols - member_min_cols))
  local preferred_orch_cols=$(( (root_usable_cols * 25 + 50) / 100 ))
  local orch_cols="$preferred_orch_cols"
  [ "$orch_cols" -ge 48 ] || orch_cols=48
  [ "$orch_cols" -le "$max_orch_cols" ] || orch_cols="$max_orch_cols"
  local member_region_cols=$((root_usable_cols - orch_cols))
  local root_ratio
  root_ratio="$(herdr_layout_plan_round_ratio "$orch_cols" "$root_usable_cols")"

  declare -a row_heights row_member_counts
  local row_content=$((target_rows - (resolved_rows - 1)))
  local row_base=$((row_content / resolved_rows))
  local row_extra=$((row_content % resolved_rows))
  for ((r = 0; r < resolved_rows; r++)); do
    row_heights[r]=$((row_base + (r < row_extra ? 1 : 0)))
    row_member_counts[r]="$resolved_cols"
  done
  row_member_counts[$((resolved_rows - 1))]=$((member_count - resolved_cols * (resolved_rows - 1)))

  local row_heights_json='[]' row_counts_json='[]'
  for ((r = 0; r < resolved_rows; r++)); do
    row_heights_json="$(jq -c --argjson value "${row_heights[r]}" '. + [$value]' <<< "$row_heights_json")"
    row_counts_json="$(jq -c --argjson value "${row_member_counts[r]}" '. + [$value]' <<< "$row_counts_json")"
  done

  local row_widths_json='[]'
  for ((r = 0; r < resolved_rows; r++)); do
    local row_count="${row_member_counts[r]}"
    local content=$((member_region_cols - (row_count - 1)))
    local base=$((content / row_count))
    local extra=$((content % row_count))
    local widths='[]'
    local j
    for ((j = 0; j < row_count; j++)); do
      widths="$(jq -c --argjson value "$((base + (j < extra ? 1 : 0)))" '. + [$value]' <<< "$widths")"
    done
    row_widths_json="$(jq -c --argjson value "$widths" '. + [$value]' <<< "$row_widths_json")"
  done

  HERDR_LAYOUT_PLAN_GEOMETRY='{}'
  HERDR_LAYOUT_PLAN_SPLITS='[]'
  HERDR_LAYOUT_PLAN_BINDINGS='{}'
  herdr_layout_plan_add_geometry orch 0 0 "$orch_cols" "$target_rows"
  herdr_layout_plan_add_geometry member-root "$((orch_cols + 1))" 0 "$member_region_cols" "$target_rows"

  herdr_layout_plan_add_split orch orch member-root right "$root_ratio" \
    0 0 "$target_cols" "$target_rows" \
    0 0 "$orch_cols" "$target_rows" \
    "$((orch_cols + 1))" 0 "$member_region_cols" "$target_rows"

  local r_idx
  for ((r_idx = 0; r_idx < resolved_rows; r_idx++)); do
    local row_ref="row-$r_idx"
    local row_y=0
    local prior
    for ((prior = 0; prior < r_idx; prior++)); do
      row_y=$((row_y + row_heights[prior] + 1))
    done
    herdr_layout_plan_add_geometry "$row_ref" "$((orch_cols + 1))" "$row_y" "$member_region_cols" "${row_heights[r_idx]}"
  done

  local current_ref="member-root"
  local current_y=0
  for ((r_idx = 1; r_idx < resolved_rows; r_idx++)); do
    local prior_row=$((r_idx - 1))
    local retained_ref="row-$prior_row"
    local created_ref="row-$r_idx"
    local current_rows="${row_heights[prior_row]}"
    local target_area_rows=$((target_rows - current_y))
    local ratio
    ratio="$(herdr_layout_plan_round_ratio "$current_rows" "$((target_area_rows - 1))")"
    local created_remaining_rows=$((target_area_rows - current_rows - 1))
    herdr_layout_plan_add_split "$current_ref" "$retained_ref" "$created_ref" down "$ratio" \
      "$((orch_cols + 1))" "$current_y" "$member_region_cols" "$target_area_rows" \
      "$((orch_cols + 1))" "$current_y" "$member_region_cols" "$current_rows" \
      "$((orch_cols + 1))" "$((current_y + current_rows + 1))" "$member_region_cols" "$created_remaining_rows"
    current_ref="$created_ref"
    current_y=$((current_y + current_rows + 1))
  done

  local member_index=0
  for ((r_idx = 0; r_idx < resolved_rows; r_idx++)); do
    local row_count="${row_member_counts[r_idx]}"
    local widths_json
    widths_json="$(jq -c ".[$r_idx]" <<< "$row_widths_json")"
    local row_x=$((orch_cols + 1))
    local row_y=0
    for ((prior = 0; prior < r_idx; prior++)); do
      row_y=$((row_y + row_heights[prior] + 1))
    done
    local row_ref
    if [ "$resolved_rows" -eq 1 ]; then
      row_ref="member-root"
    else
      row_ref="row-$r_idx"
    fi
    local row_target_cols="$member_region_cols"
    local row_current_ref="$row_ref"
    local row_current_x="$row_x"
    local j_idx
    if [ "$row_count" -eq 1 ]; then
      herdr_layout_plan_add_geometry "member-$member_index" "$row_x" "$row_y" "$member_region_cols" "${row_heights[r_idx]}"
      HERDR_LAYOUT_PLAN_BINDINGS="$(jq -c --arg member "member-$member_index" --arg row "$row_ref" '.[$member] = $row' <<< "$HERDR_LAYOUT_PLAN_BINDINGS")"
      member_index=$((member_index + 1))
      continue
    fi
    for ((j_idx = 0; j_idx < row_count - 1; j_idx++)); do
      local retained_width created_width created_x
      retained_width="$(jq -r ".[$j_idx]" <<< "$widths_json")"
      created_width=$((row_target_cols - retained_width - 1))
      created_x=$((row_current_x + retained_width + 1))
      local target_rows_here="${row_heights[r_idx]}"
      local horizontal_ratio
      horizontal_ratio="$(herdr_layout_plan_round_ratio "$retained_width" "$((row_target_cols - 1))")"
      local member_ref="member-$member_index"
      local next_ref
      if [ "$j_idx" -eq $((row_count - 2)) ]; then
        next_ref="member-$((member_index + 1))"
      else
        next_ref="row-$r_idx-tail-$((j_idx + 1))"
      fi
      herdr_layout_plan_add_split "$row_current_ref" "$member_ref" "$next_ref" right "$horizontal_ratio" \
        "$row_current_x" "$row_y" "$row_target_cols" "$target_rows_here" \
        "$row_current_x" "$row_y" "$retained_width" "$target_rows_here" \
        "$created_x" "$row_y" "$created_width" "$target_rows_here"
      herdr_layout_plan_add_geometry "$member_ref" "$row_current_x" "$row_y" "$retained_width" "$target_rows_here"
      HERDR_LAYOUT_PLAN_BINDINGS="$(jq -c --arg member "$member_ref" --arg ref "$member_ref" '.[$member] = $ref' <<< "$HERDR_LAYOUT_PLAN_BINDINGS")"
      if [[ "$next_ref" == row-* ]]; then
        herdr_layout_plan_add_geometry "$next_ref" "$created_x" "$row_y" "$created_width" "$target_rows_here"
        HERDR_LAYOUT_PLAN_BINDINGS="$(jq -c --arg member "$next_ref" --arg ref "$next_ref" '.[$member] = $ref' <<< "$HERDR_LAYOUT_PLAN_BINDINGS")"
      else
        herdr_layout_plan_add_geometry "$next_ref" "$created_x" "$row_y" "$created_width" "$target_rows_here"
      fi
      row_current_ref="$next_ref"
      row_current_x="$created_x"
      row_target_cols="$created_width"
      member_index=$((member_index + 1))
    done
    # The last member of a row is the final created pane from the row splits.
    member_index=$((member_index + 1))
  done

  local member_refs='[]'
  local mi
  for ((mi = 0; mi < member_count; mi++)); do
    # Geometry is authoritative for the logical assignment.  A member ref is
    # present for every member, including the single-cell row case.
    member_refs="$(jq -c --arg ref "member-$mi" '. + [$ref]' <<< "$member_refs")"
    HERDR_LAYOUT_PLAN_BINDINGS="$(jq -c --arg member "member-$mi" '.[$member] //= $member' <<< "$HERDR_LAYOUT_PLAN_BINDINGS")"
  done

  jq -nc \
    --argjson resolved_cols "$resolved_cols" --argjson resolved_rows "$resolved_rows" \
    --argjson geometry "$(jq -nc \
      --argjson target_cols "$target_cols" --argjson target_rows "$target_rows" \
      --argjson orch_cols "$orch_cols" --argjson member_region_cols "$member_region_cols" \
      --argjson row_heights "$row_heights_json" --argjson row_member_counts "$row_counts_json" \
      --argjson row_widths "$row_widths_json" --argjson refs "$HERDR_LAYOUT_PLAN_GEOMETRY" \
      '{target_cols:$target_cols,target_rows:$target_rows,orch_cols:$orch_cols,member_region_cols:$member_region_cols,row_heights:$row_heights,row_member_counts:$row_member_counts,row_widths:$row_widths,refs:$refs}')" \
    --argjson splits "$HERDR_LAYOUT_PLAN_SPLITS" --argjson member_refs "$member_refs" \
    --argjson member_bindings "$HERDR_LAYOUT_PLAN_BINDINGS" \
    '{status:"ok",resolved_cols:$resolved_cols,resolved_rows:$resolved_rows,geometry:$geometry,splits:$splits,member_refs:$member_refs,member_bindings:$member_bindings}'
}

herdr_layout_plan_main() {
  local input="${1:-}"
  if [ -n "$input" ] && [ -f "$input" ]; then
    input="$(cat "$input")"
  elif [ -z "$input" ]; then
    input="$(cat)"
  fi
  herdr_layout_plan_generate "$input"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  herdr_layout_plan_main "${1:-}"
fi
