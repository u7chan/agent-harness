#!/usr/bin/env node
/**
 * Read, validate, and write the approved team record of one repository.
 *
 * `team-record.sh` resolves the repository root and its `origin` remote URL
 * and passes them as `--repo-root` / `--origin-url`; this file owns the record
 * file and the model-spec resolver call. The record format, the key
 * derivation, and the validation rules live in `lib/team-record.mjs`.
 *
 * Output contract (exactly one stdout line, exit status 0 only for
 * `result=ok`, 2 for an argument error):
 *
 *   resolve:
 *     command=resolve record=<path> present=<true|false> result=<ok|missing|invalid|unresolved> ...
 *     result=ok        every recorded role resolved through the model-spec resolver
 *     result=missing   no record file for this repository
 *     result=invalid   the file is unreadable JSON or fails the record contract
 *     result=unresolved a recorded or required role does not resolve
 *   write:
 *     command=write record=<path> result=<ok|invalid|unresolved> written=<true|false> ...
 *
 * The record file is a user asset: the write is atomic (temporary file plus
 * rename) and the file mode is 0600.
 */

import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync, writeSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  REQUIRED_ROLE_NAMES,
  ROLE_NAMES,
  buildRecord,
  field,
  formatRoleSpec,
  isSafeField,
  parseOriginKey,
  parseRoleSpec,
  recordFileName,
  recordKeyFromPath,
  renderStoredRole,
  validateRecord,
} from "./lib/team-record.mjs";

/** A resolver run that hangs must not hold the kickoff pane forever. */
const RESOLVER_TIMEOUT_MS = 120000;

/** Resolver results that mean "this specification is usable". */
const OK_RESULT = "ok";

const USAGE = `Usage: team-record.sh <resolve|write> [options]

Reads, validates, and writes the approved team record for one repository:
  \${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/pi-issue-pr-workflow/teams/<key>.json
\`<key>\` is \`owner__repo\` derived from \`origin\`, or the repository root path
when the remote does not name exactly \`owner/repo\`.

Common options:
  --repo-root <dir>   repository root used to derive the record key
  --origin-url <url>  \`origin\` URL of that root (empty means no resolvable origin)
  --record <file>     record file path; overrides the derived path
  --resolver <path>   model-spec resolver (default: the sibling resolve-model-spec.sh)

resolve options:
  --require-role <role>
      also require this role in the record (repeatable). Any role name is
      accepted, so a role this version does not know yet answers \`absent\`
      instead of failing the argument check, and the kickoff returns to the
      proposal path.

write options:
  --role <role>=<provider>/<model>/<thinking>
      team member to record (repeatable); impl, review, and pr-fix are
      required, tester is optional, and the role name must be one of them.
      The provider is the first segment and the thinking level is the last
      one, so a model ID may contain \`/\`.
  --pr-fix-shared-with-impl <true|false>
      required; whether pr-fix reuses the impl agent. When \`true\`, the
      pr-fix specification must equal the impl specification.

resolve prints one key=value line and exits nonzero unless \`result=ok\`.
write prints one key=value line and exits nonzero unless \`result=ok\`; it
validates every role through the resolver before writing, so the record only
ever holds specifications that resolved at write time.`;

/** Print the single key=value line; `writeSync` keeps it complete on exit. */
function emit(fields) {
  const line = fields
    .map(([key, value]) => `${key}=${field(value === undefined || value === null ? "" : String(value))}`)
    .join(" ");
  writeSync(1, `${line}\n`);
}

function emitUsageError(command, reason) {
  emit([
    ["command", command],
    ["record", ""],
    ["result", "invalid"],
    ["reason", reason || "usage"],
  ]);
  return 2;
}

function parseBoolean(text) {
  if (text === "true") {
    return true;
  }
  if (text === "false") {
    return false;
  }
  return null;
}

function parseArgs(argv) {
  const options = {
    command: "",
    repoRoot: "",
    originUrl: null,
    record: "",
    resolver: "",
    requireRoles: [],
    roleSpecs: [],
    prFixSharedWithImpl: null,
  };
  const values = {
    "--repo-root": (value) => {
      if (!isSafeField(value) || value === "") {
        throw new Error("--repo-root requires a non-empty path");
      }
      options.repoRoot = value;
    },
    "--origin-url": (value) => {
      options.originUrl = value;
    },
    "--record": (value) => {
      if (value === "") {
        throw new Error("--record requires a non-empty path");
      }
      options.record = value;
    },
    "--resolver": (value) => {
      if (value === "") {
        throw new Error("--resolver requires a non-empty path");
      }
      options.resolver = value;
    },
    "--require-role": (value) => {
      options.requireRoles.push(value);
    },
    "--role": (value) => {
      options.roleSpecs.push(value);
    },
    "--pr-fix-shared-with-impl": (value) => {
      const parsed = parseBoolean(value);
      if (parsed === null) {
        throw new Error("--pr-fix-shared-with-impl accepts only true or false");
      }
      options.prFixSharedWithImpl = parsed;
    },
  };
  for (let i = 0; i < argv.length; i += 1) {
    const argument = argv[i];
    if (argument === "-h" || argument === "--help") {
      return { help: true };
    }
    if (i === 0) {
      if (argument !== "resolve" && argument !== "write") {
        return { options, error: `unknown command '${argument}'` };
      }
      options.command = argument;
      continue;
    }
    const apply = values[argument];
    if (!apply) {
      return { options, error: `unknown argument '${argument}'` };
    }
    i += 1;
    if (i >= argv.length) {
      return { options, error: `${argument} requires a value` };
    }
    try {
      apply(argv[i]);
    } catch (error) {
      return { options, error: error.message };
    }
  }
  if (!options.command) {
    return { options, error: "a command (resolve or write) is required" };
  }
  return { options };
}

/** Root of pi's configuration directory. */
function piAgentDir() {
  const configured = (process.env.PI_CODING_AGENT_DIR ?? "").trim();
  const base = configured !== "" ? configured : path.join(os.homedir(), ".pi", "agent");
  return path.resolve(base);
}

/** Record file path for this invocation. */
function recordPath(options) {
  if (options.record) {
    return path.resolve(options.record);
  }
  const repoRoot = options.repoRoot ? path.resolve(options.repoRoot) : process.cwd();
  const key = parseOriginKey(options.originUrl ?? "") ?? recordKeyFromPath(repoRoot);
  return path.join(piAgentDir(), "pi-issue-pr-workflow", "teams", recordFileName(key));
}

/** Model-spec resolver to use; the sibling script is the default. */
function resolverPath(options) {
  if (options.resolver) {
    return path.resolve(options.resolver);
  }
  return path.join(path.dirname(fileURLToPath(import.meta.url)), "resolve-model-spec.sh");
}

/**
 * Resolve one specification through the resolver.
 *
 * @returns {{result: string}} the resolver's own result token, or a local
 *   failure token when the resolver could not run or did not report a result
 */
function runResolver(resolver, spec) {
  const spawned = spawnSync(
    resolver,
    ["--provider", spec.provider, "--model", spec.model, "--thinking", spec.thinking],
    { encoding: "utf8", timeout: RESOLVER_TIMEOUT_MS, maxBuffer: 4 * 1024 * 1024 },
  );
  if (spawned.error) {
    return { result: spawned.error.code === "ETIMEDOUT" ? "timeout" : "error" };
  }
  const stdout = `${spawned.stdout ?? ""}`;
  const match = /(?:^|\s)result=(\S+)/.exec(stdout);
  if (!match) {
    return { result: "unparsed" };
  }
  if (match[1] === OK_RESULT && spawned.status !== 0) {
    return { result: "error" };
  }
  return { result: match[1] };
}

/** Role fields for diagnostics; rendered from whatever the file stores. */
function roleFields(raw) {
  const fields = [];
  for (const role of ROLE_NAMES) {
    const spec = renderStoredRole(raw?.roles?.[role]);
    fields.push([role, spec]);
  }
  return fields;
}

function commandResolve(options) {
  const file = recordPath(options);
  const base = [
    ["command", "resolve"],
    ["record", file],
  ];
  let raw;
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") {
      emit([...base, ["present", "false"], ["result", "missing"], ["reason", "absent"]]);
      return 1;
    }
    emit([...base, ["present", "true"], ["result", "invalid"], ["reason", "unreadable"]]);
    return 1;
  }
  try {
    raw = JSON.parse(text);
  } catch {
    emit([...base, ["present", "true"], ["result", "invalid"], ["reason", "bad-json"]]);
    return 1;
  }

  const validation = validateRecord(raw);
  if (validation.result !== "ok") {
    emit([
      ...base,
      ["present", "true"],
      ["result", "invalid"],
      ["reason", validation.reason],
      ...roleFields(raw),
    ]);
    return 1;
  }

  const record = validation.record;
  const unresolvedFields = (role, result) => [
    ...base,
    ["present", "true"],
    ["result", "unresolved"],
    ["reason", "role"],
    ["unresolved", role],
    ["unresolved_result", result],
    ["pr_fix_shared_with_impl", String(record.pr_fix_shared_with_impl)],
    ...roleFields(record),
  ];

  for (const role of options.requireRoles) {
    if (!isSafeField(role) || role === "") {
      emit([...base, ["present", "true"], ["result", "invalid"], ["reason", "usage"]]);
      return 2;
    }
    if (!Object.prototype.hasOwnProperty.call(record.roles, role)) {
      emit(unresolvedFields(role, "absent"));
      return 1;
    }
  }

  const resolver = resolverPath(options);
  for (const role of ROLE_NAMES) {
    const spec = record.roles[role];
    if (!spec) {
      continue;
    }
    const resolution = runResolver(resolver, spec);
    if (resolution.result !== OK_RESULT) {
      emit(unresolvedFields(role, resolution.result));
      return 1;
    }
  }

  const teamFields = ROLE_NAMES.filter((role) => record.roles[role]).map((role) => [
    role,
    formatRoleSpec(record.roles[role]),
  ]);
  emit([
    ...base,
    ["present", "true"],
    ["result", "ok"],
    ["pr_fix_shared_with_impl", String(record.pr_fix_shared_with_impl)],
    ...teamFields,
  ]);
  return 0;
}

/**
 * Write the record atomically: a 0600 temporary file in the target directory
 * is renamed over the record, so a reader never sees a partial file.
 */
function writeRecordFile(file, record) {
  const directory = path.dirname(file);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const temporary = path.join(directory, `.${path.basename(file)}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`);
  try {
    writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { flag: "wx" });
    chmodSync(temporary, 0o600);
    renameSync(temporary, file);
  } catch (error) {
    try {
      rmSync(temporary, { force: true });
    } catch {
      // The temporary file is best-effort cleanup; the write error is reported below.
    }
    throw error;
  }
}

function commandWrite(options) {
  const file = recordPath(options);
  const base = [
    ["command", "write"],
    ["record", file],
  ];
  const fail = (result, reason, extra = []) => {
    emit([...base, ["result", result], ["written", "false"], ["reason", reason], ...extra]);
    return result === "invalid" && reason === "usage" ? 2 : 1;
  };

  if (options.prFixSharedWithImpl === null) {
    return fail("invalid", "usage");
  }
  const roles = {};
  for (const item of options.roleSpecs) {
    const separator = item.indexOf("=");
    const role = separator < 0 ? "" : item.slice(0, separator);
    const spec = separator < 0 ? null : parseRoleSpec(item.slice(separator + 1));
    if (!ROLE_NAMES.includes(role)) {
      return fail("invalid", "unknown-role");
    }
    if (!spec) {
      return fail("invalid", "bad-role-spec");
    }
    if (Object.prototype.hasOwnProperty.call(roles, role)) {
      return fail("invalid", "duplicate-role");
    }
    roles[role] = spec;
  }
  for (const role of REQUIRED_ROLE_NAMES) {
    if (!Object.prototype.hasOwnProperty.call(roles, role)) {
      return fail("invalid", "missing-role");
    }
  }
  if (options.prFixSharedWithImpl && formatRoleSpec(roles["pr-fix"]) !== formatRoleSpec(roles["impl"])) {
    return fail("invalid", "bad-shared");
  }

  const resolver = resolverPath(options);
  for (const role of ROLE_NAMES) {
    const spec = roles[role];
    if (!spec) {
      continue;
    }
    const resolution = runResolver(resolver, spec);
    if (resolution.result !== OK_RESULT) {
      return fail("unresolved", "role", [
        ["unresolved", role],
        ["unresolved_result", resolution.result],
      ]);
    }
  }

  try {
    writeRecordFile(file, buildRecord(roles, options.prFixSharedWithImpl));
  } catch (error) {
    writeSync(2, `team-record: cannot write '${file}': ${error instanceof Error ? error.message : String(error)}\n`);
    return fail("invalid", "write-failed");
  }

  const written = ROLE_NAMES.filter((role) => roles[role]);
  emit([
    ...base,
    ["result", "ok"],
    ["written", "true"],
    ["pr_fix_shared_with_impl", String(options.prFixSharedWithImpl)],
    ["roles", written.join(",")],
  ]);
  return 0;
}

function main() {
  const parsed = parseArgs(process.argv.slice(2));
  if (parsed.help) {
    writeSync(1, `${USAGE}\n`);
    return 0;
  }
  if (parsed.error) {
    writeSync(2, `team-record: ${parsed.error}. Run team-record.sh --help for usage.\n`);
    return emitUsageError(parsed.options.command, "usage");
  }
  return parsed.options.command === "resolve" ? commandResolve(parsed.options) : commandWrite(parsed.options);
}

process.exit(main());
