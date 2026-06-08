# PSKludge-WM — Architecture

## Intent

FancyZones-free PowerShell tiling manager for a locked-down Windows Enterprise
environment. Uses direct Win32 `SetWindowPos` — no FancyZones, no synthetic
keypresses. Supports two retile modes: keybind-triggered (implicit on every move,
explicit via `retile` action) and event-driven (daemon via `SetWinEventHook`).
Keybind surface is minimal: HJKL move + retile + monocle.

---

## Dropped from original `fz-manager.ps1`

| Symbol | Reason |
|---|---|
| `Send-WinArrow` + `Invoke-FancyZonesMoveSwap` | Race-condition-prone FancyZones coupling. Not needed once we own geometry. |
| `Load/Save-TilerState` + state JSON | HWND-keyed state is session-volatile. Replaced by live geometric queries. |
| `keybd_event` P/Invoke | No synthetic keypresses. |
| `Get-GridZones` (hot path) | Out of scope for now; code kept but not invoked. |
| 13-shortcut `install-shortcuts.ps1` | Replaced by 9-shortcut version. |

---

## Components

### 1. Win32Tiler (Add-Type)
Bindings: EnumWindows, IsWindowVisible, GetForegroundWindow, GetWindowText,
GetClassName, GetWindowRect, **GetWindowPlacement** (minimized detection),
SetWindowPos, ShowWindow, MonitorFromWindow, GetMonitorInfo,
GetWindowThreadProcessId, SetForegroundWindow, **DwmGetWindowAttribute** (cloaked UWP detection).

Guarded by `PSTypeName` check to prevent double-compilation in long-running sessions.

### 2. Window Enumerator (`Get-EligibleWindowsOnActiveMonitor`)
Builds a process table once via a single `Get-Process` call before `EnumWindows`,
then looks up process names by PID — O(1) per window instead of the original O(n).

Eligibility filter additions over original:
- Skip minimized windows via `GetWindowPlacement.showCmd == SW_SHOWMINIMIZED`
- Skip cloaked UWP/system windows via `DwmGetWindowAttribute(DWMWA_CLOAKED)`

Output: `{ Area, Foreground, Windows[] }` — active window always first.

### 3. Zone Geometry (`Get-MasterStackZones`, `Get-DirectionalTarget`)
`Get-MasterStackZones` kept as-is.

`Get-DirectionalTarget` (new) — layout-aware direction→zone mapping:

```
Zone 0 = master (left column)
Zones 1..n-1 = stack (right column, top to bottom)

H  stack→master;          master→no-op
L  master→top of stack;   stack→no-op
J  master→bottom;         stack→next slot (no wrap)
K  master→top of stack;   stack→prev slot, wraps to master at zone 1
```

This is intentionally layout-specific. Swap in a different function for grid/dwindle.

### 4. Retile Engine (`Invoke-Retile`)
Enumerates live windows, computes zones from count, places all windows.
Two layouts: `master-stack` (default) and `monocle`.
Active window always placed in zone 0.
No persistent state.

### 5. Move+Swap (`Invoke-MoveDirection`)
No persistent state — all zone assignment derived from current screen geometry at
call time. Algorithm:

1. Enumerate live windows, compute zones from count.
2. Assign each window to its current geometric best zone (overlap → centroid fallback).
3. Find focused window's current zone (`oldZone`).
4. Compute `targetZone` via `Get-DirectionalTarget`.
5. Find current occupant of `targetZone` (`displaced`).
6. Move focused → `targetZone`; move displaced → `oldZone`.
7. All other windows stay put. Gaps cleaned up by explicit `retile`.

### 6. Shell Hook Daemon (`Invoke-Daemon`)
Two-layer design:

**Layer 1 — C# `ShellWatcher` (Add-Type, only compiled when `-Action daemon`)**
- Spins up a dedicated STA thread.
- Thread registers `SetWinEventHook` for `EVENT_OBJECT_SHOW` and
  `EVENT_OBJECT_DESTROY` with `WINEVENT_OUTOFCONTEXT`.
- Thread runs `GetMessage` loop — required for OUTOFCONTEXT hooks to fire.
- On each callback: filter to `idObject == OBJID_WINDOW && idChild == CHILDID_SELF`,
  then `Interlocked.Increment(_changeCount)`.
- Delegate stored in a static field to prevent GC collection while the native hook
  holds a function pointer to it.

**Layer 2 — PowerShell polling loop**
- Polls `[ShellWatcher]::ChangeCount` every 150 ms.
- On change: restart a 400 ms debounce timer.
- When timer expires: check if the eligible window count actually changed
  (discards tooltips/shadow frames that pass the WinEvent filter but not
  `Test-EligibleWindow`).
- If count changed: call `Invoke-Retile` directly (same process, no spawn overhead).

PID written to `%LOCALAPPDATA%\WindowTiler\daemon.pid` on start, cleaned up on exit.
`Invoke-StopDaemon` reads the PID file and calls `Stop-Process`.

---

## Decision Log

| Decision | Choice | Rationale |
|---|---|---|
| FancyZones dependency | Dropped | Eliminates race condition; we own geometry via SetWindowPos |
| Persistent HWND state | Dropped | HWNDs are session-volatile; live geometric queries are sufficient |
| Auto-retile on swap | No (stay-put) | Less visual noise; retile is explicit or daemon-triggered |
| Retile on move trigger | No | Retile is explicit (Alt+R) or daemon-triggered; move only swaps two windows |
| Daemon startup | User-explicit | No auto-start from keybind invocations |
| Daemon retile mechanism | Direct function call (same process) | Avoids ~500 ms powershell.exe spawn overhead per event |
| Direction semantics | Layout-aware (HJKL for master-stack) | More intuitive than index cycling; `Get-DirectionalTarget` is swappable |
| Debounce strategy | Event counter + 400 ms timer + eligible count check | Two-filter approach discards tooltip/shadow noise without expensive per-event enumeration |

---

## Component Status

| Component | Status |
|---|---|
| Win32Tiler bindings | ✅ Implemented |
| Window Enumerator | ✅ Implemented |
| Zone Geometry | ✅ Implemented |
| Retile Engine | ✅ Implemented |
| Move+Swap | ✅ Implemented |
| Shell Hook Daemon | ✅ Implemented |
