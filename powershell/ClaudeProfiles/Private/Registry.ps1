# Private/Registry.ps1
#
# The profile registry, PowerShell side. Reads and writes exactly the same
# profiles.json as lib/registry.sh — a Git Bash user and a PowerShell user on
# one Windows machine share it.
#
# WHY THERE IS A HAND-WRITTEN SERIALIZER HERE
# -------------------------------------------
# ConvertTo-Json would be one line, but its output differs between Windows
# PowerShell 5.1 and PowerShell 7, and neither matches the bash writer's
# canonical form. Deterministic, byte-identical output across all three
# implementations is what makes tests/registry-contract.sh a real test rather
# than a semantic approximation, and it keeps `git diff` on a synced registry
# readable. The document shape is small and fixed, so the cost is this file.
#
# The key order below MUST stay in step with reg_sort_children() in
# lib/registry.sh. tests/registry-contract.sh fails if it drifts.
# ---------------------------------------------------------------------------

$script:CpRegistryVersion = 1

# Reserved names, and the character set. See the long comment in
# lib/registry.sh for why this is strict — the short version is that a
# .claude-profile file arrives inside repositories you clone, so a profile
# name is untrusted input and this is the sanitisation boundary.
$script:CpNamePattern  = '^[a-z0-9][a-z0-9_-]{0,31}$'
$script:CpReservedNames = @('primary', 'default', 'all', 'none')

function Test-CpProfileName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($script:CpReservedNames -contains $Name) { return $false }
    return ($Name -cmatch $script:CpNamePattern)
}

function Assert-CpProfileName {
    param([string]$Name)
    if (-not (Test-CpProfileName $Name)) {
        Stop-Cp "Invalid profile name '$Name'. Use lowercase letters, digits, '-' and '_' (max 32, cannot start with '-' or '_', and 'primary'/'default'/'all'/'none' are reserved)."
    }
}


# ---------------------------------------------------------------------------
# Load / save
# ---------------------------------------------------------------------------
# The in-memory form is an ordered hashtable tree, so insertion order is
# irrelevant — the serializer imposes the canonical order on the way out.

function New-CpEmptyRegistry {
    $reg = [ordered]@{}
    $reg['version']  = $script:CpRegistryVersion
    $reg['profiles'] = [ordered]@{}
    return $reg
}

function Import-CpRegistry {
    param([switch]$Required)

    $path = Get-CpRegistryPath
    if (-not (Test-Path -LiteralPath $path)) {
        if ($Required) { Stop-Cp "No registry at $path. Run: Initialize-ClaudeProfiles" }
        return New-CpEmptyRegistry
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json
    } catch {
        Stop-Cp "$path is not valid JSON. Fix it by hand, or move it aside and run Initialize-ClaudeProfiles."
    }

    if ($obj.version -and [int]$obj.version -ne $script:CpRegistryVersion) {
        Stop-Cp "$path is registry version $($obj.version); this build understands version $($script:CpRegistryVersion). Upgrade claude-profiles."
    }

    # ConvertFrom-Json gives PSCustomObjects; convert to ordered hashtables so
    # the rest of the module has one type to deal with.
    $reg = ConvertTo-CpOrderedHashtable $obj

    # Normalise the two top-level keys. A hand-edited file missing "profiles"
    # would otherwise null-reference on the first lookup, several frames away
    # from the actual cause.
    if (-not $reg.Contains('version'))  { $reg['version'] = $script:CpRegistryVersion }
    if (-not $reg.Contains('profiles') -or -not ($reg['profiles'] -is [System.Collections.IDictionary])) {
        $reg['profiles'] = [ordered]@{}
    }
    return $reg
}

function ConvertTo-CpOrderedHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [int] -or
        $InputObject -is [long]   -or $InputObject -is [bool] -or
        $InputObject -is [double]) { return $InputObject }

    $out = [ordered]@{}
    foreach ($prop in $InputObject.PSObject.Properties) {
        $out[$prop.Name] = ConvertTo-CpOrderedHashtable $prop.Value
    }
    return $out
}

function Export-CpRegistry {
    param([Parameter(Mandatory)]$Registry)

    $path = Get-CpRegistryPath
    $dir  = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $Registry['version'] = $script:CpRegistryVersion
    if (-not $Registry.Contains('profiles') -or $null -eq $Registry['profiles']) {
        $Registry['profiles'] = [ordered]@{}
    }

    $text = ConvertTo-CpCanonicalJson $Registry

    # Parse what we just produced before trusting it, so a serializer bug
    # surfaces here rather than the next time any command runs.
    try { $null = $text | ConvertFrom-Json }
    catch { Stop-Cp 'Serializer produced invalid JSON — this is a bug in ClaudeProfiles' }

    # Write to a sibling temp file and move it into place: an interrupted save
    # must never be able to leave a half-written registry, which would take
    # out every profile at once.
    $tmp = "$path.tmp.$PID"
    # No BOM: the bash side reads this with awk, which would choke on one.
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($tmp, $text, $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $path -Force

    Protect-CpUserOnlyPath $path
}


# ---------------------------------------------------------------------------
# Canonical serialization — must match lib/registry.sh byte for byte
# ---------------------------------------------------------------------------

# The rank table. Identical to reg_sort_children() in lib/registry.sh.
$script:CpKeyRank = @{
    'version'      = 0
    'profiles'     = 1
    'cli'          = 10
    'desktop'      = 11
    'description'  = 12
    'configDir'    = 20
    'auth'         = 21
    'tokenBackend' = 22
    'tokenCreated' = 23
    'userDataDir'  = 30
    'appPath'      = 31
    'mirrored'     = 32
    'launcher'     = 33
}

function Get-CpSortedKeys {
    param($Node)
    $keys = @($Node.Keys)
    return $keys | Sort-Object `
        @{ Expression = { if ($script:CpKeyRank.ContainsKey($_)) { $script:CpKeyRank[$_] } else { 50 } } },
        @{ Expression = { $_ }; Ascending = $true }
}

function ConvertTo-CpJsonString {
    param([string]$Value)
    $s = $Value -replace '\\', '\\'
    $s = $s -replace '"', '\"'
    $s = $s -replace "`t", '\t'
    $s = $s -replace "`n", '\n'
    $s = $s -replace "`r", '\r'
    return '"' + $s + '"'
}

function ConvertTo-CpCanonicalJson {
    param($Node)
    $sb = [Text.StringBuilder]::new()
    Write-CpJsonNode -Node $Node -Indent '' -Builder $sb
    [void]$sb.Append("`n")
    # LF throughout, never CRLF: the file is byte-compared against what bash
    # writes, and it is routinely synced between platforms.
    return $sb.ToString()
}

function Write-CpJsonNode {
    param($Node, [string]$Indent, [Text.StringBuilder]$Builder)

    [void]$Builder.Append("{`n")
    $keys = @(Get-CpSortedKeys $Node)
    $first = $true

    foreach ($key in $keys) {
        if (-not $first) { [void]$Builder.Append(",`n") }
        $first = $false
        [void]$Builder.Append($Indent + '  ')
        [void]$Builder.Append((ConvertTo-CpJsonString $key))
        [void]$Builder.Append(': ')

        $value = $Node[$key]
        if ($value -is [System.Collections.IDictionary]) {
            if ($value.Count -eq 0) {
                [void]$Builder.Append('{}')
            } else {
                Write-CpJsonNode -Node $value -Indent ($Indent + '  ') -Builder $Builder
            }
        } elseif ($value -is [bool]) {
            [void]$Builder.Append($(if ($value) { 'true' } else { 'false' }))
        } elseif ($value -is [int] -or $value -is [long] -or $value -is [double]) {
            [void]$Builder.Append($value.ToString([Globalization.CultureInfo]::InvariantCulture))
        } elseif ($null -eq $value) {
            [void]$Builder.Append('null')
        } else {
            [void]$Builder.Append((ConvertTo-CpJsonString ([string]$value)))
        }
    }

    if (-not $first) { [void]$Builder.Append("`n") }
    [void]$Builder.Append($Indent + '}')
}


# ---------------------------------------------------------------------------
# Node helpers
# ---------------------------------------------------------------------------

function Get-CpProfileNames {
    param($Registry)
    if (-not $Registry['profiles']) { return @() }
    return @($Registry['profiles'].Keys | Sort-Object)
}

function Test-CpProfileExists {
    param($Registry, [string]$Name)
    return ($Registry['profiles'] -and $Registry['profiles'].Contains($Name))
}

function Get-CpProfileNode {
    param($Registry, [string]$Name, [switch]$Create)
    if (-not $Registry['profiles'].Contains($Name)) {
        if (-not $Create) { return $null }
        $Registry['profiles'][$Name] = [ordered]@{}
    }
    return $Registry['profiles'][$Name]
}

# Get-CpValue — dotted lookup that tolerates missing intermediate nodes.
function Get-CpValue {
    param($Registry, [string]$Name, [string]$Path, $Default = $null)
    $node = Get-CpProfileNode $Registry $Name
    if (-not $node) { return $Default }
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $node -or -not ($node -is [System.Collections.IDictionary]) -or -not $node.Contains($segment)) {
            return $Default
        }
        $node = $node[$segment]
    }
    if ($null -eq $node -or $node -eq '') { return $Default }
    return $node
}

function Set-CpValue {
    param($Registry, [string]$Name, [string]$Path, $Value)
    $node = Get-CpProfileNode $Registry $Name -Create
    $segments = $Path.Split('.')
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        if (-not $node.Contains($segments[$i]) -or -not ($node[$segments[$i]] -is [System.Collections.IDictionary])) {
            $node[$segments[$i]] = [ordered]@{}
        }
        $node = $node[$segments[$i]]
    }
    $leaf = $segments[-1]
    # An empty value removes the key rather than storing "", so optional
    # fields stay genuinely absent — same rule as reg_set_str in bash.
    if ($null -eq $Value -or $Value -eq '') { $node.Remove($leaf) }
    else { $node[$leaf] = $Value }
}

function Remove-CpSection {
    param($Registry, [string]$Name, [string]$Section)
    $node = Get-CpProfileNode $Registry $Name
    if ($node -and $node.Contains($Section)) { $node.Remove($Section) }
}


# ---------------------------------------------------------------------------
# Validation — the counterpart of registry_validate
# ---------------------------------------------------------------------------
function Test-CpRegistry {
    param($Registry)
    $problems = [Collections.Generic.List[string]]::new()
    $names = Get-CpProfileNames $Registry

    foreach ($name in $names) {
        if (-not (Test-CpProfileName $name)) {
            $problems.Add("profile `"$name`": name is not valid")
        }

        $auth = Get-CpValue $Registry $name 'cli.auth' ''
        if ($auth -and $auth -notin @('config-dir', 'oauth-token')) {
            $problems.Add("profile `"$name`": unknown auth mode `"$auth`"")
        }

        $dir = Get-CpValue $Registry $name 'cli.configDir' ''
        if ($dir -and (Expand-CpPath $dir) -eq (Get-CpPrimaryCliConfigDir)) {
            $problems.Add("profile `"$name`": cli.configDir is the PRIMARY config dir — that would overwrite your main account")
        }

        $udd = Get-CpValue $Registry $name 'desktop.userDataDir' ''
        if ($udd -and (Expand-CpPath $udd) -eq (Get-CpPrimaryDesktopDir)) {
            $problems.Add("profile `"$name`": desktop.userDataDir is the PRIMARY profile directory — that would overwrite your main account")
        }

        # Each colliding pair reported once: only compare against names that
        # sort after this one.
        foreach ($other in $names) {
            if ([string]::Compare($other, $name, [StringComparison]::Ordinal) -le 0) { continue }
            if ($dir -and $dir -eq (Get-CpValue $Registry $other 'cli.configDir' '')) {
                $problems.Add("profiles `"$name`" and `"$other`" share cli.configDir $dir")
            }
            if ($udd -and $udd -eq (Get-CpValue $Registry $other 'desktop.userDataDir' '')) {
                $problems.Add("profiles `"$name`" and `"$other`" share desktop.userDataDir $udd")
            }
        }
    }

    return $problems
}


# ---------------------------------------------------------------------------
# Protect-CpUserOnlyPath
# ---------------------------------------------------------------------------
# The Windows equivalent of chmod 600/700. Inheritance is disabled and every
# inherited ACE dropped, leaving the current user only — otherwise a token
# file would still be readable by whatever the parent directory grants.
function Protect-CpUserOnlyPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $script:CpIsWindows) {
        # 700 for a directory, 600 for a file — the same modes the bash
        # implementation applies, so a machine with both sees no churn.
        $mode = if (Test-Path -LiteralPath $Path -PathType Container) { '700' } else { '600' }
        # Best effort: on a filesystem without POSIX modes (an exFAT
        # volume, say) chmod fails and there is nothing useful to do about it.
        try { & chmod $mode $Path 2>$null } catch { Write-Debug "chmod $mode failed on ${Path}: $_" }
        return
    }
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $isDir = Test-Path -LiteralPath $Path -PathType Container
        $inherit = if ($isDir) { 'ContainerInherit,ObjectInherit' } else { 'None' }
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $me, 'FullControl', $inherit, 'None', 'Allow'))
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        Write-CpWarn "Could not restrict permissions on $Path — $($_.Exception.Message)"
    }
}
