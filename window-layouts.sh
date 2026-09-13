#!/bin/bash

# omarchy:summary=Save/restore which apps live on which workspace (jocahdj.window-layouts plugin)
#
# Data model: ~/.local/state/omarchy/window-layouts.json
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
# Hyprland window rule to land its window on the right workspace — see
# apply_temp_workspace_rule below for why that's needed instead of just an
# exec-time workspace hint.

set -uo pipefail

# Every helper this script shells out to (hyprctl, jq, omarchy, sed, mktemp,
# ...) is a standard part of the base OS install and lives under /usr/bin on
# Omarchy. Pinning PATH here means all of them resolve to that known,
# root-owned location regardless of what PATH looked like in the calling
# environment (e.g. the Quickshell process, a hook runner, or a user shell),
# rather than trusting whatever earlier-in-PATH entry happens to exist.
export PATH=/usr/bin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
STATE_FILE="$STATE_DIR/window-layouts.json"

# A hard ceiling on the state file's size, checked before it's ever parsed.
# This is a sanity/DoS bound, not a realistic layout size -- a legitimate
# file with dozens of layouts and windows is a few KB.
readonly MAX_STATE_FILE_BYTES=$((2 * 1024 * 1024))
readonly MAX_CMD_ARGS=64
readonly MAX_ARG_LEN=4096

mkdir -p "$STATE_DIR"

ensure_state_file() {
  if [[ ! -s "$STATE_FILE" ]]; then
    printf '{"layouts":{},"bootLayout":""}' >"$STATE_FILE"
    return
  fi

  # A state file this large is not a realistic layout collection -- treat it
  # as corrupted/tampered rather than ever parsing it, and start fresh.
  local size
  size="$(stat -c%s "$STATE_FILE" 2>/dev/null || echo 0)"
  if (( size > MAX_STATE_FILE_BYTES )); then
    mv "$STATE_FILE" "$STATE_FILE.rejected-$(date +%s)" 2>/dev/null || true
    printf '{"layouts":{},"bootLayout":""}' >"$STATE_FILE"
    notify "State file was abnormally large and has been reset"
  fi
}

notify() {
  omarchy-notification-send -g "" "OmaSpace" "$1" >/dev/null 2>&1 || true
}

atomic_write() {
  # Writes stdin to $STATE_FILE atomically.
  local tmp
  tmp="$(mktemp "$STATE_DIR/.window-layouts.XXXXXX")"
  cat >"$tmp"
  mv "$tmp" "$STATE_FILE"
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
# singletons — Nautilus, Text Editor, and friends) don't map their window from
# the process we spawn at all. Launching them just messages an
# already-running background instance over D-Bus, and that pre-existing
# process is the one that actually creates the window — so an exec-time
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
# appear — i.e. waits for *our* new window specifically, not just for any
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
# spec's Exec= quoting) — printed as a JSON string array. This is pure
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

  (( ${#tokens[@]} <= MAX_CMD_ARGS )) || return 1
  for token in "${tokens[@]:-}"; do
    (( ${#token} <= MAX_ARG_LEN )) || return 1
  done

  printf '%s\0' "${tokens[@]}" | jq -R -s -c 'split("\u0000")[:-1]'
}

# Writes a one-shot launcher script with $cmd_json's argv baked in via normal
# bash quoting (see cmd_restore's header comment for why this crosses the
# Lua/shell boundary instead of the raw command).
build_launcher() {
  local launcher="$1" cmd_json="$2"
  local count first
  count="$(jq 'length' <<<"$cmd_json")"
  first="$(jq -r '.[0]' <<<"$cmd_json")"

  if [[ "$count" -eq 1 && "$first" == *' '* ]]; then
    # A single argv element containing spaces is a strong signal the real
    # command line got flattened into one string somewhere upstream (seen
    # with some Electron apps' /proc/<pid>/cmdline) rather than kept as real
    # argv — exec'ing it literally would try to run a file whose name is
    # that whole string. Recovering the intended words with a plain,
    # non-executing tokenizer (rather than `sh -c`) means nothing in a
    # stored value — however it got there — is ever interpreted as shell
    # syntax.
    local recovered
    recovered="$(tokenize_words "$first")" || return 1
    cmd_json="$recovered"
  fi

  {
    printf '#!/bin/bash\n'
    printf 'exec'
    while IFS= read -r quoted_arg; do printf ' %s' "$quoted_arg"; done \
      < <(jq -r '.[] | @sh' <<<"$cmd_json")
    printf '\n'
  } >"$launcher"
  chmod +x "$launcher"
}

# Resolves a window class to its installed .desktop entry's Exec= command,
# printed as a JSON argv array (or nothing, with a non-zero exit, if no
# matching entry is found). This is the generic, app-agnostic answer to
# "what's the real command to open a new window of this app" — the same
# mechanism every application launcher/menu uses — which is why it's tried
# before falling back to whatever /proc/<pid>/cmdline happens to report. That
# fallback can be misleading in two ways this sidesteps entirely: some
# packaging wraps an app so its cmdline is one flattened string instead of
# real argv (some Electron apps), and some apps are backed by a persistent
# D-Bus-activated singleton process whose cmdline reflects a background
# "--gapplication-service" invocation rather than "open a window" (Nautilus,
# GNOME Text Editor, and other GApplication-based apps).
desktop_launch_cmd() {
  local class="$1"
  local dirs=(
    "$HOME/.local/share/applications"
    "/usr/local/share/applications"
    "/usr/share/applications"
    "$HOME/.local/share/flatpak/exports/share/applications"
    "/var/lib/flatpak/exports/share/applications"
  )

  local file="" d
  for d in "${dirs[@]}"; do
    [[ -f "$d/$class.desktop" ]] || continue
    file="$d/$class.desktop"
    break
  done

  if [[ -z "$file" ]]; then
    # Not every app's window class matches its .desktop filename (Obsidian's
    # window class is "md.obsidian.Obsidian" but the file is
    # obsidian.desktop) — StartupWMClass is the field that maps the two.
    for d in "${dirs[@]}"; do
      [[ -d "$d" ]] || continue
      local candidate
      candidate="$(grep -rlxF "StartupWMClass=$class" "$d" 2>/dev/null | head -1)"
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
  ensure_state_file

  local entries
  entries="$(mktemp "$STATE_DIR/.window-layouts-entries.XXXXXX")"
  trap 'rm -f "$entries"' RETURN

  while IFS=$'\t' read -r ws class title pid; do
    local cmd_json=""
    cmd_json="$(desktop_launch_cmd "$class")" || cmd_json=""

    if [[ -z "$cmd_json" ]]; then
      # No installed .desktop entry for this class -- fall back to whatever
      # this window's own process was actually invoked with.
      [[ -n "$pid" && -r "/proc/$pid/cmdline" ]] || continue
      local argv=()
      mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null
      [[ ${#argv[@]} -gt 0 ]] || continue
      # Args are piped in as NUL-separated stdin rather than jq CLI args,
      # since an argv entry that looks like a flag (e.g. "--app-id=...")
      # would otherwise be parsed by jq itself instead of treated as a string.
      cmd_json="$(printf '%s\0' "${argv[@]}" | jq -R -s -c 'split("\u0000")[:-1]')"
    fi

    jq -n -c --arg ws "$ws" --arg class "$class" --arg title "$title" --argjson cmd "$cmd_json" \
      '{ws:$ws, class:$class, title:$title, cmd:$cmd}' >>"$entries"
  done < <(hyprctl clients -j | jq -r '.[] | select(.mapped == true and .workspace.id >= 1) | [(.workspace.id|tostring), .class, .title, (.pid|tostring)] | @tsv')

  local ws_map
  if [[ -s "$entries" ]]; then
    ws_map="$(jq -s -c 'group_by(.ws) | map({(.[0].ws): map({class,title,cmd})}) | add // {}' "$entries")"
  else
    ws_map="{}"
  fi

  jq -c --arg name "$name" --argjson ws "$ws_map" '.layouts[$name] = $ws' "$STATE_FILE" | atomic_write

  local count
  count="$(jq -n --argjson ws "$ws_map" '[$ws[]] | add | length // 0')"
  notify "Saved '$name' ($count windows across $(jq -n --argjson ws "$ws_map" '$ws | length') workspaces)"
}

cmd_restore() {
  local name="${1:?Usage: window-layouts.sh restore <name>}"
  ensure_state_file

  # Persisted state is treated as untrusted input, not as pre-validated
  # command data, before any of it is allowed to influence what gets
  # executed: the workspace key must look like a plain small integer (it's
  # interpolated into a Lua string for the window rule/exec call below), and
  # each entry must be a well-shaped {class: string, title: string, cmd:
  # [string, ...]} within the same size bounds tokenize_words enforces.
  # Anything that doesn't match this shape is dropped rather than used.
  local ws_map
  ws_map="$(jq -c \
    --arg name "$name" \
    --argjson maxArgs "$MAX_CMD_ARGS" \
    --argjson maxLen "$MAX_ARG_LEN" \
    '
      (.layouts[$name] // empty) as $raw
      | if ($raw | type) != "object" then empty else
          $raw
          | with_entries(
              select(.key | test("^[0-9]{1,4}$"))
              | .value |= (
                  if type != "array" then [] else
                    map(
                      select(
                        (type == "object")
                        and ((.class // "") | type == "string")
                        and ((.title // "") | type == "string")
                        and (.cmd | type == "array")
                        and ((.cmd | length) > 0)
                        and ((.cmd | length) <= $maxArgs)
                        and (.cmd | all(type == "string" and (length <= $maxLen)))
                      )
                    )
                  end
                )
              | select(.value | length > 0)
            )
        end
    ' "$STATE_FILE")"
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
  # bash quoting, and only that script's plain temp path crosses the
  # Lua/shell boundary.
  local launcher_dir
  launcher_dir="$(mktemp -d "$STATE_DIR/.window-layouts-launch.XXXXXX")"

  # Snapshot how many windows of each class already exist *before* touching
  # anything, so an app that's already open isn't relaunched as a duplicate.
  # This is consumed as a budget below: the Nth already-open window of a
  # class satisfies the Nth entry asking for that class, so a layout with
  # two "foot" entries on different workspaces still opens a second one once
  # the one already-open foot has been credited to the first.
  local -A already_open
  while IFS=$'\t' read -r cls cnt; do
    [[ -n "$cls" ]] || continue
    already_open["$cls"]=$cnt
  done < <(hyprctl clients -j 2>/dev/null | jq -r '.[] | select(.mapped == true) | .class' | sort | uniq -c | awk '{$1=$1; print $2"\t"$1}')

  local launched=0 skipped=0
  while IFS=$'\t' read -r ws class cmd_json; do
    [[ -n "$cmd_json" ]] || continue

    if [[ "${already_open[$class]:-0}" -gt 0 ]]; then
      already_open["$class"]=$(( already_open[$class] - 1 ))
      skipped=$((skipped + 1))
      continue
    fi

    launched=$((launched + 1))

    local launcher="$launcher_dir/$launched.sh"
    build_launcher "$launcher" "$cmd_json"

    local before
    before="$(hyprctl clients -j 2>/dev/null | jq -r --arg c "$class" '.[] | select(.class == $c) | .address')"

    apply_temp_workspace_rule "$class" "$ws"
    hyprctl eval "hl.exec_cmd('[workspace $ws silent] $launcher')" >/dev/null 2>&1
    wait_for_new_window_of_class "$class" "$before"
    clear_temp_workspace_rule
  done < <(jq -r 'to_entries[] as $e | $e.value[] | [$e.key, .class, (.cmd | @json)] | @tsv' <<<"$ws_map")

  # Give Hyprland a few seconds to spawn every launcher before removing them.
  (sleep 10 && rm -rf "$launcher_dir") >/dev/null 2>&1 &
  disown

  if [[ "$skipped" -gt 0 ]]; then
    notify "Restored '$name' ($launched opened, $skipped already open)"
  else
    notify "Restored '$name' ($launched windows)"
  fi
}

cmd_delete() {
  local name="${1:?Usage: window-layouts.sh delete <name>}"
  ensure_state_file
  jq -c --arg name "$name" '
    del(.layouts[$name])
    | if .bootLayout == $name then .bootLayout = "" else . end
  ' "$STATE_FILE" | atomic_write
  notify "Deleted '$name'"
}

ensure_boot_hook_installed() {
  local shim="$STATE_DIR/window-layouts-boot-hook.sh"
  printf '#!/bin/bash\nexec "%s" restore-boot\n' "$SCRIPT_DIR/window-layouts.sh" >"$shim"
  chmod +x "$shim"
  omarchy hook install post-boot "$shim" >/dev/null 2>&1
}

cmd_set_boot() {
  local name="${1:-}"
  ensure_state_file
  if [[ -z "$name" || "$name" == "none" ]]; then
    jq -c '.bootLayout = ""' "$STATE_FILE" | atomic_write
    notify "Boot layout cleared"
    return 0
  fi

  if ! jq -e --arg n "$name" '.layouts | has($n)' "$STATE_FILE" >/dev/null; then
    notify "Layout '$name' not found"
    exit 1
  fi

  jq -c --arg n "$name" '.bootLayout = $n' "$STATE_FILE" | atomic_write
  ensure_boot_hook_installed
  notify "'$name' will restore on next login"
}

cmd_restore_boot() {
  ensure_state_file
  local name
  name="$(jq -r '.bootLayout // ""' "$STATE_FILE")"
  [[ -n "$name" ]] || exit 0
  cmd_restore "$name"
}

case "${1:-}" in
  save) shift; cmd_save "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  delete) shift; cmd_delete "$@" ;;
  set-boot) shift; cmd_set_boot "$@" ;;
  restore-boot) shift; cmd_restore_boot "$@" ;;
  *)
    echo "Usage: $(basename "$0") {save|restore|delete|set-boot|restore-boot} [name]" >&2
    exit 1
    ;;
esac
