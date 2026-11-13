#!/usr/bin/env node
/**
 * Generate the model master that the local profile editor offers as candidates.
 *
 * The master is a cache, not an authority: a save is validated against the
 * live catalog by `team-record.sh write`. This script only turns the installed
 * pi catalog into the small JSON document the UI can read without pi.
 *
 * It keeps no catalog and no supported-level table of its own; it loads the
 * public pi API exactly as `resolve-model-spec.mjs` does and asks it for the
 * authenticated models.
 *
 * Output contract (exactly one stdout line, exit status 0 only for
 * `result=ok`):
 *
 *   result=ok path=<file> providers=<n> models=<n> pi_version=<v>
 *   result=failed [path=<file>] reason=<token>
 *
 * A failure or an empty catalog never overwrites the existing file: the last
 * good master stays readable, and the UI degrades to free-text input instead of
 * losing its candidates.
 */

import { readFileSync, mkdirSync, renameSync, rmSync, writeSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

import { THINKING_LEVELS } from "./lib/model-spec.mjs";

const DEFAULT_PI_AI_SUBPATH = ["node_modules", "@earendil-works", "pi-ai"];
const MASTER_FILE_NAME = "models.json";

const USAGE = `Usage: refresh-models.mjs [--pi-root <pi-package>] [--pi-ai-root <pi-ai-package>] [--out <file>]

Writes the model master for the local profile editor:
  generated_at, pi_version, providers[].id, providers[].models[]
Exit status is 0 only for result=ok. A failure or an empty catalog leaves the
existing file untouched.`;

/** True when a value can be embedded in the one-line record. */
function isSafeField(value) {
  return typeof value === "string" && !/[\s\u0000-\u001f\u007f]/.test(value);
}

/** Keep the one-line record parseable even when a value is unexpected. */
function field(value) {
  return isSafeField(value) ? value : "";
}

function fail(reason, out, extra = []) {
  const pairs = [...extra.filter(([, value]) => value !== ""), ["result", "failed"], ["reason", reason]];
  writeSync(1, `${pairs.map(([key, value]) => `${key}=${field(String(value))}`).join(" ")}\n`);
  return 1;
}

function parseArgs(argv) {
  const options = { piRoot: "", piAiRoot: "", out: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") {
      return { help: true };
    }
    if (arg === "--pi-root" || arg === "--pi-ai-root" || arg === "--out") {
      const value = argv[i + 1];
      if (typeof value !== "string" || value === "") {
        return { error: `${arg} requires a value` };
      }
      options[{ "--pi-root": "piRoot", "--pi-ai-root": "piAiRoot", "--out": "out" }[arg]] = value;
      i += 1;
      continue;
    }
    return { error: `unexpected argument '${arg}'` };
  }
  return { options };
}

/** Root of pi's configuration directory, matching team-record.mjs. */
function piAgentDir() {
  const configured = (process.env.PI_CODING_AGENT_DIR ?? "").trim();
  const base = configured !== "" ? configured : path.join(os.homedir(), ".pi", "agent");
  return path.resolve(base);
}

/** Default destination: the shared user asset, next to `profiles/`. */
function defaultOut() {
  return path.join(piAgentDir(), "pi-development", MASTER_FILE_NAME);
}

/**
 * Resolve a package entry through the package.json `exports` map. `--pi-root`
 * is a package root by contract, so reading the manifest avoids depending on
 * the node_modules ancestry of the install layout.
 */
async function packageEntry(packageRoot, exportKey, fallbackRelative) {
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(path.join(packageRoot, "package.json"), "utf8"));
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

function packageVersion(packageRoot) {
  try {
    const manifest = JSON.parse(readFileSync(path.join(packageRoot, "package.json"), "utf8"));
    return typeof manifest.version === "string" ? manifest.version : "";
  } catch {
    return "";
  }
}

/** Canonical thinking order, dropping levels the model does not support. */
function normalizeLevels(rawSupported) {
  if (!Array.isArray(rawSupported)) {
    return [];
  }
  const supported = new Set(rawSupported.filter((level) => typeof level === "string"));
  return THINKING_LEVELS.filter((level) => supported.has(level));
}

/** One provider entry, with the models the UI needs and nothing else. */
function modelEntry(model, getSupportedThinkingLevels) {
  const entry = {
    id: model.id,
    supported_thinking: normalizeLevels(getSupportedThinkingLevels(model)),
  };
  if (Number.isFinite(model.contextWindow)) {
    entry.context_window = model.contextWindow;
  }
  if (Number.isFinite(model.maxTokens)) {
    entry.max_tokens = model.maxTokens;
  }
  if (Array.isArray(model.input)) {
    entry.images = model.input.includes("image");
  }
  if (model.thinkingLevelMap && typeof model.thinkingLevelMap === "object") {
    entry.thinking_level_map = model.thinkingLevelMap;
  }
  return entry;
}

/** Build the document, sorted so an unchanged catalog produces an equal file. */
function buildMaster({ models, getSupportedThinkingLevels, piVersion }) {
  const byProvider = new Map();
  for (const model of models) {
    if (!isSafeField(model?.id) || !isSafeField(model?.provider)) {
      continue;
    }
    if (!byProvider.has(model.provider)) {
      byProvider.set(model.provider, []);
    }
    byProvider.get(model.provider).push(modelEntry(model, getSupportedThinkingLevels));
  }
  const providers = [...byProvider.keys()]
    .sort()
    .map((id) => ({
      id,
      models: byProvider
        .get(id)
        .sort((left, right) => left.id.localeCompare(right.id)),
    }));
  return {
    generated_at: new Date().toISOString(),
    pi_version: piVersion,
    providers,
  };
}

/** Write atomically with mode 0600, so a reader never sees a partial file. */
async function writeMaster(file, document) {
  const directory = path.dirname(file);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const temporary = path.join(directory, `.${path.basename(file)}.${process.pid}.tmp`);
  try {
    await writeFile(temporary, `${JSON.stringify(document, null, 2)}\n`, { mode: 0o600 });
    renameSync(temporary, file);
  } catch (error) {
    rmSync(temporary, { force: true });
    throw error;
  }
}

async function main() {
  const parsed = parseArgs(process.argv.slice(2));
  if (parsed.help) {
    writeSync(1, `${USAGE}\n`);
    return 0;
  }
  const out = parsed.options?.out || defaultOut();
  if (parsed.error) {
    writeSync(2, `refresh-models: ${parsed.error}\n${USAGE}\n`);
    return fail("argument-error", out);
  }
  const options = parsed.options;
  if (!options.piRoot) {
    return fail("unresolved-pi-root", out);
  }
  const piVersion = packageVersion(options.piRoot);
  if (!piVersion) {
    return fail("unreadable-pi-root", out, [["pi_root", options.piRoot]]);
  }

  let runtime;
  let getSupportedThinkingLevels;
  try {
    const { ModelRuntime } = await import(await packageEntry(options.piRoot, ".", "dist/index.js"));
    const piAiRoot = options.piAiRoot || path.join(options.piRoot, ...DEFAULT_PI_AI_SUBPATH);
    const compat = await import(await packageEntry(piAiRoot, "./compat", "dist/compat.js"));
    getSupportedThinkingLevels = compat.getSupportedThinkingLevels;
    if (typeof ModelRuntime?.create !== "function") {
      throw new Error(`'${options.piRoot}' does not export ModelRuntime`);
    }
    if (typeof getSupportedThinkingLevels !== "function") {
      throw new Error(`'${piAiRoot}' does not export getSupportedThinkingLevels through ./compat`);
    }
    runtime = await ModelRuntime.create({ refreshOnCreate: false, allowModelNetwork: false });
  } catch (error) {
    writeSync(2, `refresh-models: ${error instanceof Error ? error.message : String(error)}\n`);
    return fail("catalog-unavailable", out);
  }

  let models;
  try {
    models = await runtime.getAvailable();
  } catch (error) {
    writeSync(2, `refresh-models: ${error instanceof Error ? error.message : String(error)}\n`);
    return fail("catalog-unavailable", out);
  }
  if (!Array.isArray(models) || models.length === 0) {
    return fail("no-models", out);
  }

  const document = buildMaster({ models, getSupportedThinkingLevels, piVersion });
  const modelCount = document.providers.reduce((total, provider) => total + provider.models.length, 0);
  if (modelCount === 0) {
    return fail("no-models", out);
  }

  try {
    await writeMaster(out, document);
  } catch (error) {
    writeSync(2, `refresh-models: cannot write '${out}': ${error instanceof Error ? error.message : String(error)}\n`);
    return fail("write-failed", out);
  }

  writeSync(
    1,
    `result=ok path=${field(out)} providers=${document.providers.length} models=${modelCount} pi_version=${field(piVersion)}\n`,
  );
  return 0;
}

process.exitCode = await main();
