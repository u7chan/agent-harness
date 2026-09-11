# playwright-cli command reference

The examples below are written as `playwright-cli xxx`, but from this skill **run them as `pw.sh xxx`** (the `-s=` session pinning, banner stripping, and snapshot inlining are done on the `pw.sh` side).

## Commands

### Basics

```bash
playwright-cli open
# open and stay there
playwright-cli open https://example.com/
playwright-cli goto https://playwright.dev
playwright-cli type "search query"
playwright-cli click e3
playwright-cli dblclick e7
playwright-cli fill e5 "user@example.com"
playwright-cli fill e5 "user@example.com" --submit
playwright-cli drop e5 --path=/abs/path/file.png
playwright-cli drop e5 --data "text/plain=hello"
playwright-cli drag e2 e8
playwright-cli hover e4
playwright-cli select e9 "option-value"
playwright-cli upload ./document.pdf
playwright-cli check e12
playwright-cli uncheck e12
playwright-cli snapshot
playwright-cli snapshot --depth=3
playwright-cli snapshot e34
playwright-cli snapshot "#main"
playwright-cli snapshot --boxes
playwright-cli snapshot --filename=after-click.yaml
playwright-cli find "Sign in"
playwright-cli find --regex "Sign ?in"
playwright-cli eval "document.title"
playwright-cli eval "el => el.textContent" e5
playwright-cli dialog-accept
playwright-cli dialog-accept "confirmation text"
playwright-cli dialog-dismiss
playwright-cli resize 1920 1080
playwright-cli close
```

### Navigation

```bash
playwright-cli go-back
playwright-cli go-forward
playwright-cli reload
```

### Keyboard

```bash
playwright-cli press Enter
playwright-cli press ArrowDown
playwright-cli keydown Shift
playwright-cli keyup Shift
```

### Mouse

```bash
playwright-cli mousemove 150 300
playwright-cli mousedown
playwright-cli mousedown right
playwright-cli mouseup
playwright-cli mouseup right
playwright-cli mousewheel 0 100
```

### Saving

```bash
playwright-cli screenshot
playwright-cli screenshot e5
playwright-cli screenshot --filename=page.png
playwright-cli screenshot --hires
playwright-cli pdf --filename=page.pdf
```

### Tabs

```bash
playwright-cli tab-list
playwright-cli tab-new
playwright-cli tab-new https://example.com/page
playwright-cli tab-close
playwright-cli tab-close 2
playwright-cli tab-select 0
```

### Storage

```bash
playwright-cli state-save
playwright-cli state-save auth.json
playwright-cli state-load auth.json

# Cookies — when `cookie-set` omits `--domain`, it uses the current page's
# origin for domain/path. Specify `--domain` explicitly when targeting another origin.
playwright-cli cookie-list
playwright-cli cookie-list --domain=example.com
playwright-cli cookie-get session_id
playwright-cli cookie-set session_id abc123
playwright-cli cookie-set session_id abc123 --domain=example.com --httpOnly --secure
playwright-cli cookie-delete session_id
playwright-cli cookie-clear

# LocalStorage
playwright-cli localstorage-list
playwright-cli localstorage-get theme
playwright-cli localstorage-set theme dark
playwright-cli localstorage-delete theme
playwright-cli localstorage-clear

# SessionStorage
playwright-cli sessionstorage-list
playwright-cli sessionstorage-get step
playwright-cli sessionstorage-set step 3
playwright-cli sessionstorage-delete step
playwright-cli sessionstorage-clear
```

### Network

```bash
playwright-cli requests
playwright-cli request 3
playwright-cli response-body 3
playwright-cli route "**/*.jpg" --status=404
playwright-cli route "https://api.example.com/**" --body='{"mock": true}'
playwright-cli route-list
playwright-cli unroute "**/*.jpg"
playwright-cli unroute
playwright-cli network-state-set offline
```

### DevTools

```bash
playwright-cli console
playwright-cli console warning
playwright-cli run-code "async page => await page.context().grantPermissions(['geolocation'])"
playwright-cli run-code --filename=script.js   # read the code from a file
playwright-cli tracing-start
playwright-cli tracing-stop
playwright-cli video-start video.webm
playwright-cli video-stop
playwright-cli video-chapter "Checkout" --description="up to payment" --duration=2000
playwright-cli generate-locator e5
playwright-cli highlight e5
playwright-cli highlight --hide
playwright-cli show --annotate
```

### Installation

```bash
playwright-cli install
playwright-cli install-browser chromium
# firefox / webkit / msedge likewise
```

## Targets other than refs

`<target>` for `click` / `fill` / `hover` etc. is usually a snapshot `ref`, but a CSS selector or a Playwright locator is also accepted. This is the escape hatch for when the `ref` is stale or the element does not appear in the snapshot.

```bash
playwright-cli click "#main > button.submit"
playwright-cli click "getByRole('button', { name: 'Submit' })"
playwright-cli click "getByTestId('submit-button')"
```

## `--raw` for data only

The global option `--raw` drops the Page / generated code / Snapshot sections and returns only the resulting value. Use it for data extraction and piping.

```bash
pw.sh --raw eval "document.title"
pw.sh --raw eval "JSON.stringify([...document.querySelectorAll('a')].map(a => a.href))" > links.json
pw.sh --raw snapshot > before.yml
pw.sh --raw cookie-get session_id
pw.sh --raw localstorage-get theme
```

Passing a target as the second argument of `eval` scopes it to that element (`pw.sh --raw eval "el => el.textContent" e5`). To write the result to a file, use `eval --filename=out.json`.

## `open` parameters

```bash
# Choose the browser at session creation time
playwright-cli open --browser=chrome
playwright-cli open --browser=firefox
playwright-cli open --browser=webkit
playwright-cli open --browser=msedge
```

Extensions and connecting to an existing browser use `attach`, not `open`:

```bash
playwright-cli attach --extension=chrome
playwright-cli attach --cdp=chrome
playwright-cli attach --cdp=http://localhost:9222
playwright-cli -s=<name> detach
```

```bash
# Use a persistent profile (the default is in-memory)
playwright-cli open --persistent
# Use a persistent profile with a directory you specify
playwright-cli open --profile=/path/to/profile

# Launch with a config file
playwright-cli open --config=my-config.json

# Open as a lightweight mobile view (saves tokens)
playwright-cli open --mobile
playwright-cli open --device="iphone 15"

# Close the browser
playwright-cli close
# Delete the default session's user data
playwright-cli delete-data
```

`--headed` (visible window) is auto-detected from the environment by `pw.sh open`. To be explicit, use `PW_HEADED=1` / `PW_HEADED=0`.

- macOS / Windows (native): a headed browser works as is
- WSL2: showing a window requires WSLg (headed is possible when `$DISPLAY` is set and `/mnt/wslg` exists)
- Headless environments (CI, SSH without a display, Linux without a GUI): launches headless

## Snapshots

Action commands write a snapshot to a file after running, and the output returns only the path.

```bash
> playwright-cli goto https://example.com
### Page
- Page URL: https://example.com/
- Page Title: Example Domain
### Snapshot
- [Snapshot](.playwright-cli/page-2026-02-14T19-22-42-679Z.yml)
```

`pw.sh` reads this path, inlines the content at the end of its output as `### Snapshot (path, N bytes)`, and drops the original `- [Snapshot](path)` link line (so nothing invites a follow-up Read). The `snapshot` / `find` commands return the yaml inline from the start. When the output is too large, cut it down at the source with `snapshot --depth=N` / `snapshot <ref>` / `find`.

Without `--filename`, `pw.sh` creates a new timestamped snapshot file under its identifier-based temporary artifact directory (`${TMPDIR:-/tmp}/playwright-cli/<identifier>`), outside the current directory. `--filename=` accepts both relative (from the cwd) and absolute paths; use it only when the artifact is intentionally part of the workflow's result.

## Browser sessions

**In agent / multi-process environments, prefer `-s=<name>`.** The unnamed `default` session is shared by all processes on this host, so when another agent calls `playwright-cli open` your page can be hijacked, and your subsequent commands may land in the other agent's tabs. Named sessions are isolated. `pw.sh` attaches `PW_SESSION` (default `playwright`) to every command as `-s=`, so normally you do not have to think about it. Use `PW_SESSION=other pw.sh ...` only when you need another session in parallel.

**A session is tied to the workspace of the cwd it was opened from.** A workspace is the nearest ancestor directory that has `.playwright/` (falling back to the package root), and `-s=<name>` does not change that scope. Running from the cwd of another workspace returns `Browser 'xxx' is not open`. **Use the same cwd.** Snapshot paths are also cwd-relative, which makes reading them back easy.

**Recovering a broken session** (`Session closed`, `EADDRINUSE`, or `open` itself failing). `is not open` is not broken — just `open` again:

```bash
playwright-cli close-all   # first (only the sessions registered in this workspace)
playwright-cli kill-all    # if that is not enough: force-kill leftover processes on the host
```

`pw.sh recover` bundles these two. `close-all` closes **only the sessions registered in the same workspace** (the safe first move); `kill-all` is the one that hits every process on the host, so recover is never run automatically.

```bash
playwright-cli list        # session list
playwright-cli list --all  # include other workspaces' sessions
playwright-cli close-all
playwright-cli kill-all
```

## Local installation

If running the global `playwright-cli` binary fails, use `npx @playwright/cli`. With `pw.sh`, swap the binary via `PW_BIN`.

```bash
PW_BIN='npx @playwright/cli' pw.sh open https://example.com
```
