#!/usr/bin/env bash
#
# tests/registry-contract.sh
#
# The one test that keeps two implementations honest.
#
# claude-profiles is written twice — bash for macOS and Linux, PowerShell for
# Windows — and both read and write the same profiles.json. A machine can
# have both (Git Bash alongside PowerShell), and people sync the registry
# between machines. So the two implementations must agree exactly on what the
# file looks like.
#
# HOW IT WORKS. A fixture registry is written in deliberately WRONG key order
# with awkward values. Each implementation is asked to read it and print its
# canonical form. The two outputs are compared byte for byte.
#
# That isolates the contract itself — the serializer and the key ordering —
# rather than the whole `add` flow, whose defaults legitimately differ per
# platform. Those differences are the smoke test's job.
#
# Skips cleanly when PowerShell is not installed, so it is safe to run
# everywhere. CI installs pwsh on all three runners so it always executes
# there.
#
# Usage:  ./tests/registry-contract.sh
# ---------------------------------------------------------------------------

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="/tmp/claude-profiles-contract-$$"
CP="$REPO_DIR/bin/claude-profiles"
MODULE="$REPO_DIR/powershell/ClaudeProfiles/ClaudeProfiles.psd1"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

printf '\033[1mclaude-profiles registry contract\033[0m\n'

PWSH=""
for candidate in pwsh powershell.exe; do
  command -v "$candidate" >/dev/null 2>&1 && { PWSH="$candidate"; break; }
done

if [ -z "$PWSH" ]; then
  printf '  \033[33mSKIP\033[0m PowerShell not installed — cannot compare implementations.\n'
  printf '       Install pwsh to run this locally; CI runs it on every platform.\n\n'
  exit 0
fi
printf '  using %s\n' "$PWSH"

mkdir -p "$SANDBOX/bash" "$SANDBOX/pwsh"

# ---------------------------------------------------------------------------
# The fixture
# ---------------------------------------------------------------------------
# Deliberately hostile to a naive serializer:
#   - keys in the wrong order at every level
#   - profile names that do not sort in insertion order
#   - a value containing a quote and a backslash
#   - an optional key present on one profile and absent on the other
#   - a desktop-only profile and a CLI-only profile
write_fixture() {
  cat > "$1" <<'EOF'
{
  "profiles": {
    "work": {
      "description": "agency \"main\" account C:\\path",
      "desktop": {
        "mirrored": "true",
        "userDataDir": "~/Library/Application Support/Claude-Work",
        "launcher": "/Applications/Claude Work.app",
        "appPath": "~/apps/Claude Work.app"
      },
      "cli": {
        "tokenCreated": "2026-08-02",
        "auth": "oauth-token",
        "configDir": "~/.claude-work",
        "tokenBackend": "keychain"
      }
    },
    "alpha": {
      "cli": {
        "auth": "config-dir",
        "configDir": "~/.claude-alpha"
      }
    },
    "gui_only": {
      "desktop": {
        "userDataDir": "~/.config/Claude-Gui",
        "appPath": "/opt/Claude/claude"
      }
    }
  },
  "version": 1
}
EOF
}

write_fixture "$SANDBOX/bash/profiles.json"
write_fixture "$SANDBOX/pwsh/profiles.json"

# ---------------------------------------------------------------------------
# Ask each implementation for its canonical form
# ---------------------------------------------------------------------------
CLAUDE_PROFILES_HOME="$SANDBOX/bash" "$CP" list --json > "$SANDBOX/from-bash.json" 2>"$SANDBOX/bash.err"
bash_rc=$?

CLAUDE_PROFILES_HOME="$SANDBOX/pwsh" "$PWSH" -NoProfile -NonInteractive -Command "
  \$ErrorActionPreference = 'Stop'
  Import-Module '$MODULE' -Force
  \$text = Get-ClaudeProfile -Json
  [IO.File]::WriteAllText('$SANDBOX/from-pwsh.json', \$text, [Text.UTF8Encoding]::new(\$false))
" > "$SANDBOX/pwsh.out" 2>"$SANDBOX/pwsh.err"
pwsh_rc=$?

FAILED=0
report_fail() {
  FAILED=1
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2"
}

if [ "$bash_rc" -ne 0 ]; then
  report_fail "bash implementation errored" "$(head -20 "$SANDBOX/bash.err")"
fi
if [ "$pwsh_rc" -ne 0 ] || [ ! -s "$SANDBOX/from-pwsh.json" ]; then
  report_fail "PowerShell implementation errored" "$(head -20 "$SANDBOX/pwsh.err")"
fi

if [ "$FAILED" -eq 0 ]; then
  if diff -u "$SANDBOX/from-bash.json" "$SANDBOX/from-pwsh.json" > "$SANDBOX/diff.txt" 2>&1; then
    printf '  \033[32mPASS\033[0m both implementations produce identical canonical JSON\n'
  else
    report_fail "canonical JSON differs between implementations" "$(cat "$SANDBOX/diff.txt")"
  fi

  # Both must also be readable by our own parser, and must round-trip: the
  # canonical form of the canonical form is itself.
  if awk -f "$REPO_DIR/lib/json.awk" < "$SANDBOX/from-bash.json" >/dev/null 2>&1; then
    printf '  \033[32mPASS\033[0m output re-parses with lib/json.awk\n'
  else
    report_fail "output re-parses with lib/json.awk"
  fi

  cp "$SANDBOX/from-bash.json" "$SANDBOX/bash/profiles.json"
  CLAUDE_PROFILES_HOME="$SANDBOX/bash" "$CP" list --json > "$SANDBOX/again.json" 2>/dev/null
  if diff -q "$SANDBOX/from-bash.json" "$SANDBOX/again.json" >/dev/null 2>&1; then
    printf '  \033[32mPASS\033[0m canonical form is a fixed point\n'
  else
    report_fail "canonical form is a fixed point" "$(diff -u "$SANDBOX/from-bash.json" "$SANDBOX/again.json")"
  fi
fi

printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '  \033[32mcontract holds\033[0m\n\n'
  exit 0
else
  printf '  \033[31mcontract broken\033[0m\n'
  printf '  The two implementations must agree byte for byte. Check the key rank\n'
  printf '  tables: reg_sort_children() in lib/registry.sh and $script:CpKeyRank\n'
  printf '  in powershell/ClaudeProfiles/Private/Registry.ps1.\n\n'
  exit 1
fi
