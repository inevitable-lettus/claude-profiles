# lib/secrets.sh
#
# One interface over four OS secret stores, used for exactly one thing: the
# long-lived OAuth token that an `oauth-token` profile needs.
#
# A `config-dir` profile never comes near this file. On Linux and Windows,
# CLAUDE_CONFIG_DIR relocates .credentials.json and Claude Code manages the
# credential itself — there is no secret for us to hold. That is most
# profiles on most machines; this file is the macOS tax.
#
# WHAT WE STORE AND WHERE
#
#   keychain    macOS       `security` generic-password, service
#                           "claude-profiles-<name>-token"
#   dpapi       Windows     DPAPI-encrypted file, user-scoped, written via
#                           powershell.exe
#   libsecret   Linux       `secret-tool`, i.e. the session keyring
#   file        anywhere    mode-0600 file, and we say so out loud
#
# The service name is ours (`claude-profiles-...`) and can never collide with
# the item Claude Code itself uses ("Claude Code-credentials"). We read that
# one to detect whether a primary login exists and never write to it.
#
# THE TOKEN IS NEVER EXPORTED INTO A SHELL. It is fetched at the moment of
# use and passed to one child process. If it were exported at shell startup it
# would sit in the environment of everything you launch, and `ps eww` would
# show it to anything running as your user.
# ---------------------------------------------------------------------------

# secret_service_name <profile> — the identifier used inside whichever store.
secret_service_name() {
  printf 'claude-profiles-%s-token' "$1"
}

# The Keychain item Claude Code itself uses. Read-only for us, always.
CLAUDE_NATIVE_KEYCHAIN_SERVICE="Claude Code-credentials"


# secret_backend_available <backend>
secret_backend_available() {
  case "$1" in
    keychain)  [ "$(platform_id)" = "macos" ] && have security ;;
    libsecret) have secret-tool ;;
    dpapi)     [ "$(platform_id)" = "windows" ] && have powershell.exe ;;
    file)      return 0 ;;
    *)         return 1 ;;
  esac
}

# secret_backend_default — the best store this machine actually has.
#
# Falls all the way through to `file` rather than failing, because a profile
# that cannot store a token is useless, and a 0600 file in an already
# owner-only directory is a reasonable floor. Callers warn when they land here.
secret_backend_default() {
  case "$(platform_id)" in
    macos)
      secret_backend_available keychain && { printf 'keychain'; return; } ;;
    windows)
      secret_backend_available dpapi && { printf 'dpapi'; return; } ;;
    linux)
      secret_backend_available libsecret && { printf 'libsecret'; return; } ;;
  esac
  printf 'file'
}

# secret_backend_label <backend> — for human output.
secret_backend_label() {
  case "$1" in
    keychain)  printf 'macOS Keychain' ;;
    dpapi)     printf 'Windows DPAPI (user-scoped file)' ;;
    libsecret) printf 'libsecret / session keyring' ;;
    file)      printf 'plain file, mode 0600' ;;
    *)         printf '%s' "$1" ;;
  esac
}


# ---------------------------------------------------------------------------
# file backend
# ---------------------------------------------------------------------------
secret_file_path() {
  printf '%s/%s.token' "$(secrets_fallback_dir)" "$1"
}

secret_dpapi_path() {
  printf '%s/%s.dpapi' "$(secrets_fallback_dir)" "$1"
}

_secret_prepare_dir() {
  local dir
  dir="$(secrets_fallback_dir)"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
}


# ---------------------------------------------------------------------------
# The interface
# ---------------------------------------------------------------------------

# secret_set <backend> <profile> <value>
#
# The value arrives as an argument, which is visible in this process's own
# argv for an instant. That is acceptable on a single-user machine and the
# alternatives are worse: a temp file lingers on disk, and a pipe would mean
# the value crossing another process boundary anyway. Where a backend lets us
# avoid it — dpapi, via an environment variable — we do.
secret_set() {
  local backend="$1" profile="$2" value="$3"
  local service; service="$(secret_service_name "$profile")"

  case "$backend" in
    keychain)
      # -U updates in place instead of erroring when the item already exists.
      security add-generic-password \
        -U \
        -s "$service" \
        -a "$USER" \
        -w "$value" \
        -D "Claude Code OAuth token (claude-profiles: $profile)" \
        >/dev/null 2>&1
      ;;
    libsecret)
      printf '%s' "$value" | secret-tool store --label="Claude Code OAuth token ($profile)" \
        service "$service" account "$USER" >/dev/null 2>&1
      ;;
    dpapi)
      _secret_prepare_dir
      # The value goes through the environment rather than the command line,
      # so it never appears in a process listing on the Windows side.
      CP_SECRET_IN="$value" CP_SECRET_OUT="$(secret_dpapi_path "$profile")" \
        powershell.exe -NoProfile -NonInteractive -Command \
        '$env:CP_SECRET_IN | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -NoNewline -Path $env:CP_SECRET_OUT' \
        >/dev/null 2>&1
      ;;
    file)
      _secret_prepare_dir
      local path; path="$(secret_file_path "$profile")"
      # Create the file empty and lock it down BEFORE the secret goes in, so
      # there is no window where it exists world-readable.
      : > "$path"
      chmod 600 "$path"
      printf '%s' "$value" > "$path"
      ;;
    *)
      return 1
      ;;
  esac
}

# secret_get <backend> <profile> — print the token, or nothing and return 1.
secret_get() {
  local backend="$1" profile="$2" out=""
  local service; service="$(secret_service_name "$profile")"

  case "$backend" in
    keychain)
      out="$(security find-generic-password -s "$service" -a "$USER" -w 2>/dev/null)" || return 1
      ;;
    libsecret)
      out="$(secret-tool lookup service "$service" account "$USER" 2>/dev/null)" || return 1
      ;;
    dpapi)
      local path; path="$(secret_dpapi_path "$profile")"
      [ -f "$path" ] || return 1
      out="$(CP_SECRET_IN="$path" powershell.exe -NoProfile -NonInteractive -Command \
        '$s = Get-Content -Raw $env:CP_SECRET_IN | ConvertTo-SecureString; [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))' \
        2>/dev/null | tr -d "\r\n")" || return 1
      ;;
    file)
      local fpath; fpath="$(secret_file_path "$profile")"
      [ -f "$fpath" ] || return 1
      out="$(cat "$fpath")"
      ;;
    *)
      return 1
      ;;
  esac

  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# secret_exists <backend> <profile>
#
# Metadata-only where the backend allows it. On macOS that matters: omitting
# -w means `security` does not read the secret, so macOS never shows a
# Keychain authorisation prompt just because you ran `doctor`.
secret_exists() {
  local backend="$1" profile="$2"
  local service; service="$(secret_service_name "$profile")"

  case "$backend" in
    keychain)  security find-generic-password -s "$service" -a "$USER" >/dev/null 2>&1 ;;
    libsecret) [ -n "$(secret-tool lookup service "$service" account "$USER" 2>/dev/null)" ] ;;
    dpapi)     [ -f "$(secret_dpapi_path "$profile")" ] ;;
    file)      [ -s "$(secret_file_path "$profile")" ] ;;
    *)         return 1 ;;
  esac
}

# secret_delete <backend> <profile>
#
# Deleting the local copy does NOT revoke the token. Callers must say so —
# revocation happens in claude.ai account settings.
secret_delete() {
  local backend="$1" profile="$2"
  local service; service="$(secret_service_name "$profile")"

  case "$backend" in
    keychain)  security delete-generic-password -s "$service" -a "$USER" >/dev/null 2>&1 ;;
    libsecret) secret-tool clear service "$service" account "$USER" >/dev/null 2>&1 ;;
    dpapi)     rm -f "$(secret_dpapi_path "$profile")" ;;
    file)      rm -f "$(secret_file_path "$profile")" ;;
    *)         return 1 ;;
  esac
}


# primary_login_exists — is there a normal `/login` credential for the primary
# account? Informational only; we never touch it.
primary_login_exists() {
  case "$(platform_id)" in
    macos)
      security find-generic-password -s "$CLAUDE_NATIVE_KEYCHAIN_SERVICE" >/dev/null 2>&1
      ;;
    *)
      [ -f "$(platform_primary_cli_config_dir)/.credentials.json" ] \
        || [ -f "$HOME/.claude/.credentials.json" ]
      ;;
  esac
}
