#!/bin/bash -p

# omarchy:summary=Save/restore which apps live on which workspace (jocahdj.omaspace plugin)
#
# Data model: $XDG_STATE_HOME/omarchy/omaspace/layouts.json  (dir 0700, file 0600)
#   {
#     "layouts": {
#       "<name>": { "<workspace-id>": [ { "class": "...", "title": "...", "cmd": ["..."] }, ... ] }
#     },
#     "bootLayout": "<name-or-empty>"
#   }
#
# "save" snapshots the current windows (via hyprctl + /proc/<pid>/cmdline) into
# a named layout. "restore" relaunches each saved command and, generically for
# every app (no per-app special-casing), uses a temporary class-matched
# Hyprland window rule to land its window on the right workspace -- see
# apply_temp_workspace_rule below for why that's needed instead of just an
# exec-time workspace hint.
#
# ---------------------------------------------------------------------------
# Execution / trust model
#
# * How this script is started. Bash processes $BASH_ENV, $SHELLOPTS,
#   $BASHOPTS and exported functions from the *inherited* environment before
#   line 1 of a script runs, so nothing inside this file can undo a hostile
#   environment after the fact. Both supported entry points therefore start
#   it through a fixed shell with a cleared, allowlisted environment:
#     - Panel.qml: /bin/bash --noprofile --norc -p -- window-layouts.sh ...
#       with Quickshell's clearEnvironment: true plus an explicit allowlist
#       (helperCommand / helperEnvironment there);
#     - the generated post-boot hook (boot_hook_content):
#       /usr/bin/env -i <allowlist> /bin/bash --noprofile --norc -p -- ...
#   The `-p` in the shebang is a backstop for direct invocation: privileged
#   mode makes Bash ignore BASH_ENV/ENV, SHELLOPTS, BASHOPTS, CDPATH,
#   GLOBIGNORE and inherited functions.
#
# * Where helpers come from. PATH is pinned to /usr/bin (root-owned on
#   Omarchy), so hyprctl, jq, omarchy-*, stat, mktemp, mv, ... resolve to the
#   base-OS binaries only.
#
# * State on disk (open_state_dir, load_checked_json, atomic_write).
#   - The state directory path is walked from "/" one component at a time.
#     Each component is lstat'ed (symlinks are refused, never followed),
#     opened, and the opened descriptor is fstat'ed and required to be the
#     same device/inode. Every ancestor must be owned by root or by this user
#     and not be group/other-writable; the leaf must be owned by this user
#     with mode 0700. Each step is resolved relative to the previous step's
#     open descriptor (/proc/self/fd/<fd>/<name>, i.e. openat semantics), so
#     the hierarchy is never re-walked by pathname.
#   - The leaf descriptor is kept for the whole run; every later read, write,
#     mktemp, rename and delete of state goes through it.
#   - The state file is lstat'ed before it is opened (must be a regular file,
#     so a symlink/FIFO/device is never opened), then the open descriptor is
#     fstat'ed and must be the same inode, owned by this user, single link,
#     no group/other write bit, and at most MAX_STATE_FILE_BYTES. At most that
#     many bytes are read. A file failing any check is renamed aside and
#     never parsed.
#   - Writes create a fresh 0600 temp file (O_EXCL) in the directory, verify
#     it, and rename it over the state file. The state file itself is never
#     opened for writing.
#
# * What may influence execution. Persisted state is untrusted input. After
#   the checks above it is normalised by a strict jq schema (validate_state)
#   with fixed count/length bounds, and anything that does not fit is
#   dropped. Only that validated document is used: by the panel (`list`), by
#   `restore`, and by the post-boot hook (`restore-boot`, which only restores
#   the validated bootLayout). Commands are exec'd as argv arrays; there is no
#   eval, no `sh -c`, and no stored string is re-parsed as shell.
# ---------------------------------------------------------------------------

set -uo pipefail

export PATH=/usr/bin
umask 077
unset -v BASH_ENV ENV CDPATH GLOBIGNORE 2>/dev/null || true

if [[ "${HOME:-}" != /* ]]; then
  echo "window-layouts.sh: HOME must be an absolute path" >&2
  exit 1
fi

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"

# Hard bounds on everything read from disk. These are sanity/DoS limits, not
# realistic sizes -- a legitimate state file with dozens of layouts is a few KB.
readonly MAX_STATE_FILE_BYTES=$((1024 * 1024))
readonly MAX_LAYOUTS=256
readonly MAX_NAME_LEN=128
readonly MAX_WORKSPACES=64
readonly MAX_ENTRIES_PER_WORKSPACE=128
readonly MAX_STR_LEN=1024
readonly MAX_CMD_ARGS=64
readonly MAX_ARG_LEN=4096

readonly EMPTY_STATE='{"layouts":{},"bootLayout":""}'

# Per the XDG spec, a relative XDG_STATE_HOME is invalid and ignored.
if [[ "${XDG_STATE_HOME:-}" == /* ]]; then
  STATE_HOME="$XDG_STATE_HOME"
else
  STATE_HOME="$HOME/.local/state"
fi
STATE_DIR="$STATE_HOME/omarchy/omaspace"
readonly STATE_FILE_NAME="layouts.json"
# Pre-1.2 location, in the shared parent directory; migrated once (validated).
readonly LEGACY_STATE_FILE_NAME="window-layouts.json"

readonly BOOT_HOOK_NAME="window-layouts-boot-hook.sh"
readonly BOOT_HOOK_MARKER="# Generated by OmaSpace (jocahdj.omaspace). Do not edit."
HOOK_INSTALL_DIR="$HOME/.config/omarchy/hooks/post-boot.d"

# Set by open_state_dir.
STATE_FD=""      # open descriptor on $STATE_DIR
STATE_ROOT=""    # /proc/self/fd/$STATE_FD
PARENT_FD=""     # open descriptor on $STATE_DIR/.. (only for legacy migration)

STATE_JSON="$EMPTY_STATE"
LOADED_JSON=""
REJECT_REASON=""

notify() {
  omarchy-notification-send -g "" "OmaSpace" "$1" >/dev/null 2>&1 || true
}

die() {
  notify "$1"
  echo "window-layouts.sh: $1" >&2
  exit 1
}

# Prints "<type>|<uid>|<octal mode>|<nlink>|<size>|<dev>:<inode>".
# Without -L this is lstat (a final symlink is reported, not followed); with
# -L on /proc/self/fd/N it is fstat of that open descriptor.
stat_fields() {
  stat -c '%F|%u|%a|%h|%s|%d:%i' "$@" 2>/dev/null
}

# GNU stat reports empty regular files as "regular empty file".
is_regular() {
  [[ "$1" == "regular file" || "$1" == "regular empty file" ]]
}

# True if an octal mode has no group/other write bits.
mode_is_private_enough() {
  local mode="$1"
  [[ "$mode" =~ ^[0-7]+$ ]] || return 1
  (( (8#$mode & 8#022) == 0 ))
}

# Walks $STATE_DIR from "/" descriptor-relatively (see header), creating
# missing components with mode 0700, and leaves $STATE_FD open on the leaf.
open_state_dir() {
  local -a raw_parts=() parts=()
  local part
  IFS='/' read -r -a raw_parts <<<"${STATE_DIR#/}"
  for part in "${raw_parts[@]}"; do
    [[ -n "$part" ]] || continue
    if [[ "$part" == "." || "$part" == ".." ]]; then
      die "Refusing state path containing . or ..: $STATE_DIR"
    fi
    parts+=("$part")
  done
  (( ${#parts[@]} >= 2 )) || die "Invalid state path: $STATE_DIR"

  local cur_fd next_fd
  exec {cur_fd}</ || die "Could not open /"

  local i last=$(( ${#parts[@]} - 1 )) shown="" entry
  local lfields ltype luid lmode lnlink lsize lid
  local ffields ftype fuid fmode fnlink fsize fid
  for (( i = 0; i <= last; i++ )); do
    part="${parts[i]}"
    shown+="/$part"
    entry="/proc/self/fd/$cur_fd/$part"

    if [[ ! -e "$entry" && ! -L "$entry" ]]; then
      # mkdir never follows a symlink in the final component. With umask
      # 077 new directories are 0700. This only succeeds where this user may
      # write (i.e. beneath $HOME); anywhere else the lstat below fails.
      mkdir -- "$entry" 2>/dev/null || true
    fi

    lfields="$(stat_fields -- "$entry")" || die "State path component missing: $shown"
    IFS='|' read -r ltype luid lmode lnlink lsize lid <<<"$lfields"
    [[ "$ltype" == "directory" ]] \
      || die "Refusing state path component that is not a plain directory (symlinks are not followed): $shown"

    { exec {next_fd}<"$entry"; } 2>/dev/null || die "Could not open state path component: $shown"
    ffields="$(stat_fields -L -- "/proc/self/fd/$next_fd")" || ffields=""
    IFS='|' read -r ftype fuid fmode fnlink fsize fid <<<"$ffields"
    [[ "$ftype" == "directory" && -n "$fid" && "$fid" == "$lid" ]] \
      || die "State path component changed while opening: $shown"

    if (( i == last )); then
      [[ "$fuid" == "$EUID" ]] || die "Refusing state directory not owned by you: $shown"
      if [[ "$fmode" != "700" ]]; then
        # Our own private directory: re-assert its mode on the open
        # descriptor (not by pathname), then re-verify.
        chmod 700 -- "/proc/self/fd/$next_fd" 2>/dev/null || die "Could not secure state directory: $shown"
        ffields="$(stat_fields -L -- "/proc/self/fd/$next_fd")" || ffields=""
        IFS='|' read -r ftype fuid fmode fnlink fsize fid <<<"$ffields"
        [[ "$fmode" == "700" && "$fid" == "$lid" ]] || die "Could not secure state directory: $shown"
      fi
    else
      [[ "$fuid" == "$EUID" || "$fuid" == "0" ]] \
        || die "Refusing state path component owned by another user: $shown"
      mode_is_private_enough "$fmode" \
        || die "Refusing group/other-writable state path component: $shown"
    fi

    if [[ "$cur_fd" != "$PARENT_FD" ]]; then
      exec {cur_fd}<&-
    fi
    cur_fd=$next_fd
    if (( i == last - 1 )); then
      PARENT_FD=$next_fd
    fi
  done

  STATE_FD=$cur_fd
  STATE_ROOT="/proc/self/fd/$STATE_FD"
}

# jq program (run with --slurp) that turns any input into a well-formed,
# bounded state document, dropping every part that does not fit the schema.
# Character checks use explode (code points), not regex classes, so they do
# not depend on the jq build's regex engine.
readonly VALIDATE_STATE_JQ='
  def no_ctrl: explode | all(. >= 32 and . != 127);
  def clean_chars: explode | map(select(. >= 32 and . != 127)) | implode;
  def bounded_str($n):
    type == "string" and (length > 0) and (length <= $n) and no_ctrl;
  def valid_entry:
    type == "object"
    and (.class | bounded_str($maxStr))
    and (.cmd | type == "array")
    and ((.cmd | length) > 0)
    and ((.cmd | length) <= $maxArgs)
    and (.cmd | all(type == "string" and (length <= $maxArgLen)))
    and ((.cmd[0] | length) > 0);
  def clean_title:
    if type == "string" then clean_chars | .[:$maxStr] else "" end;
  def valid_layout:
    if type != "object" then {} else
      to_entries
      | map(
          select((.key | test("^[0-9]{1,4}$")) and (.value | type == "array"))
          | .value |= (map(select(valid_entry) | {class, title: (.title | clean_title), cmd}) | .[:$maxEntries])
          | select((.value | length) > 0)
        )
      | .[:$maxWorkspaces]
      | from_entries
    end;
  (if length == 1 and (.[0] | type) == "object" then .[0] else {} end) as $doc
  | ($doc.layouts
     | if type == "object" then . else {} end
     | to_entries
     | map(select(.key | bounded_str($maxName)) | .value |= valid_layout)
     | .[:$maxLayouts]
     | from_entries) as $layouts
  | ($doc.bootLayout as $b
     | if ($b | bounded_str($maxName)) and ($layouts | has($b)) then $b else "" end) as $boot
  | {layouts: $layouts, bootLayout: $boot}
'

validate_state() {
  jq -c -s \
    --argjson maxLayouts "$MAX_LAYOUTS" \
    --argjson maxName "$MAX_NAME_LEN" \
    --argjson maxWorkspaces "$MAX_WORKSPACES" \
    --argjson maxEntries "$MAX_ENTRIES_PER_WORKSPACE" \
    --argjson maxStr "$MAX_STR_LEN" \
    --argjson maxArgs "$MAX_CMD_ARGS" \
    --argjson maxArgLen "$MAX_ARG_LEN" \
    "$VALIDATE_STATE_JQ" 2>/dev/null
}

# Loads "$1/$2" ($1 is a /proc/self/fd/N directory root) with the checks in
# the header. Sets LOADED_JSON to the validated document.
# Returns 0 = loaded, 1 = present but rejected (REJECT_REASON set), 2 = absent.
load_checked_json() {
  local root="$1" name="$2"
  local entry="$root/$name"
  LOADED_JSON=""
  REJECT_REASON=""

  local lfields ltype luid lmode lnlink lsize lid
  lfields="$(stat_fields -- "$entry")" || return 2
  IFS='|' read -r ltype luid lmode lnlink lsize lid <<<"$lfields"

  # Checked on the directory entry *before* opening, so a symlink, FIFO,
  # socket, device or directory is never opened at all.
  if ! is_regular "$ltype"; then
    REJECT_REASON="not a plain file"
    return 1
  fi
  if ! [[ "$lsize" =~ ^[0-9]+$ ]] || (( lsize > MAX_STATE_FILE_BYTES )); then
    REJECT_REASON="abnormally large"
    return 1
  fi

  local fd
  { exec {fd}<"$entry"; } 2>/dev/null || return 2

  local ffields ftype fuid fmode fnlink fsize fid
  ffields="$(stat_fields -L -- "/proc/self/fd/$fd")" || ffields=""
  IFS='|' read -r ftype fuid fmode fnlink fsize fid <<<"$ffields"

  local why=""
  if ! is_regular "$ftype" || [[ -z "$fid" || "$fid" != "$lid" ]]; then
    why="changed while opening"
  elif [[ "$fuid" != "$EUID" ]]; then
    why="not owned by you"
  elif [[ "$fnlink" != "1" ]]; then
    why="unexpected hard links"
  elif ! mode_is_private_enough "$fmode"; then
    why="unsafe permissions"
  elif ! [[ "$fsize" =~ ^[0-9]+$ ]] || (( fsize > MAX_STATE_FILE_BYTES )); then
    why="abnormally large"
  fi
  if [[ -n "$why" ]]; then
    exec {fd}<&-
    REJECT_REASON="$why"
    return 1
  fi

  LOADED_JSON="$(head -c "$MAX_STATE_FILE_BYTES" <&"$fd" | validate_state)"
  exec {fd}<&-
  if [[ -z "$LOADED_JSON" ]]; then
    REJECT_REASON="not valid JSON"
    return 1
  fi
  return 0
}

# Renames a rejected state file aside (rename never follows symlinks) so it
# is never parsed again.
quarantine_state_file() {
  local why="$1"
  mv -fT -- "$STATE_ROOT/$STATE_FILE_NAME" "$STATE_ROOT/$STATE_FILE_NAME.rejected-$(date +%s)" 2>/dev/null || true
  notify "State file was reset ($why)"
}

# Writes stdin to the state file atomically (see header).
atomic_write() {
  local tmp
  tmp="$(mktemp -- "$STATE_ROOT/.layouts.XXXXXX")" || die "Could not create temp state file"
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    die "Could not write state"
  fi

  local fields ftype fuid fmode fnlink _size _id
  fields="$(stat_fields -- "$tmp")" || fields=""
  IFS='|' read -r ftype fuid fmode fnlink _size _id <<<"$fields"
  if ! is_regular "$ftype" || [[ "$fuid" != "$EUID" || "$fnlink" != "1" || "$fmode" != "600" ]]; then
    rm -f -- "$tmp"
    die "Temp state file failed verification"
  fi

  mv -fT -- "$tmp" "$STATE_ROOT/$STATE_FILE_NAME" || { rm -f -- "$tmp"; die "Could not replace state file"; }
}

# One-time migration of the pre-1.2 state file from the shared parent
# directory. It goes through exactly the same checked, bounded, validated
# load; only the validated document is written into the protected directory.
migrate_legacy_state() {
  [[ -n "$PARENT_FD" ]] || return 0
  local current="$STATE_ROOT/$STATE_FILE_NAME"
  if [[ ! -e "$current" && ! -L "$current" ]]; then
    local legacy_root="/proc/self/fd/$PARENT_FD"
    if load_checked_json "$legacy_root" "$LEGACY_STATE_FILE_NAME"; then
      printf '%s\n' "$LOADED_JSON" | atomic_write
      rm -f -- "$legacy_root/$LEGACY_STATE_FILE_NAME"
    fi
  fi
  exec {PARENT_FD}<&-
  PARENT_FD=""
}

load_state() {
  STATE_JSON="$EMPTY_STATE"
  load_checked_json "$STATE_ROOT" "$STATE_FILE_NAME"
  case $? in
    0) STATE_JSON="$LOADED_JSON" ;;
    1) quarantine_state_file "$REJECT_REASON" ;;
    *) : ;;
  esac
}

# Applies a jq transform to the in-memory validated document and persists the
# re-validated result.
update_state() {
  local program="$1"; shift
  local next
  next="$(jq -c "$@" "$program" <<<"$STATE_JSON" | validate_state)"
  [[ -n "$next" ]] || die "Could not update state"
  STATE_JSON="$next"
  printf '%s\n' "$STATE_JSON" | atomic_write
}

# Layout names come from the UI text field / argv; bound them the same way
# the schema does so a saved name always survives validation.
validate_name() {
  local name="$1"
  [[ -n "$name" ]] || die "Layout name is empty"
  (( ${#name} <= MAX_NAME_LEN )) || die "Layout name is too long"
  if [[ "$name" == *[[:cntrl:]]* ]]; then
    die "Layout name contains control characters"
  fi
  return 0
}

b64decode() {
  printf '%s' "$1" | base64 -d 2>/dev/null
}

# Lua-escapes a string for embedding inside a single-quoted Lua string literal
# passed to `hyprctl eval`.
lua_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"
}

# Builds a `^...$`-anchored regex that matches $1 literally (escapes regex
# metacharacters), for Hyprland's class-match window rules.
regex_escape_exact() {
  local escaped
  escaped="$(printf '%s' "$1" | sed -e 's/[.^$*+?()\[\]{}|\\]/\\&/g')"
  printf '^%s$' "$escaped"
}

# Installs a one-shot, class-matched "workspace $ws silent" window rule. This
# is the generic mechanism that makes restore work for *any* app without
# knowing anything app-specific about it: some apps (GNOME's GApplication
# singletons -- Nautilus, Text Editor, and friends) don't map their window
# from the process we spawn at all. Launching them just messages an
# already-running background instance over D-Bus, and that pre-existing
# process is the one that actually creates the window -- so an exec-time
# `[workspace N silent]` hint (tied to the process we spawn) never has a
# chance to apply. A rule matched purely on window class catches the window
# regardless of which process ends up mapping it.
apply_temp_workspace_rule() {
  local class="$1" ws="$2"
  local lua_pattern
  lua_pattern="$(lua_escape "$(regex_escape_exact "$class")")"
  hyprctl eval "_G.__window_layouts_rule = hl.window_rule({ match = { class = '$lua_pattern' }, workspace = '$ws silent' })" >/dev/null 2>&1
}

# Disables the rule installed above so it doesn't linger and hijack that
# app's workspace the next time the user opens it normally.
clear_temp_workspace_rule() {
  hyprctl eval 'if _G.__window_layouts_rule then _G.__window_layouts_rule:set_enabled(false); _G.__window_layouts_rule = nil end' >/dev/null 2>&1
}

# Waits (up to ~3s) for a window of $class whose address wasn't already in
# $before (a newline-separated address list snapshotted before launching) to
# appear -- i.e. waits for *our* new window specifically, not just for any
# pre-existing window of that class to still be there.
wait_for_new_window_of_class() {
  local class="$1" before="$2"
  local i after
  for i in $(seq 1 15); do
    sleep 0.2
    after="$(hyprctl clients -j 2>/dev/null | jq -r --arg c "$class" '.[] | select(.class == $c) | .address')"
    if [[ -n "$(comm -13 <(sort <<<"$before") <(sort <<<"$after") 2>/dev/null)" ]]; then
      return 0
    fi
  done
  return 1
}

# Splits $1 into words on plain whitespace, honoring "double quoted"
# segments and backslash-escapes of `" \ $ ` ` (mirroring the Desktop Entry
# spec's Exec= quoting) -- printed as a JSON string array. This is pure
# character-by-character scanning: the input is only ever treated as data,
# never handed to a shell/`eval` to interpret, so nothing in it (`;`, `$(...)`,
# backticks, redirects, etc.) can execute anything, no matter how it got here
# (a .desktop file's Exec= line, or a flattened /proc/<pid>/cmdline value
# recovered from persisted state).
tokenize_words() {
  local line="$1"
  local -a tokens=()
  local token="" in_quotes=0 have_token=0
  local i=0 len=${#line} char next
  while (( i < len )); do
    char="${line:i:1}"
    if (( in_quotes )); then
      if [[ "$char" == '"' ]]; then
        in_quotes=0
      elif [[ "$char" == '\' ]] && (( i + 1 < len )); then
        next="${line:i+1:1}"
        if [[ "$next" == '"' || "$next" == '\' || "$next" == '$' || "$next" == '`' ]]; then
          token+="$next"
          i=$((i + 1))
        else
          token+="$char"
        fi
      else
        token+="$char"
      fi
      have_token=1
    else
      if [[ "$char" == ' ' || "$char" == $'\t' ]]; then
        if (( have_token )); then
          tokens+=("$token")
          token=""
          have_token=0
        fi
      elif [[ "$char" == '"' ]]; then
        in_quotes=1
        have_token=1
      else
        token+="$char"
        have_token=1
      fi
    fi
    i=$((i + 1))
  done
  (( have_token )) && tokens+=("$token")

  (( ${#tokens[@]} > 0 && ${#tokens[@]} <= MAX_CMD_ARGS )) || return 1
  for token in "${tokens[@]}"; do
    (( ${#token} <= MAX_ARG_LEN )) || return 1
  done

  printf '%s\0' "${tokens[@]}" | jq -R -s -c 'split(" ")[:-1]'
}

# Writes a one-shot launcher script with $cmd_json's argv baked in via jq's
# @sh quoting (see cmd_restore for why this crosses the Lua/shell boundary).
# $cmd_json comes from the validated document.
build_launcher() {
  local launcher="$1" cmd_json="$2"
  local count first
  count="$(jq 'length' <<<"$cmd_json")" || return 1
  first="$(jq -r '.[0]' <<<"$cmd_json")" || return 1

  if [[ "$count" == "1" && "$first" == *' '* ]]; then
    # A single argv element containing spaces is a strong signal the real
    # command line got flattened into one string somewhere upstream (seen
    # with some Electron apps' /proc/<pid>/cmdline) rather than kept as real
    # argv -- exec'ing it literally would try to run a file whose name is
    # that whole string. Recovering the intended words with a plain,
    # non-executing tokenizer (rather than `sh -c`) means nothing in a
    # stored value -- however it got there -- is ever interpreted as shell
    # syntax.
    local recovered
    recovered="$(tokenize_words "$first")" || return 1
    cmd_json="$recovered"
  fi

  jq -r '"#!/bin/bash -p\nexec -- " + (map(@sh) | join(" "))' <<<"$cmd_json" >"$launcher" || return 1
  chmod 700 -- "$launcher"
}

# Resolves a window class to its installed .desktop entry's Exec= command,
# printed as a JSON argv array (or nothing, with a non-zero exit, if no
# matching entry is found). This is the generic, app-agnostic answer to
# "what's the real command to open a new window of this app" -- the same
# mechanism every application launcher/menu uses -- which is why it's tried
# before falling back to whatever /proc/<pid>/cmdline happens to report. That
# fallback can be misleading in two ways this sidesteps entirely: some
# packaging wraps an app so its cmdline is one flattened string instead of
# real argv (some Electron apps), and some apps are backed by a persistent
# D-Bus-activated singleton process whose cmdline reflects a background
# "--gapplication-service" invocation rather than "open a window" (Nautilus,
# GNOME Text Editor, and other GApplication-based apps).
desktop_launch_cmd() {
  local class="$1"
  [[ -n "$class" ]] || return 1
  local dirs=(
    "$HOME/.local/share/applications"
    "/usr/local/share/applications"
    "/usr/share/applications"
    "$HOME/.local/share/flatpak/exports/share/applications"
    "/var/lib/flatpak/exports/share/applications"
  )

  local file="" d
  # A class containing "/" is never used to build a path.
  if [[ "$class" != */* ]]; then
    for d in "${dirs[@]}"; do
      [[ -f "$d/$class.desktop" ]] || continue
      file="$d/$class.desktop"
      break
    done
  fi

  if [[ -z "$file" ]]; then
    # Not every app's window class matches its .desktop filename (Obsidian's
    # window class is "md.obsidian.Obsidian" but the file is
    # obsidian.desktop) -- StartupWMClass is the field that maps the two.
    for d in "${dirs[@]}"; do
      [[ -d "$d" ]] || continue
      local candidate
      candidate="$(grep -rlxF -- "StartupWMClass=$class" "$d" 2>/dev/null | head -1)"
      [[ -n "$candidate" ]] || continue
      file="$candidate"
      break
    done
  fi

  [[ -n "$file" ]] || return 1

  local exec_line
  exec_line="$(sed -n 's/^Exec=//p' "$file" | head -1)"
  [[ -n "$exec_line" ]] || return 1

  # Strip desktop-entry field codes (%f %F %u %U %i %c %k, literal %% -> %)
  # per the Desktop Entry spec.
  exec_line="$(sed -E 's/%[fFuUick]//g; s/%%/%/g' <<<"$exec_line")"

  # Tokenize per the Desktop Entry spec's quoting rules, without ever
  # handing this file's contents to `eval`/a shell to interpret -- see
  # tokenize_words.
  tokenize_words "$exec_line"
}

cmd_save() {
  local name="${1:?Usage: window-layouts.sh save <name>}"
  validate_name "$name"

  local entries
  entries="$(mktemp -- "$STATE_ROOT/.entries.XXXXXX")" || die "Could not create temp file"
  trap 'rm -f -- "$entries"' RETURN

  # class/title are base64-encoded in the TSV so tabs, newlines and
  # backslashes in them survive intact.
  local ws class_b64 title_b64 pid class title
  while IFS=$'\t' read -r ws class_b64 title_b64 pid; do
    class="$(b64decode "$class_b64")"
    title="$(b64decode "$title_b64")"
    [[ -n "$class" ]] || continue

    local cmd_json=""
    cmd_json="$(desktop_launch_cmd "$class")" || cmd_json=""

    if [[ -z "$cmd_json" ]]; then
      # No installed .desktop entry for this class -- fall back to whatever
      # this window's own process was actually invoked with.
      [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || continue
      local argv=()
      mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null
      [[ ${#argv[@]} -gt 0 ]] || continue
      # Args are piped in as NUL-separated stdin rather than jq CLI args,
      # since an argv entry that looks like a flag (e.g. "--app-id=...")
      # would otherwise be parsed by jq itself instead of treated as a string.
      cmd_json="$(printf '%s\0' "${argv[@]}" | jq -R -s -c 'split(" ")[:-1]')"
    fi

    jq -n -c --arg ws "$ws" --arg class "$class" --arg title "$title" --argjson cmd "$cmd_json" \
      '{ws:$ws, class:$class, title:$title, cmd:$cmd}' >>"$entries"
  done < <(hyprctl clients -j | jq -r '.[] | select(.mapped == true and .workspace.id >= 1) | [(.workspace.id|tostring), ((.class // "")|@base64), ((.title // "")|@base64), (.pid|tostring)] | @tsv')

  local ws_map
  if [[ -s "$entries" ]]; then
    ws_map="$(jq -s -c 'group_by(.ws) | map({(.[0].ws): map({class,title,cmd})}) | add // {}' "$entries")"
  else
    ws_map="{}"
  fi

  update_state '.layouts[$name] = $ws' --arg name "$name" --argjson ws "$ws_map"

  local count ws_count
  count="$(jq -r --arg name "$name" '[.layouts[$name][]?[]] | length' <<<"$STATE_JSON")"
  ws_count="$(jq -r --arg name "$name" '.layouts[$name] // {} | length' <<<"$STATE_JSON")"
  notify "Saved '$name' ($count windows across $ws_count workspaces)"
}

cmd_restore() {
  local name="${1:?Usage: window-layouts.sh restore <name>}"
  validate_name "$name"

  # $STATE_JSON is the validated document (load_state / validate_state):
  # workspace keys are 1-4 digit integers (they are interpolated into a Lua
  # string below), and every entry is a well-shaped {class, title, cmd:
  # [string, ...]} within fixed bounds. Nothing else exists in it.
  local ws_map
  ws_map="$(jq -c --arg name "$name" '.layouts[$name] // empty' <<<"$STATE_JSON")"
  if [[ -z "$ws_map" ]]; then
    notify "Layout '$name' not found"
    exit 1
  fi

  # This Hyprland build routes `hyprctl dispatch exec ...` through a Lua
  # evaluator that reconstructs the CLI args as raw (unquoted) Lua source, so
  # anything with spaces or "--" breaks. `hyprctl eval "hl.exec_cmd('...')"`
  # is the reliable path, but that means our own payload has to survive both
  # Lua-string escaping *and* a shell parse. Rather than double-escape
  # arbitrary argv (titles, flags, paths) through both layers, each entry
  # gets its own tiny one-shot launcher script with argv baked in via normal
  # shell quoting, and only that script's plain path crosses the Lua/shell
  # boundary.
  #
  # The launcher directory is created (mkdtemp, 0700) through the verified
  # state directory descriptor. Hyprland is a separate process, so it is
  # handed the equivalent real pathname inside that verified directory.
  local launcher_dir launcher_dir_real
  launcher_dir="$(mktemp -d -- "$STATE_ROOT/launch.XXXXXX")" || die "Could not create launcher directory"
  launcher_dir_real="$STATE_DIR/${launcher_dir##*/}"

  # Snapshot how many windows of each class already exist *before* touching
  # anything, so an app that's already open isn't relaunched as a duplicate.
  # This is consumed as a budget below: the Nth already-open window of a
  # class satisfies the Nth entry asking for that class, so a layout with
  # two "foot" entries on different workspaces still opens a second one once
  # the one already-open foot has been credited to the first. Keys are the
  # base64 class so any class string is a safe associative-array key.
  local -A already_open=()
  local cls_b64 cnt
  while IFS=$'\t' read -r cls_b64 cnt; do
    [[ -n "$cls_b64" && "$cnt" =~ ^[0-9]+$ ]] || continue
    already_open["$cls_b64"]=$cnt
  done < <(hyprctl clients -j 2>/dev/null | jq -r 'map(select(.mapped == true) | (.class // "")) | group_by(.) | .[] | [(.[0]|@base64), (length|tostring)] | @tsv')

  local launched=0 skipped=0
  local ws class_b64 cmd_b64 class cmd_json
  while IFS=$'\t' read -r ws class_b64 cmd_b64; do
    [[ "$ws" =~ ^[0-9]{1,4}$ ]] || continue
    class="$(b64decode "$class_b64")"
    cmd_json="$(b64decode "$cmd_b64")"
    [[ -n "$class" && -n "$cmd_json" ]] || continue

    if [[ "${already_open[$class_b64]:-0}" -gt 0 ]]; then
      already_open["$class_b64"]=$(( already_open[$class_b64] - 1 ))
      skipped=$((skipped + 1))
      continue
    fi

    local n=$((launched + 1))
    build_launcher "$launcher_dir/$n.sh" "$cmd_json" || continue
    launched=$n

    local launcher_real
    launcher_real="$(lua_escape "$(printf '%q' "$launcher_dir_real/$n.sh")")"

    local before
    before="$(hyprctl clients -j 2>/dev/null | jq -r --arg c "$class" '.[] | select(.class == $c) | .address')"

    apply_temp_workspace_rule "$class" "$ws"
    hyprctl eval "hl.exec_cmd('[workspace $ws silent] $launcher_real')" >/dev/null 2>&1
    wait_for_new_window_of_class "$class" "$before"
    clear_temp_workspace_rule
  done < <(jq -r 'to_entries[] as $e | $e.value[] | [$e.key, (.class|@base64), (.cmd|@json|@base64)] | @tsv' <<<"$ws_map")

  # Give Hyprland a few seconds to spawn every launcher before removing them.
  # The background subshell inherits the state directory descriptor, so the
  # removal also goes through it rather than the pathname.
  (sleep 10 && rm -rf -- "$launcher_dir") >/dev/null 2>&1 &
  disown

  if [[ "$skipped" -gt 0 ]]; then
    notify "Restored '$name' ($launched opened, $skipped already open)"
  else
    notify "Restored '$name' ($launched windows)"
  fi
}

cmd_delete() {
  local name="${1:?Usage: window-layouts.sh delete <name>}"
  validate_name "$name"
  update_state '
    del(.layouts[$name])
    | if .bootLayout == $name then .bootLayout = "" else . end
  ' --arg name "$name"
  if [[ "$(jq -r '.bootLayout' <<<"$STATE_JSON")" == "" ]]; then
    remove_boot_hook
  fi
  notify "Deleted '$name'"
}

# The post-boot hook. Omarchy copies it into ~/.config/omarchy/hooks/post-boot.d/
# and runs it as `bash <hook>` in the hook runner's environment. The hook's
# only job is to re-exec the helper through a fixed shell with a cleared,
# allowlisted environment -- the same way Panel.qml starts it -- so the
# restore-boot path (validated protected state -> generated launchers) never
# runs with anything inherited. It takes no input other than the helper path
# fixed at install time.
boot_hook_content() {
  local script_q
  script_q="$(printf '%q' "$SCRIPT_PATH")"
  cat <<HOOK
#!/bin/bash -p
$BOOT_HOOK_MARKER
# Restores the OmaSpace boot layout, if one is set, by starting the plugin
# helper with a fixed shell and a cleared, allowlisted environment.
script=$script_q
[[ -f "\$script" && ! -L "\$script" ]] || exit 0
owner="\$(/usr/bin/stat -c %u -- "\$script" 2>/dev/null)" || exit 0
[[ "\$owner" == "\$EUID" || "\$owner" == "0" ]] || exit 0
env_allow=(PATH=/usr/bin LC_ALL=C.UTF-8)
for v in HOME XDG_STATE_HOME XDG_RUNTIME_DIR HYPRLAND_INSTANCE_SIGNATURE DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY; do
  if [[ -n "\${!v:-}" ]]; then env_allow+=("\$v=\${!v}"); fi
done
exec /usr/bin/env -i "\${env_allow[@]}" /bin/bash --noprofile --norc -p -- "\$script" restore-boot
HOOK
}

ensure_boot_hook_installed() {
  local tmp
  tmp="$(mktemp -- "$STATE_ROOT/.hook.XXXXXX")" || die "Could not create boot hook"
  if ! boot_hook_content >"$tmp"; then
    rm -f -- "$tmp"
    die "Could not write boot hook"
  fi
  chmod 700 -- "$tmp"
  mv -fT -- "$tmp" "$STATE_ROOT/$BOOT_HOOK_NAME" || { rm -f -- "$tmp"; die "Could not stage boot hook"; }
  # `omarchy hook install` copies the file into the hooks directory by its
  # basename. It is a separate program, so it gets the real path inside the
  # verified directory.
  omarchy hook install post-boot "$STATE_DIR/$BOOT_HOOK_NAME" >/dev/null 2>&1 \
    || die "Could not register post-boot hook with Omarchy"
}

# Removes the installed hook once nothing restores on boot, but only if it is
# a plain file carrying this plugin's marker (never someone else's file that
# happens to share the name).
remove_boot_hook() {
  local installed="$HOOK_INSTALL_DIR/$BOOT_HOOK_NAME"
  if [[ -f "$installed" && ! -L "$installed" && -O "$installed" ]] \
    && head -n 2 -- "$installed" 2>/dev/null | grep -qxF -- "$BOOT_HOOK_MARKER"; then
    rm -f -- "$installed"
  fi
  rm -f -- "$STATE_ROOT/$BOOT_HOOK_NAME"
}

cmd_set_boot() {
  local name="${1:-}"
  if [[ -z "$name" || "$name" == "none" ]]; then
    update_state '.bootLayout = ""'
    remove_boot_hook
    notify "Boot layout cleared"
    return 0
  fi
  validate_name "$name"

  if ! jq -e --arg n "$name" '.layouts | has($n)' <<<"$STATE_JSON" >/dev/null; then
    notify "Layout '$name' not found"
    exit 1
  fi

  update_state '.bootLayout = $n' --arg n "$name"
  ensure_boot_hook_installed
  notify "'$name' will restore on next login"
}

cmd_restore_boot() {
  # Uses only the validated document loaded from the protected directory;
  # validate_state guarantees bootLayout is empty or names an existing,
  # well-formed layout.
  local name
  name="$(jq -r '.bootLayout' <<<"$STATE_JSON")"
  [[ -n "$name" ]] || exit 0
  cmd_restore "$name"
}

# Prints the validated document for the panel, without command lines (the
# panel only shows names, classes and titles). Panel.qml never opens the
# state file itself, so the checks and bounds above apply to the UI too.
cmd_list() {
  jq -c '.layouts |= map_values(map_values(map({class, title})))' <<<"$STATE_JSON"
}

open_state_dir
migrate_legacy_state
load_state

case "${1:-}" in
  save) shift; cmd_save "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  delete) shift; cmd_delete "$@" ;;
  set-boot) shift; cmd_set_boot "$@" ;;
  restore-boot) shift; cmd_restore_boot "$@" ;;
  list) shift; cmd_list ;;
  *)
    echo "Usage: $(basename -- "$0") {save|restore|delete|set-boot|restore-boot|list} [name]" >&2
    exit 1
    ;;
esac
