param(
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\MAME\roms",
    [int]$FinWait = 700,
    [int]$Ladder = -1,
    [switch]$Wav,
    [switch]$Ym
)
# Logs every sound command MK1 (MAME `mk`) sends through a 1P match - round
# start, FINISH HIM, round end - so its music sequencing can be read off.
# See tools/mk1_music_cmd_probe.lua.  -Wav also records the audio; -Ym logs
# every YM2151 register write to ym.log (hard cut vs fade at a music change).
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $ToolsDir "screens\mk1_music_cmd\run_$RunId"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Private = Join-Path $ToolsDir "mk1probe_state"
New-Item -ItemType Directory -Force -Path (Join-Path $Private "cfg")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Private "nvram") | Out-Null
$env:MK1P_OUT = $OutDir.Replace("\", "/")
$env:MK1P_FINWAIT = [string]$FinWait
$env:MK1P_YM = $(if ($Ym) { "1" } else { "" })
$env:MK1P_LADDER = $(if ($Ladder -ge 0) { [string]$Ladder } else { "" })
$mameArgs = @("mk", "-rompath", $RomPath, "-video", "none", "-nothrottle", "-skip_gameinfo",
    "-cfg_directory", (Join-Path $Private "cfg"), "-nvram_directory", (Join-Path $Private "nvram"),
    "-autoboot_script", (Join-Path $ToolsDir "mk1_music_cmd_probe.lua"), "-seconds_to_run", "1200")
if ($Wav) { $mameArgs += @("-wavwrite", (Join-Path $OutDir "mk1.wav")) } else { $mameArgs += @("-sound", "none") }
Write-Host "[mk1-music] $Mame -> $OutDir"
Push-Location $OutDir
try { & $Mame @mameArgs *> (Join-Path $OutDir "mame_out.log") } finally { Pop-Location }
$log = Join-Path $OutDir "cmds.log"
if (-not (Test-Path $log)) { throw "no cmds.log - the Lua never loaded; see mame_out.log" }
Get-Content $log
