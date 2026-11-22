#!/usr/bin/env node
/**
 * Resolve one canonical role specification and print the result as one
 * key=value line.
 *
 * `resolve-model-spec.sh` resolves the pi package roots (following the `pi`
 * command's symlink chain) and passes them as `--pi-root` / `--pi-ai-root`;
 * this file loads only the public API from those roots. It keeps no model
 * catalog and no supported-level table of its own.
 *
 * The harness decides what is verified:
 *
 *   pi      `--provider`, `--model`, and `--thinking` are matched exactly
 *           against the installed catalog. An unsupported level is never
 *           accepted silently.
 *   claude  `--model`, `--effort`, and `--permission-mode` are checked for
 *           shape and enumeration only. A model exists only after launch, so
 *           the resolver reports `verification=postlaunch` and leaves the
 *           effective values empty instead of claiming an exact match. It
 *           holds no alias table; an alias is confirmed after launch.
 *
 * Output contract (exactly one stdout line):
 *
 *   pi:
 *     harness=pi provider=<id> model=<id> requested=<level> supported=<csv> \
 *     effective=<level> result=<ok|clamped|unsupported|unknown> \
 *     verification=exact thinking_level_map=<json>
 *   claude:
 *     harness=claude provider= model=<id> requested=<effort> supported= \
 *     effective= result=<ok|unknown> verification=postlaunch \
 *     permission_mode=<mode>
 *
 * Exit status is 0 only for result=ok; every other result or an argument error
 * exits nonzero. Diagnostics go to stderr and are not collected by callers.
 */

import { writeSync } from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

import {
  CLAUDE_DEFAULT_PERMISSION_MODE,
  CLAUDE_EFFORT_LEVELS,
  CLAUDE_PERMISSION_MODES,
  HARNESSES,
  THINKING_LEVELS,
  classify,
  isClaudeModelId,
} from "./lib/model-spec.mjs";

const DEFAULT_PI_AI_SUBPATH = ["node_modules", "@earendil-works", "pi-ai"];

/** Harness a request means when `--harness` is absent. */
const DEFAULT_HARNESS = "pi";

const USAGE = `Usage: resolve-model-spec.mjs [--harness <pi|claude>] [options]

Resolves one role specification and prints one key=value line.
Exit status is 0 only for result=ok.

pi (default):
  --provider <id> --model <id> --thinking <level>
  [--pi-root <pi-package>] [--pi-ai-root <pi-ai-package>]
  Verifies the exact model in the installed pi catalog (no fuzzy fallback) and
  reports result=ok verification=exact.

claude:
  --model <id-or-alias> --effort <level> [--permission-mode <mode>]
  Verifies the model shape and the effort/permission vocabularies only and
  reports result=ok verification=postlaunch. The effective model and effort
  are confirmed after launch, so supported= and effective= stay empty here.
  --effort is one of ${CLAUDE_EFFORT_LEVELS.join(", ")}.
  --permission-mode is one of ${CLAUDE_PERMISSION_MODES.join(", ")}; when it
  is omitted the resolver uses ${CLAUDE_DEFAULT_PERMISSION_MODE}.
  An explicit empty value is a usage error, not an omission.`;

/**
 * True when a value can be embedded in the one-line record. Whitespace and
 * control characters (including newlines) would split the record or its key=value
 * fields, so they are not accepted as field content.
 */
function isSafeField(value) {
  return typeof value === "string" && !/[\s\u0000-\u001f\u007f]/.test(value);
}

/** Keep the one-line record parseable even when a value is unexpected. */
function field(value) {
  return isSafeField(value) ? value : "";
}

/** How a harness's request can be verified. */
function verificationFor(harness) {
  if (harness === "pi") {
    return "exact";
  }
  return harness === "claude" ? "postlaunch" : "";
}

/**
 * Print the single key=value line. `writeSync` keeps the line complete even
 * when the process exits right after writing to a pipe. Every field passes
 * through `field()`, so the record stays on one line even for invalid input.
 * The trailing field names the harness's own vocabulary: a Pi record reports
 * `thinking_level_map`, a Claude record reports `permission_mode`.
 */
function emit({
  harness = DEFAULT_HARNESS,
  provider = "",
  model = "",
  requested = "",
  supported = [],
  effective = "",
  result,
  verification = verificationFor(harness),
  thinkingLevelMap,
  permissionMode = "",
}) {
  const map = thinkingLevelMap === undefined ? "" : JSON.stringify(thinkingLevelMap);
  const levels = Array.isArray(supported) ? supported.join(",") : "";
  const fields = [
    `harness=${field(harness)}`,
    `provider=${field(provider)}`,
    `model=${field(model)}`,
    `requested=${field(requested)}`,
    `supported=${field(levels)}`,
    `effective=${field(effective)}`,
    `result=${field(result)}`,
    `verification=${field(verification)}`,
  ];
  if (harness === "claude") {
    fields.push(`permission_mode=${field(permissionMode)}`);
  } else {
    fields.push(`thinking_level_map=${field(map)}`);
  }
  writeSync(1, `${fields.join(" ")}\n`);
}

/** Report an unresolved result on stdout, a reason on stderr, and exit nonzero. */
function unresolved(record, reason, code = 1) {
  emit({ ...record, result: "unknown" });
  writeSync(2, `resolve-model-spec: ${reason}\n`);
  process.exit(code);
}

function reasonOf(error) {
  return error instanceof Error ? error.message : String(error);
}

function parseArgs(argv) {
  const options = {
    harness: "",
    provider: "",
    model: "",
    thinking: "",
    effort: "",
    permissionMode: "",
    permissionModeGiven: false,
    piRoot: "",
    piAIRoot: "",
  };
  const optionNames = {
    "--harness": "harness",
    "--provider": "provider",
    "--model": "model",
    "--thinking": "thinking",
    "--effort": "effort",
    "--permission-mode": "permissionMode",
    "--pi-root": "piRoot",
    "--pi-ai-root": "piAIRoot",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const argument = argv[i];
    if (argument === "-h" || argument === "--help") {
      return { help: true };
    }
    const key = optionNames[argument];
    if (!key) {
      return { options, error: `unknown argument '${argument}'` };
    }
    i += 1;
    if (i >= argv.length) {
      return { options, error: `${argument} requires a value` };
    }
    options[key] = argv[i];
    if (key === "permissionMode") {
      options.permissionModeGiven = true;
    }
  }
  return { options };
}

/**
 * Validate a Claude specification without claiming the model exists.
 *
 * Only the model shape and the two closed vocabularies are checked; nothing
 * here resolves an alias or reads a catalog. `result=ok` therefore means
 * "launchable request", and the spec is confirmed from the launched session.
 */
function resolveClaudeSpec(options) {
  const record = {
    harness: "claude",
    model: options.model,
    requested: options.effort,
    permissionMode: options.permissionMode,
  };
  if (options.provider !== "" || options.thinking !== "") {
    unresolved(record, "--provider and --thinking are not Claude options", 2);
  }
  if (!options.model || !options.effort) {
    unresolved(record, "--model and --effort are required", 2);
  }
  if (options.permissionModeGiven && options.permissionMode === "") {
    unresolved(record, "--permission-mode requires a non-empty value", 2);
  }
  if (!isClaudeModelId(options.model)) {
    unresolved(record, `'${options.model}' is not a Claude model ID or alias`, 2);
  }
  if (!CLAUDE_EFFORT_LEVELS.includes(options.effort)) {
    unresolved(record, `unknown effort '${options.effort}'`, 2);
  }
  // Fill the default only after the request has a usable model and effort. An
  // unresolved record that never reached this point keeps `permission_mode=`
  // empty instead of claiming a value the run did not reach.
  const permissionMode = options.permissionModeGiven
    ? options.permissionMode
    : CLAUDE_DEFAULT_PERMISSION_MODE;
  record.permissionMode = permissionMode;
  if (!CLAUDE_PERMISSION_MODES.includes(permissionMode)) {
    unresolved(record, `unsupported permission mode '${permissionMode}'`, 2);
  }
  emit({ ...record, supported: [], effective: "", result: "ok" });
  process.exit(0);
}

/**
 * Resolve a package entry through the package.json `exports` map. `--pi-root`
 * is a package root by contract, so reading the manifest avoids depending on
 * the node_modules ancestry of the install layout.
 */
async function packageEntry(packageRoot, exportKey, fallbackRelative) {
  let manifest;
  try {
    manifest = JSON.parse(await readFile(path.join(packageRoot, "package.json"), "utf8"));
  } catch (error) {
    throw new Error(`cannot read package.json under '${packageRoot}': ${error.message}`);
  }
  const exported = manifest.exports?.[exportKey];
  let relative = typeof exported === "string" ? exported : exported?.import ?? exported?.default;
  if (!relative && exportKey === "." && typeof manifest.main === "string") {
    relative = manifest.main;
  }
  if (!relative) {
    relative = fallbackRelative;
  }
  if (!relative) {
    throw new Error(`package '${packageRoot}' has no entry for '${exportKey}'`);
  }
  return pathToFileURL(path.resolve(packageRoot, relative)).href;
}

async function resolvePiSpec(options) {
  const record = {
    harness: "pi",
    provider: options.provider,
    model: options.model,
    requested: options.thinking,
  };
  if (!options.provider || !options.model || !options.thinking) {
    unresolved(record, "--provider, --model, and --thinking are required", 2);
  }
  if (!isSafeField(options.provider) || !isSafeField(options.model)) {
    unresolved(record, "--provider and --model must not contain whitespace or control characters", 2);
  }
  if (!THINKING_LEVELS.includes(options.thinking)) {
    unresolved(record, `unknown thinking level '${options.thinking}'`, 2);
  }
  if (!options.piRoot) {
    unresolved(record, "the pi package root is unresolved; install pi or pass --pi-root");
  }

  let ModelRuntime;
  let getSupportedThinkingLevels;
  let clampThinkingLevel;
  try {
    const { ModelRuntime: runtimeClass } = await import(
      await packageEntry(options.piRoot, ".", "dist/index.js")
    );
    const piAIRoot = options.piAIRoot || path.join(options.piRoot, ...DEFAULT_PI_AI_SUBPATH);
    const compat = await import(await packageEntry(piAIRoot, "./compat", "dist/compat.js"));
    ModelRuntime = runtimeClass;
    getSupportedThinkingLevels = compat.getSupportedThinkingLevels;
    clampThinkingLevel = compat.clampThinkingLevel;
    if (typeof ModelRuntime?.create !== "function") {
      throw new Error(`'${options.piRoot}' does not export ModelRuntime`);
    }
    if (
      typeof getSupportedThinkingLevels !== "function" ||
      typeof clampThinkingLevel !== "function"
    ) {
      throw new Error(
        `'${piAIRoot}' does not export getSupportedThinkingLevels/clampThinkingLevel through ./compat`,
      );
    }
  } catch (error) {
    unresolved(record, `cannot load the pi public API: ${reasonOf(error)}`);
  }

  let model;
  try {
    const runtime = await ModelRuntime.create({ refreshOnCreate: false, allowModelNetwork: false });
    model = runtime.getModel(options.provider, options.model);
  } catch (error) {
    unresolved(record, `cannot read the installed model catalog: ${reasonOf(error)}`);
  }
  if (!model || model.provider !== options.provider || model.id !== options.model) {
    unresolved(
      record,
      `'${options.provider}/${options.model}' is not an exact model in the installed catalog`,
    );
  }

  let rawSupported;
  let supported = [];
  let effective = "";
  let result;
  try {
    rawSupported = getSupportedThinkingLevels(model);
    supported = Array.isArray(rawSupported) ? rawSupported : [];
    if (supported.includes(options.thinking)) {
      effective = options.thinking;
    } else if (supported.length > 0) {
      effective = clampThinkingLevel(model, options.thinking);
    }
    result = classify(options.thinking, rawSupported, effective);
  } catch (error) {
    unresolved(record, `cannot classify '${options.provider}/${options.model}': ${reasonOf(error)}`);
  }

  emit({
    harness: "pi",
    provider: options.provider,
    model: options.model,
    requested: options.thinking,
    supported,
    effective,
    result,
    thinkingLevelMap: model.thinkingLevelMap ?? {},
  });
  process.exit(result === "ok" ? 0 : 1);
}

async function main() {
  const parsed = parseArgs(process.argv.slice(2));
  if (parsed.help) {
    writeSync(1, `${USAGE}\n`);
    process.exit(0);
  }
  if (parsed.error) {
    writeSync(2, `resolve-model-spec: ${parsed.error}\n${USAGE}\n`);
    const failedHarness = parsed.options.harness === "" ? DEFAULT_HARNESS : parsed.options.harness;
    unresolved(
      {
        harness: failedHarness,
        provider: parsed.options.provider,
        model: parsed.options.model,
        requested: failedHarness === "claude" ? parsed.options.effort : parsed.options.thinking,
        permissionMode: parsed.options.permissionMode,
      },
      parsed.error,
      2,
    );
  }
  const options = parsed.options;
  const harness = options.harness === "" ? DEFAULT_HARNESS : options.harness;
  if (!HARNESSES.includes(harness)) {
    unresolved({ harness }, `unknown harness '${harness}'`, 2);
  }
  if (harness === "claude") {
    resolveClaudeSpec(options);
  }
  await resolvePiSpec(options);
}

await main();
