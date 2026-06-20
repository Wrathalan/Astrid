param(
    [string] $SourceDir,
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [switch] $SkipPatches,
    [switch] $NoBuild,
    [switch] $AllowMissingBlocker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $RepoRoot 'scripts/lib/Astrid.psm1') -Force

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = Get-AstridDefaultSourceDir
}

$SourceDir = Assert-AstridSafeSourcePath -Path $SourceDir
if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    throw "Source directory '$SourceDir' does not exist. Run scripts/bootstrap.ps1 first."
}

$blockerXpi = Join-Path $RepoRoot 'third_party/ublock/ublock-origin.signed.xpi'
if (-not $AllowMissingBlocker -and -not (Test-Path -LiteralPath $blockerXpi -PathType Leaf)) {
    throw "Missing bundled uBlock Origin XPI at '$blockerXpi'. Run scripts/update-blocker.ps1 -AcceptGpl3 before building, or use -AllowMissingBlocker for policy-only testing."
}

$distribution = Install-AstridDistribution -RepoRoot $RepoRoot -SourceDir $SourceDir
Write-Host "Installed Astrid policies to $($distribution.PolicyPath)"

$sourceBranding = Install-AstridSourceBranding -RepoRoot $RepoRoot -SourceDir $SourceDir
Write-Host "Installed Astrid source branding to $($sourceBranding.BrandingDir)"

$mozconfigPath = Write-AstridMozConfig -SourceDir $SourceDir -Configuration $Configuration
Write-Host "Wrote Astrid mozconfig to $mozconfigPath"

if (-not $SkipPatches) {
    $applied = @(Invoke-AstridPatches -RepoRoot $RepoRoot -SourceDir $SourceDir)
    if ($applied.Count -gt 0) {
        Write-Host "Applied Astrid patches: $($applied -join ', ')"
    } else {
        Write-Host 'No Astrid source patches are present yet; using mozconfig and distribution overlay only.'
    }
}

if ($NoBuild) {
    $existingBrowserExe = Get-AstridBrowserExecutable -SourceDir $SourceDir
    if (-not [string]::IsNullOrWhiteSpace($existingBrowserExe)) {
        $runtimeDistribution = Install-AstridRuntimeDistribution -RepoRoot $RepoRoot -SourceDir $SourceDir -BrowserExe $existingBrowserExe
        Write-Host "Installed Astrid runtime policies to $($runtimeDistribution.PolicyPath)"
    }

    Write-Host 'Skipping mach build because -NoBuild was provided.'
    exit 0
}

$machPath = Join-Path $SourceDir 'mach'
if (-not (Test-Path -LiteralPath $machPath -PathType Leaf)) {
    throw "Could not find mach at '$machPath'. Run scripts/bootstrap.ps1 first."
}

$pythonPath = Get-AstridPythonPath
$hgPath = Get-AstridMercurialPath

Write-Host 'Starting Astrid build. This can take a long time on first run.'
Push-Location -LiteralPath $SourceDir
try {
    Initialize-AstridMozillaBuildEnvironment
    $hgDir = Split-Path -Parent $hgPath
    if ($env:Path -notlike "*$hgDir*") {
        $env:Path = "$hgDir;$env:Path"
    }
    & $pythonPath $machPath build
    if ($LASTEXITCODE -ne 0) {
        throw 'mach build failed.'
    }
} finally {
    Pop-Location
}

$runtimeDistribution = Install-AstridRuntimeDistribution -RepoRoot $RepoRoot -SourceDir $SourceDir
Write-Host "Installed Astrid runtime policies to $($runtimeDistribution.PolicyPath)"
Write-Host 'Astrid build complete.'
