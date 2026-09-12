# OmaSpace


Omarchy shell plugin: save which apps live on which Hyprland workspace, and
restore them with a click — or automatically on login.

## Use

Click the ▦ icon in the bar (top-right by default).

- **Save current layout** — snapshots every window on every workspace right
  now under the name typed into the field.
- Each saved layout shows **Restore** (relaunches every app straight onto its
  saved workspace) and **✕** (delete, with confirmation).
- Click the **☆** star on a layout to make it restore automatically after
  login; click the filled **★** to turn that off again. This installs a
  small `post-boot` hook (via `omarchy hook install post-boot ...`, landing
  in `~/.config/omarchy/hooks/post-boot.d/`) the first time you use it.

## How it works

All of the logic lives in `window-layouts.sh`, invoked by the QML UI via
`Quickshell.execDetached`. Both problems below turned out to be widespread
enough (affecting whole classes of apps, not one-off quirks) that the fix for
each is generic — neither is a per-app special case.

- **Save.** For each window from `hyprctl clients -j`, the real "open a new
  window" command is resolved from that app's installed `.desktop` entry
  (matched by window class, falling back to `StartupWMClass=` when the class
  doesn't match the filename) — the same mechanism every app launcher/menu
  uses. This is deliberately preferred over reading the window's own
  `/proc/<pid>/cmdline`, which is used only as a fallback when no `.desktop`
  entry exists, because that can be actively misleading: some apps' packaging
  flattens their real argv into one wrapped string, and some apps (GNOME's
  GApplication-based singletons — Nautilus, Text Editor, etc.) run as a
  persistent background service, so an already-open window's cmdline is that
  service's own `--gapplication-service` invocation, not something that opens
  a window when relaunched. Windows are grouped by workspace and written to
  `~/.local/state/omarchy/window-layouts.json`.
- **Restore.** Each saved command relaunches inside a one-shot generated
  script (so its argv survives intact across the shell/Lua boundaries this
  Hyprland build's `hyprctl eval` needs — see the comment in `cmd_restore`).
  Placement onto the saved workspace is *also* handled generically: a
  temporary Hyprland window rule matches the app by class and is disabled
  again the moment its window appears (or after a few seconds either way).
  This matters because apps like the GApplication singletons above don't
  create their window from the process we just spawned at all — relaunching
  them just messages an already-running instance over D-Bus, and *that*
  process is the one that actually maps the window. A rule matched on class
  catches it regardless of which process ends up doing the mapping.
- `set-boot <name|none>` records which layout (if any) should restore after
  login, and installs a tiny `post-boot` hook that calls `restore-boot`.

## Known limitations

- A layout saved before this fix landed keeps whatever it originally
  captured — re-save it (same name) to pick up the corrected commands.
- Apps enforcing their own single-instance lock (most Electron apps,
  browsers, some GTK apps) may just focus their existing window instead of
  opening a genuinely new one when relaunched while already running. This
  only matters if the app is already open somewhere when you restore —
  actual boot-time restore (nothing running yet) isn't affected.
- If something still doesn't come back right, `~/.local/state/omarchy/window-layouts.json`
  is plain JSON — edit that entry's `"cmd"` array by hand.
