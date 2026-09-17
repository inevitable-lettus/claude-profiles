# Private/Doctor.ps1
#
# The Windows health check. Same findings vocabulary as lib/doctor.sh, so
# `Invoke-ClaudeProfileDoctor -Json` and `claude-profiles doctor --json`
# produce comparable output.
#
# Never prints a secret, and changes nothing.
# ---------------------------------------------------------------------------

function New-CpDoctorState {
    [pscustomobject]@{
        Findings = [Collections.Generic.List[object]]::new()
        Failed   = 0
        Warned   = 0
        AsJson   = $false
    }
}

function Add-CpFinding {
    param($State, [string]$Level, [string]$Id, [string]$Message)
    switch ($Level) {
        'ok'   { if (-not $State.AsJson) { Write-CpOk   $Message } }
        'warn' { $State.Warned++; if (-not $State.AsJson) { Write-CpWarn $Message } }
        'fail' { $State.Failed++; if (-not $State.AsJson) { Write-CpFail $Message } }
        'info' { if (-not $State.AsJson) { Write-CpInfo $Message } }
    }
    $State.Findings.Add([pscustomobject]@{ level = $Level; id = $Id; message = $Message })
}

function Write-CpDoctorHeader {
    param($State, [string]$Text)
    if (-not $State.AsJson) { Write-CpHeader $Text }
}


function Test-CpDoctorRegistry {
    param($State, $Registry)
    Write-CpDoctorHeader $State 'Registry'

    $path = Get-CpRegistryPath
    if (-not (Test-Path -LiteralPath $path)) {
        Add-CpFinding $State 'warn' 'registry.missing' "No registry at $path — run: Initialize-ClaudeProfiles"
        return
    }
    Add-CpFinding $State 'ok' 'registry.present' "Registry: $path"

    $problems = Test-CpRegistry $Registry
    if ($problems.Count -eq 0) {
        Add-CpFinding $State 'ok' 'registry.valid' 'Registry is internally consistent'
    } else {
        foreach ($p in $problems) { Add-CpFinding $State 'fail' 'registry.invalid' $p }
    }

    $count = (Get-CpProfileNames $Registry).Count
    Add-CpFinding $State 'info' 'registry.count' "$count profile(s) registered"
}


# Anything at precedence rank 1-4 beats a profile's own token. This is the
# most common reason for "it ran as the wrong account anyway".
function Test-CpDoctorPrecedence {
    param($State)
    Write-CpDoctorHeader $State 'Credential precedence'
    $clean = $true

    if ($env:CLAUDE_CODE_USE_BEDROCK -or $env:CLAUDE_CODE_USE_VERTEX -or $env:CLAUDE_CODE_USE_FOUNDRY) {
        Add-CpFinding $State 'warn' 'precedence.cloud' 'A cloud provider variable is set (rank 1). It outranks every profile credential.'
        $clean = $false
    }
    if ($env:ANTHROPIC_AUTH_TOKEN) {
        Add-CpFinding $State 'warn' 'precedence.auth_token' 'ANTHROPIC_AUTH_TOKEN is set (rank 2). It outranks every profile token.'
        $clean = $false
    }
    if ($env:ANTHROPIC_API_KEY) {
        Add-CpFinding $State 'warn' 'precedence.api_key' 'ANTHROPIC_API_KEY is set (rank 3). It outranks every profile token.'
        $clean = $false
    }

    # apiKeyHelper is rank 4 and easy to forget, because it lives in a
    # settings file rather than the environment.
    $settings = Join-Path (Get-CpPrimaryCliConfigDir) 'settings.json'
    if ((Test-Path -LiteralPath $settings) -and
        (Select-String -LiteralPath $settings -Pattern '"apiKeyHelper"' -Quiet -ErrorAction SilentlyContinue)) {
        Add-CpFinding $State 'warn' 'precedence.api_key_helper' "apiKeyHelper is configured in $settings (rank 4). It outranks every profile token."
        $clean = $false
    }

    if ($clean) {
        Add-CpFinding $State 'ok' 'precedence.clean' 'Nothing in the environment outranks a profile credential'
    }
}


function Test-CpDoctorCliProfile {
    param($State, $Registry, [string]$Name)
    if (-not (Test-CpCliConfigured $Registry $Name)) { return }

    $dir  = Get-CpCliConfigDir $Registry $Name
    $auth = Get-CpCliAuthMode $Registry $Name

    if (Test-Path -LiteralPath $dir) {
        Add-CpFinding $State 'ok' "cli.$Name.dir" "[$Name] config dir exists: $dir"
    } else {
        Add-CpFinding $State 'warn' "cli.$Name.dir" "[$Name] config dir does not exist yet: $dir"
    }

    if ($auth -eq 'config-dir') {
        Add-CpFinding $State 'ok' "cli.$Name.auth" "[$Name] auth: CLAUDE_CONFIG_DIR alone — the login lives in $dir\.credentials.json"
        if (-not (Test-Path -LiteralPath (Join-Path $dir '.credentials.json'))) {
            Add-CpFinding $State 'warn' "cli.$Name.login" "[$Name] no .credentials.json yet. Run: Invoke-ClaudeProfile -Name $Name -Arguments /login"
        }
    } else {
        $backend = Get-CpCliTokenBackend $Registry $Name
        if (Test-CpSecret -Name $Name -Backend $backend) {
            Add-CpFinding $State 'ok' "cli.$Name.token" "[$Name] token present in $(Get-CpSecretBackendLabel $backend)"
        } else {
            Add-CpFinding $State 'fail' "cli.$Name.token" "[$Name] no token stored. Run: Update-ClaudeProfileToken -Name $Name"
        }

        $age = Get-CpTokenAgeDays $Registry $Name
        if ($null -eq $age) {
            Add-CpFinding $State 'warn' "cli.$Name.token_age" "[$Name] no creation date recorded, so expiry cannot be tracked"
        } elseif ($age -ge $script:CpTokenLifetimeDays) {
            Add-CpFinding $State 'fail' "cli.$Name.token_age" "[$Name] token is $age days old and has almost certainly expired"
        } elseif ($age -ge $script:CpTokenWarnAfterDays) {
            Add-CpFinding $State 'warn' "cli.$Name.token_age" "[$Name] token is $age days old — expires in about $($script:CpTokenLifetimeDays - $age) days"
        } else {
            Add-CpFinding $State 'ok' "cli.$Name.token_age" "[$Name] token is $age days old"
        }

        Add-CpFinding $State 'info' "cli.$Name.token_limits" "[$Name] a token profile cannot use Remote Control or claude.ai connectors; local MCP servers still work"
        Add-CpFinding $State 'info' "cli.$Name.bare" "[$Name] 'claude --bare' ignores CLAUDE_CODE_OAUTH_TOKEN and would run as your PRIMARY account"
        Add-CpFinding $State 'info' "cli.$Name.windows_note" "[$Name] on Windows, config-dir auth would work without a token at all — token auth is only needed for CI or a registry synced from macOS"
    }
}


function Test-CpDoctorDesktopProfile {
    param($State, $Registry, [string]$Name)
    if (-not (Test-CpDesktopConfigured $Registry $Name)) { return }

    $udd = Get-CpDesktopUserDataDir $Registry $Name
    $app = Get-CpDesktopAppPath $Registry $Name

    if (Test-Path -LiteralPath $app) {
        Add-CpFinding $State 'ok' "desktop.$Name.app" "[$Name] app: $app"
    } else {
        Add-CpFinding $State 'fail' "desktop.$Name.app" "[$Name] app not found at $app"
    }

    if ($app -like "$env:ProgramFiles\WindowsApps\*") {
        Add-CpFinding $State 'fail' "desktop.$Name.windowsapps" "[$Name] appPath is inside WindowsApps, which cannot be launched with arguments. Run: New-ClaudeProfileMirror -Name $Name"
    }

    if (Test-Path -LiteralPath $udd) {
        Add-CpFinding $State 'ok' "desktop.$Name.dir" "[$Name] user-data dir exists: $udd"
    } else {
        Add-CpFinding $State 'info' "desktop.$Name.dir" "[$Name] user-data dir not created yet: $udd"
    }

    if (Test-CpDesktopMirrored $Registry $Name) {
        $info = Get-CpInstallFlavour
        $mirrorVersion = 'unknown'
        try { $mirrorVersion = (Get-Item -LiteralPath $app).VersionInfo.ProductVersion }
        catch { Write-Debug "could not read mirror version: $_" }
        if ($info.Flavour -eq 'none') {
            Add-CpFinding $State 'warn' "desktop.$Name.mirror" "[$Name] uses a mirrored app but no real install was found to compare against"
        } elseif ("$($info.Version)".StartsWith("$mirrorVersion") -or "$mirrorVersion".StartsWith("$($info.Version)")) {
            Add-CpFinding $State 'ok' "desktop.$Name.mirror" "[$Name] mirrored app looks current ($mirrorVersion)"
        } else {
            Add-CpFinding $State 'warn' "desktop.$Name.mirror" "[$Name] mirror is version $mirrorVersion but the install is $($info.Version) — re-run: New-ClaudeProfileMirror -Name $Name"
        }
        Add-CpFinding $State 'info' "desktop.$Name.mirror_links" "[$Name] claude:// links still open the ORIGINAL install, not the mirror"
    }

    $launcher = Get-CpValue $Registry $Name 'desktop.launcher' ''
    if ($launcher) {
        if (Test-Path -LiteralPath (Expand-CpPath $launcher)) {
            Add-CpFinding $State 'ok' "desktop.$Name.launcher" "[$Name] launcher: $launcher"
        } else {
            Add-CpFinding $State 'warn' "desktop.$Name.launcher" "[$Name] launcher recorded at $launcher but it is not there — re-run: Install-ClaudeProfileLauncher -Name $Name"
        }
    }
}


function Test-CpDoctorMcpPorts {
    param($State, $Registry)
    $names = Get-CpProfileNames $Registry
    if ($names.Count -eq 0) { return }

    Write-CpDoctorHeader $State 'MCP configuration'

    $seen = @{}
    $found = $false
    foreach ($name in $names) {
        $template = Get-CpMcpTemplatePath $name
        if (-not (Test-Path -LiteralPath $template)) { continue }
        $found = $true
        $text = Get-Content -LiteralPath $template -Raw
        foreach ($m in [regex]::Matches($text, '(?:--port[= ]|"PORT"\s*:\s*")(\d+)')) {
            $port = $m.Groups[1].Value
            if (-not $seen.ContainsKey($port)) { $seen[$port] = @() }
            $seen[$port] += $name
        }
    }

    if (-not $found) {
        Add-CpFinding $State 'info' 'mcp.none' "No per-profile MCP templates yet ($(Get-CpTemplatesDir))"
        return
    }

    $collisions = $seen.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }
    if ($collisions) {
        foreach ($c in $collisions) {
            Add-CpFinding $State 'warn' 'mcp.port_collision' "Fixed port $($c.Key) is used by more than one profile: $($c.Value -join ', ') — whichever instance starts second will fail to bind"
        }
    } else {
        Add-CpFinding $State 'ok' 'mcp.ports' 'No fixed-port collisions between profile MCP templates'
    }
}


function Test-CpDoctorPlatform {
    param($State)
    Write-CpDoctorHeader $State 'Windows desktop'

    $info = Get-CpInstallFlavour
    switch ($info.Flavour) {
        'direct' {
            Add-CpFinding $State 'ok' 'platform.app' "Direct .exe install: $($info.Path)"
            Add-CpFinding $State 'ok' 'platform.flavour' 'That flavour accepts --user-data-dir directly — no mirroring needed'
            Add-CpFinding $State 'info' 'platform.version' "App version: $($info.Version)"
        }
        'msix' {
            Add-CpFinding $State 'warn' 'platform.app' "MSIX / Store install: $($info.Path)"
            Add-CpFinding $State 'warn' 'platform.flavour' 'Windows will not execute anything directly out of WindowsApps, so --user-data-dir cannot be passed. Each desktop profile needs: New-ClaudeProfileMirror -Name <profile>'
            Add-CpFinding $State 'info' 'platform.version' "Package version: $($info.Version)"
        }
        default {
            Add-CpFinding $State 'info' 'platform.app' 'Claude desktop is not installed — skipping the desktop checks'
        }
    }

    Add-CpFinding $State 'ok' 'platform.credentials' 'On Windows the desktop credential blob lives inside the user-data directory (DPAPI-encrypted), so profiles cannot collide the way they can on macOS'
    Add-CpFinding $State 'info' 'platform.deeplink' 'The claude:// login link routes to whichever window is focused — log profiles in one at a time'
}


function Invoke-CpDoctor {
    param([string]$Only, [switch]$Json)

    $State = New-CpDoctorState
    $State.AsJson = [bool]$Json

    $Registry = Import-CpRegistry

    Test-CpDoctorRegistry $State $Registry
    Test-CpDoctorPrecedence $State

    $names = if ($Only) {
        if (-not (Test-CpProfileExists $Registry $Only)) { Stop-Cp "No profile called '$Only'." }
        @($Only)
    } else {
        Get-CpProfileNames $Registry
    }

    if ($names.Count -gt 0) {
        Write-CpDoctorHeader $State 'Profiles'
        foreach ($name in $names) {
            Test-CpDoctorCliProfile $State $Registry $name
            Test-CpDoctorDesktopProfile $State $Registry $name
        }
    }

    Test-CpDoctorMcpPorts $State $Registry
    Test-CpDoctorPlatform $State

    if ($Json) {
        return ([ordered]@{
            platform = 'windows'
            failed   = $State.Failed
            warned   = $State.Warned
            findings = @($State.Findings)
        } | ConvertTo-Json -Depth 5)
    }

    Write-CpHeader 'Summary'
    if ($State.Failed -gt 0)      { Write-CpFail "$($State.Failed) failure(s), $($State.Warned) warning(s)" }
    elseif ($State.Warned -gt 0)  { Write-CpWarn "0 failures, $($State.Warned) warning(s)" }
    else                          { Write-CpOk 'All checks passed' }
}
