param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Machine = "mk2",
    [string]$StateDirectory = "C:\Users\you\sta",
    [string]$StateName = "quick",
    [string]$Resolution = "640x480",
    [int]$TimeoutSeconds = 60
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$luaScript = Join-Path $PSScriptRoot "cage_headhole_state_test.lua"
$logPath = Join-Path $PSScriptRoot "cage_headhole_state_test.log"
$stdoutPath = Join-Path $PSScriptRoot "cage_headhole_state_mame_stdout.log"
$stderrPath = Join-Path $PSScriptRoot "cage_headhole_state_mame_stderr.log"
$snapRoot = Join-Path $repoRoot "snap"
$snapDir = Join-Path $snapRoot $Machine

New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue

if (-not ("CageHeadholeWinHelper" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class CageHeadholeWinHelper {
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
    "-state_directory", $StateDirectory,
    "-state", $StateName,
    "-snapshot_directory", $snapRoot,
    "-autoboot_delay", "2",
    "-autoboot_script", $luaScript
)

Write-Host "[cage-headhole] Launching MAME with state '$StateName' from $StateDirectory..."
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) -ArgumentList $args -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 400
    $hwnd = [CageHeadholeWinHelper]::FindWindowForPid($proc.Id)
    if ($hwnd -ne [IntPtr]::Zero) { break }
}

if ($hwnd -ne [IntPtr]::Zero) {
    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Milliseconds 600
        [CageHeadholeWinHelper]::DismissMameWarning($hwnd)
        if ($proc.HasExited) { break }
        if (Test-Path $logPath) { break }
    }
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    if ($proc.HasExited) { break }
    if (Test-Path $logPath) {
        if (Select-String -Path $logPath -Pattern "\[cage-headhole\] (finished|ERROR)" -Quiet) {
            break
        }
    }
}

if (-not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force
}

$after = @(Get-ChildItem -Path $snapDir -Filter "*.png" -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name)
$new = $after | Where-Object { $_ -notin $before } | Sort-Object

if (Test-Path $logPath) {
    Get-Content -Path $logPath -Tail 40
} else {
    Write-Warning "[cage-headhole] Lua log was not created."
    if (Test-Path $stdoutPath) {
        Write-Host "[cage-headhole] MAME stdout tail:"
        Get-Content -Path $stdoutPath -Tail 80
    }
    if (Test-Path $stderrPath) {
        Write-Host "[cage-headhole] MAME stderr tail:"
        Get-Content -Path $stderrPath -Tail 80
    }
}

if ($new) {
    Write-Host "[cage-headhole] New snapshots:"
    foreach ($name in $new) {
        Write-Host "  $(Join-Path $snapDir $name)"
    }
} else {
    Write-Warning "[cage-headhole] No new snapshots were created."
}
