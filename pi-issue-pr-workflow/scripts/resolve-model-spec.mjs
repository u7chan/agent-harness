#!/usr/bin/env node
/**
 * Resolve one provider/model/thinking specification through the installed pi
 * runtime and print the result as one key=value line.
 *
 * `resolve-model-spec.sh` resolves the pi package roots (following the `pi`
 * command's symlink chain) and passes them as `--pi-root` / `--pi-ai-root`;
 * this file loads only the public API from those roots. It keeps no model
 * catalog and no supported-level table of its own.
 *
 * Output contract (exactly one stdout line):
 *
 *   provider=<id> model=<id> requested=<level> supported=<csv> \
 *   effective=<level> result=<ok|clamped|unsupported|unknown> \
 *   thinking_level_map=<json>
 *
 * Exit status is 0 only for result=ok; every other result or an argument error
 * exits nonzero. Diagnostics go to stderr and are not collected by callers.
 */

import { writeSync } from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

import { classify, THINKING_LEVELS } from "./lib/model-spec.mjs";

const DEFAULT_PI_AI_SUBPATH = ["node_modules", "@earendil-works", "pi-ai"];

const USAGE = `Usage: resolve-model-spec.mjs --provider <id> --model <id> --thinking <level> [--pi-root <pi-package>] [--pi-ai-root <pi-ai-package>]

Resolves the exact model in the installed pi catalog (no fuzzy fallback) and
prints one key=value line:
  provider=<id> model=<id> requested=<level> supported=<levels> effective=<level> result=<ok|clamped|unsupported|unknown> thinking_level_map=<json>
Exit status is 0 only for result=ok.`;

/**
 * Print the single key=value line. `writeSync` keeps the line complete even
 * when the process exits right after writing to a pipe.
 */
function emit({ provider = "", model = "", requested = "", supported = [], effective = "", result, thinkingLevelMap }) {
  const map = thinkingLevelMap === undefined ? "" : JSON.stringify(thinkingLevelMap);
  const line = [
    `provider=${provider}`,
    `model=${model}`,
    `requested=${requested}`,
    `supported=${supported.join(",")}`,
    `effective=${effective}`,
    `result=${result}`,
    `thinking_level_map=${map}`,
  ].join(" ");
  writeSync(1, `${line}\n`);
}

/** Report an unresolved result on stdout, a reason on stderr, and exit nonzero. */
function unresolved({ provider = "", model = "", thinking = "" }, reason, code = 1) {
  emit({ provider, model, requested: thinking, result: "unknown" });
  writeSync(2, `resolve-model-spec: ${reason}\n`);
  process.exit(code);
}

function reasonOf(error) {
  return error instanceof Error ? error.message : String(error);
}

function parseArgs(argv) {
  const options = { provider: "", model: "", thinking: "", piRoot: "", piAIRoot: "" };
  const optionNames = {
    "--provider": "provider",
    "--model": "model",
    "--thinking": "thinking",
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
      return { error: `unknown argument '${argument}'` };
    }
    i += 1;
    if (i >= argv.length) {
      return { error: `${argument} requires a value` };
    }
    options[key] = argv[i];
  }
  return { options };
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

async function main() {
  const parsed = parseArgs(process.argv.slice(2));
  if (parsed.help) {
    writeSync(1, `${USAGE}\n`);
    process.exit(0);
  }
  if (parsed.error) {
    writeSync(2, `resolve-model-spec: ${parsed.error}\n${USAGE}\n`);
    emit({ result: "unknown" });
    process.exit(2);
  }
  const options = parsed.options;

  if (!options.provider || !options.model || !options.thinking) {
    unresolved(options, "--provider, --model, and --thinking are required", 2);
  }
  if (!THINKING_LEVELS.includes(options.thinking)) {
    unresolved(options, `unknown thinking level '${options.thinking}'`, 2);
  }
  if (!options.piRoot) {
    unresolved(options, "the pi package root is unresolved; install pi or pass --pi-root");
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
    unresolved(options, `cannot load the pi public API: ${reasonOf(error)}`);
  }

  let model;
  try {
    const runtime = await ModelRuntime.create({ refreshOnCreate: false, allowModelNetwork: false });
    model = runtime.getModel(options.provider, options.model);
  } catch (error) {
    unresolved(options, `cannot read the installed model catalog: ${reasonOf(error)}`);
  }
  if (!model || model.provider !== options.provider || model.id !== options.model) {
    unresolved(
      options,
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
    unresolved(options, `cannot classify '${options.provider}/${options.model}': ${reasonOf(error)}`);
  }

  emit({
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

await main();
