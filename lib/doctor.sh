# lib/doctor.sh
#
# One health check for every platform. Absorbs what used to be
# 01-verify-desktop.sh and generalises it.
#
# Two things it will never do:
#
#   - Print a secret. Keychain lookups here omit -w, which means macOS reads
#     metadata only and never prompts you for authorisation just because you
#     ran a diagnostic.
#   - Change anything, with one bounded exception: the --user-data-dir probe
#     launches the app against a throwaway directory and deletes it again.
#     That probe is opt-in (--probe) precisely because it is the one step
#     that is not read-only.
#
# --json prints a machine-readable report on stdout and nothing else, so it
# can drive CI. Human chatter goes to stderr throughout the tool for exactly
# this reason.
# ---------------------------------------------------------------------------

DOCTOR_FAILED=0
DOCTOR_WARNED=0
DOCTOR_PASSED=0
DOCTOR_JSON=""

# Report one finding. Level is ok | warn | fail | info.
dr() {
  local level="$1" id="$2" message="$3"
  case "$level" in
    ok)   DOCTOR_PASSED=$((DOCTOR_PASSED + 1)); [ "$DOCTOR_AS_JSON" = "1" ] || ok "$message" ;;
    warn) DOCTOR_WARNED=$((DOCTOR_WARNED + 1)); [ "$DOCTOR_AS_JSON" = "1" ] || warn "$message" ;;
    fail) DOCTOR_FAILED=$((DOCTOR_FAILED + 1)); [ "$DOCTOR_AS_JSON" = "1" ] || fail "$message" ;;
    info) [ "$DOCTOR_AS_JSON" = "1" ] || info "$message" ;;
  esac
  if [ "$DOCTOR_AS_JSON" = "1" ]; then
    local entry
    entry="{\"level\":\"$level\",\"id\":\"$(json_escape "$id")\",\"message\":\"$(json_escape "$message")\"}"
    if [ -z "$DOCTOR_JSON" ]; then DOCTOR_JSON="$entry"; else DOCTOR_JSON="$DOCTOR_JSON,$entry"; fi
  fi
}

dr_header() { [ "$DOCTOR_AS_JSON" = "1" ] || header "$*"; }


# ---------------------------------------------------------------------------
# Environment: things that outrank a profile's own credential
# ---------------------------------------------------------------------------
# Claude Code's documented precedence:
#
#   1  cloud provider (CLAUDE_CODE_USE_BEDROCK / _VERTEX / _FOUNDRY)
#   2  ANTHROPIC_AUTH_TOKEN
#   3  ANTHROPIC_API_KEY
#   4  apiKeyHelper
#   5  CLAUDE_CODE_OAUTH_TOKEN     <- what an oauth-token profile uses
#   6  subscription login from /login
#
# Anything in 1-4 wins over a profile token, which is the single most common
# reason for "claude-work runs as the wrong account anyway".
doctor_check_precedence() {
  dr_header "Credential precedence"

  local clean=1

  if [ -n "${CLAUDE_CODE_USE_BEDROCK:-}${CLAUDE_CODE_USE_VERTEX:-}${CLAUDE_CODE_USE_FOUNDRY:-}" ]; then
    dr warn precedence.cloud "A cloud provider variable is set (rank 1). It outranks every profile credential."
    clean=0
  fi
  if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    dr warn precedence.auth_token "ANTHROPIC_AUTH_TOKEN is set (rank 2). It outranks every profile token."
    clean=0
  fi
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    dr warn precedence.api_key "ANTHROPIC_API_KEY is set (rank 3). It outranks every profile token."
    clean=0
  fi

  # apiKeyHelper sits at rank 4 and is easy to forget about, because it lives
  # in a settings file rather than the environment.
  local settings
  for settings in "$HOME/.claude/settings.json" "$(platform_primary_cli_config_dir)/settings.json"; do
    if [ -f "$settings" ] && grep -q '"apiKeyHelper"' "$settings" 2>/dev/null; then
      dr warn precedence.api_key_helper "apiKeyHelper is configured in $settings (rank 4). It outranks every profile token."
      clean=0
      break
    fi
  done

  [ "$clean" = "1" ] && dr ok precedence.clean "Nothing in the environment outranks a profile credential"
}


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------
doctor_check_registry() {
  dr_header "Registry"

  local path; path="$(registry_path)"
  if [ ! -f "$path" ]; then
    dr warn registry.missing "No registry at $path — run: claude-profiles init"
    return
  fi
  dr ok registry.present "Registry: $path"

  local problems
  if problems="$(registry_validate)"; then
    dr ok registry.valid "Registry is internally consistent"
  else
    while IFS= read -r problem; do
      [ -n "$problem" ] && dr fail registry.invalid "$problem"
    done <<EOF
$problems
EOF
  fi

  local count; count="$(registry_count)"
  dr info registry.count "$count profile(s) registered"
}


# ---------------------------------------------------------------------------
# Per-profile: CLI half
# ---------------------------------------------------------------------------
doctor_check_cli_profile() {
  local profile="$1"
  cli_profile_configured "$profile" || return 0

  local dir auth backend age
  dir="$(cli_config_dir "$profile")"
  auth="$(cli_auth_mode "$profile")"

  if [ -d "$dir" ]; then
    dr ok "cli.$profile.dir" "[$profile] config dir exists: $dir"
  else
    dr warn "cli.$profile.dir" "[$profile] config dir does not exist yet: $dir"
  fi

  case "$auth" in
    config-dir)
      if [ "$(platform_id)" = "macos" ]; then
        # Metadata lookup only — no -w, so macOS never prompts and no secret
        # is read. See platform_macos_keychain_service for the naming.
        local svc
        if svc="$(platform_macos_keychain_service "$dir")" && have security \
           && security find-generic-password -s "$svc" >/dev/null 2>&1; then
          dr ok "cli.$profile.login" "[$profile] logged in — Keychain item \"$svc\""
        else
          dr warn "cli.$profile.login" "[$profile] no Keychain login found yet. Run: claude-profiles run $profile -- /login"
        fi
      elif [ -f "$dir/.credentials.json" ]; then
        dr ok "cli.$profile.login" "[$profile] logged in — $(path_contract "$dir")/.credentials.json"
      else
        dr warn "cli.$profile.login" "[$profile] no .credentials.json yet. Run: claude-profiles run $profile -- /login"
      fi
      ;;
    oauth-token)
      backend="$(cli_token_backend "$profile")"
      if secret_exists "$backend" "$profile"; then
        dr ok "cli.$profile.token" "[$profile] token present in $(secret_backend_label "$backend")"
      else
        dr fail "cli.$profile.token" "[$profile] no token stored. Run: claude-profiles token refresh $profile"
      fi

      if age="$(cli_token_age_days "$profile")"; then
        if [ "$age" -ge "$TOKEN_LIFETIME_DAYS" ]; then
          dr fail "cli.$profile.token_age" "[$profile] token is $age days old and has almost certainly expired"
        elif [ "$age" -ge "$TOKEN_WARN_AFTER_DAYS" ]; then
          dr warn "cli.$profile.token_age" "[$profile] token is $age days old — expires in about $(( TOKEN_LIFETIME_DAYS - age )) days"
        else
          dr ok "cli.$profile.token_age" "[$profile] token is $age days old"
        fi
      else
        dr warn "cli.$profile.token_age" "[$profile] no creation date recorded, so expiry cannot be tracked"
      fi

      if [ "$backend" = "file" ]; then
        dr warn "cli.$profile.token_backend" "[$profile] token is in a plain 0600 file, not an OS secret store"
      fi

      # Two documented costs, worth restating where someone will read them.
      dr info "cli.$profile.token_limits" "[$profile] a token profile cannot use Remote Control or claude.ai connectors; local MCP servers still work"
      dr info "cli.$profile.bare" "[$profile] 'claude --bare' ignores CLAUDE_CODE_OAUTH_TOKEN and would run as your PRIMARY account"
      if [ "$(platform_id)" = "macos" ]; then
        dr info "cli.$profile.auth_hint" "[$profile] current Claude Code isolates macOS logins per config dir; 'claude-profiles add $profile --auth config-dir' drops the token and restores connectors"
      fi
      ;;
  esac
}


# ---------------------------------------------------------------------------
# Per-profile: desktop half
# ---------------------------------------------------------------------------
doctor_check_desktop_profile() {
  local profile="$1"
  desktop_profile_configured "$profile" || return 0

  local udd app launcher
  udd="$(desktop_user_data_dir "$profile")"
  app="$(desktop_app_path "$profile")"

  if [ -e "$app" ]; then
    dr ok "desktop.$profile.app" "[$profile] app: $app"
  else
    dr fail "desktop.$profile.app" "[$profile] app not found at $app"
  fi

  if [ -d "$udd" ]; then
    dr ok "desktop.$profile.dir" "[$profile] user-data dir exists: $udd"
  else
    dr info "desktop.$profile.dir" "[$profile] user-data dir not created yet: $udd"
  fi

  if desktop_is_mirrored "$profile"; then
    local real real_ver mirror_ver
    mirror_ver="$(desktop_app_version "$app")"
    if real="$(platform_find_desktop_app)"; then
      real_ver="$(desktop_app_version "$real")"
      if [ "$real_ver" = "$mirror_ver" ]; then
        dr ok "desktop.$profile.mirror" "[$profile] mirrored app is current ($mirror_ver)"
      else
        dr warn "desktop.$profile.mirror" "[$profile] mirrored app is version $mirror_ver but the real install is $real_ver — re-run: claude-profiles mirror-app $profile"
      fi
    else
      dr warn "desktop.$profile.mirror" "[$profile] uses a mirrored app but the real install could not be found to compare against"
    fi
  fi

  launcher="$(reg_get_or ".profiles.$profile.desktop.launcher" "")"
  if [ -n "$launcher" ]; then
    if [ -e "$(path_expand "$launcher")" ]; then
      dr ok "desktop.$profile.launcher" "[$profile] launcher: $launcher"
    else
      dr warn "desktop.$profile.launcher" "[$profile] launcher recorded at $launcher but it is not there — re-run: claude-profiles install-launcher $profile"
    fi
  fi
}


# ---------------------------------------------------------------------------
# MCP port collisions
# ---------------------------------------------------------------------------
# Each desktop instance spawns its own copy of every configured MCP server.
# Any server binding a fixed port fails in whichever instance starts second,
# and the symptom at runtime is just "the server didn't work".
doctor_check_mcp_ports() {
  local names ports dupes
  names="$(registry_profiles)"
  [ -n "$names" ] || return 0

  dr_header "MCP configuration"

  local name template found=0
  ports=""
  for name in $names; do
    template="$(desktop_mcp_template_path "$name")"
    [ -f "$template" ] || continue
    found=1
    # Deliberately crude: any "--port 1234", "--port=1234" or "PORT": "1234"
    # in the template. A false positive here is a warning, not a failure.
    local p
    for p in $(grep -oE '(--port[= ]|"PORT"[[:space:]]*:[[:space:]]*")[0-9]+' "$template" 2>/dev/null \
               | grep -oE '[0-9]+$' | sort -u); do
      ports="$ports$p $name
"
    done
  done

  if [ "$found" = "0" ]; then
    dr info mcp.none "No per-profile MCP templates yet ($(templates_dir))"
    return
  fi

  dupes="$(printf '%s' "$ports" | awk 'NF { count[$1]++; who[$1] = who[$1] " " $2 } END { for (p in count) if (count[p] > 1) print p ":" who[p] }')"
  if [ -n "$dupes" ]; then
    local line
    while IFS= read -r line; do
      [ -n "$line" ] && dr warn mcp.port_collision "Fixed port ${line%%:*} is used by more than one profile:${line#*:} — whichever instance starts second will fail to bind"
    done <<EOF
$dupes
EOF
  else
    dr ok mcp.ports "No fixed-port collisions between profile MCP templates"
  fi
}


# ---------------------------------------------------------------------------
# Platform-specific desktop checks
# ---------------------------------------------------------------------------

doctor_platform_macos() {
  dr_header "macOS desktop"

  local app
  if ! app="$(platform_find_desktop_app)"; then
    dr info platform.app "Claude desktop is not installed — skipping the desktop checks"
    return
  fi
  dr ok platform.app "Found $app"

  # Every Electron app ships this framework bundle. Without it,
  # --user-data-dir means nothing and the whole desktop plan is dead.
  if [ -d "$app/Contents/Frameworks/Electron Framework.framework" ]; then
    dr ok platform.electron "Confirmed Electron app"
  else
    dr fail platform.electron "No Electron Framework found — --user-data-dir is an Electron flag and will do nothing"
  fi

  dr info platform.version "App version: $(desktop_app_version "$app")"

  # If Info.plist sets this, `open -n` is silently ignored and macOS just
  # brings the existing window forward.
  local prohibited
  prohibited="$(defaults read "$app/Contents/Info.plist" LSMultipleInstancesProhibited 2>/dev/null || echo "0")"
  if [ "$prohibited" = "1" ]; then
    dr fail platform.multi_instance "LSMultipleInstancesProhibited is set — macOS will refuse a second instance. Use: claude-profiles mirror-app <profile>"
  else
    dr ok platform.multi_instance "A second instance is allowed"
  fi

  # Two possible credential designs, and which one is in play decides whether
  # two desktop accounts can coexist:
  #
  #   (a) Electron safeStorage. The Keychain holds only an ENCRYPTION KEY.
  #       The token is an encrypted file inside the user-data directory, so
  #       two directories are two tokens. This is the good outcome.
  #   (b) A plain generic-password item holding the token under one fixed
  #       name. Both profiles share the slot and the second login wins.
  #
  # No -w flag anywhere below: metadata only, so macOS never prompts.
  local found_safe=0 found_plain=0 name
  for name in "Claude Safe Storage" "Claude Desktop Safe Storage" "Chromium Safe Storage"; do
    security find-generic-password -s "$name" >/dev/null 2>&1 && found_safe=1
  done
  for name in "Claude" "Claude Desktop" "Claude-credentials" "Claude Desktop-credentials"; do
    security find-generic-password -s "$name" >/dev/null 2>&1 && found_plain=1
  done

  if [ "$found_safe" = "1" ] && [ "$found_plain" = "0" ]; then
    dr ok platform.keychain "safeStorage only — two desktop accounts should coexist"
  elif [ "$found_safe" = "1" ] && [ "$found_plain" = "1" ]; then
    dr warn platform.keychain "Both credential patterns present. The manual round-trip test below decides."
  elif [ "$found_plain" = "1" ]; then
    dr warn platform.keychain "A fixed Keychain credential and no safeStorage key — two profiles may fight. Run the manual test below."
  else
    dr info platform.keychain "Neither pattern found — either not logged in, or a naming scheme this build does not know"
  fi
}

doctor_platform_linux() {
  dr_header "Linux desktop"

  local app
  if ! app="$(platform_find_desktop_app)"; then
    dr info platform.app "Claude desktop is not installed — skipping the desktop checks"
    return
  fi
  dr ok platform.app "Found $app"
  dr ok platform.credentials "On Linux the desktop credential blob lives inside the user-data directory, so profiles cannot collide"
  is_wsl && dr warn platform.wsl "This is WSL. The CLI half works natively; driving the Windows desktop app from here is not supported — use the ClaudeProfiles PowerShell module on the Windows side."
}

doctor_platform_windows() {
  dr_header "Windows desktop"
  dr info platform.bash "You are running the bash entrypoint under $(uname -s)."
  dr info platform.module "The CLI subcommands work here. For the desktop half — MSIX detection, app mirroring and shortcuts — use the PowerShell module: Import-Module ClaudeProfiles; Invoke-ClaudeProfileDoctor"

  local app
  if app="$(platform_find_desktop_app)"; then
    dr ok platform.app "Found a direct-.exe install: $app"
    dr ok platform.flavour "That flavour accepts --user-data-dir directly — no mirroring needed"
  else
    dr warn platform.app "No install found under %LOCALAPPDATA%\\AnthropicClaude. If Claude came from the Store or an MSIX package it lives in C:\\Program Files\\WindowsApps, which is not reachable from here — run the PowerShell module's doctor."
  fi
}


# ---------------------------------------------------------------------------
# The one test that cannot be automated (macOS only)
# ---------------------------------------------------------------------------
doctor_manual_test() {
  [ "$(platform_id)" = "macos" ] || return 0
  [ "$DOCTOR_AS_JSON" = "1" ] && return 0

  # The test is about the desktop app's Keychain slot. With no desktop
  # profile registered there is nothing for it to decide, so stay quiet.
  local first="" name
  for name in $(registry_profiles); do
    desktop_profile_configured "$name" && { first="$name"; break; }
  done
  [ -n "$first" ] || return 0

  header "The manual test that actually decides it"
  cat >&2 <<EOF
Static checks can only guess about the Keychain. This five-minute test gives
a definitive answer. Do it BEFORE you build launchers and get comfortable.

  1. Launch Claude normally. Confirm you are ACCOUNT A.
     Quit fully with Cmd+Q — closing the window is not enough.

  2. Run:  claude-profiles desktop $first
     Log in as ACCOUNT B. Confirm it in Settings. Quit fully with Cmd+Q.

  3. Launch Claude normally again.

  4. Look at which account you are in.

       Still ACCOUNT A  ->  PASS. The profiles are independent.
                            Build the launcher and you are done.

       Now ACCOUNT B    ->  FAIL. They share one Keychain slot.
       or logged out         Run: claude-profiles mirror-app $first

Step 4 is the whole point. It is easy to stop after step 2, see account B
working beautifully, and declare victory — then a week later account A
logs out for no apparent reason.
EOF
}


# ---------------------------------------------------------------------------
# The --user-data-dir probe (opt-in, macOS/Linux)
# ---------------------------------------------------------------------------
# Static inspection cannot answer this: the app could call
# app.setPath('userData', ...) internally and override the flag. So launch it
# against a throwaway directory and see whether that directory gets populated.
doctor_probe() {
  local app probe waited=0
  app="$(platform_find_desktop_app)" || { dr info probe.skip "No desktop app to probe"; return; }

  dr_header "Probe: is --user-data-dir honoured?"

  if pgrep -x "Claude" >/dev/null 2>&1; then
    dr warn probe.running "Claude is running. Quit it fully (Cmd+Q) and re-run — a running instance makes this unreliable."
    return
  fi

  probe="$(platform_default_desktop_user_data_dir "probe-$$")"
  rm -rf "$probe"

  dr info probe.launch "Launching against $probe — a Claude window will open. Do not log in."
  case "$(platform_id)" in
    macos) open -n -a "$app" --args --user-data-dir="$probe" ;;
    linux) ( "$app" --user-data-dir="$probe" >/dev/null 2>&1 & ) ;;
  esac

  while [ "$waited" -lt 20 ]; do
    [ -d "$probe" ] && [ -n "$(ls -A "$probe" 2>/dev/null)" ] && break
    sleep 1
    waited=$((waited + 1))
  done

  if [ -d "$probe" ] && [ -n "$(ls -A "$probe" 2>/dev/null)" ]; then
    dr ok probe.result "The probe directory was created and populated — --user-data-dir is honoured"
  else
    dr fail probe.result "The probe directory is empty after ${waited}s — the app is ignoring --user-data-dir"
  fi

  if [ "$DOCTOR_AS_JSON" != "1" ] && [ -t 0 ]; then
    say ""
    say "${C_BOLD}Now quit the Claude window that just opened (Cmd+Q).${C_RESET}"
    printf 'Press Enter once you have... ' >&2
    read -r _ || true
  fi
  rm -rf "$probe"
  dr info probe.cleanup "Probe directory removed"
}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
doctor_run() {
  local only="$1" want_probe="$2"
  local name names

  # Load before the first check: registry_validate and registry_count both
  # read $REG_DATA, and an unloaded registry looks like a clean empty one.
  registry_load

  doctor_check_registry
  doctor_check_precedence

  if [ -n "$only" ]; then
    registry_has_profile "$only" || die "No profile called '$only'."
    names="$only"
  else
    names="$(registry_profiles)"
  fi

  if [ -n "$names" ]; then
    dr_header "Profiles"
    for name in $names; do
      doctor_check_cli_profile "$name"
      doctor_check_desktop_profile "$name"
    done
  fi

  doctor_check_mcp_ports

  case "$(platform_id)" in
    macos)   doctor_platform_macos ;;
    linux)   doctor_platform_linux ;;
    windows) doctor_platform_windows ;;
  esac

  [ "$want_probe" = "1" ] && doctor_probe

  doctor_manual_test

  if [ "$DOCTOR_AS_JSON" = "1" ]; then
    printf '{\n  "platform": "%s",\n  "failed": %d,\n  "warned": %d,\n  "findings": [%s]\n}\n' \
      "$(platform_id)" "$DOCTOR_FAILED" "$DOCTOR_WARNED" "$DOCTOR_JSON"
  else
    header "Summary"
    local tally="$DOCTOR_PASSED passed, $DOCTOR_WARNED warning(s), $DOCTOR_FAILED failure(s)"
    if [ "$DOCTOR_FAILED" -gt 0 ]; then
      fail "$tally"
    elif [ "$DOCTOR_WARNED" -gt 0 ]; then
      warn "$tally"
    else
      ok "All $DOCTOR_PASSED checks passed"
    fi
  fi

  [ "$DOCTOR_FAILED" -eq 0 ]
}
