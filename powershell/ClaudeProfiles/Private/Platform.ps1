# Private/Platform.ps1
#
# Paths and platform facts. The counterpart of lib/platform.sh — and it must
# agree with it exactly, because a Git Bash user and a PowerShell user on the
# same Windows machine share one registry.
#
# THE WINDOWS FACT THAT SHAPES THIS FILE
# --------------------------------------
# There are two Claude desktop install flavours on Windows and they need
# completely different handling:
#
#   Direct .exe installer
#     %LOCALAPPDATA%\AnthropicClaude\app-<version>\claude.exe
#     user data in %APPDATA%\Claude
#     --user-data-dir works. Launch it and you are done.
#
#   MSIX / Microsoft Store / enterprise deployment
#     C:\Program Files\WindowsApps\<package>\...
#     user data in %LOCALAPPDATA%\Packages\<pfn>\LocalCache\Roaming\Claude
#     Windows refuses to execute anything directly out of WindowsApps, so
#     there is no way to pass --user-data-dir at all. The app-execution alias
#     at %LOCALAPPDATA%\Microsoft\WindowsApps\Claude.exe launches the package
#     but does not reliably forward arguments to it.
#
# The MSIX flavour therefore needs the app mirrored into a writable directory
# first. That is New-ClaudeProfileMirror, and it carries the same costs as its
# macOS equivalent: a frozen copy that stops auto-updating.
#
# THE CREDENTIAL SITUATION IS BETTER THAN macOS. Electron's safeStorage on
# Windows encrypts with DPAPI and keeps the encrypted blob inside the
# user-data directory. There is no single shared credential slot for two
# profiles to fight over, so no round-trip test and no Keychain workaround.
# On Windows the risk is packaging, not credentials.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Which OS is this?
# ---------------------------------------------------------------------------
# The module targets Windows, but it must run correctly on macOS and Linux
# too: PowerShell 7 exists there, and tests/registry-contract.sh imports this
# module on all three platforms to compare its output against the bash
# implementation. A module that only worked on Windows would make that check
# impossible to run anywhere it matters.
#
# $IsWindows / $IsMacOS / $IsLinux are PowerShell Core automatic variables.
# Windows PowerShell 5.1 does not define them at all — and 5.1 only ever runs
# on Windows — so $null means Windows.
$script:CpIsWindows = if ($null -eq $IsWindows) { $true } else { [bool]$IsWindows }
$script:CpIsMacOS   = if ($null -eq $IsMacOS)   { $false } else { [bool]$IsMacOS }
$script:CpIsLinux   = if ($null -eq $IsLinux)   { $false } else { [bool]$IsLinux }

function Get-CpPlatformId {
    if ($script:CpIsWindows) { return 'windows' }
    if ($script:CpIsMacOS)   { return 'macos' }
    if ($script:CpIsLinux)   { return 'linux' }
    return 'unknown'
}

# Get-CpHome — the user's home directory, on any platform.
#
# $HOME is reliable in PowerShell everywhere; $env:USERPROFILE is Windows-only
# and is null elsewhere, which is exactly the kind of silent null that turns
# into "Cannot bind argument to parameter 'Path'" three frames away.
function Get-CpHome { if ($HOME) { $HOME } else { $env:USERPROFILE } }

function Get-CpXdgConfigHome {
    if ($env:XDG_CONFIG_HOME) { return $env:XDG_CONFIG_HOME }
    return (Join-Path (Get-CpHome) '.config')
}

function Get-CpStateHome {
    if ($env:CLAUDE_PROFILES_HOME) { return $env:CLAUDE_PROFILES_HOME }
    if ($script:CpIsWindows) { return (Join-Path $env:APPDATA 'claude-profiles') }
    return (Join-Path (Get-CpXdgConfigHome) 'claude-profiles')
}

function Get-CpRegistryPath   { Join-Path (Get-CpStateHome) 'profiles.json' }
function Get-CpTemplatesDir   { Join-Path (Get-CpStateHome) 'profiles' }
function Get-CpSecretsDir     { Join-Path (Get-CpStateHome) 'secrets' }

# Mirrors are about a gigabyte. On Windows %APPDATA% roams and %LOCALAPPDATA%
# does not, so a mirror must never land in the state home there.
function Get-CpAppsHome {
    if ($script:CpIsWindows) { return (Join-Path $env:LOCALAPPDATA 'claude-profiles\apps') }
    return (Join-Path (Get-CpStateHome) 'apps')
}

function Get-CpPrimaryCliConfigDir { Join-Path (Get-CpHome) '.claude' }

function Get-CpPrimaryDesktopDir {
    switch (Get-CpPlatformId) {
        'windows' { Join-Path $env:APPDATA 'Claude' }
        'macos'   { Join-Path (Get-CpHome) 'Library/Application Support/Claude' }
        default   { Join-Path (Get-CpXdgConfigHome) 'Claude' }
    }
}

function Get-CpDefaultCliConfigDir {
    param([Parameter(Mandatory)][string]$Name)
    Join-Path (Get-CpHome) ".claude-$Name"
}

function Get-CpDefaultDesktopDir {
    param([Parameter(Mandatory)][string]$Name)
    $pretty = 'Claude-' + (ConvertTo-CpTitleCase $Name)
    switch (Get-CpPlatformId) {
        'windows' { Join-Path $env:APPDATA $pretty }
        'macos'   { Join-Path (Get-CpHome) "Library/Application Support/$pretty" }
        default   { Join-Path (Get-CpXdgConfigHome) $pretty }
    }
}

# Get-CpDefaultAuthMode
#
# Must agree with platform_default_auth_mode() in lib/platform.sh, or a
# registry written on one implementation would be wrong on the other.
#
# config-dir everywhere. On Windows and Linux, CLAUDE_CONFIG_DIR relocates
# .credentials.json; on macOS, current Claude Code keys its Keychain item to
# the config directory. Either way the variable isolates the login by itself.
function Get-CpDefaultAuthMode {
    return 'config-dir'
}


# ---------------------------------------------------------------------------
# Finding the installed app
# ---------------------------------------------------------------------------

# Get-CpAppxClaude — the MSIX package, if there is one.
#
# The Appx module is a Windows PowerShell component. PowerShell 7 can reach it
# through the compatibility layer, but that is slow and noisy, so it is only
# attempted once and cached.
function Get-CpAppxClaude {
    if ($script:CpAppxProbed) { return $script:CpAppxPackage }
    $script:CpAppxProbed = $true
    $script:CpAppxPackage = $null

    if (-not $script:CpIsWindows) { return $null }

    try {
        if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
            Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop
        }
        $script:CpAppxPackage = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue |
            Select-Object -First 1
    } catch {
        # No Appx module, or the compatibility layer is unavailable. Not an
        # error: it just means the install is not MSIX, or we cannot tell.
        $script:CpAppxPackage = $null
    }
    return $script:CpAppxPackage
}

# Get-CpDirectInstall — the newest %LOCALAPPDATA%\AnthropicClaude\app-* build.
function Get-CpDirectInstall {
    # Windows-only by definition. Off Windows %LOCALAPPDATA% is unset, and
    # Join-Path with a null root throws several frames from the real cause.
    if (-not $script:CpIsWindows) { return $null }

    $base = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    if (-not (Test-Path -LiteralPath $base)) { return $null }

    $candidate = Get-ChildItem -LiteralPath $base -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Sort-Object { try { [version](($_.Name -replace '^app-', '') -replace '[^0-9.].*$', '') } catch { [version]'0.0' } } |
        Select-Object -Last 1
    if (-not $candidate) { return $null }

    $exe = Join-Path $candidate.FullName 'claude.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    return $null
}

# Get-CpInstallFlavour — what we are dealing with.
#
# Returns an object with:
#   Flavour   'direct' | 'msix' | 'none'
#   Path      the executable (direct) or the package install location (msix)
#   Version   best-effort version string
#   Launchable  whether --user-data-dir can be passed without mirroring first
function Get-CpInstallFlavour {
    # Desktop discovery on macOS and Linux belongs to the bash implementation.
    # Reporting 'none' here keeps `Add-ClaudeProfile` and `doctor` working
    # under pwsh on those platforms — which the contract test needs — without
    # this module pretending to manage a desktop app it cannot launch.
    if (-not $script:CpIsWindows) {
        return [pscustomobject]@{ Flavour = 'none'; Path = $null; Version = $null; Launchable = $false }
    }

    $direct = Get-CpDirectInstall
    if ($direct) {
        $version = 'unknown'
        # Version is cosmetic — used only for staleness reporting — so a
        # failure here must not stop us returning a usable path.
        try { $version = (Get-Item -LiteralPath $direct).VersionInfo.ProductVersion }
        catch { Write-Debug "could not read version of ${direct}: $_" }
        return [pscustomobject]@{
            Flavour    = 'direct'
            Path       = $direct
            Version    = $version
            Launchable = $true
        }
    }

    $appx = Get-CpAppxClaude
    if ($appx) {
        return [pscustomobject]@{
            Flavour    = 'msix'
            Path       = $appx.InstallLocation
            Version    = $appx.Version
            Launchable = $false
        }
    }

    return [pscustomobject]@{
        Flavour = 'none'; Path = $null; Version = $null; Launchable = $false
    }
}

# Find-CpClaudeApp — a launchable executable, or $null.
function Find-CpClaudeApp {
    $info = Get-CpInstallFlavour
    if ($info.Flavour -eq 'direct') { return $info.Path }
    return $null
}


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# The registry stores paths with a leading ~ where it can, so a synced
# dotfiles repository is portable between machines. On Windows that is a
# little unusual to look at but it keeps one format across all three
# platforms, and one format is one fewer thing to get wrong.

function Expand-CpPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path -eq '~') { return $HOME }
    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        return (Join-Path $HOME $Path.Substring(2))
    }
    return $Path
}

function Compress-CpPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    if ($Path -eq $HOME) { return '~' }
    if ($Path.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) {
        # Always store with forward slashes so bash and PowerShell produce the
        # same registry text for the same directory.
        $rest = $Path.Substring($HOME.Length).TrimStart('\', '/')
        return '~/' + ($rest -replace '\\', '/')
    }
    return $Path
}
