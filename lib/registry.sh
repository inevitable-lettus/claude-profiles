# lib/registry.sh
#
# The profile registry: read, mutate, validate, write.
#
# WHY THIS FILE EXISTS
# --------------------
# Before 1.0 the profile name, its config directory and its Keychain service
# name were constants in config.sh, hand-copied into shell/claude-profiles.sh
# and again into shell/envrc.example. Three copies, nothing enforcing that
# they matched, and a whole test whose only job was to notice when they
# drifted. The registry replaces all of that with one file that every code
# path — bash, PowerShell, the generated shell integration — reads.
#
# ON-DISK SHAPE
#
#   {
#     "version": 1,
#     "profiles": {
#       "work": {
#         "cli": {
#           "configDir": "~/.claude-work",
#           "auth": "config-dir",           // or "oauth-token"
#           "tokenBackend": "keychain",     // only with oauth-token
#           "tokenCreated": "2026-08-02"
#         },
#         "desktop": {
#           "userDataDir": "~/Library/Application Support/Claude-Work",
#           "appPath": "/Applications/Claude.app",
#           "mirrored": "false",
#           "launcher": "/Applications/Claude Work.app"
#         },
#         "description": "agency account"
#       }
#     }
#   }
#
# Paths are stored with a leading ~ so a synced dotfiles repo survives moving
# between machines. Nothing but path_expand() ever consumes them.
#
# IN-MEMORY SHAPE
#
# One string, $REG_DATA, holding the flattened output of lib/json.awk — one
# "path<TAB>type<TAB>encoded-value" line per leaf. bash 3.2 ships on macOS and
# has no associative arrays, so a flat line format that awk and grep can chew
# on beats any attempt at a nested structure.
# ---------------------------------------------------------------------------

REG_DATA=""

# The only shape this tool understands. Bumping it means writing a migration
# in registry_load.
REGISTRY_VERSION=1


# ---------------------------------------------------------------------------
# Encoding — the other half of lib/json.awk's encode()
# ---------------------------------------------------------------------------
reg_encode() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}


# ---------------------------------------------------------------------------
# Profile names
# ---------------------------------------------------------------------------
# Deliberately strict, for three separate reasons:
#
#   1. The name becomes a directory name, a Keychain service name, a Windows
#      shortcut filename and a shell function name. The intersection of what
#      all four accept is small.
#   2. The registry's flat path format is dot-delimited, so a dot in a profile
#      name would make ".profiles.a.b.cli" ambiguous.
#   3. A .claude-profile file arrives inside repositories you clone, which
#      makes it untrusted input. Constraining the character set here means a
#      hostile one cannot smuggle a path, a flag or a shell metacharacter
#      through. See lib/workflow.sh for the rest of that argument.
#
# "primary" and "default" are reserved: they name the account this tool
# deliberately never manages, and letting someone create a profile called
# "primary" would make every error message ambiguous.
PROFILE_NAME_PATTERN='^[a-z0-9][a-z0-9_-]*$'
PROFILE_NAME_MAX=32

profile_name_valid() {
  local name="$1"
  [ -n "$name" ] || return 1
  [ "${#name}" -le "$PROFILE_NAME_MAX" ] || return 1
  case "$name" in
    primary|default|all|none) return 1 ;;
  esac
  printf '%s' "$name" | grep -qE "$PROFILE_NAME_PATTERN"
}

# require_profile_name <name> — validate or die with a useful message.
require_profile_name() {
  local name="$1"
  if ! profile_name_valid "$name"; then
    die "Invalid profile name '$name'. Use lowercase letters, digits, '-' and '_' (max $PROFILE_NAME_MAX, cannot start with '-' or '_', and 'primary'/'default'/'all'/'none' are reserved)."
  fi
}


# ---------------------------------------------------------------------------
# Load / save
# ---------------------------------------------------------------------------

# registry_load [--required]
#
# Reads the registry into $REG_DATA. A missing file is not an error — it means
# `init` has not run yet — and produces an empty registry, so `list` on a
# fresh machine prints nothing rather than exploding.
registry_load() {
  local path parsed
  path="$(registry_path)"

  if [ ! -f "$path" ]; then
    if [ "${1:-}" = "--required" ]; then
      die "No registry at $path. Run: claude-profiles init"
    fi
    REG_DATA=""
    return 0
  fi

  parsed="$(awk -f "$LIB_DIR/json.awk" < "$path")" || {
    die "$path is not valid JSON. Fix it by hand, or move it aside and re-run 'claude-profiles init'."
  }

  REG_DATA="$parsed"

  local found
  found="$(reg_get '.version' || true)"
  if [ -n "$found" ] && [ "$found" != "$REGISTRY_VERSION" ]; then
    die "$path is registry version $found; this build understands version $REGISTRY_VERSION. Upgrade claude-profiles."
  fi
}

# registry_save — canonical serialize, atomic replace, owner-only.
registry_save() {
  local path tmp dir
  path="$(registry_path)"
  dir="$(dirname "$path")"

  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true

  # Write to a sibling temp file and rename. A rename within one filesystem is
  # atomic, so an interrupted save can never leave a half-written registry —
  # which would otherwise take out every profile at once.
  tmp="$path.tmp.$$"
  registry_serialize > "$tmp" || { rm -f "$tmp"; die "Failed to serialize the registry"; }

  # Parse what we just wrote before trusting it. This is cheap and it means a
  # bug in the serializer surfaces here rather than the next time you run any
  # command at all.
  awk -f "$LIB_DIR/json.awk" < "$tmp" >/dev/null || {
    rm -f "$tmp"
    die "Serializer produced invalid JSON — this is a bug in claude-profiles"
  }

  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$path" || { rm -f "$tmp"; die "Failed to write $path"; }
}


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

# reg_get <path> — print the decoded value; return 1 if the path is absent.
reg_get() {
  local path="$1" line value
  line="$(printf '%s\n' "$REG_DATA" | awk -F'\t' -v p="$path" '$1 == p { print $3; found=1; exit } END { exit !found }')" || return 1
  json_decode "$line"
}

# reg_get_or <path> <default>
reg_get_or() {
  local v
  if v="$(reg_get "$1")"; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

# reg_has <path>
reg_has() {
  printf '%s\n' "$REG_DATA" | awk -F'\t' -v p="$1" '$1 == p { found=1; exit } END { exit !found }'
}

# reg_children <prefix> — the distinct next path segments under a prefix,
# in first-seen order.
#
# index() rather than a regex, so a prefix containing a dot (every prefix does)
# is compared literally.
reg_children() {
  printf '%s\n' "$REG_DATA" | awk -F'\t' -v p="$1." '
    index($1, p) == 1 {
      rest = substr($1, length(p) + 1)
      dot = index(rest, ".")
      if (dot > 0) { rest = substr(rest, 1, dot - 1) }
      br = index(rest, "[")
      if (br > 0) { rest = substr(rest, 1, br - 1) }
      if (rest != "" && !(rest in seen)) { seen[rest] = 1; print rest }
    }'
}

# registry_profiles — every registered profile name, sorted.
registry_profiles() {
  reg_children '.profiles' | sort
}

registry_has_profile() {
  reg_has ".profiles.$1.cli.configDir" || reg_has ".profiles.$1.desktop.userDataDir" \
    || printf '%s\n' "$REG_DATA" | awk -F'\t' -v p=".profiles.$1." 'index($1, p) == 1 { found=1; exit } END { exit !found }'
}

registry_count() {
  local n
  n="$(registry_profiles | grep -c . 2>/dev/null)" || n=0
  printf '%s' "${n:-0}"
}


# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

# reg_set <path> <type> <value>
#
# type is string | number | bool | null | object | array, matching lib/json.awk.
reg_set() {
  local path="$1" type="$2" value="$3" enc
  enc="$(reg_encode "$value")"
  REG_DATA="$(printf '%s\n' "$REG_DATA" | awk -F'\t' -v p="$path" 'NF && $1 != p')"
  if [ -n "$REG_DATA" ]; then
    REG_DATA="$REG_DATA
$path	$type	$enc"
  else
    REG_DATA="$path	$type	$enc"
  fi
}

# reg_set_str <path> <value> — the common case; an empty value removes the key
# rather than storing "", so optional fields stay genuinely absent.
reg_set_str() {
  if [ -z "$2" ]; then reg_unset "$1"; else reg_set "$1" string "$2"; fi
}

# reg_unset <path> — remove one leaf.
reg_unset() {
  REG_DATA="$(printf '%s\n' "$REG_DATA" | awk -F'\t' -v p="$1" 'NF && $1 != p')"
}

# reg_unset_subtree <prefix> — remove a leaf and everything beneath it.
reg_unset_subtree() {
  REG_DATA="$(printf '%s\n' "$REG_DATA" | awk -F'\t' -v p="$1" -v pd="$1." -v pb="$1[" '
    NF && $1 != p && index($1, pd) != 1 && index($1, pb) != 1')"
}


# ---------------------------------------------------------------------------
# Serialization
# ---------------------------------------------------------------------------
# Canonical output: two-space indent, a fixed key order, one key per line.
# Deterministic output means `git diff` on a synced registry is readable and
# the contract test can compare bash and PowerShell byte for byte.

# reg_sort_children <prefix> — children in canonical order.
#
# Known keys come first in a hand-picked order, so a profile reads
# cli-then-desktop rather than alphabetically; anything unrecognised follows
# alphabetically, which keeps forward-compatibility with a newer registry
# without reordering it.
reg_sort_children() {
  reg_children "$1" | awk '
    {
      rank = 50
      if ($0 == "version")      rank = 0
      if ($0 == "profiles")     rank = 1
      if ($0 == "cli")          rank = 10
      if ($0 == "desktop")      rank = 11
      if ($0 == "description")  rank = 12
      if ($0 == "configDir")    rank = 20
      if ($0 == "auth")         rank = 21
      if ($0 == "tokenBackend") rank = 22
      if ($0 == "tokenCreated") rank = 23
      if ($0 == "userDataDir")  rank = 30
      if ($0 == "appPath")      rank = 31
      if ($0 == "mirrored")     rank = 32
      if ($0 == "launcher")     rank = 33
      printf("%03d\t%s\n", rank, $0)
    }' | sort | cut -f2-
}

# reg_emit_scalar <type> <decoded-value>
reg_emit_scalar() {
  case "$1" in
    number|bool) printf '%s' "$2" ;;
    null)        printf 'null' ;;
    object)      printf '{}' ;;
    array)       printf '[]' ;;
    *)           printf '"%s"' "$(json_escape "$2")" ;;
  esac
}

# reg_emit_node <prefix> <indent>
#
# Recursive. A path that exists as a leaf is emitted as a scalar; anything
# else is an object and we descend. Arrays are readable by lib/json.awk but
# this tool never writes one, so they are not handled here — registry_validate
# rejects a document containing one rather than silently dropping it.
reg_emit_node() {
  local prefix="$1" indent="$2"
  local children child first line type value
  children="$(reg_sort_children "$prefix")"

  printf '{\n'
  first=1
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    [ "$first" = "1" ] || printf ',\n'
    first=0
    printf '%s"%s": ' "$indent  " "$(json_escape "$child")"

    line="$(printf '%s\n' "$REG_DATA" | awk -F'\t' -v p="$prefix.$child" '$1 == p { print $2 "\t" $3; exit }')"
    if [ -n "$line" ]; then
      type="${line%%	*}"
      value="$(json_decode "${line#*	}")"
      reg_emit_scalar "$type" "$value"
    else
      reg_emit_node "$prefix.$child" "$indent  "
    fi
  done <<EOF
$children
EOF
  [ "$first" = "1" ] || printf '\n'
  printf '%s}' "$indent"
}

registry_serialize() {
  # The version key is synthesised rather than read, so a registry that
  # somehow lost it gets one back on the next write.
  reg_set '.version' number "$REGISTRY_VERSION"
  if ! reg_children '.profiles' | grep -q .; then
    reg_set '.profiles' object ''
  else
    reg_unset '.profiles'
  fi
  reg_emit_node '' ''
  printf '\n'
}


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
# Used by `doctor`. Prints one line per problem on stdout and returns non-zero
# if there were any, so callers can count them.

registry_validate() {
  local problems=0
  local name auth dir udd other odir oudd

  if printf '%s\n' "$REG_DATA" | grep -q '\['; then
    printf 'registry contains a JSON array, which this version does not understand\n'
    problems=$((problems + 1))
  fi

  for name in $(registry_profiles); do
    if ! profile_name_valid "$name"; then
      printf 'profile "%s": name is not valid (see the naming rules in lib/registry.sh)\n' "$name"
      problems=$((problems + 1))
    fi

    auth="$(reg_get_or ".profiles.$name.cli.auth" "")"
    case "$auth" in
      ""|config-dir|oauth-token) : ;;
      *) printf 'profile "%s": unknown auth mode "%s"\n' "$name" "$auth"
         problems=$((problems + 1)) ;;
    esac

    dir="$(reg_get_or ".profiles.$name.cli.configDir" "")"
    if [ -n "$dir" ]; then
      if [ "$(path_expand "$dir")" = "$(platform_primary_cli_config_dir)" ]; then
        printf 'profile "%s": cli.configDir is the PRIMARY config dir — that would overwrite your main account\n' "$name"
        problems=$((problems + 1))
      fi
    fi

    udd="$(reg_get_or ".profiles.$name.desktop.userDataDir" "")"
    if [ -n "$udd" ]; then
      if [ "$(path_expand "$udd")" = "$(platform_primary_desktop_user_data_dir)" ]; then
        printf 'profile "%s": desktop.userDataDir is the PRIMARY profile directory — that would overwrite your main account\n' "$name"
        problems=$((problems + 1))
      fi
    fi

    # Cross-profile collisions. Two profiles pointing at one directory is the
    # same failure as pointing at the primary, just less obvious.
    #
    # Only compare against names that sort after this one, so each colliding
    # pair is reported once rather than from both sides.
    for other in $(registry_profiles); do
      [ "$other" \> "$name" ] || continue
      odir="$(reg_get_or ".profiles.$other.cli.configDir" "")"
      oudd="$(reg_get_or ".profiles.$other.desktop.userDataDir" "")"
      if [ -n "$dir" ] && [ "$dir" = "$odir" ]; then
        printf 'profiles "%s" and "%s" share cli.configDir %s\n' "$name" "$other" "$dir"
        problems=$((problems + 1))
      fi
      if [ -n "$udd" ] && [ "$udd" = "$oudd" ]; then
        printf 'profiles "%s" and "%s" share desktop.userDataDir %s\n' "$name" "$other" "$udd"
        problems=$((problems + 1))
      fi
    done
  done

  [ "$problems" -eq 0 ]
}
