# Security

## Reporting a vulnerability

Open a [GitHub security advisory](https://github.com/inevitable-lettus/claude-profiles/security/advisories/new)
rather than a public issue. Include what you did, what happened, and what you
expected.

This is a small unfunded project, so there is no bounty and no SLA — but
anything that could expose a credential or run unintended code is taken
seriously and will be answered.

Vulnerabilities in Claude Code or the Claude desktop app themselves belong to
Anthropic, not here: https://www.anthropic.com/responsible-disclosure-policy

---

## What this tool handles

**Long-lived OAuth tokens**, but only for profiles using `oauth-token` auth —
which on Windows and Linux is unusual, because `CLAUDE_CONFIG_DIR` isolates
the login by itself there. On macOS it is the normal case.

Where a token is stored:

| Platform | Store | Notes |
|---|---|---|
| macOS | Keychain, service `claude-profiles-<name>-token` | Cannot collide with Claude Code's own `Claude Code-credentials` |
| Windows | DPAPI-encrypted file, ACL stripped to the current user | Bound to one user on one machine |
| Linux | `secret-tool` / libsecret | Preferred when available |
| Fallback | mode-0600 file | Only when no OS store exists, and the tool says so out loud before writing one |

---

## Properties the design maintains

**The primary account is never written to.** `~/.claude`, the default desktop
profile directory, and Claude Code's own credential are read-only for this
tool. This is enforced at registration time, at use time, in
`registry_validate`, and asserted by the test suite.

**Tokens are not exported at shell startup.** A token is read at the moment of
use and passed to one child process. Exporting it into your interactive shell
would put it in the environment of everything you launch, where `ps eww` would
show it to anything running as your user.

Two places deliberately do export it, because that is what makes plain
`claude` work in that shell, and both say so at the time:

- `claude-profiles shell <name>`
- the per-directory auto-switch hook, for an `oauth-token` profile

Set `CLAUDE_PROFILES_AUTOSWITCH_TOKEN=0` to turn the second off. The profile's
config directory still switches and `claude-<name>` still works; plain
`claude` falls back to your primary login.

**Diagnostics never print or read secrets.** `doctor` omits `-w` on Keychain
lookups, so macOS reads metadata only and never prompts for authorisation just
because you ran a health check. No output path prints a token in either human
or `--json` mode, and the test suite asserts it.

**Destructive actions decline by default.** `confirm()` treats anything but an
explicit yes as no, including a closed stdin. Under automation, every
destructive prompt declines. `CLAUDE_PROFILES_ASSUME_YES=1` overrides it —
deliberately an environment variable rather than a `--yes` flag, because a
flag is too easy to copy out of a README without reading what it skips.

**File permissions.** The registry is mode 600, state and secret directories
are 700. On Windows the equivalent is an ACL with inheritance disabled and
every inherited entry removed, so a permissive parent directory cannot widen
access.

---

## `.claude-profile` is treated as untrusted input

That file arrives inside repositories you clone from other people, so it is
handled like any other file in a hostile repo.

**It may only select a profile that is already registered on your machine, by
name.** It cannot create a profile, name a directory, name a token, pass a
flag, or cause a login. Its entire vocabulary is the set of names you already
chose.

The permitted character set is `^[a-z0-9][a-z0-9_-]{0,31}$`, checked in three
places: the generated shell hook validates it in pure shell *before* the name
reaches any argv; `claude-profiles env` validates it again; and
`require_profile_name` validates it a third time. No dots, no slashes, no
spaces, no shell metacharacters.

An unrecognised name warns and leaves you on the primary account. It never
falls through to a *different* registered profile.

The test suites assert this on both implementations, with path traversal,
command substitution and shell metacharacters as fixtures.

---

## Things that are risky by nature

**`mirror-app` re-signs an application bundle.** On macOS it discards
Anthropic's signature for an ad-hoc one — that different identity is the whole
mechanism — which means the copy is no longer notarised and some macOS
security features degrade. On Windows it copies a package payload out of its
MSIX container, which loses package identity. Both are gated behind an
explicit confirmation that lists the costs first, and neither is ever run
implicitly.

**The install scripts pipe to a shell.** `curl | sh` and `irm | iex` are
convenient and are also exactly the pattern you should be suspicious of. Both
scripts are short and readable; download and read one before running it if you
would rather:

```bash
curl -fsSL https://raw.githubusercontent.com/inevitable-lettus/claude-profiles/main/install.sh -o install.sh
less install.sh && sh install.sh
```

Neither installer edits your shell configuration, elevates, or writes outside
your home directory.

**This is unsupported behaviour, not an API.** It drives documented
environment variables and an Electron command-line flag. An update to Claude
Code or the desktop app can invalidate any of it, and a change in where
credentials are stored could in principle change the isolation properties
described above. `claude-profiles doctor` exists so that re-checking takes one
command.
