#!/usr/bin/env bash
set -u

setup_fixture() {
  local contract_dir
  local gh_dir
  local common_name

  contract_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  gh_dir="$(cd "$contract_dir/../.." && pwd)"
  FIXTURE_DIR="$(mktemp -d /tmp/gh-test-XXXXXX)"

  mkdir -p "$FIXTURE_DIR/scripts/common" "$FIXTURE_DIR/scripts/actions"
  cp "$gh_dir/scripts/gh.sh" "$FIXTURE_DIR/scripts/gh.sh"
  ln -s "$gh_dir/actions.json" "$FIXTURE_DIR/actions.json"

  cat > "$FIXTURE_DIR/scripts/common/auth.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

check_auth() {
  if [ "${GH_TEST_AUTH_RESULT:-0}" = "0" ]; then
    return 0
  else
    echo "auth failed (mock)" >&2
    return 1
  fi
}

get_host() {
  echo "github.com"
}
EOF

  for common_name in envelope target http file attach; do
    ln -s "$gh_dir/scripts/common/$common_name.sh" \
      "$FIXTURE_DIR/scripts/common/$common_name.sh"
  done
}

teardown_fixture() {
  rm -rf "$FIXTURE_DIR"
}

fixture_gh() {
  "$FIXTURE_DIR/scripts/gh.sh" "$@"
}

add_mock_action() {
  local action_name="$1"
  local script_content="$2"
  local action_file="$FIXTURE_DIR/scripts/actions/${action_name}.sh"

  printf '%s\n' "$script_content" > "$action_file"
  chmod +x "$action_file"
}

register_mock_action() {
  local action_name="$1"
  local input_schema
  local script_content

  if [ "$#" -ge 3 ]; then
    input_schema="$2"
    script_content="$3"
  else
    input_schema="{}"
    script_content="$2"
  fi

  local actions_file="$FIXTURE_DIR/actions.json"
  local actions_source
  local actions_tmp

  add_mock_action "$action_name" "$script_content"

  if [ -L "$actions_file" ]; then
    actions_source="$(readlink -f "$actions_file")"
    unlink "$actions_file"
    cp "$actions_source" "$actions_file"
  fi

  actions_tmp="$FIXTURE_DIR/actions.json.tmp"
  jq --arg action_name "$action_name" \
    --argjson input_schema "$input_schema" \
    '.actions += [{
      name: $action_name,
      description: "contract-test mock action",
      category: "contract-test",
      permission: "read",
      requires_auth: false,
      input_schema: $input_schema,
      output_schema: {data: {type: "object"}}
    }]' \
    "$actions_file" > "$actions_tmp"
  mv "$actions_tmp" "$actions_file"
}
