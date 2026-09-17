# Private/Common.ps1
#
# Output helpers and small utilities. The counterpart of lib/common.sh.
#
# Human-facing output goes to the information/warning streams, never to the
# success stream. That is the PowerShell equivalent of the bash side's
# "chatter on stderr" rule, and it exists for the same reason: `Get-ClaudeProfile
# -Json` and `Invoke-ClaudeProfileDoctor -Json` have to be able to put clean
# machine-readable text on the pipeline with nothing else mixed in.
# ---------------------------------------------------------------------------

$script:CpUseColour = $Host.UI.SupportsVirtualTerminal -and -not $env:NO_COLOR

function Write-CpLine {
    param([string]$Prefix, [string]$Colour, [string]$Message)
    if ($script:CpUseColour) {
        [Console]::Error.WriteLine("$([char]27)[${Colour}m$Prefix$([char]27)[0m $Message")
    } else {
        [Console]::Error.WriteLine("$Prefix $Message")
    }
}

function Write-CpSay  { param([string]$Message) [Console]::Error.WriteLine($Message) }
function Write-CpOk   { param([string]$Message) Write-CpLine '  OK  ' '32' $Message }
function Write-CpWarn { param([string]$Message) Write-CpLine ' WARN ' '33' $Message }
function Write-CpFail { param([string]$Message) Write-CpLine ' FAIL ' '31' $Message }
function Write-CpInfo { param([string]$Message) Write-CpLine ' INFO ' '34' $Message }

function Write-CpHeader {
    param([string]$Message)
    [Console]::Error.WriteLine('')
    Write-CpLine '===' '1' "$Message ==="
}

function Stop-Cp {
    param([string]$Message)
    throw $Message
}


# Confirm-CpAction — every destructive path goes through here.
#
# Anything other than an explicit yes is a no, including a closed stdin under
# automation. $env:CLAUDE_PROFILES_ASSUME_YES = '1' bypasses it; there is no
# per-command -Force switch, because a switch is too easy to copy out of a
# README without reading what it skips.
function Confirm-CpAction {
    param([Parameter(Mandatory)][string]$Prompt)

    if ($env:CLAUDE_PROFILES_ASSUME_YES -eq '1') {
        Write-CpInfo "$Prompt — assuming yes (CLAUDE_PROFILES_ASSUME_YES=1)"
        return $true
    }

    if ([Console]::IsInputRedirected) {
        Write-CpWarn "$Prompt — no console to ask on, assuming no"
        return $false
    }

    [Console]::Error.Write("$Prompt [y/N] ")
    $reply = [Console]::ReadLine()
    return ($reply -match '^(y|yes)$')
}


# Read-CpSecret — one line with echo suppressed, returned as plain text.
#
# The token has to become a plain string eventually: it is written into a
# child process's environment. Keeping it in a SecureString until the last
# moment buys nothing here and makes the code harder to audit.
function Read-CpSecret {
    param([Parameter(Mandatory)][string]$Prompt)
    [Console]::Error.Write($Prompt)
    $secure = $Host.UI.ReadLineAsSecureString()
    [Console]::Error.WriteLine('')
    if (-not $secure) { return '' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}


function ConvertTo-CpTitleCase {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    return $Value.Substring(0, 1).ToUpperInvariant() + $Value.Substring(1)
}
