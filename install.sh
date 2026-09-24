#!/usr/bin/env sh
#
# install.sh — claude-profiles, macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/inevitable-lettus/claude-profiles/main/install.sh | sh
#
# What it does, in order:
#   1. checks the handful of things it needs (git, awk, bash)
#   2. clones or updates ~/.claude-profiles
#   3. symlinks the entrypoint onto your PATH
#   4. prints the one line to add to your shell rc
#
# What it does NOT do: touch your shell rc, create any profile, read any
# credential, or run anything with sudo. Everything it writes is under your
# home directory. Setup is `claude-profiles init`, which you run yourself.
#
# POSIX sh, not bash: this is the one file that runs before we know what is
# installed.
# ---------------------------------------------------------------------------

set -eu

REPO_URL="${CLAUDE_PROFILES_REPO:-https://github.com/inevitable-lettus/claude-profiles.git}"
INSTALL_DIR="${CLAUDE_PROFILES_INSTALL_DIR:-$HOME/.claude-profiles}"
# Which ref to install. Unset means the newest release tag, so a push to main
# never reaches people who installed a release. CLAUDE_PROFILES_BRANCH=main
# opts into the development head; any tag or branch name works.
REF="${CLAUDE_PROFILES_BRANCH:-}"

if [ -t 1 ]; then
  B=$(printf '\033[1m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m')
  R=$(printf '\033[31m'); N=$(printf '\033[0m')
else
  B=''; G=''; Y=''; R=''; N=''
fi

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf-8*|*UTF8*|*utf8*) OKG='✓' FAILG='✗' ;;
  *) OKG='+' FAILG='x' ;;
esac

say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s%s%s %s\n' "$G" "$OKG" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s%s error:%s %s\n' "$R" "$FAILG" "$N" "$*" >&2; exit 1; }

say "${B}claude-profiles installer${N}"
say ""

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

have git  || die "git is required."
have awk  || die "awk is required. It is part of every POSIX system; something is very wrong."
have bash || die "bash is required (3.2 or newer — the version macOS ships is fine)."

case "$(uname -s)" in
  Darwin) PLATFORM=macOS ;;
  Linux)  PLATFORM=Linux ;;
  MINGW*|MSYS*|CYGWIN*)
    warn "This looks like Git Bash on Windows."
    warn "The CLI half will work, but the desktop half needs the PowerShell module."
    warn "See docs/windows.md — install.ps1 is the one you want."
    PLATFORM=Windows ;;
  *) die "Unsupported platform: $(uname -s)" ;;
esac
ok "Platform: $PLATFORM"

if [ -z "$REF" ]; then
  # Plain x.y.z tags only, sorted numerically field by field — POSIX sort
  # has no version sort, and a pre-release tag should never be the default.
  REF="$(git ls-remote --tags --refs "$REPO_URL" 'v*' 2>/dev/null \
         | sed 's#.*refs/tags/v##' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
         | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" || REF=""
  if [ -n "$REF" ]; then REF="v$REF"; else REF=main; fi
fi
ok "Version: $REF"

have claude || warn "The 'claude' CLI is not on your PATH. Install it first if you want the CLI half: https://code.claude.com/docs/en/setup"

# ---------------------------------------------------------------------------
# 2. Clone or update
# ---------------------------------------------------------------------------
if [ -d "$INSTALL_DIR/.git" ]; then
  say "Updating $INSTALL_DIR"
  # FETCH_HEAD, detached: the same two lines work for a tag and a branch.
  git -C "$INSTALL_DIR" fetch --quiet --depth 1 origin "$REF" || die "Could not fetch $REF from origin."
  git -C "$INSTALL_DIR" checkout --quiet --force FETCH_HEAD
  ok "Updated to $REF ($(git -C "$INSTALL_DIR" rev-parse --short HEAD))"
elif [ -e "$INSTALL_DIR" ]; then
  die "$INSTALL_DIR exists but is not a git checkout. Move it aside and re-run."
else
  say "Cloning into $INSTALL_DIR"
  # Output is held back and shown only on failure: a shallow clone of an
  # annotated tag prints a harmless "is not a commit!" warning otherwise.
  if ! CLONE_OUT="$(git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$INSTALL_DIR" 2>&1)"; then
    printf '%s\n' "$CLONE_OUT" >&2
    die "Clone failed."
  fi
  ok "Cloned $REF ($(git -C "$INSTALL_DIR" rev-parse --short HEAD))"
fi

chmod +x "$INSTALL_DIR/bin/claude-profiles" "$INSTALL_DIR/tests"/*.sh 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Put it on PATH
# ---------------------------------------------------------------------------
# ~/.local/bin is the XDG convention and is already on PATH for most people.
# We never write to /usr/local/bin: that needs sudo, and an installer that
# asks for your password to place one symlink has not earned it.
BIN_DIR="${CLAUDE_PROFILES_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/bin/claude-profiles" "$BIN_DIR/claude-profiles"
ok "Linked $BIN_DIR/claude-profiles"

ON_PATH=0
case ":$PATH:" in *":$BIN_DIR:"*) ON_PATH=1 ;; esac
[ "$ON_PATH" = "1" ] || warn "$BIN_DIR is not on your PATH — add it, or the command will not be found."

# ---------------------------------------------------------------------------
# 4. What to do next
# ---------------------------------------------------------------------------
SHELL_NAME="$(basename "${SHELL:-zsh}")"
case "$SHELL_NAME" in
  zsh)  RC="$HOME/.zshrc" ;;
  bash) RC="$HOME/.bashrc" ;;
  *)    RC="your shell's rc file"; SHELL_NAME=zsh ;;
esac

say ""
say "${B}Installed.${N} Two steps left, both yours to run:"
say ""
say "  ${B}1.${N} Add this line to $RC:"
say ""
say "         eval \"\$(claude-profiles shell-init $SHELL_NAME)\""
say ""
say "     That defines claude-<profile> commands and switches profiles"
say "     automatically when you cd into a project with a .claude-profile file."
say ""
say "  ${B}2.${N} Set up your first profile:"
say ""
say "         claude-profiles init"
say "         claude-profiles add work"
say ""
say "Then: ${B}claude-profiles doctor${N}"
say ""
say "The installer deliberately did not edit $RC. Adding one line yourself is"
say "cheaper than trusting a script with your shell configuration."
say ""
