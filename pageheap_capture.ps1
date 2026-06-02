# One-shot: enable FULL page heap for Teleglitch.exe, launch the JOINER under cdb
# to catch the heap corruptor at its exact instruction, then disable page heap.
#
# Run it (it will self-elevate via a UAC prompt — click Yes):
#   powershell -ExecutionPolicy Bypass -File "E:\projects\TMEMultiplayerClient\pageheap_capture.ps1"
#
# Before running: make sure the HOST window is hosting (click "Host MP" on it so
# it reconnects to the relay). This script only launches the JOINER.

# --- self-elevate ---
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host "Requesting admin (UAC)..."
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy","Bypass","-NoProfile","-File","`"$PSCommandPath`""
    return
}

# --- elevated from here ---
$ErrorActionPreference = "Continue"
$cdb     = "C:\Program Files\WindowsApps\Microsoft.WinDbg_1.2603.20001.0_x64__8wekyb3d8bbwe\x86\cdb.exe"
$gamedir = "E:\SteamLibrary\steamapps\common\TeleglitchDME"
$game    = "$gamedir\Teleglitch.exe"
$script  = "E:\projects\TMEMultiplayerClient\cdb_pageheap.txt"
$out     = "E:\projects\TMEMultiplayerClient\cdb_ph.out"
$err     = "E:\projects\TMEMultiplayerClient\cdb_ph.err"
$ifeo    = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Teleglitch.exe"

if (-not (Test-Path $cdb))  { Write-Host "ERROR: cdb not found at $cdb"; Read-Host "Enter to exit"; return }
if (-not (Test-Path $game)) { Write-Host "ERROR: game not found"; Read-Host "Enter to exit"; return }

try {
    Write-Host "[1/3] Enabling FULL page heap for Teleglitch.exe ..."
    New-Item -Path $ifeo -Force | Out-Null
    # GlobalFlag = 0x02001000 = FLG_HEAP_PAGE_ALLOCATIONS | FLG_USER_STACK_TRACE_DB.
    # The +0x1000 enables stack tracing for ALL heap allocations, so when the
    # crash hits we can `!heap -p -a <addr>` to get the alloc stack of the
    # corrupted block — that tells us WHICH allocation got overwritten.
    New-ItemProperty -Path $ifeo -Name GlobalFlag    -PropertyType DWord -Value 0x02001000 -Force | Out-Null
    New-ItemProperty -Path $ifeo -Name PageHeapFlags -PropertyType DWord -Value 0x00000003 -Force | Out-Null
    $gf = (Get-ItemProperty $ifeo).GlobalFlag
    Write-Host ("      GlobalFlag = 0x{0:X8}  (page heap + alloc stack tracing)" -f $gf)

    Remove-Item $out,$err,"E:\projects\TMEMultiplayerClient\crash_ph.dmp" -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "[2/3] Launching JOINER under cdb. A game window will open (slow - full page heap)."
    Write-Host "      >>> In that window: click 'Join MP', then MOVE + GRAB ITEMS until it crashes. <<<"
    Write-Host "      (May take a few tries - the crash is intermittent. Keep looting / rejoining.)"
    Write-Host "      cdb auto-captures the faulting stack + crash_ph.dmp, then this window continues."
    Write-Host ""

    $spArgs = @{
        FilePath               = $cdb
        ArgumentList           = @("-g","-G","-cf",$script,$game)
        WorkingDirectory       = $gamedir
        RedirectStandardOutput = $out
        RedirectStandardError  = $err
        Wait                   = $true
    }
    Start-Process @spArgs
    Write-Host "      cdb session ended."
}
finally {
    Write-Host ""
    Write-Host "[3/3] Disabling page heap (cleanup) ..."
    Remove-Item -Path $ifeo -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $ifeo) { Write-Host "      WARNING: IFEO key still present - disable manually." }
    else { Write-Host "      Page heap disabled." }
}

Write-Host ""
Write-Host "DONE. Captured:"
Write-Host "  stack/analysis : $out"
Write-Host "  full dump      : E:\projects\TMEMultiplayerClient\crash_ph.dmp"
Write-Host "Tell Claude it is done; it will read the stack."
Read-Host "Press Enter to close"
