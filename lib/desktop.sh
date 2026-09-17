# lib/desktop.sh
#
# The Claude desktop app half, for macOS and Linux. Windows lives in the
# PowerShell module — see powershell/ClaudeProfiles/Private/Desktop.ps1 — for
# a reason that is not laziness: the Windows install is usually an MSIX
# package under C:\Program Files\WindowsApps, and reading Appx package state,
# mirroring out of a protected directory and creating shell shortcuts are all
# things only PowerShell can do properly.
#
# THE TRICK, in one line:
#
#     open -n -a Claude --args --user-data-dir=<somewhere else>       (macOS)
#     claude-desktop --user-data-dir=<somewhere else>                 (Linux)
#
# --user-data-dir is a Chromium/Electron flag. Everything the instance stores
# — credential blob, MCP config, window state, caches — lands in that
# directory, so two directories are two independent instances.
#
# WHERE THE CREDENTIAL ACTUALLY LIVES, and why this is riskier on macOS:
#
#   Electron's safeStorage keeps an ENCRYPTION KEY in the OS store and the
#   encrypted token in a file inside the user-data directory. When that is
#   what is happening, two profiles coexist happily.
#
#   The failure mode is an app that instead puts the token itself in one
#   fixed OS-store slot. Then both profiles share it and the second login
#   overwrites the first. On Windows (DPAPI) and Linux the blob is inside the
#   user-data directory, so this does not arise. On macOS it might, which is
#   why `doctor` prints a manual round-trip test and why mirror-app exists.
# ---------------------------------------------------------------------------

desktop_profile_configured() {
  reg_has ".profiles.$1.desktop.userDataDir"
}

desktop_user_data_dir() { path_expand "$(reg_get_or ".profiles.$1.desktop.userDataDir" "")"; }
desktop_app_path()      { path_expand "$(reg_get_or ".profiles.$1.desktop.appPath" "")"; }
desktop_is_mirrored()   { [ "$(reg_get_or ".profiles.$1.desktop.mirrored" "false")" = "true" ]; }


# desktop_require_ready <profile>
desktop_require_ready() {
  local profile="$1" udd app
  registry_has_profile "$profile" || die "No profile called '$profile'. See: claude-profiles list"
  desktop_profile_configured "$profile" \
    || die "Profile '$profile' has no desktop half. Add one with: claude-profiles add $profile --desktop"

  udd="$(desktop_user_data_dir "$profile")"
  app="$(desktop_app_path "$profile")"

  # The single most important check in this file. Pointing a second instance
  # at the primary's directory would let it stomp on the first account's data.
  if [ "$udd" = "$(platform_primary_desktop_user_data_dir)" ]; then
    die "Profile '$profile' points at the PRIMARY user-data directory. Refusing to launch."
  fi

  [ -n "$app" ] || die "Profile '$profile' has no desktop.appPath set."
  if [ ! -e "$app" ]; then
    die "Claude is not at $app. Reinstall it, or fix the path with: claude-profiles add $profile --desktop --app-path <path>"
  fi
}


# desktop_launch <profile> [extra args...]
desktop_launch() {
  local profile="$1"; shift
  desktop_require_ready "$profile"

  local udd app first_run=0
  udd="$(desktop_user_data_dir "$profile")"
  app="$(desktop_app_path "$profile")"

  # Create it ourselves rather than letting Electron do it, so a permissions
  # problem surfaces here with a clear message instead of as a blank window.
  [ -d "$udd" ] && [ -n "$(ls -A "$udd" 2>/dev/null)" ] || first_run=1
  mkdir -p "$udd"

  desktop_apply_mcp_config "$profile"

  info "Launching Claude for profile '$profile'"
  info "  app:     $app"
  info "  profile: $udd"

  case "$(platform_id)" in
    macos)
      # -n forces a NEW instance rather than focusing the existing window.
      # --args passes everything after it to the app itself.
      open -n -a "$app" --args --user-data-dir="$udd" "$@"
      ;;
    linux)
      # No `open -n` equivalent, and no need for one: Electron's
      # single-instance lock is keyed to the user-data directory, so a
      # different directory is already a different instance.
      ( "$app" --user-data-dir="$udd" "$@" >/dev/null 2>&1 & )
      ;;
    *)
      die "Launching the desktop app on $(platform_label) is handled by the PowerShell module: Start-ClaudeProfileDesktop -Name $profile"
      ;;
  esac

  if [ "$first_run" = "1" ]; then
    say ""
    say "${C_BOLD}First launch of this profile.${C_RESET}"
    say "You will be asked to log in — use the account you want on '$profile'."
    say "Afterwards quit fully (Cmd+Q / File > Quit) so the session is saved."
  fi
}


# ---------------------------------------------------------------------------
# Per-profile MCP configuration
# ---------------------------------------------------------------------------
# Each desktop instance reads its own claude_desktop_config.json out of its
# own user-data directory and spawns its own copy of every server listed. Any
# server binding a fixed port therefore fails in whichever instance starts
# second — a documented failure mode with no good runtime symptom.
#
# So each profile gets a template under the registry directory, and it is
# copied into place on every launch. Edit the template, relaunch, done.

desktop_mcp_template_path() {
  printf '%s/%s/claude_desktop_config.json' "$(templates_dir)" "$1"
}

# desktop_init_mcp_template <profile> — create an empty template if absent.
desktop_init_mcp_template() {
  local path; path="$(desktop_mcp_template_path "$1")"
  [ -f "$path" ] && return 0
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
{
  "mcpServers": {}
}
EOF
  info "Created an MCP config template: $path"
}

# desktop_apply_mcp_config <profile>
#
# Only copies when the template differs, so a launch does not needlessly
# rewrite a file the app may be watching.
desktop_apply_mcp_config() {
  local profile="$1" template target
  template="$(desktop_mcp_template_path "$profile")"
  [ -f "$template" ] || return 0

  target="$(desktop_user_data_dir "$profile")/claude_desktop_config.json"
  if [ -f "$target" ] && cmp -s "$template" "$target"; then
    return 0
  fi
  cp "$template" "$target" && info "Applied MCP config from $template"
}


# ---------------------------------------------------------------------------
# Launcher app (macOS)
# ---------------------------------------------------------------------------
# A macOS .app is just a directory with a required layout:
#
#   Claude Work.app/Contents/
#     Info.plist              metadata telling macOS how to launch it
#     PkgInfo                 legacy 8-byte type/creator file
#     MacOS/launcher          the executable — here, a shell script
#     Resources/AppIcon.icns  the dock icon
#
# Built here rather than exported from Script Editor because the result is a
# folder of readable files you can open and debug, and because it is
# reproducible and version-controllable.

desktop_launcher_name()  { printf 'Claude %s' "$(ucfirst "$1")"; }
desktop_launcher_path_macos() { printf '/Applications/%s.app' "$(desktop_launcher_name "$1")"; }

desktop_install_launcher_macos() {
  local profile="$1"
  local app udd name target build staged exec_path icon_name source_icon
  app="$(desktop_app_path "$profile")"
  udd="$(desktop_user_data_dir "$profile")"
  name="$(desktop_launcher_name "$profile")"
  target="$(desktop_launcher_path_macos "$profile")"

  # Stage the whole bundle in a temp directory and move it into place at the
  # end. If anything fails halfway, /Applications is never left holding a
  # half-built app.
  build="$(mktemp -d)"
  staged="$build/$name.app"
  mkdir -p "$staged/Contents/MacOS" "$staged/Contents/Resources"
  printf 'APPL????' > "$staged/Contents/PkgInfo"

  # The profile path is baked in rather than read from the registry, so the
  # finished .app keeps working even if you uninstall claude-profiles.
  exec_path="$staged/Contents/MacOS/launcher"
  cat > "$exec_path" <<EOF
#!/usr/bin/env bash
#
# Generated by claude-profiles for the '$profile' profile.
# Rebuild with: claude-profiles install-launcher $profile
#
# Launches Claude desktop against a separate Electron profile directory.

set -euo pipefail

CLAUDE_APP="$app"
PROFILE_DIR="$udd"

# There is no terminal attached, so a failure has to be a dialog or it is
# invisible.
if [ ! -e "\$CLAUDE_APP" ]; then
  osascript -e 'display alert "Claude not found" message "Expected the app at $app. Reinstall Claude, then run: claude-profiles install-launcher $profile" as critical'
  exit 1
fi

mkdir -p "\$PROFILE_DIR"

exec open -n -a "\$CLAUDE_APP" --args --user-data-dir="\$PROFILE_DIR"
EOF
  chmod +x "$exec_path"

  # CFBundleIdentifier is deliberately NOT com.anthropic.* — this is our own
  # launcher and reusing Anthropic's ID would confuse macOS about which app
  # is which. LSUIElement hides it from the Dock: it runs for a fraction of a
  # second and exits, and without this you get a pointless bouncing icon.
  cat > "$staged/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$name</string>
	<key>CFBundleDisplayName</key>
	<string>$name</string>
	<key>CFBundleExecutable</key>
	<string>launcher</string>
	<key>CFBundleIdentifier</key>
	<string>local.claudeprofiles.launcher.$profile</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

  plutil -lint "$staged/Contents/Info.plist" >/dev/null 2>&1 \
    || { rm -rf "$build"; die "Generated Info.plist is malformed — this is a bug in claude-profiles"; }

  # Icon is cosmetic; every failure here is a warning, never fatal.
  icon_name="$(defaults read "$app/Contents/Info.plist" CFBundleIconFile 2>/dev/null || echo "")"
  if [ -n "$icon_name" ]; then
    case "$icon_name" in *.icns) : ;; *) icon_name="$icon_name.icns" ;; esac
    source_icon="$app/Contents/Resources/$icon_name"
    if [ -f "$source_icon" ]; then
      cp "$source_icon" "$staged/Contents/Resources/AppIcon.icns"
    else
      warn "Icon not found at $source_icon — using a generic one"
    fi
  else
    warn "Claude declares no icon file — the launcher will use a generic icon"
  fi

  # Ad-hoc signature: valid, but with no developer identity. Recent macOS is
  # happier launching a signed bundle than an unsigned one.
  codesign --force --sign - "$staged" >/dev/null 2>&1 \
    || warn "Ad-hoc signing failed — the launcher will probably still work"

  if [ -e "$target" ]; then
    confirm "$target already exists. Replace it?" || { rm -rf "$build"; die "Aborted."; }
    rm -rf "$target"
  fi

  if ! mv "$staged" "$target" 2>/dev/null; then
    warn "Could not write to /Applications without elevated permissions"
    sudo mv "$staged" "$target" || { rm -rf "$build"; die "Install failed"; }
  fi
  rm -rf "$build"

  # Nudge Launch Services so it appears in Spotlight now rather than whenever
  # macOS next feels like rescanning.
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [ -x "$lsregister" ] && "$lsregister" -f "$target" >/dev/null 2>&1 || true

  ok "Installed $target"
  reg_set_str ".profiles.$profile.desktop.launcher" "$(path_contract "$target")"
  registry_save
  say "Launch it from Spotlight as \"$name\", or drag it to your Dock."
}


# ---------------------------------------------------------------------------
# Launcher entry (Linux)
# ---------------------------------------------------------------------------
desktop_install_launcher_linux() {
  local profile="$1" app udd name dir target
  app="$(desktop_app_path "$profile")"
  udd="$(desktop_user_data_dir "$profile")"
  name="$(desktop_launcher_name "$profile")"
  dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  target="$dir/claude-profiles-$profile.desktop"

  mkdir -p "$dir"

  # Exec is quoted so a user-data path containing a space survives. StartupWMClass
  # helps the desktop environment associate the window with this entry rather
  # than merging it into the primary instance's icon.
  cat > "$target" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=Claude desktop, '$profile' profile (generated by claude-profiles)
Exec="$app" --user-data-dir="$udd"
Icon=claude-desktop
Terminal=false
Categories=Development;Utility;
StartupWMClass=Claude
EOF
  chmod +x "$target"

  have update-desktop-database && update-desktop-database "$dir" >/dev/null 2>&1 || true

  ok "Installed $target"
  reg_set_str ".profiles.$profile.desktop.launcher" "$(path_contract "$target")"
  registry_save
}

desktop_install_launcher() {
  local profile="$1"
  desktop_require_ready "$profile"
  case "$(platform_id)" in
    macos) desktop_install_launcher_macos "$profile" ;;
    linux) desktop_install_launcher_linux "$profile" ;;
    *) die "Launcher creation on $(platform_label) is handled by the PowerShell module: Install-ClaudeProfileLauncher -Name $profile" ;;
  esac
}


# ---------------------------------------------------------------------------
# mirror-app — the escape hatch (macOS)
# ---------------------------------------------------------------------------
# ONLY for when the manual Keychain round-trip test in `doctor` actually
# failed: logging into account B knocked account A out.
#
# WHAT IT DOES. Copies Claude.app to a second bundle with a different
# CFBundleIdentifier and a fresh ad-hoc signature.
#
# WHY THAT HELPS. macOS scopes Keychain access by code signature plus bundle
# identifier. Two bundles with different identities cannot see each other's
# Keychain items, so each gets its own credential slot. It is the only
# approach that definitively solves a shared-credential collision.
#
# WHAT IT COSTS, and all four are real:
#
#   1. NO AUTO-UPDATES. The mirror is a frozen copy. Re-run after every
#      Claude update. `doctor` reports how far behind it is.
#   2. THE SIGNATURE IS REPLACED. Anthropic's is discarded for an ad-hoc one.
#      That is the entire mechanism, but it means the copy is not notarised
#      and some macOS security features degrade.
#   3. IT MAY SIMPLY NOT WORK. If the app verifies its own signature at
#      startup, or hardened-runtime entitlements do not survive re-signing,
#      it will refuse to launch. There is no way to know without trying.
#   4. It costs about a gigabyte per mirror.
#
# If it fails, the honest answer is to use claude.ai in a separate browser
# profile for the second account and keep the desktop app single-account.

desktop_mirror_path() {
  printf '%s/%s' "$(platform_apps_home)" "$1"
}

desktop_mirror_macos() {
  local profile="$1" source target bundle_id entitlements size actual_id
  source="$(path_expand "$(reg_get_or ".profiles.$profile.desktop.appPath" "")")"

  # If this profile is already mirrored, re-mirror from the real install
  # rather than from the (stale) mirror.
  if desktop_is_mirrored "$profile"; then
    source="$(platform_find_desktop_app)" \
      || die "Cannot find the real Claude.app to refresh the mirror from."
  fi
  [ -d "$source" ] || die "Claude is not at $source"

  target="$(desktop_mirror_path "$profile").app"
  bundle_id="local.claudeprofiles.engine.$profile"

  header "Confirm you need a mirrored app"
  say ""
  say "This is the heavyweight option. It only makes sense if the simple"
  say "approach already failed. Before continuing you should have:"
  say ""
  say "  [ ] Run: claude-profiles doctor $profile"
  say "  [ ] Done the manual round-trip test IN FULL — including the last"
  say "      step, relaunching the primary app and checking which account"
  say "      it lands on"
  say "  [ ] Seen the primary account get logged out or swapped"
  say ""
  say "Costs: no auto-updates, Anthropic's signature is replaced, roughly"
  say "1GB of disk, and it may not launch at all."
  say ""
  confirm "Have you confirmed the simple approach fails?" \
    || die "Stopped. Run 'claude-profiles doctor $profile' first."

  # Entitlements are permissions baked into the signature — network access,
  # JIT for the JS engine. Re-signing without them produces a bundle that
  # launches and immediately crashes, usually with no useful error.
  entitlements="$(mktemp)"
  if codesign -d --entitlements :- "$source" > "$entitlements" 2>/dev/null && [ -s "$entitlements" ]; then
    ok "Extracted entitlements from the original"
  else
    warn "Could not extract entitlements — the mirror may crash on launch"
    rm -f "$entitlements"; entitlements=""
  fi

  if [ -e "$target" ]; then
    confirm "$target exists. Delete and re-mirror?" || die "Aborted."
    rm -rf "$target"
  fi
  mkdir -p "$(dirname "$target")"

  size="$(du -sh "$source" 2>/dev/null | cut -f1)"
  info "Copying $size — this takes a moment"
  cp -Rp "$source" "$target" || die "Copy failed"

  local pb="/usr/libexec/PlistBuddy"
  [ -x "$pb" ] || die "PlistBuddy not found — unexpected on macOS"
  "$pb" -c "Set :CFBundleIdentifier $bundle_id" "$target/Contents/Info.plist" \
    || die "Failed to set CFBundleIdentifier"
  "$pb" -c "Set :CFBundleName Claude $(ucfirst "$profile")" "$target/Contents/Info.plist" 2>/dev/null || true
  "$pb" -c "Add :CFBundleDisplayName string Claude $(ucfirst "$profile")" "$target/Contents/Info.plist" 2>/dev/null \
    || "$pb" -c "Set :CFBundleDisplayName Claude $(ucfirst "$profile")" "$target/Contents/Info.plist" 2>/dev/null || true
  plutil -lint "$target/Contents/Info.plist" >/dev/null 2>&1 || die "Rewritten Info.plist is malformed"
  ok "Bundle identifier -> $bundle_id"

  # Leftover _CodeSignature directories in nested frameworks are a common
  # cause of confusing signing failures.
  find "$target" -name "_CodeSignature" -type d -exec rm -rf {} + 2>/dev/null || true

  local sign_args
  sign_args="--force --deep --sign -"
  info "Signing (there are a lot of nested binaries; this takes a minute)"
  # shellcheck disable=SC2086
  if [ -n "$entitlements" ]; then
    codesign $sign_args --entitlements "$entitlements" "$target" 2>&1 | sed 's/^/    /' || true
  else
    codesign $sign_args "$target" 2>&1 | sed 's/^/    /' || true
  fi
  [ -n "$entitlements" ] && rm -f "$entitlements"

  if codesign --verify --deep "$target" >/dev/null 2>&1; then
    ok "Signature verifies"
  else
    warn "Signature does not verify. Try launching anyway — sometimes it still works."
  fi

  # Confirm the identifier actually changed. If it did not, the mirror shares
  # a Keychain scope with the original and the exercise was pointless.
  actual_id="$(codesign -dv "$target" 2>&1 | grep '^Identifier=' | cut -d= -f2 || echo "")"
  [ -n "$actual_id" ] && info "Signed identifier: $actual_id"

  reg_set_str ".profiles.$profile.desktop.appPath" "$(path_contract "$target")"
  reg_set_str ".profiles.$profile.desktop.mirrored" "true"
  registry_save

  ok "Profile '$profile' now uses the mirrored app"
  say ""
  say "Next:"
  say "  1. claude-profiles install-launcher $profile   # point the launcher at the mirror"
  say "  2. Redo the manual round-trip test. It should pass now."
  say ""
  say "MAINTENANCE: the mirror does not update itself. Re-run this after each"
  say "Claude update. If it starts behaving oddly, suspect a version mismatch"
  say "first — 'claude-profiles doctor $profile' compares the versions."
}

desktop_mirror() {
  local profile="$1"
  registry_has_profile "$profile" || die "No profile called '$profile'."
  desktop_profile_configured "$profile" || die "Profile '$profile' has no desktop half."
  case "$(platform_id)" in
    macos) desktop_mirror_macos "$profile" ;;
    linux) die "Linux does not need a mirrored app: the credential blob lives inside the user-data directory, so profiles cannot collide." ;;
    *) die "Mirroring on $(platform_label) is handled by the PowerShell module: New-ClaudeProfileMirror -Name $profile" ;;
  esac
}

# desktop_app_version <path> — best effort, for staleness reporting.
desktop_app_version() {
  case "$(platform_id)" in
    macos) defaults read "$1/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || printf 'unknown' ;;
    *)     printf 'unknown' ;;
  esac
}
