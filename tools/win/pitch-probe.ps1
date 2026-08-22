<#
  OpenV7 - re-measurement of the motor results that the first probe pass could
  not establish reliably: the 0x49/0x69 pitch-trim pair, and the CC sweep.

  The first pass reported non-monotonic trim readings and a lone "hit" on
  B0 40, both of which were artifacts of under-filled measurement bins rather
  than device behaviour. This uses the corrected helpers in MotorLib.ps1 and
  starts by proving the harness reads a stopped platter as stopped.

  Run: powershell -ExecutionPolicy Bypass -File .\tools\win\pitch-probe.ps1
#>

[CmdletBinding()]
param([string]$OutFile = '')

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($OutFile)) { $OutFile = Join-Path $repo 'captures\pitch-probe.md' }

Add-Type -Path (Join-Path $PSScriptRoot 'OpenV7Midi.dll')
. (Join-Path $PSScriptRoot 'MotorLib.ps1')

$rcIn = [MidiMon]::OpenIn([MidiEnum]::FindIn('V7'))
$rcOut = [MidiMon]::OpenOut([MidiEnum]::FindOut('V7'))
if ($rcIn -ne 0 -or $rcOut -ne 0) { throw "MIDI open failed (in=$rcIn out=$rcOut)" }
[MidiMon]::RecordRaw(80000)

$report = New-Object System.Collections.ArrayList
function Say($s) { Write-Host $s; [void]$report.Add($s) }

function Send-Trim([int]$v) {
    Send-Motor 0x49 ([byte](($v -shr 7) -band 0x7F))   # MSB
    Send-Motor 0x69 ([byte]($v -band 0x7F))            # LSB (MSB cc + 32)
}

try {
    Say '# Numark V7 - pitch trim and CC sweep (corrected pass)'
    Say ''

    # -------------------------------------------------- harness sanity check
    Say '## Harness check'
    Say ''
    Stop-Platter
    $s = Get-SpeedSeries -Ms 2000
    $rpm = Get-SteadyRpm $s
    Say ("stopped platter reads: **$rpm RPM** over $($s.Count) bins " +
         "($(($s | Measure-Object Samples -Average).Average -as [int]) samples/bin)")
    if ($rpm -ne 0) { Say '' ; Say '> WARNING: dead-band did not clamp a stationary platter to zero.' }
    Say ''

    # ------------------------------------------ trim with the motor stopped
    Say '## `B0 49`/`B0 69` trim with the motor stopped'
    Say ''
    Say 'Does the trim pair drive the platter on its own, or only modulate a'
    Say 'motor already started?'
    Say ''
    foreach ($t in @(0, 4096, 8192, 12288, 16383)) {
        Send-Trim $t
        Start-Sleep -Milliseconds 1200
        $r = Get-SteadyRpm (Get-SpeedSeries -Ms 1800)
        Say ("- trim {0,5} -> **{1} RPM**" -f $t, $r)
    }
    Send-Trim 8192
    Stop-Platter
    Say ''

    # ------------------------------------------ trim while soft-started
    Say '## `B0 49`/`B0 69` trim while the platter is running'
    Say ''
    Send-Motor 0x45 0x00      # 33 1/3
    Send-Motor 0x46 0x00      # forward
    Send-Motor 0x43 0x00      # soft start
    Start-Sleep -Milliseconds 4500
    $base = Get-SteadyRpm (Get-SpeedSeries -Ms 2000)
    Say ("baseline, no trim written this pass: **$base RPM**")
    Say ''
    Say '| 14-bit trim | `49` MSB | `69` LSB | steady RPM | vs baseline |'
    Say '|---|---|---|---|---|'
    $rows = @()
    foreach ($t in @(0, 1024, 2048, 3072, 4096, 5190, 6144, 7168, 8192, 9216, 10240, 12288, 14336, 16383)) {
        Send-Trim $t
        Start-Sleep -Milliseconds 1600
        $r = Get-SteadyRpm (Get-SpeedSeries -Ms 2000)
        $delta = if ($base -and $base -ne 0 -and $r -ne $null) { [math]::Round($r - $base, 2) } else { $null }
        Say ('| {0} | `{1:X2}` | `{2:X2}` | {3} | {4} |' -f `
             $t, (($t -shr 7) -band 0x7F), ($t -band 0x7F), $r, $delta)
        $rows += [pscustomobject]@{ Trim = $t; Rpm = $r }
    }
    Say ''
    $mono = $true
    for ($i = 1; $i -lt $rows.Count; $i++) {
        if ($rows[$i].Rpm -ne $null -and $rows[$i-1].Rpm -ne $null -and $rows[$i].Rpm -lt $rows[$i-1].Rpm - 0.5) { $mono = $false }
    }
    Say ("monotonic with increasing trim: **{0}**" -f $(if ($mono) { 'yes' } else { 'no' }))
    Send-Trim 8192
    Stop-Platter
    Say ''

    # ------------------------------------------------------- CC sweep, clean
    Say '## CC sweep for motor effects'
    Say ''
    Say 'Each CC sent with `0x7F` then `0x00` while the platter is stopped,'
    Say 'with settle time and the corrected dead-band. Known motor commands'
    Say '(`0x41`-`0x49`) are skipped.'
    Say ''
    $known = @(0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x69)
    $hits = @()
    for ($cc = 0x00; $cc -le 0x7F; $cc++) {
        if ($known -contains $cc) { continue }
        Send-Motor ([byte]$cc) 0x7F
        Start-Sleep -Milliseconds 400
        $r = Get-SteadyRpm (Get-SpeedSeries -Ms 900)
        if ($r -ne $null -and [math]::Abs($r) -gt 1) {
            $hits += ('- `B0 {0:X2} 7F` -> platter moved (**{1} RPM**)' -f $cc, $r)
            Stop-Platter
        }
        Send-Motor ([byte]$cc) 0x00
        Start-Sleep -Milliseconds 150
    }
    if ($hits.Count -eq 0) {
        Say 'No CC outside the documented `0x41`-`0x49` block produced platter motion.'
    } else {
        foreach ($h in $hits) { Say $h }
    }
    Say ''
}
finally {
    Send-Motor 0x45 0x00
    Send-Motor 0x46 0x00
    Send-Motor 0x47 0x00
    Send-Motor 0x48 0x00
    Stop-Platter
    [MidiMon]::CloseOut()
    [MidiMon]::CloseIn()
    $report -join "`r`n" | Set-Content -Path $OutFile -Encoding utf8
    Write-Host ''
    Write-Host "report written to $OutFile" -ForegroundColor Green
}
