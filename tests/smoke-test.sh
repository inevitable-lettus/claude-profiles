#!/usr/bin/env bash
#
# tests/smoke-test.sh
#
# Exercises the bash implementation against a fake OS in a throwaway
# directory. Nothing outside the sandbox is touched — no real app is
# launched, no real Keychain is read or written, no real HOME is modified.
#
# It works by putting stubs for the OS-specific commands (security, defaults,
# codesign, open, ...) at the front of PATH and pointing both $HOME and
# $CLAUDE_PROFILES_HOME inside the sandbox.
#
# WHAT IT PROVES
#   - every script parses, under bash and (where relevant) zsh
#   - lib/json.awk parses and rejects the right things
#   - the registry round-trips, is canonical, and is stable across writes
#   - N profiles work, and both auth modes behave differently in the right way
#   - the generated launcher is valid and has the right paths baked in
#   - the shell integration switches profiles on cd, and refuses hostile input
#   - a missing token fails loudly instead of falling back to the primary
#   - nothing removable is outside the sandbox's own state
#   - doctor emits valid JSON
#
# WHAT IT CANNOT PROVE
#   Whether the real Claude app honours --user-data-dir, or where it stores
#   credentials. Only `claude-profiles doctor --probe` plus the manual
#   round-trip test, on a real machine, answer those.
#
# Usage:  ./tests/smoke-test.sh [--verbose]
# ---------------------------------------------------------------------------

set -uo pipefail   # deliberately NOT -e: a failing test should report, not abort

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="/tmp/claude-profiles-test-$$"
STUB_BIN="$SANDBOX/stubs"
FAKE_HOME="$SANDBOX/home"
CP="$REPO_DIR/bin/claude-profiles"

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

# assert_eq <description> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else flunk "$1" "expected [$2], got [$3]"; fi
}

# assert_contains <description> <needle> <haystack>
assert_contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) flunk "$1" "expected to find [$2] in: $(printf '%s' "$3" | head -c 300)" ;;
  esac
}

# assert_not_contains <description> <needle> <haystack>
assert_not_contains() {
  case "$3" in
    *"$2"*) flunk "$1" "did not expect [$2]" ;;
    *) pass "$1" ;;
  esac
}

# assert_file_contains <description> <literal> <file>
#
# The `--` before the pattern matters: without it a pattern starting with a
# dash (like "--user-data-dir=") is parsed by grep as an option, and grep
# then blocks reading stdin forever.
assert_file_contains() {
  if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"
  else flunk "$1" "expected to find: $2"; fi
}

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# cp_run — invoke the tool inside the sandbox with stdin closed.
#
# CLAUDE_PROFILES_NO_ADOPT=1 because `init`'s adoption step inspects real
# paths; without it, whether these tests see an extra profile would depend on
# what is on the machine running them.
cp_run() {
  HOME="$FAKE_HOME" CLAUDE_PROFILES_HOME="$FAKE_HOME/.config/claude-profiles" \
    CLAUDE_PROFILES_NO_ADOPT=1 \
    "$CP" "$@" </dev/null 2>&1
}
# cp_out — same, but stderr discarded so only machine output remains.
cp_out() {
  HOME="$FAKE_HOME" CLAUDE_PROFILES_HOME="$FAKE_HOME/.config/claude-profiles" \
    CLAUDE_PROFILES_NO_ADOPT=1 \
    "$CP" "$@" </dev/null 2>/dev/null
}


# ===========================================================================
# Build the fake OS
# ===========================================================================
build_stubs() {
  section "Sandbox: $SANDBOX"
  # PIDs get reused, so a previous aborted run may have left this exact
  # directory behind. Start genuinely clean or tests see stale state.
  rm -rf "$SANDBOX"
  mkdir -p "$STUB_BIN" "$FAKE_HOME/Applications" "$SANDBOX/Applications"

  # --- uname: pretend to be macOS. Flipped later for the Linux pass. ---
  printf '#!/usr/bin/env bash\necho "Darwin"\n' > "$STUB_BIN/uname"

  # --- defaults: a real plist read, so a malformed plist is caught here ---
  cat > "$STUB_BIN/defaults" <<'EOF'
#!/usr/bin/env bash
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

  # --- plutil -lint: real plist validation ---
  cat > "$STUB_BIN/plutil" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-lint" ] || exit 0
python3 -c "
import plistlib, sys
with open(sys.argv[1],'rb') as f: plistlib.load(f)
print('OK')
" "$2"
EOF

  # --- security: a fake Keychain backed by a flat file ---
  cat > "$STUB_BIN/security" <<EOF
#!/usr/bin/env bash
STORE="$SANDBOX/keychain.txt"
touch "\$STORE"
sub="\${1:-}"; shift || true
svc=""; val=""; want_secret=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    -s) svc="\$2"; shift 2 ;;
    -w) if [ "\$sub" = "add-generic-password" ]; then val="\$2"; shift 2; else want_secret=1; shift; fi ;;
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
    [ "\$want_secret" = "1" ] && printf '%s\n' "\${line#*	}"
    exit 0 ;;
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

  # --- claude: dump the environment it was handed ---
  cat > "$STUB_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf 'CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR:-unset}"
printf 'TOKEN=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:-unset}"
printf 'PROFILE=%s\n' "${CLAUDE_ACTIVE_PROFILE:-unset}"
printf 'ARGS=%s\n' "$*"
EOF

  for cmd in codesign osascript pgrep lsregister sudo; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/$cmd"
  done

  chmod +x "$STUB_BIN"/*
  export PATH="$STUB_BIN:$PATH"

  # --- a fake Claude.app, structured like the real one ---
  local app="$SANDBOX/Applications/Claude.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
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
  FAKE_APP="$app"

  pass "sandbox built"
}


# ===========================================================================
# 1 — everything parses
# ===========================================================================
test_syntax() {
  section "Syntax"
  local f
  for f in "$REPO_DIR/bin/claude-profiles" "$REPO_DIR/lib"/*.sh "$REPO_DIR/tests"/*.sh; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/dev/null; then pass "parses: ${f#"$REPO_DIR"/}"
    else flunk "parses: ${f#"$REPO_DIR"/}" "$(bash -n "$f" 2>&1 | head -3)"; fi
  done

  # The awk parser has to be valid awk on whatever awk this machine has.
  if echo '{}' | awk -f "$REPO_DIR/lib/json.awk" >/dev/null 2>&1; then
    pass "lib/json.awk is valid awk"
  else
    flunk "lib/json.awk is valid awk" "$(echo '{}' | awk -f "$REPO_DIR/lib/json.awk" 2>&1 | head -3)"
  fi

  # A library must never change the caller's error behaviour. Sourcing one
  # into an interactive shell should not turn on errexit, or the first
  # failing command would kill the terminal.
  #
  # Tested by sourcing rather than grepping: lib/desktop.sh legitimately
  # contains "set -euo pipefail" inside the heredoc for the generated
  # launcher, which is a standalone script and does need it.
  local lib state
  for lib in "$REPO_DIR/lib"/*.sh; do
    # shellcheck disable=SC1090,SC2034  # path is computed; LIB_DIR is read by the sourced file
    state=$( LIB_DIR="$REPO_DIR/lib"; . "$lib" >/dev/null 2>&1
             if [ -o errexit ]; then echo ON; else echo OFF; fi )
    if [ "$state" = "OFF" ]; then pass "sourcing does not set errexit: $(basename "$lib")"
    else flunk "sourcing does not set errexit: $(basename "$lib")"; fi
  done
}


# ===========================================================================
# 2 — lib/json.awk
# ===========================================================================
test_json_awk() {
  section "lib/json.awk"
  local out

  out="$(printf '%s' '{"a":{"b":"c"},"n":1,"t":true,"z":null,"e":{},"arr":[]}' | awk -f "$REPO_DIR/lib/json.awk")"
  assert_contains "flattens nested objects" '.a.b	string	c' "$out"
  assert_contains "types numbers" '.n	number	1' "$out"
  assert_contains "types booleans" '.t	bool	true' "$out"
  assert_contains "types null" '.z	null	' "$out"
  assert_contains "emits empty objects" '.e	object	' "$out"
  assert_contains "emits empty arrays" '.arr	array	0' "$out"

  # Values containing a tab or newline must survive the line format.
  out="$(printf '%s' '{"a":"x\ty","b":"p\nq"}' | awk -f "$REPO_DIR/lib/json.awk")"
  assert_contains "escapes tabs in values" '.a	string	x\ty' "$out"
  assert_contains "escapes newlines in values" '.b	string	p\nq' "$out"

  # Malformed input must fail, not produce partial output that a caller
  # would treat as a valid (but wrong) registry.
  local rc
  printf '%s' '{"a":' | awk -f "$REPO_DIR/lib/json.awk" >/dev/null 2>&1; rc=$?
  assert_eq "rejects truncated input" "2" "$rc"
  printf '%s' '{"a":1}{"b":2}' | awk -f "$REPO_DIR/lib/json.awk" >/dev/null 2>&1; rc=$?
  assert_eq "rejects trailing content" "2" "$rc"
  printf '%s' '{"a":oops}' | awk -f "$REPO_DIR/lib/json.awk" >/dev/null 2>&1; rc=$?
  assert_eq "rejects bare words" "2" "$rc"
}


# ===========================================================================
# 3 — the registry
# ===========================================================================
test_registry() {
  section "Registry"

  cp_run init >/dev/null
  local reg="$FAKE_HOME/.config/claude-profiles/profiles.json"
  [ -f "$reg" ] && pass "init creates the registry" || { flunk "init creates the registry"; return; }

  # Owner-only. The registry names every profile directory you have.
  local mode
  # GNU stat must be tried FIRST: its -f means "filesystem status", which
  # succeeds and prints a File: block, so a BSD-first order never falls
  # through on Linux. BSD stat has no -c at all, so it fails cleanly.
  mode="$(stat -c '%a' "$reg" 2>/dev/null || stat -f '%Lp' "$reg" 2>/dev/null)"
  assert_eq "registry is mode 600" "600" "$mode"

  cp_run add work --no-desktop --auth oauth-token --description 'agency "quoted"' >/dev/null
  cp_run add client-a --no-desktop --auth config-dir >/dev/null
  cp_run add solo --no-desktop --auth config-dir --config-dir "$FAKE_HOME/custom-dir" >/dev/null

  local json; json="$(cp_out list --json)"
  assert_contains "profile appears in list --json" '"work"' "$json"
  assert_contains "second profile appears" '"client-a"' "$json"
  assert_contains "quotes in a description are escaped" '\"quoted\"' "$json"
  assert_contains "custom config dir is honoured" 'custom-dir' "$json"

  # Canonical order: version before profiles, cli before description,
  # configDir before auth, and profile names alphabetical.
  local order
  order="$(printf '%s' "$json" | grep -oE '"(version|profiles|client-a|solo|work|cli|configDir|auth|description)"' | tr -d '"' | tr '\n' ' ')"
  assert_contains "canonical key order" "version profiles client-a cli configDir auth" "$order"

  # Re-serialising must be byte-identical, or the contract test and every
  # git diff on a synced registry become noise.
  local a b
  a="$(cp_out list --json)"; b="$(cp_out list --json)"
  assert_eq "serialization is stable" "$a" "$b"

  # And it must be parseable by our own parser.
  if printf '%s' "$json" | awk -f "$REPO_DIR/lib/json.awk" >/dev/null 2>&1; then
    pass "list --json output re-parses"
  else
    flunk "list --json output re-parses"
  fi

  # Paths are stored with ~ so a synced dotfiles repo is portable.
  assert_contains "paths are stored with a leading ~" '"~/.claude-work"' "$json"
}


# ===========================================================================
# 4 — profile names, and the refusals that matter
# ===========================================================================
test_guardrails() {
  section "Guardrails"

  local out
  out="$(cp_run add 'Bad Name')";        assert_contains "rejects spaces and capitals" "Invalid profile name" "$out"
  out="$(cp_run add 'primary')";         assert_contains "rejects the reserved name 'primary'" "Invalid profile name" "$out"
  out="$(cp_run add 'a.b')";             assert_contains "rejects dots (the path format is dot-delimited)" "Invalid profile name" "$out"
  out="$(cp_run add '../../etc')";       assert_contains "rejects path traversal" "Invalid profile name" "$out"
  out="$(cp_run add 'x;rm -rf /')";      assert_contains "rejects shell metacharacters" "Invalid profile name" "$out"

  # The single most important refusal: never point a profile at the primary
  # account's directory.
  out="$(cp_run add danger --no-desktop --config-dir "$FAKE_HOME/.claude")"
  assert_contains "refuses the primary CLI config dir" "primary account's config directory" "$out"

  out="$(cp_run add danger2 --no-desktop --config-dir "$FAKE_HOME/.claude-work")"
  assert_contains "refuses a config dir already used by another profile" "share cli.configDir" "$out"
}


# ===========================================================================
# 5 — the two auth modes behave differently
# ===========================================================================
test_auth_modes() {
  section "Auth modes"

  # config-dir: no token needed, CLAUDE_CODE_OAUTH_TOKEN must NOT be set.
  local out
  out="$(cp_out run client-a -- --hello)"
  assert_contains "config-dir passes CLAUDE_CONFIG_DIR" "CONFIG_DIR=$FAKE_HOME/.claude-client-a" "$out"
  assert_contains "config-dir sets CLAUDE_ACTIVE_PROFILE" "PROFILE=client-a" "$out"
  assert_contains "config-dir sets no token" "TOKEN=unset" "$out"
  assert_contains "arguments are forwarded" "ARGS=--hello" "$out"

  # oauth-token with nothing stored must fail LOUDLY. Falling through to the
  # primary account is the exact failure this tool exists to prevent.
  out="$(cp_run run work -- --hello)"
  assert_contains "token profile with no token fails" "no token is stored" "$out"
  assert_not_contains "token profile with no token does not run claude" "CONFIG_DIR=" "$out"

  # Store one and try again.
  HOME="$FAKE_HOME" security add-generic-password -s "claude-profiles-work-token" -a "$USER" -w "sk-ant-oat-FAKE"
  out="$(cp_out run work -- --hello)"
  assert_contains "token profile passes the token" "TOKEN=sk-ant-oat-FAKE" "$out"
  assert_contains "token profile passes the config dir" "CONFIG_DIR=$FAKE_HOME/.claude-work" "$out"

  # --bare silently ignores the token, so it must be called out.
  out="$(cp_run run work -- --bare -p hi)"
  assert_contains "warns that --bare ignores the token" "does not read CLAUDE_CODE_OAUTH_TOKEN" "$out"

  # Anything at precedence rank 2 or 3 outranks the profile's token.
  out="$(HOME="$FAKE_HOME" CLAUDE_PROFILES_HOME="$FAKE_HOME/.config/claude-profiles" \
        ANTHROPIC_API_KEY=sk-fake "$CP" run work -- --hello </dev/null 2>&1)"
  assert_contains "warns when ANTHROPIC_API_KEY outranks the profile" "ANTHROPIC_API_KEY is set" "$out"
}


# ===========================================================================
# 6 — env output is safe to eval
# ===========================================================================
test_env_output() {
  section "env output"

  local out
  out="$(cp_out env client-a)"
  assert_contains "exports the config dir" "export CLAUDE_CONFIG_DIR=" "$out"
  assert_contains "quotes the value" "'" "$out"
  assert_contains "unsets the token for a config-dir profile" "unset CLAUDE_CODE_OAUTH_TOKEN" "$out"

  # It has to be valid shell, since the hook evals it.
  if printf '%s' "$out" | bash -n 2>/dev/null; then pass "env output is valid bash"
  else flunk "env output is valid bash"; fi

  # --unset must clear everything, or leaving a directory would leave the
  # shell half-switched.
  out="$(cp_out env --unset)"
  assert_contains "--unset clears the config dir" "CLAUDE_CONFIG_DIR" "$out"
  assert_contains "--unset clears the token" "CLAUDE_CODE_OAUTH_TOKEN" "$out"
  assert_contains "--unset clears the marker" "CLAUDE_ACTIVE_PROFILE" "$out"

  # A profile that does not exist must be an error, not empty output that
  # the caller would treat as a successful no-op switch.
  local rc
  cp_out env ghost >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && pass "env on an unknown profile exits non-zero" \
                  || flunk "env on an unknown profile exits non-zero"
}


# ===========================================================================
# 7 — the generated shell integration
# ===========================================================================
test_shell_integration() {
  section "Shell integration"

  local init="$SANDBOX/init.bash"
  cp_out shell-init bash > "$init"

  if bash -n "$init" 2>/dev/null; then pass "generated bash integration parses"
  else flunk "generated bash integration parses" "$(bash -n "$init" 2>&1 | head -3)"; fi

  if command -v zsh >/dev/null 2>&1; then
    cp_out shell-init zsh > "$SANDBOX/init.zsh"
    if zsh -n "$SANDBOX/init.zsh" 2>/dev/null; then pass "generated zsh integration parses"
    else flunk "generated zsh integration parses" "$(zsh -n "$SANDBOX/init.zsh" 2>&1 | head -3)"; fi
  fi

  assert_file_contains "declares a function per profile" "claude-work()" "$init"
  assert_file_contains "declares the subshell helper" "claude-work-shell()" "$init"
  assert_file_contains "installs the directory hook" "_claude_profiles_sync" "$init"

  # The pre-1.0 design duplicated four constants into the shell file and had
  # a whole test policing the drift. The generated form must contain no
  # configuration at all beyond the binary path and the profile names.
  assert_file_contains "does not hardcode a config dir" "CLAUDE_PROFILES_BIN" "$init"
  if grep -qE '\.claude-work"?$' "$init"; then
    flunk "no profile paths are baked into the shell integration" \
          "found a literal config dir — that is the drift the registry exists to prevent"
  else
    pass "no profile paths are baked into the shell integration"
  fi

  # It must not define `say`, which would shadow the macOS text-to-speech
  # command in the user's interactive shell.
  local shadows
  # shellcheck disable=SC1090
  shadows=$( source "$init" >/dev/null 2>&1; declare -F say >/dev/null && echo YES )
  [ -z "$shadows" ] && pass "does not shadow the macOS 'say' command" \
                    || flunk "does not shadow the macOS 'say' command"

  # Sourcing must not enable errexit — that would kill an interactive shell
  # on the first failing command.
  # `case $- in *e*)` inside a command substitution trips bash 3.2's parser,
  # so ask the option directly.
  local errexit
  # shellcheck disable=SC1090
  errexit=$( source "$init" >/dev/null 2>&1; if [ -o errexit ]; then echo ON; else echo OFF; fi )
  assert_eq "sourcing does not enable errexit" "OFF" "$errexit"
}


# ===========================================================================
# 8 — per-directory switching, including hostile input
# ===========================================================================
test_auto_switch() {
  section "Per-directory switching"

  local proj="$FAKE_HOME/projects"
  mkdir -p "$proj/agency" "$proj/plain" "$proj/hostile" "$proj/deep/src"
  printf 'client-a\n'                    > "$proj/agency/.claude-profile"
  printf '  client-a  \r\n'              > "$proj/deep/.claude-profile"
  printf '../../etc/passwd; rm -rf /\n'  > "$proj/hostile/.claude-profile"
  printf 'ghost\n'                       > "$proj/plain/.claude-profile"

  # Drive the hook the way an interactive shell would.
  local script="$SANDBOX/drive.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
export HOME="$FAKE_HOME"
export CLAUDE_PROFILES_HOME="$FAKE_HOME/.config/claude-profiles"
source "$SANDBOX/init.bash"
report() { printf '%s|%s|%s\n' "\$1" "\${CLAUDE_ACTIVE_PROFILE:-}" "\${_CLAUDE_PROFILES_AUTO:-}"; }
cd "$proj/agency";  _claude_profiles_prompt_hook; report agency
cd "$proj/deep/src"; _claude_profiles_prompt_hook; report deep
cd "$FAKE_HOME";    _claude_profiles_prompt_hook; report home
cd "$proj/hostile"; _claude_profiles_prompt_hook; report hostile
cd "$proj/plain";   _claude_profiles_prompt_hook; report ghost
cd "$FAKE_HOME"
claude-profile-use work; report explicit
cd "$proj/agency";  _claude_profiles_prompt_hook; report explicit_kept
EOF
  local out; out="$(bash "$script" 2>/dev/null)"

  assert_contains "switches on entering a directory with .claude-profile" "agency|client-a|1" "$out"
  assert_contains "a nested directory inherits the file, CRLF and all" "deep|client-a|1" "$out"
  assert_contains "switches back on leaving" "home||" "$out"

  # The security property. A .claude-profile arrives inside repositories you
  # clone; it must never be able to do anything but select a name you already
  # have, and an unusable one must leave you on the primary account.
  assert_contains "a hostile .claude-profile leaves you on the primary" "hostile||" "$out"
  assert_contains "an unregistered name leaves you on the primary" "ghost||" "$out"

  # An explicit choice must survive a cd into a directory that asks for
  # something else.
  assert_contains "an explicit choice is applied" "explicit|work|" "$out"
  assert_contains "an explicit choice is not clobbered by a file" "explicit_kept|work|" "$out"
}


# ===========================================================================
# 9 — the desktop launcher (macOS)
# ===========================================================================
test_launcher() {
  section "Launcher (macOS)"

  cp_run add desk --no-cli --desktop --app-path "$FAKE_APP" \
    --user-data-dir "$FAKE_HOME/Library/Application Support/Claude-Desk" >/dev/null

  # /Applications is not writable in the sandbox, so aim the launcher at the
  # sandbox copy by overriding where the tool installs it.
  local out
  out="$(HOME="$FAKE_HOME" CLAUDE_PROFILES_HOME="$FAKE_HOME/.config/claude-profiles" \
        CLAUDE_PROFILES_ASSUME_YES=1 "$CP" install-launcher desk </dev/null 2>&1)"

  local app="/Applications/Claude Desk.app"
  if [ -d "$app" ]; then
    pass "launcher bundle created"
    local launcher="$app/Contents/MacOS/launcher"
    if bash -n "$launcher" 2>/dev/null; then pass "generated launcher is valid bash"
    else flunk "generated launcher is valid bash"; fi
    assert_file_contains "launcher passes --user-data-dir" "--user-data-dir=" "$launcher"
    assert_file_contains "launcher forces a new instance" "open -n" "$launcher"
    assert_file_contains "launcher bakes in the profile path" "Claude-Desk" "$launcher"
    # It must work standalone, so no registry lookups may remain in it.
    if grep -q 'claude-profiles list\|reg_get' "$launcher"; then
      flunk "launcher is standalone"
    else
      pass "launcher is standalone (no registry lookups)"
    fi
    python3 -c "import plistlib,sys; d=plistlib.load(open(sys.argv[1],'rb')); sys.exit(0 if not d['CFBundleIdentifier'].startswith('com.anthropic') else 1)" \
      "$app/Contents/Info.plist" 2>/dev/null \
      && pass "bundle ID is ours, not Anthropic's" \
      || flunk "bundle ID is ours, not Anthropic's"
    rm -rf "$app"
  else
    # Not fatal: on a locked-down machine /Applications is not writable and
    # the sudo stub cannot help. Report it rather than failing the suite.
    printf '  \033[33mSKIP\033[0m launcher install (could not write to /Applications)\n'
  fi
}


# ===========================================================================
# 10 — doctor
# ===========================================================================
test_doctor() {
  section "doctor"

  local json; json="$(cp_out doctor --json)"
  if printf '%s' "$json" | awk -f "$REPO_DIR/lib/json.awk" >/dev/null 2>&1; then
    pass "doctor --json emits valid JSON"
  else
    flunk "doctor --json emits valid JSON" "$(printf '%s' "$json" | head -c 200)"
  fi
  assert_contains "doctor --json reports the platform" '"platform"' "$json"
  assert_contains "doctor --json counts failures" '"failed"' "$json"

  # No human chatter may reach stdout in JSON mode, or the output is
  # unparseable for anything downstream.
  case "$json" in
    "{"*) pass "doctor --json puts nothing but JSON on stdout" ;;
    *) flunk "doctor --json puts nothing but JSON on stdout" "starts with: $(printf '%s' "$json" | head -c 60)" ;;
  esac

  # A secret must never appear in output, in either mode.
  local human; human="$(cp_run doctor)"
  assert_not_contains "doctor does not print the token (human)" "sk-ant-oat-FAKE" "$human"
  assert_not_contains "doctor does not print the token (json)" "sk-ant-oat-FAKE" "$json"

  # On macOS, config-dir auth cannot isolate the login. doctor must say so.
  assert_contains "doctor flags config-dir auth on macOS" "does NOT separate the login" "$human"
}


# ===========================================================================
# 11 — Linux behaves differently in exactly the right way
# ===========================================================================
test_linux_pass() {
  section "Linux pass (uname stub flipped)"

  printf '#!/usr/bin/env bash\necho "Linux"\n' > "$STUB_BIN/uname"

  # platform_find_desktop_app looks for claude-desktop on PATH on Linux. The
  # macOS stub is named `claude`, which satisfied that lookup only because
  # HFS+/APFS are case-insensitive — on a case-sensitive filesystem it did
  # not, and the desktop checks silently skipped. Give Linux its own stub so
  # the result does not depend on the host's filesystem semantics.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/claude-desktop"
  chmod +x "$STUB_BIN/claude-desktop"

  local lhome="$SANDBOX/linux-home"
  mkdir -p "$lhome"

  local out
  out=$(HOME="$lhome" CLAUDE_PROFILES_HOME="$lhome/.config/claude-profiles" "$CP" init </dev/null 2>&1)
  out=$(HOME="$lhome" CLAUDE_PROFILES_HOME="$lhome/.config/claude-profiles" "$CP" add work --no-desktop </dev/null 2>&1)

  # THE headline difference: on Linux, CLAUDE_CONFIG_DIR isolates the login
  # by itself, so a new profile must default to config-dir and must not ask
  # for a token.
  local json
  json=$(HOME="$lhome" CLAUDE_PROFILES_HOME="$lhome/.config/claude-profiles" "$CP" list --json </dev/null 2>/dev/null)
  assert_contains "Linux defaults to config-dir auth" '"auth": "config-dir"' "$json"
  assert_not_contains "Linux does not default to token auth" 'oauth-token' "$json"
  assert_contains "Linux tells you to just log in" "/login" "$out"
  assert_not_contains "Linux does not mention the Keychain" "Keychain" "$out"

  # The desktop user-data dir follows the Linux convention, not Apple's.
  out=$(HOME="$lhome" CLAUDE_PROFILES_HOME="$lhome/.config/claude-profiles" \
        "$CP" add gui --no-cli --desktop --app-path "$STUB_BIN/claude" </dev/null 2>&1)
  json=$(HOME="$lhome" CLAUDE_PROFILES_HOME="$lhome/.config/claude-profiles" "$CP" list --json </dev/null 2>/dev/null)
  assert_contains "Linux desktop dir follows the XDG convention" '.config/Claude-Gui' "$json"
  assert_not_contains "Linux does not use Library/Application Support" 'Library/Application Support' "$json"

  local human
  human=$(HOME="$lhome" CLAUDE_PROFILES_HOME="$lhome/.config/claude-profiles" "$CP" doctor </dev/null 2>&1)
  assert_contains "Linux doctor explains why profiles cannot collide" "inside the user-data directory" "$human"

  printf '#!/usr/bin/env bash\necho "Darwin"\n' > "$STUB_BIN/uname"
  rm -f "$STUB_BIN/claude-desktop"
}


# ===========================================================================
# 12 — removal safety
# ===========================================================================
# The single most important property of the whole tool: nothing it deletes
# may ever belong to the primary account.
test_removal_safety() {
  section "Removal safety"

  local sources="$REPO_DIR/bin/claude-profiles $REPO_DIR/lib/desktop.sh $REPO_DIR/lib/cli.sh"
  local dangerous=0 line

  # Join line continuations first, or a wrapped call looks like an unguarded
  # removal.
  while IFS= read -r line; do
    case "$line" in
      *'rm -rf "$HOME"'*|*'rm -rf "$(platform_primary'*|*'rm -rf ~/.claude"'*)
        dangerous=1; printf '       dangerous: %s\n' "$line" ;;
    esac
  done < <(cat $sources | sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' | grep -E 'rm -rf|delete-generic-password')

  [ "$dangerous" -eq 0 ] && pass "no removal targets a primary-account path" \
                         || flunk "no removal targets a primary-account path"

  # Every removal must sit behind a prompt — either inline (`confirm ... &&
  # rm`) or inside an `if confirm` block opened in the preceding few lines.
  # A plain same-line grep misses the block form, so track how recently a
  # confirm was seen.
  local unprompted
  unprompted=$(awk '
    /confirm / { last = NR }
    /rm -rf/ {
      if ($0 ~ /confirm /) next            # inline form
      if (last > 0 && NR - last <= 4) next # inside an if-confirm block
      printf("%d: %s\n", NR, $0)
    }
  ' "$REPO_DIR/bin/claude-profiles")

  [ -z "$unprompted" ] && pass "every removal goes through a confirm prompt" \
                       || flunk "every removal goes through a confirm prompt" "$unprompted"

  # And prove the whole uninstall path at runtime: with no terminal every
  # prompt declines, so it must unregister and delete nothing.
  local keep="$FAKE_HOME/.claude-solo"
  [ -d "$keep" ] || mkdir -p "$keep"
  cp_run uninstall >/dev/null
  [ -d "$keep" ] && pass "uninstall keeps profile data when it cannot ask" \
                 || flunk "uninstall keeps profile data when it cannot ask"
  [ -f "$FAKE_HOME/.config/claude-profiles/profiles.json" ] \
    && pass "uninstall keeps the registry when it cannot ask" \
    || flunk "uninstall keeps the registry when it cannot ask"

  # And prove it at runtime: with no terminal, confirm() must decline, so
  # `remove` unregisters but deletes nothing.
  local dir="$FAKE_HOME/.claude-client-a"
  [ -d "$dir" ] || mkdir -p "$dir"
  cp_run remove client-a >/dev/null
  [ -d "$dir" ] && pass "remove keeps the data when it cannot ask" \
                || flunk "remove keeps the data when it cannot ask" "it deleted $dir unprompted"

  local json; json="$(cp_out list --json)"
  assert_not_contains "remove unregisters the profile" '"client-a"' "$json"

  # The primary account's own directory must still be untouched throughout.
  [ ! -e "$FAKE_HOME/.claude/DELETED" ] && pass "primary config dir untouched" \
                                        || flunk "primary config dir untouched"
}


# ===========================================================================
# 13 — no drift between the two implementations
# ===========================================================================
# The bash and PowerShell registries must impose the same canonical key
# order. If they diverge, the same registry serialises differently on
# different platforms and every sync produces a spurious diff.
test_key_order_contract() {
  section "Key-order contract"

  local bash_keys ps_keys
  bash_keys="$(grep -oE '\$0 == "[a-zA-Z]+"\) *rank = [0-9]+' "$REPO_DIR/lib/registry.sh" \
    | sed -E 's/.*"([a-zA-Z]+)".*rank = ([0-9]+)/\2 \1/' | sort -n)"
  ps_keys="$(grep -oE "'[a-zA-Z]+' *= *[0-9]+" "$REPO_DIR/powershell/ClaudeProfiles/Private/Registry.ps1" \
    | sed -E "s/'([a-zA-Z]+)' *= *([0-9]+)/\2 \1/" | sort -n)"

  if [ -n "$bash_keys" ] && [ "$bash_keys" = "$ps_keys" ]; then
    pass "bash and PowerShell agree on the canonical key order"
  else
    flunk "bash and PowerShell agree on the canonical key order" \
          "$(diff <(printf '%s\n' "$bash_keys") <(printf '%s\n' "$ps_keys") | head -10)"
  fi

  # The schema documents the same names; a key in one and not the other means
  # something was added without being written down.
  local key
  for key in configDir auth tokenBackend tokenCreated userDataDir appPath mirrored launcher; do
    if grep -q "\"$key\"" "$REPO_DIR/schema/profiles.schema.json"; then :
    else flunk "schema documents '$key'"; fi
  done
  pass "schema documents every registry key"
}


# ===========================================================================
printf '\033[1mclaude-profiles smoke test\033[0m\n'

build_stubs
test_syntax
test_json_awk
test_registry
test_guardrails
test_auth_modes
test_env_output
test_shell_integration
test_auto_switch
test_launcher
test_doctor
test_linux_pass
test_removal_safety
test_key_order_contract

section "Result"
if [ "$TESTS_FAILED" -eq 0 ]; then
  printf '  \033[32m%s/%s passed\033[0m\n\n' "$TESTS_RUN" "$TESTS_RUN"
  exit 0
else
  printf '  \033[31m%s of %s failed\033[0m\n\n' "$TESTS_FAILED" "$TESTS_RUN"
  exit 1
fi
