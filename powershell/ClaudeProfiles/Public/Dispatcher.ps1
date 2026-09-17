# Public/Dispatcher.ps1
#
# `claude-profiles <subcommand>` — the same command surface as the bash
# entrypoint, so the README and every doc page read the same on all three
# platforms and nobody has to translate between them.
#
# This is a thin front end. Every branch calls the corresponding Verb-Noun
# cmdlet; there is no second implementation to keep in step.
# ---------------------------------------------------------------------------

# Invoke-ClaudeProfileCommand — the dispatcher, exported as `claude-profiles`.
#
# Two things about this signature are deliberate:
#
#   No [CmdletBinding()] and no declared parameters. The arguments are
#   CLI-shaped — `--json`, `--no-desktop`, `--auth config-dir`. With
#   CmdletBinding, PowerShell tries to bind anything starting with a dash as a
#   parameter name and errors out before the body runs. An empty signature
#   puts every token in $args verbatim, which is what a subcommand dispatcher
#   needs.
#
#   The real name is Verb-Noun, with `claude-profiles` as an alias. Exporting
#   a function literally called `claude-profiles` makes Import-Module print an
#   "unapproved verbs" warning on every shell start. Aliases are not
#   verb-checked, so this gets the portable spelling without the noise.
function Invoke-ClaudeProfileCommand {
    $argv = @($args | ForEach-Object { [string]$_ })

    $cmd  = if ($argv.Count -gt 0) { $argv[0] } else { '' }
    $rest = if ($argv.Count -gt 1) { @($argv[1..($argv.Count - 1)]) } else { @() }

    # Split the remaining arguments into positional values and flags once,
    # rather than in every branch.
    $positional = @($rest | Where-Object { $_ -notlike '-*' })
    $flags      = @($rest | Where-Object { $_ -like '-*' })
    $first      = if ($positional.Count -gt 0) { $positional[0] } else { $null }
    $hasFlag    = { param($f) $flags -contains $f }

    switch ($cmd) {
        '' { Show-CpUsage; return }
        { $_ -in '-h', '--help', 'help' } { Show-CpUsage; return }
        { $_ -in '-V', '--version', 'version' } {
            Write-Output "claude-profiles $((Get-Module ClaudeProfiles).Version) (PowerShell module)"
            return
        }

        'init'   { Initialize-ClaudeProfiles; return }

        'add' {
            if (-not $first) { Stop-Cp 'usage: claude-profiles add <name> [options]' }
            $params = @{ Name = $first }
            # Mirror the bash flag spellings so the docs are portable.
            for ($i = 0; $i -lt $rest.Count; $i++) {
                switch ($rest[$i]) {
                    '--cli'            { $params['Cli'] = $true }
                    '--no-cli'         { $params['NoCli'] = $true }
                    '--desktop'        { $params['Desktop'] = $true }
                    '--no-desktop'     { $params['NoDesktop'] = $true }
                    '--auth'           { $params['Auth'] = $rest[++$i] }
                    '--config-dir'     { $params['ConfigDir'] = $rest[++$i] }
                    '--user-data-dir'  { $params['UserDataDir'] = $rest[++$i] }
                    '--app-path'       { $params['AppPath'] = $rest[++$i] }
                    '--description'    { $params['Description'] = $rest[++$i] }
                }
            }
            Add-ClaudeProfile @params
            return
        }

        { $_ -in 'list', 'ls' } {
            if (& $hasFlag '--json') { Get-ClaudeProfile -Json } else { Get-ClaudeProfile | Format-Table -AutoSize }
            return
        }

        { $_ -in 'remove', 'rm' } {
            if (-not $first) { Stop-Cp 'usage: claude-profiles remove <name>' }
            Remove-ClaudeProfile -Name $first
            return
        }

        'run' {
            if (-not $first) { Stop-Cp 'usage: claude-profiles run <name> [-- args...]' }
            # Everything after the profile name, minus one separating '--'.
            # Ranges are built explicitly rather than with $a[$i..$a.Count],
            # which silently wraps when the start index is past the end.
            $idx = [Array]::IndexOf($rest, $first)
            $tail = @()
            for ($i = $idx + 1; $i -lt $rest.Count; $i++) {
                if ($i -eq $idx + 1 -and $rest[$i] -eq '--') { continue }
                $tail += $rest[$i]
            }
            Invoke-ClaudeProfile -Name $first -Arguments $tail
            return
        }

        'shell' {
            if (-not $first) { Stop-Cp 'usage: claude-profiles shell <name>' }
            Enter-ClaudeProfile -Name $first; return
        }

        'desktop' {
            if (-not $first) { Stop-Cp 'usage: claude-profiles desktop <name>' }
            Start-ClaudeProfileDesktop -Name $first; return
        }

        'install-launcher' {
            if (-not $first) { Stop-Cp 'usage: claude-profiles install-launcher <name>' }
            Install-ClaudeProfileLauncher -Name $first -AlsoOnDesktop:(& $hasFlag '--desktop-shortcut')
            return
        }

        'mirror-app' {
            if (-not $first) { Stop-Cp 'usage: claude-profiles mirror-app <name>' }
            New-ClaudeProfileMirror -Name $first; return
        }

        'mcp-config' {
            if (-not $first) { Stop-Cp 'usage: claude-profiles mcp-config <name>' }
            Initialize-CpMcpTemplate $first
            Write-Output (Get-CpMcpTemplatePath $first)
            return
        }

        'token' {
            if ($first -ne 'refresh' -or $positional.Count -lt 2) {
                Stop-Cp 'usage: claude-profiles token refresh <name>'
            }
            Update-ClaudeProfileToken -Name $positional[1]; return
        }

        'doctor' {
            Invoke-ClaudeProfileDoctor -Name $first -Json:(& $hasFlag '--json'); return
        }

        'whoami' { Get-ClaudeProfileStatus; return }

        'prompt' {
            if (& $hasFlag '--help') { Show-CpPromptHelp; return }
            Write-Output $env:CLAUDE_ACTIVE_PROFILE
            return
        }

        'use' {
            if (-not $first) { Stop-Cp 'usage: claude-profiles use <name>' }
            Use-ClaudeProfile -Name $first -Persist; return
        }

        'uninstall' { Invoke-CpUninstall; return }

        'shell-init' {
            Stop-Cp 'On Windows the integration is the module itself. Add this to your $PROFILE instead: Import-Module ClaudeProfiles'
        }

        default { Stop-Cp "Unknown command '$cmd'. See: claude-profiles --help" }
    }
}


function Show-CpUsage {
    Write-CpSay @'
claude-profiles — run several Claude accounts on one machine

USAGE
  claude-profiles <command> [args]          the portable spelling
  <Verb>-ClaudeProfile...                   the PowerShell spelling

SETUP
  init                          create the registry; adopt an existing setup
  add <name> [options]          register a profile
  remove <name>                 unregister a profile (asks about its data)
  list [--json]                 show every profile

USING A PROFILE
  run <name> [-- args...]       run Claude Code as that profile
  shell <name>                  child shell where plain 'claude' is it
  desktop <name>                launch the desktop app on that profile
  whoami                        which profile is this session on?

WORKFLOW
  use <name>                    write .claude-profile here
  prompt [--help]               active profile, for a prompt or statusline

MAINTENANCE
  doctor [<name>] [--json]      health check
  token refresh <name>          generate and store a new OAuth token
  install-launcher <name>       Start-menu shortcut for a desktop profile
  mirror-app <name>             required for MSIX installs — see doctor first
  mcp-config <name>             path to that profile's MCP template
  uninstall                     remove everything, asking about each item

ADD OPTIONS
  --cli / --no-cli              --desktop / --no-desktop
  --auth <config-dir|oauth-token>
  --config-dir <path>           --user-data-dir <path>
  --app-path <path>             --description <text>

Windows notes: docs/windows.md
'@
}

function Show-CpPromptHelp {
    Write-CpSay @'
claude-profiles prompt — print the active profile, or nothing.

  PowerShell    function prompt {
                  $p = $env:CLAUDE_ACTIVE_PROFILE
                  if ($p) { "($p) PS $(Get-Location)> " } else { "PS $(Get-Location)> " }
                }

  oh-my-posh    { "type": "command",
                  "properties": { "command": "claude-profiles prompt" } }

  starship      [custom.claude]
                command = "claude-profiles prompt"
                when = true

  Claude Code   in settings.json:
  statusLine        "statusLine": { "type": "command",
                                    "command": "claude-profiles prompt" }
'@
}


function Invoke-CpUninstall {
    $reg = Import-CpRegistry
    Write-CpHeader 'Uninstall'
    Write-CpSay 'This walks every profile, then removes the registry itself.'
    Write-CpSay 'Your PRIMARY account is never touched.'

    foreach ($name in (Get-CpProfileNames $reg)) {
        Remove-ClaudeProfile -Name $name -Confirm:$false
    }

    if (Confirm-CpAction "Delete the claude-profiles state directory ($(Get-CpStateHome))?") {
        Remove-Item -LiteralPath (Get-CpStateHome) -Recurse -Force
        Write-CpOk "Deleted $(Get-CpStateHome)"
    }
    $apps = Get-CpAppsHome
    if (Test-Path -LiteralPath $apps) {
        if (Confirm-CpAction "Delete mirrored applications ($apps)?") {
            Remove-Item -LiteralPath $apps -Recurse -Force
            Write-CpOk "Deleted $apps"
        }
    }

    Write-CpHeader 'Left for you to do by hand'
    Write-CpSay '  1. Remove "Import-Module ClaudeProfiles" from your $PROFILE.'
    Write-CpSay '  2. Delete any .claude-profile files you left in projects.'
    Write-CpSay '  3. Revoke any OAuth tokens in your claude.ai account settings —'
    Write-CpSay '     deleting the local copy does not revoke the token.'
}
