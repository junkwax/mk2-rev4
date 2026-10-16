param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Machine = "mk2",
    [string]$Resolution = "400x300",
    [string]$Video = "gdi",
    [string]$LuaScriptName = "kunglao_backfist_test.lua",
    [string]$LogPrefix = "kunglao_backfist",
    [string]$Tag = "hkbfist",
    [switch]$SkipStaticBlockCheck,
    [int]$TimeoutSeconds = 150
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$luaScript = Join-Path $PSScriptRoot $LuaScriptName
$logPath = Join-Path $PSScriptRoot "$($LogPrefix)_test.log"
$stdoutPath = Join-Path $PSScriptRoot "$($LogPrefix)_mame_stdout.log"
$stderrPath = Join-Path $PSScriptRoot "$($LogPrefix)_mame_stderr.log"
$snapRoot = Join-Path $repoRoot "snap"
$snapDir = Join-Path $snapRoot $Machine

New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue

if (-not ("KungLaoBackfistWinHelper" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class KungLaoBackfistWinHelper {
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

function Test-HkbfistStaticBlock {
    param([Parameter(Mandatory=$true)][string]$Path)

    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::new($Path)
    try {
        $x0 = [Math]::Max(0, [Math]::Floor($bmp.Width * 0.09))
        $x1 = [Math]::Min($bmp.Width - 1, [Math]::Floor($bmp.Width * 0.31))
        $y0 = [Math]::Max(0, [Math]::Floor($bmp.Height * 0.39))
        $y1 = [Math]::Min($bmp.Height - 1, [Math]::Floor($bmp.Height * 0.73))

        $cyanNoise = 0
        $total = 0
        for ($y = $y0; $y -le $y1; $y += 2) {
            for ($x = $x0; $x -le $x1; $x += 2) {
                $p = $bmp.GetPixel($x, $y)
                $total++
                if ($p.B -gt 120 -and $p.G -gt 85 -and $p.R -lt 95) {
                    $cyanNoise++
                }
            }
        }

        return ($total -gt 0 -and ($cyanNoise / $total) -gt 0.18)
    }
    finally {
        $bmp.Dispose()
    }
}

$before = @(Get-ChildItem -Path $snapDir -Filter "*.png" -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name)

$args = @(
    "-rompath", $RomPath,
    $Machine,
    "-window",
    "-nomaximize",
    "-resolution", $Resolution,
    "-video", $Video,
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-sound", "none",
    "-snapshot_directory", $snapRoot,
    "-autoboot_script", $luaScript
)

Write-Host "[$Tag-test] Launching MAME..."
$proc = Start-Process -FilePath $Mame `
    -WorkingDirectory (Split-Path -Parent $Mame) `
    -ArgumentList $args `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru

$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 400
    $hwnd = [KungLaoBackfistWinHelper]::FindWindowForPid($proc.Id)
    if ($hwnd -eq [IntPtr]::Zero) {
        $hwnd = [KungLaoBackfistWinHelper]::FindWindowContaining("Mortal Kombat II")
    }
    if ($hwnd -ne [IntPtr]::Zero) { break }
}

if ($hwnd -eq [IntPtr]::Zero) {
    Write-Warning "[$Tag-test] MAME window not found; warning dismissal may fail."
} else {
    Write-Host "[$Tag-test] Dismissing ROM warning..."
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 700
        [KungLaoBackfistWinHelper]::DismissMameWarning($hwnd)
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
        $done = Select-String -Path $logPath -Pattern "\[$Tag\] (finished|ERROR)" -Quiet
        if ($done) { break }
    }
}

if (-not $proc.HasExited) {
    Write-Host "[$Tag-test] Stopping MAME..."
    Stop-Process -Id $proc.Id -Force
}

if ($snap) {
    Write-Host "[$Tag-test] Snapshot: $snap"
} else {
    Write-Host "[$Tag-test] Snapshot: none"
}

$failed = $false

if (Test-Path $logPath) {
    Write-Host "[$Tag-test] Log tail:"
    Get-Content -Path $logPath -Tail 80

    $hasError = Select-String -Path $logPath -Pattern "\[$Tag\] ERROR" -Quiet
    $hasFinished = Select-String -Path $logPath -Pattern "\[$Tag\] finished" -Quiet
    if ($hasError) {
        Write-Error "[$Tag-test] Lua reported an error."
        $failed = $true
    }
    if (-not $hasFinished) {
        Write-Error "[$Tag-test] Lua did not reach its finished marker."
        $failed = $true
    }
} else {
    Write-Error "[$Tag-test] Lua log was not created. MAME probably failed before the autoboot script ran."
    $failed = $true
}

if (-not $snap) {
    Write-Error "[$Tag-test] No new screenshot was produced."
    $failed = $true
} elseif (-not $SkipStaticBlockCheck -and (Test-HkbfistStaticBlock -Path $snap)) {
    Write-Error "[$Tag-test] Screenshot contains the known HKBFIST static-block render failure."
    $failed = $true
}

if ($proc.ExitCode -ne 0) {
    Write-Error "[$Tag-test] MAME exited with code $($proc.ExitCode)."
    $failed = $true
}

$mameOutput = @()
if (Test-Path $stdoutPath) { $mameOutput += Get-Content -Path $stdoutPath }
if (Test-Path $stderrPath) { $mameOutput += Get-Content -Path $stderrPath }
if ($mameOutput -match "Fatal error|Unable to initialize|Unable to complete window creation") {
    Write-Error "[$Tag-test] MAME reported a startup/display failure."
    if (Test-Path $stderrPath) {
        Write-Host "[$Tag-test] MAME stderr tail:"
        Get-Content -Path $stderrPath -Tail 40
    }
    if (Test-Path $stdoutPath) {
        Write-Host "[$Tag-test] MAME stdout tail:"
        Get-Content -Path $stdoutPath -Tail 40
    }
    $failed = $true
}

if ($failed) {
    exit 1
}
