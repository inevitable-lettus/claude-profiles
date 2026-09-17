# ClaudeProfiles.psm1
#
# Run several Claude accounts on one Windows machine.
#
# Load order matters: Private before Public, because the public commands are
# thin wrappers over the private helpers.
#
# Importing this module also installs the per-directory auto-switch hook by
# wrapping the `prompt` function. See Register-CpPromptHook at the bottom —
# and read the security note there before changing it, because
# .claude-profile arrives inside repositories you clone.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

foreach ($folder in 'Private', 'Public') {
    $dir = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.ps1' | Sort-Object Name) {
        . $file.FullName
    }
}


# ---------------------------------------------------------------------------
# Per-directory auto-switching
# ---------------------------------------------------------------------------
# PowerShell has no chpwd event, so the hook rides the `prompt` function. It
# short-circuits unless the working directory actually changed, and the walk
# up the tree is plain filesystem checks — no subprocess unless a
# .claude-profile file is actually found and its contents differ from the
# current state.
#
# .claude-profile IS UNTRUSTED INPUT. It arrives inside repositories you
# clone from other people. The rules, enforced here and again in
# Assert-CpProfileName:
#
#   It may ONLY name an already-registered local profile. It may not create
#   one, name a directory, name a token, or cause a login. An unrecognised
#   name warns and leaves you on the primary account — it must never fall
#   through to a DIFFERENT registered profile, because that is exactly the
#   failure this feature exists to prevent.

$script:CpLastPwd = $null
$script:CpAutoSwitched = $false

function Find-CpProfileFile {
    $dir = (Get-Location).ProviderPath
    $depth = 0
    while ($dir -and $depth -lt 40) {
        $candidate = Join-Path $dir '.claude-profile'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        # The repository root is the ceiling: a repo's own file should win,
        # and we should not silently inherit one from outside it.
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { return $null }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
        $depth++
    }
    return $null
}

function Sync-CpDirectoryProfile {
    # A profile chosen deliberately with Use-ClaudeProfile outranks any file
    # on disk. Never clobber an explicit choice.
    if ($env:CLAUDE_ACTIVE_PROFILE -and -not $script:CpAutoSwitched) { return }

    $want = $null
    $file = Find-CpProfileFile
    if ($file) {
        $line = (Get-Content -LiteralPath $file -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($null -ne $line) {
            $candidate = $line.Trim()
            # Validate before the name reaches anything else.
            if ($candidate -cmatch '^[a-z0-9][a-z0-9_-]{0,31}$') {
                $want = $candidate
            } elseif ($candidate) {
                Write-CpWarn "$file names an invalid profile — ignoring."
            }
        }
    }

    if ($want -eq $env:CLAUDE_ACTIVE_PROFILE) { return }

    if (-not $want) {
        if ($script:CpAutoSwitched) {
            $env:CLAUDE_CONFIG_DIR       = $null
            $env:CLAUDE_CODE_OAUTH_TOKEN = $null
            $env:CLAUDE_ACTIVE_PROFILE   = $null
            $script:CpAutoSwitched = $false
        }
        return
    }

    try {
        $reg = Import-CpRegistry
        if (-not (Test-CpProfileExists $reg $want)) {
            Write-CpWarn "$file asks for profile '$want', which is not registered here. Staying on the primary account."
            return
        }
        $env:CLAUDE_CONFIG_DIR     = Get-CpCliConfigDir $reg $want
        $env:CLAUDE_ACTIVE_PROFILE = $want
        if ((Get-CpCliAuthMode $reg $want) -eq 'oauth-token' -and
            $env:CLAUDE_PROFILES_AUTOSWITCH_TOKEN -ne '0') {
            $env:CLAUDE_CODE_OAUTH_TOKEN = Get-CpSecret -Name $want -Backend (Get-CpCliTokenBackend $reg $want)
        } else {
            $env:CLAUDE_CODE_OAUTH_TOKEN = $null
        }
        $script:CpAutoSwitched = $true
    } catch {
        Write-CpWarn "Auto-switch failed: $($_.Exception.Message)"
    }
}

function Register-CpPromptHook {
    # Wrap whatever `prompt` already is rather than replacing it, so this
    # composes with oh-my-posh, Starship and hand-written prompts. Guarded so
    # a re-import does not wrap the wrapper.
    if ($script:CpPromptHooked) { return }
    $script:CpPromptHooked = $true

    $existing = Get-Command prompt -CommandType Function -ErrorAction SilentlyContinue
    $script:CpInnerPrompt = if ($existing) { $existing.ScriptBlock } else { { "PS $(Get-Location)> " } }

    Set-Item -Path function:global:prompt -Value {
        $here = (Get-Location).ProviderPath
        if ($here -ne $script:CpLastPwd) {
            $script:CpLastPwd = $here
            # A broken sync must never break the prompt: an unreadable
            # registry or a vanished secret store would otherwise make the
            # shell unusable rather than just un-switched.
            try { Sync-CpDirectoryProfile } catch { Write-Debug "claude-profiles auto-switch: $_" }
        }
        & $script:CpInnerPrompt
    }
}

if ($env:CLAUDE_PROFILES_NO_PROMPT_HOOK -ne '1') {
    Register-CpPromptHook
}


# `claude-profiles` is exported as an ALIAS, not a function: a function with
# that name makes Import-Module warn about unapproved verbs on every shell
# start. Aliases are not verb-checked.
Set-Alias -Name 'claude-profiles' -Value 'Invoke-ClaudeProfileCommand'

Export-ModuleMember -Function @(
    'Initialize-ClaudeProfiles'
    'Add-ClaudeProfile'
    'Get-ClaudeProfile'
    'Remove-ClaudeProfile'
    'Invoke-ClaudeProfile'
    'Enter-ClaudeProfile'
    'Start-ClaudeProfileDesktop'
    'Install-ClaudeProfileLauncher'
    'New-ClaudeProfileMirror'
    'Update-ClaudeProfileToken'
    'Invoke-ClaudeProfileDoctor'
    'Get-ClaudeProfileStatus'
    'Use-ClaudeProfile'
    'Reset-ClaudeProfile'
    'Invoke-ClaudeProfileCommand'
) -Alias 'claude-profiles'
