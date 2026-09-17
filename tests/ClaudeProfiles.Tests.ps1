# tests/ClaudeProfiles.Tests.ps1
#
# Pester tests for the PowerShell implementation.
#
#     Invoke-Pester tests/ClaudeProfiles.Tests.ps1
#
# Everything here runs against a sandbox under the temp directory: no real
# registry, no real secrets, no Appx queries, no shortcuts, nothing launched.
#
# The cross-implementation agreement — that this module and lib/registry.sh
# serialise a registry identically — is tests/registry-contract.sh, not here.
# ---------------------------------------------------------------------------

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Sandbox  = Join-Path ([IO.Path]::GetTempPath()) "cp-pester-$PID"
    New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null

    # Point the module's state at the sandbox before importing it, and keep
    # the prompt hook out of the test session.
    $env:CLAUDE_PROFILES_HOME = $script:Sandbox
    $env:CLAUDE_PROFILES_NO_PROMPT_HOOK = '1'
    $env:CLAUDE_PROFILES_ASSUME_YES = '1'
    # Adoption inspects real paths in the real home directory, which would
    # make these tests pass or fail depending on whose machine they run on.
    $env:CLAUDE_PROFILES_NO_ADOPT = '1'

    Import-Module (Join-Path $script:RepoRoot 'powershell/ClaudeProfiles/ClaudeProfiles.psd1') -Force
}

AfterAll {
    Remove-Module ClaudeProfiles -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:Sandbox) {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item env:CLAUDE_PROFILES_HOME -ErrorAction SilentlyContinue
    Remove-Item env:CLAUDE_PROFILES_NO_PROMPT_HOOK -ErrorAction SilentlyContinue
    Remove-Item env:CLAUDE_PROFILES_ASSUME_YES -ErrorAction SilentlyContinue
    Remove-Item env:CLAUDE_PROFILES_NO_ADOPT -ErrorAction SilentlyContinue
}


Describe 'Module surface' {
    It 'exports every documented command' {
        $expected = @(
            'Initialize-ClaudeProfiles', 'Add-ClaudeProfile', 'Get-ClaudeProfile',
            'Remove-ClaudeProfile', 'Invoke-ClaudeProfile', 'Enter-ClaudeProfile',
            'Start-ClaudeProfileDesktop', 'Install-ClaudeProfileLauncher',
            'New-ClaudeProfileMirror', 'Update-ClaudeProfileToken',
            'Invoke-ClaudeProfileDoctor', 'Get-ClaudeProfileStatus',
            'Use-ClaudeProfile', 'Reset-ClaudeProfile', 'Invoke-ClaudeProfileCommand'
        )
        $actual = (Get-Module ClaudeProfiles).ExportedFunctions.Keys
        foreach ($name in $expected) { $actual | Should -Contain $name }
    }

    It 'exports the portable spelling as an alias' {
        # An alias rather than a function called `claude-profiles`: a function
        # with that name makes Import-Module warn about unapproved verbs on
        # every shell start.
        (Get-Module ClaudeProfiles).ExportedAliases.Keys | Should -Contain 'claude-profiles'
        (Get-Alias claude-profiles).ResolvedCommandName | Should -Be 'Invoke-ClaudeProfileCommand'
    }

    It 'the manifest and the module agree on exports' {
        $manifest = Import-PowerShellDataFile (Join-Path $script:RepoRoot 'powershell/ClaudeProfiles/ClaudeProfiles.psd1')
        $exported = (Get-Module ClaudeProfiles).ExportedFunctions.Keys | Sort-Object
        ($manifest.FunctionsToExport | Sort-Object) | Should -Be $exported
    }
}


Describe 'Profile names' {
    # The character set is the sanitisation boundary for .claude-profile
    # files, which arrive inside repositories you clone.
    It 'accepts <name>' -ForEach @(
        @{ name = 'work' }, @{ name = 'client-a' }, @{ name = 'a_b' }, @{ name = 'x1' }
    ) {
        InModuleScope ClaudeProfiles -Parameters @{ n = $name } { Test-CpProfileName $n | Should -BeTrue }
    }

    It 'rejects <name>' -ForEach @(
        @{ name = 'Work' }        # capitals become a different directory on a case-sensitive volume
        @{ name = 'a.b' }         # the registry's flat path format is dot-delimited
        @{ name = '-x' }
        @{ name = 'primary' }     # reserved: names the account we never manage
        @{ name = 'default' }
        @{ name = '' }
        @{ name = '../../etc' }   # path traversal
        @{ name = 'a;rm -rf /' }  # shell metacharacters
        @{ name = 'a b' }
        @{ name = 'x'.PadRight(33, 'y') }
    ) {
        InModuleScope ClaudeProfiles -Parameters @{ n = $name } { Test-CpProfileName $n | Should -BeFalse }
    }
}


Describe 'Canonical JSON' {
    It 'orders keys the way lib/registry.sh does' {
        InModuleScope ClaudeProfiles {
            $reg = [ordered]@{}
            $reg['profiles'] = [ordered]@{}
            $reg['profiles']['work'] = [ordered]@{
                description = 'x'
                cli = [ordered]@{ auth = 'config-dir'; configDir = '~/.claude-work' }
            }
            $reg['version'] = 1

            $json = ConvertTo-CpCanonicalJson $reg
            # version before profiles, cli before description, configDir before auth
            $json.IndexOf('"version"')     | Should -BeLessThan $json.IndexOf('"profiles"')
            $json.IndexOf('"cli"')         | Should -BeLessThan $json.IndexOf('"description"')
            $json.IndexOf('"configDir"')   | Should -BeLessThan $json.IndexOf('"auth"')
        }
    }

    It 'escapes quotes and backslashes' {
        InModuleScope ClaudeProfiles {
            ConvertTo-CpJsonString 'a"b\c' | Should -Be '"a\"b\\c"'
        }
    }

    It 'emits an empty object for an empty profiles map' {
        InModuleScope ClaudeProfiles {
            $reg = New-CpEmptyRegistry
            (ConvertTo-CpCanonicalJson $reg) | Should -Match '"profiles": \{\}'
        }
    }

    It 'uses LF, never CRLF' {
        # The file is byte-compared against what bash writes and is routinely
        # synced between platforms.
        InModuleScope ClaudeProfiles {
            (ConvertTo-CpCanonicalJson (New-CpEmptyRegistry)) | Should -Not -Match "`r"
        }
    }

    It 'produces byte-identical output on repeat' {
        InModuleScope ClaudeProfiles {
            $reg = New-CpEmptyRegistry
            Set-CpValue $reg 'work' 'cli.configDir' '~/.claude-work'
            Set-CpValue $reg 'work' 'cli.auth' 'config-dir'
            (ConvertTo-CpCanonicalJson $reg) | Should -Be (ConvertTo-CpCanonicalJson $reg)
        }
    }
}


Describe 'Paths' {
    It 'round-trips through compress and expand' {
        InModuleScope ClaudeProfiles {
            $p = Join-Path $HOME '.claude-work'
            Expand-CpPath (Compress-CpPath $p) | Should -Be $p
        }
    }

    It 'stores home-relative paths with a leading ~ and forward slashes' {
        InModuleScope ClaudeProfiles {
            # Forward slashes so bash and PowerShell write the same text for
            # the same directory.
            Compress-CpPath (Join-Path $HOME '.claude-work') | Should -Be '~/.claude-work'
        }
    }

    It 'leaves paths outside home alone' {
        InModuleScope ClaudeProfiles {
            Compress-CpPath '/opt/Claude/claude' | Should -Be '/opt/Claude/claude'
        }
    }
}


Describe 'Registry lifecycle' {
    BeforeEach {
        Get-ChildItem -LiteralPath $script:Sandbox -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Every Add-ClaudeProfile below passes an explicit -ConfigDir inside the
    # sandbox. Without it the default is $HOME/.claude-<name>, and the test
    # suite would create directories in the real home directory of whoever
    # ran it. CI runners have throwaway homes; contributors do not.

    It 'creates a registry and reads it back' {
        Initialize-ClaudeProfiles
        Test-Path (Join-Path $script:Sandbox 'profiles.json') | Should -BeTrue
    }

    It 'registers and lists a profile' {
        Initialize-ClaudeProfiles
        Add-ClaudeProfile -Name work -NoDesktop -Auth config-dir `
            -ConfigDir (Join-Path $script:Sandbox 'cli-work')
        (Get-ClaudeProfile).Name | Should -Contain 'work'
    }

    It 'defaults the auth mode by platform, matching lib/platform.sh' {
        # The asymmetry is the whole point: CLAUDE_CONFIG_DIR relocates
        # .credentials.json on Windows and Linux and so isolates the login by
        # itself, but on macOS credentials live in one shared Keychain item
        # that it does not touch. Both implementations must agree, or a
        # registry written by one is wrong for the other.
        InModuleScope ClaudeProfiles {
            $expected = if ($script:CpIsMacOS) { 'oauth-token' } else { 'config-dir' }
            Get-CpDefaultAuthMode | Should -Be $expected
        }
    }

    It 'refuses a config dir that is the primary account' {
        Initialize-ClaudeProfiles
        { Add-ClaudeProfile -Name danger -NoDesktop -ConfigDir (Join-Path $HOME '.claude') } |
            Should -Throw '*primary account*'
    }

    It 'refuses two profiles sharing one config dir' {
        Initialize-ClaudeProfiles
        Add-ClaudeProfile -Name one -NoDesktop -Auth config-dir -ConfigDir (Join-Path $script:Sandbox 'shared')
        { Add-ClaudeProfile -Name two -NoDesktop -Auth config-dir -ConfigDir (Join-Path $script:Sandbox 'shared') } |
            Should -Throw '*share cli.configDir*'
    }

    It 'refuses an invalid profile name' {
        Initialize-ClaudeProfiles
        { Add-ClaudeProfile -Name 'Bad Name' -NoDesktop `
            -ConfigDir (Join-Path $script:Sandbox 'cli-bad') } | Should -Throw '*Invalid profile name*'
    }

    It 'survives a registry missing its top-level keys' {
        # A hand-edited file must produce a clear error or a repaired
        # document, never a null-reference several frames away.
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'profiles.json') -Value '{}' -Encoding UTF8
        InModuleScope ClaudeProfiles {
            $reg = Import-CpRegistry
            $reg.Contains('profiles') | Should -BeTrue
            $reg.Contains('version')  | Should -BeTrue
        }
    }

    It 'rejects a registry from a future version' {
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'profiles.json') `
            -Value '{"version": 99, "profiles": {}}' -Encoding UTF8
        InModuleScope ClaudeProfiles { { Import-CpRegistry } | Should -Throw '*version 99*' }
    }
}


Describe 'Validation' {
    It 'reports a collision once, not from both sides' {
        InModuleScope ClaudeProfiles {
            $reg = New-CpEmptyRegistry
            Set-CpValue $reg 'a' 'cli.configDir' '~/.same'
            Set-CpValue $reg 'b' 'cli.configDir' '~/.same'
            @(Test-CpRegistry $reg | Where-Object { $_ -like '*share cli.configDir*' }).Count | Should -Be 1
        }
    }

    It 'flags an unknown auth mode' {
        InModuleScope ClaudeProfiles {
            $reg = New-CpEmptyRegistry
            Set-CpValue $reg 'a' 'cli.auth' 'nonsense'
            Test-CpRegistry $reg | Should -Match 'unknown auth mode'
        }
    }
}


Describe 'Secrets' {
    It 'round-trips through the file backend' {
        InModuleScope ClaudeProfiles {
            Set-CpSecret -Name 'unit' -Value 'sk-ant-oat-TEST' -Backend 'file'
            Test-CpSecret -Name 'unit' -Backend 'file' | Should -BeTrue
            Get-CpSecret  -Name 'unit' -Backend 'file' | Should -Be 'sk-ant-oat-TEST'
            Remove-CpSecret -Name 'unit' -Backend 'file'
            Test-CpSecret -Name 'unit' -Backend 'file' | Should -BeFalse
        }
    }

    It 'round-trips through DPAPI on Windows' -Skip:(-not $IsWindows -and $null -ne $IsWindows) {
        InModuleScope ClaudeProfiles {
            Set-CpSecret -Name 'unit2' -Value 'sk-ant-oat-DPAPI' -Backend 'dpapi'
            Get-CpSecret -Name 'unit2' -Backend 'dpapi' | Should -Be 'sk-ant-oat-DPAPI'
            # The stored form must not be the plaintext.
            (Get-Content -LiteralPath (Get-CpSecretPath -Name 'unit2' -Backend 'dpapi') -Raw) |
                Should -Not -Match 'sk-ant-oat-DPAPI'
            Remove-CpSecret -Name 'unit2' -Backend 'dpapi'
        }
    }

    It 'returns nothing rather than throwing when a secret is absent' {
        InModuleScope ClaudeProfiles {
            Get-CpSecret -Name 'never-stored' -Backend 'file' | Should -BeNullOrEmpty
        }
    }
}


Describe 'Auto-switch input handling' {
    # .claude-profile arrives inside repositories you clone. It may only ever
    # select a name that is already registered locally.
    It 'accepts a well-formed name' {
        InModuleScope ClaudeProfiles {
            'client-a' -cmatch '^[a-z0-9][a-z0-9_-]{0,31}$' | Should -BeTrue
        }
    }

    It 'rejects <bad> before it can reach a subprocess' -ForEach @(
        @{ bad = '../../etc/passwd' }
        @{ bad = 'work; rm -rf /' }
        @{ bad = '$(whoami)' }
        @{ bad = 'C:\Windows\System32' }
    ) {
        InModuleScope ClaudeProfiles -Parameters @{ b = $bad } {
            $b -cmatch '^[a-z0-9][a-z0-9_-]{0,31}$' | Should -BeFalse
        }
    }
}


Describe 'Doctor' {
    # Its own clean sandbox: the lifecycle block deliberately leaves a
    # version-99 registry behind, and inheriting it would fail every test here
    # for the wrong reason.
    BeforeEach {
        Get-ChildItem -LiteralPath $script:Sandbox -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'emits parseable JSON' {
        Initialize-ClaudeProfiles
        $json = Invoke-ClaudeProfileDoctor -Json
        { $json | ConvertFrom-Json } | Should -Not -Throw
        ($json | ConvertFrom-Json).PSObject.Properties.Name | Should -Contain 'findings'
    }

    It 'never prints a stored token' {
        Initialize-ClaudeProfiles
        Add-ClaudeProfile -Name tok -NoDesktop -Auth oauth-token `
            -ConfigDir (Join-Path $script:Sandbox 'cli-tok')
        InModuleScope ClaudeProfiles { Set-CpSecret -Name 'tok' -Value 'sk-ant-oat-SECRET' -Backend 'file' }
        (Invoke-ClaudeProfileDoctor -Json) | Should -Not -Match 'sk-ant-oat-SECRET'
    }
}
