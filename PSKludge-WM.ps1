<#
PSKludge-WM.ps1

FancyZones-free PowerShell tiling manager.
Uses direct Win32 SetWindowPos -- no FancyZones, no synthetic keypresses.

USAGE
  Move focused window:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden `
      -File PSKludge-WM.ps1 -Action move -Direction left

  Force retile:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden `
      -File PSKludge-WM.ps1 -Action retile

  Start background auto-retile daemon (run once; stays alive):
    powershell.exe -NoProfile -ExecutionPolicy Bypass `
      -File PSKludge-WM.ps1 -Action daemon

  Stop daemon:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden `
      -File PSKludge-WM.ps1 -Action stop-daemon

LAYOUT  master-stack
  Zone 0    full left column (master)
  Zone 1+   right column, subdivided top-to-bottom (stack)

DIRECTION mapping for -Action move
  H / left    any stack item -> master;         master -> no-op
  L / right   master -> top of stack (zone 1);  stack item -> no-op
  J / down    master -> bottom of stack;         stack item -> next slot (no wrap)
  K / up      master -> top of stack;            stack item -> prev slot, wraps to master at zone 1
#>

param(
    [ValidateSet("list","retile","monocle","move","focus","daemon","stop-daemon")]
    [string]$Action = "list",

    [ValidateSet("left","right","up","down")]
    [string]$Direction = "right",

    # Pixel gap inset on every placed window.
    [int]$Gap = 8,

    # Master-pane width as a fraction of the monitor work area width.
    [double]$MasterRatio = 0.62,

    # Upper bound on the number of zones produced by the layout engine.
    [int]$MaxZones = 6,

    # Windows smaller than these dimensions are ignored.
    [int]$MinWidth  = 180,
    [int]$MinHeight = 120,

    # Daemon: milliseconds of event silence before triggering a retile.
    [int]$DebounceMs = 400,

    [switch]$VerboseLog
)

$ErrorActionPreference = "Stop"

$StateDir = Join-Path $env:LOCALAPPDATA "WindowTiler"
$PidFile  = Join-Path $StateDir "daemon.pid"
New-Item -ItemType Directory -Force $StateDir | Out-Null

# ============================================================
#  Win32 type definitions
# ============================================================
#
# The PSTypeName guard prevents Add-Type from throwing when the script
# is invoked multiple times within the same PowerShell session (e.g. by
# the daemon calling Invoke-Retile in a loop).

if (-not ([System.Management.Automation.PSTypeName]'Win32Tiler').Type) {
    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public class Win32Tiler {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    // GetWindowPlacement is used instead of GetWindowRect for eligibility checks.
    // GetWindowRect returns garbage coordinates for minimized windows;
    // GetWindowPlacement.showCmd tells us the minimized/maximized/normal state reliably.
    [DllImport("user32.dll")]
    public static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

    [DllImport("user32.dll")]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    // Warps the hardware cursor to an absolute screen position.
    // Used after SetForegroundWindow to land the cursor at the center of
    // the newly focused window -- mirrors Hyprland's cursor-warp-on-focus behavior.
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    // DwmGetWindowAttribute(DWMWA_CLOAKED=14) returns non-zero for UWP/system
    // windows that are technically visible to Win32 but not rendered on screen.
    // Without this check those processes end up in the tile set.
    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(
        IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x, y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT {
        public int   length, flags, showCmd;
        public POINT ptMinPosition, ptMaxPosition;
        public RECT  rcNormalPosition;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO {
        public int  cbSize;
        public RECT rcMonitor, rcWork;
        public uint dwFlags;
    }
}
"@
}

# ============================================================
#  Constants
# ============================================================

$SW_RESTORE       = 9
$SW_SHOWMINIMIZED = 2
$SWP_NOZORDER     = 0x0004
$SWP_NOACTIVATE   = 0x0010
$SWP_SHOWWINDOW   = 0x0040
$MONITOR_NEAREST  = 2
$DWMWA_CLOAKED    = 14

$ExcludedProcessNames = @(
    "PowerToys","PowerToys.FancyZones","PowerToys.PowerLauncher",
    "PowerToys.CommandPalette","Power Automate","PAD.Console.Host",
    "PAD.Robot","TextInputHost","ShellExperienceHost",
    "StartMenuExperienceHost","SearchHost","ApplicationFrameHost",
    "SystemSettings"
)

$ExcludedClasses = @(
    "Shell_TrayWnd","Shell_SecondaryTrayWnd","Progman","WorkerW",
    "Windows.UI.Core.CoreWindow","NotifyIconOverflowWindow"
)

$ExcludedTitleFragments = @("Program Manager")

# ============================================================
#  Low-level helpers
# ============================================================

function Write-DebugLog($msg) { if ($VerboseLog) { Write-Host "[PSKludge-WM] $msg" } }

function Get-WindowTitle([IntPtr]$hwnd) {
    $len = [Win32Tiler]::GetWindowTextLength($hwnd)
    if ($len -le 0) { return "" }
    $sb = New-Object System.Text.StringBuilder ($len + 1)
    [void][Win32Tiler]::GetWindowText($hwnd, $sb, $sb.Capacity)
    return $sb.ToString()
}

function Get-WindowClass([IntPtr]$hwnd) {
    $sb = New-Object System.Text.StringBuilder 256
    [void][Win32Tiler]::GetClassName($hwnd, $sb, $sb.Capacity)
    return $sb.ToString()
}

function Get-WindowPid([IntPtr]$hwnd) {
    [uint32]$pid = 0
    [void][Win32Tiler]::GetWindowThreadProcessId($hwnd, [ref]$pid)
    return [int64]$pid
}

function Get-Rect([IntPtr]$hwnd) {
    $r = New-Object Win32Tiler+RECT
    [void][Win32Tiler]::GetWindowRect($hwnd, [ref]$r)
    return [PSCustomObject]@{
        X = $r.Left; Y = $r.Top
        W = $r.Right  - $r.Left
        H = $r.Bottom - $r.Top
        CX = [int](($r.Left + $r.Right)  / 2)
        CY = [int](($r.Top  + $r.Bottom) / 2)
        Left = $r.Left; Top = $r.Top; Right = $r.Right; Bottom = $r.Bottom
    }
}

function New-RectObj([int]$x, [int]$y, [int]$w, [int]$h) {
    return [PSCustomObject]@{
        X = $x; Y = $y; W = $w; H = $h
        CX = [int]($x + $w / 2)
        CY = [int]($y + $h / 2)
        Left = $x; Top = $y; Right = $x + $w; Bottom = $y + $h
    }
}

function Get-MonitorWorkArea([IntPtr]$hwnd) {
    $monitor = [Win32Tiler]::MonitorFromWindow($hwnd, $MONITOR_NEAREST)
    $mi = New-Object Win32Tiler+MONITORINFO
    $mi.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($mi)
    [void][Win32Tiler]::GetMonitorInfo($monitor, [ref]$mi)
    return [PSCustomObject]@{
        Monitor = $monitor
        X = $mi.rcWork.Left;  Y = $mi.rcWork.Top
        W = $mi.rcWork.Right  - $mi.rcWork.Left
        H = $mi.rcWork.Bottom - $mi.rcWork.Top
        Left  = $mi.rcWork.Left;   Top    = $mi.rcWork.Top
        Right = $mi.rcWork.Right;  Bottom = $mi.rcWork.Bottom
    }
}

function Get-OverlapArea($a, $b) {
    $l  = [Math]::Max($a.Left,   $b.Left)
    $t  = [Math]::Max($a.Top,    $b.Top)
    $r  = [Math]::Min($a.Right,  $b.Right)
    $bo = [Math]::Min($a.Bottom, $b.Bottom)
    if ($r -le $l -or $bo -le $t) { return 0 }
    return ($r - $l) * ($bo - $t)
}

# ============================================================
#  Window enumeration
# ============================================================

function Test-EligibleWindow([IntPtr]$hwnd, [IntPtr]$targetMonitor, [hashtable]$procTable) {
    if (-not [Win32Tiler]::IsWindowVisible($hwnd)) { return $false }

    # Skip minimized windows — their GetWindowRect coordinates are meaningless.
    $wp = New-Object Win32Tiler+WINDOWPLACEMENT
    $wp.length = [Runtime.InteropServices.Marshal]::SizeOf($wp)
    [void][Win32Tiler]::GetWindowPlacement($hwnd, [ref]$wp)
    if ($wp.showCmd -eq $SW_SHOWMINIMIZED) { return $false }

    # Skip cloaked windows (UWP background processes, ghost windows, etc.).
    [int]$cloaked = 0
    [void][Win32Tiler]::DwmGetWindowAttribute($hwnd, $DWMWA_CLOAKED, [ref]$cloaked, 4)
    if ($cloaked -ne 0) { return $false }

    $title = Get-WindowTitle $hwnd
    if ([string]::IsNullOrWhiteSpace($title)) { return $false }
    foreach ($frag in $ExcludedTitleFragments) { if ($title -like "*$frag*") { return $false } }

    $class = Get-WindowClass $hwnd
    if ($ExcludedClasses -contains $class) { return $false }

    $pid  = Get-WindowPid $hwnd
    $proc = if ($procTable.ContainsKey($pid)) { $procTable[$pid] } else { "" }
    foreach ($ex in $ExcludedProcessNames) { if ($proc -like "$ex*") { return $false } }

    $rect = Get-Rect $hwnd
    if ($rect.W -lt $MinWidth -or $rect.H -lt $MinHeight) { return $false }

    $mon = [Win32Tiler]::MonitorFromWindow($hwnd, $MONITOR_NEAREST)
    if ($mon -ne $targetMonitor) { return $false }

    return $true
}

function Get-EligibleWindowsOnActiveMonitor {
    $foreground = [Win32Tiler]::GetForegroundWindow()
    if ($foreground -eq [IntPtr]::Zero) { throw "No foreground window found." }

    $area          = Get-MonitorWorkArea $foreground
    $targetMonitor = $area.Monitor

    # Build the process table once before the enumeration.
    # The original code called Get-Process -Id inside the EnumWindows callback,
    # which is one expensive process-list scan per window. This batches it to one.
    $procTable = @{}
    Get-Process | ForEach-Object { $procTable[[int64]$_.Id] = $_.ProcessName }

    $windows = New-Object System.Collections.ArrayList

    $callback = {
        param([IntPtr]$hwnd, [IntPtr]$lParam)
        if (Test-EligibleWindow $hwnd $targetMonitor $procTable) {
            $pid = Get-WindowPid $hwnd
            [void]$windows.Add([PSCustomObject]@{
                Hwnd     = $hwnd
                HwndInt  = $hwnd.ToInt64()
                Title    = Get-WindowTitle $hwnd
                Process  = if ($procTable.ContainsKey($pid)) { $procTable[$pid] } else { "" }
                Rect     = Get-Rect $hwnd
                IsActive = ($hwnd -eq $foreground)
            })
        }
        return $true
    }

    [void][Win32Tiler]::EnumWindows($callback, [IntPtr]::Zero)

    # Active window always first — Invoke-Retile uses index order to assign zones,
    # so the focused window reliably lands in zone 0 (master).
    $active = @($windows | Where-Object {  $_.IsActive })
    $rest   = @($windows | Where-Object { -not $_.IsActive })

    return [PSCustomObject]@{
        Area       = $area
        Foreground = $foreground
        Windows    = @($active + $rest)
    }
}

# ============================================================
#  Zone geometry
# ============================================================

function Get-MasterStackZones($area, [int]$count, [double]$masterRatio, [int]$maxZones) {
    $count = [Math]::Max(1, [Math]::Min($count, $maxZones))
    $zones = New-Object System.Collections.ArrayList

    if ($count -eq 1) {
        [void]$zones.Add((New-RectObj $area.X $area.Y $area.W $area.H))
        return @($zones)
    }

    $masterW = [int]($area.W * $masterRatio)

    if ($count -eq 2) {
        [void]$zones.Add((New-RectObj $area.X               $area.Y $masterW             $area.H))
        [void]$zones.Add((New-RectObj ($area.X + $masterW)  $area.Y ($area.W - $masterW) $area.H))
        return @($zones)
    }

    $stackX     = $area.X + $masterW
    $stackW     = $area.W - $masterW
    $stackCount = $count - 1
    $stackH     = [int]($area.H / $stackCount)

    [void]$zones.Add((New-RectObj $area.X $area.Y $masterW $area.H))
    for ($i = 0; $i -lt $stackCount; $i++) {
        $y = $area.Y + $i * $stackH
        $h = if ($i -eq $stackCount - 1) { $area.H - $i * $stackH } else { $stackH }
        [void]$zones.Add((New-RectObj $stackX $y $stackW $h))
    }

    return @($zones)
}

function Get-BestZoneForWindow($window, $zones) {
    $rect = $window.Rect
    $bestIndex = 0; $bestOverlap = -1

    for ($i = 0; $i -lt $zones.Count; $i++) {
        $ov = Get-OverlapArea $rect $zones[$i]
        if ($ov -gt $bestOverlap) { $bestOverlap = $ov; $bestIndex = $i }
    }

    if ($bestOverlap -gt 0) { return $bestIndex }

    # No overlap at all (window is off-screen or between zones): nearest center.
    $bestDist = [double]::PositiveInfinity
    for ($i = 0; $i -lt $zones.Count; $i++) {
        $dx = $rect.CX - $zones[$i].CX; $dy = $rect.CY - $zones[$i].CY
        $d  = $dx * $dx + $dy * $dy
        if ($d -lt $bestDist) { $bestDist = $d; $bestIndex = $i }
    }

    return $bestIndex
}

# Layout-aware direction→zone mapping for master-stack.
#
# This function is intentionally layout-specific.  If you add a grid or dwindle
# layout later, swap in a different direction function for that layout rather than
# making this one generic — the semantics differ too much.
#
# Zone 0  = master (full left column)
# Zone 1+ = stack (right column, top to bottom)
function Get-DirectionalTarget([int]$current, [string]$dir, [int]$zoneCount) {
    $isMaster = ($current -eq 0)

    switch ($dir) {
        "left" {
            if (-not $isMaster) { return 0 }           # any stack item -> master
            return $current                             # already master, no-op
        }
        "right" {
            if ($isMaster -and $zoneCount -gt 1) { return 1 }  # master -> top of stack
            return $current                             # already in stack (rightmost column), no-op
        }
        "down" {
            if ($isMaster -and $zoneCount -gt 1)      { return $zoneCount - 1 }   # master -> bottom of stack
            if (-not $isMaster -and $current -lt $zoneCount - 1) { return $current + 1 }  # next slot
            return $current                             # already at bottom, no-op
        }
        "up" {
            if ($isMaster -and $zoneCount -gt 1)      { return 1 }                # master -> top of stack
            if (-not $isMaster)                        { return [Math]::Max(0, $current - 1) }  # prev slot, or master at zone 1
            return $current
        }
    }

    return $current
}

# ============================================================
#  Window placement
# ============================================================

function Move-WindowToRect([IntPtr]$hwnd, $rect, [int]$gap) {
    $x = [int]($rect.X + $gap)
    $y = [int]($rect.Y + $gap)
    $w = [int]([Math]::Max(100, $rect.W - 2 * $gap))
    $h = [int]([Math]::Max(80,  $rect.H - 2 * $gap))

    # SW_RESTORE unminimizes/unmaximizes before repositioning.
    [void][Win32Tiler]::ShowWindow($hwnd, $SW_RESTORE)
    $flags = $SWP_NOZORDER -bor $SWP_SHOWWINDOW -bor $SWP_NOACTIVATE
    [void][Win32Tiler]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, $w, $h, $flags)
}

# ============================================================
#  Actions
# ============================================================

function Invoke-Retile([string]$layout = "master-stack") {
    $ctx     = Get-EligibleWindowsOnActiveMonitor
    $windows = @($ctx.Windows)
    if ($windows.Count -eq 0) { return }

    if ($layout -eq "monocle") {
        $full = New-RectObj $ctx.Area.X $ctx.Area.Y $ctx.Area.W $ctx.Area.H
        foreach ($w in $windows) { Move-WindowToRect $w.Hwnd $full $Gap }
        [void][Win32Tiler]::SetForegroundWindow($ctx.Foreground)
        return
    }

    # master-stack: zone assignment is purely by list position.
    # Active window is always first (see Get-EligibleWindowsOnActiveMonitor),
    # so it always lands in zone 0 (master pane).
    $zones = Get-MasterStackZones $ctx.Area $windows.Count $MasterRatio $MaxZones
    $limit = [Math]::Min($windows.Count, $zones.Count)

    for ($i = 0; $i -lt $limit; $i++) {
        Move-WindowToRect $windows[$i].Hwnd $zones[$i] $Gap
    }

    [void][Win32Tiler]::SetForegroundWindow($ctx.Foreground)
}

function Invoke-MoveDirection([string]$direction) {
    $ctx     = Get-EligibleWindowsOnActiveMonitor
    $windows = @($ctx.Windows)
    if ($windows.Count -eq 0) { return }

    $focused = $windows | Where-Object { $_.IsActive } | Select-Object -First 1
    if (-not $focused) { return }

    $zones = Get-MasterStackZones $ctx.Area $windows.Count $MasterRatio $MaxZones

    # Assign every live window to its current geometric best zone.
    # This is stateless — no JSON, no HWND table — the assignment is
    # derived from where windows physically are on screen right now.
    $assignments = @{}
    foreach ($w in $windows) {
        $assignments[$w.HwndInt] = Get-BestZoneForWindow $w $zones
    }

    $oldZone    = $assignments[$focused.HwndInt]
    $targetZone = Get-DirectionalTarget $oldZone $direction $zones.Count

    Write-DebugLog "move: old=$oldZone target=$targetZone dir=$direction hwnd=$($focused.HwndInt)"

    if ($targetZone -eq $oldZone) {
        Write-DebugLog "move: no zone in direction '$direction' from zone $oldZone"
        return
    }

    # Find the current occupant of the target zone (if any).
    $displaced = $windows |
        Where-Object { $_.HwndInt -ne $focused.HwndInt -and $assignments[$_.HwndInt] -eq $targetZone } |
        Select-Object -First 1

    # Swap: focused → target, displaced → old.  All other windows stay put.
    Move-WindowToRect $focused.Hwnd $zones[$targetZone] $Gap
    if ($displaced) {
        Move-WindowToRect $displaced.Hwnd $zones[$oldZone] $Gap
    }

    [void][Win32Tiler]::SetForegroundWindow($focused.Hwnd)
}

function Invoke-FocusDirection([string]$direction) {
    $ctx     = Get-EligibleWindowsOnActiveMonitor
    $windows = @($ctx.Windows)
    if ($windows.Count -eq 0) { return }

    $focused = $windows | Where-Object { $_.IsActive } | Select-Object -First 1
    if (-not $focused) { return }

    $zones = Get-MasterStackZones $ctx.Area $windows.Count $MasterRatio $MaxZones

    # Same geometric assignment as Invoke-MoveDirection — no persistent state.
    $assignments = @{}
    foreach ($w in $windows) {
        $assignments[$w.HwndInt] = Get-BestZoneForWindow $w $zones
    }

    $oldZone    = $assignments[$focused.HwndInt]
    $targetZone = Get-DirectionalTarget $oldZone $direction $zones.Count

    Write-DebugLog "focus: old=$oldZone target=$targetZone dir=$direction"

    if ($targetZone -eq $oldZone) {
        Write-DebugLog "focus: no zone in direction '$direction' from zone $oldZone"
        return
    }

    $target = $windows |
        Where-Object { $_.HwndInt -ne $focused.HwndInt -and $assignments[$_.HwndInt] -eq $targetZone } |
        Select-Object -First 1

    if (-not $target) {
        Write-DebugLog "focus: target zone $targetZone is empty"
        return
    }

    # Focus the target window, then warp the cursor to its center.
    # SetForegroundWindow is instant; the cursor warp reinforces focus-follows-mouse
    # and gives visual feedback about where focus landed.
    [void][Win32Tiler]::SetForegroundWindow($target.Hwnd)
    [void][Win32Tiler]::SetCursorPos($target.Rect.CX, $target.Rect.CY)
}

function Invoke-List {
    $ctx     = Get-EligibleWindowsOnActiveMonitor
    $windows = @($ctx.Windows)
    $zones   = Get-MasterStackZones $ctx.Area ([Math]::Max(1, $windows.Count)) $MasterRatio $MaxZones

    Write-Host "`nWork area  X=$($ctx.Area.X)  Y=$($ctx.Area.Y)  W=$($ctx.Area.W)  H=$($ctx.Area.H)"
    Write-Host "`nZones ($($zones.Count) for $($windows.Count) eligible windows):"
    for ($i = 0; $i -lt $zones.Count; $i++) {
        $z = $zones[$i]
        Write-Host ("  [{0}]  X={1}  Y={2}  W={3}  H={4}" -f $i, $z.X, $z.Y, $z.W, $z.H)
    }

    Write-Host "`nEligible windows (geometric zone assignment):"
    foreach ($w in $windows) {
        $zi   = Get-BestZoneForWindow $w $zones
        $mark = if ($w.IsActive) { "*" } else { " " }
        Write-Host ("{0} Zone[{1}]  HWND={2}  [{3}]  {4}" -f $mark, $zi, $w.HwndInt, $w.Process, $w.Title)
    }
    Write-Host ""
}

# ============================================================
#  Daemon
# ============================================================

function Invoke-Daemon {
    # ShellWatcher is only compiled when the daemon is actually started.
    # Keeping it out of the top-level Add-Type means non-daemon invocations
    # (move, retile, etc.) don't pay the Roslyn compilation cost.
    if (-not ([System.Management.Automation.PSTypeName]'ShellWatcher').Type) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Threading;

public class ShellWatcher {
    private const uint WINEVENT_OUTOFCONTEXT = 0x0000;
    private const uint EVENT_OBJECT_SHOW     = 0x8002;
    private const uint EVENT_OBJECT_DESTROY  = 0x8001;
    private const int  OBJID_WINDOW          = 0;
    private const int  CHILDID_SELF          = 0;

    // The delegate MUST be stored in a static field.
    // If it were a local variable, the GC could collect it after Start() returns
    // while the native hook still holds a raw function pointer to the delegate's
    // thunk, causing a crash.  Static field = GC root = stays alive forever.
    private static WinEventDelegate _callback;
    private static IntPtr _hook1 = IntPtr.Zero;
    private static IntPtr _hook2 = IntPtr.Zero;
    private static int    _changeCount = 0;

    public static int ChangeCount { get { return _changeCount; } }

    public delegate void WinEventDelegate(
        IntPtr hHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild,
        uint dwEventThread, uint dwmsEventTime);

    [DllImport("user32.dll")]
    private static extern IntPtr SetWinEventHook(
        uint eventMin, uint eventMax,
        IntPtr hmodWinEventProc, WinEventDelegate lpfnWinEventProc,
        uint idProcess, uint idThread, uint dwFlags);

    [DllImport("user32.dll")]
    private static extern bool UnhookWinEvent(IntPtr hWinEventHook);

    // GetMessage is required for WINEVENT_OUTOFCONTEXT hooks to fire.
    // The hook callback is delivered on the hooking thread's message queue,
    // so that thread must be pumping messages, not just sleeping.
    [DllImport("user32.dll")]
    private static extern int GetMessage(
        out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG lpMsg);

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG {
        public IntPtr hwnd;
        public uint   message;
        public IntPtr wParam, lParam;
        public uint   time;
        public int    ptX, ptY;
    }

    private static void OnWinEvent(
        IntPtr hHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild,
        uint dwEventThread, uint dwmsEventTime)
    {
        // idObject == OBJID_WINDOW (0) and idChild == CHILDID_SELF (0) together
        // mean this is a top-level window event, not a menu, tooltip, caret,
        // scroll bar, or other child-object event.  This is the primary noise
        // filter at the native level; the eligible-count check in the PowerShell
        // polling loop is the secondary filter.
        if (idObject == OBJID_WINDOW && idChild == CHILDID_SELF && hwnd != IntPtr.Zero) {
            Interlocked.Increment(ref _changeCount);
        }
    }

    public static void Start() {
        _callback = new WinEventDelegate(OnWinEvent);  // stored statically above

        Thread pump = new Thread(() => {
            // Both hooks registered on the pump thread so callbacks are
            // delivered here.  WINEVENT_OUTOFCONTEXT means no DLL injection.
            _hook1 = SetWinEventHook(
                EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW,
                IntPtr.Zero, _callback, 0, 0, WINEVENT_OUTOFCONTEXT);
            _hook2 = SetWinEventHook(
                EVENT_OBJECT_DESTROY, EVENT_OBJECT_DESTROY,
                IntPtr.Zero, _callback, 0, 0, WINEVENT_OUTOFCONTEXT);

            MSG msg;
            // GetMessage returns 0 on WM_QUIT, -1 on error.
            // This loop is what actually delivers the callbacks.
            while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }

            if (_hook1 != IntPtr.Zero) { UnhookWinEvent(_hook1); _hook1 = IntPtr.Zero; }
            if (_hook2 != IntPtr.Zero) { UnhookWinEvent(_hook2); _hook2 = IntPtr.Zero; }
        });

        // IsBackground = true: the pump thread is killed automatically when
        // the main PowerShell thread exits (Ctrl+C or Stop-Process).
        pump.IsBackground = true;
        pump.SetApartmentState(ApartmentState.STA);
        pump.Name = "ShellWatcherPump";
        pump.Start();
    }
}
"@
    }

    [ShellWatcher]::Start()
    [System.IO.File]::WriteAllText($PidFile, $PID.ToString())
    Write-Host "PSKludge-WM daemon running (PID $PID). Ctrl+C to stop."

    # Snapshot eligible window count at startup.
    $lastWindowCount = 0
    try { $lastWindowCount = (Get-EligibleWindowsOnActiveMonitor).Windows.Count }
    catch { Write-DebugLog "daemon: initial count failed -- $($_.Exception.Message)" }

    $lastSeen      = [ShellWatcher]::ChangeCount
    $pendingRetile = $false
    $pendingSince  = [DateTime]::MinValue

    try {
        while ($true) {
            $current = [ShellWatcher]::ChangeCount

            # New event arrived — restart the debounce timer.
            # This means a burst of events (e.g. Chrome opening six windows at once)
            # collapses to a single retile 400 ms after the last event in the burst.
            if ($current -ne $lastSeen) {
                $lastSeen      = $current
                $pendingRetile = $true
                $pendingSince  = [DateTime]::UtcNow
            }

            if ($pendingRetile) {
                $elapsed = ([DateTime]::UtcNow - $pendingSince).TotalMilliseconds
                if ($elapsed -ge $DebounceMs) {
                    $pendingRetile = $false

                    # Second filter: only retile if the eligible window count actually
                    # changed.  Many things fire WinEvent callbacks (tooltips, shadow
                    # frames, IME windows) without changing what we'd tile.
                    try {
                        $nowCount = (Get-EligibleWindowsOnActiveMonitor).Windows.Count
                        if ($nowCount -ne $lastWindowCount) {
                            Write-DebugLog "daemon: count $lastWindowCount -> $nowCount, retiling"
                            $lastWindowCount = $nowCount
                            Invoke-Retile "master-stack"
                        } else {
                            Write-DebugLog "daemon: events fired but eligible count unchanged ($nowCount), skipping"
                        }
                    } catch {
                        Write-DebugLog "daemon: retile skipped -- $($_.Exception.Message)"
                    }
                }
            }

            Start-Sleep -Milliseconds 150
        }
    }
    finally {
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        Write-Host "PSKludge-WM daemon stopped."
    }
}

function Invoke-StopDaemon {
    if (-not (Test-Path $PidFile)) {
        Write-Host "No daemon PID file found at $PidFile.  Is the daemon running?"
        return
    }

    $daemonPid = [int](Get-Content $PidFile -Raw).Trim()
    try {
        Stop-Process -Id $daemonPid -Force -ErrorAction Stop
        Write-Host "Daemon (PID $daemonPid) stopped."
    } catch {
        Write-Host "Could not stop PID $daemonPid -- $($_.Exception.Message)"
    } finally {
        # Always clean up the PID file, even if the process was already dead.
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
#  Dispatch
# ============================================================

switch ($Action) {
    "list"        { Invoke-List }
    "retile"      { Invoke-Retile "master-stack" }
    "monocle"     { Invoke-Retile "monocle" }
    "move"        { Invoke-MoveDirection $Direction }
    "focus"       { Invoke-FocusDirection $Direction }
    "daemon"      { Invoke-Daemon }
    "stop-daemon" { Invoke-StopDaemon }
}
