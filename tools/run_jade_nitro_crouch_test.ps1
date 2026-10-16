param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    # Seen once: both modes exited having logged nothing but "loaded" - no
    # fight, no verdict - and the old scoring below called that a PASS.  It
    # did not reproduce at 260 or, afterwards, at 140, so the cause is a boot
    # flake rather than a short backstop; 260 is just cheap headroom.  The
    # real fix is the NO VERDICT guard at the bottom.
    [int]$Backstop = 260
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "jade_nitro_crouch_test.lua"
$Log = Join-Path $ToolsDir "jade_nitro_crouch_test.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

# Two runs: the crouch case, and the standing control that proves the kick
# still connects at all. A "crouch passed" result is worthless on its own --
# a move that whiffs everything would also pass it.
foreach ($mode in @("stand", "crouch")) {
    Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue
    $env:NITRO_MODE = $mode
    $env:NITRO_LOG  = $Log
    $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
      "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
      "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
    Write-Host "[nitro-crouch] running $mode ..."
    Push-Location (Split-Path -Parent $Mame)
    try { & $Mame @mameArgs *> (Join-Path $ToolsDir "jade_nitro_crouch_mame_$mode.log") } finally { Pop-Location }
}
Remove-Item "Env:\NITRO_MODE" -ErrorAction SilentlyContinue
Remove-Item "Env:\NITRO_LOG" -ErrorAction SilentlyContinue

Write-Host "`n===== JADE NITRO CROUCH DODGE ====="
if (Test-Path $Log) {
    Get-Content $Log | Select-String "RESULT|PASS |FAIL |staged|fight " | ForEach-Object { Write-Host $_.Line }
    $fails = (Get-Content $Log | Select-String "^\[nitro-crouch:.*\] FAIL ").Count
    # Both modes must actually REACH a verdict.  Counting only FAIL lines
    # scores a run that died before the fight as a pass, which is what a
    # boot flake produced here - silently, on a balance change.
    $verdicts = (Get-Content $Log | Select-String "^\[nitro-crouch:(stand|crouch)\] (PASS|FAIL) ").Count
    if ($verdicts -lt 2) {
        Write-Host "`nOVERALL: NO VERDICT ($verdicts/2 modes reported) - the run"
        Write-Host "did not get far enough to decide anything.  Raise -Backstop and re-run;"
        Write-Host "do NOT read this as a pass."
        exit 1
    }
    if ($fails -eq 0) { Write-Host "`nOVERALL: PASS" } else { Write-Host "`nOVERALL: FAIL ($fails)" }
} else { Write-Host "no log produced (MAME lua-never-started flake? re-run)"; exit 1 }
Write-Host "Full log: $Log"
