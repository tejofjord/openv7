<#
  OpenV7 - Numark V7 vendor-driver USB capture (Windows)

  Captures raw USB traffic from the stock Ploytec/Numark v2.9 Windows driver so we can
  answer the two open questions in the macOS bridge:
    1. what the vendor driver sends on bulk OUT 0x04 while idle (the keepalive)
    2. how it recovers a stalled device without a physical power cycle

  Run ELEVATED:
    powershell -ExecutionPolicy Bypass -File .\captures\capture-v7.ps1

  Captures every USBPcap root hub at once (one file each) rather than filtering to the
  device address, because the address changes across the unplug/replug in step 1.
#>

[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'raw'),
    [string]$UsbPcapCmd = 'C:\Program Files\USBPcap\USBPcapCMD.exe'
)

$ErrorActionPreference = 'Stop'

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
              [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "ERROR: must run elevated (USBPcap needs admin)." -ForegroundColor Red
        Write-Host "  Right-click PowerShell -> Run as administrator, then re-run this script."
        exit 1
    }
}

$script:Notes = @()
function Note($msg) {
    $stamp = (Get-Date).ToString('HH:mm:ss.fff')
    $script:Notes += "$stamp  $msg"
    Write-Host "[$stamp] $msg" -ForegroundColor Cyan
}

function Step($n, $title, $instruction, $seconds) {
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkGray
    Write-Host " STEP $n - $title" -ForegroundColor Yellow
    Write-Host ("=" * 72) -ForegroundColor DarkGray
    Write-Host $instruction
    Write-Host ""
    Read-Host "  Press ENTER when you are ready to start this step"
    Note "STEP $n BEGIN - $title"
    for ($i = $seconds; $i -gt 0; $i--) {
        Write-Host -NoNewline ("`r  capturing... {0,3}s remaining   " -f $i)
        Start-Sleep -Seconds 1
    }
    Write-Host "`r  step complete.                    "
    Note "STEP $n END   - $title"
}

Assert-Admin

if (-not (Test-Path $UsbPcapCmd)) { throw "USBPcapCMD not found at $UsbPcapCmd" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# --- find the USBPcap root-hub interfaces -------------------------------------
$ifaceLines = & $UsbPcapCmd --extcap-interfaces 2>$null
$ifaces = @()
foreach ($line in $ifaceLines) {
    if ($line -match 'value=(\\\\\.\\USBPcap\d+)') { $ifaces += $Matches[1] }
}
if ($ifaces.Count -eq 0) {
    Write-Host "ERROR: no USBPcap interfaces found." -ForegroundColor Red
    Write-Host "  USBPcap's filter driver attaches to the USB root hubs at boot."
    Write-Host "  Reboot and re-run this script."
    exit 1
}
Write-Host "USBPcap interfaces: $($ifaces -join ', ')" -ForegroundColor Green

# --- confirm the V7 is present ------------------------------------------------
$v7 = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
      Where-Object { $_.InstanceId -like '*VID_15E4*PID_0075*' }
if ($v7) {
    Write-Host "Numark V7 present:" -ForegroundColor Green
    $v7 | ForEach-Object { Write-Host "  $($_.FriendlyName)  [$($_.Status)]" }
} else {
    Write-Host "WARNING: no VID_15E4/PID_0075 device found. Plug in the V7." -ForegroundColor Yellow
}

# --- start one capture per interface -----------------------------------------
$procs = @()
foreach ($if in $ifaces) {
    $tag  = ($if -replace '.*\\', '')
    $file = Join-Path $OutDir "$tag.pcap"
    if (Test-Path $file) { Remove-Item $file -Force }
    $cmdArgs = @('-d', $if, '-o', $file, '-A', '-s', '65535', '-b', '1048576')
    $p = Start-Process -FilePath $UsbPcapCmd -ArgumentList $cmdArgs -PassThru -WindowStyle Hidden
    $procs += [pscustomobject]@{ Proc = $p; Iface = $if; File = $file }
    Write-Host "  capturing $if -> $file" -ForegroundColor DarkGray
}
Start-Sleep -Seconds 2
Note "CAPTURE STARTED on $($ifaces.Count) interface(s)"

Write-Host ""
Write-Host "Capture is running. Follow each step; the script times them for you." -ForegroundColor Green

try {
    Step 1 'UNPLUG / REPLUG' @'
  Unplug the V7's USB cable, wait ~5 seconds, plug it back in.
  -> captures the full init handshake (EP0 control transfers, rate set, arm).
'@ 45

    Step 2 'IDLE - 60s HANDS OFF' @'
  Do NOT touch the controller at all. Hands off the desk.
  -> ALREADY ANSWERED by tools/win/capture-idle.ps1: the driver sends nothing
     at all on bulk OUT 0x04 while idle, and issues no control transfers. Kept
     here as a longer-window confirmation.
'@ 60

    Step 3 'SPIN THE PLATTER' @'
  Spin the platter continuously for the whole step.
'@ 15

    Step 4 'PLAY AUDIO TO THE V7' @'
  Set "Speakers (Numark V7 Audio - WDM 2.9.64)" as the Windows output device
  and play music for the whole step.
  -> THE key remaining step. The endpoint roles are already settled (iso OUT
     0x02 is PCM out, bulk IN 0x86 is PCM in); what is still unknown is the
     ENCODING. Silence captures as all zeros, which cannot distinguish plain
     S24_3LE packing from bit-interleaving. Real audio can.
'@ 20

    Step 5 'LONG IDLE, THEN SPIN AGAIN' @'
  Stop the platter and leave it completely untouched.
  When the countdown reaches ~10s remaining, spin the platter again.
  -> does the control stream survive a long idle, and what kept it alive?
'@ 60

    Step 6 'EXERCISE EVERY CONTROL' @'
  Press each button and pad once, move every fader/knob through its range:
  PLAY, CUE, SYNC, hot cues 1-5, loop controls, FX, browse encoder,
  strip search, pitch fader, and the platter touch surface.
  -> full control map, plus any LED/display feedback the driver sends on 0x04.
'@ 90

    Step 7 'STALL / RECOVERY (optional)' @'
  If you can make the controller go silent or stall, do it now, then do
  whatever brings it back (restart the DJ software, or unplug/replug).
  If you cannot reproduce a stall, just wait this step out - it is optional.
'@ 45
}
finally {
    Note "CAPTURE STOPPING"
    foreach ($e in $procs) {
        if (-not $e.Proc.HasExited) { Stop-Process -Id $e.Proc.Id -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 2

    Write-Host ""
    Write-Host "Capture files:" -ForegroundColor Green
    foreach ($e in $procs) {
        if (Test-Path $e.File) {
            $kb = [math]::Round((Get-Item $e.File).Length / 1KB, 1)
            Write-Host ("  {0,-40} {1,10} KB" -f $e.File, $kb)
        }
    }

    $notesFile = Join-Path $PSScriptRoot 'capture-notes.txt'
    $script:Notes | Set-Content -Path $notesFile -Encoding utf8
    Write-Host ""
    Write-Host "Timestamps written to $notesFile" -ForegroundColor Green
    Write-Host "Done. Tell Claude the capture is finished." -ForegroundColor Yellow
}

