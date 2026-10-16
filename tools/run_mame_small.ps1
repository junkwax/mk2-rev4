param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Machine = "mk2",
    [string]$Resolution = "640x480",
    [string]$Script = "",
    [switch]$Debug,
    [string]$DebugScript = "",
    [string]$SnapshotDirectory = "",
    [string]$OutputDirectory = "",
    [string]$State = "",
    [string]$StateDirectory = "",
    [string]$Video = "",
    [double]$Speed = 0,
    [int]$AutoCloseSeconds = 0,
    # 0 by default: C:\MAME\ui.ini has skip_warnings=1, so MAME never shows
    # the checksum-warning screen anymore and these synthetic keypresses
    # would land in the running game instead (flaky boots: phantom starts,
    # stalled character select). Pass a count only if skip_warnings is off.
    # Non-zero = dismiss MAME's ROM warning.  Defaults ON: every
    # source-built set trips that screen, and a run that sits on it
    # looks exactly like a slow boot.  Pass 0 to opt out.
    [int]$WarningDismissCount = 1,
    [int]$WarningDismissTimeoutSec = 120,
    [string]$ReadyFile = "",
    [switch]$Wait,
    [switch]$NoThrottle,
    [switch]$NoSound,
    # Anything else to hand MAME verbatim, e.g. @("-wavwrite","out.wav").
    [string[]]$ExtraArgs = @()
)

if (-not ("Mk2SmallMameWinHelper" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class Mk2SmallMameWinHelper {
    const uint WM_KEYDOWN = 0x0100;
    const uint WM_KEYUP   = 0x0101;
    const uint WM_CHAR    = 0x0102;
    const uint KEYEVENTF_KEYUP = 0x0002;

    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lp);

    public static IntPtr FindWindowForPid(int pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, _) => {
            if (!IsWindowVisible(hWnd)) return true;
            uint ownerPid;
            GetWindowThreadProcessId(hWnd, out ownerPid);
            if (ownerPid == (uint)pid) {
                found = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static void PressVk(IntPtr hWnd, int vk) {
        PostMessage(hWnd, WM_KEYDOWN, (IntPtr)vk, IntPtr.Zero);
        Thread.Sleep(80);
        PostMessage(hWnd, WM_KEYUP, (IntPtr)vk, IntPtr.Zero);
    }

    public static void PressChar(IntPtr hWnd, char ch) {
        PostMessage(hWnd, WM_CHAR, (IntPtr)ch, IntPtr.Zero);
    }

    public static void DismissWarning(IntPtr hWnd, bool withArrows) {
        // FOCUS FIRST.  With -keyboardprovider win32 MAME ignores posted key
        // messages unless its window is foreground; a manual poke that called
        // SetForegroundWindow worked every time while this routine, which did
        // not, stranded run after run on the red ROM warning.  keybd_event is
        // the belt-and-braces path - it injects at the system level into
        // whatever is foreground, which is now MAME.
        SetForegroundWindow(hWnd);
        Thread.Sleep(30);
        keybd_event(0x0D, 0, 0, UIntPtr.Zero);
        Thread.Sleep(30);
        keybd_event(0x0D, 0, 2, UIntPtr.Zero);
        PressVk(hWnd, 0x4F); PressChar(hWnd, 'o');
        Thread.Sleep(100);
        PressVk(hWnd, 0x4B); PressChar(hWnd, 'k');
        Thread.Sleep(100);
        PressVk(hWnd, 0x20);
        Thread.Sleep(60);
        PressVk(hWnd, 0x0D);
        if (!withArrows) return;
        Thread.Sleep(60);
        PressVk(hWnd, 0x25);
        Thread.Sleep(60);
        PressVk(hWnd, 0x27);
    }
}
'@ -ErrorAction Stop
}

$args = @(
    "-rompath", $RomPath,
    $Machine,
    "-window",
    "-nomaximize",
    "-resolution", $Resolution,
    "-keyboardprovider", "win32",
    "-skip_gameinfo"
)

if ($Script) {
    $args += @("-autoboot_script", $Script)
}

if ($Debug -or $DebugScript) {
    $args += "-debug"
}

if ($DebugScript) {
    $args += @("-debugscript", $DebugScript)
}

if ($SnapshotDirectory) {
    New-Item -ItemType Directory -Force -Path $SnapshotDirectory | Out-Null
    $args += @("-snapshot_directory", $SnapshotDirectory)
}

if ($StateDirectory) {
    New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null
    $args += @("-state_directory", $StateDirectory)
}

if ($State) {
    $args += @("-state", $State)
}

if ($Video) {
    $args += @("-video", $Video)
}

if ($Speed -gt 0) {
    $args += @("-speed", ([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:0.###}", $Speed)))
}

if ($NoThrottle) {
    $args += "-nothrottle"
}

if ($NoSound) {
    $args += @("-sound", "none")
}

if ($ExtraArgs -and $ExtraArgs.Count -gt 0) {
    $args += $ExtraArgs
}

Write-Host "[mame-small] Launching $Machine at $Resolution..."
$startInfo = @{
    FilePath         = $Mame
    WorkingDirectory = (Split-Path -Parent $Mame)
    ArgumentList     = $args
    PassThru         = $true
}

if ($OutputDirectory) {
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $startInfo.RedirectStandardOutput = Join-Path $OutputDirectory "mame_stdout.log"
    $startInfo.RedirectStandardError = Join-Path $OutputDirectory "mame_stderr.log"
}

$proc = Start-Process @startInfo

if ($WarningDismissCount -gt 0) {
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 400
        $hwnd = [Mk2SmallMameWinHelper]::FindWindowForPid($proc.Id)
        if ($hwnd -ne [IntPtr]::Zero) { break }
    }

    if ($hwnd -eq [IntPtr]::Zero) {
        Write-Warning "[mame-small] Window not found; warning dismissal skipped."
    } else {
        Write-Host "[mame-small] Dismissing warning/info screens..."

        # Source-built ROMs NEVER match MAME's CRC table, so the
        # "press any key to continue" warning is posted on EVERY run - it is
        # not an occasional thing to tolerate, it is guaranteed.
        #
        # This used to fire a fixed count of dismissals inside the first few
        # seconds. Miss that window - a slow window handle, a cold disk, a
        # machine under load - and MAME parks on the warning forever at ~0 CPU,
        # which is indistinguishable from "still booting" and hangs the whole
        # test. Seen repeatedly; one instance sat there 14 minutes.
        #
        # So keep posting until the emulation is demonstrably RUNNING. An
        # emulating MAME burns CPU continuously; one sitting on the warning
        # screen burns almost none. Stop as soon as it is clearly live, so the
        # dismissal keys are never delivered into the game itself.
        # Hand the job to a SEPARATE process - see the header of
        # tools/mame_dismiss_warning.ps1 for why doing it from in here can
        # never work.
        $poker = Join-Path $PSScriptRoot "mame_dismiss_warning.ps1"
        $pokerArgs = @("-ExecutionPolicy","Bypass","-File",$poker,
                       "-ProcessId",$proc.Id,"-TimeoutSec",$WarningDismissTimeoutSec)
        if ($ReadyFile) { $pokerArgs += @("-ReadyFile",$ReadyFile) }
        Start-Process -FilePath "powershell" -ArgumentList $pokerArgs -WindowStyle Hidden | Out-Null
        Write-Host "[mame-small] Warning dismisser launched."
    }
}

if ($AutoCloseSeconds -gt 0 -and -not $proc.HasExited) {
    Start-Sleep -Seconds $AutoCloseSeconds
    if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force
    }
}

if ($Wait -and -not $proc.HasExited) {
    Write-Host "[mame-small] Waiting for MAME to exit..."
    $proc.WaitForExit()
}
