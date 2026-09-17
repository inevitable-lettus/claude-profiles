# Public/Commands.ps1
#
# The exported surface. Two spellings of the same thing, on purpose:
#
#   Verb-Noun cmdlets     what a PowerShell user expects, and what tab
#                         completion and Get-Help work with.
#
#   claude-profiles       the same subcommands as the bash entrypoint, so the
#                         README, every doc page and anyone's muscle memory
#                         transfer between platforms unchanged.
#
# Neither is a second implementation: the dispatcher calls the cmdlets.
# ---------------------------------------------------------------------------

function Initialize-ClaudeProfiles {
    <#
    .SYNOPSIS
    Create the profile registry, adopting an existing setup if one is found.
    #>
    [CmdletBinding()]
    param()

    $stateHome = Get-CpStateHome
    $existed = Test-Path -LiteralPath (Get-CpRegistryPath)

    if (-not (Test-Path -LiteralPath $stateHome)) {
        New-Item -ItemType Directory -Path $stateHome -Force | Out-Null
        Protect-CpUserOnlyPath $stateHome
        Write-CpOk "Created $stateHome"
    } elseif ($existed) {
        Write-CpInfo "Registry already exists: $(Get-CpRegistryPath)"
    }

    $reg = Import-CpRegistry

    # Adopt a ~/.claude-work directory left by an earlier manual setup.
    # Nothing is moved, copied or logged out — only registered.
    #
    # CLAUDE_PROFILES_NO_ADOPT=1 skips it. Adoption inspects real paths in the
    # real home directory, which makes this cmdlet behave differently
    # depending on whose machine it runs on — fine for a person, wrong for a
    # test or a scripted provision that wants a known-empty registry.
    if ($env:CLAUDE_PROFILES_NO_ADOPT -ne '1' -and -not (Test-CpProfileExists $reg 'work')) {
        $legacyCli = Get-CpDefaultCliConfigDir 'work'
        $legacyDesktop = Get-CpDefaultDesktopDir 'work'
        if ((Test-Path -LiteralPath $legacyCli) -or (Test-Path -LiteralPath $legacyDesktop)) {
            Write-CpHeader 'Existing setup detected'
            if (Test-Path -LiteralPath $legacyCli)     { Write-CpSay "  CLI config dir   $legacyCli" }
            if (Test-Path -LiteralPath $legacyDesktop) { Write-CpSay "  Desktop profile  $legacyDesktop" }
            Write-CpSay ''
            Write-CpSay "Adopting registers a profile called 'work' pointing at these exact"
            Write-CpSay 'paths. Nothing is moved, copied, or logged out.'
            Write-CpSay ''
            if (Confirm-CpAction "Adopt them as the 'work' profile?") {
                if (Test-Path -LiteralPath $legacyCli) {
                    Set-CpValue $reg 'work' 'cli.configDir' (Compress-CpPath $legacyCli)
                    Set-CpValue $reg 'work' 'cli.auth' (Get-CpDefaultAuthMode)
                }
                if (Test-Path -LiteralPath $legacyDesktop) {
                    Set-CpValue $reg 'work' 'desktop.userDataDir' (Compress-CpPath $legacyDesktop)
                    $app = Find-CpClaudeApp
                    if ($app) { Set-CpValue $reg 'work' 'desktop.appPath' $app }
                    Set-CpValue $reg 'work' 'desktop.mirrored' 'false'
                }
                Set-CpValue $reg 'work' 'description' 'adopted from an earlier setup'
                Write-CpOk "Adopted as profile 'work'"
            }
        }
    }

    Export-CpRegistry $reg

    Write-CpHeader 'Next'
    if ((Get-CpProfileNames $reg).Count -eq 0) {
        Write-CpSay '  Add-ClaudeProfile -Name work'
    } else {
        Write-CpSay '  Get-ClaudeProfile'
        Write-CpSay '  Invoke-ClaudeProfileDoctor'
    }
}


function Add-ClaudeProfile {
    <#
    .SYNOPSIS
    Register a profile, or update an existing one.

    .DESCRIPTION
    On Windows the CLI half needs nothing but CLAUDE_CONFIG_DIR: the docs are
    explicit that setting it relocates .credentials.json into that directory,
    so the login is isolated by that variable alone. Use -Auth oauth-token
    only for CI, for headless runs, or to match a registry synced from macOS.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [switch]$Cli,
        [switch]$NoCli,
        [switch]$Desktop,
        [switch]$NoDesktop,
        [ValidateSet('config-dir', 'oauth-token')][string]$Auth,
        [string]$ConfigDir,
        [string]$UserDataDir,
        [string]$AppPath,
        [string]$Description
    )

    Assert-CpProfileName $Name
    $reg = Import-CpRegistry
    $updating = Test-CpProfileExists $reg $Name

    # -Cli and -NoCli are both accepted so the switch pair reads symmetrically
    # with -Desktop/-NoDesktop and matches the bash --cli/--no-cli flags. The
    # CLI half is on by default, so -Cli only matters as an explicit override
    # of -NoCli — which is a contradiction worth naming rather than resolving
    # silently.
    if ($Cli -and $NoCli) { Stop-Cp 'Pass either -Cli or -NoCli, not both.' }
    $wantCli = $Cli -or (-not $NoCli)

    # Desktop defaults on when an app is actually installed, because most
    # people want both halves. PowerShell requires `elseif` on the same line
    # as the preceding brace, hence the explicit block.
    if ($Desktop)                       { $wantDesktop = $true }
    elseif ($NoDesktop)                 { $wantDesktop = $false }
    elseif ($AppPath -or $UserDataDir)  { $wantDesktop = $true }
    else                                { $wantDesktop = ((Get-CpInstallFlavour).Flavour -ne 'none') }

    if (-not $wantCli -and -not $wantDesktop) {
        Stop-Cp 'Nothing to do: both -NoCli and -NoDesktop were given.'
    }

    if ($wantCli) {
        if (-not $ConfigDir) { $ConfigDir = Get-CpDefaultCliConfigDir $Name }
        $ConfigDir = Expand-CpPath $ConfigDir
        if ($ConfigDir -eq (Get-CpPrimaryCliConfigDir)) {
            Stop-Cp "$ConfigDir is the primary account's config directory. Pick another with -ConfigDir."
        }
        if (-not $Auth) { $Auth = Get-CpDefaultAuthMode }

        Set-CpValue $reg $Name 'cli.configDir' (Compress-CpPath $ConfigDir)
        Set-CpValue $reg $Name 'cli.auth' $Auth
    } elseif ($updating) {
        Remove-CpSection $reg $Name 'cli'
    }

    if ($wantDesktop) {
        if (-not $UserDataDir) { $UserDataDir = Get-CpDefaultDesktopDir $Name }
        $UserDataDir = Expand-CpPath $UserDataDir
        if ($UserDataDir -eq (Get-CpPrimaryDesktopDir)) {
            Stop-Cp "$UserDataDir is the primary profile's directory. Pick another with -UserDataDir."
        }

        $info = Get-CpInstallFlavour
        if (-not $AppPath) {
            if ($info.Flavour -eq 'direct') {
                $AppPath = $info.Path
            } elseif ($info.Flavour -eq 'msix') {
                # Record the profile anyway — it is not wrong, just not yet
                # launchable — and say exactly what the next step is.
                Write-CpWarn 'Claude is installed as an MSIX package. Windows will not execute'
                Write-CpWarn 'anything directly out of C:\Program Files\WindowsApps, so'
                Write-CpWarn '--user-data-dir cannot be passed to it.'
                Write-CpWarn "This profile needs a mirrored copy: New-ClaudeProfileMirror -Name $Name"
                $AppPath = $info.Path
            } else {
                Stop-Cp 'Could not find the Claude desktop app. Pass -AppPath, or use -NoDesktop for a CLI-only profile.'
            }
        }
        $AppPath = Expand-CpPath $AppPath
        if (-not (Test-Path -LiteralPath $AppPath)) { Stop-Cp "No app at $AppPath" }

        Set-CpValue $reg $Name 'desktop.userDataDir' (Compress-CpPath $UserDataDir)
        Set-CpValue $reg $Name 'desktop.appPath' (Compress-CpPath $AppPath)
        if (-not (Get-CpValue $reg $Name 'desktop.mirrored' '')) {
            Set-CpValue $reg $Name 'desktop.mirrored' 'false'
        }
    } elseif ($updating) {
        Remove-CpSection $reg $Name 'desktop'
    }

    if ($Description) { Set-CpValue $reg $Name 'description' $Description }

    $problems = Test-CpRegistry $reg
    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { Write-CpFail $p }
        # The problems go in the exception too, not just the warning stream.
        # A caller catching this — a script, or a test — should not have to
        # scrape stderr to find out what was actually wrong.
        Stop-Cp ("Refusing to save a registry with those problems: " + ($problems -join '; '))
    }
    Export-CpRegistry $reg

    if ($updating) { Write-CpOk "Updated profile '$Name'" } else { Write-CpOk "Registered profile '$Name'" }

    if ($wantCli) {
        Initialize-CpCliConfigDir $reg $Name
        if ($Auth -eq 'oauth-token') {
            Write-CpHeader 'This profile uses token auth'
            Write-CpSay 'Two costs, decide before you continue:'
            Write-CpSay '  1. A token profile cannot use Remote Control or claude.ai'
            Write-CpSay '     connectors. Local MCP servers still work.'
            Write-CpSay '  2. The token expires after a year.'
            Write-CpSay ''
            Write-CpSay 'On Windows you probably do not need this — -Auth config-dir'
            Write-CpSay 'isolates the login on its own. Token auth is for CI and headless use.'
            Write-CpSay ''
            # Only offer when there is someone to paste a token. Capturing one
            # is inherently interactive, so under automation the offer would
            # be answered yes by CLAUDE_PROFILES_ASSUME_YES and then fail —
            # registering the profile but reporting an error.
            if ([Console]::IsInputRedirected) {
                Write-CpInfo "Run this from a terminal when you are ready: Update-ClaudeProfileToken -Name $Name"
            } elseif (Confirm-CpAction 'Set up the token now?') {
                Update-CpToken $reg $Name
            } else {
                Write-CpInfo "Later: Update-ClaudeProfileToken -Name $Name"
            }
        } else {
            Write-CpHeader 'Log in to this profile'
            Write-CpSay 'CLAUDE_CONFIG_DIR relocates .credentials.json into this profile''s'
            Write-CpSay 'own directory, so the login is isolated by that alone. Just log in:'
            Write-CpSay ''
            Write-CpSay "    Invoke-ClaudeProfile -Name $Name -Arguments /login"
        }
    }

    if ($wantDesktop) {
        Initialize-CpMcpTemplate $Name
        Write-CpSay ''
        Write-CpSay "Desktop: Start-ClaudeProfileDesktop -Name $Name"
        Write-CpSay "         Install-ClaudeProfileLauncher -Name $Name"
    }
}


function Get-ClaudeProfile {
    <#
    .SYNOPSIS
    List registered profiles.
    .PARAMETER Json
    Emit the registry verbatim, in the canonical form the bash implementation
    also produces. This is what tests/registry-contract.sh compares.
    #>
    [CmdletBinding()]
    param([string]$Name, [switch]$Json)

    $reg = Import-CpRegistry

    if ($Json) { return (ConvertTo-CpCanonicalJson $reg) }

    $names = if ($Name) { @($Name) } else { Get-CpProfileNames $reg }
    if ($names.Count -eq 0) {
        Write-CpSay 'No profiles registered yet.'
        Write-CpSay 'Add one with: Add-ClaudeProfile -Name work'
        return
    }

    foreach ($n in $names) {
        if (-not (Test-CpProfileExists $reg $n)) { Stop-Cp "No profile called '$n'." }
        [pscustomobject]@{
            Name        = $n
            Active      = ($env:CLAUDE_ACTIVE_PROFILE -eq $n)
            Cli         = Get-CpValue $reg $n 'cli.configDir' ''
            Auth        = Get-CpValue $reg $n 'cli.auth' ''
            Desktop     = Get-CpValue $reg $n 'desktop.userDataDir' ''
            Mirrored    = (Test-CpDesktopMirrored $reg $n)
            Description = Get-CpValue $reg $n 'description' ''
        }
    }
}


function Remove-ClaudeProfile {
    <#
    .SYNOPSIS
    Unregister a profile, asking separately about each piece of its data.
    .DESCRIPTION
    Your primary account is never touched.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory, Position = 0)][string]$Name)

    $reg = Import-CpRegistry -Required
    if (-not (Test-CpProfileExists $reg $Name)) { Stop-Cp "No profile called '$Name'." }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Remove profile')) { return }

    Write-CpHeader "Removing profile '$Name'"
    Write-CpSay 'Unregistering is separate from deleting data. You will be asked about'
    Write-CpSay 'each piece individually, and your PRIMARY account is never touched.'

    $dir      = Get-CpCliConfigDir $reg $Name
    $udd      = Get-CpDesktopUserDataDir $reg $Name
    $launcher = Expand-CpPath (Get-CpValue $reg $Name 'desktop.launcher' '')
    $app      = Get-CpDesktopAppPath $reg $Name
    $backend  = Get-CpCliTokenBackend $reg $Name

    if ($dir -and (Test-Path -LiteralPath $dir)) {
        Write-CpWarn "$dir holds this profile's session history and project state."
        if (Confirm-CpAction 'Delete it?') { Remove-Item -LiteralPath $dir -Recurse -Force; Write-CpOk "Deleted $dir" }
    }
    if ($udd -and (Test-Path -LiteralPath $udd)) {
        Write-CpWarn "$udd holds this profile's desktop login, chat cache and MCP config."
        Write-CpWarn 'Deleting it means logging in again next time.'
        if (Confirm-CpAction 'Delete it?') { Remove-Item -LiteralPath $udd -Recurse -Force; Write-CpOk "Deleted $udd" }
    }
    if ($launcher -and (Test-Path -LiteralPath $launcher)) {
        if (Confirm-CpAction "Delete the shortcut at $launcher?") { Remove-Item -LiteralPath $launcher -Force; Write-CpOk "Deleted $launcher" }
    }
    if ((Test-CpDesktopMirrored $reg $Name) -and $app) {
        $mirrorRoot = Get-CpMirrorPath $Name
        if (Test-Path -LiteralPath $mirrorRoot) {
            if (Confirm-CpAction "Delete the mirrored app at $mirrorRoot?") {
                Remove-Item -LiteralPath $mirrorRoot -Recurse -Force; Write-CpOk "Deleted $mirrorRoot"
            }
        }
    }
    if (Test-CpSecret -Name $Name -Backend $backend) {
        Write-CpWarn 'Deleting the stored token does NOT revoke it.'
        Write-CpWarn 'To actually revoke it, remove the authorisation in your claude.ai settings.'
        if (Confirm-CpAction 'Delete the stored token?') { Remove-CpSecret -Name $Name -Backend $backend; Write-CpOk 'Deleted the stored token' }
    }
    $template = Get-CpMcpTemplatePath $Name
    if (Test-Path -LiteralPath $template) {
        if (Confirm-CpAction "Delete the MCP template at $template?") { Remove-Item -LiteralPath $template -Force }
    }

    $reg['profiles'].Remove($Name)
    Export-CpRegistry $reg
    Write-CpOk "Unregistered '$Name'"
}


function Invoke-ClaudeProfile {
    <#
    .SYNOPSIS
    Run Claude Code as a profile.
    .EXAMPLE
    Invoke-ClaudeProfile -Name work -Arguments '-p', 'summarise this repo'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments = @()
    )
    $reg = Import-CpRegistry -Required
    Invoke-CpClaude -Registry $reg -Name $Name -Arguments $Arguments
}


function Enter-ClaudeProfile {
    <#
    .SYNOPSIS
    Open a child PowerShell where the plain 'claude' command is this profile.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    $reg = Import-CpRegistry -Required
    Enter-CpProfileShell -Registry $reg -Name $Name
}


function Start-ClaudeProfileDesktop {
    <#
    .SYNOPSIS
    Launch the Claude desktop app on a profile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments = @()
    )
    $reg = Import-CpRegistry -Required
    Start-CpDesktop -Registry $reg -Name $Name -ExtraArgs $Arguments
}


function Install-ClaudeProfileLauncher {
    <#
    .SYNOPSIS
    Create a Start-menu shortcut that launches the desktop app on a profile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [switch]$AlsoOnDesktop
    )
    $reg = Import-CpRegistry -Required
    Install-CpLauncher -Registry $reg -Name $Name -Desktop:$AlsoOnDesktop
}


function New-ClaudeProfileMirror {
    <#
    .SYNOPSIS
    Mirror an MSIX-installed Claude into a writable directory so it can be
    launched with --user-data-dir.
    .DESCRIPTION
    Only needed for the MSIX / Microsoft Store install flavour. The mirror is
    a frozen snapshot that does not auto-update; re-run after each Claude
    update. Invoke-ClaudeProfileDoctor reports when it has fallen behind.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory, Position = 0)][string]$Name)

    $reg = Import-CpRegistry -Required
    if (-not (Test-CpProfileExists $reg $Name)) { Stop-Cp "No profile called '$Name'." }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Mirror the Claude application')) { return }
    New-CpMirror -Registry $reg -Name $Name
}


function Update-ClaudeProfileToken {
    <#
    .SYNOPSIS
    Generate and store a new long-lived OAuth token for a profile.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    $reg = Import-CpRegistry -Required
    if (-not (Test-CpProfileExists $reg $Name)) { Stop-Cp "No profile called '$Name'." }
    Update-CpToken -Registry $reg -Name $Name
}


function Invoke-ClaudeProfileDoctor {
    <#
    .SYNOPSIS
    Health check. Changes nothing and never prints a secret.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name, [switch]$Json)
    Invoke-CpDoctor -Only $Name -Json:$Json
}


function Get-ClaudeProfileStatus {
    <#
    .SYNOPSIS
    Which profile is this session on?
    #>
    [CmdletBinding()]
    param()

    if ($env:CLAUDE_ACTIVE_PROFILE) {
        Write-Output "Profile:     $env:CLAUDE_ACTIVE_PROFILE"
        Write-Output "Config dir:  $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { 'unset' })"
        if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
            Write-Output 'Auth:        CLAUDE_CODE_OAUTH_TOKEN (precedence rank 5)'
        } else {
            Write-Output "Auth:        $env:CLAUDE_CONFIG_DIR\.credentials.json via /login"
        }
    } else {
        Write-Output 'Profile:     primary (default, unmanaged)'
        Write-Output "Config dir:  $(Get-CpPrimaryCliConfigDir)"
        Write-Output "Auth:        $(Get-CpPrimaryCliConfigDir)\.credentials.json via /login"
    }

    if ($env:ANTHROPIC_AUTH_TOKEN) { Write-Output 'WARNING:     ANTHROPIC_AUTH_TOKEN is set and outranks the above' }
    if ($env:ANTHROPIC_API_KEY)    { Write-Output 'WARNING:     ANTHROPIC_API_KEY is set and outranks the above' }

    Write-Output ''
    Write-Output 'For the authoritative answer, run "claude" and use /status — that'
    Write-Output 'reports the account the CLI itself thinks it is using, rather than'
    Write-Output 'what the environment implies.'
}


function Use-ClaudeProfile {
    <#
    .SYNOPSIS
    Switch this PowerShell session to a profile, or write a .claude-profile
    file so it switches automatically.
    .PARAMETER Persist
    Write .claude-profile in the current directory instead of switching now.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [switch]$Persist
    )

    Assert-CpProfileName $Name
    $reg = Import-CpRegistry -Required
    if (-not (Test-CpProfileExists $reg $Name)) {
        Stop-Cp "No profile called '$Name'. See: Get-ClaudeProfile"
    }

    if ($Persist) {
        $target = Join-Path (Get-Location) '.claude-profile'
        if (Test-Path -LiteralPath $target) {
            $current = (Get-Content -LiteralPath $target -TotalCount 1).Trim()
            if ($current -eq $Name) { Write-CpInfo "$target already selects '$Name'"; return }
            if (-not (Confirm-CpAction "$target currently selects '$current'. Overwrite with '$Name'?")) { Stop-Cp 'Aborted.' }
        }
        Set-Content -LiteralPath $target -Value $Name -Encoding UTF8
        Write-CpOk "Wrote $target"
        return
    }

    $env:CLAUDE_CONFIG_DIR     = Get-CpCliConfigDir $reg $Name
    $env:CLAUDE_ACTIVE_PROFILE = $Name
    if ((Get-CpCliAuthMode $reg $Name) -eq 'oauth-token') {
        $env:CLAUDE_CODE_OAUTH_TOKEN = Get-CpSecret -Name $Name -Backend (Get-CpCliTokenBackend $reg $Name)
    } else {
        $env:CLAUDE_CODE_OAUTH_TOKEN = $null
    }
    Write-CpOk "This session is now on '$Name'"
}


function Reset-ClaudeProfile {
    <#
    .SYNOPSIS
    Return this PowerShell session to the primary account.
    #>
    [CmdletBinding()]
    param()
    $env:CLAUDE_CONFIG_DIR       = $null
    $env:CLAUDE_CODE_OAUTH_TOKEN = $null
    $env:CLAUDE_ACTIVE_PROFILE   = $null
    $script:CpAutoSwitched = $false
    Write-CpOk 'Back to the primary account'
}
