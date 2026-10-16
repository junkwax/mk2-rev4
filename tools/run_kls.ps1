param([string]$Configs, [string]$Snap = "0", [int]$Seconds = 400)
$env:MK2_ROOT = "C:/Users/you/Workplace/mk2-main"
$env:KLS_CONFIGS = $Configs
$env:KLS_SNAP = $Snap
$env:KLS_LOG = "C:\Users\you\Workplace\mk2-main\tools\klsweep\sweep.log"
$a = @("-rompath","C:\Users\you\Workplace\mk2-main\rom\escape_test","mk2","-skip_gameinfo",
  "-autoboot_script","C:\Users\you\Workplace\mk2-main\tools\kunglao_escape_sweep.lua",
  "-nvram_directory","C:\Users\you\Workplace\mk2-main\tools\klsweep\nv",
  "-cfg_directory","C:\Users\you\Workplace\mk2-main\tools\klsweep\cfg",
  "-snapshot_directory","C:\Users\you\Workplace\mk2-main\tools\klsweep\snap",
  "-seconds_to_run","$Seconds")
if ($Snap -eq "0") { $a += @("-video","none","-nothrottle","-sound","none") } else { $a += @("-window","-nomaximize","-resolution","640x480","-sound","none") }
& "C:\MAME\mame_klsweep.exe" @a 2>&1 | Select-String -Pattern "kls|error" | Select-Object -Last 5
