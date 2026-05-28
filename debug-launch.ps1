# Launch Teleglitch under cdb so we get a full stack trace when it crashes.
# When the process crashes, cdb pauses; run ".dump /ma C:\path\to\dump.dmp"
# inside cdb, then "k 50" for the call stack.
#
# Usage: .\debug-launch.ps1

$cdb  = "C:\Program Files\WindowsApps\Microsoft.WinDbg_1.2603.20001.0_x64__8wekyb3d8bbwe\x86\cdb.exe"
$game = "E:\SteamLibrary\steamapps\common\TeleglitchDME\Teleglitch.exe"
$dumpPath = "E:\projects\TMEMultiplayerClient\crash.dmp"

if (-not (Test-Path $cdb))  { Write-Error "cdb.exe not found at $cdb" }
if (-not (Test-Path $game)) { Write-Error "Teleglitch.exe not found" }

# -g  : skip initial breakpoint
# -G  : break on exit (so we can collect post-mortem info if needed)
# -c  : run initial commands; we auto-dump on second-chance exception and quit
$initCmds = "sxe -c `".dump /ma $dumpPath; kn 60; q`" av; g"

& $cdb -g -G -c $initCmds $game
