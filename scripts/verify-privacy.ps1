param(
    [string] $SourceDir,
    [string] $PolicyPath,
    [string] $BrowserExe,
    [int] $RuntimeSeconds = 0,
    [string] $HostLogPath,
    [string] $AllowedHostsPath,
    [switch] $EnforceAllowList
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $RepoRoot 'scripts/lib/Astrid.psm1') -Force

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = Get-AstridDefaultSourceDir
}
if ([string]::IsNullOrWhiteSpace($BrowserExe)) {
    $BrowserExe = Get-AstridBrowserExecutable -SourceDir $SourceDir
}
if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
    if (-not [string]::IsNullOrWhiteSpace($BrowserExe)) {
        $runtimeDistribution = Install-AstridRuntimeDistribution -RepoRoot $RepoRoot -SourceDir $SourceDir -BrowserExe $BrowserExe
        $PolicyPath = $runtimeDistribution.PolicyPath
    } else {
        $PolicyPath = Join-Path $SourceDir 'distribution/policies.json'
    }
}
if ([string]::IsNullOrWhiteSpace($AllowedHostsPath)) {
    $AllowedHostsPath = Join-Path $RepoRoot 'config/allowed-startup-hosts.json'
}

$result = Test-AstridPolicies -PolicyPath $PolicyPath
if (-not $result.Passed) {
    Write-Host 'Static policy verification failed:'
    foreach ($failure in $result.Failures) {
        Write-Host " - $failure"
    }
    exit 1
}

Write-Host "Static policy verification passed for $PolicyPath"

if (-not [string]::IsNullOrWhiteSpace($BrowserExe)) {
    $browserDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($BrowserExe))
    $autoConfigResult = Test-AstridAutoConfig -BrowserDir $browserDir
    if (-not $autoConfigResult.Passed) {
        Write-Host 'AutoConfig verification failed:'
        foreach ($failure in $autoConfigResult.Failures) {
            Write-Host " - $failure"
        }
        exit 1
    }

    Write-Host "AutoConfig verification passed for $($autoConfigResult.ConfigPath)"
}

if ($RuntimeSeconds -le 0) {
    Write-Host 'Skipping runtime network verification because -RuntimeSeconds was not set.'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($BrowserExe) -or -not (Test-Path -LiteralPath $BrowserExe -PathType Leaf)) {
    throw 'Runtime verification requested, but no Astrid executable was found.'
}

if ([string]::IsNullOrWhiteSpace($HostLogPath)) {
    $HostLogPath = Join-Path ([System.IO.Path]::GetTempPath()) ("astrid-network-" + [System.Guid]::NewGuid().ToString('N') + '.log')
}

$profileDir = Join-Path ([System.IO.Path]::GetTempPath()) ("astrid-profile-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

$forbiddenPatterns = @(
    'telemetry\.mozilla\.org',
    'incoming\.telemetry\.mozilla\.org',
    'normandy\.cdn\.mozilla\.net',
    'shield\.mozilla\.org',
    'getpocket\.com',
    'pocket\.cdn\.mozilla\.net',
    'ads\.mozilla\.org',
    'contile\.services\.mozilla\.com',
    'quicksuggest\.services\.mozilla\.com'
)

try {
    $runtimeStartedAt = Get-Date
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $BrowserExe
    $psi.UseShellExecute = $false
    $psi.ArgumentList.Add('-no-remote') | Out-Null
    $psi.ArgumentList.Add('-profile') | Out-Null
    $psi.ArgumentList.Add($profileDir) | Out-Null
    $psi.ArgumentList.Add('about:blank') | Out-Null
    $psi.Environment['MOZ_LOG'] = 'timestamp,nsHttp:3'
    $psi.Environment['MOZ_LOG_FILE'] = $HostLogPath

    $process = [System.Diagnostics.Process]::Start($psi)
    Start-Sleep -Seconds $RuntimeSeconds
    if (-not $process.HasExited) {
        $process.CloseMainWindow() | Out-Null
        if (-not $process.WaitForExit(5000)) {
            $process.Kill()
            $process.WaitForExit()
        }
    }

    $createdLogFiles = @(Get-AstridMozLogFiles -HostLogPath $HostLogPath -IncludeEmpty)
    if ($createdLogFiles.Count -eq 0) {
        throw "Runtime verification did not create a network log for '$HostLogPath'."
    }

    $logFiles = @(Get-AstridMozLogFiles -HostLogPath $HostLogPath)
    $log = if ($logFiles.Count -gt 0) {
        ($logFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join [Environment]::NewLine
    } else {
        ''
    }
    foreach ($pattern in $forbiddenPatterns) {
        if ($log -match $pattern) {
            Write-Host "Forbidden startup network target matched pattern '$pattern'."
            exit 1
        }
    }

    if ($EnforceAllowList) {
        if (-not (Test-Path -LiteralPath $AllowedHostsPath -PathType Leaf)) {
            throw "Allow-list file '$AllowedHostsPath' does not exist."
        }

        $allowConfig = Get-Content -LiteralPath $AllowedHostsPath -Raw | ConvertFrom-Json
        $allowedHosts = @($allowConfig.allowed_hosts)
        $hostMatches = [regex]::Matches($log, 'https?://([A-Za-z0-9.-]+)')
        $seenHosts = @($hostMatches | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Sort-Object -Unique)
        $unexpected = @($seenHosts | Where-Object { $allowedHosts -notcontains $_ })
        if ($unexpected.Count -gt 0) {
            Write-Host 'Unexpected startup hosts:'
            foreach ($hostName in $unexpected) {
                Write-Host " - $hostName"
            }
            exit 1
        }
    }

    if ($logFiles.Count -gt 0) {
        Write-Host "Runtime network verification completed. Log: $($logFiles -join ', ')"
    } else {
        Write-Host "Runtime network verification completed with no HTTP log entries. Logs: $($createdLogFiles -join ', ')"
    }
} finally {
    if (-not [string]::IsNullOrWhiteSpace($BrowserExe)) {
        $browserFullPath = [System.IO.Path]::GetFullPath($BrowserExe)
        $verificationProcesses = @(Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($browserFullPath)) -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $browserFullPath -and $_.StartTime -ge $runtimeStartedAt })
        foreach ($verificationProcess in $verificationProcesses) {
            Stop-Process -Id $verificationProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
}
