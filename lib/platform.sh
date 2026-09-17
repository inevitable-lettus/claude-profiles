# lib/platform.sh
#
# Everything that differs between macOS, Linux and Windows lives behind a
# function here. The rest of the codebase should not contain a `uname` test.
#
# THE ONE FACT THAT SHAPES THIS FILE
# ----------------------------------
# From the Claude Code authentication docs:
#
#   "On macOS, credentials are stored in the encrypted macOS Keychain. On
#    Linux, credentials are stored in ~/.claude/.credentials.json [...] On
#    Windows, credentials are stored in %USERPROFILE%\.claude\.credentials.json
#    [...] If you've set the CLAUDE_CONFIG_DIR environment variable ON LINUX
#    OR WINDOWS, the .credentials.json file lives under that directory
#    instead."
#
# macOS is excluded from that last sentence deliberately. So:
#
#   Linux / Windows   CLAUDE_CONFIG_DIR separates the login. That is the
#                     whole mechanism. Two config dirs, two /login runs.
#
#   macOS             CLAUDE_CONFIG_DIR separates settings, history, projects
#                     and sessions but NOT the login — both profiles read the
#                     same Keychain item, so the second /login overwrites the
#                     first. A long-lived OAuth token in
#                     CLAUDE_CODE_OAUTH_TOKEN (precedence rank 5, above the
#                     rank 6 subscription login) is the way around it.
#
# In other words the token machinery is a macOS workaround, not the design.
# platform_default_auth_mode() below is where that asymmetry is encoded.
# ---------------------------------------------------------------------------


# platform_id — macos | linux | windows
#
# WSL reports Linux and is treated as Linux, because that is what it is: the
# CLI half works there natively. Driving the Windows desktop app from inside
# WSL is out of scope and doctor says so.
#
# Git Bash / MSYS2 / Cygwin report MINGW*/MSYS*/CYGWIN* and are treated as
# windows. The CLI subcommands work fine there; the desktop subcommands defer
# to the PowerShell module, which is the only thing that can talk to MSIX
# packaging and create shortcuts.
platform_id() {
  case "$(uname -s 2>/dev/null)" in
    Darwin)                   printf 'macos' ;;
    Linux)                    printf 'linux' ;;
    MINGW*|MSYS*|CYGWIN*)     printf 'windows' ;;
    *)                        printf 'unknown' ;;
  esac
}

# platform_label — a human-readable name for messages.
platform_label() {
  case "$(platform_id)" in
    macos)   printf 'macOS' ;;
    linux)   printf 'Linux' ;;
    windows) printf 'Windows' ;;
    *)       printf '%s' "$(uname -s 2>/dev/null || echo unknown)" ;;
  esac
}

# is_wsl — WSL is Linux, but a few messages are worth qualifying.
is_wsl() {
  [ "$(platform_id)" = "linux" ] || return 1
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}

# require_platform <id>...
#
# The replacement for the old require_macos. Used only where a subcommand is
# genuinely platform-specific, and the message always says what to do instead.
require_platform() {
  local current
  current="$(platform_id)"
  local want
  for want in "$@"; do
    [ "$current" = "$want" ] && return 0
  done
  die "This needs $(join_by ' or ' "$@"); you are on $(platform_label)."
}


# ---------------------------------------------------------------------------
# Where our own state lives
# ---------------------------------------------------------------------------
# XDG on macOS as well as Linux. Apple's convention would be
# ~/Library/Application Support, but people who sync dotfiles expect
# ~/.config, the tool is a CLI rather than an app, and one path is one less
# thing to explain. CLAUDE_PROFILES_HOME overrides it — the test sandbox
# relies on that, and so does anyone wanting the registry on an encrypted
# volume.

platform_state_home() {
  if [ -n "${CLAUDE_PROFILES_HOME:-}" ]; then
    printf '%s' "$CLAUDE_PROFILES_HOME"
    return
  fi
  case "$(platform_id)" in
    windows)
      # Git Bash exposes %APPDATA% with forward slashes already.
      printf '%s/claude-profiles' "${APPDATA:-$HOME/AppData/Roaming}"
      ;;
    *)
      printf '%s/claude-profiles' "${XDG_CONFIG_HOME:-$HOME/.config}"
      ;;
  esac
}

registry_path()      { printf '%s/profiles.json' "$(platform_state_home)"; }
templates_dir()      { printf '%s/profiles' "$(platform_state_home)"; }
secrets_fallback_dir() { printf '%s/secrets' "$(platform_state_home)"; }

# platform_apps_home — where mirrored application copies go.
#
# Separate from the state home because a mirror is roughly a gigabyte, and on
# Windows the state home is %APPDATA%, which roams. Putting a gigabyte into a
# roaming profile is a good way to be unpopular on a domain-joined machine.
platform_apps_home() {
  case "$(platform_id)" in
    windows) printf '%s/claude-profiles/apps' "${LOCALAPPDATA:-$HOME/AppData/Local}" ;;
    *)       printf '%s/apps' "$(platform_state_home)" ;;
  esac
}


# ---------------------------------------------------------------------------
# Defaults for a newly added profile
# ---------------------------------------------------------------------------

# platform_default_auth_mode — see the header of this file.
#
#   config-dir    CLAUDE_CONFIG_DIR alone isolates the login  (Linux, Windows)
#   oauth-token   plus CLAUDE_CODE_OAUTH_TOKEN                (macOS)
platform_default_auth_mode() {
  case "$(platform_id)" in
    macos) printf 'oauth-token' ;;
    *)     printf 'config-dir' ;;
  esac
}

# platform_default_cli_config_dir <profile>
#
# ~/.claude-<name> everywhere. Matches what the pre-1.0 scripts created, so
# `init` can adopt an existing ~/.claude-work without moving anything.
platform_default_cli_config_dir() {
  printf '%s/.claude-%s' "$HOME" "$1"
}

# platform_primary_cli_config_dir — the untouchable one.
platform_primary_cli_config_dir() {
  printf '%s/.claude' "$HOME"
}

# platform_default_desktop_user_data_dir <profile>
#
# Where Electron is told to put this profile's everything. Follows each
# platform's own convention for an app's userData directory, with the profile
# name appended:
#
#   macOS    ~/Library/Application Support/Claude-Work
#   Linux    ~/.config/Claude-Work
#   Windows  %APPDATA%\Claude-Work
platform_default_desktop_user_data_dir() {
  local pretty
  pretty="Claude-$(ucfirst "$1")"
  case "$(platform_id)" in
    macos)   printf '%s/Library/Application Support/%s' "$HOME" "$pretty" ;;
    windows) printf '%s/%s' "${APPDATA:-$HOME/AppData/Roaming}" "$pretty" ;;
    *)       printf '%s/%s' "${XDG_CONFIG_HOME:-$HOME/.config}" "$pretty" ;;
  esac
}

# platform_primary_desktop_user_data_dir — the default profile's directory.
# Read-only for us. We only need it to refuse to collide with it.
platform_primary_desktop_user_data_dir() {
  case "$(platform_id)" in
    macos)   printf '%s/Library/Application Support/Claude' "$HOME" ;;
    windows) printf '%s/Claude' "${APPDATA:-$HOME/AppData/Roaming}" ;;
    *)       printf '%s/Claude' "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
  esac
}

# platform_find_desktop_app — best guess at the installed Claude desktop app.
#
# Prints nothing and returns 1 when it cannot find one, which is a normal
# outcome: plenty of people only want the CLI half.
platform_find_desktop_app() {
  local candidate
  case "$(platform_id)" in
    macos)
      for candidate in \
        "/Applications/Claude.app" \
        "$HOME/Applications/Claude.app"
      do
        [ -d "$candidate" ] && { printf '%s' "$candidate"; return 0; }
      done
      ;;
    linux)
      # Distribution packaging for the desktop app is inconsistent, so try
      # PATH first and then the usual unpacked-Electron locations.
      for candidate in claude-desktop claude-desktop-bin Claude; do
        if have "$candidate"; then
          printf '%s' "$(command -v "$candidate")"
          return 0
        fi
      done
      for candidate in \
        "/opt/Claude/claude" \
        "/opt/claude-desktop/claude-desktop" \
        "/usr/lib/claude-desktop/claude-desktop" \
        "$HOME/.local/share/claude-desktop/claude-desktop"
      do
        [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
      done
      ;;
    windows)
      # Only the direct-.exe install flavour is reachable from bash. The MSIX
      # flavour lives under C:\Program Files\WindowsApps, which Windows will
      # not let anything execute directly — that is what the PowerShell
      # module's mirror-app is for.
      local base="${LOCALAPPDATA:-$HOME/AppData/Local}/AnthropicClaude"
      if [ -d "$base" ]; then
        # app-1.2.3/claude.exe — newest version wins.
        candidate="$(ls -d "$base"/app-* 2>/dev/null | sort -V | tail -1)"
        if [ -n "$candidate" ] && [ -f "$candidate/claude.exe" ]; then
          printf '%s/claude.exe' "$candidate"
          return 0
        fi
      fi
      ;;
  esac
  return 1
}


# ---------------------------------------------------------------------------
# Dates
# ---------------------------------------------------------------------------
# The pre-1.0 shell helper used `date -j -f "%Y-%m-%d"`, which is BSD syntax
# and fails outright on GNU coreutils. Both spellings are tried here, so the
# token-expiry warning works on Linux too.

today_iso() { date "+%Y-%m-%d"; }

# date_to_epoch <YYYY-MM-DD> — prints seconds since the epoch, or nothing.
date_to_epoch() {
  local iso="$1" out=""
  # BSD / macOS
  out="$(date -j -f "%Y-%m-%d" "$iso" "+%s" 2>/dev/null)" && [ -n "$out" ] && {
    printf '%s' "$out"; return 0
  }
  # GNU coreutils
  out="$(date -d "$iso" "+%s" 2>/dev/null)" && [ -n "$out" ] && {
    printf '%s' "$out"; return 0
  }
  return 1
}

# days_since <YYYY-MM-DD>
days_since() {
  local created_epoch now_epoch
  created_epoch="$(date_to_epoch "$1")" || return 1
  now_epoch="$(date "+%s")"
  printf '%s' $(( (now_epoch - created_epoch) / 86400 ))
}


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# path_expand <path> — turn a leading ~ into $HOME.
#
# The registry stores paths with ~ so a synced dotfiles repo is portable
# between machines with different usernames. Everything that touches the
# filesystem expands first.
path_expand() {
  # The tildes below are literal characters being matched and stripped, not
  # attempts at shell expansion — that is the whole point of the function.
  # shellcheck disable=SC2088
  case "$1" in
    "~")    printf '%s' "$HOME" ;;
    "~/"*)  printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *)      printf '%s' "$1" ;;
  esac
}

# path_contract <path> — inverse, for storing.
path_contract() {
  # shellcheck disable=SC2088
  case "$1" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
