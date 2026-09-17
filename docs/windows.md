# Windows

Two things to know before anything else:

1. **The CLI half is easier on Windows than on macOS.** `CLAUDE_CONFIG_DIR`
   isolates the login by itself. No token, no expiry, nothing to renew.
2. **The desktop half may be harder**, and which it is depends entirely on how
   Claude was installed. `Invoke-ClaudeProfileDoctor` tells you in one line.

---

## Install

```powershell
irm https://raw.githubusercontent.com/inevitable-lettus/claude-profiles/main/install.ps1 | iex
```

Then add to your `$PROFILE`:

```powershell
Import-Module ClaudeProfiles
```

```powershell
Initialize-ClaudeProfiles
Add-ClaudeProfile -Name work
Invoke-ClaudeProfileDoctor
```

Windows PowerShell 5.1 and PowerShell 7+ are both supported and both tested in
CI. 5.1 is the floor because it ships with Windows, and because
`Get-AppxPackage` — needed to detect an MSIX install — is a Windows PowerShell
component. PowerShell 7 reaches it through the compatibility layer, which the
module handles for you.

---

## Two spellings of every command

```powershell
Add-ClaudeProfile -Name work -NoDesktop     # PowerShell style
claude-profiles add work --no-desktop       # the portable style
```

The second exists so the README, every doc page, and anyone's muscle memory
transfer between platforms unchanged. It is a thin dispatcher over the
cmdlets, not a second implementation.

| Portable | PowerShell |
|---|---|
| `init` | `Initialize-ClaudeProfiles` |
| `add <name>` | `Add-ClaudeProfile -Name <name>` |
| `list` | `Get-ClaudeProfile` |
| `remove <name>` | `Remove-ClaudeProfile -Name <name>` |
| `run <name> -- args` | `Invoke-ClaudeProfile -Name <name> -Arguments args` |
| `shell <name>` | `Enter-ClaudeProfile -Name <name>` |
| `desktop <name>` | `Start-ClaudeProfileDesktop -Name <name>` |
| `install-launcher <name>` | `Install-ClaudeProfileLauncher -Name <name>` |
| `mirror-app <name>` | `New-ClaudeProfileMirror -Name <name>` |
| `token refresh <name>` | `Update-ClaudeProfileToken -Name <name>` |
| `doctor` | `Invoke-ClaudeProfileDoctor` |
| `whoami` | `Get-ClaudeProfileStatus` |
| `use <name>` | `Use-ClaudeProfile -Name <name> -Persist` |

`Use-ClaudeProfile -Name work` without `-Persist` switches the current session
instead of writing a file.

---

## The CLI half

From [the authentication docs](https://code.claude.com/docs/en/authentication):

> On Windows, credentials are stored in
> `%USERPROFILE%\.claude\.credentials.json` […] If you've set the
> `CLAUDE_CONFIG_DIR` environment variable on Linux or Windows, the
> `.credentials.json` file lives under that directory instead.

So:

```powershell
Add-ClaudeProfile -Name work -NoDesktop
Invoke-ClaudeProfile -Name work -Arguments /login
```

That is the entire setup. Two config directories, two logins, no interference.

### When you might still want a token

`-Auth oauth-token` exists on Windows for two situations:

- **CI and headless runs**, where there is no browser to log in with.
- **A registry synced from a Mac**, where `oauth-token` is the default.

It is stored with DPAPI, which binds it to one Windows user on one machine.
Copying the secrets file to another machine will not work, and the module says
so clearly rather than surfacing a `CryptographicException`.

---

## The desktop half: which install do you have?

```powershell
Invoke-ClaudeProfileDoctor
```

### Direct `.exe` installer — the easy case

```
%LOCALAPPDATA%\AnthropicClaude\app-<version>\claude.exe
```

`--user-data-dir` works. Nothing special to do:

```powershell
Add-ClaudeProfile -Name work -Desktop
Start-ClaudeProfileDesktop -Name work
Install-ClaudeProfileLauncher -Name work -AlsoOnDesktop
```

### MSIX / Microsoft Store / enterprise deployment — the awkward case

```
C:\Program Files\WindowsApps\<package>\...
```

Windows refuses to execute anything directly out of `WindowsApps`, so
`--user-data-dir` **cannot be passed at all**. The app-execution alias at
`%LOCALAPPDATA%\Microsoft\WindowsApps\Claude.exe` starts the package but does
not reliably forward arguments to it.

The way around it is to mirror the package payload into a writable directory:

```powershell
New-ClaudeProfileMirror -Name work
Install-ClaudeProfileLauncher -Name work
Start-ClaudeProfileDesktop -Name work
```

**What that costs, and all of it is real:**

1. **No auto-updates.** The mirror is a frozen snapshot. Re-run
   `New-ClaudeProfileMirror` after each Claude update. `Invoke-ClaudeProfileDoctor`
   compares the versions and tells you when it has fallen behind.
2. **About a gigabyte of disk** per mirror. It goes under `%LOCALAPPDATA%`,
   not `%APPDATA%` — a gigabyte in a roaming profile makes you unpopular on a
   domain-joined machine.
3. **It may simply not work.** A packaged app can depend on package identity
   at runtime, for virtualised registry access or for entitlements that only
   exist inside the container. A plain copy has none of that, and there is no
   way to know without trying.
4. **`claude://` links keep opening the original install**, not the mirror.
   Protocol handlers stay registered to the real package.

If it does not work, the honest answer is to use claude.ai in a separate
browser profile for the second account and keep the desktop app
single-account.

---

## What Windows does *not* need

No Keychain round-trip test, and no re-signing.

Electron's `safeStorage` on Windows encrypts with DPAPI and keeps the
encrypted blob **inside the user-data directory**. There is no single shared
credential slot for two profiles to fight over — which is the macOS problem
this tool spends most of its complexity on. On Windows the risk is packaging,
not credentials.

---

## Gotchas

**Log profiles in one at a time.** The `claude://` deep link used by the login
flow routes to whichever window is focused. Two pending logins get crossed.

**Both instances share one taskbar identity**, because they are the same
application. The shortcut gives you a separate way to *start* the second
instance, not a separate app identity.

**MCP servers with fixed ports.** Each instance spawns its own copy of every
configured server, so whichever starts second fails to bind. Give the profiles
different configs:

```powershell
claude-profiles mcp-config work    # prints the path to edit
```

`Invoke-ClaudeProfileDoctor` cross-references declared ports across profiles
and flags collisions before you hit them.

**Execution policy.** If `Import-Module ClaudeProfiles` is blocked:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

That is a change to your machine's security settings — read what it does
before running it, and prefer `-Scope CurrentUser` over anything wider.

---

## Git Bash and WSL

**Git Bash** gets the bash entrypoint, and the CLI subcommands work there. The
desktop subcommands defer to the PowerShell module, because reading Appx
package state and creating shortcuts are things only PowerShell can do. Both
read the same registry at `%APPDATA%\claude-profiles\profiles.json`, so a
profile added in one is visible in the other.

**WSL** is Linux and is treated as Linux — see [docs/linux.md](linux.md). The
CLI half works natively there. Driving the *Windows* desktop app from inside
WSL is out of scope; use the PowerShell module on the Windows side.

---

## Where things live

```
%APPDATA%\claude-profiles\profiles.json      the registry
%APPDATA%\claude-profiles\profiles\<name>\   per-profile MCP template
%APPDATA%\claude-profiles\secrets\           DPAPI-encrypted tokens, if any
%LOCALAPPDATA%\claude-profiles\apps\<name>\  mirrored applications
%USERPROFILE%\.claude-<name>\                that profile's CLI config
%APPDATA%\Claude-<Name>\                     that profile's desktop data

%USERPROFILE%\.claude\                       your PRIMARY account. Never touched.
%APPDATA%\Claude\                            the primary desktop profile. Never touched.
```

The registry and the secrets directory have their ACLs stripped to your user
account only — inheritance disabled, every inherited entry removed — so a
permissive parent directory cannot widen access to them.
