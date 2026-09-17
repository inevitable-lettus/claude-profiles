# Contributing

Bug reports, platform fixes and documentation corrections are all welcome. So
is telling us that something in here is wrong — much of this tool is inference
about undocumented behaviour, and inference goes stale.

---

## Before you start

Read [docs/design.md](docs/design.md). Most of what looks arbitrary in this
codebase is the record of a constraint, and that file is where the constraints
are written down. The three that catch people:

1. **macOS ships bash 3.2.** No associative arrays, no `${var,,}`, no
   `mapfile`, no `readlink -f`. If it needs bash 4, it does not run on a Mac.
2. **The auth-mode asymmetry is the point.** `CLAUDE_CONFIG_DIR` isolates the
   login on Windows and Linux but not on macOS. The token machinery is a macOS
   workaround, not the design. If you are adding token handling to a Windows
   code path, check whether you actually need it.
3. **The primary account is never written to.** No exceptions, no new code
   paths.

---

## Running the tests

```bash
./tests/smoke-test.sh          # bash implementation, fake OS in /tmp
./tests/registry-contract.sh   # bash vs PowerShell, byte for byte
```

Both must pass before a PR. The smoke test runs against stubbed `security`,
`defaults`, `codesign` and `open` in a throwaway sandbox — it never launches a
real app, reads a real Keychain, or touches your real `HOME`. Run it freely.

For the PowerShell side:

```powershell
Invoke-Pester tests/ClaudeProfiles.Tests.ps1
```

Linters, which CI also runs:

```bash
shellcheck --shell=bash --severity=warning --exclude=SC1091,SC2016 \
  bin/claude-profiles lib/*.sh tests/*.sh install.sh
```

```powershell
Invoke-ScriptAnalyzer -Path ./powershell -Recurse -Severity Error,Warning
```

---

## If you change the registry format

Three things have to move together, and CI fails if they do not:

1. `schema/profiles.schema.json` — the documented contract.
2. `reg_sort_children()` in `lib/registry.sh` — the canonical key order.
3. `$script:CpKeyRank` in `powershell/ClaudeProfiles/Private/Registry.ps1` —
   the same order again.

`tests/registry-contract.sh` feeds an identical fixture to both
implementations and compares their output byte for byte. The smoke test also
diffs the two rank tables directly, so drift is caught even without PowerShell
installed.

Adding a field means bumping nothing; changing or removing one means bumping
`REGISTRY_VERSION` and writing a migration in `registry_load`.

---

## Style

**Match the comment density.** This is the codebase's best feature and the
reason it is shell rather than a compiled binary: you can read it and see
exactly what it does to your machine. Comments here explain *why*, not what —
if you find yourself writing `# increment the counter`, delete it; if you find
yourself writing `# this has to happen before X because Y`, keep it.

**Explain the surprising thing.** If a line looks wrong until you know
something, write down the something. Half the existing comments exist because
someone would otherwise "fix" the code and break it.

**Fail loudly.** Every path that could silently fall back to the primary
account must error instead. That is the whole safety model.

**Human output goes to stderr.** stdout is reserved for machine-readable
output (`list --json`, `doctor --json`, `env`), so those can be piped without
interleaving.

---

## Adding a platform or a shell

`fish` support would be genuinely useful and is currently a stub in
`workflow_shell_init`. It needs a `fish` branch emitting the equivalent
functions plus a `--on-variable PWD` hook, and a `test_shell_integration`
case.

New OS support means a `platform_id` branch, the path conventions in
`lib/platform.sh`, a secret backend if the OS has one, and a `doctor` section.
Follow what Linux does; it is the smallest complete example.

---

## Pull requests

- One concern per PR.
- Say which platforms you actually tested on. "Untested on Windows" is a fine
  thing to write and much better than leaving it implied.
- If you found the behaviour empirically rather than in documentation, say so
  and say how — a comment recording *how* something was determined is worth as
  much as the fix.

---

## What will not be merged

Anything that automates rotating between accounts to work around usage limits:
scheduling, automatic failover, switching on a rate-limit error. Two accounts
for two genuinely separate contexts is what this tool is for, and that
distinction is stated in the README on purpose.
