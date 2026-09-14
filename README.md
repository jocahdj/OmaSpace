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
  login; click the filled **★** to turn that off again. Turning it on
  installs a small `post-boot` hook (via `omarchy hook install post-boot ...`,
  landing in `~/.config/omarchy/hooks/post-boot.d/window-layouts-boot-hook.sh`);
  turning it off again removes that hook.

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
  `~/.local/state/omarchy/omaspace/layouts.json`.
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

## Security model

The helper only ever runs commands it can reconstruct as an argv array. There
is no `eval`, no `sh -c`, and nothing read from disk is re-parsed as shell.
Beyond that:

- **Fixed shell, cleared environment.** The panel starts the helper as
  `/bin/bash --noprofile --norc -p -- window-layouts.sh ...` with the process
  environment cleared and only an allowlist passed through: `PATH` pinned to
  `/usr/bin`, `LC_ALL`, `HOME`, `XDG_STATE_HOME`, `XDG_RUNTIME_DIR`,
  `HYPRLAND_INSTANCE_SIGNATURE`, `DBUS_SESSION_BUS_ADDRESS` and
  `WAYLAND_DISPLAY`. The generated boot hook re-execs the helper the same way
  through `/usr/bin/env -i`. The script's `#!/bin/bash -p` shebang makes Bash
  ignore `BASH_ENV`, `SHELLOPTS` and inherited functions if it is ever run
  directly.
- **Descriptor-relative state hierarchy.** State lives in
  `~/.local/state/omarchy/omaspace/`. The helper walks that path from `/` one
  component at a time through open directory descriptors
  (`/proc/self/fd/N/<name>`, i.e. `openat`-style). Every component is
  `lstat`ed first, so symlinks are refused rather than followed, then opened
  and `fstat`ed to confirm it is the same inode. Ancestors must be owned by
  root or by you and not be group/other-writable. The `omaspace` directory
  must be owned by you with mode `0700`. Every later read, write, temp file,
  rename and delete goes through the open descriptor.
- **Checked, bounded reads.** The state file is `lstat`ed before it is
  opened, so a symlink, FIFO or device is never opened. The open descriptor
  must then be the same inode, a regular file owned by you, with one link, no
  group/other write bit and at most 1 MiB. At most 1 MiB is read. A file that
  fails any check is renamed to `layouts.json.rejected-<timestamp>` and never
  parsed.
- **Strict schema.** Whatever is parsed is normalised by a fixed jq schema with
  hard limits on layout count and name length, workspace keys, entries per
  workspace, string lengths, and argv count and length. Anything that does not
  fit is dropped. Only this validated document is used by the panel, by
  `restore`, and by the boot hook's `restore-boot`.
- **Atomic writes.** Changes go to a fresh `0600` temp file in the same
  directory, which is verified and then renamed over the state file. The state
  file is never opened for writing.
- **No direct state access from QML.** The panel never opens or watches the
  state file. It runs `window-layouts.sh list` under the same fixed shell and
  environment, and parses at most 2 MiB of its output.
- **Boot hook.** Turning off "restore on login", or deleting the boot layout,
  removes the installed hook again. Only a plain file carrying this plugin's
  marker line is removed.

## Known limitations

- A layout saved before this fix landed keeps whatever it originally
  captured — re-save it (same name) to pick up the corrected commands.
- Apps enforcing their own single-instance lock (most Electron apps,
  browsers, some GTK apps) may just focus their existing window instead of
  opening a genuinely new one when relaunched while already running. This
  only matters if the app is already open somewhere when you restore —
  actual boot-time restore (nothing running yet) isn't affected.
- If something still doesn't come back right, `~/.local/state/omarchy/omaspace/layouts.json`
  is plain JSON — edit that entry's `"cmd"` array by hand (keep the file
  `0600` and owned by you, or it will be rejected).
- Layouts saved by versions before 1.2 (in
  `~/.local/state/omarchy/window-layouts.json`) are validated and moved into
  the new directory automatically the first time the plugin runs.
- None of the directories on the path to `~/.local/state/omarchy/omaspace/`
  may be symlinks. If yours are, the helper refuses to run and says which
  component it rejected.
