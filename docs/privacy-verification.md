# Astrid Privacy Verification

Astrid has two verification layers.

## Static Policy Verification

`scripts/verify-privacy.ps1` reads `distribution/policies.json` and fails if required telemetry, sponsored-content, experiment, Pocket, crash-upload, or uBlock settings are absent or unlocked.

Run it after `scripts/build.ps1` installs the distribution overlay:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-privacy.ps1
```

## Runtime Startup Verification

Runtime verification launches a built Astrid binary with a temporary profile, enables Mozilla networking logs, waits for a fixed number of seconds, and scans the log for forbidden product-callback endpoints.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-privacy.ps1 -RuntimeSeconds 20
```

Use `-EnforceAllowList` only after checking the current Firefox ESR startup behavior, because security-service and filter-list hosts can shift over time.

## Manual Browser Checks

After launch:

- `about:policies` should show active policies with no errors.
- `about:addons` should show uBlock Origin installed and locked.
- New tab should not show sponsored shortcuts, Pocket stories, or snippets.
- Address bar suggestions should not include Firefox Suggest sponsored or online results.
- Crash reporting controls should be disabled or locked off.
