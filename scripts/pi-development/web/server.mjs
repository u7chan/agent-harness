#!/usr/bin/env node
/**
 * Local web editor for the shared development profiles.
 *
 * The browser never touches the profile files. Every read is a read-only read
 * of the JSON plus one `team-record.sh resolve` call for the authoritative
 * record line, and every write is a `team-record.sh write` call. The server
 * holds no state: the JSON files are the only state, so a restart loses
 * nothing.
 *
 * Routes (three of them, all local):
 *
 *   GET  /api/state            profiles + model master
 *   PUT  /api/profile          one profile, guarded by an expected hash
 *   POST /api/models/refresh   run refresh-models.sh
 *
 * Safety: the socket binds 127.0.0.1 only, the Host header must name
 * localhost/127.0.0.1 and the listening port, and a browser Origin must parse
 * to the same host and port over http. A cross-origin page (or a DNS
 * rebinding) therefore cannot drive the editor even though any local process
 * can reach it.
 */

import http from "node:http";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  REQUIRED_ROLE_NAMES,
  ROLE_NAMES,
  isProfileName,
  profileFileName,
} from "../lib/team-record.mjs";

const HOST = "127.0.0.1";
const DEFAULT_PORT = 9999;
const MAX_BODY_BYTES = 64 * 1024;
const STALE_AFTER_DAYS = 30;
const ROLE_FIELDS = ["provider", "model", "thinking"];
const PROFILE_KEYS = ["pr_fix_shared_with_impl", "roles"];

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const PACKAGE_DIR = path.dirname(SCRIPT_DIR);

const USAGE = `Usage: server.mjs [--port <port>] [--resolver <path>] [--refresh <path>] [--team-record <path>] [--index <path>]

Serves the local profile editor on 127.0.0.1.
  --port         listening port (default: PI_MODEL_EDITOR_PORT or 9999)
  --resolver     model-spec resolver passed to team-record.sh
  --refresh      refresh-models.sh replacement (default: the sibling script)
  --team-record  team-record.sh replacement (default: the sibling script)
  --index        HTML document to serve (default: the sibling index.html)

Prints one line after binding:
  listening host=127.0.0.1 port=<port>`;

/** Root of pi's configuration directory, matching team-record.mjs. */
function piAgentDir() {
  const configured = (process.env.PI_CODING_AGENT_DIR ?? "").trim();
  const base = configured !== "" ? configured : path.join(os.homedir(), ".pi", "agent");
  return path.resolve(base);
}

function assetDir() {
  return path.join(piAgentDir(), "pi-development");
}

function profilesDir() {
  return path.join(assetDir(), "profiles");
}

function profilePath(name) {
  return path.join(profilesDir(), profileFileName(name));
}

function masterPath() {
  return path.join(assetDir(), "models.json");
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** True when a value can be embedded in a `role=provider/model/thinking` spec. */
function isSafeField(value) {
  return typeof value === "string" && value !== "" && !/[\s\u0000-\u001f\u007f]/.test(value);
}

function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
}

function firstLine(text) {
  return (text ?? "").split("\n")[0].trim();
}

function ageInDays(isoTimestamp) {
  const parsed = Date.parse(isoTimestamp);
  if (!Number.isFinite(parsed)) {
    return Number.POSITIVE_INFINITY;
  }
  return (Date.now() - parsed) / 86_400_000;
}

function parseArgs(argv) {
  const options = { port: "", resolver: "", refresh: "", teamRecord: "", index: "" };
  const keys = {
    "--port": "port",
    "--resolver": "resolver",
    "--refresh": "refresh",
    "--team-record": "teamRecord",
    "--index": "index",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") {
      return { help: true };
    }
    const key = keys[arg];
    if (key) {
      const value = argv[i + 1];
      if (typeof value !== "string" || value === "") {
        return { error: `${arg} requires a value` };
      }
      options[key] = value;
      i += 1;
      continue;
    }
    return { error: `unexpected argument '${arg}'` };
  }
  return { options };
}

/** The catalog cache, as the UI needs it. A missing or broken file is not fatal. */
function readMaster(currentPiVersion) {
  let text;
  try {
    text = readFileSync(masterPath(), "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      return { status: "missing" };
    }
    return { status: "invalid", reason: "unreadable" };
  }
  let document;
  try {
    document = JSON.parse(text);
  } catch {
    return { status: "invalid", reason: "invalid-json" };
  }
  if (
    !isPlainObject(document) ||
    typeof document.generated_at !== "string" ||
    typeof document.pi_version !== "string" ||
    !Array.isArray(document.providers)
  ) {
    return { status: "invalid", reason: "invalid-shape" };
  }
  const providers = document.providers
    .filter((provider) => isPlainObject(provider) && typeof provider.id === "string" && Array.isArray(provider.models))
    .map((provider) => ({ id: provider.id, models: provider.models }));
  if (providers.length !== document.providers.length) {
    return { status: "invalid", reason: "invalid-shape" };
  }
  const versionChanged = currentPiVersion !== "" && document.pi_version !== currentPiVersion;
  const tooOld = ageInDays(document.generated_at) > STALE_AFTER_DAYS;
  return {
    status: "ok",
    stale: versionChanged || tooOld,
    stale_reason: versionChanged ? "pi-version" : tooOld ? "age" : "",
    generated_at: document.generated_at,
    pi_version: document.pi_version,
    current_pi_version: currentPiVersion,
    providers,
  };
}

/** Unknown keys a later `write` drops. `resolve` ignores them silently. */
function unknownKeys(raw) {
  const unknown = { top: [], roles: {} };
  if (!isPlainObject(raw)) {
    return unknown;
  }
  for (const key of Object.keys(raw)) {
    if (!PROFILE_KEYS.includes(key)) {
      unknown.top.push(key);
    }
  }
  if (isPlainObject(raw.roles)) {
    for (const [role, spec] of Object.entries(raw.roles)) {
      const extra = isPlainObject(spec)
        ? Object.keys(spec).filter((key) => !ROLE_FIELDS.includes(key))
        : [];
      if (!ROLE_NAMES.includes(role) || extra.length > 0) {
        unknown.roles[role] = extra;
      }
    }
  }
  return unknown;
}

function storedRoles(raw) {
  const roles = {};
  if (!isPlainObject(raw) || !isPlainObject(raw.roles)) {
    return roles;
  }
  for (const role of ROLE_NAMES) {
    const spec = raw.roles[role];
    if (!isPlainObject(spec)) {
      continue;
    }
    roles[role] = {};
    for (const key of ROLE_FIELDS) {
      if (typeof spec[key] === "string") {
        roles[role][key] = spec[key];
      }
    }
  }
  return roles;
}

/** Name-ordered profile files. A name that is not a profile is not an entry. */
function listProfileNames() {
  let entries;
  try {
    entries = readdirSync(profilesDir());
  } catch (error) {
    if (error?.code === "ENOENT") {
      return [];
    }
    throw error;
  }
  return entries
    .filter((entry) => entry.endsWith(".json"))
    .map((entry) => entry.slice(0, -".json".length))
    .filter((name) => isProfileName(name))
    .sort();
}

function run(command, args, timeout) {
  return spawnSync(command, args, { encoding: "utf8", timeout });
}

/**
 * One profile as the UI needs it.
 *
 * `roles`, `unknown`, and `hash` come from the file; the `record` line comes
 * from `team-record.sh resolve`, so the reader and the writer agree on the
 * contract instead of a second parser growing here.
 */
function readProfile(name, { teamRecord, resolver }) {
  const file = profilePath(name);
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch (error) {
    return { name, error: error?.code === "ENOENT" ? "missing" : "unreadable" };
  }
  const hash = sha256(text);
  let raw;
  try {
    raw = JSON.parse(text);
  } catch {
    return { name, hash, error: "invalid-json" };
  }
  const args = ["resolve", "--profile", name];
  if (resolver) {
    args.push("--resolver", resolver);
  }
  const result = run(teamRecord, args, 20_000);
  const record = firstLine(result.stdout);
  const profile = {
    name,
    hash,
    pr_fix_shared_with_impl: raw?.pr_fix_shared_with_impl === true,
    roles: storedRoles(raw),
    unknown: unknownKeys(raw),
    record,
  };
  if (result.error) {
    profile.error = "resolve-not-runnable";
  } else if (!record.includes("result=ok")) {
    profile.error = "resolve-not-ok";
  }
  return profile;
}

function readState({ teamRecord, resolver }, currentPiVersion) {
  return {
    profiles: listProfileNames().map((name) => readProfile(name, { teamRecord, resolver })),
    models: readMaster(currentPiVersion),
  };
}

function sendJson(response, status, payload) {
  const body = `${JSON.stringify(payload)}\n`;
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
  });
  response.end(body);
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(Object.assign(new Error("body too large"), { code: "too-large" }));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

/** The Host header must name this loopback socket, not a rebound domain. */
function hostAllowed(hostHeader, port) {
  if (typeof hostHeader !== "string") {
    return false;
  }
  const value = hostHeader.toLowerCase();
  return value === `localhost:${port}` || value === `127.0.0.1:${port}`;
}

/**
 * A browser Origin carries a scheme, so it is parsed instead of compared with
 * the Host allowlist. An absent Origin is a non-browser client (curl, tests).
 */
function originAllowed(originHeader, port) {
  if (typeof originHeader !== "string" || originHeader === "") {
    return true;
  }
  let parsed;
  try {
    parsed = new URL(originHeader);
  } catch {
    return false;
  }
  return (
    parsed.protocol === "http:" &&
    (parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1") &&
    parsed.port === String(port)
  );
}

function validateProfileRequest(body) {
  if (!isPlainObject(body)) {
    return "body must be a JSON object";
  }
  for (const key of Object.keys(body)) {
    if (!["profile", "expected_hash", "pr_fix_shared_with_impl", "roles"].includes(key)) {
      return `unknown field '${key}'`;
    }
  }
  if (typeof body.profile !== "string" || !isProfileName(body.profile)) {
    return "profile must be a profile name";
  }
  if (typeof body.expected_hash !== "string" || !/^[0-9a-f]{64}$/.test(body.expected_hash)) {
    return "expected_hash must be a sha256 hex digest";
  }
  if (typeof body.pr_fix_shared_with_impl !== "boolean") {
    return "pr_fix_shared_with_impl must be a boolean";
  }
  if (!isPlainObject(body.roles)) {
    return "roles must be an object";
  }
  for (const [role, spec] of Object.entries(body.roles)) {
    if (!ROLE_NAMES.includes(role)) {
      return `unknown role '${role}'`;
    }
    if (!isPlainObject(spec)) {
      return `roles.${role} must be an object`;
    }
    for (const key of Object.keys(spec)) {
      if (!ROLE_FIELDS.includes(key)) {
        return `unknown field 'roles.${role}.${key}'`;
      }
    }
    for (const key of ROLE_FIELDS) {
      if (!isSafeField(spec[key])) {
        return `roles.${role}.${key} must be a non-empty field`;
      }
    }
  }
  for (const role of REQUIRED_ROLE_NAMES) {
    if (!isPlainObject(body.roles[role])) {
      return `roles.${role} is required`;
    }
  }
  return "";
}

/** Build the `write` arguments. `ui-tester` is passed only when it is set. */
function writeArgs(body, { teamRecord, resolver }) {
  const args = [
    "write",
    "--profile",
    body.profile,
    "--pr-fix-shared-with-impl",
    String(body.pr_fix_shared_with_impl),
  ];
  for (const role of ROLE_NAMES) {
    const spec = body.roles[role];
    if (!isPlainObject(spec)) {
      continue;
    }
    args.push("--role", `${role}=${spec.provider}/${spec.model}/${spec.thinking}`);
  }
  if (resolver) {
    args.push("--resolver", resolver);
  }
  return args;
}

async function handleProfilePut(request, response, context) {
  let body;
  try {
    body = JSON.parse(await readBody(request));
  } catch (error) {
    const code = error?.code === "too-large" ? 413 : 400;
    sendJson(response, code, { result: "rejected", reason: "invalid-body" });
    return;
  }
  const problem = validateProfileRequest(body);
  if (problem) {
    sendJson(response, 400, { result: "rejected", reason: problem });
    return;
  }

  let current;
  try {
    current = readFileSync(profilePath(body.profile), "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      sendJson(response, 404, { result: "rejected", reason: "missing-profile" });
      return;
    }
    sendJson(response, 500, { result: "rejected", reason: "unreadable-profile" });
    return;
  }
  const hash = sha256(current);
  if (hash !== body.expected_hash) {
    sendJson(response, 409, { result: "conflict", expected_hash: body.expected_hash, hash });
    return;
  }

  const result = run(context.teamRecord, writeArgs(body, context), 30_000);
  const record = firstLine(result.stdout);
  if (result.error) {
    sendJson(response, 502, { result: "failed", reason: "write-not-runnable" });
    return;
  }
  if (!record.includes("result=ok")) {
    sendJson(response, 422, { result: "rejected", record, stderr: (result.stderr ?? "").trim() });
    return;
  }
  sendJson(response, 200, { result: "ok", record });
}

async function handleRefresh(response, context) {
  if (context.refreshing) {
    sendJson(response, 409, { result: "rejected", reason: "refresh-in-progress" });
    return;
  }
  context.refreshing = true;
  let result;
  try {
    result = run(context.refresh, [], 120_000);
  } finally {
    context.refreshing = false;
  }
  const record = firstLine(result.stdout);
  if (result.error) {
    sendJson(response, 500, { result: "failed", reason: "refresh-not-runnable" });
    return;
  }
  if (!record.includes("result=ok")) {
    sendJson(response, 500, { result: "failed", record, stderr: (result.stderr ?? "").trim() });
    return;
  }
  const models = readMaster(context.currentPiVersion);
  sendJson(response, 200, { result: "ok", record, models });
}

async function route(request, response, context) {
  const url = new URL(request.url ?? "/", `http://${HOST}:${context.port}`);
  if (!hostAllowed(request.headers.host, context.port)) {
    sendJson(response, 403, { result: "rejected", reason: "host" });
    return;
  }
  const mutating = request.method === "PUT" || request.method === "POST";
  if (mutating && !originAllowed(request.headers.origin, context.port)) {
    sendJson(response, 403, { result: "rejected", reason: "origin" });
    return;
  }

  if (request.method === "GET" && url.pathname === "/") {
    response.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "content-length": Buffer.byteLength(context.indexHtml),
      "cache-control": "no-store",
    });
    response.end(context.indexHtml);
    return;
  }
  if (request.method === "GET" && url.pathname === "/api/state") {
    sendJson(response, 200, readState(context, context.currentPiVersion));
    return;
  }
  if (request.method === "PUT" && url.pathname === "/api/profile") {
    await handleProfilePut(request, response, context);
    return;
  }
  if (request.method === "POST" && url.pathname === "/api/models/refresh") {
    await handleRefresh(response, context);
    return;
  }
  sendJson(response, 404, { result: "rejected", reason: "not-found" });
}

function currentPiVersion() {
  const result = spawnSync("pi", ["--version"], { encoding: "utf8", timeout: 15_000 });
  if (result.error || typeof result.stdout !== "string") {
    return "";
  }
  return firstLine(result.stdout);
}

function main() {
  const parsed = parseArgs(process.argv.slice(2));
  if (parsed.help) {
    process.stdout.write(`${USAGE}\n`);
    return 0;
  }
  if (parsed.error) {
    process.stderr.write(`server: ${parsed.error}\n${USAGE}\n`);
    return 2;
  }
  const options = parsed.options;
  const port = options.port !== "" ? Number(options.port) : Number(process.env.PI_MODEL_EDITOR_PORT ?? DEFAULT_PORT);
  if (!Number.isInteger(port) || port < 0 || port > 65_535) {
    process.stderr.write("server: --port must be an integer between 0 and 65535\n");
    return 2;
  }

  const indexPath = options.index || path.join(SCRIPT_DIR, "index.html");
  let indexHtml;
  try {
    indexHtml = readFileSync(indexPath, "utf8");
  } catch (error) {
    process.stderr.write(`server: cannot read '${indexPath}': ${error.message}\n`);
    return 1;
  }

  const context = {
    port,
    teamRecord: options.teamRecord || path.join(PACKAGE_DIR, "team-record.sh"),
    refresh: options.refresh || path.join(PACKAGE_DIR, "refresh-models.sh"),
    resolver: options.resolver,
    indexHtml,
    currentPiVersion: currentPiVersion(),
    refreshing: false,
  };

  const server = http.createServer((request, response) => {
    route(request, response, context).catch((error) => {
      process.stderr.write(`server: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
      if (!response.headersSent) {
        sendJson(response, 500, { result: "failed", reason: "internal" });
        return;
      }
      response.destroy();
    });
  });

  server.on("error", (error) => {
    process.stderr.write(`server: cannot listen on ${HOST}:${port}: ${error.message}\n`);
    process.exit(1);
  });
  server.listen(port, HOST, () => {
    context.port = server.address().port;
    process.stdout.write(`listening host=${HOST} port=${context.port}\n`);
  });

  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.on(signal, () => {
      server.close(() => process.exit(0));
    });
  }
  return null;
}

const code = main();
if (code !== null) {
  process.exit(code);
}
