# Private/Desktop.ps1
#
# The Claude desktop app half on Windows. This is the part that genuinely
# needs PowerShell rather than bash.
#
# THE SHAPE OF THE PROBLEM
#
#   Direct .exe install    %LOCALAPPDATA%\AnthropicClaude\app-<ver>\claude.exe
#                          Start it with --user-data-dir and you are finished.
#
#   MSIX / Store install   C:\Program Files\WindowsApps\<package>
#                          Windows blocks direct execution out of
#                          WindowsApps, so --user-data-dir cannot be passed
#                          at all. The app-execution alias at
#                          %LOCALAPPDATA%\Microsoft\WindowsApps\Claude.exe
#                          starts the package but does not reliably forward
#                          arguments to it.
#
# For MSIX the app has to be mirrored into a writable directory first, and
# then each profile gets a shortcut pointing at the mirror. That is
# New-ClaudeProfileMirror, and it carries the same cost as its macOS
# counterpart: a frozen copy that stops auto-updating.
#
# WHAT WINDOWS DOES NOT NEED. Electron's safeStorage encrypts with DPAPI and
# keeps the encrypted blob inside the user-data directory. There is no single
# shared credential slot for two profiles to fight over, so there is no
# Keychain round-trip test here and no re-signing. On Windows the risk is
# packaging; on macOS it is credentials.
#
# ONE GOTCHA WORTH KNOWING. The claude:// deep link used by the login flow
# routes to whichever window is focused. Log profiles in one at a time.
# ---------------------------------------------------------------------------

function Test-CpDesktopConfigured {
    param($Registry, [string]$Name)
    return [bool](Get-CpValue $Registry $Name 'desktop.userDataDir' '')
}

function Get-CpDesktopUserDataDir {
    param($Registry, [string]$Name)
    Expand-CpPath (Get-CpValue $Registry $Name 'desktop.userDataDir' '')
}

function Get-CpDesktopAppPath {
    param($Registry, [string]$Name)
    Expand-CpPath (Get-CpValue $Registry $Name 'desktop.appPath' '')
}

function Test-CpDesktopMirrored {
    param($Registry, [string]$Name)
    return ((Get-CpValue $Registry $Name 'desktop.mirrored' 'false') -eq 'true')
}

function Get-CpMirrorPath {
    param([string]$Name)
    Join-Path (Get-CpAppsHome) $Name
}

function Assert-CpDesktopReady {
    param($Registry, [Parameter(Mandatory)][string]$Name)

    if (-not (Test-CpProfileExists $Registry $Name)) {
        Stop-Cp "No profile called '$Name'. See: Get-ClaudeProfile"
    }
    if (-not (Test-CpDesktopConfigured $Registry $Name)) {
        Stop-Cp "Profile '$Name' has no desktop half. Add one with: Add-ClaudeProfile -Name $Name -Desktop"
    }

    $udd = Get-CpDesktopUserDataDir $Registry $Name
    # The single most important check here: pointing a second instance at the
    # primary's directory would let it overwrite the first account's data.
    if ($udd -eq (Get-CpPrimaryDesktopDir)) {
        Stop-Cp "Profile '$Name' points at the PRIMARY user-data directory. Refusing to launch."
    }

    $app = Get-CpDesktopAppPath $Registry $Name
    if (-not $app) { Stop-Cp "Profile '$Name' has no desktop.appPath set." }
    if (-not (Test-Path -LiteralPath $app)) {
        Stop-Cp "Claude is not at $app. Reinstall it, or fix the path with: Add-ClaudeProfile -Name $Name -AppPath <path>"
    }
    if ($script:CpIsWindows -and $app -like "$env:ProgramFiles\WindowsApps\*") {
        Stop-Cp "Profile '$Name' points into C:\Program Files\WindowsApps, which Windows will not let anything execute directly — so --user-data-dir cannot be passed. Run: New-ClaudeProfileMirror -Name $Name"
    }
}


# ---------------------------------------------------------------------------
# Per-profile MCP configuration
# ---------------------------------------------------------------------------
# Each desktop instance reads its own claude_desktop_config.json out of its
# own user-data directory and spawns its own copy of every server listed. Any
# server binding a fixed port therefore fails in whichever instance starts
# second, with no useful runtime symptom.

function Get-CpMcpTemplatePath {
    param([string]$Name)
    Join-Path (Get-CpTemplatesDir) "$Name\claude_desktop_config.json"
}

function Initialize-CpMcpTemplate {
    param([string]$Name)
    $path = Get-CpMcpTemplatePath $Name
    if (Test-Path -LiteralPath $path) { return }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $path -Value "{`n  `"mcpServers`": {}`n}`n" -NoNewline -Encoding UTF8
    Write-CpInfo "Created an MCP config template: $path"
}

function Sync-CpMcpConfig {
    param($Registry, [string]$Name)
    $template = Get-CpMcpTemplatePath $Name
    if (-not (Test-Path -LiteralPath $template)) { return }

    $target = Join-Path (Get-CpDesktopUserDataDir $Registry $Name) 'claude_desktop_config.json'
    if (Test-Path -LiteralPath $target) {
        $a = Get-FileHash -LiteralPath $template -Algorithm SHA256
        $b = Get-FileHash -LiteralPath $target   -Algorithm SHA256
        if ($a.Hash -eq $b.Hash) { return }
    }
    Copy-Item -LiteralPath $template -Destination $target -Force
    Write-CpInfo "Applied MCP config from $template"
}


# ---------------------------------------------------------------------------
# Launching
# ---------------------------------------------------------------------------
function Start-CpDesktop {
    param($Registry, [Parameter(Mandatory)][string]$Name, [string[]]$ExtraArgs = @())

    Assert-CpDesktopReady $Registry $Name

    $udd = Get-CpDesktopUserDataDir $Registry $Name
    $app = Get-CpDesktopAppPath $Registry $Name

    $firstRun = -not (Test-Path -LiteralPath $udd) -or
                -not (Get-ChildItem -LiteralPath $udd -Force -ErrorAction SilentlyContinue)

    if (-not (Test-Path -LiteralPath $udd)) {
        New-Item -ItemType Directory -Path $udd -Force | Out-Null
    }

    Sync-CpMcpConfig $Registry $Name

    Write-CpInfo "Launching Claude for profile '$Name'"
    Write-CpInfo "  app:     $app"
    Write-CpInfo "  profile: $udd"

    # No equivalent of macOS `open -n` is needed: Electron's single-instance
    # lock is keyed to the user-data directory, so a different directory is
    # already a different instance.
    $argList = @("--user-data-dir=$udd") + $ExtraArgs
    Start-Process -FilePath $app -ArgumentList $argList | Out-Null

    if ($firstRun) {
        Write-CpSay ''
        Write-CpSay 'First launch of this profile.'
        Write-CpSay "You will be asked to log in — use the account you want on '$Name'."
        Write-CpSay 'Log profiles in ONE AT A TIME: the claude:// login link routes to'
        Write-CpSay 'whichever window is focused, so two pending logins get crossed.'
    }
}


# ---------------------------------------------------------------------------
# Shortcut launcher (.lnk)
# ---------------------------------------------------------------------------
function Install-CpLauncher {
    param($Registry, [Parameter(Mandatory)][string]$Name, [switch]$Desktop)

    if (-not $script:CpIsWindows) {
        Stop-Cp 'Shortcut creation is Windows-only. On macOS and Linux use the bash entrypoint: claude-profiles install-launcher <name>'
    }

    Assert-CpDesktopReady $Registry $Name

    $app   = Get-CpDesktopAppPath $Registry $Name
    $udd   = Get-CpDesktopUserDataDir $Registry $Name
    $label = 'Claude ' + (ConvertTo-CpTitleCase $Name)

    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    if (-not (Test-Path -LiteralPath $startMenu)) {
        New-Item -ItemType Directory -Path $startMenu -Force | Out-Null
    }
    $target = Join-Path $startMenu "$label.lnk"

    if (Test-Path -LiteralPath $target) {
        if (-not (Confirm-CpAction "$target already exists. Replace it?")) { Stop-Cp 'Aborted.' }
        Remove-Item -LiteralPath $target -Force
    }

    # WScript.Shell is the only supported way to author a .lnk without
    # shipping a binary. It exists on every Windows install.
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($target)
        $link.TargetPath       = $app
        # Quoted: the user-data path routinely contains spaces.
        $link.Arguments        = "--user-data-dir=`"$udd`""
        $link.WorkingDirectory = Split-Path -Parent $app
        $link.IconLocation     = "$app,0"
        $link.Description      = "Claude desktop, '$Name' profile (generated by claude-profiles)"
        $link.Save()
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }

    Write-CpOk "Installed $target"

    if ($Desktop) {
        $desktopDir = [Environment]::GetFolderPath('Desktop')
        Copy-Item -LiteralPath $target -Destination (Join-Path $desktopDir "$label.lnk") -Force
        Write-CpOk "Also placed a shortcut on the Desktop"
    }

    Set-CpValue $Registry $Name 'desktop.launcher' $target
    Export-CpRegistry $Registry

    Write-CpSay "Find it in the Start menu as `"$label`", or pin it to the taskbar."
    Write-CpSay ''
    Write-CpSay 'Note: both instances share one taskbar identity, because they are'
    Write-CpSay 'the same application. The shortcut gives you a separate way to'
    Write-CpSay 'START the second instance, not a separate app identity.'
}


# ---------------------------------------------------------------------------
# Mirroring an MSIX install
# ---------------------------------------------------------------------------
# Windows refuses to execute anything directly out of C:\Program Files\
# WindowsApps, so an MSIX-installed Claude cannot be given --user-data-dir.
# Copying the package payload into a writable directory sidesteps that.
#
# WHAT IT COSTS, and all of it is real:
#
#   1. NO AUTO-UPDATES. The mirror is a frozen snapshot. When Claude updates,
#      the mirror does not, and you re-run this. Invoke-ClaudeProfileDoctor
#      compares the versions and tells you when it has fallen behind.
#   2. Roughly a gigabyte of disk per mirror.
#   3. It may simply not work. Some packaged apps depend on package identity
#      at runtime — for virtualised registry access, for protocol handler
#      registration, or for entitlements that only exist inside the package
#      container. A mirrored copy has none of that. There is no way to know
#      without trying.
#   4. Protocol handlers stay registered to the real package, so claude://
#      links continue to open the ORIGINAL install, not the mirror.
#
# If it fails, the honest answer is to use claude.ai in a separate browser
# profile for the second account and keep the desktop app single-account.
function New-CpMirror {
    param($Registry, [Parameter(Mandatory)][string]$Name)

    if (-not $script:CpIsWindows) {
        Stop-Cp 'Mirroring from PowerShell is Windows-only. On macOS use: claude-profiles mirror-app <name>. Linux never needs it — the credential blob lives inside the user-data directory, so profiles cannot collide.'
    }

    $info = Get-CpInstallFlavour
    if ($info.Flavour -eq 'none') {
        Stop-Cp 'No Claude desktop install found to mirror.'
    }
    if ($info.Flavour -eq 'direct') {
        Write-CpWarn 'This machine has the direct .exe install, which already accepts --user-data-dir.'
        Write-CpWarn 'Mirroring it would only cost you auto-updates for no benefit.'
        if (-not (Confirm-CpAction 'Mirror anyway?')) { Stop-Cp 'Stopped — nothing was changed.' }
    }

    $source = $info.Path
    $target = Get-CpMirrorPath $Name

    Write-CpHeader 'Confirm you need a mirrored app'
    Write-CpSay ''
    Write-CpSay "Source:  $source  (flavour: $($info.Flavour), version $($info.Version))"
    Write-CpSay "Mirror:  $target"
    Write-CpSay ''
    Write-CpSay 'Costs:'
    Write-CpSay '  - The mirror never auto-updates. Re-run this after each Claude update.'
    Write-CpSay '  - Roughly 1GB of disk.'
    Write-CpSay '  - It may not launch at all: a packaged app can depend on package'
    Write-CpSay '    identity, which a plain copy does not have.'
    Write-CpSay '  - claude:// links keep opening the ORIGINAL install, not the mirror.'
    Write-CpSay ''
    if (-not (Confirm-CpAction 'Continue?')) { Stop-Cp 'Stopped — nothing was changed.' }

    if (Test-Path -LiteralPath $target) {
        if (-not (Confirm-CpAction "$target exists. Delete and re-mirror?")) { Stop-Cp 'Aborted.' }
    }
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    Write-CpInfo 'Copying — this takes a minute.'
    # /MIR mirrors and prunes, so a re-run after an update leaves no stale
    # files behind. /NFL /NDL /NJH /NJS keep the output to a summary.
    # Robocopy's exit codes below 8 are all success variants, which is why
    # this cannot just check for 0.
    & robocopy $source $target /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { Stop-Cp "robocopy failed with exit code $rc" }

    $exe = Get-ChildItem -LiteralPath $target -Filter 'claude.exe' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $exe) {
        Stop-Cp "Copied, but no claude.exe was found under $target. The package layout may have changed; please open an issue."
    }

    Write-CpOk "Mirrored to $($exe.FullName)"

    Set-CpValue $Registry $Name 'desktop.appPath' $exe.FullName
    Set-CpValue $Registry $Name 'desktop.mirrored' 'true'
    Export-CpRegistry $Registry

    Write-CpSay ''
    Write-CpSay 'Next:'
    Write-CpSay "  Install-ClaudeProfileLauncher -Name $Name"
    Write-CpSay "  Start-ClaudeProfileDesktop -Name $Name"
    Write-CpSay ''
    Write-CpSay 'MAINTENANCE: re-run this after each Claude update.'
    Write-CpSay 'Invoke-ClaudeProfileDoctor reports when the mirror has fallen behind.'
}
