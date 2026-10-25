#!/usr/bin/env node
/**
 * Read, validate, and write team profiles.
 *
 * The user asset is `${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/pi-issue-pr-workflow`:
 * `profiles/<name>.json` holds one team composition and `active` names the
 * profile a run uses when it states none. The profile format and the validation
 * rules live in `lib/team-record.mjs`.
 *
 * Output contract (exactly one stdout line, exit status 0 only for
 * `result=ok`, 2 for an argument error):
 *
 *   resolve:
 *     command=resolve profile=<name> source=<explicit|active|default> record=<path>
 *       profiles_present=<true|false|> present=<true|false>
 *       result=<ok|missing|invalid|unresolved> [reason=<token>] ...
 *     result=ok         every role of the selected profile resolved
 *     result=missing    no profile file for the selected name
 *     result=invalid    unreadable JSON, an unreadable `active` or
 *                       `profiles/`, a name violation, or the profile contract
 *     result=unresolved a role does not resolve
 *
 * `profiles_present` is empty only when `profiles/` exists but cannot be read
 * reliably: enumeration fails (permission denied, or not a directory), or a
 * `.json` entry cannot be inspected. That is never the `profiles_present=false`
 * bootstrap state: the result is `<invalid>` with `reason=unreadable`. An
 * unreadable `active` or profile file reports the same reason and is never
 * treated as absent.
 *   use:
 *     command=use profile=<name> active=<path> result=<ok|missing|invalid|unresolved>
 *       written=<true|false> [reason=<token>] ...
 *   write:
 *     command=write profile=<name> record=<path> result=<ok|invalid|unresolved>
 *       written=<true|false> [reason=<token>] ...
 *
 * `use` writes `active` and `write` writes one profile; neither changes the
 * other. Both write atomically (temporary file plus rename) with mode 0600.
 */

import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  chmodSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  ACTIVE_FILE_NAME,
  DEFAULT_PROFILE_NAME,
  REQUIRED_ROLE_NAMES,
  ROLE_NAMES,
  buildProfile,
  field,
  formatRoleSpec,
  isProfileName,
  isSafeField,
  parseActiveContent,
  parseRoleSpec,
  profileFileName,
  renderStoredRole,
  validateProfile,
} from "./lib/team-record.mjs";

/** A resolver run that hangs must not hold the kickoff pane forever. */
const RESOLVER_TIMEOUT_MS = 120000;

/** Resolver results that mean "this specification is usable". */
const OK_RESULT = "ok";

const USAGE = `Usage: team-record.sh <resolve|use|write> [options]

Reads, validates, and writes team profiles under
\${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/pi-issue-pr-workflow:
  profiles/<name>.json   one team composition per profile
  active                 the profile name a run uses when it states none

\`resolve\` selects this run's profile: --profile, then \`active\`, then
\`default\`. An \`active\` that names a missing profile is an error, not a
silent fallback to \`default\`. An unreadable \`profiles/\` (it cannot be
listed, or a \`.json\` entry cannot be inspected) and an unreadable
\`active\` or profile file are \`result=invalid reason=unreadable\`; they
are never reported as absent, so they cannot satisfy the bootstrap
condition.

Common options:
  --resolver <path>   model-spec resolver (default: the sibling resolve-model-spec.sh)

resolve options:
  --profile <name>    use this profile for the run (extensionless name)
  --require-role <role>
      also require this role in the profile (repeatable). Any role name is
      accepted, so a role this version does not know yet answers \`unresolved\`
      instead of failing the argument check, and the kickoff returns to the
      proposal path.

use:
  use <name>          validate the named profile and write it to \`active\`.
      Only a profile whose every role resolves is selected.
  use -- <name>       the same, for a name that starts with \`-\`; \`--\` ends
      option parsing, so \`use -- -fallback\` reaches the profile
      \`profiles/-fallback.json\`.

write options:
  --profile <name>    required; the profile to write, and the only file this
      command changes (\`active\` is untouched).
  --role <role>=<provider>/<model>/<thinking>
      team member to record (repeatable); impl, review, and pr-fix are
      required, ui-tester is optional, and the role name must be one of them.
      The provider is the first segment and the thinking level is the last
      one, so a model ID may contain \`/\`.
  --pr-fix-shared-with-impl <true|false>
      required; whether pr-fix reuses the impl agent. When \`true\`, the
      pr-fix specification must equal the impl specification.

Every command prints one key=value line and exits nonzero unless \`result=ok\`.
\`write\` and \`use\` validate every role through the resolver, so the user asset
only ever holds specifications that resolved at write time.`;

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
    ["profile", ""],
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
    profile: "",
    positional: [],
    resolver: "",
    requireRoles: [],
    roleSpecs: [],
    prFixSharedWithImpl: null,
  };
  const values = {
    "--profile": (value) => {
      if (value === "") {
        throw new Error("--profile requires a name");
      }
      options.profile = value;
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
  let endOfOptions = false;
  for (let i = 0; i < argv.length; i += 1) {
    const argument = argv[i];
    if (i === 0) {
      if (argument === "-h" || argument === "--help") {
        return { help: true };
      }
      if (argument !== "resolve" && argument !== "use" && argument !== "write") {
        return { options, error: `unknown command '${argument}'` };
      }
      options.command = argument;
      continue;
    }
    if (!endOfOptions && argument === "--") {
      endOfOptions = true;
      continue;
    }
    if (!endOfOptions && (argument === "-h" || argument === "--help")) {
      return { help: true };
    }
    if (endOfOptions || !argument.startsWith("-")) {
      options.positional.push(argument);
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
    return { options, error: "a command (resolve, use, or write) is required" };
  }
  if (options.command === "use") {
    if (options.positional.length === 0) {
      return { options, error: "use requires a profile name" };
    }
    if (options.positional.length > 1) {
      return { options, error: "use takes exactly one profile name" };
    }
  } else if (options.positional.length > 0) {
    return { options, error: `unexpected argument '${options.positional[0]}'` };
  }
  return { options };
}

/** Root of pi's configuration directory. */
function piAgentDir() {
  const configured = (process.env.PI_CODING_AGENT_DIR ?? "").trim();
  const base = configured !== "" ? configured : path.join(os.homedir(), ".pi", "agent");
  return path.resolve(base);
}

/**
 * Root of the user asset. "pi-issue-pr-workflow" is the asset's stable
 * identifier, not this skill's distribution path: profiles written before the
 * skill directory was renamed stay readable, so renaming it requires a
 * migration.
 */
function assetDir() {
  return path.join(piAgentDir(), "pi-issue-pr-workflow");
}

function profilesDir() {
  return path.join(assetDir(), "profiles");
}

function activePath() {
  return path.join(assetDir(), ACTIVE_FILE_NAME);
}

function profilePath(name) {
  return path.join(profilesDir(), profileFileName(name));
}

/**
 * Presence of one file, following a symlink.
 *
 * A failed inspection is not an absent file: only `ENOENT` reads as `missing`,
 * so a permission or type error can never become "there is no profile here".
 *
 * @returns {"present" | "missing" | "unreadable"}
 */
function profilePresence(file) {
  try {
    statSync(file);
    return "present";
  } catch (error) {
    return error.code === "ENOENT" ? "missing" : "unreadable";
  }
}

/**
 * Enumeration state of `profiles/`.
 *
 * A failed read is not an empty set: `unreadable` keeps it distinct from the
 * absence of the directory, so it can never satisfy the
 * `profiles_present=false` bootstrap condition. The same holds after a
 * successful enumeration when a candidate entry cannot be inspected: a
 * directory that can be listed but not traversed reports `EACCES` on the
 * child `stat`, which must not read as "that entry does not exist".
 *
 * @returns {{state: "present" | "empty" | "unreadable"}}
 */
function profilesPresence() {
  let names;
  try {
    names = readdirSync(profilesDir());
  } catch (error) {
    return { state: error.code === "ENOENT" ? "empty" : "unreadable" };
  }
  let present = false;
  for (const name of names) {
    if (!name.endsWith(".json")) {
      continue;
    }
    try {
      statSync(path.join(profilesDir(), name));
    } catch {
      return { state: "unreadable" };
    }
    present = true;
  }
  return { state: present ? "present" : "empty" };
}

/**
 * Select this run's profile name, before the profile set is inspected.
 *
 * @returns {{name: string, source: string,
 *   status?: {result: "invalid", reason: string}}}
 */
function selectProfileName(options) {
  if (options.profile !== "") {
    if (!isProfileName(options.profile)) {
      return { name: "", source: "explicit", status: { result: "invalid", reason: "bad-profile-name" } };
    }
    return { name: options.profile, source: "explicit" };
  }
  let text;
  try {
    text = readFileSync(activePath(), "utf8");
  } catch (error) {
    if (error.code === "ENOENT") {
      return { name: DEFAULT_PROFILE_NAME, source: "default" };
    }
    // An unreadable `active` is not an absent one: a permission or type error
    // must never select the implicit default as if no switch were configured.
    return { name: "", source: "active", status: { result: "invalid", reason: "unreadable" } };
  }
  const parsed = parseActiveContent(text);
  if (parsed.result !== "ok") {
    return { name: "", source: "active", status: { result: "invalid", reason: parsed.reason } };
  }
  return { name: parsed.name, source: "active" };
}

/**
 * Select this run's profile and report the profile-set state.
 *
 * `profilesPresent` is `"true"`, `"false"`, or `""` when `profiles/` cannot be
 * enumerated. The unreadable state is an `invalid` result, so an unknown
 * profile set is never reported as `profiles_present=false` and never reaches
 * the bootstrap condition.
 *
 * @returns {{name: string, source: string, profilesPresent: string,
 *   status?: {result: "invalid", reason: string}}}
 */
function selectProfile(options) {
  const selection = selectProfileName(options);
  const presence = profilesPresence();
  const profilesPresent = presence.state === "present" ? "true" : presence.state === "empty" ? "false" : "";
  if (!selection.status && presence.state === "unreadable") {
    return { ...selection, profilesPresent, status: { result: "invalid", reason: "unreadable" } };
  }
  return { ...selection, profilesPresent };
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

/** A resolved `{result, reason}` is an argument error only for a bad name. */
function exitForReason(reason) {
  return reason === "bad-profile-name" || reason === "usage" ? 2 : 1;
}

/**
 * Read and validate one profile file.
 *
 * @returns {{result: "ok", profile: object} | {result: "invalid" | "missing" | "unresolved", ...}}
 */
function loadProfile(file) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") {
      return { result: "missing" };
    }
    return { result: "invalid", reason: "unreadable" };
  }
  let raw;
  try {
    raw = JSON.parse(text);
  } catch {
    return { result: "invalid", reason: "bad-json", raw: undefined };
  }
  const validation = validateProfile(raw);
  if (validation.result !== "ok") {
    return { result: "invalid", reason: validation.reason, raw };
  }
  return { result: "ok", profile: validation.profile, raw };
}

/** Every role of a profile must resolve before the profile is usable. */
function resolveRoles(profile, resolver) {
  for (const role of ROLE_NAMES) {
    const spec = profile.roles[role];
    if (!spec) {
      continue;
    }
    const resolution = runResolver(resolver, spec);
    if (resolution.result !== OK_RESULT) {
      return { role, result: resolution.result };
    }
  }
  return null;
}

function commandResolve(options) {
  const selection = selectProfile(options);
  const file = selection.name === "" ? "" : profilePath(selection.name);
  const base = [
    ["command", "resolve"],
    ["profile", selection.name],
    ["source", selection.source],
    ["record", file],
    ["profiles_present", String(selection.profilesPresent)],
  ];

  if (selection.status) {
    emit([
      ...base,
      ["present", "false"],
      ["result", selection.status.result],
      ["reason", selection.status.reason],
    ]);
    return exitForReason(selection.status.reason);
  }

  const filePresence = file === "" ? "missing" : profilePresence(file);
  if (filePresence === "unreadable") {
    emit([...base, ["present", "false"], ["result", "invalid"], ["reason", "unreadable"]]);
    return 1;
  }
  if (filePresence === "missing") {
    const reason =
      selection.source === "explicit"
        ? "missing-explicit-profile"
        : selection.source === "active"
          ? "missing-active-profile"
          : selection.profilesPresent === "true"
            ? "missing-selected-profile"
            : "no-profiles";
    emit([...base, ["present", "false"], ["result", "missing"], ["reason", reason]]);
    return 1;
  }

  const loaded = loadProfile(file);
  if (loaded.result !== "ok") {
    emit([
      ...base,
      ["present", "true"],
      ["result", "invalid"],
      ["reason", loaded.reason],
      ...(loaded.raw === undefined ? [] : roleFields(loaded.raw)),
    ]);
    return 1;
  }

  const profile = loaded.profile;
  const unresolvedFields = (role, result) => [
    ...base,
    ["present", "true"],
    ["result", "unresolved"],
    ["reason", "role"],
    ["unresolved", role],
    ["unresolved_result", result],
    ["pr_fix_shared_with_impl", String(profile.pr_fix_shared_with_impl)],
    ...roleFields(profile),
  ];

  for (const role of options.requireRoles) {
    if (!isSafeField(role) || role === "") {
      emit([...base, ["present", "true"], ["result", "invalid"], ["reason", "usage"]]);
      return 2;
    }
    if (!Object.prototype.hasOwnProperty.call(profile.roles, role)) {
      emit(unresolvedFields(role, "absent"));
      return 1;
    }
  }

  const failed = resolveRoles(profile, resolverPath(options));
  if (failed) {
    emit(unresolvedFields(failed.role, failed.result));
    return 1;
  }

  const teamFields = ROLE_NAMES.filter((role) => profile.roles[role]).map((role) => [
    role,
    formatRoleSpec(profile.roles[role]),
  ]);
  emit([
    ...base,
    ["present", "true"],
    ["result", "ok"],
    ["pr_fix_shared_with_impl", String(profile.pr_fix_shared_with_impl)],
    ...teamFields,
  ]);
  return 0;
}

/**
 * Write one user asset file atomically: a 0600 temporary file in the target
 * directory is renamed over the target, so a reader never sees a partial file.
 */
function writeAssetFile(file, content) {
  const directory = path.dirname(file);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const temporary = path.join(directory, `.${path.basename(file)}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`);
  try {
    writeFileSync(temporary, content, { flag: "wx" });
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

function commandUse(options) {
  const name = options.positional[0] ?? "";
  const active = activePath();
  const base = [
    ["command", "use"],
    ["profile", isProfileName(name) ? name : ""],
    ["active", active],
  ];
  const fail = (result, reason, extra = []) => {
    emit([...base, ["result", result], ["written", "false"], ["reason", reason], ...extra]);
    return exitForReason(reason);
  };

  if (!isProfileName(name)) {
    return fail("invalid", "bad-profile-name");
  }
  const file = profilePath(name);
  const loaded = loadProfile(file);
  if (loaded.result === "missing") {
    return fail("missing", "missing-explicit-profile");
  }
  if (loaded.result !== "ok") {
    return fail("invalid", loaded.reason, loaded.raw === undefined ? [] : roleFields(loaded.raw));
  }
  const profile = loaded.profile;
  const failed = resolveRoles(profile, resolverPath(options));
  if (failed) {
    return fail("unresolved", "role", [
      ["unresolved", failed.role],
      ["unresolved_result", failed.result],
      ["pr_fix_shared_with_impl", String(profile.pr_fix_shared_with_impl)],
      ...roleFields(profile),
    ]);
  }

  try {
    writeAssetFile(active, `${name}\n`);
  } catch (error) {
    writeSync(2, `team-record: cannot write '${active}': ${error instanceof Error ? error.message : String(error)}\n`);
    return fail("invalid", "write-failed");
  }

  emit([
    ...base,
    ["result", "ok"],
    ["written", "true"],
    ["pr_fix_shared_with_impl", String(profile.pr_fix_shared_with_impl)],
    ...ROLE_NAMES.filter((role) => profile.roles[role]).map((role) => [role, formatRoleSpec(profile.roles[role])]),
  ]);
  return 0;
}

function commandWrite(options) {
  const name = options.profile;
  const file = isProfileName(name) ? profilePath(name) : "";
  const base = [
    ["command", "write"],
    ["profile", isProfileName(name) ? name : ""],
    ["record", file],
  ];
  const fail = (result, reason, extra = []) => {
    emit([...base, ["result", result], ["written", "false"], ["reason", reason], ...extra]);
    return exitForReason(reason);
  };

  if (name === "") {
    return fail("invalid", "usage");
  }
  if (!isProfileName(name)) {
    return fail("invalid", "bad-profile-name");
  }
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

  const profile = buildProfile(roles, options.prFixSharedWithImpl);
  const failed = resolveRoles(profile, resolverPath(options));
  if (failed) {
    return fail("unresolved", "role", [
      ["unresolved", failed.role],
      ["unresolved_result", failed.result],
    ]);
  }

  try {
    writeAssetFile(file, `${JSON.stringify(profile, null, 2)}\n`);
  } catch (error) {
    writeSync(2, `team-record: cannot write '${file}': ${error instanceof Error ? error.message : String(error)}\n`);
    return fail("invalid", "write-failed");
  }

  emit([
    ...base,
    ["result", "ok"],
    ["written", "true"],
    ["pr_fix_shared_with_impl", String(options.prFixSharedWithImpl)],
    ["roles", ROLE_NAMES.filter((role) => roles[role]).join(",")],
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
  switch (parsed.options.command) {
    case "resolve":
      return commandResolve(parsed.options);
    case "use":
      return commandUse(parsed.options);
    default:
      return commandWrite(parsed.options);
  }
}

process.exit(main());
