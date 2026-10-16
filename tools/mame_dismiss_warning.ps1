# Dismiss MAME's red "One or more ROMs/disk images for this system are
# incorrect - Press any key to continue" screen.
#
# This ALWAYS appears for mk2: the driver carries undumped PLDs, so
# rom_load raises a warning even though `mame -verifyroms mk2` reports the
# set as good. There is no -skip_warnings switch in this build (checked with
# -showusage), so the screen cannot be turned off - it can only be answered.
#
# It runs as its OWN PROCESS, deliberately. Doing this from inside the shell
# that launched MAME does not work: that shell starts MAME with redirected
# stdout/stderr (UseShellExecute = false) and never owns the foreground, so
# Windows refuses its SetForegroundWindow and MAME - on -keyboardprovider
# win32 - ignores the posted keys. A standalone poker process has always
# cleared the screen first try. Several in-process variants did not:
#   - a fixed burst of dismissals in the first seconds (missed a slow window)
#   - a CPU-activity "is it running yet" check (ROM loading reads as busy,
#     especially with -sound)
#   - re-resolving MainWindowHandle each pass (still the wrong process)
#
# Exits as soon as ReadyFile exists - the autoboot Lua script's log is a
# definitive "we are past the warning" signal - or when the timeout expires.

param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [string]$ReadyFile = "",
    [int]$TimeoutSec = 180
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class MameWarnPoke {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
'@

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    if ($ReadyFile -and (Test-Path -LiteralPath $ReadyFile)) { break }

    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { break }
    $p.Refresh()
    $h = $p.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        [void][MameWarnPoke]::SetForegroundWindow($h)
        Start-Sleep -Milliseconds 60
        foreach ($vk in 0x0D, 0x20) {
            # REAL key injection, not a posted message.  PostMessage is only
            # seen by -keyboardprovider win32; keybd_event goes in at the
            # driver level and every provider (win32, dinput, rawinput) sees
            # it, so this does not depend on which provider MAME picked.
            [MameWarnPoke]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 60
            [MameWarnPoke]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 120
            # ...and the posted message as well, for the case where MAME is
            # not actually foreground and keybd_event lands elsewhere.
            [void][MameWarnPoke]::PostMessage($h, 0x0100, [IntPtr]$vk, [IntPtr]::Zero)
            Start-Sleep -Milliseconds 80
            [void][MameWarnPoke]::PostMessage($h, 0x0101, [IntPtr]$vk, [IntPtr]::Zero)
        }
    }
    Start-Sleep -Milliseconds 500
}
