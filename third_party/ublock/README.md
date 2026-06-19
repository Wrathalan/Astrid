# uBlock Origin Bundle

Run the update script to download and pin the signed Firefox XPI:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\update-blocker.ps1 -AcceptGpl3
```

Generated files:

- `ublock-origin.firefox.signed.xpi`
- `metadata.json`
- `LICENSE.txt`

Astrid force-installs the local XPI through enterprise `ExtensionSettings`. The extension package is updated manually with `scripts/update-blocker.ps1`; filter lists update automatically inside uBlock Origin.
