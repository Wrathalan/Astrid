param(
    [string] $SourceDir = '',
    [string] $BrowserExe = '',
    [string] $Version = '1.0.0',
    [string] $Repository = 'Wrathalan/Astrid',
    [string] $OutputDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $RepoRoot 'scripts/lib/Astrid.psm1') -Force

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = Get-AstridDefaultSourceDir
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $RepoRoot (Join-Path 'artifacts' "v$Version")
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($BrowserExe)) {
    $BrowserExe = Get-AstridFirefoxExecutable -SourceDir $SourceDir
}

if ([string]::IsNullOrWhiteSpace($BrowserExe) -or -not (Test-Path -LiteralPath $BrowserExe -PathType Leaf)) {
    throw "Could not find a built Astrid browser executable. Run scripts/build.ps1 first or pass -BrowserExe."
}

$runtimeDistribution = Install-AstridRuntimeDistribution -RepoRoot $RepoRoot -SourceDir $SourceDir -BrowserExe $BrowserExe
$browserDir = Split-Path -Parent $runtimeDistribution.BrowserExe
$commit = (& git -C $RepoRoot rev-parse --short HEAD).Trim()

$stagingDir = Join-Path $OutputDir 'staging'
$staged = New-AstridPackageStaging -RepoRoot $RepoRoot -BrowserDir $browserDir -Version $Version -Repository $Repository -StagingDir $stagingDir -Commit $commit

$packagePath = Join-Path $OutputDir (Get-AstridPackageAssetName -Version $Version)
if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
    Remove-Item -LiteralPath $packagePath -Force
}

Compress-Archive -Path (Join-Path $staged.AppDir '*') -DestinationPath $packagePath -CompressionLevel Optimal

$innoScriptPath = Join-Path $OutputDir 'Astrid.iss'
[void] (Save-AstridInnoSetupScript -Version $Version -StagingAppDir $staged.AppDir -OutputDir $OutputDir -ScriptPath $innoScriptPath)

$iscc = Get-AstridInnoSetupCompilerPath
& $iscc $innoScriptPath
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compiler failed with exit code $LASTEXITCODE."
}

$installerPath = Join-Path $OutputDir (Get-AstridInstallerAssetName -Version $Version)
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Expected installer was not created at '$installerPath'."
}

$manifestPath = Join-Path $OutputDir (Get-AstridReleaseManifestAssetName -Version $Version)
[void] (Save-AstridReleaseManifest -Version $Version -Repository $Repository -Commit $commit -PackagePath $packagePath -InstallerPath $installerPath -OutputPath $manifestPath)

Write-Host "Packaged Astrid $Version"
Write-Host "Package:  $packagePath"
Write-Host "Installer: $installerPath"
Write-Host "Manifest:  $manifestPath"

[pscustomobject]@{
    Version = $Version
    PackagePath = $packagePath
    InstallerPath = $installerPath
    ManifestPath = $manifestPath
    InnoScriptPath = $innoScriptPath
    StagingDir = $staged.StagingDir
}
