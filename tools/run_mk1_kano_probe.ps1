param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\MAME\roms",
    [switch]$TwoPlayer,
    [switch]$KO,
    [switch]$Win,
    [switch]$Heart,
    [switch]$Moves2,
    [switch]$BallTest,
    [switch]$Swept,
    [switch]$Jumps,
    [int]$GetHit = 0,
    [int]$BallHold = 0,
    [string]$Tag = ""
)
# MK1's Kano in MAME `mk`: his sound commands, the OKI phrases they play (dumped
# raw), and every blit with its palette.  See tools/mk1_kano_probe.lua.
$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$OutDir = Join-Path $Root "tmp\mk1kano_probe$Tag"
if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Private = Join-Path $ToolsDir "mk1probe_state"
New-Item -ItemType Directory -Force -Path (Join-Path $Private "cfg")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Private "nvram") | Out-Null
$env:MK1K_JUMPS = $(if ($Jumps) { "1" } else { "" })
$env:MK1K_SWEPT = $(if ($Swept) { "1" } else { "" })
$env:MK1K_BALLTEST = $(if ($BallTest) { "1" } else { "" })
$env:MK1K_BALLHOLD = $(if ($BallHold) { "$BallHold" } else { "" })
$env:MK1K_MOVES2 = $(if ($Moves2) { "1" } else { "" })
$env:MK1K_HEART = $(if ($Heart) { "1" } else { "" })
$env:MK1K_WIN = $(if ($Win) { "1" } else { "" })
$env:MK1K_KO = $(if ($KO) { "1" } else { "" })
$env:MK1K_GETHIT = $(if ($GetHit) { "$GetHit" } else { "" })
$env:MK1K_2P = $(if ($TwoPlayer) { "1" } else { "" })
$env:MK1K_OUT = $OutDir.Replace("\", "/") + "/"
$mameArgs = @("mk", "-rompath", $RomPath, "-video", "none", "-nothrottle", "-skip_gameinfo",
    "-sound", "none", "-cfg_directory", (Join-Path $Private "cfg"),
    "-nvram_directory", (Join-Path $Private "nvram"),
    "-snapshot_directory", $OutDir,
    "-autoboot_script", (Join-Path $ToolsDir "mk1_kano_probe.lua"), "-seconds_to_run", "900")
Push-Location $OutDir
try { & $Mame @mameArgs *> (Join-Path $OutDir "mame_out.log") } finally { Pop-Location }
if (-not (Test-Path (Join-Path $OutDir "kano.log"))) { throw "no kano.log - see mame_out.log" }
Write-Host "[mk1-kano] $OutDir"
