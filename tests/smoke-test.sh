#!/usr/bin/env bash
#
# tests/smoke-test.sh
#
# Exercises the scripts against a fake macOS, in a throwaway directory.
# Nothing outside /tmp is touched — no real app is launched, no real
# Keychain is read or written.
#
# It works by putting stub versions of the macOS-only commands (defaults,
# security, codesign, open, ...) at the front of PATH, then copying the repo
# into a sandbox with all its paths rewritten to point inside that sandbox.
#
# What it actually proves:
#   - every script parses
#   - the generated Info.plist is a valid plist with the right keys
#   - the generated launcher is valid bash with the right paths baked in
#   - the shell helpers export the right environment variables
#   - the "no token" and "wrong path" failure paths behave
#
# What it cannot prove: whether the real Claude app honours --user-data-dir,
# or where it stores credentials. Only 01-verify-desktop.sh on your actual
# machine can answer those.
#
# Usage:  ./tests/smoke-test.sh
#
# ---------------------------------------------------------------------------

set -uo pipefail   # deliberately NOT -e: a failing test should report, not abort

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="/tmp/claude-profiles-test-$$"
STUB_BIN="$SANDBOX/stubs"
FAKE_HOME="$SANDBOX/home"

TESTS_RUN=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
flunk() {
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [ $# -gt 1 ] && printf '       %s\n' "$2"
  return 0
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# check_contains <description> <expected-substring> <file>
#
# The `--` before the pattern matters: without it, a pattern starting with a
# dash (like "--user-data-dir=") is parsed by grep as an option, and grep
# then blocks reading stdin forever.
check_contains() {
  if grep -qF -- "$2" "$3" 2>/dev/null; then
    pass "$1"
  else
    flunk "$1" "expected to find: $2"
  fi
}

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT


# ===========================================================================
# Build the fake macOS
# ===========================================================================
build_stubs() {
  section "Setting up sandbox at $SANDBOX"
  # PIDs get reused, so a previous aborted run may have left a directory
  # with this exact name. Start genuinely clean or tests see stale state.
  rm -rf "$SANDBOX"
  mkdir -p "$STUB_BIN" "$FAKE_HOME/Applications" "$SANDBOX/Applications"

  # --- uname: pretend to be macOS so require_macos passes ---
  cat > "$STUB_BIN/uname" <<'EOF'
#!/usr/bin/env bash
echo "Darwin"
EOF

  # --- defaults: minimal `defaults read <plist> <key>` ---
  # Uses python to actually parse the plist rather than faking a response,
  # so a malformed plist is caught here.
  cat > "$STUB_BIN/defaults" <<'EOF'
#!/usr/bin/env bash
# defaults read <plist-path> <key>
[ "${1:-}" = "read" ] || exit 1
python3 - "$2" "$3" <<'PY'
import plistlib, sys
try:
    with open(sys.argv[1], 'rb') as f:
        data = plistlib.load(f)
    print(data[sys.argv[2]])
except Exception:
    sys.exit(1)
PY
EOF

  # --- plutil -lint: real plist validation via python ---
  cat > "$STUB_BIN/plutil" <<'EOF'
#!/usr/bin/env bash
# plutil -lint <file>
[ "${1:-}" = "-lint" ] || exit 0
python3 -c "
import plistlib, sys
with open(sys.argv[1],'rb') as f: plistlib.load(f)
print('OK')
" "$2"
EOF

  # --- security: fake Keychain backed by a flat file ---
  # Supports the three subcommands the scripts use.
  cat > "$STUB_BIN/security" <<EOF
#!/usr/bin/env bash
STORE="$SANDBOX/keychain.txt"
touch "\$STORE"
sub="\${1:-}"; shift || true
svc=""; val=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -s) svc="\$2"; shift 2 ;;
    -w) if [ "\$sub" = "add-generic-password" ]; then val="\$2"; shift 2; else shift; fi ;;
    -a|-D) shift 2 ;;
    *) shift ;;
  esac
done
case "\$sub" in
  add-generic-password)
    grep -v "^\$svc	" "\$STORE" > "\$STORE.tmp" 2>/dev/null || true
    mv "\$STORE.tmp" "\$STORE"
    printf '%s\t%s\n' "\$svc" "\$val" >> "\$STORE" ;;
  find-generic-password)
    line=\$(grep "^\$svc	" "\$STORE" 2>/dev/null) || exit 44
    [ -n "\$val" ] || true
    printf '%s\n' "\${line#*	}" ;;
  delete-generic-password)
    grep -q "^\$svc	" "\$STORE" || exit 44
    grep -v "^\$svc	" "\$STORE" > "\$STORE.tmp"; mv "\$STORE.tmp" "\$STORE" ;;
  *) exit 1 ;;
esac
EOF

  # --- open: record the launch instead of performing it ---
  cat > "$STUB_BIN/open" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/open.log"
EOF

  # --- no-op stubs for things whose output we do not inspect ---
  for cmd in codesign osascript pgrep lsregister; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/$cmd"
  done

  chmod +x "$STUB_BIN"/*
  export PATH="$STUB_BIN:$PATH"

  # --- a fake Claude.app, structured like the real one ---
  local app="$SANDBOX/Applications/Claude.app"
  mkdir -p "$app/Contents/MacOS" \
           "$app/Contents/Resources" \
           "$app/Contents/Frameworks/Electron Framework.framework"
  cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.anthropic.claudefordesktop</string>
	<key>CFBundleName</key><string>Claude</string>
	<key>CFBundleShortVersionString</key><string>9.9.9</string>
	<key>CFBundleIconFile</key><string>electron.icns</string>
</dict>
</plist>
EOF
  echo "fake icon data" > "$app/Contents/Resources/electron.icns"

  # --- the repo, with every path rewritten into the sandbox ---
  cp -R "$REPO_DIR" "$SANDBOX/repo"
  rm -rf "$SANDBOX/repo/tests"
  local cfg="$SANDBOX/repo/config.sh"
  sed -i.bak \
    -e "s|^CLAUDE_APP=.*|CLAUDE_APP=\"$app\"|" \
    -e "s|\$HOME/Library/Application Support|$FAKE_HOME/Library/Application Support|g" \
    -e "s|^LAUNCHER_APP_PATH=.*|LAUNCHER_APP_PATH=\"$SANDBOX/Applications/\${LAUNCHER_APP_NAME}.app\"|" \
    -e "s|\$HOME/Applications|$FAKE_HOME/Applications|g" \
    -e "s|\$HOME/.claude-|$FAKE_HOME/.claude-|g" \
    "$cfg"
  rm -f "$cfg.bak"
  chmod +x "$SANDBOX/repo"/*.sh "$SANDBOX/repo/shell"/*.sh 2>/dev/null

  pass "sandbox built"
}


# ===========================================================================
# TEST 1 — every script parses
# ===========================================================================
test_syntax() {
  section "Syntax"
  local f
  for f in "$SANDBOX/repo"/*.sh "$SANDBOX/repo/shell"/*.sh; do
    if bash -n "$f" 2>/dev/null; then
      pass "parses: $(basename "$f")"
    else
      flunk "parses: $(basename "$f")" "$(bash -n "$f" 2>&1 | head -3)"
    fi
  done
}


# ===========================================================================
# TEST 2 — config.sh is self-consistent
# ===========================================================================
test_config() {
  section "config.sh"

  if ( set -euo pipefail; source "$SANDBOX/repo/config.sh" ) 2>/dev/null; then
    pass "sources without error"
  else
    flunk "sources without error"
    return
  fi

  # Every variable the other scripts reference must be defined.
  local out
  out=$( source "$SANDBOX/repo/config.sh"
    for v in PROFILE_NAME CLAUDE_APP CLAUDE_APP_SECONDARY DESKTOP_PRIMARY_DIR \
             DESKTOP_SECONDARY_DIR LAUNCHER_APP_NAME LAUNCHER_APP_PATH \
             CLONED_APP_PATH CLONED_BUNDLE_ID CLI_SECONDARY_CONFIG_DIR \
             CLI_TOKEN_KEYCHAIN_SERVICE CLI_NATIVE_KEYCHAIN_SERVICE; do
      [ -n "${!v:-}" ] || echo "MISSING:$v"
    done )
  if [ -z "$out" ]; then
    pass "all required variables defined"
  else
    flunk "all required variables defined" "$out"
  fi

  # The primary profile must never be the same as the secondary, or the
  # second instance would overwrite the first account's data.
  out=$( source "$SANDBOX/repo/config.sh"
         [ "$DESKTOP_PRIMARY_DIR" != "$DESKTOP_SECONDARY_DIR" ] || echo "COLLISION" )
  [ -z "$out" ] && pass "primary and secondary profile dirs differ" \
                || flunk "primary and secondary profile dirs differ"

  # Our Keychain service name must not collide with Claude Code's own.
  out=$( source "$SANDBOX/repo/config.sh"
         [ "$CLI_TOKEN_KEYCHAIN_SERVICE" != "$CLI_NATIVE_KEYCHAIN_SERVICE" ] || echo "COLLISION" )
  [ -z "$out" ] && pass "our Keychain service differs from Claude Code's" \
                || flunk "our Keychain service differs from Claude Code's"
}


# ===========================================================================
# TEST 3 — 04-install-launcher.sh produces a correct bundle
# ===========================================================================
test_launcher_build() {
  section "04-install-launcher.sh"

  local log="$SANDBOX/launcher.log"
  ( cd "$SANDBOX/repo" && HOME="$FAKE_HOME" ./04-install-launcher.sh </dev/null ) \
    > "$log" 2>&1
  local rc=$?

  local app="$SANDBOX/Applications/Claude Work.app"

  if [ "$rc" -eq 0 ]; then
    pass "script exits 0"
  else
    flunk "script exits 0" "$(tail -5 "$log")"
  fi

  [ -d "$app" ] && pass "bundle created" || { flunk "bundle created"; return; }

  # --- Info.plist ---
  local plist="$app/Contents/Info.plist"
  if python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$plist" 2>/dev/null; then
    pass "Info.plist is a valid plist"
  else
    flunk "Info.plist is a valid plist"
  fi

  local exec_name
  exec_name=$(python3 -c "
import plistlib,sys
print(plistlib.load(open(sys.argv[1],'rb')).get('CFBundleExecutable',''))" "$plist" 2>/dev/null)
  [ -n "$exec_name" ] && pass "CFBundleExecutable set ($exec_name)" \
                      || flunk "CFBundleExecutable set"

  # The executable named in the plist must actually exist and be runnable,
  # or macOS shows a useless "app is damaged" error.
  if [ -x "$app/Contents/MacOS/$exec_name" ]; then
    pass "declared executable exists and is +x"
  else
    flunk "declared executable exists and is +x"
  fi

  # Must NOT reuse Anthropic's bundle ID.
  local bid
  bid=$(python3 -c "
import plistlib,sys
print(plistlib.load(open(sys.argv[1],'rb')).get('CFBundleIdentifier',''))" "$plist" 2>/dev/null)
  case "$bid" in
    com.anthropic.*) flunk "bundle ID is not Anthropic's" "got: $bid" ;;
    "")              flunk "bundle ID is set" ;;
    *)               pass "bundle ID is our own ($bid)" ;;
  esac

  # --- generated launcher script ---
  local launcher="$app/Contents/MacOS/$exec_name"
  if bash -n "$launcher" 2>/dev/null; then
    pass "generated launcher is valid bash"
  else
    flunk "generated launcher is valid bash" "$(bash -n "$launcher" 2>&1 | head -3)"
  fi

  check_contains "launcher passes --user-data-dir" "--user-data-dir=" "$launcher"
  check_contains "launcher points at the secondary profile" "Claude-Work" "$launcher"
  check_contains "launcher forces a new instance (-n)" "open -n" "$launcher"

  # The path must be baked in literally, not left as an unexpanded variable
  # referring to config.sh — the .app has to work standalone.
  if grep -q 'DESKTOP_SECONDARY_DIR' "$launcher"; then
    flunk "profile path is baked in, not a config.sh reference"
  else
    pass "profile path is baked in, not a config.sh reference"
  fi

  # --- actually run it, and check what it tried to launch ---
  rm -f "$SANDBOX/open.log"
  HOME="$FAKE_HOME" bash "$launcher" >/dev/null 2>&1
  if [ -f "$SANDBOX/open.log" ]; then
    pass "launcher runs and invokes open"
    check_contains "open call includes --user-data-dir" "--user-data-dir=" "$SANDBOX/open.log"
    check_contains "open call includes -n (new instance)" "-n -a" "$SANDBOX/open.log"
  else
    flunk "launcher runs and invokes open"
  fi

  # --- icon ---
  [ -f "$app/Contents/Resources/AppIcon.icns" ] \
    && pass "icon copied from Claude.app" \
    || flunk "icon copied from Claude.app"
}


# ===========================================================================
# TEST 4 — the shell helpers
# ===========================================================================
test_shell_helpers() {
  section "shell/claude-profiles.sh"

  local helper="$SANDBOX/repo/shell/claude-profiles.sh"

  # A `claude` stub that dumps the environment it was given, so we can check
  # exactly what the wrapper passed through.
  cat > "$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
printf 'CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR:-unset}"
printf 'TOKEN=%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN:-unset}"
printf 'PROFILE=%s\n' "\${CLAUDE_ACTIVE_PROFILE:-unset}"
printf 'ARGS=%s\n' "\$*"
EOF
  chmod +x "$STUB_BIN/claude"

  # Sourcing must not enable errexit — that would kill an interactive shell
  # on the first failing command. This is the reason the helper deliberately
  # does not source config.sh.
  local errexit_state
  errexit_state=$( source "$helper" >/dev/null 2>&1; case $- in *e*) echo "ON";; *) echo "OFF";; esac )
  [ "$errexit_state" = "OFF" ] \
    && pass "sourcing does not enable errexit" \
    || flunk "sourcing does not enable errexit" "an interactive shell would die on any error"

  # It must not define a function called `say` — that would shadow the real
  # macOS text-to-speech command in the user's shell.
  local shadows
  shadows=$( source "$helper" >/dev/null 2>&1; declare -F say >/dev/null && echo "YES" )
  [ -z "$shadows" ] \
    && pass "does not shadow the macOS 'say' command" \
    || flunk "does not shadow the macOS 'say' command"

  # --- no token stored: must fail loudly, not silently use the primary ---
  rm -f "$SANDBOX/keychain.txt"
  local out rc
  out=$( source "$helper" >/dev/null 2>&1; claude-work 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "claude-work fails when no token is stored"
  else
    flunk "claude-work fails when no token is stored" "silently ran as the primary account"
  fi
  case "$out" in
    *"No token"*) pass "the no-token error message is useful" ;;
    *)            flunk "the no-token error message is useful" "got: $out" ;;
  esac

  # --- token stored: must pass the right env through ---
  security add-generic-password -s "claude-code-work-token" -a "$USER" -w "sk-ant-oat-FAKE"

  out=$( source "$helper" >/dev/null 2>&1
         HOME="$FAKE_HOME" claude-work --some-flag 2>/dev/null )

  case "$out" in
    *"TOKEN=sk-ant-oat-FAKE"*) pass "passes CLAUDE_CODE_OAUTH_TOKEN from the Keychain" ;;
    *)                         flunk "passes CLAUDE_CODE_OAUTH_TOKEN from the Keychain" "got: $out" ;;
  esac
  case "$out" in
    *"CONFIG_DIR="*".claude-work"*) pass "passes CLAUDE_CONFIG_DIR" ;;
    *)                              flunk "passes CLAUDE_CONFIG_DIR" "got: $out" ;;
  esac
  case "$out" in
    *"ARGS=--some-flag"*) pass "forwards arguments to claude" ;;
    *)                    flunk "forwards arguments to claude" "got: $out" ;;
  esac

  # The token must not leak into the calling shell after the command returns.
  local leaked
  leaked=$( source "$helper" >/dev/null 2>&1
            claude-work >/dev/null 2>&1
            echo "${CLAUDE_CODE_OAUTH_TOKEN:-clean}" )
  [ "$leaked" = "clean" ] \
    && pass "token does not leak into the calling shell" \
    || flunk "token does not leak into the calling shell" "found: $leaked"

  # claude-whoami should report the primary profile when nothing is set.
  out=$( source "$helper" >/dev/null 2>&1; unset CLAUDE_ACTIVE_PROFILE; claude-whoami 2>&1 )
  case "$out" in
    *primary*) pass "claude-whoami reports the primary profile by default" ;;
    *)         flunk "claude-whoami reports the primary profile by default" "got: $out" ;;
  esac
}


# ===========================================================================
# TEST 5 — config.sh and the shell helper have not drifted apart
# ===========================================================================
# These four values are duplicated by design (see the shell file's header).
# Nothing enforces that they match, so check it here.
test_no_drift() {
  section "Drift between config.sh and shell/claude-profiles.sh"

  local cfg_profile cfg_dir cfg_service
  eval "$( grep -E '^(PROFILE_NAME)=' "$REPO_DIR/config.sh" )"
  cfg_profile="$PROFILE_NAME"
  cfg_dir="$(grep -E '^CLI_SECONDARY_CONFIG_DIR=' "$REPO_DIR/config.sh" | sed 's/.*="\(.*\)"/\1/')"
  cfg_service="$(grep -E '^CLI_TOKEN_KEYCHAIN_SERVICE=' "$REPO_DIR/config.sh" | sed 's/.*="\(.*\)"/\1/')"

  # Resolve the ${PROFILE_NAME} placeholders the same way bash would.
  cfg_dir="${cfg_dir//\$\{PROFILE_NAME\}/$cfg_profile}"
  cfg_service="${cfg_service//\$\{PROFILE_NAME\}/$cfg_profile}"

  local sh_file="$REPO_DIR/shell/claude-profiles.sh"
  local sh_profile sh_dir sh_service
  sh_profile="$(grep -E '^CLAUDE_PROFILE_NAME=' "$sh_file" | sed 's/.*="\(.*\)"/\1/')"
  sh_dir="$(grep -E '^CLAUDE_PROFILE_CONFIG_DIR=' "$sh_file" | sed 's/.*="\(.*\)"/\1/')"
  sh_service="$(grep -E '^CLAUDE_PROFILE_KEYCHAIN_SERVICE=' "$sh_file" | sed 's/.*="\(.*\)"/\1/')"

  [ "$cfg_profile" = "$sh_profile" ] \
    && pass "PROFILE_NAME matches ($cfg_profile)" \
    || flunk "PROFILE_NAME matches" "config.sh=$cfg_profile  shell=$sh_profile"

  [ "$cfg_dir" = "$sh_dir" ] \
    && pass "CLI config dir matches" \
    || flunk "CLI config dir matches" "config.sh=$cfg_dir  shell=$sh_dir"

  [ "$cfg_service" = "$sh_service" ] \
    && pass "Keychain service name matches" \
    || flunk "Keychain service name matches" "config.sh=$cfg_service  shell=$sh_service"

  # envrc.example duplicates them a third time.
  local envrc="$REPO_DIR/shell/envrc.example"
  grep -qF "$cfg_service" "$envrc" \
    && pass "envrc.example uses the same Keychain service" \
    || flunk "envrc.example uses the same Keychain service"
}


# ===========================================================================
# TEST 6 — uninstall is safe
# ===========================================================================
# The single most important property: it must never delete anything
# belonging to the primary account.
test_uninstall_safety() {
  section "99-uninstall.sh safety"

  local f="$REPO_DIR/99-uninstall.sh"

  # Pull out every rm target and confirm none of them is a primary path.
  local dangerous=0
  local line
  while IFS= read -r line; do
    case "$line" in
      *DESKTOP_PRIMARY_DIR*|*'$HOME/.claude"'*|*CLI_NATIVE_KEYCHAIN_SERVICE*)
        dangerous=1
        printf '       dangerous line: %s\n' "$line" ;;
    esac
  done < <(grep -E 'rm -rf|delete-generic-password' "$f")

  [ "$dangerous" -eq 0 ] \
    && pass "no removal targets a primary-account path" \
    || flunk "no removal targets a primary-account path"

  # Every removal must sit behind a prompt.
  #
  # The ask_remove calls are line-wrapped with a trailing backslash, so the
  # `rm -rf` often lands on its own line. Join continuations first, otherwise
  # every wrapped call looks like an unguarded removal.
  local unprompted
  unprompted=$(
    sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$f" \
      | grep -nE '(^|;|&&|\|\|)\s*rm -rf' \
      | grep -v 'ask_remove' || true
  )
  [ -z "$unprompted" ] \
    && pass "every removal goes through the ask_remove prompt" \
    || flunk "every removal goes through the ask_remove prompt" "$unprompted"
}


# ===========================================================================
# MAIN
# ===========================================================================
printf '\033[1mclaude-profiles smoke test\033[0m\n'
printf 'Sandbox: %s\n' "$SANDBOX"

build_stubs
test_syntax
test_config
test_launcher_build
test_shell_helpers
test_no_drift
test_uninstall_safety

section "Result"
if [ "$TESTS_FAILED" -eq 0 ]; then
  printf '  \033[32m%s/%s passed\033[0m\n\n' "$TESTS_RUN" "$TESTS_RUN"
  exit 0
else
  printf '  \033[31m%s of %s failed\033[0m\n\n' "$TESTS_FAILED" "$TESTS_RUN"
  exit 1
fi
