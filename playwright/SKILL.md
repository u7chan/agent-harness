---
name: playwright
description: Automate browser operations with Playwright. Use for web navigation, form filling, screenshots, data extraction, and web app testing.
---

# Browser automation with playwright-cli

Run every operation through `scripts/pw.sh` next to this SKILL.md (below: `pw.sh`). Resolve the script from the directory of the SKILL.md you actually read: its absolute path is `<skill-dir>/scripts/pw.sh`, where `<skill-dir>` is that directory. Invoke it by that absolute path and do not depend on a harness-injected base directory.

`pw.sh` is a wrapper around the plain CLI that pins the session name, strips the update banner, **inlines snapshots** (the plain CLI returns only a path), and adds an `open` preflight.

## Basic loop

```bash
pw.sh open https://example.com/   # the snapshot is inlined at the end of the output
pw.sh click e6                    # pass the [ref=e6] from the snapshot
pw.sh fill e3 "user@example.com"
pw.sh close
```

One command = one tool call. Decide the next step from the `ref` it returns. If you only want to see the state, run `pw.sh snapshot`.

**Run from the same cwd as `open`.** A session is tied to the workspace of the cwd (the nearest ancestor directory that has `.playwright/`), and the `-s` name does not change that scope.

Always finish with `pw.sh close`. `.playwright-cli/page-*.yml` files are artifact output and belong in `.gitignore`.

## Batch (consecutive operations with no need to see the state in between)

Bundle consecutive operations when you do not need the intermediate snapshots. **It stops at the first failure** and reports which line it stopped on. Only the last successful snapshot is inlined.

```bash
pw.sh - <<'EOF'
fill e1 "user@example.com"
fill e2 "secret"
click e3
EOF
```

One command per line. Blank lines and lines starting with `#` are skipped. Only `'…'` and `"…"` quoting is interpreted (`fill e1 "hello world"` is one argument). Wrap a value containing `'` in `"…"`. `\` is not interpreted. `"` cannot appear inside `"…"`.

**Do not batch across operations that change refs.** A click that re-renders the page shifts the refs of the following lines.

Instead of a `ref`, you can pass a CSS selector or a Playwright locator (`pw.sh click "#main > button.submit"`, `pw.sh click "getByRole('button', { name: 'Submit' })"`). Use these when the ref is stale or the element does not appear in the snapshot.

## Narrowing down large pages

Above `PW_SNAPSHOT_MAX` (default 12000 bytes) the output is truncated. Cut it down at the source:

```bash
pw.sh snapshot --depth=4      # cut off by depth
pw.sh snapshot e34            # only under that element (selectors also work)
pw.sh find "Sign in"          # search by text and return only the surroundings
pw.sh open https://example.com/ --mobile  # the mobile view is lighter
```

## When it breaks

`is not open` alone means nothing is broken (not opened yet / already closed / cwd from another workspace). Re-running `pw.sh open <url>` is enough. **recover is not needed.**

Only when `Session closed` / `EADDRINUSE` occurs, or `open` itself fails, run `pw.sh recover` (`close-all` → `kill-all`). `kill-all` **sweeps in every session on the host**, so confirm with the user first.

## Environment variables

`PW_SESSION` (default `playwright`) / `PW_SNAPSHOT_MAX` (default 12000) / `PW_HEADED` (`1` visible, `0` headless; auto-detected by default) / `PW_BIN` (default `playwright-cli`).

## Topics

* Command list, `open` parameters, session details [references/commands.md](references/commands.md)
* Request mocking [references/request-mocking.md](references/request-mocking.md)
* Running Playwright code [references/running-code.md](references/running-code.md)
* Browser session management [references/session-management.md](references/session-management.md)
* Storage state (cookies, localStorage) [references/storage-state.md](references/storage-state.md)
* Test code generation [references/test-generation.md](references/test-generation.md)
* Tracing [references/tracing.md](references/tracing.md)
* Video recording [references/video-recording.md](references/video-recording.md)
