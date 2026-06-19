param(
    [string] $InstallDirectory = $PSScriptRoot,
    [string] $Repository = '',
    [switch] $CheckOnly,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-InstalledAstridVersion {
    param(
        [Parameter(Mandatory)]
        [string] $InstallDirectory
    )

    $versionPath = Join-Path $InstallDirectory 'astrid-version.json'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        return [pscustomobject]@{
            version = '0.0.0'
            repository = 'Wrathalan/Astrid'
            path = $versionPath
        }
    }

    $info = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
    return [pscustomobject]@{
        version = [string] $info.version
        repository = [string] $info.repository
        path = $versionPath
    }
}

function Invoke-GitHubJson {
    param(
        [Parameter(Mandatory)]
        [string] $Uri
    )

    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'Astrid-Updater'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    return Invoke-RestMethod -Uri $Uri -Headers $headers
}

function Save-GitHubAsset {
    param(
        [Parameter(Mandatory)]
        [string] $Uri,
        [Parameter(Mandatory)]
        [string] $OutputPath
    )

    $headers = @{
        Accept = 'application/octet-stream'
        'User-Agent' = 'Astrid-Updater'
    }

    Invoke-WebRequest -Uri $Uri -Headers $headers -OutFile $OutputPath
    return $OutputPath
}

function ConvertTo-VersionOrZero {
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    try {
        return [version] $Value.TrimStart('v')
    } catch {
        return [version] '0.0.0'
    }
}

$installFullPath = [System.IO.Path]::GetFullPath($InstallDirectory)
if (-not (Test-Path -LiteralPath (Join-Path $installFullPath 'astrid.exe') -PathType Leaf)) {
    throw "Install directory '$installFullPath' does not contain astrid.exe."
}

$installed = Read-InstalledAstridVersion -InstallDirectory $installFullPath
if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = if ([string]::IsNullOrWhiteSpace($installed.repository)) { 'Wrathalan/Astrid' } else { $installed.repository }
}

$latestReleaseUri = "https://api.github.com/repos/$Repository/releases/latest"
Write-Host "Checking $latestReleaseUri"
$release = Invoke-GitHubJson -Uri $latestReleaseUri

$manifestAsset = @($release.assets | Where-Object { $_.name -like 'Astrid-*-release.json' } | Sort-Object name -Descending | Select-Object -First 1)
if ($manifestAsset.Count -eq 0) {
    throw "Latest release '$($release.tag_name)' does not include an Astrid release manifest asset."
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("astrid-update-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $manifestPath = Join-Path $tempRoot $manifestAsset[0].name
    [void] (Save-GitHubAsset -Uri $manifestAsset[0].browser_download_url -OutputPath $manifestPath)
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    $currentVersion = ConvertTo-VersionOrZero -Value $installed.version
    $latestVersion = ConvertTo-VersionOrZero -Value ([string] $manifest.version)
    if (-not $Force -and $latestVersion -le $currentVersion) {
        Write-Host "Astrid is up to date: $($installed.version)"
        return
    }

    Write-Host "Astrid update available: $($installed.version) -> $($manifest.version)"
    if ($CheckOnly) {
        return
    }

    $runningAstrid = @(Get-Process -Name 'astrid' -ErrorAction SilentlyContinue)
    if ($runningAstrid.Count -gt 0 -and -not $Force) {
        throw 'Close Astrid before updating, then run AstridUpdateCheck.cmd again.'
    }

    $packageAssetName = [string] $manifest.package.asset
    $packageAsset = @($release.assets | Where-Object { $_.name -eq $packageAssetName })
    if ($packageAsset.Count -eq 0) {
        throw "Latest release '$($release.tag_name)' does not include package asset '$packageAssetName'."
    }

    $packagePath = Join-Path $tempRoot $packageAssetName
    [void] (Save-GitHubAsset -Uri $packageAsset[0].browser_download_url -OutputPath $packagePath)

    $actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedHash = ([string] $manifest.package.sha256).ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "Downloaded package hash mismatch. Expected $expectedHash, got $actualHash."
    }

    $extractDir = Join-Path $tempRoot 'package'
    Expand-Archive -LiteralPath $packagePath -DestinationPath $extractDir -Force
    if (-not (Test-Path -LiteralPath (Join-Path $extractDir 'astrid.exe') -PathType Leaf)) {
        throw "Downloaded package '$packageAssetName' did not contain astrid.exe at its root."
    }

    $robocopyArgs = @($extractDir, $installFullPath, '/MIR', '/R:2', '/W:1')
    & robocopy @robocopyArgs | Out-Host
    $robocopyExit = $LASTEXITCODE
    if ($robocopyExit -gt 7) {
        throw "robocopy failed with exit code $robocopyExit."
    }

    Write-Host "Astrid updated to $($manifest.version)."
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
