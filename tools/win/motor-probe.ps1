<#
  OpenV7 - Numark V7 motor command characterisation

  The platter reports an absolute 7-bit position on CC 0x00 once per USB frame
  (~1 kHz). That makes it a tachometer: send a motor command, watch the counter,
  and read the platter's actual response. This script uses that loop to settle
  the motor commands PROTOCOL.md still marks unconfirmed - notably direction
  (the "reverse" open item), instant stop, the ramp-time parameters and the
  pitch-trim pair.

  Everything is measured, not assumed. Run:
    powershell -ExecutionPolicy Bypass -File .\tools\win\motor-probe.ps1

  The platter spins during this. It is stopped in a finally block on any exit.
#>

[CmdletBinding()]
param(
    [string]$OutFile = '',
    [int]$BinMs = 100
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path $repo 'captures\motor-probe.md'
}

$dll = Join-Path $PSScriptRoot 'OpenV7Midi.dll'
if (-not (Test-Path $dll)) { throw 'OpenV7Midi.dll missing - run tools/win/build.ps1' }
Add-Type -Path $dll

$rcIn = [MidiMon]::OpenIn([MidiEnum]::FindIn('V7'))
$rcOut = [MidiMon]::OpenOut([MidiEnum]::FindOut('V7'))
if ($rcIn -ne 0 -or $rcOut -ne 0) { throw "MIDI open failed (in=$rcIn out=$rcOut)" }
[MidiMon]::RecordRaw(80000)

$COUNTS_PER_REV = 3767.0     # measured; see docs/PROTOCOL.md
$report = New-Object System.Collections.ArrayList
function Say($s) { Write-Host $s; [void]$report.Add($s) }

function Send-Motor([byte]$cc, [byte]$v) { [void][MidiMon]::Send(0xB0, $cc, $v) }

# Signed per-sample delta of the wrapping 7-bit counter.
function Get-SignedDelta($cur, $prev) {
    $d = ($cur - $prev) % 128
    if ($d -gt 63) { $d -= 128 }
    if ($d -lt -63) { $d += 128 }
    return $d
}

# Capture for $ms and return a time series of signed counts/sec in $BinMs bins.
function Get-SpeedSeries($ms) {
    [MidiMon]::Reset()
    Start-Sleep -Milliseconds $ms
    $raw = [MidiMon]::Raw()
    $bins = @{}
    $prev = -1; $t0 = -1
    foreach ($r in $raw) {
        $p = $r -split ' '
        $t = [int64]$p[0]; $st = [int]$p[1]; $d1 = [int]$p[2]; $d2 = [int]$p[3]
        if ($st -ne 0xB0 -or $d1 -ne 0x00) { continue }
        if ($t0 -lt 0) { $t0 = $t }
        if ($prev -ge 0) {
            $b = [math]::Floor(($t - $t0) / $BinMs)
            if (-not $bins.ContainsKey($b)) { $bins[$b] = @{ Sum = 0; N = 0 } }
            $bins[$b].Sum += (Get-SignedDelta $d2 $prev)
            $bins[$b].N++
        }
        $prev = $d2
    }
    $series = @()
    foreach ($b in ($bins.Keys | Sort-Object)) {
        $e = $bins[$b]
        # counts/sec = counts accumulated / seconds of samples in the bin
        $secs = $e.N / 998.7
        $series += [pscustomobject]@{
            TimeMs = [int]($b * $BinMs)
            CountsPerSec = if ($secs -gt 0) { [math]::Round($e.Sum / $secs, 1) } else { 0 }
            Rpm = if ($secs -gt 0) { [math]::Round(($e.Sum / $secs) / $COUNTS_PER_REV * 60.0, 2) } else { 0 }
        }
    }
    return $series
}

function Show-Series($series, $label) {
    Say "``````"
    Say ("  {0,7}  {1,12}  {2,8}   profile" -f 'time ms', 'counts/sec', 'RPM')
    foreach ($s in $series) {
        $bar = ''
        $mag = [math]::Min(40, [math]::Abs($s.Rpm) * 0.8)
        if ($mag -ge 1) { $bar = ('#' * [int]$mag) }
        if ($s.Rpm -lt 0) { $bar = '<' + $bar }
        Say ("  {0,7}  {1,12}  {2,8}   {3}" -f $s.TimeMs, $s.CountsPerSec, $s.Rpm, $bar)
    }
    Say "``````"
}

function Get-SteadyRpm($series, $fromMs) {
    $vals = @($series | Where-Object { $_.TimeMs -ge $fromMs } | ForEach-Object { $_.Rpm })
    if ($vals.Count -eq 0) { return 0 }
    return [math]::Round((($vals | Measure-Object -Average).Average), 2)
}

function Stop-Platter {
    Send-Motor 0x44 0x00
    Start-Sleep -Milliseconds 1500
    Send-Motor 0x42 0x00
    Start-Sleep -Milliseconds 400
}

try {
    Say '# Numark V7 - motor command characterisation'
    Say ''
    Say 'Measured by using the platter''s own CC `0x00` position counter as a'
    Say ("tachometer ({0} counts/rev, sampled at ~1 kHz). Values are signed:" -f $COUNTS_PER_REV)
    Say 'negative RPM means the platter is turning backwards.'
    Say ''

    # ---------------------------------------------------------------- baseline
    Stop-Platter
    Say '## Baseline (motor stopped)'
    Say ''
    $s = Get-SpeedSeries 1000
    Say ("stationary RPM: {0}" -f (Get-SteadyRpm $s 0))
    Say ''

    # ------------------------------------------------- 0x43 soft start / 0x44
    Say '## `B0 43 00` soft start, then `B0 44 00` brake'
    Say ''
    Send-Motor 0x43 0x00
    $s = Get-SpeedSeries 4000
    Show-Series $s 'soft start'
    $softSteady = Get-SteadyRpm $s 2500
    Say ("steady RPM after soft start: **{0}**" -f $softSteady)
    Say ''
    Send-Motor 0x44 0x00
    $s = Get-SpeedSeries 3000
    Show-Series $s 'brake'
    Say ''
    Send-Motor 0x42 0x00; Start-Sleep -Milliseconds 500

    # ------------------------------------------------ 0x41 instant start/stop
    Say '## `B0 41 00` instant start, then `B0 42 00` instant stop'
    Say ''
    Send-Motor 0x41 0x00
    $s = Get-SpeedSeries 3000
    Show-Series $s 'instant start'
    Say ("steady RPM after instant start: **{0}**" -f (Get-SteadyRpm $s 1500))
    Say ''
    Send-Motor 0x42 0x00
    $s = Get-SpeedSeries 2000
    Show-Series $s 'instant stop'
    Say ''
    Stop-Platter

    # --------------------------------------------------------- 0x45 RPM select
    Say '## `B0 45 vv` RPM select'
    Say ''
    foreach ($rpmSel in @(0x00, 0x01)) {
        Send-Motor 0x45 ([byte]$rpmSel)
        Send-Motor 0x43 0x00
        Start-Sleep -Milliseconds 4000
        $s = Get-SpeedSeries 2500
        $r = Get-SteadyRpm $s 0
        Say ("- ``B0 45 {0:X2}`` -> steady **{1} RPM**" -f $rpmSel, $r)
        Stop-Platter
    }
    Send-Motor 0x45 0x00
    Say ''

    # ------------------------------------------------------- 0x46 direction
    Say '## `B0 46 vv` direction (PROTOCOL.md open item: reverse)'
    Say ''
    foreach ($dir in @(0x00, 0x01)) {
        Send-Motor 0x42 0x00; Start-Sleep -Milliseconds 400
        Send-Motor 0x46 ([byte]$dir)
        Start-Sleep -Milliseconds 200
        Send-Motor 0x43 0x00
        $s = Get-SpeedSeries 4000
        $r = Get-SteadyRpm $s 2500
        $verdict = if ($r -lt -1) { '**REVERSE**' } elseif ($r -gt 1) { 'forward' } else { 'no motion' }
        Say ("- ``B0 46 {0:X2}`` + soft start -> steady **{1} RPM** ({2})" -f $dir, $r, $verdict)
        Show-Series $s "direction $dir"
        Stop-Platter
    }
    Send-Motor 0x46 0x00
    Say ''

    # --------------------------------------------------- 0x47 / 0x48 ramp times
    Say '## `B0 47 vv` / `B0 48 vv` ramp times'
    Say ''
    Say 'Time from command to reaching 90% of steady speed (start ramp), and'
    Say 'from brake to a stop, for a few parameter values.'
    Say ''
    foreach ($rv in @(0x00, 0x20, 0x40, 0x7F)) {
        Send-Motor 0x47 ([byte]$rv)
        Send-Motor 0x48 ([byte]$rv)
        Start-Sleep -Milliseconds 200
        Send-Motor 0x43 0x00
        $s = Get-SpeedSeries 5000
        $peak = ($s | Measure-Object Rpm -Maximum).Maximum
        $t90 = ($s | Where-Object { $_.Rpm -ge $peak * 0.9 } | Select-Object -First 1)
        $startMs = if ($t90) { $t90.TimeMs } else { -1 }
        Send-Motor 0x44 0x00
        $s2 = Get-SpeedSeries 5000
        $tStop = ($s2 | Where-Object { [math]::Abs($_.Rpm) -lt 1 } | Select-Object -First 1)
        $stopMs = if ($tStop) { $tStop.TimeMs } else { -1 }
        Say ("- ``47/48 = {0:X2}`` -> spin-up to 90% in **{1} ms**, stop in **{2} ms** (peak {3} RPM)" -f `
             $rv, $startMs, $stopMs, $peak)
        Stop-Platter
    }
    Send-Motor 0x47 0x00; Send-Motor 0x48 0x00
    Say ''

    # ------------------------------------------------- 0x49 / 0x69 pitch trim
    Say '## `B0 49 msb` + `B0 69 lsb` pitch trim'
    Say ''
    Say 'Steady speed for a range of 14-bit trim values, to establish sign,'
    Say 'scale, and whether negative values drive the platter backwards.'
    Say ''
    Send-Motor 0x43 0x00
    Start-Sleep -Milliseconds 4000
    $baseRpm = Get-SteadyRpm (Get-SpeedSeries 2000) 0
    Say ("baseline (no trim sent): **{0} RPM**" -f $baseRpm)
    Say ''
    foreach ($trim in @(0, 1000, 5190, 8192, 10000, 16000)) {
        $msb = [byte](($trim -shr 7) -band 0x7F)
        $lsb = [byte]($trim -band 0x7F)
        Send-Motor 0x49 $msb
        Send-Motor 0x69 $lsb
        Start-Sleep -Milliseconds 1500
        $r = Get-SteadyRpm (Get-SpeedSeries 2000) 0
        $pct = if ($baseRpm -ne 0) { [math]::Round(($r - $baseRpm) / $baseRpm * 100.0, 2) } else { 0 }
        Say ("- trim {0,6} (``49 {1:X2}`` ``69 {2:X2}``) -> **{3} RPM** ({4:+0.00;-0.00;0}% vs baseline)" -f `
             $trim, $msb, $lsb, $r, $pct)
    }
    Stop-Platter
    Say ''

    # ----------------------------------------------------------- command sweep
    Say '## Unknown CC sweep'
    Say ''
    Say 'Every CC in `0x40`-`0x60` sent with value 0 and 0x7F while the platter'
    Say 'is stopped, looking for any that produces motion or a device reply.'
    Say ''
    $hits = @()
    for ($cc = 0x40; $cc -le 0x60; $cc++) {
        if ($cc -in @(0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48,0x49)) { continue }
        foreach ($v in @(0x00, 0x7F)) {
            Send-Motor ([byte]$cc) ([byte]$v)
            Start-Sleep -Milliseconds 250
            $s = Get-SpeedSeries 600
            $r = Get-SteadyRpm $s 0
            if ([math]::Abs($r) -gt 1) {
                $hits += ("- ``B0 {0:X2} {1:X2}`` -> platter moved ({2} RPM)" -f $cc, $v, $r)
                Stop-Platter
            }
        }
    }
    if ($hits.Count -eq 0) { Say 'No additional CC in that range produced platter motion.' }
    else { foreach ($h in $hits) { Say $h } }
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
