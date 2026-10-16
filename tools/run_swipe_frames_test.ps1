param([string]$Mame = "C:\MAME\mame.exe", [int]$Seconds = 60)
$repo = "C:\Users\you\Workplace\mk2-main"
$lua  = Join-Path $repo "tools\swipe_frames_test.lua"
$out  = Join-Path $repo "tools\swipe_frames_test.mame.log"
Remove-Item -LiteralPath (Join-Path $repo "tools\swipe_frames_test.log") -Force -ErrorAction SilentlyContinue
$a = @("-rompath",(Join-Path $repo "rom\test"),"mk2","-window","-nomaximize",
       "-resolution","640x480","-keyboardprovider","win32","-skip_gameinfo",
       "-sound","none","-video","gdi","-seconds_to_run",$Seconds,
       "-autoboot_script",$lua)
Push-Location (Split-Path -Parent $Mame); & $Mame @a *> $out; Pop-Location
$log = Join-Path $repo "tools\swipe_frames_test.log"
if (Test-Path $log) { Get-Content $log } else { Get-Content $out -Tail 30 }
