# Isolated air-zap geometry run: private rompath / cfg / nvram so a rig in
# another session cannot swap the ROM or the nvram out from under this one.
# (Two MAME rigs sharing C:\MAME really do kill each other - the failure looks
# like "no log produced", not like a crash.)
param(
    [string]$Char = "subzero",
    [int]$Diff = 9,
    [int]$Backstop = 300,
    [string]$Sandbox = "C:\Users\you\AppData\Local\Temp\claude\c--Users-you-Workplace-mk2-main\2e8415ab-2086-4469-9d61-c60856f54008\scratchpad"
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "drone_airzap_test.lua"
$Log = Join-Path $ToolsDir "drone_airzap_geo_$Char.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $Sandbox "nvram\mk2") -ErrorAction SilentlyContinue

$env:AIRZAP_LOG = $Log
$env:AIRZAP_CHAR = $Char
$env:AIRZAP_DIFF = "$Diff"
$env:AIRZAP_MODE = "zone"
$args2 = @("-rompath",(Join-Path $Sandbox "rom"),"mk2","-window","-nomaximize",
  "-resolution","640x480","-video","gdi","-sound","none","-keyboardprovider","win32",
  "-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
Push-Location "C:\MAME"
try { & "C:\MAME\mame.exe" @args2 *> (Join-Path $ToolsDir "drone_airzap_geo_mame.log") } finally { Pop-Location }
"AIRZAP_LOG","AIRZAP_CHAR","AIRZAP_DIFF","AIRZAP_MODE" | ForEach-Object {
    Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }
if (Test-Path $Log) { Get-Content $Log | Select-String "AIR  #|GEO |LAND gap|RESULT|AIR PROJECTILES" }
else { Write-Host "no log" }
