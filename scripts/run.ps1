param(
    [string] $SourceDir,
    [string] $FirefoxExe,
    [string] $ProfileDir,
    [string] $Url = 'about:blank',
    [switch] $CleanProfile,
    [string[]] $AdditionalArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $RepoRoot 'scripts/lib/Astrid.psm1') -Force

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = Get-AstridDefaultSourceDir
}
if ([string]::IsNullOrWhiteSpace($ProfileDir)) {
    $ProfileDir = Join-Path $env:LOCALAPPDATA 'Astrid\dev-profile'
}
if ([string]::IsNullOrWhiteSpace($FirefoxExe)) {
    $FirefoxExe = Get-AstridFirefoxExecutable -SourceDir $SourceDir
}
if ([string]::IsNullOrWhiteSpace($FirefoxExe) -or -not (Test-Path -LiteralPath $FirefoxExe -PathType Leaf)) {
    throw "Could not find a built Astrid browser executable. Run scripts/build.ps1 first or pass -FirefoxExe."
}

$runtimeDistribution = Install-AstridRuntimeDistribution -RepoRoot $RepoRoot -SourceDir $SourceDir -BrowserExe $FirefoxExe

$profileFullPath = [System.IO.Path]::GetFullPath($ProfileDir)
$allowedProfileRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Astrid'))

if ($CleanProfile) {
    if (-not $profileFullPath.StartsWith($allowedProfileRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to delete profile path '$profileFullPath' because it is outside '$allowedProfileRoot'."
    }

    Remove-Item -LiteralPath $profileFullPath -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Path $profileFullPath -Force | Out-Null

$args = @(
    '-no-remote',
    '-profile',
    $profileFullPath,
    $Url
) + $AdditionalArgs

Write-Host "Launching Astrid from $FirefoxExe"
Write-Host "Policies: $($runtimeDistribution.PolicyPath)"
Write-Host "Profile: $profileFullPath"
Start-Process -FilePath $FirefoxExe -ArgumentList $args
