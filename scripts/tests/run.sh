#!/usr/bin/env bash
# Root-script test runner: the skill manifest check and the harness-neutral
# distribution command. Both suites are hermetic: they build fixture
# repositories under a temporary directory, need no network, and never call a
# harness CLI or touch a real distribution root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for suite in skill-manifest skill-distribution; do
  printf '\n== %s ==\n' "$suite"
  "$SCRIPT_DIR/$suite.sh"
done
