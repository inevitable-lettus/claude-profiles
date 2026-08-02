#!/usr/bin/env bash
#
# shell/claude-profiles.sh
#
# Shell helpers for running Claude Code as a second account.
# Add this to your ~/.zshrc:
#
#     source "$HOME/Documents/code/claude-profiles/shell/claude-profiles.sh"
#
# Deliberately standalone — it does NOT source config.sh.
# Two reasons:
#   1. config.sh runs `set -euo pipefail`, which in an interactive shell means
#      any failing command kills your terminal session.
#   2. config.sh defines a helper named `say`, which would shadow the real
#      macOS `say` command in your shell.
#
# The cost is that the four values below are duplicated from config.sh.
# If you change PROFILE_NAME or the paths in config.sh, change them here too.
# Nothing enforces that, so it is the one place this setup can drift.
#
# ---------------------------------------------------------------------------

# --- must match config.sh ---------------------------------------------------
CLAUDE_PROFILE_NAME="work"
CLAUDE_PROFILE_CONFIG_DIR="$HOME/.claude-work"
CLAUDE_PROFILE_KEYCHAIN_SERVICE="claude-code-work-token"
CLAUDE_PROFILE_KEYCHAIN_ACCOUNT="$USER"
# ---------------------------------------------------------------------------


# _claude_profile_token
#
# Reads the OAuth token out of the macOS Keychain.
#
# Fetched fresh on every invocation, on purpose. If it were exported at shell
# startup it would sit in the environment of every process you launch — and
# `ps eww` would happily show it to anything running as your user.
#
# The first call in a login session may show a Keychain prompt. Tick
# "Always Allow" and you will not see it again.
_claude_profile_token() {
  security find-generic-password \
    -s "$CLAUDE_PROFILE_KEYCHAIN_SERVICE" \
    -a "$CLAUDE_PROFILE_KEYCHAIN_ACCOUNT" \
    -w 2>/dev/null
}


# _claude_profile_check_expiry
#
# The token from `claude setup-token` lasts one year. Warn from day 335 so
# a background job does not silently start failing auth some morning.
_claude_profile_check_expiry() {
  local created_file="$CLAUDE_PROFILE_CONFIG_DIR/.token-created"
  [ -f "$created_file" ] || return 0

  local created_epoch now_epoch days_old
  # -j = do not set the clock, -f = input format. BSD date syntax (macOS).
  created_epoch="$(date -j -f "%Y-%m-%d" "$(cat "$created_file")" "+%s" 2>/dev/null)" || return 0
  now_epoch="$(date "+%s")"
  days_old=$(( (now_epoch - created_epoch) / 86400 ))

  if [ "$days_old" -ge 365 ]; then
    printf '\033[31m[claude-%s] Token is %s days old and has almost certainly expired.\033[0m\n' \
      "$CLAUDE_PROFILE_NAME" "$days_old" >&2
    printf '           Re-run: ./05-setup-cli-profile.sh\n' >&2
  elif [ "$days_old" -ge 335 ]; then
    printf '\033[33m[claude-%s] Token is %s days old — expires in about %s days.\033[0m\n' \
      "$CLAUDE_PROFILE_NAME" "$days_old" "$(( 365 - days_old ))" >&2
  fi
}


# claude-work
#
# Run Claude Code as the secondary account. Arguments pass straight through,
# so `claude-work -p "hello"` works exactly like `claude -p "hello"`.
#
# Two environment variables do the work:
#   CLAUDE_CONFIG_DIR       separates settings, history, sessions, projects
#   CLAUDE_CODE_OAUTH_TOKEN separates the login — outranks the Keychain
#                           credential in Claude Code's precedence order
claude-work() {
  local token
  token="$(_claude_profile_token)"

  if [ -z "$token" ]; then
    printf '\033[31m[claude-%s] No token in the Keychain.\033[0m\n' "$CLAUDE_PROFILE_NAME" >&2
    printf '           Run ./05-setup-cli-profile.sh to set one up.\n' >&2
    return 1
  fi

  _claude_profile_check_expiry

  # Scoped to this one command via the `VAR=value cmd` form, so nothing
  # leaks into the surrounding shell.
  CLAUDE_CONFIG_DIR="$CLAUDE_PROFILE_CONFIG_DIR" \
  CLAUDE_CODE_OAUTH_TOKEN="$token" \
  CLAUDE_ACTIVE_PROFILE="$CLAUDE_PROFILE_NAME" \
    command claude "$@"
}


# claude-work-shell
#
# Opens a subshell where the plain `claude` command is the secondary account.
# Handy when you are working in a client project for a while and do not want
# to prefix every invocation. Type `exit` to come back.
claude-work-shell() {
  local token
  token="$(_claude_profile_token)"

  if [ -z "$token" ]; then
    printf '\033[31m[claude-%s] No token in the Keychain.\033[0m\n' "$CLAUDE_PROFILE_NAME" >&2
    return 1
  fi

  _claude_profile_check_expiry

  printf '\033[34mEntering %s profile subshell. Type "exit" to leave.\033[0m\n' \
    "$CLAUDE_PROFILE_NAME"

  CLAUDE_CONFIG_DIR="$CLAUDE_PROFILE_CONFIG_DIR" \
  CLAUDE_CODE_OAUTH_TOKEN="$token" \
  CLAUDE_ACTIVE_PROFILE="$CLAUDE_PROFILE_NAME" \
    "$SHELL"

  printf '\033[34mBack to the primary profile.\033[0m\n'
}


# claude-whoami
#
# Tells you which profile the current shell is set up to use. Run this first
# whenever you are confused about which account something ran as.
claude-whoami() {
  if [ -n "${CLAUDE_ACTIVE_PROFILE:-}" ]; then
    printf 'Profile:     %s (secondary)\n' "$CLAUDE_ACTIVE_PROFILE"
    printf 'Config dir:  %s\n' "${CLAUDE_CONFIG_DIR:-unset}"
    printf 'Auth:        CLAUDE_CODE_OAUTH_TOKEN (Keychain: %s)\n' \
      "$CLAUDE_PROFILE_KEYCHAIN_SERVICE"
  else
    printf 'Profile:     primary (default)\n'
    printf 'Config dir:  %s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    printf 'Auth:        macOS Keychain "Claude Code-credentials" via /login\n'
  fi
  printf '\n'
  printf 'For the authoritative answer, run "claude" and use /status —\n'
  printf 'that shows the account the CLI itself thinks it is using.\n'
}
