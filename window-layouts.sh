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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
STATE_FILE="$STATE_DIR/window-layouts.json"

mkdir -p "$STATE_DIR"

ensure_state_file() {
  [[ -s "$STATE_FILE" ]] || printf '{"layouts":{},"bootLayout":""}' >"$STATE_FILE"
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

# Writes a one-shot launcher script with $cmd_json's argv baked in via normal
# bash quoting (see cmd_restore's header comment for why this crosses the
# Lua/shell boundary instead of the raw command).
build_launcher() {
  local launcher="$1" cmd_json="$2"
  local count first
  count="$(jq 'length' <<<"$cmd_json")"
  first="$(jq -r '.[0]' <<<"$cmd_json")"
  {
    printf '#!/bin/bash\n'
    if [[ "$count" -eq 1 && "$first" == *' '* ]]; then
      # A single argv element containing spaces is a strong signal the real
      # command line got flattened into one string somewhere upstream (seen
      # with some Electron apps' /proc/<pid>/cmdline) rather than kept as
      # real argv — exec'ing it literally would try to run a file whose name
      # is that whole string. Handing it to a shell instead recovers the
      # intended words generically, with no per-app special-casing.
      printf 'exec sh -c %s\n' "$(jq -r '.[0] | @sh' <<<"$cmd_json")"
    else
      printf 'exec'
      while IFS= read -r quoted_arg; do printf ' %s' "$quoted_arg"; done \
        < <(jq -r '.[] | @sh' <<<"$cmd_json")
      printf '\n'
    fi
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

  # Tokenize the same way a shell would, since Exec= may quote arguments.
  local argv=()
  eval "argv=($exec_line)" 2>/dev/null || return 1
  [[ ${#argv[@]} -gt 0 ]] || return 1

  printf '%s\0' "${argv[@]}" | jq -R -s -c 'split("\u0000")[:-1]'
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

  local ws_map
  ws_map="$(jq -c --arg name "$name" '.layouts[$name] // empty' "$STATE_FILE")"
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

  local launched=0
  while IFS=$'\t' read -r ws class cmd_json; do
    [[ -n "$cmd_json" ]] || continue
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

  notify "Restored '$name' ($launched windows)"
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
