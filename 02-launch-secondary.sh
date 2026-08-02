#!/usr/bin/env bash
#
# 02-launch-secondary.sh
#
# Launches a second instance of Claude desktop using its own profile
# directory, so it can be logged into a different account.
#
# This is the whole trick, in one command:
#
#   open -n -a Claude --args --user-data-dir=<somewhere else>
#
#     open      macOS launcher
#     -n        force a NEW instance instead of focusing the existing one
#     -a        the application to launch
#     --args    everything after this is passed to the app itself
#
# Run this directly from the terminal, or install it as a clickable app
# with ./04-install-launcher.sh
#
# Usage:  ./02-launch-secondary.sh
#
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

require_macos

[ -d "$CLAUDE_APP" ] || die "Claude not found at $CLAUDE_APP (edit CLAUDE_APP in config.sh)"

# Create the profile directory up front. Electron would create it anyway,
# but doing it here means a permissions problem surfaces now with a clear
# error rather than as a mysterious blank window later.
mkdir -p "$DESKTOP_SECONDARY_DIR"

# Refuse to run if someone has pointed the secondary at the primary path.
# That would let the second instance stomp on the first account's data.
if [ "$DESKTOP_SECONDARY_DIR" = "$DESKTOP_PRIMARY_DIR" ]; then
  die "DESKTOP_SECONDARY_DIR is the same as DESKTOP_PRIMARY_DIR. Fix config.sh."
fi

info "Launching Claude with profile: $DESKTOP_SECONDARY_DIR"

open -n -a "$CLAUDE_APP" --args --user-data-dir="$DESKTOP_SECONDARY_DIR"

# On a first run the profile directory is empty, so tell the user what to
# expect rather than letting them wonder why they are staring at a login page.
if [ -z "$(ls -A "$DESKTOP_SECONDARY_DIR" 2>/dev/null)" ]; then
  say ""
  say "${C_BOLD}First launch of this profile.${C_RESET}"
  say "You will be asked to log in — use your SECOND account."
  say "After logging in, quit fully with Cmd+Q so the session is saved."
fi
