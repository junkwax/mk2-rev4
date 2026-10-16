param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Stage = 0,
    [switch]$ClipOff,            # reopen the clip band = stock behaviour
    [string]$Tag = "after",
    [int]$Backstop = 180
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua  = Join-Path $ToolsDir "shadow_rise_probe.lua"
$Log  = Join-Path $ToolsDir "shadow_rise_probe_$Tag.log"
$Snap = "C:\MAME\snap\shadow_$Tag"

if (-not (Test-Path $Mame)) { $Mame = "C:\MAME\mame.exe" }
$MameName = [IO.Path]::GetFileNameWithoutExtension($Mame)

Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $Snap -ErrorAction SilentlyContinue
Get-Process -Name $MameName -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

$Nvram = Join-Path $env:TEMP "mk2_shadow_nvram"
Remove-Item -Recurse -Force $Nvram -ErrorAction SilentlyContinue

$env:SHADOW_LOG = $Log
$env:SHADOW_STAGE = "$Stage"
if ($ClipOff) { $env:SHAD_CLIP = "off" } else { Remove-Item Env:\SHAD_CLIP -ErrorAction SilentlyContinue }

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","400x254",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-nvram_directory",$Nvram,"-snapshot_directory",$Snap,
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[rise] stage $Stage, clipoff=$ClipOff, tag '$Tag' ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "shadow_rise_probe_$Tag`_mame.log") } finally { Pop-Location }
Remove-Item Env:\SHADOW_LOG,Env:\SHADOW_STAGE -ErrorAction SilentlyContinue
Remove-Item Env:\SHAD_CLIP -ErrorAction SilentlyContinue

if (Test-Path $Log) { Get-Content $Log | ForEach-Object { Write-Host $_ } }
Get-ChildItem -Recurse $Snap -ErrorAction SilentlyContinue | Select-Object FullName,Length
