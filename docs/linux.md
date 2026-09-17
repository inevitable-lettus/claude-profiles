# Linux

The easy platform. Both halves work with no workarounds, and there is nothing
here that can silently log your other account out.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/inevitable-lettus/claude-profiles/main/install.sh | sh
```

Add to `~/.bashrc` or `~/.zshrc`:

```bash
eval "$(claude-profiles shell-init bash)"   # or zsh
```

```bash
claude-profiles init
claude-profiles add work
claude-profiles doctor
```

---

## The CLI half

From [the authentication docs](https://code.claude.com/docs/en/authentication):

> On Linux, credentials are stored in `~/.claude/.credentials.json` with file
> mode `0600`. […] If you've set the `CLAUDE_CONFIG_DIR` environment variable
> on Linux or Windows, the `.credentials.json` file lives under that directory
> instead.

So `CLAUDE_CONFIG_DIR` isolates the login by itself:

```bash
claude-profiles add work --no-desktop
claude-profiles run work -- /login
```

That is the whole setup. Two config directories, two logins, no interference,
nothing that expires.

`claude-profiles add` creates the directory with mode 700, because session
transcripts and project state live in it.

### When you might still want a token

`--auth oauth-token` exists for CI and headless runs, where there is no
browser to log in with. It is not the default and you do not need it
otherwise.

Where it is stored depends on what you have:

| | Backend |
|---|---|
| `secret-tool` present (libsecret) | the session keyring |
| otherwise | a mode-0600 file under `~/.config/claude-profiles/secrets/` |

The file fallback is weaker than a keyring, and the tool says so out loud
before writing one rather than quietly downgrading.

---

## The desktop half

Desktop packaging on Linux is inconsistent, so `claude-profiles` looks for the
binary on `PATH` first and then in the usual unpacked-Electron locations. If
it cannot find yours:

```bash
claude-profiles add work --desktop --app-path /path/to/claude-desktop
```

```bash
claude-profiles desktop work
claude-profiles install-launcher work    # a .desktop entry
```

No `open -n` equivalent is needed, and none is wanted: Electron's
single-instance lock is keyed to the user-data directory, so a different
directory is already a different instance.

The launcher is a `.desktop` file in
`~/.local/share/applications/claude-profiles-<name>.desktop`.

### No mirroring, ever

`claude-profiles mirror-app` refuses to run on Linux, and says why: the
desktop credential blob lives **inside** the user-data directory, so two
profiles cannot collide. There is no shared credential slot, so there is
nothing for a separate application identity to solve.

This is the macOS problem that most of this tool's complexity exists for, and
Linux simply does not have it.

---

## WSL

WSL is Linux and is treated as Linux. The CLI half works natively.

Driving the *Windows* desktop app from inside WSL is out of scope — use the
`ClaudeProfiles` PowerShell module on the Windows side instead. `doctor`
detects WSL and says so rather than letting you wonder.

If browser login does not complete, the Claude Code docs cover it: WSL2 often
cannot reach the local callback server, so press `c` to copy the URL and paste
the resulting code back into the terminal.

---

## Where things live

```
~/.config/claude-profiles/profiles.json      the registry
~/.config/claude-profiles/profiles/<name>/   per-profile MCP template
~/.config/claude-profiles/secrets/           token file fallback, if used
~/.claude-<name>/                            that profile's CLI config
~/.config/Claude-<Name>/                     that profile's desktop data
~/.local/share/applications/                 the generated .desktop entry

~/.claude/                                   your PRIMARY account. Never touched.
~/.config/Claude/                            the primary desktop profile. Never touched.
```

`$XDG_CONFIG_HOME` and `$XDG_DATA_HOME` are respected if set.

---

## Distro notes

`awk` is the only slightly unusual dependency, and every distro has it. The
JSON parser at `lib/json.awk` is written for POSIX awk, so mawk (Debian and
Ubuntu's default), gawk and busybox awk all work — there is no gawk-only
syntax in it.

If your image is minimal enough to lack `awk` entirely, install `mawk` or
`gawk`; `install.sh` checks and tells you.
