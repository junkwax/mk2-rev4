param(
    # Its own binary: two rigs sharing one mame.exe kill each other mid-run
    # and the log stops with exit -1 that looks exactly like a crash.
    [string]$Mame = $(if (Test-Path "C:\MAME\mame_mk2test.exe") { "C:\MAME\mame_mk2test.exe" } else { "C:\MAME\mame.exe" }),
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 180,
    [int]$Frames = 5400,
    [int]$Diff = 9,
    # Step P1 out of the FIRST smash so the SECOND one is the thing under test.
    [switch]$Dodge
)
# One Kintaro face-smash trial.  P1 is pinned on top of him and jabs on a loop,
# so Kintaro blocks; the block is the trigger - stop_abusive_attackers offers
# goro_facesmash there.  Its five branches (started / first hit / first missed /
# second hit / both whiffed) are counted separately off @debug4.  See the header of
# tools/kintaro_facesmash_test.lua for what each breadcrumb means.
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "kintaro_facesmash_test.lua"
$Log = Join-Path $ToolsDir "kintaro_facesmash_test.log"
$MameLog = Join-Path $ToolsDir "kintaro_facesmash_mame.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

$env:KFS_LOG = $Log
$env:KFS_FRAMES = "$Frames"
$env:KFS_DIFF = "$Diff"
if ($Dodge) { $env:KFS_DODGE = "1" } else { Remove-Item Env:\KFS_DODGE -ErrorAction SilentlyContinue }

$mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
  "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
  "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

Write-Host "[kfs] running Kintaro face smash trial (diff=$Diff, $Frames fight frames)..."
Push-Location (Split-Path -Parent $Mame)
try { & $Mame @mameArgs *> $MameLog } finally { Pop-Location }

foreach ($e in @("KFS_LOG","KFS_FRAMES","KFS_DIFF","KFS_DODGE")) {
  Remove-Item "Env:\$e" -ErrorAction SilentlyContinue }

if (-not (Test-Path $Log)) {
  Write-Host "[kfs] NO-VERDICT - no log written; check $MameLog"
  exit 1
}
Get-Content $Log
$verdict = Get-Content $Log | Select-String "PASS|PARTIAL|FAIL" | Select-Object -Last 1
Write-Host "`n===== KINTARO FACE SMASH ====="
if ($verdict) { Write-Host $verdict.Line } else { Write-Host "NO-VERDICT - see $Log and $MameLog" }
Write-Host "Full log: $Log"
