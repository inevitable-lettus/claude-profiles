@{
    RootModule        = 'ClaudeProfiles.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b3f1c6de-9a52-4f8e-8c47-5d1e7a0b2c93'
    Author            = 'claude-profiles contributors'
    Description       = 'Run several Claude accounts on one machine — Claude Code CLI and the desktop app, each with its own isolated profile. Windows implementation; macOS and Linux use the bash entrypoint in bin/.'

    # 5.1 is the floor because that is what ships with Windows and because
    # Get-AppxPackage — needed to detect an MSIX install — is a Windows
    # PowerShell component. PowerShell 7 reaches it through the compatibility
    # layer, which Private/Platform.ps1 handles.
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @(
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
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    # The portable `claude-profiles <subcommand>` spelling. An alias rather
    # than a function so Import-Module does not warn about unapproved verbs.
    AliasesToExport   = @('claude-profiles')

    PrivateData = @{
        PSData = @{
            Tags         = @('Claude', 'AI', 'Profiles', 'MultiAccount', 'ClaudeCode')
            LicenseUri   = 'https://github.com/inevitable-lettus/claude-profiles/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/inevitable-lettus/claude-profiles'
            ReleaseNotes = 'First public release. Windows, macOS and Linux; any number of named profiles; per-directory auto-switching.'
        }
    }
}
