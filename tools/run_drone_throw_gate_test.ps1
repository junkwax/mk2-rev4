param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 220
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "drone_throw_gate_test.lua"
$Log = Join-Path $ToolsDir "drone_throw_gate_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:THROW_LOG = $Log
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[throw] running drone throw gate test ..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> (Join-Path $ToolsDir "drone_throw_gate_mame.log") } finally { Pop-Location }
Remove-Item "Env:\THROW_LOG" -ErrorAction SilentlyContinue

Write-Host "`n===== DRONE THROW GATE ====="
if (Test-Path $Log) {
    Get-Content $Log | Select-String "THROW #|RESULT|PASS |FAIL |ERROR|phase ->|fight start" |
        ForEach-Object { Write-Host $_.Line }
} else {
    Write-Host "no log produced"
}
Write-Host "Full log: $Log"
