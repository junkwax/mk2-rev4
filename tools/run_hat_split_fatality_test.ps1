param(
    # mame_mk2test.exe is a byte copy of mame.exe kept under a different NAME
    # so this rig and any other MAME sweep do not Stop-Process each other.
    # Two rigs at once kill the loser with exit -1 and a log that stops
    # mid-run, which reads exactly like the ROM crashing.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 400,

    [ValidateSet("subzero", "kitana", "both")]
    [string]$Victim = "subzero",

    # Stick holds to try, in ticks, one MAME run each: >0 Down (expects the
    # WAIST split), <0 Up (expects retail's NECK decap), 0 no steering (the
    # hat flies level at 92 px - the chest - so expects a CANCEL).  FINISH HIM is only ~110
    # ticks wide and hh_lp_open eats 030h of them holding LP, so a second
    # attempt does not fit inside one window: the sweep is across runs.
    [int[]]$Down = @(0, -2, 2, 3),
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
# MAME writes benign "WRONG CHECKSUMS" chatter to stderr for the crc_spoof'd
# ROMs (see mamerom.py); on pwsh 7.3+ that alone would be promoted to a
# terminating NativeCommandError.
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "hat_split_fatality_test.lua"

# Source-built ROMs never match MAME's CRC table, so EVERY launch posts the red
# "press any key to continue" box.  MAME then sits there at ~0% CPU forever,
# the autoboot script never gets a frame, and a plain WaitForExit burns the
# whole backstop producing nothing - which looks exactly like a slow run.
# rawinput ignores synthetic keys, hence -keyboardprovider win32 below.
if (-not ("HsfWin" -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
public class HsfWin {
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

# The lua holds the log open, and Get-Content returns NOTHING on a locked file
# with the error swallowed.
function Read-HsfLog($path) {
    for ($i = 0; $i -lt 12; $i++) {
        try {
            $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            $sr = New-Object System.IO.StreamReader($fs)
            $t = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
            if ($t) { return ($t -split "`r?`n") }
        } catch { Start-Sleep -Milliseconds 250 }
    }
    return @()
}

$victims = if ($Victim -eq "both") { @("subzero", "kitana") } else { @($Victim) }

foreach ($v in $victims) {
  foreach ($d in $Down) {
    $LogPath = Join-Path $ToolsDir "hat_split_fatality_${v}_d$d.log"
    $MameOut = Join-Path $ToolsDir "hat_split_fatality_mame_out_${v}_d$d.log"
    $MameErr = Join-Path $ToolsDir "hat_split_fatality_mame_err_${v}_d$d.log"
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    # A stranded instance from an earlier run blocks or confuses this one.
    Get-Process (Split-Path -Leaf $Mame).Replace(".exe", "") -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    # Leftover CMOS credits desync the scripted coin/start schedule.
    Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

    $env:MK2_ROOT = $Root
    $env:HSF_VICTIM = $v
    $env:HSF_DOWN = "$d"
    $env:HSF_LOG = $LogPath

    $mameArgs = @(
        "-rompath", $RomPath,
        "mk2",
        "-window", "-nomaximize",
        "-resolution", $Resolution,
        "-video", "gdi",
        "-keyboardprovider", "win32",
        "-skip_gameinfo",
        "-autoboot_script", $LuaScript,
        "-seconds_to_run", $BackstopEmuSeconds
    )
    if (-not $Sound) { $mameArgs += @("-sound", "none") }

    Write-Host "[hsf] $v, Down held $d tick(s) ..."
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput $MameOut -RedirectStandardError $MameErr

    $started = $false
    for ($i = 0; $i -lt 60 -and -not $proc.HasExited; $i++) {
        if ((Read-HsfLog $LogPath) -match "select screen") { $started = $true; break }
        Start-Sleep -Milliseconds 700
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [HsfWin]::DismissWarning($proc.MainWindowHandle) }
        $proc.Refresh()
    }
    if (-not $started -and -not $proc.HasExited) {
        Write-Host "  never reached the select screen in ~40s - parked on the ROM warning box."
        Write-Host "  killing rather than waiting out the ${BackstopEmuSeconds}s backstop."
        try { $proc.Kill() } catch {}
    }
    $proc.WaitForExit()

    foreach ($e in @("HSF_VICTIM", "HSF_DOWN", "HSF_LOG")) {
        Remove-Item "Env:\$e" -ErrorAction SilentlyContinue
    }

    if (Test-Path $LogPath) {
        Read-HsfLog $LogPath | Select-String 'WINDOW HIT|fatality started|RESULT|CANCELLED' |
            ForEach-Object { Write-Host $_.Line }
        $verdict = Read-HsfLog $LogPath | Select-String '^\[.*\] (PASS|FAIL)' | Select-Object -Last 1
        if ($verdict) { Write-Host $verdict.Line }
        else { Write-Host "[hsf/$v/d$d] NO VERDICT - check $LogPath and $MameOut" }
    } else {
        Write-Host "[hsf/$v/d$d] NO LOG - MAME never ran a frame; see $MameOut"
    }
  }
}
