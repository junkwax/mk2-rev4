param(
    [string]$Mame = "C:\MAME\mame_mk2test.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 400
)
# Raiden's electrocute grab against a CPU opponent -- see
# tools/raiden_shocker_ai_test.lua for what the two phases prove.
#
# mame_mk2test.exe rather than mame.exe on purpose: two rigs sharing one
# binary kill each other and the loser looks like a crash.
#
# The launch is Start-Process + the standalone warning poker rather than a
# plain call, because mk2 ALWAYS raises the red "ROMs are incorrect" screen
# (undumped PLDs) and this MAME has no -skip_warnings. Left unanswered it
# parks forever at ~0% CPU and the run looks like a hang with an empty log --
# which is exactly what happened here before the poker was wired in. See the
# header of tools/mame_dismiss_warning.ps1 for why it cannot be done from
# inside the launching shell.
$ErrorActionPreference = "Continue"
if (-not (Test-Path $Mame)) { $Mame = "C:\MAME\mame.exe" }
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "raiden_shocker_ai_test.lua"
$Log = Join-Path $ToolsDir "raiden_shocker_ai_test.log"
$MameLog = Join-Path $ToolsDir "raiden_shocker_ai_mame.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

Get-Process mame, mame_mk2test -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:RSK_LOG = $Log
$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[rsk] running Raiden shocker vs CPU ..."
$proc = Start-Process -FilePath $Mame -ArgumentList $mameArgs `
    -WorkingDirectory (Split-Path -Parent $Mame) `
    -RedirectStandardOutput $MameLog -RedirectStandardError "$MameLog.err" `
    -PassThru

# The Lua log is the definitive "we are past the warning" signal, so the
# poker stops itself the moment it appears.
$poker = Join-Path $ToolsDir "mame_dismiss_warning.ps1"
if (Test-Path $poker) {
    Start-Process -FilePath "powershell" -WindowStyle Hidden -ArgumentList @(
        "-ExecutionPolicy","Bypass","-File",$poker,
        "-ProcessId",$proc.Id,"-ReadyFile",$Log,"-TimeoutSec",120) | Out-Null
}

if (-not $proc.WaitForExit(($Backstop + 180) * 1000)) {
    Write-Host "[rsk] MAME did not exit - killing"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

if (Test-Path $Log) {
    Get-Content $Log | Where-Object { $_ -match "RESULT|PASS|FAIL|ERROR|MISSING" }
    $verdict = (Select-String -Path $Log -Pattern "^\[rsk\] (PASS|FAIL)" |
                Select-Object -Last 1).Line
    if (-not $verdict) {
        Write-Host "[rsk] NO-VERDICT - see $MameLog"
        exit 2
    }
    if ($verdict -match "FAIL") { exit 1 }
    exit 0
} else {
    Write-Host "[rsk] no log written - MAME never got past the ROM warning; see $MameLog"
    exit 2
}
