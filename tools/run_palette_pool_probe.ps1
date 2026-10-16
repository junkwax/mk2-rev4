param(
    [string]$Mame = "C:\MAME\mame.exe",
    [string]$RomPath = "C:\Users\you\Workplace\mk2-main\rom",
    [int]$Backstop = 90
)
$ErrorActionPreference = "Continue"
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Lua = Join-Path $ToolsDir "palette_pool_probe.lua"
$Log = Join-Path $ToolsDir "palette_pool_probe.log"
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue

# Dead Pool is the reported failure; the others are the comparison that says
# whether it is unusually palette-hungry or whether every stage is that tight.
# P1 = Sub-Zero (8) so the freeze palettes are the ones in play.
$stages = @(
  @{st=0;  l="deadpool"},
  @{st=10; l="pitbottom"},
  @{st=1;  l="tomb"},
  @{st=8;  l="arena"}
)

foreach ($s in $stages) {
  Get-Process mame -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force "C:\MAME\nvram\mk2" -ErrorAction SilentlyContinue
  $env:PAL_STAGE = "$($s.st)"; $env:PAL_LABEL = $s.l; $env:PAL_LOG = $Log
  $env:PAL_P1 = "8"; $env:PAL_P2 = "9"; $env:PAL_HOVER = $env:PAL_HOVER
  $mameArgs = @("-rompath",$RomPath,"mk2","-window","-nomaximize","-resolution","640x480",
    "-video","gdi","-sound","none","-keyboardprovider","win32","-skip_gameinfo",
    "-autoboot_script",$Lua,"-seconds_to_run",$Backstop)
  Write-Host ("[pal] {0,-12} stage={1} ..." -f $s.l, $s.st)
  Push-Location (Split-Path -Parent $Mame)
  try { & $Mame @mameArgs *> (Join-Path $ToolsDir "palette_pool_mame.log") } finally { Pop-Location }
}
foreach ($e in @("PAL_STAGE","PAL_LABEL","PAL_LOG","PAL_P1","PAL_P2")) {
  Remove-Item ("Env:\" + $e) -ErrorAction SilentlyContinue
}

Write-Host "`n===== PALETTE POOL USAGE ====="
if (Test-Path $Log) {
    Get-Content $Log | Select-String "RESULT|headroom|free procs|camera|NOTE|FAIL |WARN |ok  |baseline" |
        ForEach-Object { Write-Host $_.Line }
} else { Write-Host "no log produced (MAME lua-never-started flake? re-run)" }
Write-Host "Full log: $Log"
