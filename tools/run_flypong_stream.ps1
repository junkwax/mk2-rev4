# run_flypong_stream.ps1 - the Fly Pong stream in one command.
#
#   .\tools\run_flypong_stream.ps1 -Fresh       # both flies start knowing nothing (the show)
#   .\tools\run_flypong_stream.ps1              # carry on with the brains they have
#   .\tools\run_flypong_stream.ps1 -Brains C:\tmp\flybrain\pong_train2\brains.lua   # start from a trained pair
#
# Starts the page (tools/flypong_dashboard.py, http://localhost:8778 - add ?bare=1 for an OBS
# browser source), opens it, and keeps a MAME window playing at the board's own speed. If MAME
# exits for any reason it is started again on the brains it last saved, so the learning
# survives a restart. Create <Out>\STOP to end the loop after the current run, or close the
# window three times inside a minute and it stops relaunching.
param(
    [string]$Out = "C:\tmp\flybrain\pong_live",
    [string]$Brains = "",
    [switch]$Fresh,
    [switch]$Small,            # an 800x600 window instead of maximized (the default, as the MK streams ran)
    [switch]$Sound,
    [int]$Port = 8778,
    [switch]$NoBrowser
)
$ErrorActionPreference = "Stop"
$Tools = $PSScriptRoot
New-Item -ItemType Directory -Force $Out | Out-Null
$saved = Join-Path $Out "brains.lua"
if ($Fresh -and (Test-Path $saved)) {
    $keep = Join-Path $Out ("brains_{0}.lua" -f (Get-Date -Format yyyyMMdd_HHmmss))
    Move-Item $saved $keep
    Write-Host "[flypong] -Fresh: the old brains are kept as $keep"
}
if ($Brains -and -not (Test-Path $saved)) { Copy-Item $Brains $saved }
Remove-Item (Join-Path $Out "STOP") -ErrorAction SilentlyContinue

$state = Join-Path $Out "pong.json"
$up = $false
try { $up = (Invoke-WebRequest "http://localhost:$Port/state" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } catch {}
if (-not $up) {
    Start-Process python -ArgumentList @((Join-Path $Tools "flypong_dashboard.py"), "--state", $state, "--port", "$Port") -WindowStyle Hidden
    Start-Sleep 2
}
if (-not $NoBrowser) { Start-Process "http://localhost:$Port/" }

# Closing the window three times inside a minute means "stop", not "it crashed": the loop
# remembers when each run ended and gives up instead of relaunching a fourth time.
$exits = New-Object System.Collections.Generic.List[datetime]
while (-not (Test-Path (Join-Path $Out "STOP"))) {
    $a = @{ Out = $Out; Watch = $true }
    if (-not $Small) { $a.Maximize = $true }
    if ($Sound) { $a.Sound = $true }
    if (Test-Path $saved) { $a.WeightsIn = $saved }
    & (Join-Path $Tools "run_flypong.ps1") @a
    if (Test-Path (Join-Path $Out "STOP")) { break }
    $now = Get-Date
    $exits.Add($now)
    $recent = @($exits | Where-Object { ($now - $_).TotalSeconds -le 60 })
    if ($recent.Count -ge 3) {
        Write-Host "[flypong] the window was closed 3 times inside a minute - not relaunching"
        break
    }
    Write-Host "[flypong] MAME ended - starting again on the saved brains in 5s (create $Out\STOP to end)"
    Start-Sleep 5
}
Write-Host "[flypong] stopped"
