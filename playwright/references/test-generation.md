# Test generation

Generate Playwright test code automatically while interacting with the browser.

## How it works

Every action you run with `playwright-cli` generates the corresponding Playwright TypeScript code.
The code is shown in the output and can be copied straight into a test file.

## Example workflow

```bash
# Start a session
playwright-cli open https://example.com/login

# Take a snapshot to identify the elements
playwright-cli snapshot
# Example output: e1 [textbox "Email"], e2 [textbox "Password"], e3 [button "Sign In"]

# Fill the form fields - the code is generated automatically
playwright-cli fill e1 "user@example.com"
# Playwright code that was run:
# await page.getByRole('textbox', { name: 'Email' }).fill('user@example.com');

playwright-cli fill e2 "password123"
# Playwright code that was run:
# await page.getByRole('textbox', { name: 'Password' }).fill('password123');

playwright-cli click e3
# Playwright code that was run:
# await page.getByRole('button', { name: 'Sign In' }).click();
```

## Building the test file

Collect the generated code into a Playwright test:

```typescript
import { test, expect } from '@playwright/test';

test('login flow', async ({ page }) => {
  // Code generated from the playwright-cli session:
  await page.goto('https://example.com/login');
  await page.getByRole('textbox', { name: 'Email' }).fill('user@example.com');
  await page.getByRole('textbox', { name: 'Password' }).fill('password123');
  await page.getByRole('button', { name: 'Sign In' }).click();

  // Add assertions
  await expect(page).toHaveURL(/.*dashboard/);
});
```

## Best practices

### 1. Use semantic locators

The generated code uses role-based locators wherever possible, which break less often:

```typescript
// Generated (good - semantic)
await page.getByRole('button', { name: 'Submit' }).click();

// Avoid (brittle - CSS selector)
await page.locator('#submit-btn').click();
```

### 2. Explore before recording

Before recording actions, take a snapshot to understand the page structure:

```bash
playwright-cli open https://example.com
playwright-cli snapshot
# Inspect the element structure
playwright-cli click e5
```

### 3. Add assertions manually

The generated code captures actions but not assertions. Add expectations to your tests yourself:

```typescript
// Generated action
await page.getByRole('button', { name: 'Submit' }).click();

// Manual assertion
await expect(page.getByText('Success')).toBeVisible();
```
