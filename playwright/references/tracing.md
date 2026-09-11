# Tracing

Capture detailed execution traces for debugging and analysis. A trace contains DOM snapshots, screenshots, network activity, and console logs.

## Basic usage

```bash
# Start trace recording
playwright-cli tracing-start

# Perform actions
playwright-cli open https://example.com
playwright-cli click e1
playwright-cli fill e2 "test"

# Stop trace recording
playwright-cli tracing-stop
```

## Trace output files

When tracing starts, Playwright creates a `traces/` directory containing several files:

### `trace-{timestamp}.trace`

**Action log** - the main trace file, containing:
- Every action performed (clicks, input, navigation)
- DOM snapshots before and after each action
- A screenshot for each step
- Timing information
- Console messages
- Source locations

### `trace-{timestamp}.network`

**Network log** - the full network activity:
- Every HTTP request and response
- Request headers and bodies
- Response headers and bodies
- Timing (DNS, connect, TLS, TTFB, download)
- Resource sizes
- Failed requests and errors

### `resources/`

**Resource directory** - cached resources:
- Images, fonts, stylesheets, scripts
- Response bodies for replay
- Assets required to reconstruct the page state

## What a trace captures

| Category | Details |
|----------|---------|
| **Actions** | Clicks, input, hover, keyboard events, navigation |
| **DOM** | Full DOM snapshots before and after each action |
| **Screenshots** | The visual state at each step |
| **Network** | Every request, response, header, body, and timing |
| **Console** | Every console.log, warn, and error message |
| **Timing** | Exact timing of every operation |

## Use cases

### Debugging a failed action

```bash
playwright-cli tracing-start
playwright-cli open https://app.example.com

# This click fails - why?
playwright-cli click e5

playwright-cli tracing-stop
# Open the trace and inspect the DOM state at the moment the click was attempted
```

### Performance analysis

```bash
playwright-cli tracing-start
playwright-cli open https://slow-site.com
playwright-cli tracing-stop

# View the network waterfall to find slow resources
```

### Capturing evidence

```bash
# Record a complete user flow for documentation
playwright-cli tracing-start

playwright-cli open https://app.example.com/checkout
playwright-cli fill e1 "4111111111111111"
playwright-cli fill e2 "12/25"
playwright-cli fill e3 "123"
playwright-cli click e4

playwright-cli tracing-stop
# The trace shows the exact sequence of events
```

## Trace vs video vs screenshot

| Feature | Trace | Video | Screenshot |
|---------|-------|-------|------------|
| **Format** | .trace file | .webm video | .png/.jpeg image |
| **DOM inspection** | Yes | No | No |
| **Network details** | Yes | No | No |
| **Step-by-step replay** | Yes | Continuous | Single frame |
| **File size** | Medium | Large | Small |
| **Best for** | Debugging | Demos | Quick captures |

## Best practices

### 1. Start tracing before the problem

```bash
# Trace the whole flow, not just the failing step
playwright-cli tracing-start
playwright-cli open https://example.com
# ... every step leading up to the problem ...
playwright-cli tracing-stop
```

### 2. Clean up old traces

Traces can consume a lot of disk space:

```bash
# Delete traces older than 7 days
find "${TMPDIR:-/tmp}/playwright-cli" -path '*/traces/*' -mtime +7 -delete
```

## Limitations

- Tracing adds overhead to automation
- Large traces can consume a lot of disk space
- Some dynamic content may not replay perfectly
