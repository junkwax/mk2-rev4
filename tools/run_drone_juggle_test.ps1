param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [string[]]$Case = @("hh", "fn2"),
    [int]$Diff = 9,
    [int]$Backstop = 220
)

# Drives the drone's juggle combos (MKDRONE.ASM drone_juggle_*) and scores
# them on BOTH counts: did the script chain, and did it convert damage.
#   -Diff 0   runs the honesty control: the combo must never fire down there.
# NEVER run this alongside another MAME harness -- they all kill mame.exe on
# start and would shoot each other's run.

$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "drone_juggle_test.lua"
$results = @()

Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force

foreach ($c in $Case) {
    $Log = Join-Path $ToolsDir "drone_juggle_$c.log"
    Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

    $env:JUGGLE_LOG = $Log
    $env:JUGGLE_CASE = $c
    $env:JUGGLE_DIFF = "$Diff"

    $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
      "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
      "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

    Write-Host "[juggle] $c (diff $Diff) ..."
    Push-Location (Split-Path -Parent $Mame)
    try { & $Mame @mameArgs *> (Join-Path $ToolsDir "drone_juggle_mame_$c.log") } finally { Pop-Location }
    Remove-Item Env:\JUGGLE_LOG,Env:\JUGGLE_CASE,Env:\JUGGLE_DIFF -ErrorAction SilentlyContinue

    $verdict = "NO VERDICT (setup/timeout?)"
    if (Test-Path $Log) {
        $line = Select-String -Path $Log -Pattern "^\[juggle\] (PASS|FAIL) " | Select-Object -Last 1
        if ($line) { $verdict = $line.Line -replace "^\[juggle\] ", "" }
        Get-Content $Log | Select-String "trial |----" | ForEach-Object { Write-Host "  $($_.Line)" }
    }
    Write-Host "[juggle] $c -> $verdict"
    $results += [pscustomobject]@{ Case = $c; Verdict = $verdict }
}

Write-Host ""
Write-Host "==== drone juggle combos ===="
$results | ForEach-Object { "{0,-5} {1}" -f $_.Case, $_.Verdict }
