# test_pit.ps1 - automated KFPITPL live MAME verification
#
# Responsibilities:
#   Lua script: force/hold the Pit stage, dump runtime state, take snapshot.
#   This wrapper: launch MAME, dismiss pre-boot ROM warnings, optionally record
#                 the MAME window with ffmpeg, stop once a fresh snapshot exists.
#
# Run from repo root:
#   .\tools\test_pit.ps1
#   .\tools\test_pit.ps1 -Record
#   .\tools\test_pit.ps1 -SnapOnly
#   .\tools\test_pit.ps1 -NoCompare

param(
    [switch]$SnapOnly,
    [switch]$Record,
    [switch]$NoCompare,
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\MAME\roms",
    [string]$Machine = "mk2",
    [string]$Ffmpeg = "ffmpeg",
    [string]$BddToolRoot = "",
    [string]$Expected = "",
    [int]$RecordFps = 30,
    [int]$TimeoutSeconds = 130
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$luaScript = Join-Path $PSScriptRoot "kfpitpl_test.lua"
$outDir = Join-Path $repoRoot "tmp\kfpitpl_mame"
$snapDir = Join-Path $outDir "snap"
$videoDir = Join-Path $outDir "video"
$logDir = Join-Path $outDir "log"
$compareDir = Join-Path $outDir "compare"

if (-not $BddToolRoot) {
    $BddToolRoot = Join-Path (Split-Path -Parent $repoRoot) "midway-bddtool"
}
if (-not $Expected) {
    $Expected = Join-Path $repoRoot "tmp\kfpitpl_validate\kfpitpl_expected_worldx0.png"
}
$compareTool = Join-Path $BddToolRoot "tools\check_mame_screenshot.py"

New-Item -ItemType Directory -Force -Path $snapDir, $videoDir, $logDir, $compareDir | Out-Null

if ($SnapOnly) {
    $snap = Get-ChildItem $snapDir -Filter "*.png" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime |
            Select-Object -Last 1
    if ($snap) { Start-Process $snap.FullName }
    else { Write-Host "No snapshots in $snapDir" }
    exit
}

foreach ($p in @($Mame, $luaScript)) {
    if (-not (Test-Path $p)) {
        Write-Error "Not found: $p"
        exit 1
    }
}

if ($Record) {
    $ffmpegCmd = Get-Command $Ffmpeg -ErrorAction SilentlyContinue
    if (-not $ffmpegCmd) {
        Write-Error "ffmpeg not found. Pass -Ffmpeg C:\path\to\ffmpeg.exe or add it to PATH."
        exit 1
    }
}

function Invoke-KfpitplCompare {
    param(
        [string]$SnapshotPath,
        [string]$ExpectedPath,
        [string]$ToolPath,
        [string]$OutputDir
    )

    if (-not (Test-Path $ToolPath)) {
        Write-Warning "[test_pit] Compare skipped; not found: $ToolPath"
        return
    }
    if (-not (Test-Path $ExpectedPath)) {
        Write-Warning "[test_pit] Compare skipped; expected render not found: $ExpectedPath"
        Write-Warning "[test_pit] Run: python tools\validate_kfpitpl.py"
        return
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($SnapshotPath)
    $actualOut = Join-Path $OutputDir "$base.actual.png"
    $diffOut = Join-Path $OutputDir "$base.diff.png"
    $args = @(
        $ToolPath,
        $SnapshotPath,
        "--expected", $ExpectedPath,
        "--crop", "0,0,400,254",
        "--mask-top", "55",
        "--mask-rect", "0,75,225,135",
        "--mask-rect", "245,35,105,95",
        "--actual-output", $actualOut,
        "--diff-output", $diffOut
    )

    Write-Host "[test_pit] Comparing snapshot against expected Pit render..."
    $output = & python @args 2>&1
    foreach ($line in $output) {
        Write-Host "[test_pit] compare: $line"
    }
    Write-Host "[test_pit] Compare actual: $actualOut"
    Write-Host "[test_pit] Compare diff:   $diffOut"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[test_pit] Render compare FAIL."
    } else {
        Write-Host "[test_pit] Render compare PASS."
    }
}

if (-not ("WinHelper" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class WinHelper {
    const uint WM_KEYDOWN = 0x0100;
    const uint WM_KEYUP   = 0x0101;
    const uint WM_CHAR    = 0x0102;
    const uint KEYEVENTF_KEYUP = 0x0002;

    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

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

    public static int[] GetRectArray(IntPtr hWnd) {
        RECT r;
        if (!GetWindowRect(hWnd, out r)) return new int[] {0, 0, 0, 0};
        return new int[] {r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top};
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

    public static void TypeOk(IntPtr hWnd) {
        PressVk(hWnd, 0x4F); // O
        PressChar(hWnd, 'o');
        Thread.Sleep(120);
        PressVk(hWnd, 0x4B); // K
        PressChar(hWnd, 'k');
    }

    public static void DismissMameWarning(IntPtr hWnd) {
        // MAME's incorrect-ROM warning wants "OK". Some other info screens
        // accept Space/Enter or joystick left/right, so send all harmless forms.
        TypeOk(hWnd);
        Thread.Sleep(120);
        PressVk(hWnd, 0x20); // Space
        Thread.Sleep(80);
        PressVk(hWnd, 0x0D); // Enter
        Thread.Sleep(80);
        PressVk(hWnd, 0x25); // Left
        Thread.Sleep(80);
        PressVk(hWnd, 0x27); // Right
    }
}
'@ -ErrorAction Stop
}

function Start-FfmpegWindowRecord {
    param(
        [string]$Exe,
        [IntPtr]$Hwnd,
        [string]$Output,
        [int]$Fps
    )

    $rect = [WinHelper]::GetRectArray($Hwnd)
    $x = [Math]::Max(0, $rect[0])
    $y = [Math]::Max(0, $rect[1])
    $w = [Math]::Max(16, $rect[2])
    $h = [Math]::Max(16, $rect[3])
    if (($w % 2) -ne 0) { $w -= 1 }
    if (($h % 2) -ne 0) { $h -= 1 }

    Write-Host "[test_pit] Recording MAME window ${w}x${h}+${x},${y} -> $Output"
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    foreach ($arg in @(
        "-y",
        "-hide_banner",
        "-loglevel", "warning",
        "-f", "gdigrab",
        "-framerate", "$Fps",
        "-offset_x", "$x",
        "-offset_y", "$y",
        "-video_size", "${w}x${h}",
        "-i", "desktop",
        "-c:v", "libx264",
        "-preset", "ultrafast",
        "-pix_fmt", "yuv420p",
        $Output
    )) {
        [void]$psi.ArgumentList.Add($arg)
    }
    return [System.Diagnostics.Process]::Start($psi)
}

function Stop-FfmpegRecord {
    param($Proc)
    if (-not $Proc) { return }
    if ($Proc.HasExited) { return }
    try {
        $Proc.StandardInput.WriteLine("q")
        if (-not $Proc.WaitForExit(5000)) {
            $Proc.Kill()
            $Proc.WaitForExit()
        }
    } catch {
        if (-not $Proc.HasExited) {
            $Proc.Kill()
            $Proc.WaitForExit()
        }
    }
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$stdoutLog = Join-Path $logDir "mame_$stamp.stdout.log"
$stderrLog = Join-Path $logDir "mame_$stamp.stderr.log"
$videoPath = Join-Path $videoDir "kfpitpl_$stamp.mp4"

$before = @(Get-ChildItem $snapDir -Filter "*.png" -ErrorAction SilentlyContinue |
             Select-Object -ExpandProperty Name)

$mameArgs = @(
    $Machine,
    "-rompath", "`"$RomPath`"",
    "-script", "`"$luaScript`"",
    "-window",
    "-nomaximize",
    "-resolution", "800x600",
    "-video", "gdi",
    "-sound", "none",
    "-skip_gameinfo",
    "-keyboardprovider", "win32",
    "-snapshot_directory", "`"$snapDir`"",
    "-snapname", "kfpitpl_%i",
    "-snapview", "native",
    "-snapsize", "auto"
)

Write-Host "[test_pit] Launching MAME..."
$proc = Start-Process -FilePath $Mame `
    -ArgumentList $mameArgs `
    -WorkingDirectory (Split-Path -Parent $Mame) `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -PassThru

$ffmpegProc = $null
$snap = $null

try {
    Write-Host "[test_pit] Waiting for MAME window..."
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $hwnd = [WinHelper]::FindWindowForPid($proc.Id)
        if ($hwnd -eq [IntPtr]::Zero) {
            $hwnd = [WinHelper]::FindWindowContaining("Mortal Kombat II")
        }
        if ($hwnd -ne [IntPtr]::Zero) {
            Write-Host "[test_pit] Window found (handle=$hwnd)"
            break
        }
    }
    if ($hwnd -eq [IntPtr]::Zero) {
        Write-Warning "[test_pit] MAME window not found; input/recording may not land"
    } elseif ($Record) {
        $ffmpegProc = Start-FfmpegWindowRecord -Exe $ffmpegCmd.Source -Hwnd $hwnd -Output $videoPath -Fps $RecordFps
        Start-Sleep -Milliseconds 500
    }

    Write-Host "[test_pit] Sending OK/Space/Enter/Left/Right to dismiss ROM warning (8 attempts)..."
    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Seconds 1
        if ($hwnd -ne [IntPtr]::Zero) {
            [WinHelper]::SetForegroundWindow($hwnd) | Out-Null
            [WinHelper]::DismissMameWarning($hwnd)
        }
    }
    Write-Host "[test_pit] Dismissal sent."
    Write-Host "[test_pit] Lua uses KFPITPL worldx=0 and its configured snapshot frame."

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if ($proc.HasExited) {
            Write-Host "[test_pit] MAME exited on its own."
            break
        }
        $after = @(Get-ChildItem $snapDir -Filter "*.png" -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Name)
        $new = $after | Where-Object { $_ -notin $before }
        if ($new) {
            $snap = Join-Path $snapDir ($new | Sort-Object | Select-Object -Last 1)
            Write-Host "[test_pit] Snapshot detected."
            break
        }
    }
}
finally {
    Stop-FfmpegRecord $ffmpegProc
    if (-not $proc.HasExited) {
        Write-Host "[test_pit] Stopping MAME..."
        $proc.Kill()
        $proc.WaitForExit()
    }
}

if ($snap) {
    Write-Host "[test_pit] Snapshot saved: $snap"
    if (-not $NoCompare) {
        Invoke-KfpitplCompare -SnapshotPath $snap -ExpectedPath $Expected -ToolPath $compareTool -OutputDir $compareDir
    }
    Start-Process $snap
} else {
    Write-Warning "[test_pit] No snapshot within timeout. Check logs under $logDir"
}

if ($Record) {
    if (Test-Path $videoPath) {
        Write-Host "[test_pit] Recording saved: $videoPath"
    } else {
        Write-Warning "[test_pit] Recording was requested, but no video file was created."
    }
}
Write-Host "[test_pit] MAME stdout: $stdoutLog"
Write-Host "[test_pit] MAME stderr: $stderrLog"
