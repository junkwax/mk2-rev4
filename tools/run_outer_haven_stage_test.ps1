param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\MAME\roms",
    [string]$Machine = "mk2",
    [string]$Resolution = "320x200",
    [int]$TimeoutSeconds = 120,
    [switch]$Wait,
    [switch]$Hidden,
    [switch]$NoThrottle
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$luaScript = Join-Path $PSScriptRoot "outer_haven_stage_test.lua"
$outRoot = Join-Path $repoRoot "tmp\outerhaven_test"
$snapRoot = Join-Path $outRoot "snap"
$snapDir = Join-Path $snapRoot $Machine
$stdoutPath = Join-Path $outRoot "outer_haven_mame_stdout.log"
$stderrPath = Join-Path $outRoot "outer_haven_mame_stderr.log"

New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue

if (-not ("OuterHavenWinHelper" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class OuterHavenWinHelper {
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
        SetForegroundWindow(hWnd);
        keybd_event((byte)vk, 0, 0, UIntPtr.Zero);
        PostMessage(hWnd, WM_KEYDOWN, (IntPtr)vk, IntPtr.Zero);
        Thread.Sleep(80);
        keybd_event((byte)vk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        PostMessage(hWnd, WM_KEYUP, (IntPtr)vk, IntPtr.Zero);
    }

    public static void PressChar(IntPtr hWnd, char ch) {
        PostMessage(hWnd, WM_CHAR, (IntPtr)ch, IntPtr.Zero);
    }

    public static void DismissMameWarning(IntPtr hWnd) {
        PressVk(hWnd, 0x4F); PressChar(hWnd, 'o');
        Thread.Sleep(120);
        PressVk(hWnd, 0x4B); PressChar(hWnd, 'k');
        Thread.Sleep(120);
        PressVk(hWnd, 0x20);
        Thread.Sleep(80);
        PressVk(hWnd, 0x0D);
        Thread.Sleep(80);
        PressVk(hWnd, 0x25);
        Thread.Sleep(80);
        PressVk(hWnd, 0x27);
    }
}
'@ -ErrorAction Stop
}

$before = @(Get-ChildItem -Path $snapDir -Filter "*.png" -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name)

$args = @(
    "-rompath", $RomPath,
    $Machine,
    "-window",
    "-nomaximize",
    "-resolution", $Resolution,
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-sound", "none",
    "-snapshot_directory", $snapRoot,
    "-autoboot_script", $luaScript
)

if ($NoThrottle) {
    $args += "-nothrottle"
}

$startInfo = @{
    FilePath               = $Mame
    WorkingDirectory       = Split-Path -Parent $Mame
    ArgumentList           = $args
    RedirectStandardOutput = $stdoutPath
    RedirectStandardError  = $stderrPath
    PassThru               = $true
}

if ($Hidden) {
    $startInfo.WindowStyle = "Hidden"
}

Write-Host "[outerhaven-run] Launching MAME $Machine at $Resolution (hidden=$Hidden noThrottle=$NoThrottle)..."
$proc = Start-Process @startInfo

$hwnd = [IntPtr]::Zero
if (-not $Hidden) {
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 300
        $hwnd = [OuterHavenWinHelper]::FindWindowForPid($proc.Id)
        if ($hwnd -ne [IntPtr]::Zero) { break }
    }
    if ($hwnd -ne [IntPtr]::Zero) {
        for ($i = 0; $i -lt 8; $i++) {
            if ($proc.HasExited) { break }
            [OuterHavenWinHelper]::DismissMameWarning($hwnd)
            Start-Sleep -Milliseconds 500
        }
    } else {
        Write-Warning "[outerhaven-run] MAME window not found; warning dismissal skipped."
    }
}

if (-not $Wait) {
    Write-Host "[outerhaven-run] Background pid: $($proc.Id)"
    Write-Host "[outerhaven-run] Snapshots: $snapDir"
    return
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if ($proc.HasExited) { break }
}

if (-not $proc.HasExited) {
    Write-Host "[outerhaven-run] Timeout reached; stopping MAME pid $($proc.Id)."
    Stop-Process -Id $proc.Id -Force
}

$after = @(Get-ChildItem -Path $snapDir -Filter "*.png" -ErrorAction SilentlyContinue |
           Select-Object -ExpandProperty Name)
$new = @($after | Where-Object { $_ -notin $before })
if ($new.Count -gt 0) {
    $snap = Join-Path $snapDir ($new | Sort-Object | Select-Object -Last 1)
    Write-Host "[outerhaven-run] Snapshot: $snap"
} else {
    Write-Host "[outerhaven-run] Snapshot: none"
}

if (Test-Path $stdoutPath) {
    Write-Host "[outerhaven-run] stdout tail:"
    Get-Content -Path $stdoutPath -Tail 60
}
if (Test-Path $stderrPath) {
    $stderr = Get-Content -Path $stderrPath -ErrorAction SilentlyContinue
    if ($stderr) {
        Write-Host "[outerhaven-run] stderr tail:"
        $stderr | Select-Object -Last 60
    }
}
