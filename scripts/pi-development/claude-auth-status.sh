#!/usr/bin/env bash
# Claude CLI authentication preflight.
#
# `claude auth status` reports the local account state without a network call,
# so a workflow can stop before it launches anything with an unauthenticated
# CLI. This helper reduces that document to the two fields a launcher needs and
# keeps everything else inside the helper: the account email, the organization,
# the subscription, and the other fields of the status document never appear in
# the output, and no file is written.
#
# Output contract (exactly one stdout line):
#
#   command=auth-status result=<ok|unauthenticated|error> loggedIn=<true|false> \
#     configDirectory=<path|-> [reason=<token>]
#
# `configDirectory` is `-` when the status document did not provide a usable
# absolute path. Reasons: `claude-missing`, `node-missing`, `bad-json`,
# `missing-config-directory`, `config-directory-not-absolute`,
# `config-directory-unsafe`, `not-logged-in`, `status-failed`, and `usage`.
#
# Exit status is 0 only for result=ok, 1 for every other result, and 2 for an
# argument error.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: claude-auth-status.sh

Runs `claude auth status` (no network call, no session) and prints one
key=value line with the login state and the Claude config directory:

  command=auth-status result=<ok|unauthenticated|error> loggedIn=<true|false> configDirectory=<path|-> [reason=<token>]

Exit status is 0 only for result=ok. The account email, the organization, and
the other fields of the status document are never printed, and no file is read
or written beyond the CLI's own status call. `node` parses the status document,
so it is required on PATH.
EOF
}

emit() { # result loggedIn configDirectory [reason]
  local line="command=auth-status result=$1 loggedIn=$2 configDirectory=$3"
  if [ -n "${4:-}" ]; then
    line="$line reason=$4"
  fi
  printf '%s\n' "$line"
}

case "${1:-}" in
  "")
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    emit error false - usage
    exit 2
    ;;
esac

command -v claude >/dev/null 2>&1 || {
  emit error false - claude-missing
  exit 1
}

command -v node >/dev/null 2>&1 || {
  emit error false - node-missing
  exit 1
}

# The status document is JSON on stdout; stderr is discarded so a CLI notice can
# never leak into the record. A nonzero exit is kept: `loggedIn=false` exits 1.
status_output="$(claude auth status 2>/dev/null)"
status_rc=$?

# Reduce the document to the two fields this contract owns. The probe exits 3
# when the document is not an object with a boolean login and a string path, so
# a changed or missing field is an error rather than an assumed value.
parsed="$(printf '%s' "$status_output" | node --input-type=module -e '
import { readFileSync } from "node:fs";

let document;
try {
  document = JSON.parse(readFileSync(0, "utf8"));
} catch {
  process.exit(3);
}
if (
  document === null ||
  typeof document !== "object" ||
  Array.isArray(document) ||
  typeof document.loggedIn !== "boolean"
) {
  process.exit(3);
}
// A missing or non-string path is printed as an empty field: whether that is
// an error and which reason it carries belongs to the caller below.
const configDirectory = typeof document.configDirectory === "string" ? document.configDirectory : "";
process.stdout.write(`${document.loggedIn}\n${configDirectory}\n`);
' 2>/dev/null)"
parse_rc=$?

if [ "$parse_rc" -ne 0 ]; then
  emit error false - bad-json
  exit 1
fi

logged=''
config_dir=''
{
  IFS= read -r logged || true
  # Read to end-of-input so a path that contains a newline survives the read
  # and is rejected by the safety check below; one trailing newline is the
  # record separator of the probe, not part of the path.
  IFS= read -r -d '' config_dir || true
} <<< "$parsed"
config_dir="${config_dir%$'\n'}"

case "$logged" in
  true | false) ;;
  *)
    emit error false - bad-json
    exit 1
    ;;
esac

if [ -z "$config_dir" ]; then
  emit error "$logged" - missing-config-directory
  exit 1
fi
case "$config_dir" in
  /*) ;;
  *)
    emit error "$logged" - config-directory-not-absolute
    exit 1
    ;;
esac
if [[ "$config_dir" =~ [[:space:][:cntrl:]] ]]; then
  emit error "$logged" - config-directory-unsafe
  exit 1
fi

if [ "$logged" != true ]; then
  emit unauthenticated false "$config_dir" not-logged-in
  exit 1
fi

if [ "$status_rc" -ne 0 ]; then
  emit error true "$config_dir" status-failed
  exit 1
fi

emit ok true "$config_dir"
exit 0
