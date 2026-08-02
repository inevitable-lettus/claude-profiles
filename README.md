# claude-profiles

Run two Claude accounts on one Mac — desktop (chat + Cowork) and Claude Code CLI.

macOS only. Nothing here works on Linux or Windows, and several parts would be
unnecessary there anyway.

---

## The short version

This is **two separate problems** with two separate solutions.

| Surface | Isolation mechanism | Confidence |
|---|---|---|
| Desktop chat + Cowork | Electron `--user-data-dir` | Unverified — test it |
| Claude Code CLI | `CLAUDE_CONFIG_DIR` + `CLAUDE_CODE_OAUTH_TOKEN` | Documented, reliable |

Throughout, **primary** means the account using all the default locations —
you don't configure it at all. **Secondary** is the one that gets its own
isolated everything.

---

## Run order

```bash
cd ~/Documents/code/claude-profiles
chmod +x *.sh                 # first time only

./01-verify-desktop.sh        # probe — changes nothing
                              # then do the Step 6 manual test IN FULL
./02-launch-secondary.sh      # used during that test
./04-install-launcher.sh      # only after the test passes
./05-setup-cli-profile.sh     # CLI half — independent of the desktop half
```

`03-fallback-clone-app.sh` is only for when the Step 6 test fails.
`99-uninstall.sh` reverses everything.

The CLI half doesn't depend on the desktop half. If the desktop test fails and
you give up on it, `05` still works fine on its own.

---

## Files

```
config.sh                    all settings live here — edit this, not the scripts
01-verify-desktop.sh         read-only probe: is the desktop approach viable?
02-launch-secondary.sh       launch desktop with the secondary profile
03-fallback-clone-app.sh     escape hatch: clone the app with a new identity
04-install-launcher.sh       build a clickable "Claude Work.app"
05-setup-cli-profile.sh      set up the secondary Claude Code CLI profile
99-uninstall.sh              remove everything, with per-item prompts
shell/claude-profiles.sh     shell functions — source from ~/.zshrc
shell/envrc.example          optional direnv per-project auto-switching
tests/smoke-test.sh          runs everything against a fake macOS in /tmp
```

---

## Tests

```bash
./tests/smoke-test.sh
```

Runs in a throwaway `/tmp` sandbox with stub versions of `security`,
`defaults`, `codesign`, `open` and friends. Touches nothing real — no app is
launched, no Keychain is read or written.

It checks that every script parses, that the generated `Info.plist` is a valid
plist with a non-Anthropic bundle ID, that the generated launcher is valid bash
with the profile path baked in, that the shell helpers pass the right
environment through and don't leak the token into your shell, that the four
duplicated values haven't drifted between `config.sh` and
`shell/claude-profiles.sh`, and that nothing in the uninstaller can touch a
primary-account path.

What it **cannot** tell you: whether the real Claude app honours
`--user-data-dir`, or where it stores credentials. Only `01-verify-desktop.sh`
plus the manual test, on your actual machine, answers those.

---

## The one test that matters

Step 6 of `01-verify-desktop.sh` prints this, but it's worth repeating because
it's the thing most people get wrong:

1. Launch Claude normally. Confirm **account A**. Quit with Cmd+Q.
2. Run `./02-launch-secondary.sh`. Log in as **account B**. Quit with Cmd+Q.
3. Launch Claude normally again.
4. **Which account are you in?**

Still A → it works. Now B, or logged out → the two profiles share one Keychain
slot, and you need `03-fallback-clone-app.sh`.

**Step 4 is the whole test.** It's easy to stop after step 2, see account B
working beautifully, and declare victory. Then a week later account A randomly
logs out and you have no idea why.

---

## Why the CLI needs more than `CLAUDE_CONFIG_DIR`

From the [Claude Code authentication docs](https://code.claude.com/docs/en/authentication):

> On macOS, credentials are stored in the encrypted macOS Keychain. […] If
> you've set the `CLAUDE_CONFIG_DIR` environment variable **on Linux or
> Windows**, the `.credentials.json` file lives under that directory instead.

macOS is excluded deliberately. So on a Mac:

- `CLAUDE_CONFIG_DIR` separates settings, history, projects, sessions
- `CLAUDE_CONFIG_DIR` does **not** separate your login

Both profiles read the same Keychain item (`Claude Code-credentials`), so the
second `/login` overwrites the first.

The fix is `CLAUDE_CODE_OAUTH_TOKEN`. In the documented credential precedence
it sits at **rank 5**, above the rank 6 subscription login from `/login`, so it
wins over whatever's in the Keychain. `05-setup-cli-profile.sh` generates one
with `claude setup-token` and stores it in the Keychain under a service name of
our own (`claude-code-work-token`) that can't collide with Anthropic's.

### Two costs, both documented

**A token profile can't use Remote Control or claude.ai connectors.** Local MCP
servers still work. So put whichever account you use with claude.ai connectors
on the **primary** (Keychain) profile, and the other one on the token.

**The token expires after a year.** `05` records the creation date; the shell
helper starts warning at day 335.

---

## After setup

```bash
claude              # primary account, unchanged
claude-work         # secondary account
claude-work-shell   # subshell where plain `claude` is the secondary account
claude-whoami       # which profile is this shell on?
```

For the authoritative answer, run `claude` and use `/status` — that reports the
account the CLI itself thinks it's using, rather than what the environment
implies.

For per-project auto-switching, see `shell/envrc.example` (needs
[direnv](https://direnv.net)).

---

## Troubleshooting

**Second desktop instance doesn't open, or just focuses the existing window.**
Quit Claude fully with Cmd+Q first — closing the window isn't enough. If it
still won't, check whether `01` flagged `LSMultipleInstancesProhibited`.

**Second instance opens but is logged into the same account.**
That's the Keychain collision. Run `03-fallback-clone-app.sh`.

**Primary account gets logged out after using the secondary.**
Same thing. Same fix.

**`claude-work` says "No token in the Keychain".**
Either `05` was never run, or the service name in `shell/claude-profiles.sh`
drifted from `config.sh`. Check:
```bash
security find-generic-password -s "claude-code-work-token"
```

**`claude-work` runs as the wrong account anyway.**
Something higher in the precedence order is winning. `ANTHROPIC_API_KEY` and
`ANTHROPIC_AUTH_TOKEN` both outrank the OAuth token:
```bash
env | grep -E 'ANTHROPIC|CLAUDE'
```

**MCP servers fail in the second desktop instance.**
Each instance reads its own `claude_desktop_config.json` and spawns its own
copies. Any server that binds a fixed port will fail in whichever instance
starts second. Give the two instances different MCP configs.

**Everything broke after a Claude update.**
Expected — this is unsupported behaviour, not an API. Re-run
`01-verify-desktop.sh` to see which assumption changed. If you're on the clone
fallback, re-run `03` to refresh it.

---

## Known limitations

- Both desktop instances share one dock icon and one entry in Cmd+Tab, because
  they have the same bundle ID. The launcher gives you a separate way to *start*
  the second instance, not a separate app identity.
- The cloned app in the fallback path never auto-updates.
- Four values are duplicated between `config.sh` and `shell/claude-profiles.sh`.
  Nothing enforces that they match — it's the one place this setup can drift.
  The reason is explained in the header of the shell file.

---

## A note on which accounts

Two accounts for two genuinely separate contexts — personal and an agency,
say — is ordinary. Rotating between accounts to get around usage limits is a
different thing and is the kind of behaviour Anthropic's usage policy covers.
Worth being clear with yourself about which one you're doing before building a
workflow on it.
