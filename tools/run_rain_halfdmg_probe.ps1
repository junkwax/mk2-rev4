param(
    # a byte copy of mame.exe under another NAME, so this rig and any other
    # MAME sweep do not Stop-Process each other
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 320,
    # subzero | kitana | kang | cage | kunglao | jax | baraka | shang |
    # raiden | scorpion | reptile | mileena, or "all"
    [string]$Victim = "air",
    [int]$SnapEvery = 4,
    # the mk2.map that belongs to -RomPath's zip (a frozen pair); given, the
    # live-tree staleness check below is skipped
    [string]$Map = "",
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

# Source-built ROMs never match MAME's CRC table, so EVERY launch posts the red
# "press any key" box and MAME parks there at ~0% CPU until something answers
# it.  rawinput ignores synthetic keys, hence -keyboardprovider win32 below.
if (-not ("RnfWin" -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
public class RnfWin {
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    static void Press(IntPtr h, int vk) {
        PostMessage(h, 0x0100, (IntPtr)vk, IntPtr.Zero); Thread.Sleep(60);
        PostMessage(h, 0x0101, (IntPtr)vk, IntPtr.Zero);
    }
    static void Ch(IntPtr h, char c) { PostMessage(h, 0x0102, (IntPtr)c, IntPtr.Zero); }
    public static void DismissWarning(IntPtr h) {
        Press(h, 0x4F); Ch(h, 'o'); Thread.Sleep(80);
        Press(h, 0x4B); Ch(h, 'k'); Thread.Sleep(80);
        Press(h, 0x20); Thread.Sleep(60);
        Press(h, 0x0D);
    }
}
'@
}

# the lua holds the log open; Get-Content returns nothing on a locked file
function Read-RnfLog($path) {
    for ($i = 0; $i -lt 12; $i++) {
        try {
            $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            $sr = New-Object System.IO.StreamReader($fs)
            $x = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
            if ($x) { return ($x -split "`r?`n") }
        } catch { Start-Sleep -Milliseconds 250 }
    }
    return @()
}
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "rain_halfdmg_probe.lua"

$zip = Join-Path $RomPath "mk2.zip"
$out = Join-Path $Root "src\mk2.out"
if ((-not $Map) -and (Test-Path $zip) -and (Test-Path $out) -and ((Get-Item $zip).LastWriteTime -lt (Get-Item $out).LastWriteTime)) {
    Write-Host "[rnf] REFUSING: $zip is older than src\mk2.out - rebuild the ROMs first"
    exit 2
}

$victims = @("air")

$fails = 0
foreach ($v in $victims) {
    $log = Join-Path $ToolsDir "rain_halfdmg_probe.log"
    $snapDir = Join-Path $Root "tmp\rain_fatality\$v"
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $snapDir | Out-Null
    Get-ChildItem $snapDir -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force
    Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

    $env:MK2_ROOT = $Root.Replace("\", "/")
    $env:RH_LOG = $log
    if ($Map) { $env:RH_MAP = $Map } else { Remove-Item Env:\RH_MAP -ErrorAction SilentlyContinue }

    $mameArgs = @(
        "-rompath", $RomPath, "mk2",
        "-window", "-nomaximize", "-resolution", $Resolution,
        "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
        "-snapshot_directory", $snapDir,
        "-snapname", "%i",
        "-autoboot_script", $LuaScript,
        "-seconds_to_run", $BackstopEmuSeconds
    )
    if (-not $Sound) { $mameArgs += @("-sound", "none") }

    Write-Host "[rh] Rain: combo damage protection (rhhalf)"
    $mameOut = Join-Path $ToolsDir "rain_halfdmg_mame_out.log"
    $mameErr = Join-Path $ToolsDir "rain_halfdmg_mame_err.log"
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput $mameOut -RedirectStandardError $mameErr

    # answer the warning box until the lua says it is past the select screen
    $started = $false
    for ($i = 0; $i -lt 60 -and -not $proc.HasExited; $i++) {
        if ((Read-RnfLog $log) -match "select screen") { $started = $true; break }
        Start-Sleep -Milliseconds 700
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [RnfWin]::DismissWarning($proc.MainWindowHandle) }
        $proc.Refresh()
    }
    if (-not $started -and -not $proc.HasExited) {
        Write-Host "[rnf] never reached the select screen in ~40s - parked on the ROM warning box; killing."
        try { $proc.Kill() } catch {}
    }
    $proc.WaitForExit()
    foreach ($e in @("MK2_ROOT","RH_LOG","RH_MAP")) {
        Remove-Item "Env:\$e" -ErrorAction SilentlyContinue
    }

    if (Test-Path $log) {
        Read-RnfLog $log | Select-Object -Last 20
        $verdict = Read-RnfLog $log | Select-String '^\[rh\] (PASS|FAIL) combo damage' | Select-Object -Last 1
        if (-not $verdict) { Write-Host "[rnf] NO VERDICT for ${v} - see $mameOut"; $fails++ }
        elseif ($verdict.Line -notmatch 'PASS') { $fails++ }
    } else {
        Write-Host "[rnf] NO LOG for ${v} - MAME never started; see $mameOut"
        $fails++
    }
}

if ($fails -gt 0) { Write-Host "[rnf] $fails victim(s) FAILED"; exit 1 }
Write-Host "[rnf] all passed"
exit 0
