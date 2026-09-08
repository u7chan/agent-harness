# Video recording

Record browser automation sessions as video for debugging, documentation, and verification. Outputs WebM (VP8/VP9 codecs).

## Basic recording

```bash
# Start recording (pass the file name to video-start)
playwright-cli video-start demo.webm

# Perform actions
playwright-cli open https://example.com
playwright-cli snapshot
playwright-cli click e1
playwright-cli fill e2 "test input"

# Stop and save (no arguments)
playwright-cli video-stop
```

## Best practices

### 1. Use file names that describe the content

```bash
# Include context in the file name
playwright-cli video-start recordings/login-flow-2024-01-15.webm
playwright-cli video-start recordings/checkout-test-run-42.webm
```

### 2. Mark chapters

```bash
playwright-cli video-chapter "Login" --description="up to authentication" --duration=2000
```

## Tracing vs video comparison

| Aspect | Video | Tracing |
|---------|-------|---------|
| Output | WebM file | Trace file (viewable in the Trace Viewer) |
| Records | Visual recording | DOM snapshots, network, console, actions |
| Use case | Demos, documentation | Debugging, analysis |
| Size | Large | Small |

## Limitations

- Recording adds a slight overhead to automation
- Large recordings can consume a lot of disk space
