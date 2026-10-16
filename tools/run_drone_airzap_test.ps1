param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    # kitana mileena jax reptile subzero liukang = the six with an air
    # projectile; raiden/scorpion are the honesty control (must score 0).
    [string[]]$Char = @("kitana", "jax", "reptile", "raiden"),
    [int]$Diff = 9,
    [int]$Backstop = 260,
    # zone    = idle human, measures the jump-throw
    # convert = human throws fireballs so the drone flip kicks, measures the
    #           flip-kick -> landing projectile string
    [string]$Mode = "zone"
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "drone_airzap_test.lua"

$summary = @()
foreach ($c in $Char) {
    $Log = Join-Path $ToolsDir "drone_airzap_${Mode}_$c.log"
    Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
    Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue

    $env:AIRZAP_LOG = $Log
    $env:AIRZAP_CHAR = $c
    $env:AIRZAP_DIFF = "$Diff"
    $env:AIRZAP_MODE = $Mode
    $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
      "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
      "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)

    Write-Host "[airzap] $c (mode $Mode, diff $Diff) ..."
    Push-Location (Split-Path -Parent $Mame)
    try { & $Mame @mameArgs *> (Join-Path $ToolsDir "drone_airzap_mame.log") } finally { Pop-Location }
    "AIRZAP_LOG","AIRZAP_CHAR","AIRZAP_DIFF","AIRZAP_MODE" | ForEach-Object {
        Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }

    if (Test-Path $Log) {
        Get-Content $Log | Select-String "RESULT|ARMS |PASS |FAIL |ERROR|AIR  #|CONVERT #|GEO |LAND gap" |
            ForEach-Object { Write-Host "  $($_.Line)" }
        $v = (Get-Content $Log | Select-String "PASS |FAIL " | Select-Object -Last 1)
        $summary += [pscustomobject]@{ Char = $c; Verdict = if ($v) { $v.Line } else { "NO VERDICT" } }
    } else {
        Write-Host "  no log produced (MAME lua-never-started flake? re-run)"
        $summary += [pscustomobject]@{ Char = $c; Verdict = "NO LOG" }
    }
}

Write-Host "`n===== DRONE AIR PROJECTILE ====="
$summary | ForEach-Object { Write-Host ("{0,-10} {1}" -f $_.Char, $_.Verdict) }
