param(
    [string] $OutputDir,
    [string] $DownloadUrl = 'https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi',
    [switch] $AcceptGpl3,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $RepoRoot 'scripts/lib/Astrid.psm1') -Force

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $RepoRoot 'third_party/ublock'
}

if (-not $AcceptGpl3) {
    throw 'uBlock Origin is GPLv3-licensed. Re-run with -AcceptGpl3 after reviewing the license and redistribution obligations.'
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$xpiPath = Join-Path $OutputDir 'ublock-origin.firefox.signed.xpi'
$metadataPath = Join-Path $OutputDir 'metadata.json'
$licensePath = Join-Path $OutputDir 'LICENSE.txt'

if ((Test-Path -LiteralPath $xpiPath -PathType Leaf) -and -not $Force) {
    throw "XPI already exists at '$xpiPath'. Use -Force to replace it."
}

$tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ublock-origin-" + [System.Guid]::NewGuid().ToString('N') + '.xpi')

try {
    Write-Host "Downloading uBlock Origin from $DownloadUrl"
    $response = Invoke-WebRequest -Uri $DownloadUrl -MaximumRedirection 10 -OutFile $tempPath -PassThru

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($tempPath)
    try {
        $manifestEntry = $zip.Entries | Where-Object { $_.FullName -eq 'manifest.json' } | Select-Object -First 1
        if ($null -eq $manifestEntry) {
            throw 'Downloaded XPI does not contain manifest.json.'
        }

        $reader = [System.IO.StreamReader]::new($manifestEntry.Open())
        try {
            $manifest = $reader.ReadToEnd() | ConvertFrom-Json
        } finally {
            $reader.Dispose()
        }
    } finally {
        $zip.Dispose()
    }

    $extensionId = $manifest.browser_specific_settings.gecko.id
    if ($extensionId -ne 'uBlock0@raymondhill.net') {
        throw "Downloaded XPI has unexpected Firefox extension id '$extensionId'."
    }

    $hash = (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Move-Item -LiteralPath $tempPath -Destination $xpiPath -Force

    try {
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/gorhill/uBlock/master/LICENSE.txt' -MaximumRedirection 5 -OutFile $licensePath
    } catch {
        Write-Warning "Could not download uBlock Origin license text: $($_.Exception.Message)"
    }

    $finalUrl = Get-AstridResponseUri -Response $response -DefaultUri $DownloadUrl

    $metadata = [ordered]@{
        name = 'uBlock Origin'
        extension_id = $extensionId
        version = $manifest.version
        source_url = $DownloadUrl
        downloaded_url = $finalUrl
        sha256 = $hash
        license = 'GPL-3.0-only'
        package_updates = 'manual via scripts/update-blocker.ps1'
        filter_list_updates = 'automatic inside the extension'
        downloaded_at_utc = [DateTime]::UtcNow.ToString('o')
    }

    Set-Content -LiteralPath $metadataPath -Value (($metadata | ConvertTo-Json -Depth 8) + [Environment]::NewLine) -Encoding UTF8
    Write-Host "Saved signed uBlock Origin XPI to $xpiPath"
    Write-Host "SHA256: $hash"
} finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
}
