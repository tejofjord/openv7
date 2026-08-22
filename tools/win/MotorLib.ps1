<#
  OpenV7 - shared measurement helpers for Numark V7 motor probing.

  The platter reports an absolute 7-bit position on CC 0x00 once per USB frame
  (~1 kHz, measured 998.7/s). Differencing that counter turns it into a
  tachometer, which is how the motor commands get characterised without any
  external instrumentation.

  Dot-source this: . "$PSScriptRoot\MotorLib.ps1"
  Assumes OpenV7Midi.dll is already loaded and MidiMon in/out are open.
#>

# 3600 counts/rev, confirmed on hardware: with pitch trim explicitly zeroed the
# platter runs at 2000.3 counts/sec, and 2000/(33 1/3 RPM / 60) = 3600.5.
# Measure with a non-zero trim left over from an earlier command and you get
# ~3767 instead - the trim scales the speed, not the encoder.
$script:COUNTS_PER_REV = 3600.0
$script:SAMPLE_RATE = 998.7

function Send-Motor([byte]$cc, [byte]$v) { [void][MidiMon]::Send(0xB0, $cc, $v) }

# Signed per-sample delta of the wrapping 7-bit counter.
function Get-SignedDelta($cur, $prev) {
    $d = ($cur - $prev) % 128
    if ($d -gt 63) { $d -= 128 }
    if ($d -lt -63) { $d += 128 }
    return $d
}

<#
  Capture for $Ms and return a signed counts/sec + RPM series in $BinMs bins.

  Corrections that matter, all learned the hard way:

  * Speed is counts divided by WALL-CLOCK time, not by sample count. The
    device emits a position message on change, capped at the USB frame rate -
    so above ~15 RPM there is one per frame, but at low speed there are far
    fewer, and a stopped platter sends none at all. Dividing by (N / 998.7)
    silently assumes one message per frame and inflates slow speeds by the
    duty cycle.
  * A bin is therefore never dropped for being sparse; sparse IS the signal
    at low RPM. An empty bin means genuinely no motion.
  * A stationary platter dithers +/-1 count on the encoder boundary, so
    anything inside the dead-band is clamped to zero.
#>
function Get-SpeedSeries {
    param(
        [int]$Ms,
        [int]$BinMs = 200,
        [double]$DeadBandCountsPerSec = 60.0
    )

    [MidiMon]::Reset()
    Start-Sleep -Milliseconds $Ms
    $raw = [MidiMon]::Raw()

    $sum = @{}; $n = @{}
    $prev = -1; $t0 = -1
    foreach ($r in $raw) {
        $p = $r -split ' '
        $t = [int64]$p[0]; $st = [int]$p[1]; $d1 = [int]$p[2]; $d2 = [int]$p[3]
        if ($st -ne 0xB0 -or $d1 -ne 0x00) { continue }
        if ($t0 -lt 0) { $t0 = $t; $prev = $d2; continue }
        $b = [int][math]::Floor(($t - $t0) / $BinMs)
        if (-not $sum.ContainsKey($b)) { $sum[$b] = 0; $n[$b] = 0 }
        $sum[$b] += (Get-SignedDelta $d2 $prev)
        $n[$b]++
        $prev = $d2
    }

    # Emit every whole bin in the window, including ones with no messages -
    # "no messages" is a real reading (stopped), not missing data.
    $series = New-Object System.Collections.ArrayList
    # Bins are relative to the first message, so the trailing one is usually
    # truncated - drop it rather than report a short bin as a slow one.
    $nBins = [int][math]::Floor($Ms / $BinMs) - 1
    for ($b = 0; $b -lt $nBins; $b++) {
        $counts = 0; $samples = 0
        if ($sum.ContainsKey($b)) { $counts = $sum[$b]; $samples = $n[$b] }
        $cps = $counts / ($BinMs / 1000.0)
        if ([math]::Abs($cps) -lt $DeadBandCountsPerSec) { $cps = 0.0 }
        [void]$series.Add([pscustomobject]@{
            TimeMs       = [int]($b * $BinMs)
            Samples      = $samples
            CountsPerSec = [math]::Round($cps, 1)
            Rpm          = [math]::Round($cps / $script:COUNTS_PER_REV * 60.0, 2)
        })
    }
    return $series
}

# Median RPM from $FromMs onward - median, not mean, so a single ramp or
# glitch bin cannot drag a steady-state reading.
function Get-SteadyRpm($series, $fromMs = 0) {
    $vals = @($series | Where-Object { $_.TimeMs -ge $fromMs } | ForEach-Object { $_.Rpm })
    if ($vals.Count -eq 0) { return $null }
    $sorted = @($vals | Sort-Object)
    $mid = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return $sorted[$mid] }
    return [math]::Round(($sorted[$mid - 1] + $sorted[$mid]) / 2.0, 2)
}

function Show-Series($series) {
    Write-Host ("  {0,7}  {1,6}  {2,11}  {3,8}   profile" -f 'time ms', 'n', 'counts/sec', 'RPM')
    foreach ($s in $series) {
        $bar = ''
        $mag = [math]::Min(40, [math]::Abs($s.Rpm) * 0.8)
        if ($mag -ge 1) { $bar = ('#' * [int]$mag) }
        if ($s.Rpm -lt 0) { $bar = '<' + $bar }
        Write-Host ("  {0,7}  {1,6}  {2,11}  {3,8}   {4}" -f $s.TimeMs, $s.Samples, $s.CountsPerSec, $s.Rpm, $bar)
    }
}

function Stop-Platter {
    Send-Motor 0x44 0x00
    Start-Sleep -Milliseconds 1500
    Send-Motor 0x42 0x00
    Start-Sleep -Milliseconds 500
}
