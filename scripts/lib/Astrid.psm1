Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AstridDefaultSourceDir = 'C:\mozilla-source\astrid-firefox'
$script:AstridDefaultEsrRepo = 'https://hg.mozilla.org/releases/mozilla-esr140'
$script:AstridUBlockId = 'uBlock0@raymondhill.net'
$script:AstridUBlockRelativePath = 'third_party/ublock/ublock-origin.firefox.signed.xpi'
$script:AstridBrowserExecutableNames = @('astrid.exe', 'firefox.exe')

function Get-AstridDefaultSourceDir {
    [CmdletBinding()]
    param()

    return $script:AstridDefaultSourceDir
}

function Get-AstridDefaultEsrRepo {
    [CmdletBinding()]
    param()

    return $script:AstridDefaultEsrRepo
}

function Get-AstridRepoRoot {
    [CmdletBinding()]
    param(
        [string] $StartPath = (Get-Location).Path
    )

    $current = [System.IO.Path]::GetFullPath($StartPath)
    if ((Test-Path -LiteralPath $current -PathType Leaf)) {
        $current = Split-Path -Parent $current
    }

    while ($true) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) {
            return $current
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            throw "Could not find a git repository root starting at '$StartPath'."
        }

        $current = $parent
    }
}

function Assert-AstridSafeSourcePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $invalidPattern = '[\s''"&;|<>]'
    if ($fullPath -match $invalidPattern) {
        throw "Firefox source checkout path '$fullPath' is unsafe. Use a short path without spaces, quotes, shell metacharacters, or redirection characters, such as '$script:AstridDefaultSourceDir'."
    }

    return $fullPath
}

function ConvertTo-AstridFileUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return ([System.Uri]::new($fullPath)).AbsoluteUri
}

function Resolve-AstridCommandPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [string[]] $KnownPaths = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    foreach ($knownPath in $KnownPaths) {
        if (-not [string]::IsNullOrWhiteSpace($knownPath) -and (Test-Path -LiteralPath $knownPath -PathType Leaf)) {
            return $knownPath
        }
    }

    throw "Required command '$Name' was not found on PATH or in known install locations."
}

function Get-AstridMercurialPath {
    [CmdletBinding()]
    param()

    return Resolve-AstridCommandPath -Name 'hg' -KnownPaths @(
        'C:\Program Files\Mercurial\hg.exe',
        'C:\Program Files (x86)\Mercurial\hg.exe'
    )
}

function Get-AstridPythonPath {
    [CmdletBinding()]
    param()

    function Test-MachPythonCandidate {
        param(
            [Parameter(Mandatory)]
            [string] $CandidatePath
        )

        if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
            return $null
        }

        $versionJson = & $CandidatePath -c 'import json, sys; print(json.dumps({"major": sys.version_info.major, "minor": sys.version_info.minor}))' 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($versionJson)) {
            return $null
        }

        $version = $versionJson | ConvertFrom-Json
        if ($version.major -eq 3 -and $version.minor -le 12) {
            return [pscustomobject]@{
                Path = $CandidatePath
                Major = [int] $version.major
                Minor = [int] $version.minor
            }
        }

        return $null
    }

    $pyLauncher = Get-Command 'py' -ErrorAction SilentlyContinue
    if ($null -ne $pyLauncher) {
        foreach ($version in @('3.12', '3.11', '3.10')) {
            $pythonPath = & $pyLauncher.Source "-$version" -c 'import sys; print(sys.executable)' 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($pythonPath)) {
                $candidate = $pythonPath.Trim()
                $machPython = Test-MachPythonCandidate -CandidatePath $candidate
                if ($null -ne $machPython) {
                    return $machPython.Path
                }
            }
        }

        $listedPythons = & $pyLauncher.Source -0p 2>$null
        if ($LASTEXITCODE -eq 0 -and $null -ne $listedPythons) {
            $candidates = [System.Collections.Generic.List[object]]::new()
            foreach ($line in $listedPythons) {
                $match = [regex]::Match($line, '([A-Za-z]:\\.*?python\.exe)\s*$')
                if (-not $match.Success) {
                    continue
                }

                $machPython = Test-MachPythonCandidate -CandidatePath $match.Groups[1].Value
                if ($null -ne $machPython) {
                    $candidates.Add($machPython)
                }
            }

            if ($candidates.Count -gt 0) {
                return ($candidates | Sort-Object Major, Minor -Descending | Select-Object -First 1).Path
            }
        }
    }

    $python = Resolve-AstridCommandPath -Name 'python'
    $machPython = Test-MachPythonCandidate -CandidatePath $python
    if ($null -eq $machPython) {
        throw "Python at '$python' is not compatible with Firefox Mach. Install Python 3.12 or make it available through the Python launcher."
    }

    return $machPython.Path
}

function Initialize-AstridMozillaBuildEnvironment {
    [CmdletBinding()]
    param()

    $mozillaBuildPath = if ([string]::IsNullOrWhiteSpace($env:MOZILLABUILD)) {
        'C:\mozilla-build'
    } else {
        $env:MOZILLABUILD
    }

    if (Test-Path -LiteralPath $mozillaBuildPath -PathType Container) {
        $msysTmp = Join-Path $mozillaBuildPath 'msys2\tmp'
        New-Item -ItemType Directory -Path $msysTmp -Force | Out-Null
        $env:MOZILLABUILD = $mozillaBuildPath
    }
}

function Get-AstridResponseUri {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Response,
        [Parameter(Mandatory)]
        [string] $DefaultUri
    )

    if ($null -eq $Response) {
        return $DefaultUri
    }

    $baseProperty = $Response.PSObject.Properties['BaseResponse']
    $baseResponse = if ($null -ne $baseProperty) { $baseProperty.Value } else { $null }

    foreach ($candidate in @($Response, $baseResponse)) {
        if ($null -eq $candidate) {
            continue
        }

        $responseUriProperty = $candidate.PSObject.Properties['ResponseUri']
        if ($null -ne $responseUriProperty -and $null -ne $responseUriProperty.Value) {
            return $responseUriProperty.Value.AbsoluteUri
        }

        $requestMessageProperty = $candidate.PSObject.Properties['RequestMessage']
        if ($null -ne $requestMessageProperty -and $null -ne $requestMessageProperty.Value) {
            $requestUri = $requestMessageProperty.Value.RequestUri
            if ($null -ne $requestUri) {
                return $requestUri.AbsoluteUri
            }
        }
    }

    return $DefaultUri
}

function Get-AstridMozLogFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $HostLogPath,
        [switch] $IncludeEmpty
    )

    $fullPath = [System.IO.Path]::GetFullPath($HostLogPath)
    $parent = Split-Path -Parent $fullPath
    $leaf = Split-Path -Leaf $fullPath
    $matches = [System.Collections.Generic.List[string]]::new()

    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        $file = Get-Item -LiteralPath $fullPath
        if ($IncludeEmpty -or $file.Length -gt 0) {
            $matches.Add($file.FullName)
        }
    }

    if (Test-Path -LiteralPath $parent -PathType Container) {
        $suffixedLogs = @(Get-ChildItem -LiteralPath $parent -Filter "$leaf*" -File -ErrorAction SilentlyContinue |
            Where-Object { ($IncludeEmpty -or $_.Length -gt 0) -and $_.FullName -notin $matches })
        foreach ($logFile in $suffixedLogs) {
            $matches.Add($logFile.FullName)
        }
    }

    return [string[]] $matches.ToArray()
}

function New-AstridLockedPreference {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Value
    )

    return [ordered]@{
        Value = $Value
        Status = 'locked'
    }
}

function New-AstridAutoConfigPreferences {
    [CmdletBinding()]
    param()

    return [ordered]@{
        'app.normandy.enabled' = $false
        'app.normandy.api_url' = ''
        'app.shield.optoutstudies.enabled' = $false
        'breakpad.reportURL' = ''
        'datareporting.healthreport.infoURL' = ''
        'datareporting.healthreport.uploadEnabled' = $false
        'datareporting.sessions.current.clean' = $true
        'toolkit.coverage.endpoint.base' = ''
        'toolkit.coverage.opt-out' = $true
        'toolkit.telemetry.archive.enabled' = $false
        'toolkit.telemetry.bhrPing.enabled' = $false
        'toolkit.telemetry.coverage.opt-out' = $true
        'toolkit.telemetry.enabled' = $false
        'toolkit.telemetry.firstShutdownPing.enabled' = $false
        'toolkit.telemetry.newProfilePing.enabled' = $false
        'toolkit.telemetry.reportingpolicy.firstRun' = $false
        'toolkit.telemetry.server' = ''
        'toolkit.telemetry.shutdownPingSender.enabled' = $false
        'toolkit.telemetry.unified' = $false
        'toolkit.telemetry.updatePing.enabled' = $false
    }
}

function ConvertTo-AstridJavaScriptLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Value
    )

    return ($Value | ConvertTo-Json -Compress)
}

function New-AstridUBlockAdminSettingsJson {
    [CmdletBinding()]
    param()

    $settings = [ordered]@{
        userSettings = [ordered]@{
            autoUpdate = $true
            cloudStorageEnabled = $false
            cnameUncloakEnabled = $true
            hyperlinkAuditingDisabled = $true
            prefetchingDisabled = $true
            webrtcIPAddressHidden = $true
        }
        selectedFilterLists = @(
            'user-filters',
            'ublock-filters',
            'ublock-badware',
            'ublock-privacy',
            'ublock-quick-fixes',
            'easylist',
            'easyprivacy',
            'urlhaus-1',
            'plowe-0'
        )
    }

    return ($settings | ConvertTo-Json -Depth 12 -Compress)
}

function New-AstridPolicies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,
        [string] $BlockerXpiPath
    )

    if ([string]::IsNullOrWhiteSpace($BlockerXpiPath)) {
        $BlockerXpiPath = Join-Path $RepoRoot $script:AstridUBlockRelativePath
    }

    $blockerUri = ConvertTo-AstridFileUri -Path $BlockerXpiPath
    $uboAdminSettings = New-AstridUBlockAdminSettingsJson

    $preferences = [ordered]@{
        'browser.aboutwelcome.enabled' = New-AstridLockedPreference $false
        'browser.crashReports.unsubmittedCheck.autoSubmit2' = New-AstridLockedPreference $false
        'browser.crashReports.unsubmittedCheck.enabled' = New-AstridLockedPreference $false
        'browser.discovery.enabled' = New-AstridLockedPreference $false
        'browser.ml.enable' = New-AstridLockedPreference $false
        'browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons' = New-AstridLockedPreference $false
        'browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features' = New-AstridLockedPreference $false
        'browser.newtabpage.activity-stream.default.sites' = New-AstridLockedPreference ''
        'browser.newtabpage.activity-stream.feeds.section.topstories' = New-AstridLockedPreference $false
        'browser.newtabpage.activity-stream.feeds.snippets' = New-AstridLockedPreference $false
        'browser.newtabpage.activity-stream.feeds.system.topstories' = New-AstridLockedPreference $false
        'browser.newtabpage.activity-stream.feeds.telemetry' = New-AstridLockedPreference $false
        'browser.newtabpage.activity-stream.section.highlights.includePocket' = New-AstridLockedPreference $false
        'browser.newtabpage.activity-stream.showSponsored' = New-AstridLockedPreference $false
        'browser.newtabpage.activity-stream.showSponsoredCheckboxes' = New-AstridLockedPreference $false
        'browser.newtabpage.activity-stream.showSponsoredTopSites' = New-AstridLockedPreference $false
        'browser.newtabpage.activity-stream.telemetry' = New-AstridLockedPreference $false
        'browser.newtabpage.activity-stream.telemetry.ut.events' = New-AstridLockedPreference $false
        'browser.newtabpage.enabled' = New-AstridLockedPreference $true
        'browser.ping-centre.telemetry' = New-AstridLockedPreference $false
        'browser.privatebrowsing.forceMediaMemoryCache' = New-AstridLockedPreference $true
        'browser.shopping.experience2023.enabled' = New-AstridLockedPreference $false
        'browser.startup.homepage_override.mstone' = New-AstridLockedPreference 'ignore'
        'browser.tabs.crashReporting.sendReport' = New-AstridLockedPreference $false
        'browser.urlbar.quicksuggest.enabled' = New-AstridLockedPreference $false
        'browser.urlbar.suggest.quicksuggest.nonsponsored' = New-AstridLockedPreference $false
        'browser.urlbar.suggest.quicksuggest.sponsored' = New-AstridLockedPreference $false
        'browser.urlbar.suggest.searches' = New-AstridLockedPreference $false
        'browser.urlbar.suggest.topsites' = New-AstridLockedPreference $false
        'datareporting.policy.dataSubmissionEnabled' = New-AstridLockedPreference $false
        'dom.private-attribution.submission.enabled' = New-AstridLockedPreference $false
        'extensions.getAddons.cache.enabled' = New-AstridLockedPreference $false
        'extensions.getAddons.discovery.api_url' = New-AstridLockedPreference ''
        'extensions.htmlaboutaddons.recommendations.enabled' = New-AstridLockedPreference $false
        'extensions.pocket.enabled' = New-AstridLockedPreference $false
        'extensions.recommendations.themeRecommendationUrl' = New-AstridLockedPreference ''
        'network.allow-experiments' = New-AstridLockedPreference $false
    }

    return [ordered]@{
        policies = [ordered]@{
            DisableFirefoxStudies = $true
            DisablePocket = $true
            DisableTelemetry = $true
            DontCheckDefaultBrowser = $true
            NoDefaultBookmarks = $true
            OfferToSaveLoginsDefault = $false
            OverrideFirstRunPage = ''
            OverridePostUpdatePage = ''
            SearchSuggestEnabled = $false
            FirefoxHome = [ordered]@{
                Search = $true
                TopSites = $true
                SponsoredTopSites = $false
                Highlights = $true
                Pocket = $false
                SponsoredPocket = $false
                Snippets = $false
            }
            ExtensionSettings = [ordered]@{
                '*' = [ordered]@{
                    installation_mode = 'allowed'
                }
                $script:AstridUBlockId = [ordered]@{
                    installation_mode = 'force_installed'
                    install_url = $blockerUri
                    updates_disabled = $true
                    default_area = 'navbar'
                }
            }
            '3rdparty' = [ordered]@{
                Extensions = [ordered]@{
                    $script:AstridUBlockId = [ordered]@{
                        adminSettings = $uboAdminSettings
                    }
                }
            }
            Preferences = $preferences
        }
    }
}

function Save-AstridPolicies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,
        [Parameter(Mandatory)]
        [string] $OutputPath,
        [string] $BlockerXpiPath
    )

    $policy = New-AstridPolicies -RepoRoot $RepoRoot -BlockerXpiPath $BlockerXpiPath
    $parent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $json = $policy | ConvertTo-Json -Depth 24
    Set-Content -LiteralPath $OutputPath -Value ($json + [Environment]::NewLine) -Encoding UTF8
    return $OutputPath
}

function Write-AstridDistributionNote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $OutputPath
    )

    $note = @(
        'Astrid browser distribution overlay',
        'Generated by the Astrid orchestration repo.',
        'Do not hand-edit this directory; update scripts/lib/Astrid.psm1 instead.'
    )
    Set-Content -LiteralPath $OutputPath -Value $note -Encoding UTF8
    return $OutputPath
}

function Save-AstridAutoConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $BrowserDir
    )

    $browserFullPath = [System.IO.Path]::GetFullPath($BrowserDir)
    $defaultsPrefDir = Join-Path $browserFullPath 'defaults\pref'
    New-Item -ItemType Directory -Path $defaultsPrefDir -Force | Out-Null

    $defaultsPrefPath = Join-Path $defaultsPrefDir 'astrid-autoconfig.js'
    $defaultsLines = @(
        '// Astrid AutoConfig bootstrap.',
        'pref("general.config.filename", "astrid.cfg");',
        'pref("general.config.obscure_value", 0);'
    )
    Set-Content -LiteralPath $defaultsPrefPath -Value $defaultsLines -Encoding UTF8

    $privacyDefaultsPrefPath = Join-Path $defaultsPrefDir 'astrid-privacy.js'
    $privacyDefaultsLines = [System.Collections.Generic.List[string]]::new()
    $privacyDefaultsLines.Add('// Astrid privacy defaults for early startup consumers.')
    foreach ($entry in (New-AstridAutoConfigPreferences).GetEnumerator()) {
        $nameLiteral = ConvertTo-AstridJavaScriptLiteral -Value $entry.Key
        $valueLiteral = ConvertTo-AstridJavaScriptLiteral -Value $entry.Value
        $privacyDefaultsLines.Add("pref($nameLiteral, $valueLiteral);")
    }
    Set-Content -LiteralPath $privacyDefaultsPrefPath -Value $privacyDefaultsLines -Encoding UTF8

    $appDefaultsDir = Join-Path $browserFullPath 'defaults\preferences'
    New-Item -ItemType Directory -Path $appDefaultsDir -Force | Out-Null
    $appPrivacyDefaultsPrefPath = Join-Path $appDefaultsDir 'astrid-privacy.js'
    Set-Content -LiteralPath $appPrivacyDefaultsPrefPath -Value $privacyDefaultsLines -Encoding UTF8

    $configPath = Join-Path $browserFullPath 'astrid.cfg'
    $configLines = [System.Collections.Generic.List[string]]::new()
    $configLines.Add('// Astrid AutoConfig privacy locks.')
    foreach ($entry in (New-AstridAutoConfigPreferences).GetEnumerator()) {
        $nameLiteral = ConvertTo-AstridJavaScriptLiteral -Value $entry.Key
        $valueLiteral = ConvertTo-AstridJavaScriptLiteral -Value $entry.Value
        $configLines.Add("lockPref($nameLiteral, $valueLiteral);")
    }
    Set-Content -LiteralPath $configPath -Value $configLines -Encoding UTF8

    return [pscustomobject]@{
        DefaultsPrefPath = $defaultsPrefPath
        PrivacyDefaultsPrefPath = $privacyDefaultsPrefPath
        AppPrivacyDefaultsPrefPath = $appPrivacyDefaultsPrefPath
        ConfigPath = $configPath
    }
}

function Test-AstridAutoConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $BrowserDir
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $browserFullPath = [System.IO.Path]::GetFullPath($BrowserDir)
    $defaultsPrefPath = Join-Path $browserFullPath 'defaults\pref\astrid-autoconfig.js'
    $privacyDefaultsPrefPath = Join-Path $browserFullPath 'defaults\pref\astrid-privacy.js'
    $appPrivacyDefaultsPrefPath = Join-Path $browserFullPath 'defaults\preferences\astrid-privacy.js'
    $configPath = Join-Path $browserFullPath 'astrid.cfg'

    if (-not (Test-Path -LiteralPath $defaultsPrefPath -PathType Leaf)) {
        $failures.Add("Missing AutoConfig defaults file at '$defaultsPrefPath'.")
    }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $failures.Add("Missing AutoConfig lock file at '$configPath'.")
    }
    if (-not (Test-Path -LiteralPath $privacyDefaultsPrefPath -PathType Leaf)) {
        $failures.Add("Missing privacy defaults file at '$privacyDefaultsPrefPath'.")
    }
    if (-not (Test-Path -LiteralPath $appPrivacyDefaultsPrefPath -PathType Leaf)) {
        $failures.Add("Missing app privacy defaults file at '$appPrivacyDefaultsPrefPath'.")
    }

    if ($failures.Count -eq 0) {
        $defaultsText = Get-Content -LiteralPath $defaultsPrefPath -Raw
        $privacyDefaultsText = Get-Content -LiteralPath $privacyDefaultsPrefPath -Raw
        $appPrivacyDefaultsText = Get-Content -LiteralPath $appPrivacyDefaultsPrefPath -Raw
        $configText = Get-Content -LiteralPath $configPath -Raw
        if ($defaultsText -notmatch 'general\.config\.filename' -or $defaultsText -notmatch 'astrid\.cfg') {
            $failures.Add('AutoConfig defaults file must point Firefox at astrid.cfg.')
        }

        foreach ($entry in (New-AstridAutoConfigPreferences).GetEnumerator()) {
            $nameLiteral = ConvertTo-AstridJavaScriptLiteral -Value $entry.Key
            $valueLiteral = ConvertTo-AstridJavaScriptLiteral -Value $entry.Value
            $expectedLine = "lockPref($nameLiteral, $valueLiteral);"
            if (-not $configText.Contains($expectedLine)) {
                $failures.Add("AutoConfig lock file is missing '$expectedLine'.")
            }

            $expectedDefaultLine = "pref($nameLiteral, $valueLiteral);"
            if (-not $privacyDefaultsText.Contains($expectedDefaultLine)) {
                $failures.Add("Privacy defaults file is missing '$expectedDefaultLine'.")
            }
            if (-not $appPrivacyDefaultsText.Contains($expectedDefaultLine)) {
                $failures.Add("App privacy defaults file is missing '$expectedDefaultLine'.")
            }
        }
    }

    return [pscustomobject]@{
        Passed = ($failures.Count -eq 0)
        Failures = [string[]] $failures.ToArray()
        DefaultsPrefPath = $defaultsPrefPath
        PrivacyDefaultsPrefPath = $privacyDefaultsPrefPath
        AppPrivacyDefaultsPrefPath = $appPrivacyDefaultsPrefPath
        ConfigPath = $configPath
    }
}

function Get-AstridObjectProperty {
    param(
        [AllowNull()]
        $Object,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Test-AstridPolicies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $PolicyPath
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
        $failures.Add("Missing policies file at '$PolicyPath'.")
        return [pscustomobject]@{
            Passed = $false
            Failures = [string[]] $failures.ToArray()
            PolicyPath = $PolicyPath
        }
    }

    try {
        $policyRoot = Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json
    } catch {
        $failures.Add("Policies file is not valid JSON: $($_.Exception.Message)")
        return [pscustomobject]@{
            Passed = $false
            Failures = [string[]] $failures.ToArray()
            PolicyPath = $PolicyPath
        }
    }

    $policies = Get-AstridObjectProperty -Object $policyRoot -Name 'policies'
    if ($null -eq $policies) {
        $failures.Add('Root object must contain a policies property.')
    }

    $requiredTrue = @('DisableTelemetry', 'DisableFirefoxStudies', 'DisablePocket')
    foreach ($name in $requiredTrue) {
        if ((Get-AstridObjectProperty -Object $policies -Name $name) -ne $true) {
            $failures.Add("$name must be true.")
        }
    }

    $requiredFalsePrefs = @(
        'datareporting.policy.dataSubmissionEnabled',
        'browser.ping-centre.telemetry',
        'browser.newtabpage.activity-stream.showSponsoredTopSites',
        'browser.newtabpage.activity-stream.showSponsored',
        'browser.urlbar.suggest.quicksuggest.sponsored',
        'browser.urlbar.quicksuggest.enabled',
        'browser.tabs.crashReporting.sendReport',
        'browser.crashReports.unsubmittedCheck.autoSubmit2',
        'dom.private-attribution.submission.enabled'
    )

    $preferences = Get-AstridObjectProperty -Object $policies -Name 'Preferences'
    foreach ($prefName in $requiredFalsePrefs) {
        $pref = Get-AstridObjectProperty -Object $preferences -Name $prefName
        if ($null -eq $pref) {
            $failures.Add("Missing locked preference '$prefName'.")
            continue
        }

        if ((Get-AstridObjectProperty -Object $pref -Name 'Value') -ne $false) {
            $failures.Add("Preference '$prefName' must be false.")
        }

        if ((Get-AstridObjectProperty -Object $pref -Name 'Status') -ne 'locked') {
            $failures.Add("Preference '$prefName' must be locked.")
        }
    }

    $extensionSettings = Get-AstridObjectProperty -Object $policies -Name 'ExtensionSettings'
    $ubo = Get-AstridObjectProperty -Object $extensionSettings -Name $script:AstridUBlockId
    if ($null -eq $ubo) {
        $failures.Add('uBlock Origin must be listed in ExtensionSettings.')
    } else {
        if ((Get-AstridObjectProperty -Object $ubo -Name 'installation_mode') -ne 'force_installed') {
            $failures.Add('uBlock Origin must be force_installed.')
        }

        $installUrl = Get-AstridObjectProperty -Object $ubo -Name 'install_url'
        if ([string]::IsNullOrWhiteSpace($installUrl) -or -not $installUrl.StartsWith('file:///')) {
            $failures.Add('uBlock Origin install_url must be a local file URI.')
        }

        if ((Get-AstridObjectProperty -Object $ubo -Name 'updates_disabled') -ne $true) {
            $failures.Add('uBlock Origin package updates must be disabled.')
        }
    }

    $thirdParty = Get-AstridObjectProperty -Object $policies -Name '3rdparty'
    $thirdPartyExtensions = Get-AstridObjectProperty -Object $thirdParty -Name 'Extensions'
    $uboThirdParty = Get-AstridObjectProperty -Object $thirdPartyExtensions -Name $script:AstridUBlockId
    $adminSettingsJson = Get-AstridObjectProperty -Object $uboThirdParty -Name 'adminSettings'
    if ([string]::IsNullOrWhiteSpace($adminSettingsJson)) {
        $failures.Add('uBlock Origin managed adminSettings must be present.')
    } else {
        try {
            $adminSettings = $adminSettingsJson | ConvertFrom-Json
            if ((Get-AstridObjectProperty -Object (Get-AstridObjectProperty -Object $adminSettings -Name 'userSettings') -Name 'autoUpdate') -ne $true) {
                $failures.Add('uBlock Origin filter autoUpdate must be true.')
            }
        } catch {
            $failures.Add("uBlock Origin adminSettings must be valid JSON: $($_.Exception.Message)")
        }
    }

    return [pscustomobject]@{
        Passed = ($failures.Count -eq 0)
        Failures = [string[]] $failures.ToArray()
        PolicyPath = $PolicyPath
    }
}

function Install-AstridDistribution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,
        [Parameter(Mandatory)]
        [string] $SourceDir
    )

    $safeSourceDir = Assert-AstridSafeSourcePath -Path $SourceDir
    if (-not (Test-Path -LiteralPath $safeSourceDir -PathType Container)) {
        throw "Firefox source directory '$safeSourceDir' does not exist. Run scripts/bootstrap.ps1 first."
    }

    $distributionDir = Join-Path $safeSourceDir 'distribution'
    New-Item -ItemType Directory -Path $distributionDir -Force | Out-Null

    $policyPath = Join-Path $distributionDir 'policies.json'
    Save-AstridPolicies -RepoRoot $RepoRoot -OutputPath $policyPath | Out-Null

    $notePath = Join-Path $distributionDir 'ASTRID.txt'
    Write-AstridDistributionNote -OutputPath $notePath | Out-Null

    return [pscustomobject]@{
        DistributionDir = $distributionDir
        PolicyPath = $policyPath
        NotePath = $notePath
    }
}

function Write-AstridMozConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SourceDir,
        [ValidateSet('Debug', 'Release')]
        [string] $Configuration = 'Release'
    )

    $safeSourceDir = Assert-AstridSafeSourcePath -Path $SourceDir
    if (-not (Test-Path -LiteralPath $safeSourceDir -PathType Container)) {
        throw "Firefox source directory '$safeSourceDir' does not exist. Run scripts/bootstrap.ps1 first."
    }

    $mozconfigPath = Join-Path $safeSourceDir '.mozconfig'
    $configurationLines = if ($Configuration -eq 'Debug') {
        @(
            'ac_add_options --enable-debug',
            'ac_add_options --disable-optimize'
        )
    } else {
        @(
            'ac_add_options --disable-debug',
            'ac_add_options --enable-optimize'
        )
    }

    $lines = @(
        '# Generated by Astrid. Keep source patches in the orchestration repo.',
        'ac_add_options --enable-project=browser',
        'ac_add_options --with-branding=browser/branding/unofficial',
        'ac_add_options --with-app-name=astrid',
        'ac_add_options --with-app-basename=Astrid',
        'ac_add_options --with-distribution-id=org.astrid.browser',
        'mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/obj-astrid'
    ) + $configurationLines

    Set-Content -LiteralPath $mozconfigPath -Value $lines -Encoding UTF8
    return $mozconfigPath
}

function Invoke-AstridPatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,
        [Parameter(Mandatory)]
        [string] $SourceDir
    )

    $safeSourceDir = Assert-AstridSafeSourcePath -Path $SourceDir
    $patchDir = Join-Path $RepoRoot 'patches'
    if (-not (Test-Path -LiteralPath $patchDir -PathType Container)) {
        return @()
    }

    $patches = @(Get-ChildItem -LiteralPath $patchDir -Filter '*.patch' | Sort-Object Name)
    if ($patches.Count -eq 0) {
        return @()
    }

    $hgPath = Get-AstridMercurialPath
    $applied = [System.Collections.Generic.List[string]]::new()
    foreach ($patch in $patches) {
        $status = & $hgPath --cwd $safeSourceDir status 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not inspect Mercurial source checkout at '$safeSourceDir'. Is Mercurial installed and is this a Firefox hg checkout?"
        }

        & $hgPath --cwd $safeSourceDir import --no-commit $patch.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to apply Astrid patch '$($patch.Name)'."
        }

        $applied.Add($patch.Name)
    }

    return [string[]] $applied.ToArray()
}

function Get-AstridFirefoxExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SourceDir
    )

    $safeSourceDir = Assert-AstridSafeSourcePath -Path $SourceDir
    $objectDirs = [System.Collections.Generic.List[string]]::new()
    $objectDirs.Add((Join-Path $safeSourceDir 'obj-astrid'))

    $extraObjectDirs = @(Get-ChildItem -LiteralPath $safeSourceDir -Directory -Filter 'obj-*' -ErrorAction SilentlyContinue)
    foreach ($objectDir in $extraObjectDirs) {
        if ($objectDirs -notcontains $objectDir.FullName) {
            $objectDirs.Add($objectDir.FullName)
        }
    }

    foreach ($objectDir in $objectDirs) {
        foreach ($executableName in $script:AstridBrowserExecutableNames) {
            $candidate = Join-Path $objectDir (Join-Path 'dist/bin' $executableName)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }

    return $null
}

function Install-AstridRuntimeDistribution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,
        [string] $SourceDir,
        [string] $BrowserExe
    )

    if ([string]::IsNullOrWhiteSpace($BrowserExe)) {
        if ([string]::IsNullOrWhiteSpace($SourceDir)) {
            throw 'SourceDir is required when BrowserExe is not provided.'
        }

        $BrowserExe = Get-AstridFirefoxExecutable -SourceDir $SourceDir
    }

    if ([string]::IsNullOrWhiteSpace($BrowserExe) -or -not (Test-Path -LiteralPath $BrowserExe -PathType Leaf)) {
        throw "Could not find a built Astrid browser executable. Run scripts/build.ps1 first or pass -BrowserExe."
    }

    $browserDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($BrowserExe))
    $distributionDir = Join-Path $browserDir 'distribution'
    New-Item -ItemType Directory -Path $distributionDir -Force | Out-Null

    $policyPath = Join-Path $distributionDir 'policies.json'
    Save-AstridPolicies -RepoRoot $RepoRoot -OutputPath $policyPath | Out-Null

    $notePath = Join-Path $distributionDir 'ASTRID.txt'
    Write-AstridDistributionNote -OutputPath $notePath | Out-Null

    $autoConfig = Save-AstridAutoConfig -BrowserDir $browserDir

    return [pscustomobject]@{
        DistributionDir = $distributionDir
        PolicyPath = $policyPath
        NotePath = $notePath
        AutoConfigDefaultsPrefPath = $autoConfig.DefaultsPrefPath
        PrivacyDefaultsPrefPath = $autoConfig.PrivacyDefaultsPrefPath
        AppPrivacyDefaultsPrefPath = $autoConfig.AppPrivacyDefaultsPrefPath
        AutoConfigPath = $autoConfig.ConfigPath
        BrowserExe = [System.IO.Path]::GetFullPath($BrowserExe)
    }
}

Export-ModuleMember -Function @(
    'Assert-AstridSafeSourcePath',
    'ConvertTo-AstridFileUri',
    'Get-AstridDefaultEsrRepo',
    'Get-AstridDefaultSourceDir',
    'Get-AstridFirefoxExecutable',
    'Get-AstridMercurialPath',
    'Get-AstridMozLogFiles',
    'Get-AstridPythonPath',
    'Get-AstridResponseUri',
    'Get-AstridRepoRoot',
    'Initialize-AstridMozillaBuildEnvironment',
    'Install-AstridDistribution',
    'Install-AstridRuntimeDistribution',
    'Invoke-AstridPatches',
    'New-AstridAutoConfigPreferences',
    'New-AstridPolicies',
    'Save-AstridPolicies',
    'Test-AstridAutoConfig',
    'Test-AstridPolicies',
    'Resolve-AstridCommandPath',
    'Write-AstridMozConfig'
)
