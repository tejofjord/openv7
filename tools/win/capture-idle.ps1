<#
  OpenV7 - unattended USB capture of the vendor driver's idle behaviour.

  Answers open item #1: what the stock driver sends while the device is idle,
  on which endpoint and how often. Needs no human at the controller - the
  script drives the motor over MIDI itself to produce a labelled "active"
  phase to contrast against the idle phases.

  Phases (timestamps written alongside the capture):
    A  idle, nothing touched        -> the keepalive, uncontaminated
    B  motor running                -> what active control traffic looks like
    C  idle again                   -> does the keepalive change after activity

  Must run ELEVATED (USBPcap needs admin).
    powershell -ExecutionPolicy Bypass -File .\tools\win\capture-idle.ps1
#>

[CmdletBinding()]
param(
    [int]$IdleASeconds = 45,
    [int]$ActiveSeconds = 12,
    [int]$IdleCSeconds = 30,
    [string]$UsbPcapCmd = 'C:\Program Files\USBPcap\USBPcapCMD.exe',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $repo 'captures\raw' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'ERROR: must run elevated.' -ForegroundColor Red; exit 1
}

# --- find the interface carrying the V7 ---------------------------------------
# USBPcapCMD --extcap-interfaces comes back empty on this machine even elevated,
# yet \\.\USBPcap1 plainly exists (opening it yields "access denied" rather than
# "file not found"). So probe the device paths directly and treat anything that
# is not "file not found" as present.
$ifaces = @()
foreach ($line in (& $UsbPcapCmd --extcap-interfaces 2>$null)) {
    if ($line -match 'value=(\\\\\.\\USBPcap\d+)') { $ifaces += $Matches[1] }
}
if ($ifaces.Count -eq 0) {
    Write-Host '  --extcap-interfaces empty; probing device paths directly' -ForegroundColor DarkYellow
    foreach ($n in 1..8) {
        $path = "\\.\USBPcap$n"
        try {
            $h = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            $h.Close()
            $ifaces += $path
        } catch {
            if ($_.Exception.Message -notmatch 'Could not find file') { $ifaces += $path }
        }
    }
}
if ($ifaces.Count -eq 0) {
    Write-Host 'No USBPcap interfaces. Run tools/win/enable-usbpcap.ps1 first.' -ForegroundColor Red
    exit 1
}
Write-Host "USBPcap interfaces: $($ifaces -join ', ')" -ForegroundColor Green

$notes = New-Object System.Collections.ArrayList
function Note($m) {
    $s = (Get-Date).ToString('HH:mm:ss.fff')
    [void]$notes.Add("$s  $m")
    Write-Host "[$s] $m" -ForegroundColor Cyan
}

# --- MIDI, for the active phase ------------------------------------------------
$haveMidi = $false
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'OpenV7Midi.dll')
    if ([MidiEnum]::FindOut('V7') -ge 0 -and [MidiMon]::OpenOut([MidiEnum]::FindOut('V7')) -eq 0) {
        $haveMidi = $true
    }
} catch { Write-Host "  (MIDI unavailable: $($_.Exception.Message))" -ForegroundColor DarkYellow }

# --- start capture -------------------------------------------------------------
$procs = @()
foreach ($if in $ifaces) {
    $tag = ($if -replace '.*\\', '')
    $file = Join-Path $OutDir "idle-$tag.pcap"
    if (Test-Path $file) { Remove-Item $file -Force }
    $a = @('-d', $if, '-o', $file, '-A', '-s', '65535', '-b', '1048576')
    $p = Start-Process -FilePath $UsbPcapCmd -ArgumentList $a -PassThru -WindowStyle Hidden
    $procs += [pscustomobject]@{ Proc = $p; File = $file; Iface = $if }
    Write-Host "  capturing $if -> $file" -ForegroundColor DarkGray
}
Start-Sleep -Seconds 2

try {
    Note "PHASE A BEGIN - idle, untouched ($IdleASeconds s)"
    Start-Sleep -Seconds $IdleASeconds
    Note 'PHASE A END'

    if ($haveMidi) {
        Note "PHASE B BEGIN - motor running ($ActiveSeconds s)"
        [void][MidiMon]::Send(0xB0, 0x46, 0x00)   # forward
        [void][MidiMon]::Send(0xB0, 0x45, 0x00)   # 33 1/3
        [void][MidiMon]::Send(0xB0, 0x43, 0x00)   # soft start
        Start-Sleep -Seconds $ActiveSeconds
        [void][MidiMon]::Send(0xB0, 0x44, 0x00)   # brake
        Start-Sleep -Milliseconds 1500
        [void][MidiMon]::Send(0xB0, 0x42, 0x00)   # instant stop
        Note 'PHASE B END'
    } else {
        Note 'PHASE B SKIPPED - no MIDI out'
    }

    Note "PHASE C BEGIN - idle again ($IdleCSeconds s)"
    Start-Sleep -Seconds $IdleCSeconds
    Note 'PHASE C END'
}
finally {
    Note 'CAPTURE STOPPING'
    foreach ($e in $procs) {
        if (-not $e.Proc.HasExited) { Stop-Process -Id $e.Proc.Id -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 2
    if ($haveMidi) { [MidiMon]::CloseOut() }

    Write-Host ''
    foreach ($e in $procs) {
        if (Test-Path $e.File) {
            Write-Host ("  {0}  {1:N1} KB" -f $e.File, ((Get-Item $e.File).Length / 1KB)) -ForegroundColor Green
        }
    }
    $notesFile = Join-Path $OutDir 'idle-capture-notes.txt'
    $notes | Set-Content -Path $notesFile -Encoding utf8
    Write-Host "  notes -> $notesFile" -ForegroundColor Green
}
