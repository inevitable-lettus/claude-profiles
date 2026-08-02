#!/usr/bin/env bash
#
# 01-verify-desktop.sh
#
# Read-only probe. Answers the two questions that decide whether the whole
# desktop approach works:
#
#   Q1. Does Claude.app honour the --user-data-dir flag, or does it ignore
#       it and force everyone into the same profile directory?
#
#   Q2. Where does the desktop app keep its login token?
#         - Encrypted blob inside the profile directory  -> two accounts work
#         - A fixed macOS Keychain item                  -> two accounts fight
#
# Nothing here modifies your existing Claude install. The only thing it
# writes is a throwaway probe directory, which it deletes afterwards.
#
# Usage:  ./01-verify-desktop.sh
#
# ---------------------------------------------------------------------------

# Locate this script's own folder so `config.sh` resolves no matter where
# you run the script from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

require_macos

# Counters so we can print a verdict at the end.
CHECKS_FAILED=0
CHECKS_WARNED=0

note_fail() { fail "$*"; CHECKS_FAILED=$((CHECKS_FAILED + 1)); }
note_warn() { warn "$*"; CHECKS_WARNED=$((CHECKS_WARNED + 1)); }


# ===========================================================================
# STEP 1 — Is the app where we think it is, and is it actually Electron?
# ===========================================================================
check_app_exists() {
  header "Step 1: locate the Claude desktop app"

  if [ ! -d "$CLAUDE_APP" ]; then
    note_fail "Not found at $CLAUDE_APP"
    info "If Claude is installed somewhere else, edit CLAUDE_APP in config.sh"
    return
  fi
  ok "Found $CLAUDE_APP"

  # Every Electron app ships this framework bundle. If it is missing, the
  # --user-data-dir flag means nothing and this whole plan is dead.
  if [ -d "$CLAUDE_APP/Contents/Frameworks/Electron Framework.framework" ]; then
    ok "Confirmed Electron app (Electron Framework.framework present)"
  else
    note_fail "No Electron Framework found — this is not an Electron app"
    info "--user-data-dir is an Electron/Chromium flag. Without Electron it does nothing."
  fi

  # Print the version for your own notes. If the app updates and something
  # breaks later, you will want to know which version last worked.
  local version
  version="$(defaults read "$CLAUDE_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")"
  info "App version: $version"

  local bundle_id
  bundle_id="$(defaults read "$CLAUDE_APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "unknown")"
  info "Bundle identifier: $bundle_id"
}


# ===========================================================================
# STEP 2 — Does macOS allow more than one copy of this app to run?
# ===========================================================================
# If Info.plist sets LSMultipleInstancesProhibited to true, then `open -n`
# is silently ignored and macOS just brings the existing window forward.
check_multiple_instances_allowed() {
  header "Step 2: check macOS allows multiple instances"

  local prohibited
  # `defaults read` exits non-zero when the key is absent, which is the
  # common (and good) case — so swallow the error and default to 0.
  prohibited="$(defaults read "$CLAUDE_APP/Contents/Info.plist" LSMultipleInstancesProhibited 2>/dev/null || echo "0")"

  if [ "$prohibited" = "1" ]; then
    note_fail "LSMultipleInstancesProhibited is set — macOS will refuse a second instance"
    info "Workaround: the app-clone fallback (03-fallback-clone-app.sh)"
  else
    ok "LSMultipleInstancesProhibited not set — a second instance is allowed"
  fi
}


# ===========================================================================
# STEP 3 — What already exists on disk?
# ===========================================================================
check_existing_profiles() {
  header "Step 3: inspect existing profile directories"

  # Deliberately not running `du` here — the profile directory contains
  # caches that can run to gigabytes, and sizing it can hang for 10+ seconds
  # for no useful reason.
  if [ -d "$DESKTOP_PRIMARY_DIR" ]; then
    ok "Primary profile exists: $DESKTOP_PRIMARY_DIR"
  else
    note_warn "No primary profile yet — have you launched Claude desktop and logged in?"
  fi

  if [ -d "$DESKTOP_SECONDARY_DIR" ]; then
    note_warn "Secondary profile ALREADY exists: $DESKTOP_SECONDARY_DIR"
    info "Leftover from a previous attempt. Delete it if you want a clean start."
  else
    ok "Secondary profile does not exist yet (expected on first run)"
  fi
}


# ===========================================================================
# STEP 4 — The Keychain question. This is the important one.
# ===========================================================================
# Two possible storage designs:
#
#   (a) Electron safeStorage. The Keychain holds only an ENCRYPTION KEY,
#       usually named "<App> Safe Storage". The actual token is an encrypted
#       file inside the profile directory. Two profiles = two token files
#       = two accounts coexist happily.
#
#   (b) A plain Keychain generic-password item holding the token itself,
#       under one fixed name. Two profiles share that single slot, so the
#       second login overwrites the first.
#
# We look for the fingerprints of each. `security find-generic-password`
# without the -w flag reads only metadata, so macOS will NOT prompt you for
# a password and no secret is ever printed.
check_keychain_storage() {
  header "Step 4: figure out where the desktop app stores its login"

  local found_safe_storage=0
  local found_plain_item=0

  # --- Look for the safeStorage encryption key (the good outcome) ---
  local safe_storage_names=(
    "Claude Safe Storage"
    "Claude Desktop Safe Storage"
    "Chromium Safe Storage"
  )
  local name
  for name in "${safe_storage_names[@]}"; do
    if security find-generic-password -s "$name" >/dev/null 2>&1; then
      ok "Found Keychain item: \"$name\""
      info "  -> This is an encryption key, not the token itself."
      info "  -> Strongly suggests the token lives inside the profile directory."
      found_safe_storage=1
    fi
  done

  # --- Look for a plain credential item (the bad outcome) ---
  local plain_names=(
    "Claude"
    "Claude Desktop"
    "Claude-credentials"
    "Claude Desktop-credentials"
  )
  for name in "${plain_names[@]}"; do
    if security find-generic-password -s "$name" >/dev/null 2>&1; then
      note_warn "Found Keychain item: \"$name\""
      info "  -> This MIGHT be the login token stored under a fixed name."
      info "  -> If so, two desktop profiles will overwrite each other."
      found_plain_item=1
    fi
  done

  # --- Verdict ---
  if [ "$found_safe_storage" = "1" ] && [ "$found_plain_item" = "0" ]; then
    ok "Best case: safeStorage only. Two accounts should coexist."
  elif [ "$found_safe_storage" = "1" ] && [ "$found_plain_item" = "1" ]; then
    note_warn "Mixed signals — both patterns present. The manual test in Step 6 decides."
  elif [ "$found_safe_storage" = "0" ] && [ "$found_plain_item" = "1" ]; then
    note_warn "Worst case suspected: a fixed Keychain credential and no safeStorage key."
  else
    note_warn "Found neither pattern. Either you are not logged in, or the app uses"
    info "  a naming scheme this script does not know about. Step 6 will tell us."
  fi
}


# ===========================================================================
# STEP 5 — Empirically test whether --user-data-dir is honoured.
# ===========================================================================
# Static inspection cannot answer this, because the app could call
# app.setPath('userData', ...) internally and override the flag. So we just
# launch it with the flag pointed at a throwaway directory and see whether
# that directory gets populated.
probe_user_data_dir() {
  header "Step 5: test whether --user-data-dir actually works"

  # A second instance can confuse the result, so insist on a clean slate.
  if pgrep -x "Claude" >/dev/null 2>&1; then
    note_warn "Claude is currently running. Quit it fully (Cmd+Q) and re-run this script."
    info "A running instance makes this test unreliable, so it is being skipped."
    return
  fi

  local probe_dir="$HOME/Library/Application Support/Claude-ProbeTest"

  # Clean up any leftovers from a previous run.
  rm -rf "$probe_dir"

  info "Launching Claude with --user-data-dir=$probe_dir"
  info "A Claude window will open. That is expected. Do not log in."

  open -n -a "$CLAUDE_APP" --args --user-data-dir="$probe_dir"

  # Give Electron time to boot and write its initial files.
  local waited=0
  local max_wait=20
  while [ "$waited" -lt "$max_wait" ]; do
    if [ -d "$probe_dir" ] && [ -n "$(ls -A "$probe_dir" 2>/dev/null)" ]; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  # Confirm the flag actually reached the process. If macOS dropped it,
  # the result above would be a false negative and we should say so.
  if pgrep -fl "user-data-dir=$probe_dir" >/dev/null 2>&1; then
    ok "The --user-data-dir flag reached the running process"
  else
    note_warn "Could not confirm the flag in the process arguments"
  fi

  # The actual verdict.
  if [ -d "$probe_dir" ] && [ -n "$(ls -A "$probe_dir" 2>/dev/null)" ]; then
    ok "The probe directory was created AND populated"
    info "Contents: $(ls -A "$probe_dir" | tr '\n' ' ')"
    info "-> --user-data-dir is honoured. The desktop plan works."
  else
    note_fail "The probe directory is empty or missing after ${waited}s"
    info "-> The app is ignoring --user-data-dir and forcing its own path."
    info "-> Use the app-clone fallback instead: ./03-fallback-clone-app.sh"
  fi

  say ""
  say "${C_BOLD}Now quit the Claude window that just opened (Cmd+Q).${C_RESET}"
  read -r -p "Press Enter once you have quit it... " _ || true

  rm -rf "$probe_dir"
  info "Probe directory cleaned up"
}


# ===========================================================================
# STEP 6 — Instructions for the manual Keychain round-trip test.
# ===========================================================================
# This one genuinely cannot be automated: it requires typing two different
# sets of real credentials. So we print the procedure instead.
print_manual_test() {
  header "Step 6: the manual test you must do yourself"

  cat <<'EOF'
Static checks can only make an educated guess about the Keychain. This
five-minute test gives you a definitive answer. Do it BEFORE you build
launchers and get comfortable, not after.

  1. Launch Claude normally. Confirm you are logged in as ACCOUNT A.
     Quit fully with Cmd+Q. Not just closing the window — actually quit.

  2. Run:  ./02-launch-secondary.sh
     Log in as ACCOUNT B. Confirm the account in Settings.
     Quit fully with Cmd+Q.

  3. Launch Claude normally again.

  4. Look at which account you are in.

       Still ACCOUNT A  ->  PASS. The two profiles are independent.
                            You are done. Set up the launcher app.

       Now ACCOUNT B    ->  FAIL. They share one Keychain slot.
       or logged out         Run ./03-fallback-clone-app.sh instead.

Step 4 is the whole point. It is easy to stop after step 2, see account B
working, and assume success — that is the mistake to avoid.
EOF
}


# ===========================================================================
# MAIN
# ===========================================================================
main() {
  say "${C_BOLD}Claude desktop multi-profile — verification probe${C_RESET}"
  say "Nothing here modifies your existing setup."

  check_app_exists
  check_multiple_instances_allowed
  check_existing_profiles
  check_keychain_storage
  probe_user_data_dir
  print_manual_test

  header "Summary"
  if [ "$CHECKS_FAILED" -gt 0 ]; then
    fail "$CHECKS_FAILED hard failure(s), $CHECKS_WARNED warning(s)"
    say "Read the FAIL lines above before continuing."
    exit 1
  elif [ "$CHECKS_WARNED" -gt 0 ]; then
    warn "0 failures, $CHECKS_WARNED warning(s)"
    say "Probably fine. The Step 6 manual test will confirm."
    exit 0
  else
    ok "All checks passed"
    say "Next: run the Step 6 manual test, then ./04-install-launcher.sh"
    exit 0
  fi
}

main "$@"
