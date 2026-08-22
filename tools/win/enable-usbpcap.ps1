<#
  OpenV7 - attach the USBPcap filter without rebooting.

  USBPcap installs itself as an UpperFilters entry on the USB device class
  ({36FC9E60-C465-11CF-8056-444553540000}). Filters are attached when a device
  stack is built, which normally means at boot - hence the usual "reboot after
  installing USBPcap" advice.

  Restarting the USB root hubs rebuilds their stacks with the filter attached,
  which creates the \\.\USBPcapN control devices and avoids the reboot. Every
  USB device on a restarted hub briefly disconnects and re-enumerates, so
  keyboards and mice will blink out for a second or two.

  Must run ELEVATED.
    powershell -ExecutionPolicy Bypass -File .\tools\win\enable-usbpcap.ps1
#>

[CmdletBinding()]
param(
    [string]$UsbPcapCmd = 'C:\Program Files\USBPcap\USBPcapCMD.exe',
    [switch]$AllHubs
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
          [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'ERROR: must run elevated.' -ForegroundColor Red
    exit 1
}

# --extcap-interfaces returns nothing on some machines even when the control
# devices plainly exist, so fall back to probing the device paths: anything
# that does not fail with "could not find file" is present, including the
# access-denied and busy cases.
function Get-Ifaces {
    $found = @()
    foreach ($line in (& $UsbPcapCmd --extcap-interfaces 2>$null)) {
        if ($line -match 'value=(\\\\\.\\USBPcap\d+)') { $found += $Matches[1] }
    }
    if ($found.Count -gt 0) { return $found }

    foreach ($n in 1..8) {
        $path = "\\.\USBPcap$n"
        try {
            $h = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            $h.Close(); $found += $path
        } catch {
            if ($_.Exception.Message -notmatch 'Could not find file') { $found += $path }
        }
    }
    return $found
}

Write-Host '--- preconditions ---' -ForegroundColor Cyan
$cls = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{36FC9E60-C465-11CF-8056-444553540000}'
Write-Host "  USB class UpperFilters : $($cls.UpperFilters -join ',')"
Write-Host "  USBPcap.sys staged     : $(Test-Path 'C:\Windows\System32\drivers\USBPcap.sys')"
if ($cls.UpperFilters -notcontains 'USBPcap') {
    Write-Host 'USBPcap is not registered as a USB class filter - reinstall it.' -ForegroundColor Red
    exit 1
}

$before = Get-Ifaces
Write-Host "  interfaces before      : $(if ($before) { $before -join ',' } else { '(none)' })"
if ($before.Count -gt 0) {
    Write-Host 'USBPcap is already attached - nothing to do.' -ForegroundColor Green
    exit 0
}

# The V7's hub first; that is the one the capture actually needs.
$v7Parent = (Get-PnpDeviceProperty -InstanceId 'USB\VID_15E4&PID_0075\NO_SERIAL_NUMBER' `
                -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
$hubs = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\ROOT_HUB*' }
if (-not $AllHubs -and $v7Parent) {
    $hubs = $hubs | Where-Object { $_.InstanceId -eq $v7Parent }
    Write-Host "  restarting only the V7's hub: $v7Parent"
} else {
    Write-Host '  restarting all root hubs'
}

Write-Host ''
Write-Host '--- restarting root hub(s); USB devices will blink out briefly ---' -ForegroundColor Yellow
# Windows PowerShell 5.1's PnpDevice module has no Restart-PnpDevice, so use
# pnputil - one atomic restart, rather than a disable/enable pair that would
# leave the hub down if the second half failed.
foreach ($h in $hubs) {
    $done = $false
    try {
        $out = & pnputil /restart-device "$($h.InstanceId)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  restarted $($h.InstanceId)" -ForegroundColor Green
            $done = $true
        } else {
            Write-Host "  pnputil rc=$LASTEXITCODE : $($out -join ' ')" -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "  pnputil unavailable: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    if (-not $done) {
        Write-Host '  falling back to disable/enable' -ForegroundColor DarkYellow
        try {
            Disable-PnpDevice -InstanceId $h.InstanceId -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds 2
            Enable-PnpDevice -InstanceId $h.InstanceId -Confirm:$false -ErrorAction Stop
            Write-Host "  restarted $($h.InstanceId)" -ForegroundColor Green
        } catch {
            Write-Host "  FAILED    $($h.InstanceId) : $($_.Exception.Message)" -ForegroundColor Red
            # never leave a hub disabled
            try { Enable-PnpDevice -InstanceId $h.InstanceId -Confirm:$false -ErrorAction Stop } catch { }
        }
    }
}

Write-Host ''
Write-Host '--- waiting for re-enumeration ---'
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    $now = Get-Ifaces
    if ($now.Count -gt 0) {
        Write-Host ''
        Write-Host "USBPcap attached: $($now -join ', ')" -ForegroundColor Green
        $v7 = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
              Where-Object { $_.InstanceId -like '*VID_15E4*PID_0075*' -and $_.Class -eq 'USB' }
        Write-Host "Numark V7: $(if ($v7) { $v7.Status } else { 'NOT PRESENT - replug it' })"
        Write-Host ''
        Write-Host 'You can now run captures\capture-v7.ps1 without rebooting.' -ForegroundColor Green
        exit 0
    }
    Write-Host -NoNewline "`r  waiting... $($i + 1)s "
}

Write-Host ''
Write-Host 'No USBPcap interfaces appeared.' -ForegroundColor Yellow
Write-Host 'Try -AllHubs, or fall back to a reboot.' -ForegroundColor Yellow
exit 1
