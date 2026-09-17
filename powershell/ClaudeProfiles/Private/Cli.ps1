# Private/Cli.ps1
#
# Running Claude Code as a profile on Windows.
#
# THIS IS THE EASY HALF ON WINDOWS, and it is worth being explicit about why,
# because the macOS documentation for this tool is full of Keychain
# workarounds that do not apply here. From the authentication docs:
#
#   "On Windows, credentials are stored in
#    %USERPROFILE%\.claude\.credentials.json [...] If you've set the
#    CLAUDE_CONFIG_DIR environment variable on Linux or Windows, the
#    .credentials.json file lives under that directory instead."
#
# So CLAUDE_CONFIG_DIR isolates the login by itself. Two directories, two
# `/login` runs, done. No token, no expiry, no lost Remote Control, no lost
# claude.ai connectors.
#
# The oauth-token mode still exists here for CI, for headless runs, and for a
# registry synced from a Mac — but it is opt-in on Windows rather than the
# default.
# ---------------------------------------------------------------------------

$script:CpTokenLifetimeDays = 365
$script:CpTokenWarnAfterDays = 335

function Test-CpCliConfigured {
    param($Registry, [string]$Name)
    return [bool](Get-CpValue $Registry $Name 'cli.configDir' '')
}

function Get-CpCliConfigDir {
    param($Registry, [string]$Name)
    Expand-CpPath (Get-CpValue $Registry $Name 'cli.configDir' '')
}

function Get-CpCliAuthMode {
    param($Registry, [string]$Name)
    Get-CpValue $Registry $Name 'cli.auth' (Get-CpDefaultAuthMode)
}

function Get-CpCliTokenBackend {
    param($Registry, [string]$Name)
    Get-CpValue $Registry $Name 'cli.tokenBackend' (Get-CpDefaultSecretBackend)
}

function Initialize-CpCliConfigDir {
    param($Registry, [string]$Name)
    $dir = Get-CpCliConfigDir $Registry $Name
    if (-not $dir) { Stop-Cp "Profile '$Name' has no cli.configDir" }
    if ($dir -eq (Get-CpPrimaryCliConfigDir)) {
        Stop-Cp "Refusing to use $dir — that is the primary account's config directory."
    }
    if (Test-Path -LiteralPath $dir) {
        Write-CpInfo "Config directory already exists: $dir"
    } else {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Protect-CpUserOnlyPath $dir
        Write-CpOk "Created $dir (current user only)"
    }
}


# ---------------------------------------------------------------------------
# Token lifecycle
# ---------------------------------------------------------------------------

function Get-CpTokenAgeDays {
    param($Registry, [string]$Name)
    $created = Get-CpValue $Registry $Name 'cli.tokenCreated' ''
    if (-not $created) { return $null }
    try { return [int]((Get-Date) - [datetime]::ParseExact($created, 'yyyy-MM-dd', $null)).TotalDays }
    catch { return $null }
}

function Write-CpTokenExpiryWarning {
    param($Registry, [string]$Name)
    $age = Get-CpTokenAgeDays $Registry $Name
    if ($null -eq $age) { return }
    if ($age -ge $script:CpTokenLifetimeDays) {
        Write-CpWarn "Profile '$Name': token is $age days old and has almost certainly expired. Refresh: Update-ClaudeProfileToken -Name $Name"
    } elseif ($age -ge $script:CpTokenWarnAfterDays) {
        Write-CpWarn "Profile '$Name': token is $age days old — expires in about $($script:CpTokenLifetimeDays - $age) days."
    }
}

function Update-CpToken {
    param($Registry, [Parameter(Mandatory)][string]$Name)

    # Capturing a token needs a human to paste one. Without a console this
    # would block forever on ReadLineAsSecureString — and it is reachable
    # under automation, because CLAUDE_PROFILES_ASSUME_YES answers the "set up
    # the token now?" prompt with yes. That variable means "do not ask me to
    # confirm destructive things", not "invent a credential".
    if ([Console]::IsInputRedirected) {
        Stop-Cp "Cannot capture a token without an interactive console. Run 'Update-ClaudeProfileToken -Name $Name' from a terminal, or set CLAUDE_CODE_OAUTH_TOKEN directly for CI."
    }

    $backend = Get-CpCliTokenBackend $Registry $Name

    if (Test-CpSecret -Name $Name -Backend $backend) {
        if (-not (Confirm-CpAction "A token is already stored for '$Name'. Replace it?")) {
            Write-CpInfo 'Keeping the existing token.'
            return
        }
    }

    Write-CpSay ''
    Write-CpSay 'Do this now, in a SEPARATE terminal window:'
    Write-CpSay ''
    Write-CpSay '    claude setup-token'
    Write-CpSay ''
    Write-CpSay "  A browser opens. Log in with the account you want on '$Name' —"
    Write-CpSay '  not the one your plain `claude` command uses. Approve access.'
    Write-CpSay '  The token then prints in that terminal. Copy it.'
    Write-CpSay ''
    Write-CpSay '  If the browser signs you in as the wrong account automatically,'
    Write-CpSay '  open the URL in a private window, or sign out of claude.ai first.'
    Write-CpSay ''

    if (-not [Console]::IsInputRedirected) {
        [Console]::Error.Write('Press Enter once you have the token copied... ')
        [void][Console]::ReadLine()
    }

    $token = Read-CpSecret 'Paste the token (input hidden), then Enter: '
    if (-not $token) { Stop-Cp 'No token entered. Nothing was changed.' }

    # An observed convention, not a documented guarantee — so a warning
    # rather than a hard failure.
    if ($token.StartsWith('sk-ant-oat')) { Write-CpOk 'Token format looks right' }
    else { Write-CpWarn "Token does not start with 'sk-ant-oat'. Did you paste the right thing?" }

    Set-CpSecret -Name $Name -Value $token -Backend $backend
    Write-CpOk "Token stored in $(Get-CpSecretBackendLabel $backend)"

    Set-CpValue $Registry $Name 'cli.tokenBackend' $backend
    Set-CpValue $Registry $Name 'cli.tokenCreated' (Get-Date -Format 'yyyy-MM-dd')
    Export-CpRegistry $Registry

    Write-CpInfo "Recorded $(Get-Date -Format 'yyyy-MM-dd') — expires in about a year."
}


# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

function Assert-CpCliReady {
    param($Registry, [Parameter(Mandatory)][string]$Name)

    if (-not (Test-CpProfileExists $Registry $Name)) {
        Stop-Cp "No profile called '$Name'. See: Get-ClaudeProfile"
    }
    if (-not (Test-CpCliConfigured $Registry $Name)) {
        Stop-Cp "Profile '$Name' has no CLI half. Add one with: Add-ClaudeProfile -Name $Name -Cli"
    }

    $dir = Get-CpCliConfigDir $Registry $Name
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-CpWarn "Config directory $dir does not exist yet — creating it."
        Initialize-CpCliConfigDir $Registry $Name
    }

    if ((Get-CpCliAuthMode $Registry $Name) -eq 'oauth-token') {
        $backend = Get-CpCliTokenBackend $Registry $Name
        if (-not (Test-CpSecret -Name $Name -Backend $backend)) {
            Stop-Cp "Profile '$Name' uses token auth but no token is stored in $(Get-CpSecretBackendLabel $backend). Run: Update-ClaudeProfileToken -Name $Name"
        }
    }
}

# Write-CpPrecedenceWarning
#
# Claude Code's documented precedence: 1 cloud provider, 2
# ANTHROPIC_AUTH_TOKEN, 3 ANTHROPIC_API_KEY, 4 apiKeyHelper, 5
# CLAUDE_CODE_OAUTH_TOKEN, 6 /login. Anything in 1-4 beats a profile token,
# and that is the most common reason for "it ran as the wrong account".
function Write-CpPrecedenceWarning {
    param([string]$AuthMode)
    if ($AuthMode -ne 'oauth-token') { return }
    if ($env:ANTHROPIC_AUTH_TOKEN) {
        Write-CpWarn 'ANTHROPIC_AUTH_TOKEN is set (rank 2) and will outrank this profile''s token.'
    }
    if ($env:ANTHROPIC_API_KEY) {
        Write-CpWarn 'ANTHROPIC_API_KEY is set (rank 3) and will outrank this profile''s token.'
    }
}

# Invoke-CpClaude
#
# The environment is applied to the child process only. PowerShell has no
# `VAR=value command` prefix form, so the variables are set, the child is run
# synchronously, and they are restored in a finally block — which also runs
# on Ctrl-C.
function Invoke-CpClaude {
    param(
        $Registry,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @()
    )

    Assert-CpCliReady $Registry $Name
    $dir  = Get-CpCliConfigDir $Registry $Name
    $auth = Get-CpCliAuthMode $Registry $Name

    Write-CpPrecedenceWarning $auth

    # Bare mode does not read CLAUDE_CODE_OAUTH_TOKEN, so under a token
    # profile it silently falls through to the primary account's login.
    if ($auth -eq 'oauth-token' -and ($Arguments -contains '--bare')) {
        Write-CpWarn "'--bare' does not read CLAUDE_CODE_OAUTH_TOKEN, so this will NOT run as '$Name'."
        Write-CpInfo 'Bare mode needs ANTHROPIC_API_KEY or an apiKeyHelper instead.'
    }

    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claude) { Stop-Cp "The 'claude' CLI is not on your PATH." }

    $saved = @{
        CLAUDE_CONFIG_DIR       = $env:CLAUDE_CONFIG_DIR
        CLAUDE_CODE_OAUTH_TOKEN = $env:CLAUDE_CODE_OAUTH_TOKEN
        CLAUDE_ACTIVE_PROFILE   = $env:CLAUDE_ACTIVE_PROFILE
    }
    try {
        $env:CLAUDE_CONFIG_DIR     = $dir
        $env:CLAUDE_ACTIVE_PROFILE = $Name
        if ($auth -eq 'oauth-token') {
            Write-CpTokenExpiryWarning $Registry $Name
            $token = Get-CpSecret -Name $Name -Backend (Get-CpCliTokenBackend $Registry $Name)
            if (-not $token) { Stop-Cp "Could not read the token for '$Name'." }
            $env:CLAUDE_CODE_OAUTH_TOKEN = $token
        } else {
            $env:CLAUDE_CODE_OAUTH_TOKEN = $null
        }

        & $claude.Source @Arguments
        return $LASTEXITCODE
    } finally {
        # Restore unconditionally, including on Ctrl-C, so a token can never
        # outlive the command that needed it.
        $env:CLAUDE_CONFIG_DIR       = $saved.CLAUDE_CONFIG_DIR
        $env:CLAUDE_CODE_OAUTH_TOKEN = $saved.CLAUDE_CODE_OAUTH_TOKEN
        $env:CLAUDE_ACTIVE_PROFILE   = $saved.CLAUDE_ACTIVE_PROFILE
    }
}

# Enter-CpProfileShell — a child PowerShell where plain `claude` is this profile.
function Enter-CpProfileShell {
    param($Registry, [Parameter(Mandatory)][string]$Name)

    Assert-CpCliReady $Registry $Name
    $dir  = Get-CpCliConfigDir $Registry $Name
    $auth = Get-CpCliAuthMode $Registry $Name
    Write-CpPrecedenceWarning $auth

    $saved = @{
        CLAUDE_CONFIG_DIR       = $env:CLAUDE_CONFIG_DIR
        CLAUDE_CODE_OAUTH_TOKEN = $env:CLAUDE_CODE_OAUTH_TOKEN
        CLAUDE_ACTIVE_PROFILE   = $env:CLAUDE_ACTIVE_PROFILE
    }
    try {
        $env:CLAUDE_CONFIG_DIR     = $dir
        $env:CLAUDE_ACTIVE_PROFILE = $Name
        if ($auth -eq 'oauth-token') {
            Write-CpTokenExpiryWarning $Registry $Name
            $env:CLAUDE_CODE_OAUTH_TOKEN = Get-CpSecret -Name $Name -Backend (Get-CpCliTokenBackend $Registry $Name)
            Write-CpInfo 'CLAUDE_CODE_OAUTH_TOKEN is set inside this subshell — anything you run in it can read the token.'
        } else {
            $env:CLAUDE_CODE_OAUTH_TOKEN = $null
        }

        Write-CpSay "Entering the '$Name' profile. Type 'exit' to leave."
        $host_exe = (Get-Process -Id $PID).Path
        & $host_exe -NoLogo -NoExit -Command "function prompt { '($Name) PS ' + (Get-Location) + '> ' }"
    } finally {
        $env:CLAUDE_CONFIG_DIR       = $saved.CLAUDE_CONFIG_DIR
        $env:CLAUDE_CODE_OAUTH_TOKEN = $saved.CLAUDE_CODE_OAUTH_TOKEN
        $env:CLAUDE_ACTIVE_PROFILE   = $saved.CLAUDE_ACTIVE_PROFILE
        Write-CpSay 'Back to the primary profile.'
    }
}
