#!/usr/bin/env bash
# Workflow documentation contracts; shared helper tests run independently.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for suite in team-profiles ui-tester-evidence fixed-lines sequential-runs; do
  printf '\n== %s ==\n' "$suite"
  "$SCRIPT_DIR/$suite.sh"
done
