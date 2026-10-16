param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$BackstopEmuSeconds = 200,
    [int]$Snap = 8,
    [int]$Dist = 130,
    [ValidateSet("left","right")][string]$Side = "left",
    # Who gets slammed.  Jax is every historical run of this rig; reptile and
    # noob are the OFF-COLOUR BLEEDERS, and the only way to see whether the
    # burst takes their blood colour (bldxpd_blood_pal, MKBLOOD.ASM) - this
    # fatality is the only thing in the game that draws BLDXPD1-13.
    [string]$Victim = "jax",
    [switch]$Pit,
    [switch]$Reptile,
    [switch]$Trace,
    [switch]$Sound
)
# Ermac's telekinetic slam FATALITY - Down, Up, Down, Down, Down + BLOCK.
# See tools/ermac_fatal_slam_test.lua for what each measured value means.
#
# mame_mk2test.exe, not mame.exe: two MAME rigs sharing one binary kill each
# other's cfg/nvram and the failure looks like a crash mid-log
# (reference_mame_rig_contention).
$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "ermac_fatal_slam_test.lua"
$LogPath = Join-Path $ToolsDir "ermac_fatal_slam_test.log"
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
$env:MK2_ROOT = $Root
$env:EFS_LOG = $LogPath
$env:EFS_SNAP = [string]$Snap
$env:EFS_DIST = [string]$Dist
$env:EFS_SIDE = $Side
$env:EFS_VICTIM = $Victim
$env:EFS_PIT = $(if ($Pit) { "1" } else { "0" })
$env:EFS_REPTILE = $(if ($Reptile) { "1" } else { "0" })
$env:EFS_TRACE = $(if ($Trace) { "1" } else { "0" })
# A PRIVATE cfg directory, and it is not optional.  MAME writes cfg/mk2.cfg on
# exit; a rig that holds inputs down at the backstop can leave one that makes
# the NEXT boot come up somewhere else entirely (the TEST-switch trap in
# reference_mame_repo_cwd_cfg_trap), and the symptom is "MAME never started"
# with a clean ROM and a clean script.  Cost a full debugging detour once.
$CfgDir = Join-Path $ToolsDir "_rigcfg"
New-Item -ItemType Directory -Force -Path $CfgDir | Out-Null
Remove-Item (Join-Path $CfgDir "mk2.cfg") -Force -ErrorAction SilentlyContinue
$args2 = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
           "-video","gdi","-keyboardprovider","win32","-skip_gameinfo",
           "-cfg_directory",$CfgDir,
           "-autoboot_script",$Lua,"-seconds_to_run",$BackstopEmuSeconds)
if (-not $Sound) { $args2 += @("-sound","none") }
# -Trace: MAME -debug so the rig can breakpoint the illegal-opcode trap
if ($Trace) {
  # illegal_opcode moves with every build - read it out of the map
  $ill = (Select-String -Path (Join-Path $Root "src\mk2.map") -Pattern "^([0-9a-f]{8})\s+illegal_opcode\b" | Select-Object -First 1).Matches[0].Groups[1].Value
  $ds = Join-Path ([IO.Path]::GetTempPath()) "mk2_ermac_trap.ds"   # generated - keep it out of the tree
  $bp = 'bpset ' + $ill + ',1,{printf "TRAP a13=%08X a12=%08X a7=%08X sp=%08X",a13,a12,a7,sp; history ,200; g}'
  # system_lockup parks its caller's return address in B14 before it jumps to
  # recovery (`jauc $`, illegal_opcode+50h), so B14 at recovery names the caller.
  $sl = (Select-String -Path (Join-Path $Root "src\mk2.map") -Pattern "^([0-9a-f]{8})\s+system_lockup\b" | Select-Object -First 1).Matches[0].Groups[1].Value
  $rec = "{0:x8}" -f ([Convert]::ToUInt32($ill,16) + 0x50)
  $bp2 = 'bpset ' + $sl + ',1,{printf "LOCKUP a0=%08X a13=%08X sp=%08X",a0,a13,sp; history ,200; g}'
  $bp3 = 'bpset ' + $rec + ',temp0==0,{temp0=1; printf "RECOVERY b14=%08X a13=%08X a12=%08X a7=%08X sp=%08X",b14,a13,a12,a7,sp; history ,200; g}'
  Set-Content -Path $ds -Value @($bp, $bp2, $bp3, "g") -Encoding ascii
  $args2 += @("-debug","-debugscript",$ds)
}
$Out = Join-Path $ToolsDir "ermac_fatal_slam_mame.log"
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @args2 *> $Out } finally {
  Pop-Location
  Remove-Item Env:\MK2_ROOT,Env:\EFS_LOG,Env:\EFS_SNAP,Env:\EFS_DIST,Env:\EFS_SIDE,Env:\EFS_VICTIM,Env:\EFS_PIT,Env:\EFS_REPTILE,Env:\EFS_TRACE -ErrorAction SilentlyContinue
}
if (Test-Path $LogPath) {
  $v = Select-String -Path $LogPath -Pattern '^\[efs\] (PASS|FAIL)' | Select-Object -Last 1
  if ($v) { Write-Host $v.Line } else { Write-Host "NO VERDICT - see $LogPath / $Out" }
} else { Write-Host "NO LOG - MAME never started; see $Out" }
