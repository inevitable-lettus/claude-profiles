# lib/cli.sh
#
# The Claude Code CLI half: running `claude` as a profile, and managing the
# optional OAuth token.
#
# TWO AUTH MODES. config-dir is the default everywhere:
#
#   config-dir     CLAUDE_CONFIG_DIR alone. On Linux and Windows the docs are
#                  explicit that setting it relocates .credentials.json into
#                  that directory. On macOS, current Claude Code stores the
#                  login in a Keychain item whose name is derived from the
#                  config directory (platform_macos_keychain_service), so the
#                  same variable isolates it there too. You run /login once
#                  per profile and Claude Code does the rest.
#
#   oauth-token    CLAUDE_CONFIG_DIR plus CLAUDE_CODE_OAUTH_TOKEN. For CI,
#                  headless machines, and Claude Code builds old enough to
#                  keep every macOS login in one fixed Keychain item. The
#                  token sits at precedence rank 5, above the rank 6
#                  subscription login, and therefore wins over the Keychain.
#
# THE TWO COSTS OF oauth-token, both documented upstream, both surfaced by
# `doctor` and by `add` at the moment you choose it:
#
#   1. A token cannot establish Remote Control sessions and cannot fetch
#      claude.ai connectors. Locally-configured MCP servers still work. So
#      put whichever account you use with connectors on the PRIMARY profile.
#   2. It expires after a year.
#
# And one that is easy to miss: `claude --bare` does not read
# CLAUDE_CODE_OAUTH_TOKEN at all. A bare-mode script under an oauth-token
# profile silently runs as your primary account. cli_run warns when it sees
# --bare in the arguments.
# ---------------------------------------------------------------------------

# Tokens from `claude setup-token` last one year. Warn early enough that an
# unattended job does not simply start failing auth one morning.
TOKEN_LIFETIME_DAYS=365
TOKEN_WARN_AFTER_DAYS=335


# cli_profile_configured <profile> — does this profile manage a CLI account?
cli_profile_configured() {
  reg_has ".profiles.$1.cli.configDir"
}

cli_config_dir()    { path_expand "$(reg_get_or ".profiles.$1.cli.configDir" "")"; }
cli_auth_mode()     { reg_get_or ".profiles.$1.cli.auth" "$(platform_default_auth_mode)"; }
cli_token_backend() { reg_get_or ".profiles.$1.cli.tokenBackend" "$(secret_backend_default)"; }


# cli_create_config_dir <profile>
#
# 700 because session transcripts and project state live here.
cli_create_config_dir() {
  local dir; dir="$(cli_config_dir "$1")"
  [ -n "$dir" ] || die "Profile '$1' has no cli.configDir"

  if [ "$dir" = "$(platform_primary_cli_config_dir)" ]; then
    die "Refusing to use $dir — that is the primary account's config directory."
  fi

  if [ -d "$dir" ]; then
    info "Config directory already exists: $dir"
  else
    mkdir -p "$dir"
    chmod 700 "$dir" 2>/dev/null || true
    ok "Created $dir (mode 700)"
  fi
}


# ---------------------------------------------------------------------------
# Token lifecycle
# ---------------------------------------------------------------------------

# cli_token_age_days <profile> — days since the token was created, or nothing.
cli_token_age_days() {
  local created
  created="$(reg_get_or ".profiles.$1.cli.tokenCreated" "")"
  [ -n "$created" ] || return 1
  days_since "$created"
}

# cli_warn_token_expiry <profile> — the day-335 nudge.
cli_warn_token_expiry() {
  local profile="$1" age
  age="$(cli_token_age_days "$profile")" || return 0

  if [ "$age" -ge "$TOKEN_LIFETIME_DAYS" ]; then
    warn "Profile '$profile': token is $age days old and has almost certainly expired."
    info "Refresh it with: claude-profiles token refresh $profile"
  elif [ "$age" -ge "$TOKEN_WARN_AFTER_DAYS" ]; then
    warn "Profile '$profile': token is $age days old — expires in about $(( TOKEN_LIFETIME_DAYS - age )) days."
  fi
}

# cli_capture_token <profile>
#
# `claude setup-token` is interactive: it opens a browser and then prints the
# token to its own terminal. It saves it nowhere, so there is nothing for us
# to scrape — the token has to be pasted. read_secret keeps it off the screen
# and it goes straight into the OS secret store, never onto disk in plaintext.
cli_capture_token() {
  local profile="$1" backend token
  backend="$(cli_token_backend "$profile")"

  # Capturing a token needs a human to paste one. Refuse up front rather than
  # letting `read` return empty and reporting it as "no token entered" — and
  # note this path is reachable under automation, because
  # CLAUDE_PROFILES_ASSUME_YES answers the "set up the token now?" prompt with
  # yes. That variable means "do not ask me to confirm destructive things",
  # not "invent a credential".
  if [ ! -t 0 ]; then
    die "Cannot capture a token without a terminal. Run 'claude-profiles token refresh $profile' interactively, or set CLAUDE_CODE_OAUTH_TOKEN directly for CI."
  fi

  if secret_exists "$backend" "$profile"; then
    if ! confirm "A token is already stored for '$profile'. Replace it?"; then
      info "Keeping the existing token."
      return 0
    fi
  fi

  if [ "$backend" = "file" ]; then
    warn "No OS secret store available — the token will be written to $(secret_file_path "$profile") with mode 0600."
    warn "That is weaker than the Keychain/DPAPI/keyring options. Anything running as you can read it."
    confirm "Continue anyway?" || die "Stopped. Nothing was changed."
  fi

  say ""
  say "${C_BOLD}Do this now, in a SEPARATE terminal window:${C_RESET}"
  say ""
  say "    claude setup-token"
  say ""
  say "  A browser opens. ${C_BOLD}Log in with the account you want on '$profile'${C_RESET} —"
  say "  not the one your plain 'claude' command uses. Approve access. The"
  say "  token then prints in that terminal. Copy it."
  say ""
  say "  If the browser signs you in as the wrong account automatically, open"
  say "  the URL in a private window, or sign out of claude.ai first."
  say ""

  if [ -t 0 ]; then
    printf 'Press Enter once you have the token copied... ' >&2
    read -r _ || true
  fi

  token="$(read_secret "Paste the token (input hidden), then Enter: ")"
  [ -n "$token" ] || die "No token entered. Nothing was changed."

  # Cheap sanity check. A warning rather than a hard failure, because the
  # prefix is an observed convention, not a documented guarantee.
  case "$token" in
    sk-ant-oat*) ok "Token format looks right" ;;
    *) warn "Token does not start with 'sk-ant-oat'. Did you paste the right thing?" ;;
  esac

  secret_set "$backend" "$profile" "$token" \
    || die "Failed to write the token to $(secret_backend_label "$backend")"

  ok "Token stored in $(secret_backend_label "$backend")"

  reg_set_str ".profiles.$profile.cli.tokenBackend" "$backend"
  reg_set_str ".profiles.$profile.cli.tokenCreated" "$(today_iso)"
  registry_save

  info "Recorded $(today_iso) — expires in about a year."
}


# ---------------------------------------------------------------------------
# Running claude as a profile
# ---------------------------------------------------------------------------

# cli_require_ready <profile>
#
# Everything that must be true before we hand off to `claude`. Failing loudly
# here is the whole point: the alternative is silently running as the primary
# account, which is the mistake this tool exists to prevent.
cli_require_ready() {
  local profile="$1" dir auth
  registry_has_profile "$profile" || die "No profile called '$profile'. See: claude-profiles list"
  cli_profile_configured "$profile" \
    || die "Profile '$profile' has no CLI half. Add one with: claude-profiles add $profile --cli"

  dir="$(cli_config_dir "$profile")"
  [ -d "$dir" ] || {
    warn "Config directory $dir does not exist yet — creating it."
    cli_create_config_dir "$profile"
  }

  auth="$(cli_auth_mode "$profile")"
  if [ "$auth" = "oauth-token" ]; then
    local backend; backend="$(cli_token_backend "$profile")"
    secret_exists "$backend" "$profile" || die \
      "Profile '$profile' uses token auth but no token is stored in $(secret_backend_label "$backend"). Run: claude-profiles token refresh $profile"
  fi
}

# cli_warn_precedence
#
# Anything above rank 5 beats the profile's own credential. If one of these is
# set, the command below is not going to run as the account you think.
cli_warn_precedence() {
  local auth="$1"
  [ "$auth" = "oauth-token" ] || return 0

  if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    warn "ANTHROPIC_AUTH_TOKEN is set (precedence rank 2) and will outrank this profile's token."
  fi
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    warn "ANTHROPIC_API_KEY is set (precedence rank 3) and will outrank this profile's token."
  fi
}

# cli_warn_bare <profile> <auth> <args...>
#
# Bare mode does not read CLAUDE_CODE_OAUTH_TOKEN. Under an oauth-token
# profile that means falling through to the primary account's login — the
# exact failure this tool exists to prevent, and completely silent.
cli_warn_bare() {
  local profile="$1" auth="$2"; shift 2
  [ "$auth" = "oauth-token" ] || return 0
  local arg
  for arg in "$@"; do
    if [ "$arg" = "--bare" ]; then
      warn "'--bare' does not read CLAUDE_CODE_OAUTH_TOKEN, so this will NOT run as '$profile'."
      info "Bare mode needs ANTHROPIC_API_KEY or an apiKeyHelper instead."
      return 0
    fi
  done
}

# cli_run <profile> [args...]
#
# The environment is applied with the `VAR=value command` prefix form, so it
# is scoped to this one child and nothing leaks into the calling shell.
cli_run() {
  local profile="$1"; shift

  cli_require_ready "$profile"
  local dir auth
  dir="$(cli_config_dir "$profile")"
  auth="$(cli_auth_mode "$profile")"

  cli_warn_precedence "$auth"
  cli_warn_bare "$profile" "$auth" "$@"

  have claude || die "The 'claude' CLI is not on your PATH."

  if [ "$auth" = "oauth-token" ]; then
    cli_warn_token_expiry "$profile"
    local token
    token="$(secret_get "$(cli_token_backend "$profile")" "$profile")" \
      || die "Could not read the token for '$profile'."

    CLAUDE_CONFIG_DIR="$dir" \
    CLAUDE_CODE_OAUTH_TOKEN="$token" \
    CLAUDE_ACTIVE_PROFILE="$profile" \
      command claude "$@"
  else
    CLAUDE_CONFIG_DIR="$dir" \
    CLAUDE_ACTIVE_PROFILE="$profile" \
      command claude "$@"
  fi
}

# cli_shell <profile>
#
# A subshell where the plain `claude` command is this profile. Useful when you
# are in a client project for a while and do not want to prefix everything.
#
# Note the difference from cli_run: here the token genuinely is exported, into
# a shell you asked for. That is the trade the subcommand makes, and it is
# stated in the banner rather than buried.
cli_shell() {
  local profile="$1"

  cli_require_ready "$profile"
  local dir auth
  dir="$(cli_config_dir "$profile")"
  auth="$(cli_auth_mode "$profile")"

  cli_warn_precedence "$auth"

  say "${C_BLUE}Entering the '$profile' profile. Type 'exit' to leave.${C_RESET}"

  if [ "$auth" = "oauth-token" ]; then
    cli_warn_token_expiry "$profile"
    local token
    token="$(secret_get "$(cli_token_backend "$profile")" "$profile")" \
      || die "Could not read the token for '$profile'."
    info "CLAUDE_CODE_OAUTH_TOKEN is exported inside this subshell — anything you run in it can read the token."

    CLAUDE_CONFIG_DIR="$dir" \
    CLAUDE_CODE_OAUTH_TOKEN="$token" \
    CLAUDE_ACTIVE_PROFILE="$profile" \
      "${SHELL:-/bin/sh}"
  else
    CLAUDE_CONFIG_DIR="$dir" \
    CLAUDE_ACTIVE_PROFILE="$profile" \
      "${SHELL:-/bin/sh}"
  fi

  say "${C_BLUE}Back to the primary profile.${C_RESET}"
}
