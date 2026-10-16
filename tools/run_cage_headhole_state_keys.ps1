param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\MAME\roms",
    [string]$Machine = "mk2",
    [string]$StateDirectory = "C:\Users\you\sta",
    [string]$StateName = "quick",
    [string]$Resolution = "640x480",
    [int]$TimeoutSeconds = 25,
    [switch]$NoInput
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$snapRoot = Join-Path $repoRoot "snap"
$snapDir = Join-Path $snapRoot $Machine
$windowSnapDir = Join-Path $snapRoot "cage_headhole_state"
$cfgDir = Join-Path $repoRoot "tmp\mame_cfg_keyboard"
$stdoutPath = Join-Path $PSScriptRoot "cage_headhole_state_keys_stdout.log"
$stderrPath = Join-Path $PSScriptRoot "cage_headhole_state_keys_stderr.log"

New-Item -ItemType Directory -Force -Path $snapDir | Out-Null
New-Item -ItemType Directory -Force -Path $windowSnapDir | Out-Null
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue

if (-not ("CageHeadKeysWinHelper" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Drawing;
using System.Drawing.Imaging;

public static class CageHeadKeysWinHelper {
    const uint WM_KEYDOWN = 0x0100;
    const uint WM_KEYUP   = 0x0101;
    const uint WM_CHAR    = 0x0102;
    const uint KEYEVENTF_KEYUP = 0x0002;
    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    const uint SWP_NOMOVE = 0x0002;
    const uint SWP_NOSIZE = 0x0001;
    const uint SWP_SHOWWINDOW = 0x0040;

    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
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
        IntPtr largest = IntPtr.Zero;
        int largestArea = 0;
        EnumWindows((hWnd, _) => {
            if (!IsWindowVisible(hWnd)) return true;
            uint ownerPid;
            GetWindowThreadProcessId(hWnd, out ownerPid);
            if (ownerPid == (uint)pid) {
                RECT rect;
                int area = 0;
                if (GetWindowRect(hWnd, out rect)) {
                    int width = rect.Right - rect.Left;
                    int height = rect.Bottom - rect.Top;
                    if (width > 0 && height > 0) area = width * height;
                }
                if (area > largestArea) {
                    largestArea = area;
                    largest = hWnd;
                }
                StringBuilder title = new StringBuilder(512);
                GetWindowText(hWnd, title, title.Capacity);
                string text = title.ToString();
                if (area > 10000 && (text.Contains("Mortal Kombat") || text.Contains("MAME"))) {
                    found = hWnd;
                    return false;
                }
            }
            return true;
        }, IntPtr.Zero);
        return found != IntPtr.Zero ? found : largest;
    }

    public static string WindowInfo(IntPtr hWnd) {
        RECT rect;
        string size = "rect=na";
        if (GetWindowRect(hWnd, out rect)) {
            size = String.Format("rect={0},{1},{2},{3} size={4}x{5}",
                rect.Left, rect.Top, rect.Right, rect.Bottom,
                rect.Right - rect.Left, rect.Bottom - rect.Top);
        }
        return WindowTitle(hWnd) + " " + size;
    }

    public static string WindowTitle(IntPtr hWnd) {
        StringBuilder title = new StringBuilder(512);
        GetWindowText(hWnd, title, title.Capacity);
        return title.ToString();
    }

    public static void BringToFront(IntPtr hWnd) {
        ShowWindow(hWnd, 5);
        SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        SetForegroundWindow(hWnd);
        Thread.Sleep(120);
        SetWindowPos(hWnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        SetForegroundWindow(hWnd);
        Thread.Sleep(80);
    }

    public static void KeyDown(IntPtr hWnd, int vk) {
        SetForegroundWindow(hWnd);
        keybd_event((byte)vk, 0, 0, UIntPtr.Zero);
        PostMessage(hWnd, WM_KEYDOWN, (IntPtr)vk, IntPtr.Zero);
    }

    public static void KeyUp(IntPtr hWnd, int vk) {
        keybd_event((byte)vk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        PostMessage(hWnd, WM_KEYUP, (IntPtr)vk, IntPtr.Zero);
    }

    public static void Tap(IntPtr hWnd, int vk, int ms) {
        KeyDown(hWnd, vk);
        Thread.Sleep(ms);
        KeyUp(hWnd, vk);
        Thread.Sleep(80);
    }

    public static void PressChar(IntPtr hWnd, char ch) {
        PostMessage(hWnd, WM_CHAR, (IntPtr)ch, IntPtr.Zero);
    }

    public static void DismissWarning(IntPtr hWnd) {
        Tap(hWnd, 0x4F, 70); PressChar(hWnd, 'o');
        Thread.Sleep(100);
        Tap(hWnd, 0x4B, 70); PressChar(hWnd, 'k');
        Thread.Sleep(100);
        Tap(hWnd, 0x20, 80);
        Thread.Sleep(100);
        Tap(hWnd, 0x0D, 80);
    }

    public static bool CaptureWindow(IntPtr hWnd, string path) {
        BringToFront(hWnd);
        RECT rect;
        if (!GetWindowRect(hWnd, out rect)) return false;
        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0) return false;

        using (Bitmap bmp = new Bitmap(width, height)) {
            using (Graphics gfx = Graphics.FromImage(bmp)) {
                gfx.CopyFromScreen(rect.Left, rect.Top, 0, 0, new Size(width, height));
            }
            bmp.Save(path, ImageFormat.Png);
        }
        return true;
    }
}
'@ -ReferencedAssemblies "System.Drawing.dll" -ErrorAction Stop
}

function Save-MameWindow {
    param(
        [IntPtr]$Hwnd,
        [string]$Label
    )
    $safe = $Label -replace '[^A-Za-z0-9_.-]', '_'
    $path = Join-Path $windowSnapDir ("{0:yyyyMMdd_HHmmss_fff}_{1}.png" -f (Get-Date), $safe)
    $ok = [CageHeadKeysWinHelper]::CaptureWindow($Hwnd, $path)
    if ($ok) {
        Write-Host "[cage-headkeys] Window capture: $path"
    } else {
        Write-Warning "[cage-headkeys] Window capture failed: $Label"
    }
}

$args = @(
    "-rompath", $RomPath,
    $Machine,
    "-window",
    "-nomaximize",
    "-resolution", $Resolution,
    "-keyboardprovider", "win32",
    "-skip_gameinfo",
    "-sound", "none",
    "-cfg_directory", $cfgDir,
    "-state_directory", $StateDirectory,
    "-state", $StateName,
    "-snapshot_directory", $snapRoot
)

Write-Host "[cage-headkeys] Launching MAME with keyboard cfg and state '$StateName'..."
$proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) -ArgumentList $args -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $hwnd = [CageHeadKeysWinHelper]::FindWindowForPid($proc.Id)
    if ($hwnd -ne [IntPtr]::Zero) { break }
}

if ($hwnd -eq [IntPtr]::Zero) {
    Write-Warning "[cage-headkeys] MAME window not found."
} else {
    [CageHeadKeysWinHelper]::DismissWarning($hwnd)
    Start-Sleep -Milliseconds 250

    Write-Host "[cage-headkeys] Window found: $hwnd $([CageHeadKeysWinHelper]::WindowInfo($hwnd))"
    Start-Sleep -Milliseconds 80
    if ($proc.HasExited) {
        Write-Warning "[cage-headkeys] MAME exited before initial snapshot."
    } else {
        Write-Host "[cage-headkeys] Capture: initial"
        Save-MameWindow -Hwnd $hwnd -Label "initial"
    }

    Start-Sleep -Milliseconds 120
    if ($NoInput) {
        Write-Host "[cage-headkeys] Input skipped; capture-only mode."
    } elseif ($proc.HasExited) {
        Write-Warning "[cage-headkeys] MAME exited before input."
    } else {
        Write-Host "[cage-headkeys] Input: hold Block, Left, Right, Down+HP"
        [CageHeadKeysWinHelper]::KeyDown($hwnd, 0x20)   # Space = Button 3 / Block default
        Start-Sleep -Milliseconds 30
        [CageHeadKeysWinHelper]::Tap($hwnd, 0x25, 80)   # Left = Forward when Cage faces left
        [CageHeadKeysWinHelper]::Tap($hwnd, 0x27, 80)   # Right = Back when Cage faces left
        [CageHeadKeysWinHelper]::KeyDown($hwnd, 0x28)   # Down
        Start-Sleep -Milliseconds 60
        [CageHeadKeysWinHelper]::KeyDown($hwnd, 0xA2)   # Left Ctrl = Button 1 / HP default
        Start-Sleep -Milliseconds 180
        [CageHeadKeysWinHelper]::KeyUp($hwnd, 0xA2)
        [CageHeadKeysWinHelper]::KeyUp($hwnd, 0x28)
        Start-Sleep -Milliseconds 40
        [CageHeadKeysWinHelper]::KeyUp($hwnd, 0x20)
        Save-MameWindow -Hwnd $hwnd -Label "after_input"
    }

    $captureIndex = 0
    foreach ($delay in @(600, 900, 900, 1000, 1200, 1500)) {
        Start-Sleep -Milliseconds $delay
        if ($proc.HasExited) { break }
        $captureIndex += 1
        Write-Host "[cage-headkeys] Capture after ${delay}ms"
        Save-MameWindow -Hwnd $hwnd -Label ("step_{0}" -f $captureIndex)
    }
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
    Start-Sleep -Milliseconds 500
}
if (-not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force
}

Write-Host "[cage-headkeys] Window captures are in $windowSnapDir"
if (Test-Path $stderrPath) {
    Get-Content -Path $stderrPath -Tail 60
}
