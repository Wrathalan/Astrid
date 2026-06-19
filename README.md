# Astrid Browser

Astrid is a personal Windows desktop browser fork focused on removing telemetry, browser advertising surfaces, account hooks, and product callbacks while staying close enough to upstream ESR to keep security maintenance practical.

This repository is the orchestration repo. The upstream source checkout should live outside this path because the Windows build tooling is sensitive to spaces and shell-special characters in source paths.

Default source checkout:

```powershell
C:\mozilla-source\astrid-browser
```

## What V1 Does

- Tracks upstream ESR 140 via `https://hg.mozilla.org/releases/mozilla-esr140`.
- Generates a locked `distribution/policies.json` that disables telemetry, account and sync integration, studies, Normandy, Pocket, sponsored new-tab content, sponsored/online address-bar suggestions, crash upload, onboarding promos, snippets, and related product callbacks.
- Installs a local Astrid start page with the project mission statement and locks startup to that page.
- Bundles uBlock Origin as a local, force-installed XPI.
- Allows uBlock filter lists to update automatically, while keeping extension package updates manual through `scripts/update-blocker.ps1`.
- Builds a per-user Windows installer and updater package for v1 releases.
- Installs a manual updater that checks GitHub Releases only when launched.
- Uses tracked iconography from `assets/` for the installer, uninstall entry, and Windows shortcuts.
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

The first Astrid build can take a long time and requires the upstream Windows build prerequisites, including Visual Studio Build Tools and a supported Rust toolchain. `mach bootstrap` handles much of that setup.

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

## Packaging And Updates

Build the v1 release assets after `scripts/build.ps1` has produced a runnable browser:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\package.ps1 -Version 1.0.0
```

This writes:

- `AstridSetup-1.0.0-win64.exe`: per-user installer for `%LOCALAPPDATA%\Programs\Astrid`.
- `Astrid-1.0.0-win64.zip`: updater payload.
- `Astrid-1.0.0-release.json`: release manifest with SHA-256 hashes.

The package step copies the tracked iconography from `assets/` and generates `assets\astrid.ico` inside the staged app for Inno Setup and Windows shortcuts.

Publish those assets to GitHub Releases:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\publish-release.ps1 -Version 1.0.0
```

Installed builds include `AstridUpdateCheck.cmd`. Running it checks `https://api.github.com/repos/Wrathalan/Astrid/releases/latest`, downloads the release manifest and ZIP package, verifies the package SHA-256, and mirrors the verified files into the install directory. V1 does not run background update checks.

## Patch Stack

Put source-level changes in `patches/*.patch`. `scripts/build.ps1` applies them in filename order with `hg import --no-commit`.

V1 intentionally keeps source patches minimal. Privacy and ad-removal defaults live in generated enterprise policy and locked preferences so Astrid can rebase onto upstream ESR with less churn.

## Trademark Note

Astrid is a personal modified build and is not an upstream-branded product. Before any public redistribution, review the upstream trademark policy and replace any branding that a public derivative build cannot use.
