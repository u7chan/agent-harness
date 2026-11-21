/**
 * Pure helpers for shared development team profiles.
 *
 * A team profile is a user asset that lives outside the repository. It holds
 * the harness/provider/model/thinking specification of one named team
 * composition, so a later kickoff can reuse it instead of asking for the same
 * approval again. The `active` file names the profile a run uses when it
 * states none.
 *
 * This module must not import pi and must not perform I/O. The wrapper
 * (`team-record.sh`) starts the CLI, the CLI (`team-record.mjs`) reads and
 * writes the user asset and calls the model-spec resolver, and
 * `scripts/pi-development/tests/team-record.sh` imports this module
 * directly, on machines without an installed pi.
 */

import {
  CLAUDE_EFFORT_LEVELS,
  CLAUDE_PERMISSION_MODES,
  THINKING_LEVELS,
  isClaudeModelId,
} from "./model-spec.mjs";

/** Profile a run uses when it names none and `active` is absent. */
export const DEFAULT_PROFILE_NAME = "default";

/** File that names the profile a run uses by default. */
export const ACTIVE_FILE_NAME = "active";

/**
 * Profile role names. `orchestrator` is stored and validated like any other
 * role but is not a team member, so it comes last rather than in team order.
 */
export const ROLE_NAMES = Object.freeze(["impl", "review", "pr-fix", "ui-tester", "orchestrator"]);

/** Roles a profile must provide; `ui-tester` and `orchestrator` are optional. */
export const REQUIRED_ROLE_NAMES = Object.freeze(["impl", "review", "pr-fix"]);

/**
 * Roles a full-team read or a persistent switch resolves at runtime.
 *
 * `orchestrator` is deliberately absent: it is not part of the team, so a
 * retired or unauthenticated orchestrator model must not block the team's own
 * `resolve`/`use`. The start script resolves it through `--only-role`, and
 * `--require-role orchestrator` adds it to a full-team read explicitly.
 */
export const TEAM_ROLE_NAMES = Object.freeze(["impl", "review", "pr-fix", "ui-tester"]);

/** A provider ID and a profile name may contain only these characters, so a
 * spec string stays unambiguous and a profile name stays a filename segment.
 */
const NAME_PATTERN = /^[A-Za-z0-9._-]+$/;

/**
 * A harness prefix. Only a leading `pi:` or `claude:` is one, so a model ID that
 * contains `:` never turns into a harness, and anything else is read as a
 * legacy Pi specification.
 */
const HARNESS_PREFIX = /^(pi|claude):/;

/** The harness a stored role has when the key is absent. */
const DEFAULT_HARNESS = "pi";

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

function storedHarness(value) {
  return Object.prototype.hasOwnProperty.call(value, "harness") ? value.harness : DEFAULT_HARNESS;
}

function hasKey(value, key) {
  return Object.prototype.hasOwnProperty.call(value, key);
}

/**
 * Read one role value as a specification.
 *
 * `harness` is optional and defaults to `pi`, so a profile written before the
 * harness existed is valid without an edit. The harness decides which fields
 * are required and which are refused: a Pi role takes provider/model/thinking
 * and never an effort or a permission mode, and a Claude role takes
 * model/effort/permission_mode and never a provider or a thinking level. Other
 * unknown keys stay ignored, so a hand-written note never invalidates a role.
 *
 * @param {unknown} value stored role value
 * @returns {{harness: string, provider?: string, model: string, thinking?: string,
 *   effort?: string, permission_mode?: string} | null} null when the value is not a usable specification
 */
export function readRoleSpec(value) {
  if (!isPlainObject(value)) {
    return null;
  }
  const harness = storedHarness(value);
  if (harness === "pi") {
    if (hasKey(value, "effort") || hasKey(value, "permission_mode")) {
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
    return { harness: "pi", provider, model, thinking };
  }
  if (harness === "claude") {
    if (hasKey(value, "provider") || hasKey(value, "thinking")) {
      return null;
    }
    const { model, effort, permission_mode: permissionMode } = value;
    if (!isClaudeModelId(model)) {
      return null;
    }
    if (!CLAUDE_EFFORT_LEVELS.includes(effort)) {
      return null;
    }
    if (!CLAUDE_PERMISSION_MODES.includes(permissionMode)) {
      return null;
    }
    return { harness: "claude", model, effort, permission_mode: permissionMode };
  }
  return null;
}

/**
 * Render a stored role value for diagnostics, without requiring it to resolve.
 * The result is only for display; `readRoleSpec` is the strict reader. A value
 * without `harness` is rendered as the Pi specification it is read as.
 *
 * @param {unknown} value stored role value
 * @returns {string} the canonical specification, or "" when it is not renderable
 */
export function renderStoredRole(value) {
  if (!isPlainObject(value)) {
    return "";
  }
  const harness = storedHarness(value);
  const { provider, model, thinking, effort, permission_mode: permissionMode } = value;
  if (harness === "claude") {
    if (!isSpecValue(model) || !isSpecValue(effort) || !isSpecValue(permissionMode)) {
      return "";
    }
    return formatRoleSpec({ harness: "claude", model, effort, permission_mode: permissionMode });
  }
  if (harness !== "pi") {
    return "";
  }
  if (!isSpecValue(provider) || !isSpecValue(model) || !isSpecValue(thinking)) {
    return "";
  }
  return formatRoleSpec({ harness: "pi", provider, model, thinking });
}

/** Render one validated specification in its canonical, prefixed form. */
export function formatRoleSpec(spec) {
  if (spec.harness === "claude") {
    return `claude:${spec.model}/${spec.effort}/${spec.permission_mode}`;
  }
  return `pi:${spec.provider}/${spec.model}/${spec.thinking}`;
}

/**
 * Parse the body of a Pi specification: the provider is the first segment, the
 * thinking level is the last one, and the model is everything between them, so
 * a model ID may contain `/`.
 *
 * @param {string} body text after the harness prefix, if any
 */
function parsePiSpecBody(body) {
  const first = body.indexOf("/");
  const last = body.lastIndexOf("/");
  if (first <= 0 || last <= first) {
    return null;
  }
  const provider = body.slice(0, first);
  const model = body.slice(first + 1, last);
  const thinking = body.slice(last + 1);
  if (!NAME_PATTERN.test(provider) || model === "" || !THINKING_LEVELS.includes(thinking)) {
    return null;
  }
  return { harness: "pi", provider, model, thinking };
}

/**
 * Parse the body of a Claude specification: the permission mode is the last
 * segment, the effort level the one before it, and the model everything before
 * that, so a model ID may contain `/`.
 *
 * @param {string} body text after the harness prefix
 */
function parseClaudeSpecBody(body) {
  const last = body.lastIndexOf("/");
  if (last <= 0) {
    return null;
  }
  const beforePermission = body.slice(0, last);
  const permissionMode = body.slice(last + 1);
  const secondLast = beforePermission.lastIndexOf("/");
  if (secondLast <= 0) {
    return null;
  }
  const model = beforePermission.slice(0, secondLast);
  const effort = beforePermission.slice(secondLast + 1);
  if (!isClaudeModelId(model) || effort === "") {
    return null;
  }
  if (!CLAUDE_EFFORT_LEVELS.includes(effort) || !CLAUDE_PERMISSION_MODES.includes(permissionMode)) {
    return null;
  }
  return { harness: "claude", model, effort, permission_mode: permissionMode };
}

/**
 * Parse one canonical specification from a command line:
 * `pi:<provider>/<model>/<thinking>` or
 * `claude:<model>/<effort>/<permission_mode>`. Only a leading `pi:` or
 * `claude:` is a harness prefix; without one the whole string is a legacy Pi
 * specification, which keeps every existing caller working.
 *
 * @param {unknown} text
 * @returns {{harness: string, model: string} | null}
 */
export function parseRoleSpec(text) {
  if (!isSpecValue(text)) {
    return null;
  }
  const prefixed = HARNESS_PREFIX.exec(text);
  const body = prefixed ? text.slice(prefixed[0].length) : text;
  if (prefixed && prefixed[1] === "claude") {
    return parseClaudeSpecBody(body);
  }
  return parsePiSpecBody(body);
}

/**
 * The stored form of one specification. The default harness stays implicit, so
 * an existing Pi profile round-trips byte for byte and the local editor keeps
 * reading those roles; a Claude role carries its harness because there is no
 * default to fall back to.
 */
function storedRoleSpec(spec) {
  if (spec.harness === "claude") {
    return {
      harness: "claude",
      model: spec.model,
      effort: spec.effort,
      permission_mode: spec.permission_mode,
    };
  }
  return { provider: spec.provider, model: spec.model, thinking: spec.thinking };
}

/**
 * Build the profile content for a settled team.
 *
 * @param {{[role: string]: {harness: string, model: string}}} roles
 * @param {boolean} prFixSharedWithImpl
 */
export function buildProfile(roles, prFixSharedWithImpl) {
  const stored = {};
  for (const role of ROLE_NAMES) {
    const spec = roles[role];
    if (spec) {
      stored[role] = storedRoleSpec(spec);
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
 * proposal and approval path. A stored `orchestrator` is optional but is
 * shape-validated with the other roles, so a malformed one is never reported
 * as usable.
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
