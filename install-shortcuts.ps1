<#
install-shortcuts.ps1

Creates Windows .lnk shortcuts for PSKludge-WM.ps1 and copies the script to
Documents\WindowTiler if it isn't already there.

Run from the folder containing PSKludge-WM.ps1:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-shortcuts.ps1

AFTER CREATION
  1. Open the Shortcuts folder (script prints the path).
  2. Right-click each shortcut → Properties → Shortcut key → assign a Ctrl+Alt+<key> chord.
     Windows requires the shortcut to live on the Desktop or Start Menu for global
     hotkeys to work — move or copy the Shortcuts folder there if needed.
  3. In PowerToys Keyboard Manager remap your preferred keys to those chords, e.g.:
       RightAlt+H  →  Ctrl+Alt+H   (Move Left)
       RightAlt+J  →  Ctrl+Alt+J   (Move Down)
       RightAlt+K  →  Ctrl+Alt+K   (Move Up)
       RightAlt+L  →  Ctrl+Alt+L   (Move Right)
       RightAlt+R  →  Ctrl+Alt+R   (Retile)
       RightAlt+M  →  Ctrl+Alt+M   (Monocle)
  4. Start the daemon once at login (or run it manually):
       Open "WM Start Daemon.lnk"
#>

$ErrorActionPreference = "Stop"

$installDir  = Join-Path $env:USERPROFILE "Documents\WindowTiler"
$shortcutDir = Join-Path $installDir "Shortcuts"
$script      = Join-Path $installDir "PSKludge-WM.ps1"

# Copy the script to the install location if it isn't there yet.
$sourceScript = Join-Path $PSScriptRoot "PSKludge-WM.ps1"
if (-not (Test-Path $script)) {
    if (-not (Test-Path $sourceScript)) {
        throw "Cannot find PSKludge-WM.ps1.  Run this installer from the folder that contains it."
    }
    New-Item -ItemType Directory -Force $installDir | Out-Null
    Copy-Item $sourceScript $script
    Write-Host "Copied PSKludge-WM.ps1 → $installDir"
}

New-Item -ItemType Directory -Force $shortcutDir | Out-Null

# Hidden invocation (used for all action shortcuts so no console flashes).
$h = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
# Visible invocation (list/debug only — you want to see the output).
$v = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""

# [ordered] preserves the print order in the output below.
$items = [ordered]@{
    "WM Move Left.lnk"     = "$h -Action move  -Direction left"
    "WM Move Down.lnk"     = "$h -Action move  -Direction down"
    "WM Move Up.lnk"       = "$h -Action move  -Direction up"
    "WM Move Right.lnk"    = "$h -Action move  -Direction right"
    "WM Focus Left.lnk"    = "$h -Action focus -Direction left"
    "WM Focus Down.lnk"    = "$h -Action focus -Direction down"
    "WM Focus Up.lnk"      = "$h -Action focus -Direction up"
    "WM Focus Right.lnk"   = "$h -Action focus -Direction right"
    "WM Retile.lnk"        = "$h -Action retile"
    "WM Monocle.lnk"       = "$h -Action monocle"
    "WM Start Daemon.lnk"  = "$h -Action daemon"
    "WM Stop Daemon.lnk"   = "$h -Action stop-daemon"
    "WM List.lnk"          = "$v -Action list"
}

$wsh = New-Object -ComObject WScript.Shell
foreach ($name in $items.Keys) {
    $path           = Join-Path $shortcutDir $name
    $sc             = $wsh.CreateShortcut($path)
    $sc.TargetPath       = "powershell.exe"
    $sc.Arguments        = $items[$name]
    $sc.WorkingDirectory = $installDir
    $sc.WindowStyle      = 7    # SW_SHOWMINNOACTIVE: minimized, no flash
    $sc.Save()
    Write-Host "Created  $path"
}

Write-Host ""
Write-Host "Shortcuts written to: $shortcutDir"
Write-Host ""
Write-Host "Suggested PowerToys Keyboard Manager remaps:"
Write-Host "  RightAlt+H  →  Ctrl+Alt+H   WM Move Left"
Write-Host "  RightAlt+J  →  Ctrl+Alt+J   WM Move Down"
Write-Host "  RightAlt+K  →  Ctrl+Alt+K   WM Move Up"
Write-Host "  RightAlt+L  →  Ctrl+Alt+L   WM Move Right"
Write-Host "  Alt+H       →  Ctrl+Alt+[   WM Focus Left"
Write-Host "  Alt+J       →  Ctrl+Alt+;   WM Focus Down"
Write-Host "  Alt+K       →  Ctrl+Alt+'   WM Focus Up"
Write-Host "  Alt+L       →  Ctrl+Alt+\   WM Focus Right"
Write-Host "  RightAlt+R  →  Ctrl+Alt+R   WM Retile"
Write-Host "  RightAlt+M  →  Ctrl+Alt+M   WM Monocle"
Write-Host ""
Write-Host "To start the daemon at login, copy 'WM Start Daemon.lnk' to:"
Write-Host "  $env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
