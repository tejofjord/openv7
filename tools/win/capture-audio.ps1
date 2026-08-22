<#
  OpenV7 - capture the vendor driver with REAL audio playing.

  The endpoint roles are already measured (iso OUT 0x02 = PCM out, bulk IN 0x86
  = PCM in). What is still unknown is the ENCODING: silence captures as all
  zeros, which cannot distinguish plain sample packing from the Ploytec
  bit-interleaved format. Real audio can.

  Plays a sine into the V7's own render endpoint via WASAPI, so the system's
  default playback device is left alone.

  Phases:
    A  silence   -> baseline, expect all-zero payloads
    B  441 Hz sine (exactly 100 samples/cycle at 44.1 kHz)
    C  silence   -> confirms the payload returns to zero

  Must run ELEVATED.
    powershell -ExecutionPolicy Bypass -File .\tools\win\capture-audio.ps1
#>

[CmdletBinding()]
param(
    [int]$SilenceSeconds = 5,
    [int]$ToneSeconds = 10,
    [double]$Freq = 441.0,
    [double]$Amplitude = 0.5,
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

Add-Type -Path (Join-Path $PSScriptRoot 'OpenV7Wasapi.dll')

$ep = Get-PnpDevice -PresentOnly | Where-Object {
    $_.Class -eq 'AudioEndpoint' -and $_.FriendlyName -like '*Numark V7*' -and $_.FriendlyName -like 'Speakers*'
}
if (-not $ep) { Write-Host 'No Numark V7 render endpoint found.' -ForegroundColor Red; exit 1 }
$devId = ($ep.InstanceId -replace '^SWD\\MMDEVAPI\\', '')
Write-Host "V7 render endpoint: $devId" -ForegroundColor Green

$ifaces = @()
foreach ($n in 1..8) {
    try {
        $h = [System.IO.File]::Open("\\.\USBPcap$n", 'Open', 'Read', 'ReadWrite')
        $h.Close(); $ifaces += "\\.\USBPcap$n"
    } catch {
        if ($_.Exception.Message -notmatch 'Could not find file') { $ifaces += "\\.\USBPcap$n" }
    }
}
if ($ifaces.Count -eq 0) {
    Write-Host 'No USBPcap interfaces. Run tools/win/enable-usbpcap.ps1 first.' -ForegroundColor Red
    exit 1
}

$notes = New-Object System.Collections.ArrayList
function Note($m) {
    $s = (Get-Date).ToString('HH:mm:ss.fff')
    [void]$notes.Add("$s  $m"); Write-Host "[$s] $m" -ForegroundColor Cyan
}

$procs = @()
foreach ($if in $ifaces) {
    $tag = ($if -replace '.*\\', '')
    $file = Join-Path $OutDir "audio-$tag.pcap"
    if (Test-Path $file) { Remove-Item $file -Force }
    $a = @('-d', $if, '-o', $file, '-A', '-s', '65535', '-b', '1048576')
    $p = Start-Process -FilePath $UsbPcapCmd -ArgumentList $a -PassThru -WindowStyle Hidden
    $procs += [pscustomobject]@{ Proc = $p; File = $file }
    Write-Host "  capturing $if -> $file" -ForegroundColor DarkGray
}
Start-Sleep -Seconds 2

try {
    Note "PHASE A - silence ($SilenceSeconds s)"
    Start-Sleep -Seconds $SilenceSeconds

    Note "PHASE B - $Freq Hz sine, amplitude $Amplitude ($ToneSeconds s)"
    $r = [WasapiTone]::Play($devId, $ToneSeconds, $Freq, $Amplitude)
    Note "  WASAPI: $r"

    Note "PHASE C - silence ($SilenceSeconds s)"
    Start-Sleep -Seconds $SilenceSeconds
}
finally {
    Note 'CAPTURE STOPPING'
    foreach ($e in $procs) {
        if (-not $e.Proc.HasExited) { Stop-Process -Id $e.Proc.Id -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 2
    Write-Host ''
    foreach ($e in $procs) {
        if (Test-Path $e.File) {
            Write-Host ("  {0}  {1:N1} KB" -f $e.File, ((Get-Item $e.File).Length / 1KB)) -ForegroundColor Green
        }
    }
    $notes | Set-Content -Path (Join-Path $OutDir 'audio-capture-notes.txt') -Encoding utf8
}
