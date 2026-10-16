param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Machine = "mk2",
    [string]$Resolution = "640x480",
    [int]$TimeoutSeconds = 150,
    [switch]$NoP2Block,
    [switch]$ForceMiss
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$luaScript = Join-Path $PSScriptRoot "baraka_heliport_test.lua"
$logPath = Join-Path $PSScriptRoot "baraka_heliport_test.log"
$snapRoot = Join-Path $repoRoot "snap"
$snapDir = Join-Path $snapRoot $Machine

New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

if (-not ("BarakaHeliportWinHelper" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class BarakaHeliportWinHelper {
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

    public static IntPtr FindWindowContaining(string fragment) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, _) => {
            if (!IsWindowVisible(hWnd)) return true;
            var sb = new StringBuilder(512);
            GetWindowText(hWnd, sb, 512);
            if (sb.ToString().IndexOf(fragment, StringComparison.OrdinalIgnoreCase) >= 0) {
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

Write-Host "[baraka-test] Launching MAME..."
$oldP2Block = $env:BARAKA_HELIPORT_P2_BLOCK
$oldForceMiss = $env:BARAKA_HELIPORT_FORCE_MISS
if ($NoP2Block) {
    $env:BARAKA_HELIPORT_P2_BLOCK = "0"
} else {
    $env:BARAKA_HELIPORT_P2_BLOCK = "1"
}
if ($ForceMiss) {
    $env:BARAKA_HELIPORT_FORCE_MISS = "1"
} else {
    $env:BARAKA_HELIPORT_FORCE_MISS = "0"
}
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) -ArgumentList $args -PassThru
if ($null -eq $oldP2Block) {
    Remove-Item Env:\BARAKA_HELIPORT_P2_BLOCK -ErrorAction SilentlyContinue
} else {
    $env:BARAKA_HELIPORT_P2_BLOCK = $oldP2Block
}
if ($null -eq $oldForceMiss) {
    Remove-Item Env:\BARAKA_HELIPORT_FORCE_MISS -ErrorAction SilentlyContinue
} else {
    $env:BARAKA_HELIPORT_FORCE_MISS = $oldForceMiss
}

$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 400
    $hwnd = [BarakaHeliportWinHelper]::FindWindowForPid($proc.Id)
    if ($hwnd -eq [IntPtr]::Zero) {
        $hwnd = [BarakaHeliportWinHelper]::FindWindowContaining("Mortal Kombat II")
    }
    if ($hwnd -ne [IntPtr]::Zero) { break }
}

if ($hwnd -eq [IntPtr]::Zero) {
    Write-Warning "[baraka-test] MAME window not found; warning dismissal may fail."
} else {
    Write-Host "[baraka-test] Dismissing ROM warning..."
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 700
        [BarakaHeliportWinHelper]::DismissMameWarning($hwnd)
        if ($proc.HasExited) { break }
        if (Test-Path $logPath) { break }
    }
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$snap = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if ($proc.HasExited) { break }
    $after = @(Get-ChildItem -Path $snapDir -Filter "*.png" -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Name)
    $new = $after | Where-Object { $_ -notin $before }
    if ($new) {
        $snap = Join-Path $snapDir ($new | Sort-Object | Select-Object -Last 1)
    }
    if (Test-Path $logPath) {
        $done = Select-String -Path $logPath -Pattern "\[baraka\] (finished|ERROR)" -Quiet
        if ($done) { break }
    }
}

if (-not $proc.HasExited) {
    Write-Host "[baraka-test] Stopping MAME..."
    Stop-Process -Id $proc.Id -Force
}

if ($snap) {
    Write-Host "[baraka-test] Snapshot: $snap"
} else {
    Write-Host "[baraka-test] Snapshot: none"
}

if (Test-Path $logPath) {
    Write-Host "[baraka-test] Log tail:"
    Get-Content -Path $logPath -Tail 80
} else {
    Write-Warning "[baraka-test] Lua log was not created."
}
