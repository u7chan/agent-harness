#!/usr/bin/env bash
set -u

test_pass_count=0
test_fail_count=0
test_failures=()

assert_eq() {
  if [ "$1" != "$2" ]; then
    echo "  expected: $2, got: $1"
    return 1
  fi
}

assert_contains() {
  local string="$1"
  local substring="$2"

  case "$string" in
    *"$substring"*)
      ;;
    *)
      echo "  expected '$string' to contain '$substring'"
      return 1
      ;;
  esac
}

assert_json_eq() {
  local json="$1"
  local jq_filter="$2"
  local expected="$3"
  local actual
  local jq_status

  actual="$(printf '%s\n' "$json" | jq -e -r "$jq_filter" 2>/dev/null)" && jq_status=0 || jq_status=$?
  if [ "$jq_status" -ne 0 ] || [ "$actual" != "$expected" ]; then
    echo "  expected: $expected, got: $actual"
    return 1
  fi
}

run_test() {
  local test_name="$1"
  local output

  if output="$("$test_name" 2>&1)"; then
    test_pass_count=$((test_pass_count + 1))
    echo "PASS: $test_name"
  else
    test_fail_count=$((test_fail_count + 1))
    test_failures+=("$test_name: $output")
    echo "FAIL: $test_name"
    [ -n "$output" ] && echo "$output"
  fi
}

print_summary() {
  local total=$((test_pass_count + test_fail_count))

  echo
  echo "Tests: $total, Passed: $test_pass_count, Failed: $test_fail_count"

  if [ "$test_fail_count" -gt 0 ]; then
    echo "Failures:"
    local failure
    for failure in "${test_failures[@]}"; do
      echo "- $failure"
    done
  fi

  exit "$test_fail_count"
}
