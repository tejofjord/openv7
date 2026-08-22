<#
  OpenV7 - capture the vendor driver's device init / recovery sequence.

  Answers open item #2: how the stock driver brings a device up (and back) so
  OpenV7 can reproduce it instead of relying on a physical power cycle.

  Restarting the V7's device node with pnputil tears down and rebuilds the
  driver's stack, so the capture contains the complete bring-up: the EP0
  control transfers, the interface/alt-setting selection, and the point where
  streaming resumes. That is the same path the driver takes when it recovers a
  stuck device, minus the physical unplug.

  Must run ELEVATED.
    powershell -ExecutionPolicy Bypass -File .\tools\win\capture-init.ps1
#>

[CmdletBinding()]
param(
    [int]$PreSeconds = 4,
    # 'cycle' = disable/enable, forcing a real removal and re-arrival so the
    # function driver redoes its vendor handshake. 'restart' only bounces the
    # driver stack, which the device survives with its configuration intact.
    [ValidateSet('restart', 'cycle')][string]$Method = 'cycle',
    [int]$PostSeconds = 20,
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

# USBPcapCMD --extcap-interfaces returns empty on this machine; probe directly.
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
Write-Host "USBPcap interfaces: $($ifaces -join ', ')" -ForegroundColor Green

$notes = New-Object System.Collections.ArrayList
function Note($m) {
    $s = (Get-Date).ToString('HH:mm:ss.fff')
    [void]$notes.Add("$s  $m"); Write-Host "[$s] $m" -ForegroundColor Cyan
}

$procs = @()
foreach ($if in $ifaces) {
    $tag = ($if -replace '.*\\', '')
    $file = Join-Path $OutDir "init-$Method-$tag.pcap"
    if (Test-Path $file) { Remove-Item $file -Force }
    $a = @('-d', $if, '-o', $file, '-A', '-s', '65535', '-b', '1048576')
    $p = Start-Process -FilePath $UsbPcapCmd -ArgumentList $a -PassThru -WindowStyle Hidden
    $procs += [pscustomobject]@{ Proc = $p; File = $file }
    Write-Host "  capturing $if -> $file" -ForegroundColor DarkGray
}
Start-Sleep -Seconds 2

$v7 = 'USB\VID_15E4&PID_0075\NO_SERIAL_NUMBER'
try {
    Note "settling ($PreSeconds s)"
    Start-Sleep -Seconds $PreSeconds

    if ($Method -eq 'cycle') {
        # pnputil /restart-device only bounces the driver stack - the device
        # keeps its address and configuration, so the function driver skips its
        # vendor handshake. Disabling and re-enabling forces a real removal and
        # re-arrival, which makes v7_usb.sys redo the full Ploytec bring-up.
        Note 'DISABLING the V7 device node'
        Disable-PnpDevice -InstanceId $v7 -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 4
        Note 'ENABLING the V7 device node (expect full vendor init)'
        Enable-PnpDevice -InstanceId $v7 -Confirm:$false -ErrorAction Stop
    } else {
        Note 'RESTARTING the V7 device node (driver stack bounce)'
        $out = & pnputil /restart-device "$v7" 2>&1
        Note "pnputil rc=$LASTEXITCODE"
        if ($LASTEXITCODE -ne 0) { Write-Host ($out -join "`n") -ForegroundColor DarkYellow }
    }

    Note "waiting for re-enumeration and bring-up ($PostSeconds s)"
    Start-Sleep -Seconds $PostSeconds

    $d = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
         Where-Object { $_.InstanceId -like '*VID_15E4*PID_0075*' -and $_.Class -eq 'USB' }
    Note "V7 status after restart: $(if ($d) { $d.Status } else { 'ABSENT' })"
}
finally {
    # never leave the device disabled, whatever went wrong above
    try {
        $d = Get-PnpDevice -InstanceId $v7 -ErrorAction SilentlyContinue
        if ($d -and $d.Status -ne 'OK') {
            Note "V7 not OK ($($d.Status)) - re-enabling"
            Enable-PnpDevice -InstanceId $v7 -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
    } catch { }

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
    $notes | Set-Content -Path (Join-Path $OutDir 'init-capture-notes.txt') -Encoding utf8
}
