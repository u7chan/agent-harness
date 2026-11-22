/**
 * Pure specification vocabularies and thinking-level classification.
 *
 * This module must not import pi: `scripts/pi-development/tests/run.sh` loads it
 * on machines without an installed pi. It never computes supported levels or
 * clamp results itself; the caller passes the values that Pi's public API
 * (`getSupportedThinkingLevels`, `clampThinkingLevel`) produced, and this
 * module only classifies them. It also holds the harness vocabularies that the
 * role-spec grammar and the resolver share: the harness names, the Claude
 * effort and permission modes, the Claude permission-mode default, and the
 * Claude model shape. The harness-prefix
 * pattern and the default harness stay next to each parser that applies them,
 * because the grammar's split rules and the resolver's argument rules are
 * separate, so those two constants have one definition per site.
 */

/** Thinking levels accepted by Pi (`ModelThinkingLevel`). */
export const THINKING_LEVELS = Object.freeze([
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
]);

const LEVELS = new Set(THINKING_LEVELS);

/**
 * Harnesses a role spec can name. The prefix itself is part of the grammar:
 * only a leading `pi:` or `claude:` is a harness prefix.
 */
export const HARNESSES = Object.freeze(["pi", "claude"]);

/**
 * Effort levels accepted by Claude's `--effort`. `off` and `minimal` are not
 * part of the vocabulary: the CLI ignores them with a warning and falls back
 * to the model default, so accepting them would claim an effort nobody set.
 */
export const CLAUDE_EFFORT_LEVELS = Object.freeze(["low", "medium", "high", "xhigh", "max"]);

/**
 * Claude permission modes accepted in a role spec. `bypassPermissions` is
 * deliberately absent: a role spec never skips the permission system.
 */
export const CLAUDE_PERMISSION_MODES = Object.freeze(["acceptEdits", "auto", "manual", "dontAsk", "plan"]);

/**
 * Permission mode a Claude request gets when it omits one. The resolver is the
 * only place that applies it: a stored profile and the launcher still require
 * all three fields. The value is checked against the vocabulary here, so a
 * default that is not a selectable mode stops every import of this module
 * instead of turning an omitted mode into an unsupported value at the resolver.
 */
export const CLAUDE_DEFAULT_PERMISSION_MODE = "auto";

if (!CLAUDE_PERMISSION_MODES.includes(CLAUDE_DEFAULT_PERMISSION_MODE)) {
  throw new Error(
    `CLAUDE_DEFAULT_PERMISSION_MODE '${CLAUDE_DEFAULT_PERMISSION_MODE}' is not in CLAUDE_PERMISSION_MODES`,
  );
}

/**
 * True when a value can be a Claude model or alias: one command-line token that
 * does not start with `-`, so a model ID may still contain `/`, `:` and `.`.
 * The alias table itself is not owned here; an alias is confirmed after launch.
 */
export function isClaudeModelId(value) {
  return typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9._:@+/-]*$/.test(value);
}

/**
 * True when a value is a canonical Claude model ID rather than an alias.
 *
 * The launched session reports an ID such as `claude-haiku-5-5`, and a profile
 * stores one of those: a profile start compares the stored value with the
 * launched `effective:` model, so an alias (`haiku`) or a provider-prefixed
 * form would stop the start even though the CLI grammar accepts it for a
 * one-off explicit launch. This is deliberately narrower than
 * `isClaudeModelId`, and only the editor's save path applies it; the CLI keeps
 * accepting an alias as an explicit specification.
 */
export function isCanonicalClaudeModelId(value) {
  return typeof value === "string" && /^claude-[a-z0-9][a-z0-9.-]*$/.test(value);
}

/**
 * Classify one requested thinking level.
 *
 * - `ok`: the requested level is in the model's supported levels.
 * - `clamped`: the requested level is unsupported but Pi clamps it to a
 *   different level.
 * - `unsupported`: the model reports no supported level at all.
 * - `unknown`: invalid input, or a contradictory supported/effective pair.
 *   Anything other than `ok` is unresolved and must stop the workflow.
 *
 * @param {unknown} requested requested level
 * @param {unknown} supported levels reported by getSupportedThinkingLevels()
 * @param {unknown} effective level reported by clampThinkingLevel()
 * @returns {"ok" | "clamped" | "unsupported" | "unknown"}
 */
export function classify(requested, supported, effective) {
  if (typeof requested !== "string" || !LEVELS.has(requested)) {
    return "unknown";
  }
  if (!Array.isArray(supported) || supported.some((level) => !LEVELS.has(level))) {
    return "unknown";
  }
  if (supported.length === 0) {
    return "unsupported";
  }
  if (supported.includes(requested)) {
    return "ok";
  }
  if (typeof effective === "string" && effective !== requested && LEVELS.has(effective)) {
    return "clamped";
  }
  return "unknown";
}
