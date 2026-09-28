/**
 * Pure thinking-level classification for the model-spec resolver.
 *
 * This module must not import pi: `pi-issue-pr-workflow/tests/run.sh` loads it
 * on machines without an installed pi. It never computes supported levels or
 * clamp results itself; the caller passes the values that Pi's public API
 * (`getSupportedThinkingLevels`, `clampThinkingLevel`) produced, and this
 * module only classifies them.
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
