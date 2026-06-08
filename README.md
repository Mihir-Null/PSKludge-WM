# PSKludge-WM

A PowerShell tiling window manager for locked-down Windows environments.

Provides master-stack tiling, directional window movement and focus, and automatic
layout reflow — without FancyZones, without third-party executables, and without
requiring admin rights. Everything runs through native Win32 APIs accessed via
PowerShell's `Add-Type` P/Invoke bridge.

Intended as a partial replacement for a tiling WM workflow (Hyprland/dwm/i3) when
you're stuck on a Windows machine you don't fully control.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1+ (built into Windows — no install needed)
- [PowerToys](https://github.com/microsoft/PowerToys) — for remapping keys to your preferred modifier chords (optional but strongly recommended)
- Execution policy that allows local scripts, or the ability to pass `-ExecutionPolicy Bypass` per-process (no machine-wide policy change required)

---

## How it works

```
┌─────────────────────┬──────────────┐
│                     │   Stack [1]  │
│    Master  [0]      ├──────────────┤
│                     │   Stack [2]  │
│                     ├──────────────┤
│                     │   Stack [3]  │
└─────────────────────┴──────────────┘
```

Windows are assigned to zones geometrically at query time — there is no persistent
state. Zone 0 is always the master (left column); zones 1–n divide the right column
top to bottom. The active window always lands in zone 0 on a retile.

**move** swaps two windows between zones and leaves everything else in place.
**focus** changes focus and warps the cursor to the target window's center.
**retile** reflowes all windows into the correct zones for the current count.
**daemon** watches for window open/close events and retiles automatically.

---

## Installation

1. Copy `PSKludge-WM.ps1` to `%USERPROFILE%\Documents\WindowTiler\`.

2. Run the shortcut installer:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-shortcuts.ps1
   ```
   This creates `.lnk` files under `Documents\WindowTiler\Shortcuts\` and prints
   suggested keybind assignments.

3. Assign hotkeys to the shortcuts:
   - Right-click each `.lnk` → **Properties → Shortcut key** → assign a `Ctrl+Alt+<key>` chord.
   - In **PowerToys Keyboard Manager**, remap your preferred keys to those chords
     (e.g. `RightAlt+H → Ctrl+Alt+H`).

4. *(Optional)* Enable **focus-follows-mouse**:
   Windows → Accessibility → Mouse pointer → *Automatically focus the window
   the pointer is on*. With this on, `focus` actions warp the cursor and
   focus follows — no click needed.

5. *(Optional)* Start the daemon once at login by copying `FZ Start Daemon.lnk`
   to your Startup folder:
   ```
   %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
   ```

---

## Actions

Run via `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File PSKludge-WM.ps1`:

| Action | Description |
|---|---|
| `-Action move -Direction <dir>` | Swap focused window with the occupant of the adjacent zone |
| `-Action focus -Direction <dir>` | Focus the window in the adjacent zone; warp cursor to its center |
| `-Action retile` | Reflow all windows into master-stack zones for the current count |
| `-Action monocle` | Resize all windows to fill the work area; focused window on top |
| `-Action list` | Print current zone geometry and window assignments (debugging) |
| `-Action daemon` | Start background watcher — retiles when window count changes |
| `-Action stop-daemon` | Stop a running daemon |

**Directions:** `left` `right` `up` `down`

### Direction semantics (master-stack)

| Direction | From master | From stack |
|---|---|---|
| `left` / H | no-op | → master |
| `right` / L | → top of stack | no-op |
| `down` / J | → bottom of stack | → next slot (no wrap) |
| `up` / K | → top of stack | → prev slot, or master at top |

---

## Suggested keybind layout

Using `RightAlt` as the move modifier and `Alt` as the focus modifier,
with PowerToys Keyboard Manager as the intermediate layer:

| Key | Chord | Action |
|---|---|---|
| `RightAlt+H` | `Ctrl+Alt+H` | Move Left |
| `RightAlt+J` | `Ctrl+Alt+J` | Move Down |
| `RightAlt+K` | `Ctrl+Alt+K` | Move Up |
| `RightAlt+L` | `Ctrl+Alt+L` | Move Right |
| `Alt+H` | `Ctrl+Alt+[` | Focus Left |
| `Alt+J` | `Ctrl+Alt+;` | Focus Down |
| `Alt+K` | `Ctrl+Alt+'` | Focus Up |
| `Alt+L` | `Ctrl+Alt+\` | Focus Right |
| `RightAlt+R` | `Ctrl+Alt+R` | Retile |
| `RightAlt+M` | `Ctrl+Alt+M` | Monocle |

The `Ctrl+Alt` intermediate chords are required because Windows `.lnk` global
hotkeys only accept that modifier combination. PowerToys lets you make the
actual experience feel like whatever modifier you prefer.

---

## Configuration

Parameters at the top of `PSKludge-WM.ps1` can be set per-invocation or edited as defaults:

| Parameter | Default | Description |
|---|---|---|
| `-Gap` | `8` | Pixel gap inset around each placed window |
| `-MasterRatio` | `0.62` | Master pane width as a fraction of the monitor work area |
| `-MaxZones` | `6` | Maximum number of zones the layout engine will produce |
| `-MinWidth` | `180` | Windows narrower than this are excluded from tiling |
| `-MinHeight` | `120` | Windows shorter than this are excluded from tiling |
| `-DebounceMs` | `400` | Daemon: ms of event silence before triggering a retile |
| `-VerboseLog` | off | Print debug information to stdout |

---

## Daemon internals

The daemon uses `SetWinEventHook` (Win32) with `WINEVENT_OUTOFCONTEXT` to watch
for `EVENT_OBJECT_SHOW` and `EVENT_OBJECT_DESTROY` events system-wide. Callbacks
run on a dedicated STA thread running its own `GetMessage` loop. A counter is
incremented on each relevant event; the PowerShell polling loop checks the counter
every 150 ms and triggers a retile when:

1. The counter has changed, **and**
2. A debounce window of `DebounceMs` has elapsed since the last change, **and**
3. The count of eligible windows on the active monitor actually changed.

The triple filter collapses event bursts (e.g. Chrome opening six windows) into a
single retile and discards noise from tooltips, shadow frames, and IME windows.

---

## Known limitations

- **Single monitor per invocation.** Zone geometry is computed for whichever
  monitor holds the foreground window at the time of the call. Multi-monitor
  setups work but each monitor is treated independently.
- **No HWND persistence.** Window→zone assignments are derived from current
  screen geometry on every call. Windows that have been manually dragged between
  invocations will be assigned to their nearest zone, which may not match where
  you left them. Use `retile` to clean up.
- **Daemon tracks the active monitor only.** If all windows are on a monitor
  other than the one holding the foreground window, the daemon's eligible-count
  check may not detect the change correctly.
- **focus-follows-mouse delay.** Windows' built-in focus-follows-mouse has a
  configurable hover delay (default ~100 ms). The `SetForegroundWindow` call in
  `focus` actions bypasses this and focuses instantly regardless.

---

## Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full component breakdown,
design decisions, and rationale for what was dropped from the original
`fz-manager.ps1` this was refactored from.
