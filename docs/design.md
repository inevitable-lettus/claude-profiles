# Design notes

Why the tool is shaped the way it is. Read this before changing anything
structural; most of it is the record of a decision that looked arbitrary until
you knew the constraint behind it.

---

## Why two implementations

`claude-profiles` is written twice: bash for macOS and Linux, PowerShell for
Windows. That is a real cost, and it was chosen over the alternatives on
purpose.

A single Go or Rust binary would have been one codebase and better
distribution. It would also have destroyed the property this project is
actually built on: **you can read the script and see exactly what it does to
your machine.** This is a tool that touches credential stores, copies signed
application bundles, and re-signs them. "Trust me, it's a binary" is the wrong
answer for that.

Node would have added a runtime dependency to a tool whose entire job is
manipulating OS-level credential storage.

So: two implementations, one registry format, and
`tests/registry-contract.sh` to keep them honest. The contract test feeds an
identical fixture to both and compares their canonical output byte for byte.
If the two key-order tables drift, CI fails.

---

## Why the registry exists

Before 1.0 this was six numbered scripts. The profile name, its config
directory and its Keychain service name were constants in `config.sh`,
hand-copied into `shell/claude-profiles.sh` and again into
`shell/envrc.example`. Three copies, nothing enforcing that they matched, and
a whole test whose only job was to notice when they drifted.

`profiles.json` replaces all of that with one file that every code path reads:
the bash implementation, the PowerShell module, and the generated shell
integration. The old drift test is gone because the thing it policed no longer
exists.

It also unlocked N profiles. The old design could only ever have two accounts,
one of them named `work` at compile time.

### Why paths are stored with `~`

So a synced dotfiles repository is portable between machines with different
usernames. Nothing but `path_expand()` consumes them.

### Why the output is canonical

Deterministic byte-identical output means `git diff` on a synced registry is
readable, and it means the contract test can be a real comparison rather than
a semantic approximation. The key order is hand-picked (`cli` before
`desktop`, `configDir` before `auth`) so a profile reads in the order you
think about it, with anything unrecognised falling to the end alphabetically —
which keeps forward compatibility with a newer registry without reordering it.

---

## Why there is a JSON parser in awk

`lib/json.awk`. The alternatives were all worse:

- **jq** is not installed everywhere, and is routinely absent from minimal
  Linux images.
- **python3** is not guaranteed on a bare macOS without Command Line Tools.
- **A hand-rolled bash parser** is slow and fragile.

awk is on every POSIX system, and it is enough of a language to write a real
recursive-descent parser rather than a pile of regexes.

It deliberately **refuses** `\uXXXX` escapes above U+007F rather than decoding
them. awk's `sprintf("%c")` is not portable for multi-byte code points, and
silently corrupting someone's path is worse than refusing it. JSON permits raw
UTF-8, this tool always writes raw UTF-8, so it only ever bites on a
hand-edited file — and the error message says what to do.

### Why the in-memory form is flat text

macOS ships bash 3.2, which has no associative arrays. A flat
`path<TAB>type<TAB>value` line format is something `awk` and `grep` can chew
on, and it works identically in 3.2 and 5.x. Every attempt at a nested
structure in bash 3.2 ends in `eval`.

---

## The auth-mode asymmetry

This is the single most important fact in the codebase and the source of most
of its complexity.

| | Login isolated by |
|---|---|
| Windows, Linux | `CLAUDE_CONFIG_DIR` alone |
| macOS | `CLAUDE_CONFIG_DIR` + `CLAUDE_CODE_OAUTH_TOKEN` |

On Linux and Windows, setting `CLAUDE_CONFIG_DIR` relocates
`.credentials.json` into that directory. On macOS credentials live in the
Keychain under one fixed item that `CLAUDE_CONFIG_DIR` does not touch.

So the entire token apparatus — `claude setup-token`, the secret store, the
expiry countdown, the two documented costs — is a **macOS workaround, not the
design**. `platform_default_auth_mode()` is where that is encoded, and
everything else follows from it.

Getting this backwards is the easiest way to make the tool worse. If you find
yourself adding token handling to a Windows code path, check whether you
actually need it.

---

## Why the shell integration shares no code with `lib/`

Two reasons, both learned the hard way in the pre-1.0 version:

1. `lib/` is sourced by a script running under `set -euo pipefail`. In an
   interactive shell that means any failing command kills your terminal.
2. `lib/common.sh` defines a function called `say`, which would shadow the
   real macOS text-to-speech command.

The pre-1.0 fix was to hand-duplicate four constants into the shell file —
which is exactly the drift the registry exists to remove. So the generated
integration contains **no configuration at all**: every function shells out to
`claude-profiles`, which reads the registry. The only thing baked in is the
list of profile names, and only to declare the convenience functions.

The smoke test asserts both properties: sourcing must not enable `errexit`,
and no profile path may appear in the generated file.

### Why the hook does the walk-up in pure shell

`_claude_profiles_sync` runs on every directory change. Shelling out to
`claude-profiles` each time would put 30–50 ms on every `cd`. So the walk up
the tree and the name validation happen in the shell itself, and a subprocess
only starts when a `.claude-profile` file is actually found *and* its contents
differ from the current state. A directory without one costs a few `stat`
calls.

---

## `.claude-profile` is untrusted input

It arrives inside repositories you clone from other people. Treat it exactly
like any other file in a hostile repo.

**It may only select an already-registered local profile, by name.** It cannot
create a profile, name a directory, name a token, pass a flag, or cause a
login. Its entire vocabulary is the set of names you already chose.

The permitted character set — `^[a-z0-9][a-z0-9_-]{0,31}$` — is the
sanitisation boundary, and it is checked in three places: the generated shell
hook (in pure shell, before the name reaches any argv), `cmd_env`, and
`require_profile_name`. Dots are excluded because the registry's flat path
format is dot-delimited; capitals because they become a different directory on
a case-sensitive volume.

An unrecognised name warns and leaves you on the primary account. It must
**never** fall through to a different registered profile — that is precisely
the failure this feature exists to prevent.

`primary`, `default`, `all` and `none` are reserved: they name the account
this tool deliberately never manages, and a profile called `primary` would
make every error message ambiguous.

---

## The invariant: the primary account is never touched

`~/.claude`, the default desktop profile directory, and Claude Code's own
credential are read-only for this tool, forever. There is no code path that
writes to any of them.

This is what makes the whole thing safe to try. If everything goes wrong, your
main account is exactly as it was.

It is enforced in several places rather than one, because it matters more than
DRY:

- `registry_validate` refuses a registry pointing a profile at either primary
  path.
- `cmd_add` refuses at registration time.
- `cli_create_config_dir` and `desktop_require_ready` refuse at use time.
- The smoke test greps every removal in the destructive paths and asserts
  none targets a primary path, then proves at runtime that `remove` and
  `uninstall` delete nothing when they cannot ask.

---

## Failing loudly

Every code path that could plausibly fall back to the primary account fails
instead:

- `run` on a token profile with no token stored is a hard error, not a
  silent fallback.
- `env` on an unregistered profile exits non-zero and prints nothing usable,
  so the shell hook cannot mistake it for a successful switch. (`eval "$(cmd)"`
  reports the status of the `eval`, not of `cmd` — so the hook captures the
  output first and checks *that*. This was a real bug during development.)
- `doctor` checks everything at precedence rank 1–4, including `apiKeyHelper`,
  which lives in a settings file rather than the environment and is the one
  people forget.
- `run` warns when it sees `--bare`, which ignores `CLAUDE_CODE_OAUTH_TOKEN`
  and would run as the primary account.

Silently running as the wrong account is the worst thing this tool could do.
Everything above is there because it is worse than crashing.

---

## Confirmation and destructive actions

`confirm()` returns false on anything but an explicit yes, **including a
closed stdin**. Under automation, every destructive prompt declines.

`CLAUDE_PROFILES_ASSUME_YES=1` bypasses it. There is deliberately no `--yes`
flag on individual subcommands: a flag is too easy to copy out of a README
without reading what it skips, whereas an environment variable is something
you have to decide to set.

`mirror-app` has an additional gate listing its costs before it touches
anything, because it is the one operation that is slow, large, and possibly
irreversible in its effects on the app bundle.

---

## Secrets

The token is fetched at the moment of use and passed to one child process. It
is never exported at shell startup — if it were, it would sit in the
environment of everything you launch, and `ps eww` would show it to anything
running as your user.

The one exception is deliberate and announced: `claude-profiles shell` and the
auto-switch hook do export it, because that is what makes plain `claude` work
in that shell. `CLAUDE_PROFILES_AUTOSWITCH_TOKEN=0` turns the hook's half off.

`doctor` never prints a secret, and its Keychain lookups omit `-w` so macOS
reads metadata only and never prompts for authorisation just because you ran
a diagnostic.

The service name is ours (`claude-profiles-<name>-token`) and can never
collide with Claude Code's own `Claude Code-credentials`, which we only ever
read to detect whether a primary login exists.

---

## Environment variables

All of these are read by both implementations.

| Variable | Effect |
|---|---|
| `CLAUDE_PROFILES_HOME` | Override the state directory. The test suites rely on it; so can anyone wanting the registry on an encrypted volume. |
| `CLAUDE_PROFILES_ASSUME_YES=1` | Answer every confirmation with yes. Deliberately not a `--yes` flag — see above. It does **not** make the token capture non-interactive; that refuses without a terminal rather than inventing a credential. |
| `CLAUDE_PROFILES_NO_ADOPT=1` | Skip `init`'s adoption of a pre-1.0 setup. Adoption inspects real paths in the real home, which makes `init` machine-dependent — fine for a person, wrong for a test or a scripted provision. |
| `CLAUDE_PROFILES_AUTOSWITCH_TOKEN=0` | The auto-switch hook stops exporting `CLAUDE_CODE_OAUTH_TOKEN`. The config directory still switches and `claude-<name>` still works; plain `claude` falls back to the primary login. |
| `CLAUDE_PROFILES_NO_PROMPT_HOOK=1` | PowerShell only. Skip wrapping `prompt`, so importing the module has no effect on the shell. |
| `CLAUDE_PROFILES_INSTALL_DIR`, `_BIN_DIR`, `_REPO`, `_BRANCH` | Installer only. |
| `NO_COLOR` | Standard; disables colour. |

And the ones belonging to Claude Code itself, which this tool sets on child
processes and never exports globally: `CLAUDE_CONFIG_DIR`,
`CLAUDE_CODE_OAUTH_TOKEN`, plus `CLAUDE_ACTIVE_PROFILE`, which is ours — a
marker for prompts and `whoami`, read by nothing else.

---

## What is deliberately not here

- **Anything that automates rotating accounts to dodge usage limits.** No
  scheduling, no automatic failover, no switching on a rate-limit error. Two
  accounts for two separate contexts is what this is for.
- **Syncing profiles or tokens between machines.** The registry is portable
  by design; the secrets are not, and should not be.
- **Managing the primary account.** See the invariant above.
