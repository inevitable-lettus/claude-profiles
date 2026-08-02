#!/usr/bin/env bash
#
# 03-fallback-clone-app.sh
#
# ESCAPE HATCH. Do not run this unless the manual Keychain round-trip test
# in 01-verify-desktop.sh (Step 6) actually FAILED — that is, logging into
# account B knocked account A out.
#
# WHAT IT DOES
# ------------
# Copies Claude.app to a second bundle with a different CFBundleIdentifier
# and a fresh ad-hoc code signature.
#
# WHY THAT HELPS
# --------------
# macOS scopes Keychain access by code signature and bundle identifier. Two
# bundles with different identities cannot see each other's Keychain items,
# so each one gets its own credential slot. This is the only approach that
# definitively solves a shared-credential collision.
#
# WHAT IT COSTS — read before running
# -----------------------------------
#   1. NO AUTO-UPDATES. The clone is a frozen copy. When Anthropic ships an
#      update to the real app, the clone stays on the old version until you
#      re-run this script. Expect to do that every few weeks.
#
#   2. THE SIGNATURE IS REPLACED. Anthropic's signature is discarded and an
#      ad-hoc one applied. That is deliberate — a different identity is the
#      whole mechanism — but it means the clone is no longer notarised.
#      Some macOS security features degrade. Sandboxed features may misbehave
#      in ways that are hard to attribute.
#
#   3. IT MAY SIMPLY NOT WORK. If the app verifies its own signature at
#      startup, or if hardened-runtime entitlements do not survive re-signing,
#      the clone will refuse to launch or will crash. There is no way to know
#      without trying.
#
#   4. IT COSTS ~1GB of disk per clone.
#
# If this fails, the honest answer is to use claude.ai in a separate browser
# profile for the second account and keep the desktop app single-account.
#
# Usage:  ./03-fallback-clone-app.sh
#
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

require_macos

[ -d "$CLAUDE_APP" ] || die "Claude not found at $CLAUDE_APP"

# Entitlements get extracted here so they can be reapplied during signing.
ENTITLEMENTS_FILE="$SCRIPT_DIR/build/entitlements.plist"


# ---------------------------------------------------------------------------
# 0. Make the user confirm they actually need this
# ---------------------------------------------------------------------------
confirm() {
  header "Confirm you need the fallback"

  cat <<EOF
This is the heavyweight option. It only makes sense if the simple approach
already failed.

Before continuing you should have:

  [ ] Run ./01-verify-desktop.sh
  [ ] Done the Step 6 manual test in full — including step 4, relaunching
      the primary app and checking which account it lands on
  [ ] Seen the primary account get logged out or swapped

If you have not done that test, stop and do it. The simple approach is much
better if it works, and most of the time it does.

EOF

  local reply
  read -r -p "Have you confirmed the simple approach fails? [y/N] " reply || true
  case "${reply:-}" in
    [yY]*) ok "Continuing" ;;
    *) die "Stopped. Run ./01-verify-desktop.sh first." ;;
  esac
}


# ---------------------------------------------------------------------------
# 1. Extract the original entitlements
# ---------------------------------------------------------------------------
# Entitlements are permissions baked into the signature — network access,
# JIT for the JavaScript engine, and so on. Re-signing without them produces
# a bundle that launches and then immediately crashes, usually with no
# useful error message.
#
# `codesign -d --entitlements :-` dumps them; the ":-" means "write the raw
# plist to stdout".
extract_entitlements() {
  header "Extracting entitlements from the original"

  mkdir -p "$(dirname "$ENTITLEMENTS_FILE")"

  if codesign -d --entitlements :- "$CLAUDE_APP" > "$ENTITLEMENTS_FILE" 2>/dev/null \
     && [ -s "$ENTITLEMENTS_FILE" ]; then
    ok "Saved to $ENTITLEMENTS_FILE"
    info "Entitlement keys found:"
    # Pull out just the key names so you can eyeball what is being carried over.
    grep -o '<key>[^<]*</key>' "$ENTITLEMENTS_FILE" 2>/dev/null \
      | sed 's/<[^>]*>//g' \
      | sed 's/^/    /' || true
  else
    warn "Could not extract entitlements — the clone may crash on launch"
    rm -f "$ENTITLEMENTS_FILE"
  fi
}


# ---------------------------------------------------------------------------
# 2. Copy the bundle
# ---------------------------------------------------------------------------
clone_bundle() {
  header "Cloning the app bundle"

  local reply
  if [ -e "$CLONED_APP_PATH" ]; then
    warn "$CLONED_APP_PATH already exists"
    read -r -p "Delete and re-clone? [y/N] " reply || true
    case "${reply:-}" in
      [yY]*) rm -rf "$CLONED_APP_PATH" ;;
      *) die "Aborted." ;;
    esac
  fi

  mkdir -p "$(dirname "$CLONED_APP_PATH")"

  local size
  size="$(du -sh "$CLAUDE_APP" 2>/dev/null | cut -f1)"
  info "Copying $size — this takes a moment"

  # -R recursive, -p preserve permissions and timestamps.
  cp -Rp "$CLAUDE_APP" "$CLONED_APP_PATH" || die "Copy failed"

  ok "Cloned to $CLONED_APP_PATH"
}


# ---------------------------------------------------------------------------
# 3. Rewrite the identity
# ---------------------------------------------------------------------------
# PlistBuddy is Apple's plist editor. `-c` runs one command; several -c
# flags run in sequence against the same file.
rewrite_identity() {
  header "Rewriting the bundle identity"

  local plist="$CLONED_APP_PATH/Contents/Info.plist"
  local pb="/usr/libexec/PlistBuddy"

  [ -x "$pb" ] || die "PlistBuddy not found — unexpected on macOS"

  "$pb" -c "Set :CFBundleIdentifier $CLONED_BUNDLE_ID" "$plist" \
    || die "Failed to set CFBundleIdentifier"
  ok "CFBundleIdentifier -> $CLONED_BUNDLE_ID"

  # Rename so you can tell them apart in Activity Monitor and the app switcher.
  "$pb" -c "Set :CFBundleName Claude ${LAUNCHER_APP_NAME}" "$plist" 2>/dev/null || true

  # CFBundleDisplayName may not exist in the original; Add rather than Set.
  "$pb" -c "Add :CFBundleDisplayName string Claude ${LAUNCHER_APP_NAME}" "$plist" 2>/dev/null \
    || "$pb" -c "Set :CFBundleDisplayName Claude ${LAUNCHER_APP_NAME}" "$plist" 2>/dev/null \
    || true
  ok "Display name updated"

  plutil -lint "$plist" >/dev/null 2>&1 || die "Rewritten Info.plist is malformed"
  ok "Info.plist still valid"
}


# ---------------------------------------------------------------------------
# 4. Re-sign
# ---------------------------------------------------------------------------
# Editing Info.plist invalidates the existing signature, so the bundle MUST
# be re-signed or macOS will refuse to launch it.
#
#   --force   overwrite the existing signature
#   --deep    also sign nested frameworks and helper binaries. Apple
#             discourages --deep for distribution, but for a local ad-hoc
#             re-sign of someone else's bundle it is the practical option.
#   --sign -  ad-hoc: a valid signature with no developer identity
resign_bundle() {
  header "Re-signing the clone"

  # Strip the old signature first. Leftover _CodeSignature directories in
  # nested frameworks are a common cause of confusing signing failures.
  find "$CLONED_APP_PATH" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true

  local -a sign_args=(--force --deep --sign -)

  if [ -f "$ENTITLEMENTS_FILE" ]; then
    sign_args+=(--entitlements "$ENTITLEMENTS_FILE")
    info "Reapplying the original entitlements"
  fi

  info "Signing (this takes a minute — there are a lot of nested binaries)"

  if codesign "${sign_args[@]}" "$CLONED_APP_PATH" 2>&1 | sed 's/^/    /'; then
    ok "Signed"
  else
    warn "Signing reported errors — the clone may not launch"
  fi

  # Verify. A failure here is a strong hint the clone will not run.
  if codesign --verify --deep "$CLONED_APP_PATH" >/dev/null 2>&1; then
    ok "Signature verifies"
  else
    warn "Signature does not verify. Try launching anyway — sometimes it still works."
  fi

  # Confirm the identifier actually changed. If it did not, the clone shares
  # a Keychain scope with the original and this whole exercise was pointless.
  local actual_id
  actual_id="$(codesign -dv "$CLONED_APP_PATH" 2>&1 | grep '^Identifier=' | cut -d= -f2 || echo "")"
  if [ -n "$actual_id" ]; then
    info "Signed identifier: $actual_id"
  fi
}


# ---------------------------------------------------------------------------
# 5. Next steps
# ---------------------------------------------------------------------------
print_next_steps() {
  header "Next steps"

  cat <<EOF
1. Point the launcher at the clone. In config.sh, change:

       CLAUDE_APP_SECONDARY="\$CLAUDE_APP"

   to:

       CLAUDE_APP_SECONDARY="$CLONED_APP_PATH"

2. Rebuild the launcher:

       ./04-install-launcher.sh

3. Redo the Keychain round-trip test from 01-verify-desktop.sh Step 6.
   It should pass now. If it still does not, the desktop app is storing
   credentials somewhere neither approach separates — at that point use a
   browser profile for the second account.

MAINTENANCE
   The clone does not update itself. After each Claude desktop update,
   re-run this script to refresh it. If the clone starts behaving oddly or
   refusing to connect, a version mismatch is the first thing to suspect.
EOF
}


# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
main() {
  say "${C_BOLD}Fallback: cloned app bundle with a separate identity${C_RESET}"

  confirm
  extract_entitlements
  clone_bundle
  rewrite_identity
  resign_bundle
  print_next_steps
}

main "$@"
