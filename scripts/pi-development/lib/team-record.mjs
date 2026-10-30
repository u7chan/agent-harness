/**
 * Pure helpers for shared development team profiles.
 *
 * A team profile is a user asset that lives outside the repository. It holds
 * the provider/model/thinking specification of one named team composition, so a
 * later kickoff can reuse it instead of asking for the same approval again. The
 * `active` file names the profile a run uses when it states none.
 *
 * This module must not import pi and must not perform I/O. The wrapper
 * (`team-record.sh`) starts the CLI, the CLI (`team-record.mjs`) reads and
 * writes the user asset and calls the model-spec resolver, and
 * `scripts/pi-development/tests/team-record.sh` imports this module
 * directly, on machines without an installed pi.
 */

import { THINKING_LEVELS } from "./model-spec.mjs";

/** Profile a run uses when it names none and `active` is absent. */
export const DEFAULT_PROFILE_NAME = "default";

/** File that names the profile a run uses by default. */
export const ACTIVE_FILE_NAME = "active";

/** Development role names, in full-team table order. */
export const ROLE_NAMES = Object.freeze(["impl", "review", "pr-fix", "ui-tester"]);

/** Roles a profile must provide; `ui-tester` is the optional extra role. */
export const REQUIRED_ROLE_NAMES = Object.freeze(["impl", "review", "pr-fix"]);

/**
 * A provider ID and a profile name may contain only these characters, so a
 * spec string stays unambiguous and a profile name stays a filename segment.
 */
const NAME_PATTERN = /^[A-Za-z0-9._-]+$/;

/** True when a value can be embedded in the one-line output. */
export function isSafeField(value) {
  return typeof value === "string" && !/[\s\u0000-\u001f\u007f]/.test(value);
}

/** True when a value is a complete provider, model, or thinking value. */
export function isSpecValue(value) {
  return isSafeField(value) && value !== "";
}

/** Keep the one-line output parseable even when a value is unexpected. */
export function field(value) {
  return isSafeField(value) ? value : "";
}

/**
 * True when a value can name a profile: one filename segment of `profiles/`,
 * given without the extension, and never a directory reference.
 */
export function isProfileName(value) {
  if (typeof value !== "string" || !NAME_PATTERN.test(value)) {
    return false;
  }
  return value !== "." && value !== "..";
}

/**
 * Parse the `active` file content. Exactly one line is accepted, with at most
 * one trailing newline; an empty file, several lines, and a name that is not a
 * profile name are all `bad-active`.
 *
 * @param {unknown} text raw file content
 * @returns {{result: "ok", name: string} | {result: "invalid", reason: "bad-active"}}
 */
export function parseActiveContent(text) {
  if (typeof text !== "string") {
    return { result: "invalid", reason: "bad-active" };
  }
  let value = text;
  if (value.endsWith("\n")) {
    value = value.slice(0, -1);
  }
  if (value.includes("\n") || !isProfileName(value)) {
    return { result: "invalid", reason: "bad-active" };
  }
  return { result: "ok", name: value };
}

/** Profile file name inside `profiles/`, given an extensionless profile name. */
export function profileFileName(name) {
  return `${name}.json`;
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Read one role value as a specification.
 *
 * @param {unknown} value stored `{provider, model, thinking}`
 * @returns {{provider: string, model: string, thinking: string} | null} null when the value is not a usable specification
 */
export function readRoleSpec(value) {
  if (!isPlainObject(value)) {
    return null;
  }
  const { provider, model, thinking } = value;
  if (!isSpecValue(provider) || !NAME_PATTERN.test(provider)) {
    return null;
  }
  if (!isSpecValue(model)) {
    return null;
  }
  if (!isSpecValue(thinking) || !THINKING_LEVELS.includes(thinking)) {
    return null;
  }
  return { provider, model, thinking };
}

/**
 * Render a stored role value for diagnostics, without requiring it to resolve.
 * The result is only for display; `readRoleSpec` is the strict reader.
 *
 * @param {unknown} value stored `{provider, model, thinking}`
 * @returns {string} `<provider>/<model>/<thinking>`, or "" when it is not renderable
 */
export function renderStoredRole(value) {
  if (!isPlainObject(value)) {
    return "";
  }
  const { provider, model, thinking } = value;
  if (!isSpecValue(provider) || !isSpecValue(model) || !isSpecValue(thinking)) {
    return "";
  }
  return `${provider}/${model}/${thinking}`;
}

/** Render one validated specification as `<provider>/<model>/<thinking>`. */
export function formatRoleSpec(spec) {
  return `${spec.provider}/${spec.model}/${spec.thinking}`;
}

/**
 * Parse one `<provider>/<model>/<thinking>` specification from a command line.
 * The provider is the first segment, the thinking level is the last one, and
 * the model is everything between them, so a model ID may contain `/`.
 *
 * @param {unknown} text
 * @returns {{provider: string, model: string, thinking: string} | null}
 */
export function parseRoleSpec(text) {
  if (!isSpecValue(text)) {
    return null;
  }
  const first = text.indexOf("/");
  const last = text.lastIndexOf("/");
  if (first <= 0 || last <= first) {
    return null;
  }
  const provider = text.slice(0, first);
  const model = text.slice(first + 1, last);
  const thinking = text.slice(last + 1);
  if (!NAME_PATTERN.test(provider) || model === "" || !THINKING_LEVELS.includes(thinking)) {
    return null;
  }
  return { provider, model, thinking };
}

/**
 * Build the profile content for a settled team.
 *
 * @param {{[role: string]: {provider: string, model: string, thinking: string}}} roles
 * @param {boolean} prFixSharedWithImpl
 */
export function buildProfile(roles, prFixSharedWithImpl) {
  const stored = {};
  for (const role of ROLE_NAMES) {
    const spec = roles[role];
    if (spec) {
      stored[role] = { provider: spec.provider, model: spec.model, thinking: spec.thinking };
    }
  }
  return {
    pr_fix_shared_with_impl: Boolean(prFixSharedWithImpl),
    roles: stored,
  };
}

/**
 * Validate parsed profile content.
 *
 * Unknown top-level and role keys are ignored, so a later role name does not
 * break this reader and a profile that still carries a removed key stays
 * usable. Everything a profile must provide is required: a missing or
 * malformed role, a missing shared flag, and a shared `pr-fix` that differs
 * from `impl` are all unresolvable, which sends the kickoff back to the
 * proposal and approval path.
 *
 * @param {unknown} raw parsed JSON
 * @param {{onlyRole?: string}} options read-only projection; absent for a full team
 * @returns {{result: "ok", profile: object} | {result: "invalid", reason: string}}
 */
export function validateProfile(raw, { onlyRole = "" } = {}) {
  if (!isPlainObject(raw)) {
    return { result: "invalid", reason: "bad-record" };
  }
  // A review-only consumer must not depend on unused model specifications or
  // the impl/pr-fix composition. Projection is read-only; full-team writes
  // and active-profile switches keep their existing validation contract.
  if (onlyRole) {
    if (!ROLE_NAMES.includes(onlyRole)) {
      return { result: "invalid", reason: "bad-roles" };
    }
    if (!isPlainObject(raw.roles)) {
      return { result: "invalid", reason: "bad-roles" };
    }
    if (!Object.prototype.hasOwnProperty.call(raw.roles, onlyRole)) {
      return { result: "invalid", reason: "missing-role" };
    }
    const spec = readRoleSpec(raw.roles[onlyRole]);
    return spec
      ? { result: "ok", profile: { roles: { [onlyRole]: spec } } }
      : { result: "invalid", reason: "bad-role-spec" };
  }
  if (typeof raw.pr_fix_shared_with_impl !== "boolean") {
    return { result: "invalid", reason: "bad-shared" };
  }
  if (!isPlainObject(raw.roles)) {
    return { result: "invalid", reason: "bad-roles" };
  }
  const roles = {};
  for (const role of REQUIRED_ROLE_NAMES) {
    if (!Object.prototype.hasOwnProperty.call(raw.roles, role)) {
      return { result: "invalid", reason: "missing-role" };
    }
  }
  for (const role of ROLE_NAMES) {
    if (!Object.prototype.hasOwnProperty.call(raw.roles, role)) {
      continue;
    }
    const spec = readRoleSpec(raw.roles[role]);
    if (!spec) {
      return { result: "invalid", reason: "bad-role-spec" };
    }
    roles[role] = spec;
  }
  if (raw.pr_fix_shared_with_impl && formatRoleSpec(roles["pr-fix"]) !== formatRoleSpec(roles["impl"])) {
    return { result: "invalid", reason: "bad-shared" };
  }
  return { result: "ok", profile: buildProfile(roles, raw.pr_fix_shared_with_impl) };
}
