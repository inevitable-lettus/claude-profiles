# lib/workflow.sh
#
# The bits that make this disappear into your day: per-directory switching,
# the prompt indicator, and the generated shell integration.
#
# THE PROBLEM BEING SOLVED. Before this, using a second account meant
# remembering to type `claude-work` instead of `claude`. Forget once and you
# have burned the wrong account's quota, or put a client's context in the
# wrong workspace. A `.claude-profile` file in a repository makes it
# automatic: cd in, the profile switches; cd out, it switches back.
#
# ---------------------------------------------------------------------------
# .claude-profile IS UNTRUSTED INPUT. Read this before changing anything here.
# ---------------------------------------------------------------------------
# That file arrives inside repositories you clone from other people. Treat it
# exactly like any other file in a hostile repo. The rules, enforced in three
# places (the generated shell hook, cmd_env, and require_profile_name):
#
#   It may ONLY name an already-registered local profile.
#
#   It may not create a profile. It may not name a directory, a token, a
#   command, or a flag. It may not cause a login. Its entire vocabulary is
#   the set of names you have already chosen on this machine.
#
#   An unrecognised name warns and leaves you on the primary account. It must
#   never silently fall through to a *different* registered profile, because
#   that is precisely the failure this feature exists to prevent.
#
# The character set from PROFILE_NAME_PATTERN is the sanitisation boundary:
# lowercase, digits, hyphen, underscore. No dots, no slashes, no spaces, no
# shell metacharacters. The hook re-checks it in pure shell before the name
# ever reaches a subprocess, so a malicious file cannot even get as far as
# an argv.
# ---------------------------------------------------------------------------

PROFILE_FILE_NAME=".claude-profile"

# How far up to walk. Deep enough for any real repository, shallow enough
# that a pathological path cannot turn every `cd` into a stat storm.
PROFILE_FILE_MAX_DEPTH=40


# workflow_find_profile_file [start-dir]
#
# Walks up looking for .claude-profile, stopping at a repository root — a
# repo's own file should win, and we should not silently inherit one from a
# parent directory outside it.
workflow_find_profile_file() {
  local dir="${1:-$PWD}" depth=0
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$depth" -lt "$PROFILE_FILE_MAX_DEPTH" ]; do
    if [ -f "$dir/$PROFILE_FILE_NAME" ]; then
      printf '%s' "$dir/$PROFILE_FILE_NAME"
      return 0
    fi
    # Check for the file first, then stop: the repo root is the ceiling.
    [ -e "$dir/.git" ] && return 1
    dir="${dir%/*}"
    depth=$((depth + 1))
  done
  return 1
}

# workflow_resolve [start-dir]
#
# The profile this directory asks for, or nothing. Validates the name and
# that it is actually registered; anything else is a refusal, never a guess.
workflow_resolve() {
  local file name
  file="$(workflow_find_profile_file "${1:-$PWD}")" || return 1

  # Only the first line, and only up to the first whitespace. A comment or a
  # trailing newline is fine; a second line is ignored.
  IFS= read -r name < "$file" || true
  name="$(printf '%s' "$name" | tr -d '[:space:]')"
  [ -n "$name" ] || return 1

  if ! profile_name_valid "$name"; then
    warn "$file names '$name', which is not a valid profile name. Ignoring it."
    return 1
  fi

  registry_load
  if ! registry_has_profile "$name"; then
    warn "$file asks for profile '$name', which is not registered on this machine. Staying on the primary account."
    info "Register it with: claude-profiles add $name"
    return 1
  fi

  printf '%s' "$name"
}


# ---------------------------------------------------------------------------
# Shell-eval output
# ---------------------------------------------------------------------------

# sh_quote <value> — single-quote for safe eval.
#
# Everything cmd_env prints goes through here. The values are paths out of
# your own registry rather than anything hostile, but `eval` deserves the
# discipline regardless.
sh_quote() {
  local s="$1"
  s=${s//\'/\'\\\'\'}
  printf "'%s'" "$s"
}


# ---------------------------------------------------------------------------
# The generated shell integration
# ---------------------------------------------------------------------------
# Emitted by `claude-profiles shell-init <shell>` and consumed as:
#
#     eval "$(claude-profiles shell-init zsh)"
#
# DELIBERATELY SHARES NO CODE WITH lib/*. Two reasons, both learned the hard
# way in the pre-1.0 version of this tool:
#
#   1. lib/common.sh's callers run under `set -euo pipefail`. In an
#      interactive shell that means any failing command kills your terminal.
#   2. lib/common.sh defines a function called `say`, which would shadow the
#      real macOS text-to-speech command.
#
# The pre-1.0 fix was to hand-duplicate four constants into the shell file,
# which is exactly the drift this rewrite exists to remove. So instead the
# generated code contains no configuration at all: every function shells out
# to `claude-profiles`, which reads the registry. The only thing baked in is
# the list of profile names, and that only to declare the convenience
# functions — adding a profile prints a reminder to reload.

workflow_shell_init() {
  local shell_name="$1"
  case "$shell_name" in
    zsh|bash) _workflow_shell_init_posix "$shell_name" ;;
    pwsh|powershell) _workflow_shell_init_pwsh ;;
    fish) die "fish is not supported yet. Contributions welcome — see CONTRIBUTING.md." ;;
    *) die "Unknown shell '$shell_name'. Use one of: zsh, bash, pwsh" ;;
  esac
}

_workflow_shell_init_posix() {
  local shell_name="$1" self name
  self="$CP_SELF"

  registry_load

  cat <<EOF
# claude-profiles shell integration ($shell_name)
# Generated by: claude-profiles shell-init $shell_name
# Re-run after adding or removing a profile.

CLAUDE_PROFILES_BIN=$(sh_quote "$self")

# --- switching -------------------------------------------------------------

# claude-whoami — which profile is this shell on?
claude-whoami() {
  command "\$CLAUDE_PROFILES_BIN" whoami
}

# claude-profile-use <name> — switch this shell, until you leave it.
#
# The output is captured before it is eval'd, on purpose: \`eval "\$(cmd)"\`
# reports the status of the eval, not of cmd, so a failed lookup would
# otherwise look like a successful switch to nothing.
claude-profile-use() {
  if [ -z "\${1:-}" ]; then
    printf 'usage: claude-profile-use <profile>\n' >&2
    return 1
  fi
  local _cp_out
  _cp_out=\$(command "\$CLAUDE_PROFILES_BIN" env "\$1") || return 1
  eval "\$_cp_out"
  unset _CLAUDE_PROFILES_AUTO
}

# claude-profile-off — back to the primary account in this shell.
claude-profile-off() {
  eval "\$(command "\$CLAUDE_PROFILES_BIN" env --unset)"
  unset _CLAUDE_PROFILES_AUTO
}

EOF

  # One convenience function per registered profile, so `claude-work` keeps
  # meaning what it meant before 1.0.
  for name in $(registry_profiles); do
    if cli_profile_configured "$name"; then
      cat <<EOF
claude-$name() { command "\$CLAUDE_PROFILES_BIN" run $name -- "\$@"; }
claude-$name-shell() { command "\$CLAUDE_PROFILES_BIN" shell $name; }
EOF
    fi
    if desktop_profile_configured "$name"; then
      cat <<EOF
claude-$name-desktop() { command "\$CLAUDE_PROFILES_BIN" desktop $name; }
EOF
    fi
  done

  cat <<'EOF'

# --- automatic per-directory switching ---------------------------------------
#
# A .claude-profile file switches the profile on cd. The whole walk-up and the
# name check happen in pure shell, so a directory with no such file costs a few
# stat calls and launches no processes at all.
#
# SECURITY: .claude-profile arrives inside repositories you clone, so the name
# is validated here before it is ever passed to a subprocess, and again by
# claude-profiles itself. It can only ever select a profile you already have.

_claude_profiles_find_file() {
  local dir="$PWD" depth=0
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$depth" -lt 40 ]; do
    if [ -f "$dir/.claude-profile" ]; then
      printf '%s' "$dir/.claude-profile"
      return 0
    fi
    [ -e "$dir/.git" ] && return 1
    dir="${dir%/*}"
    depth=$((depth + 1))
  done
  return 1
}

_claude_profiles_sync() {
  # A profile chosen deliberately — `claude-profile-use`, or a
  # `claude-profiles shell` subshell — outranks any file on disk. Never
  # clobber an explicit choice.
  if [ -n "${CLAUDE_ACTIVE_PROFILE:-}" ] && [ -z "${_CLAUDE_PROFILES_AUTO:-}" ]; then
    return 0
  fi

  local file want=""
  if file=$(_claude_profiles_find_file); then
    IFS= read -r want < "$file" 2>/dev/null || want=""
    # Trim without spawning anything: drop leading whitespace, then cut at the
    # first trailing whitespace. [[:space:]] includes \r, so a file saved with
    # CRLF line endings on Windows works too.
    want="${want#"${want%%[![:space:]]*}"}"
    want="${want%%[[:space:]]*}"
    # Reject anything outside the permitted character set, in pure shell,
    # before it can reach an argv.
    case "$want" in
      "" ) want="" ;;
      *[!a-z0-9_-]* )
        printf '\033[33m[claude-profiles]\033[0m %s names an invalid profile — ignoring.\n' "$file" >&2
        want="" ;;
    esac
  fi

  [ "$want" = "${CLAUDE_ACTIVE_PROFILE:-}" ] && return 0

  local out
  if [ -z "$want" ]; then
    if [ -n "${_CLAUDE_PROFILES_AUTO:-}" ]; then
      out=$(command "$CLAUDE_PROFILES_BIN" env --unset) && eval "$out"
      unset _CLAUDE_PROFILES_AUTO
    fi
    return 0
  fi

  # Capture first, then eval. `eval "$(cmd)"` returns the status of the eval,
  # not of cmd, so an unregistered profile would otherwise be recorded as a
  # successful automatic switch and leave a stale flag behind.
  if out=$(command "$CLAUDE_PROFILES_BIN" env "$want"); then
    eval "$out"
    _CLAUDE_PROFILES_AUTO=1
  fi
}
EOF

  if [ "$shell_name" = "zsh" ]; then
    cat <<'EOF'

autoload -Uz add-zsh-hook
add-zsh-hook chpwd _claude_profiles_sync
_claude_profiles_sync
EOF
  else
    cat <<'EOF'

# bash has no chpwd hook, so this rides PROMPT_COMMAND and short-circuits
# unless the directory actually changed.
_claude_profiles_prompt_hook() {
  if [ "$PWD" != "${_CLAUDE_PROFILES_LAST_PWD:-}" ]; then
    _CLAUDE_PROFILES_LAST_PWD="$PWD"
    _claude_profiles_sync
  fi
}
case "${PROMPT_COMMAND:-}" in
  *_claude_profiles_prompt_hook*) : ;;
  "") PROMPT_COMMAND="_claude_profiles_prompt_hook" ;;
  *)  PROMPT_COMMAND="_claude_profiles_prompt_hook;${PROMPT_COMMAND}" ;;
esac
_claude_profiles_prompt_hook
EOF
  fi

  cat <<'EOF'

# --- prompt indicator --------------------------------------------------------
#
# Add to your prompt however you like. The variable is set by the hook above,
# so this costs nothing:
#
#   zsh    PROMPT='${CLAUDE_ACTIVE_PROFILE:+($CLAUDE_ACTIVE_PROFILE) }'$PROMPT
#   bash   PS1='${CLAUDE_ACTIVE_PROFILE:+($CLAUDE_ACTIVE_PROFILE) }'$PS1
#
# For starship, oh-my-posh, or Claude Code's own statusLine setting, see
# `claude-profiles prompt --help`.
EOF
}

_workflow_shell_init_pwsh() {
  local self name
  self="$CP_SELF"
  registry_load

  cat <<EOF
# claude-profiles shell integration (PowerShell)
# Generated by: claude-profiles shell-init pwsh
#
# NOTE: on Windows the native implementation is the ClaudeProfiles module
# (Import-Module ClaudeProfiles). This generated form exists for PowerShell
# on macOS and Linux, where the bash entrypoint is the real implementation.

\$env:CLAUDE_PROFILES_BIN = $(sh_quote "$self")
EOF

  for name in $(registry_profiles); do
    if cli_profile_configured "$name"; then
      cat <<EOF
function claude-$name { & \$env:CLAUDE_PROFILES_BIN run $name -- @args }
EOF
    fi
  done

  cat <<'EOF'
function claude-whoami { & $env:CLAUDE_PROFILES_BIN whoami }
EOF
}
