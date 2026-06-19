Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ModulePath = Join-Path $RepoRoot 'scripts/lib/Astrid.psm1'

Import-Module $ModulePath -Force

$script:Failures = 0

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,
        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        $Actual,
        [Parameter(Mandatory)]
        $Expected,
        [Parameter(Mandatory)]
        [string] $Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock,
        [Parameter(Mandatory)]
        [string] $Message
    )

    $threw = $false
    try {
        & $ScriptBlock
    } catch {
        $threw = $true
    }

    if (-not $threw) {
        throw $Message
    }
}

function Invoke-Test {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [scriptblock] $Body
    )

    try {
        & $Body
        Write-Host "[PASS] $Name"
    } catch {
        $script:Failures++
        Write-Host "[FAIL] $Name"
        Write-Host "       $($_.Exception.Message)"
    }
}

Invoke-Test 'safe source path validation rejects workspace paths with spaces or apostrophes' {
    Assert-Throws {
        Assert-AstridSafeSourcePath -Path $RepoRoot
    } 'Expected the current workspace path to be rejected for Firefox source checkout use.'

    [void] (Assert-AstridSafeSourcePath -Path 'C:\mozilla-source\astrid-firefox')
}

Invoke-Test 'policy generation disables telemetry, studies, Pocket, sponsored surfaces, and crash upload' {
    $policy = New-AstridPolicies -RepoRoot $RepoRoot
    $prefs = $policy.policies.Preferences
    $autoConfigPrefs = New-AstridAutoConfigPreferences

    Assert-Equal $policy.policies.DisableTelemetry $true 'DisableTelemetry must be enabled.'
    Assert-Equal $policy.policies.DisableFirefoxStudies $true 'Firefox Studies must be disabled.'
    Assert-Equal $policy.policies.DisablePocket $true 'Pocket must be disabled.'
    Assert-Equal $prefs.'datareporting.policy.dataSubmissionEnabled'.Value $false 'Data submission must be disabled.'
    Assert-Equal $autoConfigPrefs.'toolkit.telemetry.enabled' $false 'Telemetry must be disabled through AutoConfig.'
    Assert-Equal $autoConfigPrefs.'app.normandy.enabled' $false 'Normandy must be disabled through AutoConfig.'
    Assert-Equal $prefs.'browser.newtabpage.activity-stream.showSponsoredTopSites'.Value $false 'Sponsored top sites must be disabled.'
    Assert-Equal $prefs.'browser.urlbar.suggest.quicksuggest.sponsored'.Value $false 'Sponsored Firefox Suggest results must be disabled.'
    Assert-Equal $prefs.'browser.tabs.crashReporting.sendReport'.Value $false 'Crash report submission must be disabled.'
}

Invoke-Test 'uBlock Origin is force installed from a local pinned XPI and extension package updates are disabled' {
    $policy = New-AstridPolicies -RepoRoot $RepoRoot
    $ubo = $policy.policies.ExtensionSettings.'uBlock0@raymondhill.net'

    Assert-Equal $ubo.installation_mode 'force_installed' 'uBlock Origin must be force installed.'
    Assert-True ($ubo.install_url -like 'file:///*/third_party/ublock/ublock-origin.firefox.signed.xpi') 'uBlock Origin install_url must point at the local pinned XPI.'
    Assert-Equal $ubo.updates_disabled $true 'The uBlock Origin extension package must not auto-update from AMO.'
}

Invoke-Test 'uBlock Origin managed settings keep filter list auto updates enabled' {
    $policy = New-AstridPolicies -RepoRoot $RepoRoot
    $settingsJson = $policy.policies.'3rdparty'.Extensions.'uBlock0@raymondhill.net'.adminSettings
    $settings = $settingsJson | ConvertFrom-Json

    Assert-Equal $settings.userSettings.autoUpdate $true 'uBlock filter list auto updates must stay enabled.'
    Assert-True ($settings.selectedFilterLists -contains 'easylist') 'EasyList must be enabled.'
    Assert-True ($settings.selectedFilterLists -contains 'easyprivacy') 'EasyPrivacy must be enabled.'
}

Invoke-Test 'policies can be written, reloaded, and statically verified' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("astrid-tests-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        $policyPath = Join-Path $tempRoot 'policies.json'
        [void] (Save-AstridPolicies -RepoRoot $RepoRoot -OutputPath $policyPath)

        $loaded = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
        Assert-Equal $loaded.policies.DisableTelemetry $true 'Saved policies.json must be valid JSON with policies at the root.'

        $result = Test-AstridPolicies -PolicyPath $policyPath
        Assert-Equal $result.Passed $true 'Static policy verification must pass for generated policies.'
        Assert-Equal $result.Failures.Count 0 'Generated policies must have no verification failures.'
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'web response URI helper handles modern HttpResponseMessage shape' {
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, [System.Uri]::new('https://example.test/final.xpi'))
    $baseResponse = [System.Net.Http.HttpResponseMessage]::new()
    $baseResponse.RequestMessage = $request
    $response = [pscustomobject]@{
        BaseResponse = $baseResponse
    }

    $finalUri = Get-AstridResponseUri -Response $response -DefaultUri 'https://example.test/latest.xpi'
    Assert-Equal $finalUri 'https://example.test/final.xpi' 'Final response URI must use RequestMessage.RequestUri when ResponseUri is unavailable.'
}

Invoke-Test 'command resolver falls back to known executable paths' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("astrid-command-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        $fakeExe = Join-Path $tempRoot 'tool.exe'
        Set-Content -LiteralPath $fakeExe -Value '' -Encoding Ascii

        $resolved = Resolve-AstridCommandPath -Name 'definitely-not-on-path-astrid-test' -KnownPaths @($fakeExe)
        Assert-Equal $resolved $fakeExe 'Resolver must return a known path when PATH lookup fails.'
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'Python resolver selects a Mach-compatible Python when one is available' {
    $pythonPath = Get-AstridPythonPath
    Assert-True (Test-Path -LiteralPath $pythonPath -PathType Leaf) 'Python resolver must return an existing executable.'

    $versionJson = & $pythonPath -c 'import json, sys; print(json.dumps({"major": sys.version_info.major, "minor": sys.version_info.minor}))'
    $version = $versionJson | ConvertFrom-Json

    Assert-Equal $version.major 3 'Mach-compatible Python must be Python 3.'
    Assert-True ($version.minor -le 12) 'Mach-compatible Python must be 3.12 or lower.'
}

Invoke-Test 'browser executable resolver prefers branded Astrid binaries' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("astrid-exe-" + [System.Guid]::NewGuid().ToString('N'))
    $binDir = Join-Path $tempRoot 'obj-astrid\dist\bin'
    New-Item -ItemType Directory -Path $binDir | Out-Null
    try {
        $astridExe = Join-Path $binDir 'astrid.exe'
        $firefoxExe = Join-Path $binDir 'firefox.exe'
        Set-Content -LiteralPath $astridExe -Value '' -Encoding Ascii
        Set-Content -LiteralPath $firefoxExe -Value '' -Encoding Ascii

        $resolved = Get-AstridFirefoxExecutable -SourceDir $tempRoot
        Assert-Equal $resolved $astridExe 'Executable resolver must prefer astrid.exe over the compatibility fallback.'
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'runtime distribution writes policies next to the browser executable' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("astrid-runtime-" + [System.Guid]::NewGuid().ToString('N'))
    $binDir = Join-Path $tempRoot 'obj-astrid\dist\bin'
    New-Item -ItemType Directory -Path $binDir | Out-Null
    try {
        $astridExe = Join-Path $binDir 'astrid.exe'
        Set-Content -LiteralPath $astridExe -Value '' -Encoding Ascii

        $runtimeDistribution = Install-AstridRuntimeDistribution -RepoRoot $RepoRoot -BrowserExe $astridExe
        Assert-Equal $runtimeDistribution.DistributionDir (Join-Path $binDir 'distribution') 'Runtime distribution must live beside the browser executable.'
        Assert-True (Test-Path -LiteralPath $runtimeDistribution.PolicyPath -PathType Leaf) 'Runtime policies.json must be written.'

        $result = Test-AstridPolicies -PolicyPath $runtimeDistribution.PolicyPath
        Assert-Equal $result.Passed $true 'Runtime policies must pass static verification.'
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'enterprise policy preferences omit Firefox policy-blocked internal prefs' {
    $policy = New-AstridPolicies -RepoRoot $RepoRoot
    $policyPrefs = @($policy.policies.Preferences.Keys)
    $blockedByFirefoxPolicy = @(
        'app.normandy.enabled',
        'app.normandy.api_url',
        'app.shield.optoutstudies.enabled',
        'breakpad.reportURL',
        'datareporting.healthreport.infoURL',
        'datareporting.healthreport.uploadEnabled',
        'datareporting.sessions.current.clean',
        'toolkit.coverage.endpoint.base',
        'toolkit.coverage.opt-out',
        'toolkit.telemetry.archive.enabled',
        'toolkit.telemetry.bhrPing.enabled',
        'toolkit.telemetry.coverage.opt-out',
        'toolkit.telemetry.enabled',
        'toolkit.telemetry.firstShutdownPing.enabled',
        'toolkit.telemetry.newProfilePing.enabled',
        'toolkit.telemetry.reportingpolicy.firstRun',
        'toolkit.telemetry.server',
        'toolkit.telemetry.shutdownPingSender.enabled',
        'toolkit.telemetry.unified',
        'toolkit.telemetry.updatePing.enabled'
    )

    foreach ($prefName in $blockedByFirefoxPolicy) {
        Assert-True ($policyPrefs -notcontains $prefName) "Policy Preferences must not contain Firefox-blocked pref '$prefName'."
    }
}

Invoke-Test 'runtime distribution writes AutoConfig locks for internal privacy prefs' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("astrid-autoconfig-" + [System.Guid]::NewGuid().ToString('N'))
    $binDir = Join-Path $tempRoot 'obj-astrid\dist\bin'
    New-Item -ItemType Directory -Path $binDir | Out-Null
    try {
        $astridExe = Join-Path $binDir 'astrid.exe'
        Set-Content -LiteralPath $astridExe -Value '' -Encoding Ascii

        [void] (Install-AstridRuntimeDistribution -RepoRoot $RepoRoot -BrowserExe $astridExe)
        $defaultsPref = Join-Path $binDir 'defaults\pref\astrid-autoconfig.js'
        $privacyDefaultsPref = Join-Path $binDir 'defaults\pref\astrid-privacy.js'
        $appPrivacyDefaultsPref = Join-Path $binDir 'defaults\preferences\astrid-privacy.js'
        $configFile = Join-Path $binDir 'astrid.cfg'

        Assert-True (Test-Path -LiteralPath $defaultsPref -PathType Leaf) 'AutoConfig defaults/pref file must be written next to the runtime.'
        Assert-True (Test-Path -LiteralPath $privacyDefaultsPref -PathType Leaf) 'Privacy defaults/pref file must be written next to the runtime.'
        Assert-True (Test-Path -LiteralPath $appPrivacyDefaultsPref -PathType Leaf) 'Privacy defaults/preferences file must be written next to the runtime.'
        Assert-True (Test-Path -LiteralPath $configFile -PathType Leaf) 'AutoConfig lock file must be written next to the runtime.'

        $defaultsText = Get-Content -LiteralPath $defaultsPref -Raw
        $privacyDefaultsText = Get-Content -LiteralPath $privacyDefaultsPref -Raw
        $appPrivacyDefaultsText = Get-Content -LiteralPath $appPrivacyDefaultsPref -Raw
        $configText = Get-Content -LiteralPath $configFile -Raw
        Assert-True ($defaultsText -match 'general\.config\.filename') 'AutoConfig defaults must point Firefox at astrid.cfg.'
        Assert-True ($privacyDefaultsText.Contains('pref("app.shield.optoutstudies.enabled", false);')) 'Privacy defaults must disable studies before Nimbus startup.'
        Assert-True ($appPrivacyDefaultsText.Contains('pref("app.shield.optoutstudies.enabled", false);')) 'App privacy defaults must override Firefox bundled study defaults.'
        Assert-True ($privacyDefaultsText.Contains('pref("datareporting.healthreport.uploadEnabled", false);')) 'Privacy defaults must disable upload before Nimbus startup.'
        Assert-True ($configText.Contains('lockPref("app.normandy.enabled", false);')) 'AutoConfig must lock Normandy off.'
        Assert-True ($configText.Contains('lockPref("toolkit.telemetry.unified", false);')) 'AutoConfig must lock unified telemetry off.'
        Assert-True ($configText.Contains('lockPref("datareporting.healthreport.uploadEnabled", false);')) 'AutoConfig must lock health report upload off.'
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'MOZ log resolver accepts Firefox .moz_log suffix files' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("astrid-mozlog-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        $baseLogPath = Join-Path $tempRoot 'astrid-network.log'
        $mainMozLog = "$baseLogPath.moz_log"
        $emptyChildLog = "$baseLogPath.child-1.moz_log"
        Set-Content -LiteralPath $mainMozLog -Value 'nsHttp: https://example.test/' -Encoding Ascii
        New-Item -ItemType File -Path $emptyChildLog | Out-Null

        $resolved = @(Get-AstridMozLogFiles -HostLogPath $baseLogPath)
        Assert-Equal $resolved.Count 1 'MOZ log resolver should ignore empty child logs.'
        Assert-Equal $resolved[0] $mainMozLog 'MOZ log resolver should return the suffixed main log.'

        $resolvedIncludingEmpty = @(Get-AstridMozLogFiles -HostLogPath $baseLogPath -IncludeEmpty)
        Assert-Equal $resolvedIncludingEmpty.Count 2 'MOZ log resolver should include empty logs when requested.'
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'release metadata builds deterministic v1 GitHub asset names' {
    $metadata = New-AstridReleaseMetadata -Version '1.0.0' -Repository 'Wrathalan/Astrid' -Commit 'abc123' -BuiltAtUtc '2026-06-19T00:00:00Z'

    Assert-Equal $metadata.version '1.0.0' 'Release metadata must preserve the package version.'
    Assert-Equal $metadata.repository 'Wrathalan/Astrid' 'Release metadata must preserve the GitHub repository.'
    Assert-Equal $metadata.releaseApiUrl 'https://api.github.com/repos/Wrathalan/Astrid/releases/latest' 'Release metadata must point at the GitHub latest-release API.'
    Assert-Equal $metadata.package.asset 'Astrid-1.0.0-win64.zip' 'Package asset name must be deterministic.'
    Assert-Equal $metadata.installer.asset 'AstridSetup-1.0.0-win64.exe' 'Installer asset name must be deterministic.'
}

Invoke-Test 'release manifest records package and installer hashes' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("astrid-release-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        $packagePath = Join-Path $tempRoot 'Astrid-1.0.0-win64.zip'
        $installerPath = Join-Path $tempRoot 'AstridSetup-1.0.0-win64.exe'
        $manifestPath = Join-Path $tempRoot 'Astrid-1.0.0-release.json'
        Set-Content -LiteralPath $packagePath -Value 'package payload' -Encoding Ascii
        Set-Content -LiteralPath $installerPath -Value 'installer payload' -Encoding Ascii

        [void] (Save-AstridReleaseManifest -Version '1.0.0' -Repository 'Wrathalan/Astrid' -Commit 'abc123' -PackagePath $packagePath -InstallerPath $installerPath -OutputPath $manifestPath)
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

        Assert-Equal $manifest.package.asset 'Astrid-1.0.0-win64.zip' 'Manifest must name the package asset.'
        Assert-Equal $manifest.installer.asset 'AstridSetup-1.0.0-win64.exe' 'Manifest must name the installer asset.'
        Assert-Equal $manifest.package.sha256 (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant() 'Manifest must include the package SHA256.'
        Assert-Equal $manifest.installer.sha256 (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant() 'Manifest must include the installer SHA256.'
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'package staging writes updater and installed version metadata' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("astrid-stage-" + [System.Guid]::NewGuid().ToString('N'))
    $browserDir = Join-Path $tempRoot 'browser'
    $stagingDir = Join-Path $tempRoot 'staging'
    New-Item -ItemType Directory -Path $browserDir | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $browserDir 'astrid.exe') -Value 'fake browser' -Encoding Ascii
        New-Item -ItemType Directory -Path (Join-Path $browserDir 'distribution') | Out-Null
        Set-Content -LiteralPath (Join-Path $browserDir 'distribution\policies.json') -Value '{"policies":{}}' -Encoding Ascii

        $staged = New-AstridPackageStaging -RepoRoot $RepoRoot -BrowserDir $browserDir -Version '1.0.0' -Repository 'Wrathalan/Astrid' -StagingDir $stagingDir -Commit 'abc123'

        Assert-True (Test-Path -LiteralPath (Join-Path $staged.AppDir 'astrid.exe') -PathType Leaf) 'Staging must copy the browser runtime.'
        Assert-True (Test-Path -LiteralPath (Join-Path $staged.AppDir 'astrid-version.json') -PathType Leaf) 'Staging must write installed version metadata.'
        Assert-True (Test-Path -LiteralPath (Join-Path $staged.AppDir 'AstridUpdater.ps1') -PathType Leaf) 'Staging must include the updater script.'
        Assert-True (Test-Path -LiteralPath (Join-Path $staged.AppDir 'AstridUpdateCheck.cmd') -PathType Leaf) 'Staging must include the updater launcher.'
        Assert-True (Test-Path -LiteralPath (Join-Path $staged.AppDir 'assets\retrowave_browser_icon_512.png') -PathType Leaf) 'Staging must include Astrid icon assets.'
        Assert-True (Test-Path -LiteralPath (Join-Path $staged.AppDir 'assets\astrid.ico') -PathType Leaf) 'Staging must create the Windows installer icon.'

        $versionInfo = Get-Content -LiteralPath (Join-Path $staged.AppDir 'astrid-version.json') -Raw | ConvertFrom-Json
        Assert-Equal $versionInfo.version '1.0.0' 'Installed version metadata must record the installed version.'
        Assert-Equal $versionInfo.repository 'Wrathalan/Astrid' 'Installed version metadata must record the update repository.'
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'installer icon generator writes a Windows ICO from Astrid PNG assets' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("astrid-icon-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        $iconPath = Join-Path $tempRoot 'astrid.ico'
        [void] (Save-AstridInstallerIcon -RepoRoot $RepoRoot -OutputPath $iconPath)

        $bytes = [System.IO.File]::ReadAllBytes($iconPath)
        Assert-Equal $bytes[0] 0 'ICO reserved byte 0 must be zero.'
        Assert-Equal $bytes[2] 1 'ICO type must be icon.'
        Assert-Equal $bytes[4] 2 'ICO must contain 64px and 256px PNG entries.'
        Assert-Equal $bytes[6] 64 'First ICO image entry must be 64px.'
        Assert-Equal $bytes[22] 0 'Second ICO image entry width byte must be zero for 256px.'
        Assert-True ($bytes.Length -gt 1000) 'Generated ICO must include image payloads.'
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'installer script uses per-user install directory and updater shortcut' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("astrid-inno-" + [System.Guid]::NewGuid().ToString('N'))
    $stagingAppDir = Join-Path $tempRoot 'app'
    $outputDir = Join-Path $tempRoot 'out'
    $scriptPath = Join-Path $tempRoot 'Astrid.iss'
    New-Item -ItemType Directory -Path $stagingAppDir | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $stagingAppDir 'astrid.exe') -Value 'fake browser' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $stagingAppDir 'AstridUpdateCheck.cmd') -Value '@echo off' -Encoding Ascii
        $iconDir = Join-Path $stagingAppDir 'assets'
        New-Item -ItemType Directory -Path $iconDir | Out-Null
        Set-Content -LiteralPath (Join-Path $iconDir 'astrid.ico') -Value 'fake icon' -Encoding Ascii

        [void] (Save-AstridInnoSetupScript -Version '1.0.0' -StagingAppDir $stagingAppDir -OutputDir $outputDir -ScriptPath $scriptPath)
        $scriptText = Get-Content -LiteralPath $scriptPath -Raw

        Assert-True ($scriptText.Contains('DefaultDirName={localappdata}\Programs\Astrid')) 'Installer must default to a per-user writable install directory.'
        Assert-True ($scriptText.Contains('AstridUpdateCheck.cmd')) 'Installer must create an updater shortcut.'
        Assert-True ($scriptText.Contains('AstridSetup-1.0.0-win64')) 'Installer output name must include the release version.'
        Assert-True ($scriptText.Contains("SetupIconFile=$(Join-Path $iconDir 'astrid.ico')")) 'Installer must use the packaged Astrid icon for setup.'
        Assert-True ($scriptText.Contains('IconFilename: "{app}\assets\astrid.ico"')) 'Installer shortcuts must use the packaged Astrid icon.'

        $scriptLines = @(Get-Content -LiteralPath $scriptPath)
        Assert-True ($scriptLines -contains "OutputDir=$outputDir") 'Installer OutputDir directive must stay on one line.'
        Assert-True (@($scriptLines | Where-Object { $_ -like 'Source: "*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs' }).Count -eq 1) 'Installer Source directive must stay on one line.'
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'installed updater checks GitHub releases and verifies package hashes' {
    $updaterPath = Join-Path $RepoRoot 'scripts\install\AstridUpdater.ps1'
    Assert-True (Test-Path -LiteralPath $updaterPath -PathType Leaf) 'Updater script must exist.'

    $updaterText = Get-Content -LiteralPath $updaterPath -Raw
    Assert-True ($updaterText.Contains('api.github.com/repos')) 'Updater must call the GitHub Releases API.'
    Assert-True ($updaterText.Contains('browser_download_url')) 'Updater must download release assets from GitHub.'
    Assert-True ($updaterText.Contains('Get-FileHash')) 'Updater must verify the downloaded package hash.'
    Assert-True ($updaterText.Contains('Expand-Archive')) 'Updater must expand the verified package.'
    Assert-True ($updaterText.Contains('astrid-version.json')) 'Updater must compare against installed version metadata.'
}

Invoke-Test 'release publisher creates a draft, uploads assets, and then publishes' {
    $publisherPath = Join-Path $RepoRoot 'scripts\publish-release.ps1'
    $publisherText = Get-Content -LiteralPath $publisherPath -Raw

    Assert-True ($publisherText.Contains("'--draft'")) 'Publisher must create the release as a draft before uploading assets.'
    Assert-True ($publisherText.Contains('gh release upload')) 'Publisher must upload assets after draft creation.'
    Assert-True ($publisherText.Contains('gh @editArgs')) 'Publisher must edit the release after uploads.'
    Assert-True ($publisherText.Contains("'--draft=false'")) 'Publisher must publish the draft after successful uploads.'
}

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures test(s) failed."
    exit 1
}

Write-Host 'All tests passed.'
