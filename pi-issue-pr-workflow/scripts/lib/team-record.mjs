/**
 * Pure helpers for the approved team record.
 *
 * The record is a user asset that lives outside the repository. It holds the
 * provider/model/thinking specification the user approved for one repository,
 * so a later kickoff can reuse it instead of asking for the same approval
 * again.
 *
 * This module must not import pi and must not perform I/O. The wrapper
 * (`team-record.sh`) resolves the repository root and its `origin` URL, and
 * the CLI (`team-record.mjs`) reads and writes the record file and calls the
 * model-spec resolver; `pi-issue-pr-workflow/tests/team-record.sh` imports this
 * module directly, on machines without an installed pi.
 */

import { THINKING_LEVELS } from "./model-spec.mjs";

/** Record format version this skill writes and accepts. */
export const RECORD_VERSION = 1;

/** Role names of this skill, in team-table order. */
export const ROLE_NAMES = Object.freeze(["impl", "review", "pr-fix", "tester"]);

/** Roles a record must provide; `tester` is the optional extra role. */
export const REQUIRED_ROLE_NAMES = Object.freeze(["impl", "review", "pr-fix"]);

/**
 * A provider ID and an `owner`/`repo` name may contain only these characters,
 * so a spec string stays unambiguous and a record key stays a filename segment.
 */
const NAME_PATTERN = /^[A-Za-z0-9._-]+$/;

/** True when a value can be embedded in the one-line record. */
export function isSafeField(value) {
  return typeof value === "string" && !/[\s\u0000-\u001f\u007f]/.test(value);
}

/** True when a value is a complete provider, model, or thinking value. */
export function isSpecValue(value) {
  return isSafeField(value) && value !== "";
}

/** Keep the one-line record parseable even when a value is unexpected. */
export function field(value) {
  return isSafeField(value) ? value : "";
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
 * Build the record content for a settled team.
 *
 * @param {{[role: string]: {provider: string, model: string, thinking: string}}} roles
 * @param {boolean} prFixSharedWithImpl
 */
export function buildRecord(roles, prFixSharedWithImpl) {
  const stored = {};
  for (const role of ROLE_NAMES) {
    const spec = roles[role];
    if (spec) {
      stored[role] = { provider: spec.provider, model: spec.model, thinking: spec.thinking };
    }
  }
  return {
    version: RECORD_VERSION,
    pr_fix_shared_with_impl: Boolean(prFixSharedWithImpl),
    roles: stored,
  };
}

/**
 * Validate parsed record content.
 *
 * Unknown top-level and role keys are ignored, so a later role name does not
 * break this reader. Everything the record must provide is required: an
 * unknown `version`, a missing or malformed role, a missing shared flag, and a
 * shared `pr-fix` that differs from `impl` are all unresolvable, which sends
 * the kickoff back to the proposal and approval path.
 *
 * @param {unknown} raw parsed JSON
 * @returns {{result: "ok", record: object} | {result: "invalid", reason: string}}
 */
export function validateRecord(raw) {
  if (!isPlainObject(raw)) {
    return { result: "invalid", reason: "bad-record" };
  }
  if (raw.version !== RECORD_VERSION) {
    return { result: "invalid", reason: "bad-version" };
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
  return { result: "ok", record: buildRecord(roles, raw.pr_fix_shared_with_impl) };
}

/**
 * Derive the record key (`<owner>__<repo>`) from an `origin` remote URL.
 * Only URLs that name exactly `owner/repo` qualify; a local path or a remote
 * that carries more path segments is not resolvable and returns null, so the
 * caller falls back to the repository-root key.
 *
 * @param {unknown} url
 * @returns {string | null}
 */
export function parseOriginKey(url) {
  if (!isSafeField(url) || url === "") {
    return null;
  }
  let pathPart = null;
  const schemeMatch = /^[A-Za-z][A-Za-z0-9+.-]*:\/\//.exec(url);
  if (schemeMatch) {
    const rest = url.slice(schemeMatch[0].length);
    const slash = rest.indexOf("/");
    if (slash < 0) {
      return null;
    }
    pathPart = rest.slice(slash + 1);
  } else if (/^[^/@]+@[^/]+:/.test(url)) {
    // scp-like remote: git@host:owner/repo.git
    pathPart = url.slice(url.indexOf(":") + 1);
  } else {
    return null;
  }
  const segments = pathPart
    .replace(/^\/+/, "")
    .replace(/\/+$/, "")
    .replace(/\.git$/, "")
    .split("/");
  if (segments.length !== 2) {
    return null;
  }
  for (const segment of segments) {
    if (!NAME_PATTERN.test(segment) || segment === "." || segment === "..") {
      return null;
    }
  }
  return `${segments[0]}__${segments[1]}`;
}

/**
 * Derive the record key from a repository root path. Every character outside
 * the safe set becomes `-`, so the key stays a single filename component.
 *
 * @param {unknown} repoRoot
 * @returns {string}
 */
export function recordKeyFromPath(repoRoot) {
  const raw = typeof repoRoot === "string" ? repoRoot : "";
  const sanitized = raw
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^-+/, "")
    .replace(/-+$/, "");
  return sanitized === "" || sanitized === "." || sanitized === ".." ? "repository-root" : sanitized;
}

/** Record file name for one key. */
export function recordFileName(key) {
  return `${key}.json`;
}
