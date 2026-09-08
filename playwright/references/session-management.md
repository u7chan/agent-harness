# Browser session management

Run multiple isolated browser sessions concurrently while persisting their state.

## Named browser sessions

Isolate browser contexts with the `-s` flag:

```bash
# Browser 1: an authentication flow
playwright-cli -s=auth open https://app.example.com/login

# Browser 2: public browsing (separate cookies and storage)
playwright-cli -s=public open https://example.com

# Commands are isolated per browser session
playwright-cli -s=auth fill e1 "user@example.com"
playwright-cli -s=public snapshot
```

## Browser session isolation properties

Each browser session independently owns:
- Cookies
- LocalStorage / SessionStorage
- IndexedDB
- Cache
- Browsing history
- Open tabs

## Browser session commands

```bash
# List all browser sessions
playwright-cli list

# Stop a browser session (closes the browser)
playwright-cli close                # stop the default browser
playwright-cli -s=mysession close   # stop the named browser

# Stop all browser sessions
playwright-cli close-all

# Force-kill all daemon processes (for leftover or zombie processes)
playwright-cli kill-all

# Delete a browser session's user data (the profile directory)
playwright-cli delete-data                # delete the default browser data
playwright-cli -s=mysession delete-data   # delete the named browser data
```

## Environment variables

Set the default browser session name via an environment variable:

```bash
export PLAYWRIGHT_CLI_SESSION="mysession"
playwright-cli open example.com  # automatically uses "mysession"
```

This variable has no effect through `pw.sh`, because it always passes `-s=` explicitly. Use `PW_SESSION` instead.

## Common patterns

### Concurrent scraping

```bash
#!/bin/bash
# Scrape several sites concurrently

# Launch all browsers
playwright-cli -s=site1 open https://site1.com &
playwright-cli -s=site2 open https://site2.com &
playwright-cli -s=site3 open https://site3.com &
wait

# Take a snapshot from each
playwright-cli -s=site1 snapshot
playwright-cli -s=site2 snapshot
playwright-cli -s=site3 snapshot

# Clean up
playwright-cli close-all
```

### A/B test sessions

```bash
# Open different user experiences
playwright-cli -s=variant-a open "https://app.com?variant=a"
playwright-cli -s=variant-b open "https://app.com?variant=b"

# Compare
playwright-cli -s=variant-a screenshot
playwright-cli -s=variant-b screenshot
```

### Persistent profiles

By default, the browser profile is kept in memory only. Use the `--persistent` flag with `open` to persist the browser profile to disk:

```bash
# Use a persistent profile (the location is auto-generated)
playwright-cli open https://example.com --persistent

# Use a persistent profile with a custom directory
playwright-cli open https://example.com --profile=/path/to/profile
```

## The default browser session

When `-s` is omitted, commands use the default browser session:

```bash
# These all use the same default browser session
playwright-cli open https://example.com
playwright-cli snapshot
playwright-cli close  # stop the default browser
```

## Browser session configuration

Configure a browser session with specific settings when opening it:

```bash
# Open with a config file
playwright-cli open https://example.com --config=.playwright/my-cli.json

# Open with a specific browser
playwright-cli open https://example.com --browser=firefox

# Open in headed mode
playwright-cli open https://example.com --headed

# Open with a persistent profile
playwright-cli open https://example.com --persistent
```

## Best practices

### 1. Give browser sessions meaningful names

```bash
# GOOD: the purpose is clear
playwright-cli -s=github-auth open https://github.com
playwright-cli -s=docs-scrape open https://docs.example.com

# AVOID: generic names
playwright-cli -s=s1 open https://github.com
```

### 2. Always clean up

```bash
# Stop the browsers when done
playwright-cli -s=auth close
playwright-cli -s=scrape close

# Or stop them all at once
playwright-cli close-all

# If a browser stops responding or zombie processes remain
playwright-cli kill-all
```

### 3. Delete stale browser data

```bash
# Delete old browser data to free disk space
playwright-cli -s=oldsession delete-data
```
