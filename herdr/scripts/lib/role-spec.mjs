/**
 * Parse one canonical role specification and print its fields.
 *
 * The grammar itself is not restated here. `scripts/pi-development/lib/team-record.mjs`
 * owns the harness prefix, the split rules, the vocabularies, and the canonical
 * formatting, so a caller that writes a `launch:` line and a caller that reads
 * one share one parser; the launcher only adds the transport to shell.
 *
 * Output: one compact JSON object on stdout, with the harness, that harness's
 * own fields, and the canonical prefixed `spec` string. Values are always
 * whitespace-free because the grammar rejects those, so a caller can compare
 * them byte for byte with a `launch:` line.
 *
 * Exit status: 0 parsed, 1 not a usable specification, 2 usage.
 */
import {
  formatRoleSpec,
  parseRoleSpec,
} from "../../../scripts/pi-development/lib/team-record.mjs";

const args = process.argv.slice(2);

if (args.length !== 1) {
  process.stderr.write("role-spec: expected exactly one role specification\n");
  process.exit(2);
}

const [text] = args;
const spec = parseRoleSpec(text);
if (!spec) {
  process.stderr.write(`role-spec: not a usable role specification: ${JSON.stringify(text)}\n`);
  process.exit(1);
}

const fields =
  spec.harness === "claude"
    ? {
        harness: "claude",
        model: spec.model,
        effort: spec.effort,
        permission_mode: spec.permission_mode,
      }
    : {
        harness: "pi",
        provider: spec.provider,
        model: spec.model,
        thinking: spec.thinking,
      };

process.stdout.write(`${JSON.stringify({ ...fields, spec: formatRoleSpec(spec) })}\n`);
