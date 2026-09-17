# Private/Secrets.ps1
#
# Storage for the long-lived OAuth token. Only ever used by an `oauth-token`
# profile — and on Windows that is the unusual case, because
# CLAUDE_CONFIG_DIR relocates .credentials.json and Claude Code manages the
# credential itself. Most Windows profiles never touch this file at all.
#
# It matters for two situations that do arise on Windows:
#   - CI and headless runs, where there is no browser to log in with.
#   - A registry synced from a Mac, where oauth-token is the default.
#
# BACKEND: DPAPI. ConvertFrom-SecureString on Windows encrypts with the
# current user's DPAPI key, so the resulting text is useless to another user
# account on the same machine and useless on a different machine. It is
# written to a file whose ACL is stripped to the current user only.
#
# On PowerShell 7 running on macOS or Linux there is no DPAPI, and
# ConvertFrom-SecureString falls back to a random per-call key that is not
# persisted — which would silently produce unrecoverable data. So those
# platforms get the plain-file backend instead, and are told so. In practice
# the bash implementation is the real one there anyway.
# ---------------------------------------------------------------------------

function Get-CpSecretPath {
    param([Parameter(Mandatory)][string]$Name, [string]$Backend = 'dpapi')
    $ext = if ($Backend -eq 'dpapi') { 'dpapi' } else { 'token' }
    Join-Path (Get-CpSecretsDir) "$Name.$ext"
}

function Get-CpDefaultSecretBackend {
    if (-not $script:CpIsWindows) { return 'file' }
    return 'dpapi'
}

function Get-CpSecretBackendLabel {
    param([string]$Backend)
    switch ($Backend) {
        'dpapi' { 'Windows DPAPI (user-scoped file)' }
        'file'  { 'plain file, user-only ACL' }
        default { $Backend }
    }
}

function Initialize-CpSecretsDir {
    $dir = Get-CpSecretsDir
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Protect-CpUserOnlyPath $dir
}

function Set-CpSecret {
    # PSScriptAnalyzer flags ConvertTo-SecureString -AsPlainText as unsafe.
    # Here it is the entire point: the token arrives as plaintext, because a
    # human pasted it, and this is the step that encrypts it with DPAPI for
    # storage. The rule targets code that hardcodes a password. Suppressing it
    # with a stated reason is more honest than restructuring around it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'Encrypting a user-supplied plaintext token with DPAPI is the purpose of this function.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [string]$Backend = 'dpapi'
    )
    Initialize-CpSecretsDir
    $path = Get-CpSecretPath -Name $Name -Backend $Backend

    if ($Backend -eq 'dpapi') {
        if (-not $script:CpIsWindows) {
            # Off Windows there is no DPAPI, and ConvertFrom-SecureString
            # falls back to a random per-call key that is never persisted —
            # which would write data nobody can ever decrypt. Refuse rather
            # than silently producing garbage.
            Stop-Cp 'The dpapi backend needs Windows. Use -Backend file, or the bash implementation.'
        }
        $encrypted = ConvertTo-SecureString -String $Value -AsPlainText -Force |
            ConvertFrom-SecureString
        Set-Content -LiteralPath $path -Value $encrypted -NoNewline -Encoding ASCII
    } else {
        Set-Content -LiteralPath $path -Value $Value -NoNewline -Encoding UTF8
    }

    Protect-CpUserOnlyPath $path
}

function Get-CpSecret {
    param([Parameter(Mandatory)][string]$Name, [string]$Backend = 'dpapi')
    $path = Get-CpSecretPath -Name $Name -Backend $Backend
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    if ($Backend -ne 'dpapi') {
        return (Get-Content -LiteralPath $path -Raw).Trim()
    }

    try {
        $secure = (Get-Content -LiteralPath $path -Raw).Trim() | ConvertTo-SecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try   { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch {
        # DPAPI refuses to decrypt data encrypted by a different user or on a
        # different machine. That is the mechanism working, not a bug — say
        # what it means rather than surfacing a CryptographicException.
        Write-CpWarn "Could not decrypt the token for '$Name'. DPAPI data is bound to one Windows user on one machine, so a copied or synced secrets file will not work here. Fix: Update-ClaudeProfileToken -Name $Name"
        return $null
    }
}

function Test-CpSecret {
    param([Parameter(Mandatory)][string]$Name, [string]$Backend = 'dpapi')
    $path = Get-CpSecretPath -Name $Name -Backend $Backend
    return (Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Length -gt 0)
}

function Remove-CpSecret {
    param([Parameter(Mandatory)][string]$Name, [string]$Backend = 'dpapi')
    $path = Get-CpSecretPath -Name $Name -Backend $Backend
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

# Test-CpPrimaryLogin — informational only. We never touch the primary
# account's credential.
function Test-CpPrimaryLogin {
    Test-Path -LiteralPath (Join-Path (Get-CpPrimaryCliConfigDir) '.credentials.json')
}
