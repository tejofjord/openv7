<#
  OpenV7 - capture the V7 while VirtualDJ drives it.

  This is the reference recording: Windows + VirtualDJ + the stock Ploytec
  driver is the configuration that plays this deck without hiccups, so what
  crosses the wire here is a working system's traffic.

  It answers two experiments from docs/HANDOFF-WINDOWS.md in one run, because
  both need the same capture:

    X4  Does VirtualDJ command the motor? Watch bulk OUT 0x04 for B0 41/42/43.
        On macOS VDJ drives the LEDs but has never once been seen to command
        the motor - conspicuous for a deck whose premise is a motorised platter.

    X2  The timestamped inbound stream (bulk IN 0x83) is the artifact to carry
        back to the Mac and replay into CoreMIDI verbatim. Without arrival
        timestamps the replay cannot reproduce the cadence and the experiment
        is worthless, so they are recorded.

  USBPcap is used rather than the MIDI port deliberately: VirtualDJ holds that
  port exclusively while it runs, so nothing else can open it. The USB layer is
  visible regardless of who owns the port.

  MUST RUN ELEVATED.
    powershell -ExecutionPolicy Bypass -File .\tools\win\capture-vdj.ps1
#>

[CmdletBinding()]
param(
    [int]$Seconds = 90,
    [string]$UsbPcapCmd = 'C:\Program Files\USBPcap\USBPcapCMD.exe',
    [string]$OutDir = '',
    [switch]$SkipReattach
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $repo 'captures\raw' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'ERROR: must run elevated.' -ForegroundColor Red
    Write-Host '  Open PowerShell as Administrator and run this again.' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $UsbPcapCmd)) { throw "USBPcapCMD not found at $UsbPcapCmd" }

# The USBPcap control devices disappear when its driver unloads (demand-start),
# so re-attach immediately before capturing rather than trusting a previous run.
if (-not $SkipReattach) {
    $enable = Join-Path $PSScriptRoot 'enable-usbpcap.ps1'
    if (Test-Path $enable) { & $enable ; Start-Sleep -Seconds 2 }
}

# Probe the control devices directly. --extcap-interfaces returns empty on this
# machine even elevated, and restarting hubs renumbers them.
# A successful open is sufficient but NOT necessary: the control device can
# exist and still refuse to open (in use, or access denied) which is not the
# same as absent. Only "could not find file" means it is really not there.
# Counting successful opens alone reports zero interfaces on a machine where
# USBPcap is correctly attached - this matches enable-usbpcap.ps1.
$ifaces = @()
foreach ($n in 1..8) {
    $path = "\\.\USBPcap$n"
    try {
        $h = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $h.Close(); $ifaces += $path
    } catch {
        if ($_.Exception.Message -notmatch 'Could not find file') { $ifaces += $path }
    }
}
if ($ifaces.Count -eq 0) {
    Write-Host 'ERROR: no USBPcap control devices openable.' -ForegroundColor Red
    Write-Host '  Run tools/win/enable-usbpcap.ps1 elevated first.' -ForegroundColor Red
    exit 1
}
Write-Host "USBPcap interfaces: $($ifaces -join ', ')" -ForegroundColor Green

$v7 = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
      Where-Object { $_.InstanceId -like '*VID_15E4*PID_0075*' }
if ($v7) { Write-Host "V7 present: $($v7[0].FriendlyName)" -ForegroundColor Green }
else { Write-Host 'WARNING: no VID_15E4/PID_0075 device found.' -ForegroundColor Yellow }

$vdj = Get-Process -Name '*virtualdj*' -ErrorAction SilentlyContinue
if ($vdj) { Write-Host "VirtualDJ running (pid $($vdj[0].Id))" -ForegroundColor Green }
else { Write-Host 'WARNING: VirtualDJ does not appear to be running.' -ForegroundColor Yellow }

$procs = @()
foreach ($if in $ifaces) {
    $tag = ($if -replace '.*\\', '')
    $file = Join-Path $OutDir "vdj-$tag.pcap"
    if (Test-Path $file) { Remove-Item $file -Force }
    $cmdArgs = @('-d', $if, '-o', $file, '-A', '-s', '65535', '-b', '1048576')
    $p = Start-Process -FilePath $UsbPcapCmd -ArgumentList $cmdArgs -PassThru -WindowStyle Hidden
    $procs += [pscustomobject]@{ Proc = $p; File = $file }
    Write-Host "  capturing $if -> $file" -ForegroundColor DarkGray
}
Start-Sleep -Seconds 2

Write-Host ''
Write-Host ('=' * 70) -ForegroundColor DarkGray
Write-Host " RECORDING $Seconds s - drive the deck from VirtualDJ now" -ForegroundColor Yellow
Write-Host ('=' * 70) -ForegroundColor DarkGray
Write-Host '   1. load a track onto the deck'
Write-Host '   2. press PLAY  (does the platter spin? that is X4)'
Write-Host '   3. let it play ~10 s untouched'
Write-Host '   4. scratch: hand on the platter, back and forth a few times'
Write-Host '   5. nudge the pitch fader'
Write-Host '   6. press PAUSE, then PLAY again'
Write-Host '   7. leave it playing until the countdown ends'
Write-Host ''

try {
    for ($i = $Seconds; $i -gt 0; $i -= 5) {
        Write-Host -NoNewline ("`r  {0,4}s remaining " -f $i)
        # The last iteration must not overshoot: -Seconds 91 steps 91,86..1 and
        # would sleep 95 s, so the capture runs longer than the operator was told.
        Start-Sleep -Seconds ([Math]::Min(5, $i))
    }
    Write-Host "`r  done.                    "
}
finally {
    foreach ($e in $procs) {
        if (-not $e.Proc.HasExited) { Stop-Process -Id $e.Proc.Id -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 2
    Write-Host ''
    foreach ($e in $procs) {
        if (Test-Path $e.File) {
            $mb = [math]::Round((Get-Item $e.File).Length / 1MB, 2)
            Write-Host ("  {0,-46} {1,8} MB" -f $e.File, $mb) -ForegroundColor Green
        }
    }
    Write-Host ''
    Write-Host 'Now tell Claude the capture is done.' -ForegroundColor Yellow
}
