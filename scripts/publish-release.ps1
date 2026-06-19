param(
    [string] $Version = '1.0.0',
    [string] $Repository = 'Wrathalan/Astrid',
    [string] $ArtifactsDir = '',
    [switch] $Draft,
    [switch] $Prerelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $RepoRoot 'scripts/lib/Astrid.psm1') -Force

if ([string]::IsNullOrWhiteSpace($ArtifactsDir)) {
    $ArtifactsDir = Join-Path $RepoRoot (Join-Path 'artifacts' "v$Version")
}

$packagePath = Join-Path $ArtifactsDir (Get-AstridPackageAssetName -Version $Version)
$installerPath = Join-Path $ArtifactsDir (Get-AstridInstallerAssetName -Version $Version)
$manifestPath = Join-Path $ArtifactsDir (Get-AstridReleaseManifestAssetName -Version $Version)
foreach ($path in @($packagePath, $installerPath, $manifestPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing release asset '$path'. Run scripts/package.ps1 first."
    }
}

& gh auth status | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI is not authenticated.'
}

$tagName = "v$Version"
$existingRelease = & gh release view $tagName --repo $Repository --json tagName 2>$null
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingRelease)) {
    throw "Release '$tagName' already exists in $Repository."
}

$existingTag = & git -C $RepoRoot tag --list $tagName
if ([string]::IsNullOrWhiteSpace($existingTag)) {
    & git -C $RepoRoot tag -a $tagName -m "Astrid $Version"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create git tag '$tagName'."
    }
}

& git -C $RepoRoot push origin $tagName
if ($LASTEXITCODE -ne 0) {
    throw "Could not push git tag '$tagName'."
}

$notesPath = Join-Path $ArtifactsDir "release-notes-$Version.md"
$notes = @(
    "# Astrid $Version",
    '',
    'Personal Windows Firefox ESR fork package with Astrid privacy policy defaults, locked telemetry/product-callback preferences, bundled uBlock Origin, and a manual GitHub Releases updater.',
    '',
    'Assets:',
    "- $(Split-Path -Leaf $installerPath): per-user installer",
    "- $(Split-Path -Leaf $packagePath): updater package ZIP",
    "- $(Split-Path -Leaf $manifestPath): hashes and updater metadata",
    '',
    'V1 updater behavior: Astrid does not perform background update checks. Run "Check for Astrid Updates" from the Start menu to check GitHub Releases manually.'
)
Set-Content -LiteralPath $notesPath -Value $notes -Encoding UTF8

$args = @(
    'release', 'create', $tagName,
    $installerPath,
    $packagePath,
    $manifestPath,
    '--repo', $Repository,
    '--title', "Astrid $Version",
    '--notes-file', $notesPath
)
if ($Draft) {
    $args += '--draft'
}
if ($Prerelease) {
    $args += '--prerelease'
}

& gh @args
if ($LASTEXITCODE -ne 0) {
    throw "Could not create GitHub release '$tagName'."
}

Write-Host "Published $Repository release $tagName."
