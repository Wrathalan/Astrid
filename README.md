# Astrid Firefox Fork

Astrid is a personal Windows desktop Firefox ESR fork focused on removing telemetry, browser advertising surfaces, and product callbacks while staying close enough to upstream ESR to keep security maintenance practical.

This repository is the orchestration repo. The Firefox source checkout should live outside this path because Mozilla's Windows build tooling is sensitive to spaces and shell-special characters in source paths.

Default source checkout:

```powershell
C:\mozilla-source\astrid-firefox
```

## What V1 Does

- Tracks Firefox ESR 140 via `https://hg.mozilla.org/releases/mozilla-esr140`.
- Generates a locked `distribution/policies.json` that disables telemetry, Firefox Studies, Normandy, Pocket, sponsored new-tab content, sponsored/online Firefox Suggest, crash upload, onboarding promos, snippets, and related product callbacks.
- Bundles uBlock Origin as a local, force-installed XPI.
- Allows uBlock filter lists to update automatically, while keeping extension package updates manual through `scripts/update-blocker.ps1`.
- Uses a small patch-stack workflow so Astrid can rebase onto ESR updates.

## Quick Start

Run commands from this repo root in PowerShell 7 or Windows PowerShell.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\update-blocker.ps1 -AcceptGpl3
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\run.ps1 -CleanProfile
```

If Mercurial or Python are missing, either install them manually or re-run bootstrap with:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap.ps1 -InstallPrerequisites
```

The first Firefox build can take a long time and requires Mozilla's Windows build prerequisites, including Visual Studio Build Tools and a supported Rust toolchain. `mach bootstrap` handles much of that setup.

## Verification

Static policy verification:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-privacy.ps1
```

Runtime startup network check after a build:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-privacy.ps1 -RuntimeSeconds 20
```

Strict allow-list mode is available for follow-up hardening:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-privacy.ps1 -RuntimeSeconds 20 -EnforceAllowList
```

## Patch Stack

Put source-level changes in `patches/*.patch`. `scripts/build.ps1` applies them in filename order with `hg import --no-commit`.

V1 intentionally keeps source patches minimal. Privacy and ad-removal defaults live in generated enterprise policy and locked preferences so Astrid can rebase onto Firefox ESR with less churn.

## Trademark Note

Astrid is a personal modified build and is not distributed as Mozilla Firefox. Before any public redistribution, review Mozilla's trademark policy and replace any Mozilla branding that a public derivative build cannot use.
