# install.ps1 — claude-profiles, Windows.
#
#   irm https://raw.githubusercontent.com/inevitable-lettus/claude-profiles/main/install.ps1 | iex
#
# What it does:
#   1. checks prerequisites
#   2. clones or updates %LOCALAPPDATA%\claude-profiles\src
#   3. links the module into your PowerShell module path
#   4. prints the one line to add to your $PROFILE
#
# What it does NOT do: edit your $PROFILE, create any profile, read any
# credential, or elevate. Everything it writes is under your user directory.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

$RepoUrl    = if ($env:CLAUDE_PROFILES_REPO) { $env:CLAUDE_PROFILES_REPO } else { 'https://github.com/inevitable-lettus/claude-profiles.git' }
# Unset means the newest release tag, resolved after git is found below.
$Branch     = $env:CLAUDE_PROFILES_BRANCH
$InstallDir = if ($env:CLAUDE_PROFILES_INSTALL_DIR) { $env:CLAUDE_PROFILES_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'claude-profiles\src' }

function Say  { param([string]$m) Write-Host $m }
function Ok   { param([string]$m) Write-Host "  OK   $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host " WARN  $m" -ForegroundColor Yellow }
function Die  { param([string]$m) Write-Host " FATAL $m" -ForegroundColor Red; exit 1 }

Say ''
Say 'claude-profiles installer'
Say ''

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die 'git is required. Install it from https://git-scm.com/download/win or with: winget install Git.Git'
}

$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -lt 5) { Die "PowerShell 5.1 or newer is required; this is $psVersion." }
Ok "PowerShell $psVersion"

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Warn "The 'claude' CLI is not on your PATH. Install it first if you want the CLI half:"
    Warn '  https://code.claude.com/docs/en/setup'
}

# ---------------------------------------------------------------------------
# 2. Clone or update
# ---------------------------------------------------------------------------
if (-not $Branch) {
    $Branch = git ls-remote --tags --refs $RepoUrl 'v*' 2>$null |
        ForEach-Object { ($_ -split 'refs/tags/')[-1] } |
        Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Substring(1) } |
        Select-Object -Last 1
    if (-not $Branch) { $Branch = 'main' }
}
Ok "Version: $Branch"

if (Test-Path -LiteralPath (Join-Path $InstallDir '.git')) {
    Say "Updating $InstallDir"
    # FETCH_HEAD, detached: the same two lines work for a tag and a branch.
    git -C $InstallDir fetch --quiet --depth 1 origin $Branch
    if ($LASTEXITCODE -ne 0) { Die "Could not fetch $Branch from origin." }
    git -C $InstallDir checkout --quiet --force FETCH_HEAD
    Ok "Updated to $Branch ($(git -C $InstallDir rev-parse --short HEAD))"
} elseif (Test-Path -LiteralPath $InstallDir) {
    Die "$InstallDir exists but is not a git checkout. Move it aside and re-run."
} else {
    Say "Cloning into $InstallDir"
    $parent = Split-Path -Parent $InstallDir
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    # Output is held back and shown only on failure: a shallow clone of an
    # annotated tag prints a harmless "is not a commit!" warning otherwise.
    $cloneOut = git -c advice.detachedHead=false clone --quiet --depth 1 --branch $Branch $RepoUrl $InstallDir 2>&1
    if ($LASTEXITCODE -ne 0) { $cloneOut | Write-Host; Die 'Clone failed.' }
    Ok "Cloned $Branch ($(git -C $InstallDir rev-parse --short HEAD))"
}

# ---------------------------------------------------------------------------
# 3. Put the module where PowerShell will find it
# ---------------------------------------------------------------------------
# A directory junction rather than a copy, so `git pull` in the checkout is
# all an update takes. Junctions do not need administrator rights or
# Developer Mode, which symbolic links on Windows do.
$moduleRoot = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
} else {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
}
if (-not (Test-Path -LiteralPath $moduleRoot)) {
    New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
}

$link   = Join-Path $moduleRoot 'ClaudeProfiles'
$source = Join-Path $InstallDir 'powershell\ClaudeProfiles'

if (Test-Path -LiteralPath $link) {
    Remove-Item -LiteralPath $link -Recurse -Force
}
try {
    New-Item -ItemType Junction -Path $link -Target $source -ErrorAction Stop | Out-Null
    Ok "Linked $link"
} catch {
    # Junctions can be blocked by policy, or the module path can be on a
    # filesystem that does not support them. A copy still works; it just
    # needs re-running after each update.
    Warn "Could not create a junction ($($_.Exception.Message)); copying instead."
    Warn 'Re-run this installer after each update to refresh the copy.'
    Copy-Item -LiteralPath $source -Destination $link -Recurse -Force
    Ok "Copied to $link"
}

# The module is the recommended path on Windows, but the bash entrypoint is
# also usable from Git Bash for the CLI half.
Import-Module ClaudeProfiles -Force -ErrorAction SilentlyContinue
if (Get-Module ClaudeProfiles) {
    Ok "Module imports cleanly (version $((Get-Module ClaudeProfiles).Version))"
} else {
    Warn 'The module did not import. Run: Import-Module ClaudeProfiles -Verbose'
}

# ---------------------------------------------------------------------------
# 4. What to do next
# ---------------------------------------------------------------------------
Say ''
Say 'Installed. Two steps left, both yours to run:'
Say ''
Say "  1. Add this line to your `$PROFILE ($PROFILE):"
Say ''
Say '         Import-Module ClaudeProfiles'
Say ''
Say '     That gives you the Verb-Noun cmdlets, the portable `claude-profiles`'
Say '     spelling, and automatic switching when you cd into a project with a'
Say '     .claude-profile file.'
Say ''
Say '  2. Set up your first profile:'
Say ''
Say '         Initialize-ClaudeProfiles'
Say '         Add-ClaudeProfile -Name work'
Say ''
Say '  Then: Invoke-ClaudeProfileDoctor'
Say ''
Say 'The installer deliberately did not edit your $PROFILE. Adding one line'
Say 'yourself is cheaper than trusting a script with your shell configuration.'
Say ''
Say 'Windows notes — especially if Claude came from the Microsoft Store:'
Say '  docs/windows.md'
Say ''
