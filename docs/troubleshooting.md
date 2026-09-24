# Troubleshooting

Start here:

```bash
claude-profiles doctor
```

It checks everything below and prints the fix. `--json` for scripting. It
changes nothing and never prints a secret.

For the authoritative answer to "which account is this actually?", run
`claude` and use `/status`. That reports the account the CLI itself thinks it
is using, rather than what the environment implies. Those can differ, and when
they do, `/status` is right.

---

## "It ran as the wrong account"

The most common problem, and almost always credential precedence.

Claude Code picks a credential in this documented order:

| Rank | Source |
|---|---|
| 1 | Cloud provider (`CLAUDE_CODE_USE_BEDROCK` / `_VERTEX` / `_FOUNDRY`) |
| 2 | `ANTHROPIC_AUTH_TOKEN` |
| 3 | `ANTHROPIC_API_KEY` |
| 4 | `apiKeyHelper` |
| 5 | `CLAUDE_CODE_OAUTH_TOKEN` ← what a token profile uses |
| 6 | Subscription login from `/login` ← what a config-dir profile uses |

Anything in 1–4 beats your profile:

```bash
env | grep -E 'ANTHROPIC|CLAUDE_CODE_USE'
```

`apiKeyHelper` is the one people forget, because it lives in
`~/.claude/settings.json` rather than the environment. `doctor` checks it.

### On macOS specifically

Current Claude Code stores each config directory's login in its own Keychain
item, `Claude Code-credentials-<hash>`. `doctor` looks for it. If it reports
"no Keychain login found yet" after you have logged in, your Claude Code build
probably predates per-directory items, and both profiles are sharing
`Claude Code-credentials`. Update Claude Code, or switch that profile to a
token:

```bash
claude-profiles add work --auth oauth-token
claude-profiles token refresh work
```

### `claude --bare` runs as the primary account

Bare mode does not read `CLAUDE_CODE_OAUTH_TOKEN` at all. Under a token
profile it silently falls through to your primary login.

`claude-profiles run` warns when it sees `--bare`. Nothing warns you if you
invoke `claude --bare` directly. Use `ANTHROPIC_API_KEY` or an `apiKeyHelper`
for bare-mode scripts.

---

## "No token is stored"

```bash
claude-profiles token refresh <name>
```

If you had a working setup and it stopped:

- **macOS**: the Keychain item may have been removed. `doctor` says which
  service name it looked for.
- **Windows**: DPAPI binds the encrypted token to one Windows user on one
  machine. A secrets file copied or synced from elsewhere will never decrypt.
  Generate a new token on this machine.
- **Any**: tokens last one year. `doctor` reports the age. Day 335 onward it
  warns; past 365 it treats it as expired.

Deleting a stored token does **not** revoke it. Revoke it in your claude.ai
account settings.

---

## The desktop app

### Second instance doesn't open, or just focuses the existing window

Quit Claude fully first — Cmd+Q on macOS, actually quitting rather than
closing the window. On macOS `doctor` also checks whether the app sets
`LSMultipleInstancesProhibited`, which makes `open -n` a no-op.

### Second instance opens but is logged into the same account (macOS)

### Primary account gets logged out after using the secondary (macOS)

Both are the same thing: the two profiles share one Keychain credential slot.
Confirm with the round-trip test in [docs/macos.md](macos.md), then:

```bash
claude-profiles mirror-app <name>
claude-profiles install-launcher <name>
```

Then redo the round-trip test.

This cannot happen on Windows or Linux, where the encrypted credential lives
inside the user-data directory.

### Nothing launches with a separate profile (Windows)

Almost certainly an MSIX / Microsoft Store install. Windows refuses to execute
anything directly out of `C:\Program Files\WindowsApps`, so `--user-data-dir`
cannot be passed at all.

```powershell
Invoke-ClaudeProfileDoctor    # confirms the install flavour
New-ClaudeProfileMirror -Name <name>
```

Details and costs: [docs/windows.md](windows.md).

### The app ignores `--user-data-dir`

Test it empirically. This is the one part of `doctor` that is not read-only —
it launches the app against a throwaway directory and deletes it afterwards:

```bash
claude-profiles doctor --probe
```

### A mirrored app behaves oddly, or won't start

Suspect a version mismatch first. A mirror is a frozen copy and does not
auto-update:

```bash
claude-profiles doctor <name>     # compares mirror against the real install
claude-profiles mirror-app <name> # refresh it
```

On macOS a mirror can also simply fail: if the app verifies its own signature
at startup, or hardened-runtime entitlements do not survive re-signing, it
will refuse to launch. There is no fix for that from outside the app.

---

## MCP servers fail in the second instance

Each desktop instance reads its own `claude_desktop_config.json` and spawns
its own copy of every server listed. Any server binding a fixed port fails in
whichever instance starts second, and the runtime symptom is just "the server
didn't work".

Give the profiles different configs:

```bash
claude-profiles mcp-config work     # prints the template path to edit
```

The template is applied to the profile's user-data directory on every launch.
`doctor` cross-references declared ports across profiles and flags collisions
before you hit them.

---

## Auto-switching

### It doesn't switch when I cd

1. Is the integration loaded? `type _claude_profiles_sync` should find a
   function. If not, the `eval "$(claude-profiles shell-init ...)"` line is
   missing from your shell rc, or you have not reloaded.
2. Is there a `.claude-profile` file? The walk stops at a repository root —
   a `.git` above you ends the search, so a file in a parent directory
   *outside* the repo is deliberately ignored.
3. Did you switch explicitly? An explicit `claude-profile-use` (or a
   `claude-profiles shell` subshell) outranks any file on disk and is never
   clobbered. `claude-profile-off` returns you to automatic.

### It says the profile is invalid or unregistered

Both are intentional refusals.

`.claude-profile` arrives inside repositories you clone, so it may only select
a profile you already have, by name, using lowercase letters, digits, hyphen
and underscore. Anything else is ignored and you stay on your primary account.

If it is your own repo and the name is right, register it:

```bash
claude-profiles add <name>
```

### I added a profile but `claude-<name>` isn't defined

The convenience functions are generated at shell-init time. Reload:

```bash
exec $SHELL
```

---

## Registry

### "is not valid JSON"

Something hand-edited it. Fix it, or move it aside and start over:

```bash
mv ~/.config/claude-profiles/profiles.json{,.broken}
claude-profiles init
```

`init` will offer to adopt any existing profile directories it recognises.

### "registry version N; this build understands version 1"

A newer `claude-profiles` wrote it. Update, rather than downgrading the file —
refusing to guess at an unknown format is deliberate.

---

## Everything broke after a Claude update

Expected. This drives documented environment variables and an Electron
command-line flag; none of it is a supported API.

```bash
claude-profiles doctor
```

That exists so the answer to "what changed?" takes one command. If you are on
a mirrored app, refresh it first — a version mismatch is the most likely
cause.

---

## Starting over

```bash
claude-profiles uninstall
```

Walks every profile and asks about each piece of data separately, then offers
to remove the registry. Your primary account is never touched.

With no terminal attached — in a script or CI — every prompt declines, so it
unregisters and deletes nothing. `CLAUDE_PROFILES_ASSUME_YES=1` overrides
that, deliberately as an environment variable rather than a flag.
