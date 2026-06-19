param(
    [string] $SourceDir,
    [string] $EsrRepo,
    [switch] $InstallPrerequisites,
    [switch] $SkipClone,
    [switch] $SkipMachBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $RepoRoot 'scripts/lib/Astrid.psm1') -Force

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = Get-AstridDefaultSourceDir
}
if ([string]::IsNullOrWhiteSpace($EsrRepo)) {
    $EsrRepo = Get-AstridDefaultEsrRepo
}

$SourceDir = Assert-AstridSafeSourcePath -Path $SourceDir

function Install-WithWinget {
    param(
        [Parameter(Mandatory)]
        [string] $PackageId
    )

    if ($null -eq (Get-Command 'winget' -ErrorAction SilentlyContinue)) {
        throw "winget is not available, so '$PackageId' cannot be installed automatically."
    }

    & winget install --id $PackageId --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install '$PackageId'."
    }
}

$hgPath = $null
try {
    $hgPath = Get-AstridMercurialPath
} catch {
    if ($InstallPrerequisites) {
        Install-WithWinget -PackageId 'Mercurial.Mercurial'
    } else {
        throw 'Mercurial (hg) is required to clone Firefox ESR. Re-run with -InstallPrerequisites or install Mercurial manually.'
    }
}

if ($null -eq $hgPath) {
    $hgPath = Get-AstridMercurialPath
}

$pythonPath = $null
try {
    $pythonPath = Get-AstridPythonPath
} catch {
    if ($InstallPrerequisites) {
        Install-WithWinget -PackageId 'Python.Python.3.12'
    } else {
        throw "Python 3.12 or lower is required for mach/bootstrap. Re-run with -InstallPrerequisites or install Python 3.12 manually. $($_.Exception.Message)"
    }
}

if ($null -eq $pythonPath) {
    $pythonPath = Get-AstridPythonPath
}

if (-not $SkipClone) {
    if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
        $parent = Split-Path -Parent $SourceDir
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Write-Host "Cloning Firefox ESR from $EsrRepo into $SourceDir"
        & $hgPath clone $EsrRepo $SourceDir
        if ($LASTEXITCODE -ne 0) {
            throw "Mercurial clone failed for '$EsrRepo'."
        }
    } elseif (Test-Path -LiteralPath (Join-Path $SourceDir '.hg') -PathType Container) {
        Write-Host "Updating existing Firefox ESR checkout at $SourceDir"
        & $hgPath --cwd $SourceDir pull -u
        if ($LASTEXITCODE -ne 0) {
            throw "Mercurial pull/update failed for '$SourceDir'."
        }
    } else {
        throw "SourceDir '$SourceDir' already exists but is not a Mercurial checkout."
    }
}

$machPath = Join-Path $SourceDir 'mach'
if (-not $SkipMachBootstrap) {
    if (-not (Test-Path -LiteralPath $machPath -PathType Leaf)) {
        throw "Could not find mach at '$machPath'. Clone the Firefox source first."
    }

    Write-Host 'Running Firefox mach bootstrap for a browser build.'
    Push-Location -LiteralPath $SourceDir
    try {
        Initialize-AstridMozillaBuildEnvironment
        $hgDir = Split-Path -Parent $hgPath
        if ($env:Path -notlike "*$hgDir*") {
            $env:Path = "$hgDir;$env:Path"
        }
        & $pythonPath $machPath --no-interactive bootstrap --application-choice browser
        if ($LASTEXITCODE -ne 0) {
            throw 'mach bootstrap failed.'
        }
    } finally {
        Pop-Location
    }
}

Write-Host "Astrid bootstrap complete. Firefox source: $SourceDir"
