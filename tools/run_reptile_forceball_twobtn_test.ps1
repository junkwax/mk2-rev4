param(
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string]$Resolution = "640x480",
    [ValidateSet("slow","fast")]
    [string]$Mode = "slow",
    [switch]$NoStray,
    [int]$Trials = 8
)

# Regression test for the rp_lo_punch two-button check fix (MOVES.ASM,
# tools/reptile_forceball_twobtn_test.lua for the full rationale).
#
# The dismissal poke lives INLINE here rather than as a separate
# mame_dismiss_warning.ps1 process: that script exits as soon as its
# ReadyFile exists, but reptile_forceball_twobtn_test.lua opens its log file
# at script load - before the ROM warning screen even appears - so the
# separate-process poker was observed to exit having never sent a key,
# leaving MAME parked indefinitely. Polling for the actual "[tb] finished"
# marker in the log (not just its existence) avoids that race.

$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$LuaScript = Join-Path $ToolsDir "reptile_forceball_twobtn_test.lua"
$StrayTag = if ($NoStray) { "nostray" } else { "stray" }
$Tag = "${Mode}_${StrayTag}"
$LogPath = Join-Path $ToolsDir "reptile_forceball_twobtn_$Tag.log"

Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
$NvramDir = Join-Path $ToolsDir "nvram_forceball_twobtn_$Tag"
Remove-Item -LiteralPath $NvramDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $NvramDir | Out-Null

$MameName = [IO.Path]::GetFileNameWithoutExtension($Mame)
Get-Process -Name $MameName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

$env:MK2_TB_ROOT = $Root
$env:MK2_TB_LOG = $LogPath
$env:MK2_TB_MODE = $Mode
$env:MK2_TB_STRAY = if ($NoStray) { "0" } else { "1" }
$env:MK2_TB_TRIALS = [string]$Trials

$mameArgs = @(
    "-rompath", $RomPath, "mk2",
    "-window", "-nomaximize", "-resolution", $Resolution,
    "-video", "gdi", "-keyboardprovider", "win32", "-skip_gameinfo",
    "-autoboot_script", $LuaScript,
    "-nvram_directory", $NvramDir,
    "-sound", "none",
    "-seconds_to_run", 300
)

Write-Host "[tb] launching Reptile two-button regression test (mode=$Mode stray=$(-not $NoStray))..."
$mameProc = Start-Process -FilePath $Mame -WorkingDirectory (Split-Path -Parent $Mame) -ArgumentList $mameArgs -PassThru `
    -RedirectStandardOutput (Join-Path $ToolsDir "reptile_forceball_twobtn_${Tag}_out.log") `
    -RedirectStandardError  (Join-Path $ToolsDir "reptile_forceball_twobtn_${Tag}_err.log")

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class MameWarnPokeTB {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
'@

$deadline = (Get-Date).AddSeconds(120)
$done = $false
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $LogPath) {
        $content = Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue
        if ($content -and ($content -match "\[tb\] finished")) { $done = $true; break }
    }
    $p = Get-Process -Id $mameProc.Id -ErrorAction SilentlyContinue
    if (-not $p) { break }
    $p.Refresh()
    $h = $p.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        [void][MameWarnPokeTB]::SetForegroundWindow($h)
        foreach ($vk in 0x0D, 0x20) {
            [MameWarnPokeTB]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 40
            [MameWarnPokeTB]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero)
            [void][MameWarnPokeTB]::PostMessage($h, 0x0100, [IntPtr]$vk, [IntPtr]::Zero)
            Start-Sleep -Milliseconds 40
            [void][MameWarnPokeTB]::PostMessage($h, 0x0101, [IntPtr]$vk, [IntPtr]::Zero)
        }
    }
    Start-Sleep -Milliseconds 700
}
Start-Sleep -Seconds 2
Get-Process -Name $MameName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Remove-Item Env:MK2_TB_ROOT, Env:MK2_TB_LOG, Env:MK2_TB_MODE, Env:MK2_TB_STRAY, Env:MK2_TB_TRIALS -ErrorAction SilentlyContinue

if (-not (Test-Path $LogPath)) { Write-Error "[tb] FAILED (no log created)"; exit 1 }
Get-Content -Path $LogPath | Select-Object -Last 30

if (-not $done) { Write-Error "[tb] FAILED - never saw '[tb] finished' (MAME likely parked on the ROM warning screen)"; exit 1 }
if (-not (Select-String -Path $LogPath -Pattern "\[tb\] PASS" -Quiet)) {
    Write-Error "[tb] FAILED - see the report above"
    exit 1
}
