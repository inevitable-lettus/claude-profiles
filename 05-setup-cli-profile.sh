#!/usr/bin/env bash
#
# 05-setup-cli-profile.sh
#
# Sets up a second Claude Code CLI profile for your secondary account.
#
# WHY THIS IS NOT JUST CLAUDE_CONFIG_DIR
# --------------------------------------
# From the Claude Code docs, on credential storage:
#
#   "On macOS, credentials are stored in the encrypted macOS Keychain.
#    ... If you've set the CLAUDE_CONFIG_DIR environment variable on Linux
#    or Windows, the .credentials.json file lives under that directory
#    instead."
#
# macOS is excluded from that sentence on purpose. So on a Mac:
#
#   CLAUDE_CONFIG_DIR  separates settings, history, projects, sessions
#   CLAUDE_CONFIG_DIR  does NOT separate your login
#
# Both profiles would read the same Keychain item ("Claude Code-credentials"),
# so the second `/login` overwrites the first.
#
# The fix is CLAUDE_CODE_OAUTH_TOKEN. In Claude Code's documented credential
# precedence it sits at rank 5, above the rank 6 subscription login from
# `/login` — so it wins over whatever is in the Keychain.
#
# The resulting arrangement:
#
#   Primary account    normal `/login`, Keychain, default ~/.claude
#   Secondary account  OAuth token + CLAUDE_CONFIG_DIR, never touches Keychain
#
# TWO COSTS, documented, decide before you run this
# -------------------------------------------------
#   1. A token profile cannot establish Remote Control sessions and cannot
#      fetch claude.ai connectors. Local MCP servers still work fine.
#      -> Put whichever account you use with claude.ai connectors on the
#         PRIMARY (Keychain) profile, and the other one here.
#   2. The token expires after one year. This script records the date and
#      the shell helper warns you before it lapses.
#
# Usage:  ./05-setup-cli-profile.sh
#
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

require_macos


# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
preflight() {
  header "Checking prerequisites"

  command -v claude >/dev/null 2>&1 || die "The 'claude' CLI is not on your PATH."
  ok "Found claude: $(command -v claude)"

  local version
  version="$(claude --version 2>/dev/null || echo "unknown")"
  info "Version: $version"

  # Purely informational. A primary login is not required for this script
  # to work, but its absence usually means you set things up out of order.
  if security find-generic-password -s "$CLI_NATIVE_KEYCHAIN_SERVICE" >/dev/null 2>&1; then
    ok "A primary Keychain login exists (\"$CLI_NATIVE_KEYCHAIN_SERVICE\")"
    info "That stays untouched — this script never writes to it."
  else
    warn "No primary Keychain login found."
    info "Consider running 'claude' and doing /login with your PRIMARY account first."
  fi
}


# ---------------------------------------------------------------------------
# 2. Create the isolated config directory
# ---------------------------------------------------------------------------
create_config_dir() {
  header "Creating config directory"

  if [ -d "$CLI_SECONDARY_CONFIG_DIR" ]; then
    ok "Already exists: $CLI_SECONDARY_CONFIG_DIR"
  else
    mkdir -p "$CLI_SECONDARY_CONFIG_DIR"
    # 700: owner-only. Session transcripts and project state live here.
    chmod 700 "$CLI_SECONDARY_CONFIG_DIR"
    ok "Created: $CLI_SECONDARY_CONFIG_DIR (mode 700)"
  fi
}


# ---------------------------------------------------------------------------
# 3. Capture the OAuth token
# ---------------------------------------------------------------------------
# `claude setup-token` is interactive: it opens a browser, then prints the
# token to the terminal. It does not save the token anywhere, so we cannot
# scrape it — the user has to paste it. `read -s` keeps it off the screen,
# and it goes straight into the Keychain, never onto disk in plaintext.
capture_token() {
  header "Generating the secondary account's OAuth token"

  if security find-generic-password \
       -s "$CLI_TOKEN_KEYCHAIN_SERVICE" \
       -a "$CLI_TOKEN_KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
    local reply
    warn "A token is already stored for this profile."
    read -r -p "Replace it? [y/N] " reply || true
    case "${reply:-}" in
      [yY]*) ;;
      *) info "Keeping the existing token."; return 0 ;;
    esac
  fi

  cat <<EOF

${C_BOLD}Do this now, in a SEPARATE terminal window:${C_RESET}

    claude setup-token

  A browser will open. ${C_BOLD}Log in with your SECONDARY account${C_RESET} — not the
  one your normal 'claude' command uses. Approve access. The token then
  prints in that terminal. Copy it.

  If the browser signs you in as the wrong account automatically, open the
  URL in a private window or sign out of claude.ai first.

EOF

  read -r -p "Press Enter once you have the token copied... " _ || true

  local token=""
  # -s suppresses echo so the token never appears on screen or in scrollback.
  read -r -s -p "Paste the token (input hidden), then Enter: " token || true
  say ""

  [ -n "$token" ] || die "No token entered. Nothing was changed."

  # Cheap sanity check. Claude Code OAuth tokens start with this prefix.
  # A warning rather than a hard failure, in case the format ever changes.
  case "$token" in
    sk-ant-oat*) ok "Token format looks right" ;;
    *) warn "Token does not start with 'sk-ant-oat'. Did you paste the right thing?" ;;
  esac

  # -U updates the item if it already exists instead of erroring.
  # -w passes the secret. It is visible in this process's arguments for an
  # instant; acceptable on a single-user machine, and the alternative
  # (a temp file) is worse.
  security add-generic-password \
    -U \
    -s "$CLI_TOKEN_KEYCHAIN_SERVICE" \
    -a "$CLI_TOKEN_KEYCHAIN_ACCOUNT" \
    -w "$token" \
    -D "Claude Code OAuth token (${PROFILE_NAME} profile)" \
    || die "Failed to write to the Keychain"

  ok "Token stored in the Keychain as \"$CLI_TOKEN_KEYCHAIN_SERVICE\""

  # Record the date so the shell helper can warn before the one-year expiry.
  date +%Y-%m-%d > "$CLI_SECONDARY_CONFIG_DIR/.token-created"
  info "Created $(cat "$CLI_SECONDARY_CONFIG_DIR/.token-created") — expires in about one year"
}


# ---------------------------------------------------------------------------
# 4. Tell the user how to wire up their shell
# ---------------------------------------------------------------------------
print_shell_instructions() {
  header "Wire it into your shell"

  local helper="$SCRIPT_DIR/shell/claude-profiles.sh"

  cat <<EOF
Add this one line to your ~/.zshrc:

    ${C_BOLD}source "$helper"${C_RESET}

Then reload:

    source ~/.zshrc

That gives you these commands:

    ${C_BOLD}claude-${PROFILE_NAME}${C_RESET}        run Claude Code as the secondary account
    ${C_BOLD}claude-${PROFILE_NAME}-shell${C_RESET}  open a subshell where plain 'claude' is the secondary account
    ${C_BOLD}claude-whoami${C_RESET}       show which profile the current shell is using

Your plain '${C_BOLD}claude${C_RESET}' command is untouched and stays on the primary account.
EOF
}


# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
main() {
  say "${C_BOLD}Claude Code — secondary CLI profile setup${C_RESET}"

  preflight
  create_config_dir
  capture_token
  print_shell_instructions

  header "Done"
  say "Verify it worked:"
  say "  claude-${PROFILE_NAME}    then run  /status  and check the account shown"
}

main "$@"
