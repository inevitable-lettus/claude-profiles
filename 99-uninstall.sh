#!/usr/bin/env bash
#
# 99-uninstall.sh
#
# Removes everything these scripts created and puts the machine back to a
# single-account setup.
#
# It never touches your PRIMARY account: not ~/.claude, not
# ~/Library/Application Support/Claude, not the "Claude Code-credentials"
# Keychain item, not /Applications/Claude.app.
#
# Every step asks first, so you can remove some things and keep others.
#
# Usage:  ./99-uninstall.sh
#
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

require_macos

# ask_remove <description> <command...>
#
# Prompts, and runs the command only on an explicit yes. Anything other than
# y/yes is treated as no, so a stray keypress cannot delete anything.
ask_remove() {
  local description="$1"
  shift

  say ""
  read -r -p "Remove $description? [y/N] " reply || true
  case "${reply:-}" in
    [yY]*)
      if "$@"; then
        ok "Removed $description"
      else
        warn "Failed to remove $description"
      fi
      ;;
    *)
      info "Kept $description"
      ;;
  esac
}

main() {
  say "${C_BOLD}Uninstall — secondary Claude profile${C_RESET}"
  say "Your primary account is not touched by any of this."

  # --- Desktop launcher app ---
  header "Desktop launcher"
  if [ -e "$LAUNCHER_APP_PATH" ]; then
    ask_remove "the launcher app ($LAUNCHER_APP_PATH)" rm -rf "$LAUNCHER_APP_PATH"
  else
    info "No launcher app installed"
  fi

  # --- Secondary desktop profile ---
  header "Secondary desktop profile"
  if [ -d "$DESKTOP_SECONDARY_DIR" ]; then
    warn "This holds the second account's login, chat cache, and MCP config."
    warn "Deleting it means logging in again next time."
    ask_remove "the secondary desktop profile ($DESKTOP_SECONDARY_DIR)" \
      rm -rf "$DESKTOP_SECONDARY_DIR"
  else
    info "No secondary desktop profile found"
  fi

  # --- Cloned app bundle ---
  header "Cloned app bundle (fallback only)"
  if [ -e "$CLONED_APP_PATH" ]; then
    ask_remove "the cloned app ($CLONED_APP_PATH)" rm -rf "$CLONED_APP_PATH"
  else
    info "No cloned app found"
  fi

  # --- CLI config directory ---
  header "Secondary CLI config"
  if [ -d "$CLI_SECONDARY_CONFIG_DIR" ]; then
    warn "This holds session history and project state for the second account."
    ask_remove "the secondary CLI config ($CLI_SECONDARY_CONFIG_DIR)" \
      rm -rf "$CLI_SECONDARY_CONFIG_DIR"
  else
    info "No secondary CLI config found"
  fi

  # --- CLI OAuth token ---
  header "Secondary CLI token"
  if security find-generic-password \
       -s "$CLI_TOKEN_KEYCHAIN_SERVICE" \
       -a "$CLI_TOKEN_KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
    warn "Deleting the Keychain entry does NOT revoke the token itself."
    warn "To actually revoke it, remove the authorisation in your claude.ai settings."
    ask_remove "the Keychain token entry (\"$CLI_TOKEN_KEYCHAIN_SERVICE\")" \
      security delete-generic-password \
        -s "$CLI_TOKEN_KEYCHAIN_SERVICE" \
        -a "$CLI_TOKEN_KEYCHAIN_ACCOUNT"
  else
    info "No token entry found"
  fi

  # --- Manual leftovers ---
  header "Left for you to do by hand"
  cat <<EOF
These scripts cannot safely edit your dotfiles, so:

  1. Remove the source line from ~/.zshrc:
         source ".../claude-profiles/shell/claude-profiles.sh"

  2. Delete any .envrc files you copied into projects:
         find ~ -maxdepth 4 -name .envrc 2>/dev/null | xargs grep -l CLAUDE_CONFIG_DIR 2>/dev/null

  3. Revoke the OAuth token in your claude.ai account settings if you no
     longer want it valid. Deleting the local copy does not revoke it.
EOF

  header "Done"
}

main "$@"
