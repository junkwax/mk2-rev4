param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$BackstopEmuSeconds = 200,
    [int]$Snap = 10,
    # ermac   = the babality itself
    # noob    = the refusal control (was jade, who has had Kitana's
    #           babality since 2026-10-05) (a zero row in ochar_baby_combos must
    #           still refuse now that bb_check reads the table instead of
    #           hardcoding "ochar >= 12")
    # reptile = the stock regression (bb_check was rewritten for everyone)
    [ValidateSet("ermac","noob","reptile")][string]$As = "ermac",
    [switch]$Sound
)
# Ermac's BABALITY - Down, Back, Back + LOW KICK.
# See tools/ermac_babality_test.lua for what each measured value means.
#
# mame_mk2test.exe, not mame.exe: two MAME rigs sharing one binary kill each
# other's cfg/nvram and the failure looks like a crash mid-log
# (reference_mame_rig_contention).
$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "ermac_babality_test.lua"
$LogPath = Join-Path $ToolsDir "ermac_babality_test.log"
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
$env:MK2_ROOT = $Root
$env:EBB_LOG = $LogPath
$env:EBB_SNAP = [string]$Snap
$env:EBB_AS = $As
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
$Out = Join-Path $ToolsDir "ermac_babality_mame.log"
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @args2 *> $Out } finally {
  Pop-Location
  Remove-Item Env:\MK2_ROOT,Env:\EBB_LOG,Env:\EBB_SNAP,Env:\EBB_AS -ErrorAction SilentlyContinue
}
if (Test-Path $LogPath) {
  $v = Select-String -Path $LogPath -Pattern '^\[ebb\] (PASS|FAIL)' | Select-Object -Last 1
  if ($v) { Write-Host $v.Line } else { Write-Host "NO VERDICT - see $LogPath / $Out" }
} else { Write-Host "NO LOG - MAME never started; see $Out" }
