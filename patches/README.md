# Astrid Patch Stack

Place Astrid source patches in this directory as `NNN-description.patch`.

`scripts/build.ps1` applies patches in filename order with:

```powershell
hg import --no-commit patches\NNN-description.patch
```

Keep patches small and ESR-focused. V1 uses generated distribution policies and `.mozconfig` settings first; source patches should be added only when a privacy or branding requirement cannot be handled safely through configuration.
