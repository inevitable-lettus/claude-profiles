#!/usr/bin/env bash
#
# config.sh — shared settings for every script in this folder.
#
# This file is SOURCED by the other scripts, never run directly.
# Everything you might want to change lives here, so you should not
# need to edit any other script.
#
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Bash safety flags. Worth understanding since they change how errors behave:
#   -e  exit immediately if any command returns non-zero
#   -u  treat use of an undefined variable as an error
#   -o pipefail  a pipeline fails if ANY command in it fails, not just the last
# ---------------------------------------------------------------------------
set -euo pipefail

# ===========================================================================
# PROFILE NAMES
# ===========================================================================
# "Primary" is the account that uses all the default locations. You do not
# configure it at all — it is just the normal Claude install.
#
# "Secondary" is the account that gets its own isolated everything.
# Rename it if "work" is not the right word for your second account.
PROFILE_NAME="work"

# ===========================================================================
# DESKTOP APP (Claude chat + Cowork)
# ===========================================================================

# Where the real Claude desktop app is installed.
CLAUDE_APP="/Applications/Claude.app"

# Which app binary the secondary launcher actually starts.
#
# Normally this is just CLAUDE_APP — one app, two profile directories.
#
# Only change it if the Keychain round-trip test FAILED and you had to run
# 03-fallback-clone-app.sh. In that case point it at the clone:
#
#   CLAUDE_APP_SECONDARY="$HOME/Applications/Claude Work Engine.app"
#
# then re-run 04-install-launcher.sh.
CLAUDE_APP_SECONDARY="$CLAUDE_APP"

# Where 03-fallback-clone-app.sh puts the cloned bundle. Kept out of
# /Applications so it does not clutter Spotlight — you launch it through
# the launcher app, never directly.
CLONED_APP_PATH="$HOME/Applications/Claude Work Engine.app"

# Bundle identifier for the clone. Must differ from Anthropic's, because
# macOS scopes Keychain access by code signature plus bundle ID — that
# difference is the entire point of the clone.
CLONED_BUNDLE_ID="local.claudeprofiles.engine.${PROFILE_NAME:-work}"

# The default (primary account) Electron profile directory. Read-only for us —
# we never touch it, we just need to know the path to compare against.
DESKTOP_PRIMARY_DIR="$HOME/Library/Application Support/Claude"

# The secondary account's Electron profile directory. This is the directory
# passed to --user-data-dir. Everything the second desktop instance stores
# (credentials blob, MCP config, window state, caches) lands here.
DESKTOP_SECONDARY_DIR="$HOME/Library/Application Support/Claude-Work"

# Name of the launcher app this repo generates, and where it gets installed.
LAUNCHER_APP_NAME="Claude Work"
LAUNCHER_APP_PATH="/Applications/${LAUNCHER_APP_NAME}.app"

# ===========================================================================
# CLAUDE CODE CLI
# ===========================================================================

# Config directory for the secondary CLI profile. This holds settings,
# session history, and per-project state — but NOT credentials on macOS.
# Credentials are handled separately via the OAuth token below.
CLI_SECONDARY_CONFIG_DIR="$HOME/.claude-${PROFILE_NAME}"

# macOS Keychain entry where we store the secondary account's OAuth token.
# We use a custom service name so it can never collide with the one Claude
# Code itself uses ("Claude Code-credentials").
CLI_TOKEN_KEYCHAIN_SERVICE="claude-code-${PROFILE_NAME}-token"
CLI_TOKEN_KEYCHAIN_ACCOUNT="$USER"

# The Keychain service name Claude Code uses for its own OAuth login.
# We only ever READ this to detect whether a primary login exists.
CLI_NATIVE_KEYCHAIN_SERVICE="Claude Code-credentials"

# ===========================================================================
# OUTPUT HELPERS
# ===========================================================================
# Colours are disabled automatically when output is piped to a file, so logs
# do not fill up with escape codes.

if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

# say    — normal progress message
# ok     — something succeeded / a check passed
# warn   — something is off but not fatal
# fail   — a check failed (does NOT exit; caller decides)
# die    — fatal, prints and exits 1
# header — section divider

say()    { printf '%s\n' "$*"; }
ok()     { printf '%s  OK  %s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()   { printf '%s WARN %s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail()   { printf '%s FAIL %s %s\n' "$C_RED" "$C_RESET" "$*"; }
info()   { printf '%s INFO %s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
die()    { printf '%s FATAL%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

header() {
  printf '\n%s=== %s ===%s\n' "$C_BOLD" "$*" "$C_RESET"
}

# require_macos — every script here is macOS-only, so bail early elsewhere.
require_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    die "These scripts are macOS-only. Detected: $(uname -s)"
  fi
}
