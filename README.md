# OmaSpace


Omarchy shell plugin: save which apps live on which Hyprland workspace, and
restore them with a click — or automatically on login.

## Installation and removal

Requires Omarchy with Quattro/Quickshell, Hyprland’s Lua API, Bash 4.4+,
GNU coreutils, jq and Python 3 at `/usr/bin/python3`. The helper also uses
`omarchy hook install` and `omarchy-notification-send`.

Install OmaSpace through the Omarchy plugin marketplace and add the OmaSpace
widget to your bar. Keep `Panel.qml`, `window-layouts.sh`, `state-store.py`
and `manifest.json` together in the installed plugin directory.

Before removing the plugin through the plugin manager, disable **Run on boot**
so its post-boot hook is removed. Saved layouts remain in
`~/.local/state/omarchy/omaspace/`; you may delete that directory if you no
longer need them. The plugin is licensed under the [MIT license](LICENSE).

## Use

Click the layered pages icon in the bar (top-right by default).

- **Save current layout** — snapshots every window on every workspace right
  now under the name typed into the field.
- Each saved layout shows **Restore** (relaunches every app straight onto its
  saved workspace) and **✕** (delete, with confirmation).
- Turn on a layout’s **Run on boot** switch to restore it automatically after
  login; turn the switch off to disable that. Turning it on
  installs a small `post-boot` hook (via `omarchy hook install post-boot ...`,
  landing in `~/.config/omarchy/hooks/post-boot.d/window-layouts-boot-hook.sh`);
  turning it off again removes that hook.

## How it works

The QML UI invokes `window-layouts.sh` using Quickshell processes.
`state-store.py` supplies the no-follow filesystem operations.
Both problems below turned out to be widespread
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

The helper only runs saved commands as argv arrays; it never splits a
flattened persisted command string. There is no shell `eval`, no `sh -c`,
and nothing read from disk is re-parsed as shell.
Beyond that:

- **Fixed shell, cleared environment.** The panel starts the helper as
  `/bin/bash --noprofile --norc -p -- window-layouts.sh ...` with the process
  environment cleared and only an allowlist passed through: `PATH` pinned to
  `/usr/bin`, `LC_ALL`, `HOME`, `XDG_STATE_HOME`, `XDG_RUNTIME_DIR`,
  `HYPRLAND_INSTANCE_SIGNATURE`, `DBUS_SESSION_BUS_ADDRESS` and
  `WAYLAND_DISPLAY`. The generated boot hook re-execs the helper the same way
  through `/usr/bin/env -i`. The script's `#!/bin/bash -p` shebang makes Bash
  ignore `BASH_ENV`, `SHELLOPTS` and inherited functions if it is ever run
  directly. Generated launchers also use `/usr/bin/env -i` with this allowlist.
- **Descriptor-relative state hierarchy.** State lives in
  `~/.local/state/omarchy/omaspace/`. The helper walks that path from `/` one
  component at a time through open directory descriptors
  using Python’s `dir_fd` operations and `O_DIRECTORY | O_NOFOLLOW`,
  then checks ownership and mode with `fstat`. Python runs in isolated mode
  (`/usr/bin/python3 -I -S`), and passes retained descriptors to the helper.
  Ancestors must be owned by
  root or by you and not be group/other-writable. The `omaspace` directory
  must be owned by you with mode `0700`. Every later read, write, temp file,
  rename and delete goes through the open descriptor.
- **Checked, bounded reads.** The state file is `lstat`ed before it is
  opened. `O_NOFOLLOW | O_NONBLOCK` also prevents a replacement symlink
  from being followed or a replacement FIFO from blocking the helper.
  The open descriptor
  must then be the same inode, a regular file owned by you, with one link, no
  group/other write bit and at most 1 MiB. A bounded read rejects growth
  beyond 1 MiB and embedded NUL bytes. A file that
  fails any check is renamed to `layouts.json.rejected-<timestamp>` and never
  parsed.
- **Strict schema.** Whatever is parsed is normalised by a fixed jq schema with
  hard limits on layout count and name length, workspace keys, entries per
  workspace, string lengths, and argv count and length. Anything that does not
  fit is dropped. Only this validated document is used by the panel, by
  `restore`, and by the boot hook's `restore-boot`.
- **Atomic writes.** Changes go to a fresh `0600` temp file in the same
  directory, opened with `O_EXCL | O_NOFOLLOW`, flushed and then renamed
  over the state file. Writes exceeding 1 MiB are refused. The state
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

State protections prevent other users and unsafe filesystem entries from
supplying executable state. Your own account remains trusted: editing an
accepted layout’s command array changes what Restore and Run on boot execute.
Schema validation does not certify that a command is safe.
