<#
  OpenV7 - X1 analysis: what the raw platter stream actually contains.

  Input is a TSV produced by tshark from a USBPcap capture:

    tshark -r cap.pcap -Y 'usb.endpoint_address==0x83 && usb.data_len>0' `
           -T fields -e frame.time_relative -e usb.data_len -e usb.capdata

  Each 42-byte control frame from the V7 looks like

    b0 00 6c   e0 70 50   fd fd ... fd   00
    |          |          |              `- terminator
    |          |          `- 0xFD idle filler
    |          `- pitch-bend, LSB then MSB
    `- CC 0x00 (deck A platter position), or 0x02 for deck B

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

$frames = New-Object System.Collections.ArrayList
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
    # b0 cc vv | e0 lsb msb
    if ($b[0] -ne 0xB0) { continue }
    [void]$frames.Add([pscustomobject]@{
        T   = [double]$p[0]
        CC  = $b[1]
        Val = $b[2]
        HasPb = ($b.Count -gt 5 -and $b[3] -eq 0xE0)
        Pb  = if ($b.Count -gt 5 -and $b[3] -eq 0xE0) { $b[4] -bor ($b[5] -shl 7) } else { $null }
        Tail = $b[$b.Count - 1]
    })
}

if ($frames.Count -eq 0) { throw 'no B0 frames parsed' }

$t0 = $frames[0].T
$t1 = $frames[$frames.Count - 1].T
$dur = $t1 - $t0

Write-Host ''
Write-Host '=== FRAME STRUCTURE ===' -ForegroundColor Cyan
Write-Host ("  frames parsed      : {0}" -f $frames.Count)
Write-Host ("  window             : {0:N3} s  ({1:N1} frames/s)" -f $dur, ($frames.Count / $dur))
$ccSet = $frames | Group-Object CC | ForEach-Object { '0x{0:X2} x{1}' -f [int]$_.Name, $_.Count }
Write-Host ("  CC numbers present : {0}" -f ($ccSet -join ', '))
$withPb = @($frames | Where-Object { $_.HasPb }).Count
Write-Host ("  frames carrying 0xE0: {0} / {1}" -f $withPb, $frames.Count)
$tails = $frames | Group-Object Tail | ForEach-Object { '0x{0:X2} x{1}' -f [int]$_.Name, $_.Count }
Write-Host ("  terminator byte    : {0}" -f ($tails -join ', '))

# ---------------------------------------------------------------- Q4: wrap ---
Write-Host ''
Write-Host '=== Q4  does B0 00 wrap at 7 bits? ===' -ForegroundColor Cyan
$vals = $frames | ForEach-Object { $_.Val }
$mn = ($vals | Measure-Object -Minimum).Minimum
$mx = ($vals | Measure-Object -Maximum).Maximum
Write-Host ("  value range        : {0} .. {1}" -f $mn, $mx)
Write-Host ("  distinct values    : {0}" -f ($vals | Sort-Object -Unique).Count)
$wraps = 0; $deltas = New-Object System.Collections.ArrayList
for ($i = 1; $i -lt $frames.Count; $i++) {
    $d = $frames[$i].Val - $frames[$i - 1].Val
    if ($d -lt -64) { $wraps++; $d += 128 }
    elseif ($d -gt 64) { $d -= 128 }
    [void]$deltas.Add($d)
}
$avgD = ($deltas | Measure-Object -Average).Average
Write-Host ("  wrap events        : {0}  (high->low jumps)" -f $wraps)
Write-Host ("  mean delta/frame   : {0:N3} counts" -f $avgD)
if ($mx -le 127 -and $wraps -gt 0) {
    Write-Host '  VERDICT: still a wrapping 7-bit counter - the driver does NOT widen or unwrap it' -ForegroundColor Yellow
}

# ------------------------------------------------- Q2: timestamp or position ---
Write-Host ''
Write-Host '=== Q2  is 0xE0 a timestamp or a position? ===' -ForegroundColor Cyan
$pb = @($frames | Where-Object { $_.HasPb })
if ($pb.Count -gt 2) {
    $sum = 0.0; $n = 0
    for ($i = 1; $i -lt $pb.Count; $i++) {
        $d = ($pb[$i].Pb - $pb[$i - 1].Pb) % 16384
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
Write-Host '=== sample frames ===' -ForegroundColor Cyan
foreach ($f in ($frames | Select-Object -First $SampleRows)) {
    Write-Host ("  t={0,10:N6}  CC 0x{1:X2}={2,3}  pb={3,5}  tail=0x{4:X2}" -f `
        $f.T, $f.CC, $f.Val, $f.Pb, $f.Tail)
}
