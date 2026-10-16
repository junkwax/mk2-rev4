param(
    [string]$Mame = "C:\MAME\mame_hfrig.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$BackstopEmuSeconds = 200,
    [int]$Snap = 10,
    [ValidateSet("jade","rain","ermac","reptile","kitana","noob")][string]$As = "jade",
    [ValidateSet("baby","stage")][string]$Kind = "baby",
    # check_dtp stages: 1 tomb, 6 pit II, 24 YOTEIGAI TOR, 26 THE PIT (MK1)
    [int]$Stage = 6,
    # -Negative: the finisher must NOT fire (refusal control)
    [switch]$Negative,
    [switch]$Sound
)
# Babalities and stage fatalities for the hidden fighters - see
# tools/hidden_finisher_test.lua for the inputs and what each beat means.
$ErrorActionPreference = "Stop"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ToolsDir
$Lua = Join-Path $ToolsDir "hidden_finisher_test.lua"
$LogPath = Join-Path $ToolsDir ("hidden_finisher_" + $As + "_" + $Kind + $(if ($Negative) {"_neg"} else {""}) + ".log")
Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "C:\MAME\nvram\mk2" -Recurse -Force -ErrorAction SilentlyContinue
$env:MK2_ROOT = $Root
$env:HF_LOG = $LogPath
$env:HF_SNAP = [string]$Snap
$env:HF_AS = $As
$env:HF_KIND = $Kind
$env:HF_STAGE = [string]$Stage
$env:HF_EXPECT = $(if ($Negative) { "0" } else { "1" })
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
$Out = Join-Path $ToolsDir ("hidden_finisher_" + $As + "_" + $Kind + "_mame.log")
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @args2 *> $Out } finally {
  Pop-Location
  Remove-Item Env:\MK2_ROOT,Env:\HF_LOG,Env:\HF_SNAP,Env:\HF_AS,Env:\HF_KIND,Env:\HF_STAGE,Env:\HF_EXPECT -ErrorAction SilentlyContinue
}
if (Test-Path $LogPath) {
  $v = Select-String -Path $LogPath -Pattern '^\[hf\] (PASS|FAIL)' | Select-Object -Last 1
  if ($v) { Write-Host $v.Line } else { Write-Host "NO VERDICT - see $LogPath / $Out" }
} else { Write-Host "NO LOG - MAME never started; see $Out" }
