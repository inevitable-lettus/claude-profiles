# macOS

macOS is the platform this tool was originally built for, and the one where
the CLI half is genuinely awkward. Both halves have a failure mode worth
understanding before you set anything up.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/inevitable-lettus/claude-profiles/main/install.sh | sh
```

Add to `~/.zshrc`:

```bash
eval "$(claude-profiles shell-init zsh)"
```

```bash
claude-profiles init
claude-profiles add work
claude-profiles doctor
```

Everything is bash 3.2 compatible, because that is what macOS ships. You do
not need a newer bash from Homebrew.

---

## The CLI half: one login per config directory

Current Claude Code stores a Mac login in the Keychain under a service name
derived from the config directory:

| Config directory | Keychain item |
|---|---|
| none (`~/.claude`) | `Claude Code-credentials` |
| `CLAUDE_CONFIG_DIR=/Users/you/.claude-work` | `Claude Code-credentials-<8 hex>` |

The suffix is the first eight hex digits of the SHA-256 of the
`CLAUDE_CONFIG_DIR` string exactly as exported (NFC-normalised, not
resolved), so `~/.claude-work` and `/Users/you/.claude-work/` are different
items. claude-profiles always exports the same absolute path. Different directory, different
Keychain item, independent login. So on a Mac, as on Linux and Windows:

```bash
claude-profiles add work             # config-dir auth, the default
claude-profiles run work -- /login   # once
```

`doctor` computes the expected item name and checks that it exists. It reads
metadata only (no `-w`), so macOS never prompts and no secret is read.

> This naming is read from Claude Code's own source (2.1.260), not a
> documented contract. The
> [authentication docs](https://code.claude.com/docs/en/authentication) still
> describe a single Keychain item on macOS. Older Claude Code builds did use
> one fixed item, and there the second `/login` overwrote the first. If
> `doctor` cannot find a profile's item after you log in, update Claude Code,
> or fall back to token auth below.

### Token auth, for CI and older builds

`CLAUDE_CODE_OAUTH_TOKEN` sits at **rank 5** in the
[credential precedence](https://code.claude.com/docs/en/authentication#authentication-precedence),
above the rank 6 subscription login, so it wins over whatever is in the
Keychain.

```bash
claude-profiles add ci --auth oauth-token
claude-profiles token refresh ci
```

`claude setup-token` runs in a separate terminal, prints the token once, and
saves it nowhere, so you paste it in. Input is hidden, and it goes straight
into the Keychain under a service name of our own
(`claude-profiles-ci-token`) that cannot collide with Anthropic's.

It has three costs, which is why it is no longer the default:

**A token profile cannot use Remote Control or claude.ai connectors.** Local
MCP servers still work.

**The token expires after a year.** The creation date is recorded; `doctor`
and every `claude-profiles run` start warning at day 335.

**`claude --bare` ignores `CLAUDE_CODE_OAUTH_TOKEN` entirely.** A bare-mode
script under a token profile silently runs as your primary account.
`claude-profiles run` warns when it sees `--bare` in the arguments; nothing
warns you if you invoke `claude --bare` directly.

To move an existing token profile to config-dir auth:

```bash
claude-profiles add work --auth config-dir
claude-profiles run work -- /login
```

---

## The desktop half

```bash
claude-profiles add work --desktop
claude-profiles desktop work
claude-profiles install-launcher work    # a clickable "Claude Work.app"
```

The mechanism is one command:

```
open -n -a Claude --args --user-data-dir=<somewhere else>
```

`-n` forces a new instance rather than focusing the existing window; `--args`
passes the rest to the app. Everything the instance stores — credential blob,
MCP config, window state, caches — lands in that directory.

### The one test that matters

Static checks can only guess about the Keychain. `claude-profiles doctor`
prints this, and it is the thing most people get wrong:

1. Launch Claude normally. Confirm **account A**. Quit fully with Cmd+Q.
2. `claude-profiles desktop work`. Log in as **account B**. Quit fully.
3. Launch Claude normally again.
4. **Which account are you in?**

- Still **A** → the profiles are independent. Done.
- Now **B**, or logged out → they share one Keychain slot. See below.

Step 4 is the whole test. It is easy to stop after step 2, see account B
working, and assume success.

You can also ask `doctor` to test the flag empirically, which launches the app
against a throwaway directory and deletes it afterwards:

```bash
claude-profiles doctor --probe
```

That is the only part of `doctor` that is not read-only, which is why it is
opt-in.

### If the test fails: mirror-app

```bash
claude-profiles mirror-app work
```

Copies `Claude.app` to a second bundle with a different `CFBundleIdentifier`
and a fresh ad-hoc signature. macOS scopes Keychain access by code signature
plus bundle identifier, so two bundles with different identities cannot see
each other's items. It is the only approach that definitively solves a
shared-credential collision.

**What it costs, and all four are real:**

1. **No auto-updates.** The mirror is a frozen copy. Re-run after every Claude
   update; `doctor` compares the versions and tells you when it is behind.
2. **The signature is replaced.** Anthropic's is discarded for an ad-hoc one.
   That is the entire mechanism, but it means the copy is not notarised and
   some macOS security features degrade.
3. **It may simply not work.** If the app verifies its own signature at
   startup, or hardened-runtime entitlements do not survive re-signing, it
   will refuse to launch or crash. No way to know without trying.
4. **About a gigabyte** of disk per mirror.

Then point the launcher at it and redo the round-trip test:

```bash
claude-profiles install-launcher work
```

If it still fails, the honest answer is to use claude.ai in a separate browser
profile for the second account and keep the desktop app single-account.

---

## The launcher app

`install-launcher` builds a real `.app` in `/Applications` — a folder of
readable files, not a compiled Script Editor blob, so you can open it up and
see exactly what it runs:

```bash
cat "/Applications/Claude Work.app/Contents/MacOS/launcher"
```

The profile path is baked in rather than read from the registry, so the app
keeps working even if you uninstall `claude-profiles`. `LSUIElement` hides it
from the Dock: it runs for a fraction of a second and exits, and without that
you get a pointless bouncing icon.

Its `CFBundleIdentifier` is deliberately **not** `com.anthropic.*` — reusing
Anthropic's would confuse macOS about which app is which.

---

## Keychain prompts

The first time a profile's token is read in a login session, macOS may ask for
authorisation. Tick **Always Allow** and you will not see it again.

`doctor` never triggers this: its Keychain lookups omit `-w`, which reads
metadata only. A diagnostic command should not need your password.

---

## Where things live

```
~/.config/claude-profiles/profiles.json        the registry
~/.config/claude-profiles/profiles/<name>/     per-profile MCP template
~/.config/claude-profiles/apps/<name>.app      mirrored app, if any
~/.claude-<name>/                              that profile's CLI config
~/Library/Application Support/Claude-<Name>/   that profile's desktop data
/Applications/Claude <Name>.app                the generated launcher

~/.claude/                                     your PRIMARY account. Never touched.
~/Library/Application Support/Claude/          the primary desktop profile. Never touched.
Keychain "Claude Code-credentials"             the primary login. Read-only for us.
Keychain "Claude Code-credentials-<hash>"      each profile's login, written by Claude Code.
```

XDG `~/.config` rather than `~/Library/Application Support` for our own state:
this is a CLI tool, people who sync dotfiles expect `~/.config`, and one path
across all three platforms is one fewer thing to explain.

---

## Known limitations

- Both desktop instances share one Dock icon and one Cmd+Tab entry, because
  they have the same bundle ID. The launcher gives you a separate way to
  *start* the second instance, not a separate app identity. A mirrored app
  does get its own identity, at the cost of never updating.
- `/Applications` usually needs no `sudo` for an admin user. If it does,
  `install-launcher` asks.
