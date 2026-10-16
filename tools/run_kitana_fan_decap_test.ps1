param(
    # mame_mk2test.exe is a byte copy of mame.exe kept under a different NAME
    # so this rig and any other MAME sweep do not Stop-Process each other.
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [int]$BackstopEmuSeconds = 400,

    # One MAME run per victim.  "all" is the twelve stock fighters Kitana can
    # meet in a FINISH HIM.
    [string[]]$Victim = @("subzero"),
    [int]$SnapEvery = 6,
    [switch]$Sound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "kitana_fan_decap_test.lua"

if ($Victim -contains "all") {
    $Victim = @("subzero", "kitana", "kang", "cage", "kunglao", "jax", "baraka",
                "shang", "raiden", "scorpion", "reptile", "mileena")
}

# Source-built ROMs never match MAME's CRC table, so every launch posts the red
# "press any key" box and MAME parks there at ~0% CPU.  rawinput ignores
# synthetic keys, hence -keyboardprovider win32 below.
if (-not ("KfdWin" -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
public class KfdWin {
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

# The lua holds the log open; Get-Content returns nothing on a locked file.
function Read-KfdLog($path) {
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

# rom/mk2.zip paired with another build's map reads every symbol at the wrong
# address and reports nothing useful.
$zip = Join-Path $RomPath "mk2.zip"
$out = Join-Path $Root "src\mk2.out"
if ((Test-Path $zip) -and (Test-Path $out) -and
    ((Get-Item $zip).LastWriteTime -lt (Get-Item $out).LastWriteTime.AddSeconds(-30))) {
    Write-Host "[kfd] REFUSING: $zip is older than src\mk2.out - repackage first (mamerom.py --no-install)."
    exit 2
}

$SnapRoot = Join-Path $Root "tmp\kitana_fan_decap"
$fails = 0
foreach ($v in $Victim) {
    $LogPath = Join-Path $ToolsDir "kitana_fan_decap_$v.log"
    $MameOut = Join-Path $ToolsDir "kitana_fan_decap_mame_out_$v.log"
    $MameErr = Join-Path $ToolsDir "kitana_fan_decap_mame_err_$v.log"
    $SnapDir = Join-Path $SnapRoot $v
    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $SnapDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $SnapDir | Out-Null
    Get-Process (Split-Path -Leaf $Mame).Replace(".exe", "") -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    # Leftover CMOS credits desync the scripted coin/start schedule.
    Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue

    $env:MK2_ROOT = $Root
    $env:KFD_VICTIM = $v
    $env:KFD_LOG = $LogPath
    $env:KFD_SNAP_EVERY = "$SnapEvery"

    $mameArgs = @(
        "-rompath", $RomPath,
        "mk2",
        "-window", "-nomaximize",
        "-resolution", $Resolution,
        "-video", "gdi",
        "-keyboardprovider", "win32",
        "-skip_gameinfo",
        "-snapshot_directory", $SnapDir,
        "-snapname", "%i",
        "-autoboot_script", $LuaScript,
        "-seconds_to_run", $BackstopEmuSeconds
    )
    if (-not $Sound) { $mameArgs += @("-sound", "none") }

    Write-Host "[kfd] $v ..."
    $proc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) `
        -ArgumentList $mameArgs -PassThru `
        -RedirectStandardOutput $MameOut -RedirectStandardError $MameErr

    $started = $false
    for ($i = 0; $i -lt 60 -and -not $proc.HasExited; $i++) {
        if ((Read-KfdLog $LogPath) -match "select screen") { $started = $true; break }
        Start-Sleep -Milliseconds 700
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [KfdWin]::DismissWarning($proc.MainWindowHandle) }
        $proc.Refresh()
    }
    if (-not $started -and -not $proc.HasExited) {
        Write-Host "  never reached the select screen in ~40s - parked on the ROM warning box; killing."
        try { $proc.Kill() } catch {}
    }
    $proc.WaitForExit()

    foreach ($e in @("KFD_VICTIM", "KFD_LOG", "KFD_SNAP_EVERY")) {
        Remove-Item "Env:\$e" -ErrorAction SilentlyContinue
    }

    if (Test-Path $LogPath) {
        Read-KfdLog $LogPath |
            Select-String 'fatality started|LANE|TOP |HEAD off|VICTIM drew|BLOOD' |
            ForEach-Object { Write-Host $_.Line }
        $verdict = Read-KfdLog $LogPath | Select-String '^\[.*\] (PASS|FAIL)' | Select-Object -Last 1
        if ($verdict) {
            Write-Host $verdict.Line
            if ($verdict.Line -match 'FAIL') { $fails++ }
        } else {
            Write-Host "[kfd/$v] NO VERDICT - check $LogPath and $MameOut"; $fails++
        }
    } else {
        Write-Host "[kfd/$v] NO LOG - MAME never ran a frame; see $MameOut"; $fails++
    }
    Write-Host "  snapshots: $SnapDir"
}
Write-Host "[kfd] $($Victim.Count - $fails)/$($Victim.Count) PASS"
if ($fails -gt 0) { exit 1 }
