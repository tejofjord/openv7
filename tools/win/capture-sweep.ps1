<#
  OpenV7 - sweep every output message while capturing USB, to see whether the
  device answers anything.

  The V7 is provably silent on bulk IN 0x83 when untouched (45 s of idle
  capture contains zero packets), which makes it a perfect null background:
  ANY inbound traffic during an output sweep is a response, and therefore
  information about which output addresses are real.

  A sweep through the vendor driver's MIDI port drew no replies, but that port
  filters. This looks at the raw USB level instead.

  Motor CCs are skipped so the platter cannot start mid-sweep.

  Must run ELEVATED.
    powershell -ExecutionPolicy Bypass -File .\tools\win\capture-sweep.ps1
#>

[CmdletBinding()]
param(
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
    Write-Host 'ERROR: must run elevated.' -ForegroundColor Red; exit 1
}

# The USBPcap control devices disappear once the driver unloads (its service is
# demand-start), so re-attach immediately before capturing rather than assuming
# a previous run left them in place.
if (-not $SkipReattach) {
    & (Join-Path $PSScriptRoot 'enable-usbpcap.ps1') -AllHubs
    Start-Sleep -Seconds 2
}

$ifaces = @()
foreach ($n in 1..8) {
    $path = "\\.\USBPcap$n"
    try {
        $h = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite'); $h.Close()
        $ifaces += $path
    } catch {
        if ($_.Exception.Message -notmatch 'Could not find file') { $ifaces += $path }
    }
}
Write-Host "interfaces: $($ifaces -join ', ')" -ForegroundColor Green
if ($ifaces.Count -eq 0) { Write-Host 'NO INTERFACES - aborting' -ForegroundColor Red; exit 1 }

$procs = @()
foreach ($if in $ifaces) {
    $tag = ($if -replace '.*\\', '')
    $f = Join-Path $OutDir "sweep-$tag.pcap"
    if (Test-Path $f) { Remove-Item $f -Force }
    $procs += Start-Process $UsbPcapCmd `
        -ArgumentList @('-d', $if, '-o', $f, '-A', '-s', '65535', '-b', '1048576') `
        -PassThru -WindowStyle Hidden
}
Start-Sleep -Seconds 2

Add-Type -Path (Join-Path $PSScriptRoot 'OpenV7Midi.dll')
$rc = [MidiMon]::OpenOut([MidiEnum]::FindOut('V7'))
Write-Host "OpenOut rc=$rc"

$marks = New-Object System.Collections.ArrayList
function Mark($m) {
    $s = (Get-Date).ToString('HH:mm:ss.fff')
    [void]$marks.Add("$s  $m"); Write-Host "[$s] $m" -ForegroundColor Cyan
}

try {
    Mark 'baseline 3s (expect complete silence inbound)'
    Start-Sleep -Seconds 3

    $motor = @(0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x69)
    Mark 'CC sweep 0x00-0x7F'
    for ($cc = 0; $cc -le 0x7F; $cc++) {
        if ($motor -contains $cc) { continue }
        [void][MidiMon]::Send(0xB0, [byte]$cc, 0x7F); Start-Sleep -Milliseconds 40
        [void][MidiMon]::Send(0xB0, [byte]$cc, 0x00); Start-Sleep -Milliseconds 40
    }
    Mark 'note-on sweep 0x00-0x7F'
    for ($n = 0; $n -le 0x7F; $n++) {
        [void][MidiMon]::Send(0x90, [byte]$n, 0x7F); Start-Sleep -Milliseconds 30
        [void][MidiMon]::Send(0x80, [byte]$n, 0x00); Start-Sleep -Milliseconds 30
    }
    Mark 'sweep done, 3s tail'
    Start-Sleep -Seconds 3
}
finally {
    [MidiMon]::CloseOut()
    foreach ($p in $procs) {
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 2
    Get-ChildItem $OutDir -Filter 'sweep-*.pcap' |
        ForEach-Object { Write-Host ("  {0}  {1:N1} KB" -f $_.Name, ($_.Length / 1KB)) -ForegroundColor Green }
    $marks | Set-Content -Path (Join-Path $OutDir 'sweep-notes.txt') -Encoding utf8
}
