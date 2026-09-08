# Running custom Playwright code

For advanced scenarios not covered by CLI commands, use `run-code` to execute arbitrary Playwright code.

## Syntax

```bash
playwright-cli run-code "async page => {
  // Write Playwright code here
  // Access page.context() for browser context operations
}"
```

## Geolocation

```bash
# Grant the geolocation permission and set the position
playwright-cli run-code "async page => {
  await page.context().grantPermissions(['geolocation']);
  await page.context().setGeolocation({ latitude: 37.7749, longitude: -122.4194 });
}"

# Set the position to London
playwright-cli run-code "async page => {
  await page.context().grantPermissions(['geolocation']);
  await page.context().setGeolocation({ latitude: 51.5074, longitude: -0.1278 });
}"

# Clear the geolocation override
playwright-cli run-code "async page => {
  await page.context().clearPermissions();
}"
```

## Permissions

```bash
# Grant multiple permissions
playwright-cli run-code "async page => {
  await page.context().grantPermissions([
    'geolocation',
    'notifications',
    'camera',
    'microphone'
  ]);
}"

# Grant a permission for a specific origin
playwright-cli run-code "async page => {
  await page.context().grantPermissions(['clipboard-read'], {
    origin: 'https://example.com'
  });
}"
```

## Media emulation

```bash
# Emulate a dark color scheme
playwright-cli run-code "async page => {
  await page.emulateMedia({ colorScheme: 'dark' });
}"

# Emulate a light color scheme
playwright-cli run-code "async page => {
  await page.emulateMedia({ colorScheme: 'light' });
}"

# Emulate reduced motion
playwright-cli run-code "async page => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
}"

# Emulate print media
playwright-cli run-code "async page => {
  await page.emulateMedia({ media: 'print' });
}"
```

## Wait strategies

```bash
# Wait until the network is idle
playwright-cli run-code "async page => {
  await page.waitForLoadState('networkidle');
}"

# Wait for a specific element
playwright-cli run-code "async page => {
  await page.waitForSelector('.loading', { state: 'hidden' });
}"

# Wait until a function returns true
playwright-cli run-code "async page => {
  await page.waitForFunction(() => window.appReady === true);
}"

# Wait with a timeout
playwright-cli run-code "async page => {
  await page.waitForSelector('.result', { timeout: 10000 });
}"
```

## Frames and iframes

```bash
# Work with an iframe
playwright-cli run-code "async page => {
  const frame = page.locator('iframe#my-iframe').contentFrame();
  await frame.locator('button').click();
}"

# Get all frames
playwright-cli run-code "async page => {
  const frames = page.frames();
  return frames.map(f => f.url());
}"
```

## File downloads

```bash
# Handle a file download
playwright-cli run-code "async page => {
  const [download] = await Promise.all([
    page.waitForEvent('download'),
    page.click('a.download-link')
  ]);
  await download.saveAs('./downloaded-file.pdf');
  return download.suggestedFilename();
}"
```

## Clipboard

```bash
# Read the clipboard (requires the permission)
playwright-cli run-code "async page => {
  await page.context().grantPermissions(['clipboard-read']);
  return await page.evaluate(() => navigator.clipboard.readText());
}"

# Write to the clipboard
playwright-cli run-code "async page => {
  await page.evaluate(text => navigator.clipboard.writeText(text), 'Hello clipboard!');
}"
```

## Page information

```bash
# Get the page title
playwright-cli run-code "async page => {
  return await page.title();
}"

# Get the current URL
playwright-cli run-code "async page => {
  return page.url();
}"

# Get the page content
playwright-cli run-code "async page => {
  return await page.content();
}"

# Get the viewport size
playwright-cli run-code "async page => {
  return page.viewportSize();
}"
```

## JavaScript execution

```bash
# Execute JavaScript and return the result
playwright-cli run-code "async page => {
  return await page.evaluate(() => {
    return {
      userAgent: navigator.userAgent,
      language: navigator.language,
      cookiesEnabled: navigator.cookieEnabled
    };
  });
}"

# Pass an argument to evaluate
playwright-cli run-code "async page => {
  const multiplier = 5;
  return await page.evaluate(m => document.querySelectorAll('li').length * m, multiplier);
}"
```

## Error handling

```bash
# try-catch inside run-code
playwright-cli run-code "async page => {
  try {
    await page.click('.maybe-missing', { timeout: 1000 });
    return 'clicked';
  } catch (e) {
    return 'element not found';
  }
}"
```

## Complex workflows

```bash
# Log in and save the state
playwright-cli run-code "async page => {
  await page.goto('https://example.com/login');
  await page.fill('input[name=email]', 'user@example.com');
  await page.fill('input[name=password]', 'secret');
  await page.click('button[type=submit]');
  await page.waitForURL('**/dashboard');
  await page.context().storageState({ path: 'auth.json' });
  return 'Login successful';
}"

# Scrape data from multiple pages
playwright-cli run-code "async page => {
  const results = [];
  for (let i = 1; i <= 3; i++) {
    await page.goto(\`https://example.com/page/\${i}\`);
    const items = await page.locator('.item').allTextContents();
    results.push(...items);
  }
  return results;
}"
```
