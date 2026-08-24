<#
  OpenV7 - X1 analysis: what the raw platter stream actually contains.

  Input is a TSV produced by tshark from a USBPcap capture:

    tshark -r cap.pcap -Y 'usb.endpoint_address==0x83 && usb.data_len>0' `
           -T fields -e frame.time_relative -e usb.data_len -e usb.capdata

  A 42-byte control frame from the V7 usually looks like

    b0 00 6c   e0 70 50   fd fd ... fd   00
    |          |          |              `- terminator
    |          |          `- 0xFD idle filler
    |          `- pitch-bend, LSB then MSB
    `- CC 0x00 (deck A platter position), or 0x02 for deck B

  but the frame is a TRANSPORT container, not a message container, and this
  script used to assume otherwise. Measured on the reference capture, 11.7% of
  frames begin part-way through a message that the previous frame started. An
  earlier version skipped every frame whose first byte was not 0xB0 and read the
  pitch-bend from fixed offsets 3..5, so it dropped roughly one frame in eight
  and, on the frames it kept, could read 0xFD filler as a pitch-bend byte.

  The content is therefore parsed from the CONCATENATED stream: strip the 0xFD
  filler and the trailing terminator from every frame, join, and parse MIDI with
  running status. Frame timestamps are still used for arrival cadence, which is
  the one thing that genuinely is per-frame.

  This answers the X1 questions from docs/HANDOFF-WINDOWS.md that can be
  settled from the wire alone:

    Q2  is 0xE0 a timestamp or a position?   -> does it advance at a fixed rate
                                                independent of platter speed
    Q3  does the OEM decimate or rate-limit? -> frames/sec vs the published rate
    Q4  does B0 00 still wrap at 7 bits?     -> value range and delta pattern
    X5  arrival-time distribution            -> histogram, not min/max

  Usage: .\analyze-platter-frames.ps1 -Tsv .\x83.tsv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Tsv,
    [double]$GapBucketMs = 1.0,
    [int]$SampleRows = 12
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Tsv)) { throw "not found: $Tsv" }

# Pass 1: frames, kept whole. Arrival cadence is a property of the transport, so
# it is measured here and never from parsed messages.
$frames = New-Object System.Collections.ArrayList
$stream = New-Object 'System.Collections.Generic.List[int]'
$stamps = New-Object 'System.Collections.Generic.List[double]'
$spanning = 0
foreach ($line in [System.IO.File]::ReadLines((Resolve-Path $Tsv))) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $p = $line -split "`t"
    if ($p.Count -lt 3) { continue }
    $hex = $p[2] -replace '[^0-9a-fA-F]', ''
    if ($hex.Length -lt 12) { continue }

    $b = New-Object 'System.Collections.Generic.List[int]'
    for ($i = 0; $i -lt $hex.Length; $i += 2) {
        $b.Add([Convert]::ToInt32($hex.Substring($i, 2), 16))
    }
    $t = [double]$p[0]
    if (($b[0] -band 0x80) -eq 0) { $spanning++ }
    [void]$frames.Add([pscustomobject]@{ T = $t; Tail = $b[$b.Count - 1]; First = $b[0] })

    # Strip the 0xFD filler and the trailing terminator, then append. Each byte
    # carries its frame's timestamp so a parsed message can be dated by the
    # frame its LAST byte arrived in, which is when a host actually has it.
    for ($i = 0; $i -lt $b.Count - 1; $i++) {
        if ($b[$i] -eq 0xFD) { continue }
        $stream.Add($b[$i]); $stamps.Add($t)
    }
}

if ($frames.Count -eq 0) { throw 'no frames parsed' }

# Pass 2: MIDI out of the concatenated stream, with running status.
$msgs = New-Object System.Collections.ArrayList
$status = 0; $data = New-Object 'System.Collections.Generic.List[int]'
for ($i = 0; $i -lt $stream.Count; $i++) {
    $x = $stream[$i]
    if ($x -ge 0xF8) { continue }                       # realtime is transparent
    if (($x -band 0x80) -ne 0) { $status = $x; $data.Clear(); continue }
    if ($status -eq 0) { continue }                     # data with no status yet
    $data.Add($x)
    $need = if (($status -band 0xF0) -eq 0xC0 -or ($status -band 0xF0) -eq 0xD0) { 1 } else { 2 }
    if ($data.Count -lt $need) { continue }
    [void]$msgs.Add([pscustomobject]@{
        T      = $stamps[$i]
        Status = $status
        D1     = $data[0]
        D2     = if ($need -eq 2) { $data[1] } else { $null }
    })
    $data.Clear()                                       # running status stays armed
}

$posMsgs = @($msgs | Where-Object { $_.Status -eq 0xB0 -and ($_.D1 -eq 0x00 -or $_.D1 -eq 0x02) })
$pbMsgs  = @($msgs | Where-Object { ($_.Status -band 0xF0) -eq 0xE0 })
if ($posMsgs.Count -eq 0) { throw 'no platter position messages parsed' }

$t0 = $frames[0].T
$t1 = $frames[$frames.Count - 1].T
$dur = $t1 - $t0

Write-Host ''
Write-Host '=== FRAME STRUCTURE ===' -ForegroundColor Cyan
Write-Host ("  frames parsed      : {0}" -f $frames.Count)
Write-Host ("  window             : {0:N3} s  ({1:N1} frames/s)" -f $dur, ($frames.Count / $dur))
Write-Host ("  opening mid-message: {0} ({1:N1}%) <- why the stream is parsed whole" -f `
    $spanning, ($spanning * 100.0 / $frames.Count))
Write-Host ("  MIDI messages      : {0}" -f $msgs.Count)
$ccSet = $posMsgs | Group-Object D1 | ForEach-Object { '0x{0:X2} x{1}' -f [int]$_.Name, $_.Count }
Write-Host ("  position CCs       : {0}" -f ($ccSet -join ', '))
Write-Host ("  0xE0 timestamps    : {0}  (positions: {1}{2})" -f $pbMsgs.Count, $posMsgs.Count,
    $(if ($pbMsgs.Count -eq $posMsgs.Count) { ' - paired 1:1' } else { ' - NOT PAIRED' }))
$tails = $frames | Group-Object Tail | ForEach-Object { '0x{0:X2} x{1}' -f [int]$_.Name, $_.Count }
Write-Host ("  terminator byte    : {0}" -f ($tails -join ', '))

# ---------------------------------------------------------------- Q4: wrap ---
Write-Host ''
Write-Host '=== Q4  does B0 00 wrap at 7 bits? ===' -ForegroundColor Cyan
$vals = $posMsgs | ForEach-Object { $_.D2 }
$mn = ($vals | Measure-Object -Minimum).Minimum
$mx = ($vals | Measure-Object -Maximum).Maximum
Write-Host ("  value range        : {0} .. {1}" -f $mn, $mx)
Write-Host ("  distinct values    : {0}" -f ($vals | Sort-Object -Unique).Count)
$wraps = 0; $deltas = New-Object System.Collections.ArrayList
for ($i = 1; $i -lt $posMsgs.Count; $i++) {
    $d = $posMsgs[$i].D2 - $posMsgs[$i - 1].D2
    if ($d -lt -64) { $wraps++; $d += 128 }
    elseif ($d -gt 64) { $d -= 128 }
    [void]$deltas.Add($d)
}
$avgD = ($deltas | Measure-Object -Average).Average
Write-Host ("  wrap events        : {0}  (high->low jumps)" -f $wraps)
Write-Host ("  mean delta/message : {0:N3} counts" -f $avgD)
if ($mx -le 127 -and $wraps -gt 0) {
    Write-Host '  VERDICT: still a wrapping 7-bit counter - the driver does NOT widen or unwrap it' -ForegroundColor Yellow
}

# ------------------------------------------------- Q2: timestamp or position ---
Write-Host ''
Write-Host '=== Q2  is 0xE0 a timestamp or a position? ===' -ForegroundColor Cyan
$pb = $pbMsgs
if ($pb.Count -gt 2) {
    $sum = 0.0; $n = 0
    for ($i = 1; $i -lt $pb.Count; $i++) {
        $prev = $pb[$i - 1].D1 -bor ($pb[$i - 1].D2 -shl 7)
        $cur  = $pb[$i].D1     -bor ($pb[$i].D2     -shl 7)
        $d = ($cur - $prev) % 16384
        if ($d -lt 0) { $d += 16384 }
        $dt = $pb[$i].T - $pb[$i - 1].T
        if ($dt -gt 0 -and $d -gt 0 -and $d -lt 16000) { $sum += $d / $dt; $n++ }
    }
    if ($n) {
        $rate = $sum / $n
        Write-Host ("  mean advance       : {0:N0} units/sec" -f $rate)
        Write-Host ("  vs 2,822,400 Hz    : {0:P2} error" -f (($rate - 2822400) / 2822400))
        Write-Host '  A position would track platter speed; a fixed rate means TIMESTAMP.' -ForegroundColor Yellow
    }
}

# ------------------------------------------------------ Q3 / X5: arrival times ---
Write-Host ''
Write-Host '=== X5  arrival-time distribution (not min/max) ===' -ForegroundColor Cyan
$gaps = New-Object System.Collections.ArrayList
for ($i = 1; $i -lt $frames.Count; $i++) {
    [void]$gaps.Add((($frames[$i].T - $frames[$i - 1].T) * 1000.0))
}
$gs = $gaps | Measure-Object -Average -Minimum -Maximum
Write-Host ("  mean gap           : {0:N3} ms   ({1:N1} frames/s)" -f $gs.Average, (1000.0 / $gs.Average))
$sorted = @($gaps | Sort-Object)
function Pct($p) { return $sorted[[int][math]::Floor($sorted.Count * $p)] }
Write-Host ("  p50 / p90 / p99    : {0:N2} / {1:N2} / {2:N2} ms" -f (Pct 0.50), (Pct 0.90), (Pct 0.99))
Write-Host ("  min / max          : {0:N2} / {1:N2} ms" -f $gs.Minimum, $gs.Maximum)
Write-Host ''
Write-Host '  histogram:'
$buckets = @{}
foreach ($g in $gaps) {
    $k = [int][math]::Floor($g / $GapBucketMs)
    if ($buckets.ContainsKey($k)) { $buckets[$k]++ } else { $buckets[$k] = 1 }
}
$total = $gaps.Count
foreach ($k in ($buckets.Keys | Sort-Object)) {
    $pct = $buckets[$k] * 100.0 / $total
    if ($pct -lt 0.05) { continue }
    $bar = '#' * [int][math]::Min(50, [math]::Round($pct / 2))
    Write-Host ("    {0,6:N1}-{1,-6:N1} ms {2,7} {3,6:N2}%  {4}" -f `
        ($k * $GapBucketMs), (($k + 1) * $GapBucketMs), $buckets[$k], $pct, $bar)
}

Write-Host ''
Write-Host '=== sample messages (parsed from the stream, not per frame) ===' -ForegroundColor Cyan
foreach ($m in ($msgs | Select-Object -First $SampleRows)) {
    Write-Host ("  t={0,10:N6}  {1:X2} {2:X2} {3}" -f `
        $m.T, $m.Status, $m.D1, $(if ($null -ne $m.D2) { '{0:X2}' -f $m.D2 } else { '--' }))
}
