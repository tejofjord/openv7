<#
  OpenV7 - X1: reconstruct the V7's control stream the way it is actually framed.

  THE KEY POINT, and the thing a naive parser gets wrong:

    MIDI messages are NOT aligned to the 42-byte frame. A message begun near
    the end of one frame continues in the next. In a real capture 15.6% of
    frames start with a leftover data byte belonging to the previous frame's
    message:

      frame N    b0 00 16  e0 4d            fd..fd 00   <- pitch-bend MSB absent
      frame N+1  0b        b0 00 18  e0 02  fd..fd 00   <- it is here
                 ^ that MSB

  So the 42-byte frame is a transport container, not a message container. The
  correct procedure is:

    1. take each frame's payload
    2. strip the 0xFD filler and the trailing 0x00 terminator
    3. concatenate the remainder into one continuous byte stream
    4. run an ordinary MIDI parser over that stream

  Parsing frames independently corrupts roughly one message in six, and the
  damage lands on the pitch-bend - which is exactly the value a host would use
  for jog timing.

  Input is the TSV from:
    tshark -r cap.pcap -Y 'usb.endpoint_address==0x83 && usb.data_len>0' `
           -T fields -e frame.time_relative -e usb.data_len -e usb.capdata

  Usage: .\parse-control-stream.ps1 -Tsv .\x83.tsv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Tsv,
    [int]$Sample = 14,
    [switch]$Csv,
    [string]$CsvPath = ''
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Tsv)) { throw "not found: $Tsv" }

# ---- 1. read frames, strip filler, concatenate --------------------------------
$stream = New-Object 'System.Collections.Generic.List[int]'
$times  = New-Object 'System.Collections.Generic.List[double]'   # arrival time per stream byte
$frameCount = 0
$tailBytes = @{}
$leadingOrphans = 0

foreach ($line in [System.IO.File]::ReadLines((Resolve-Path $Tsv))) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $p = $line -split "`t"
    if ($p.Count -lt 3) { continue }
    $hex = $p[2] -replace '[^0-9a-fA-F]', ''
    if ($hex.Length -lt 4) { continue }
    $t = [double]$p[0]
    $frameCount++

    $bytes = New-Object 'System.Collections.Generic.List[int]'
    for ($i = 0; $i -lt $hex.Length; $i += 2) {
        $bytes.Add([Convert]::ToInt32($hex.Substring($i, 2), 16))
    }

    $tail = $bytes[$bytes.Count - 1]
    if ($tailBytes.ContainsKey($tail)) { $tailBytes[$tail]++ } else { $tailBytes[$tail] = 1 }
    if ($bytes[0] -ne 0xB0 -and $bytes[0] -ne 0xE0 -and $bytes[0] -lt 0x80) { $leadingOrphans++ }

    # drop the terminator, then the filler
    $bytes.RemoveAt($bytes.Count - 1)
    foreach ($b in $bytes) {
        if ($b -eq 0xFD) { continue }
        $stream.Add($b)
        $times.Add($t)
    }
}

Write-Host ''
Write-Host '=== FRAMING ===' -ForegroundColor Cyan
Write-Host ("  frames                    : {0}" -f $frameCount)
Write-Host ("  frames starting mid-message: {0}  ({1:P1})" -f $leadingOrphans, ($leadingOrphans / $frameCount))
Write-Host ("  terminator bytes          : {0}" -f (($tailBytes.Keys | Sort-Object | ForEach-Object { '0x{0:X2} x{1}' -f $_, $tailBytes[$_] }) -join ', '))
Write-Host ("  stream bytes after strip  : {0}" -f $stream.Count)

# ---- 2. parse the byte stream as MIDI -----------------------------------------
$msgs = New-Object System.Collections.ArrayList
$i = 0
$bad = 0
while ($i -lt $stream.Count) {
    $s = $stream[$i]
    if ($s -lt 0x80) { $bad++; $i++; continue }        # data byte with no status
    $type = $s -band 0xF0
    $need = if ($type -eq 0xC0 -or $type -eq 0xD0) { 1 } else { 2 }
    if ($i + $need -ge $stream.Count) { break }
    $d1 = $stream[$i + 1]; $d2 = if ($need -eq 2) { $stream[$i + 2] } else { 0 }
    if ($d1 -ge 0x80 -or ($need -eq 2 -and $d2 -ge 0x80)) { $bad++; $i++; continue }
    [void]$msgs.Add([pscustomobject]@{
        T = $times[$i]; Status = $s; D1 = $d1; D2 = $d2
        Val14 = if ($type -eq 0xE0) { $d1 -bor ($d2 -shl 7) } else { $null }
    })
    $i += 1 + $need
}

Write-Host ''
Write-Host '=== PARSE ===' -ForegroundColor Cyan
Write-Host ("  messages                  : {0}" -f $msgs.Count)
Write-Host ("  resync events (bad bytes) : {0}" -f $bad)
$byType = $msgs | Group-Object { '{0:X2} {1:X2}' -f ($_.Status -band 0xF0), $(if (($_.Status -band 0xF0) -eq 0xE0) { 0 } else { $_.D1 }) }
foreach ($g in ($byType | Sort-Object Count -Descending | Select-Object -First 8)) {
    Write-Host ("    {0,-8} x{1}" -f $g.Name, $g.Count)
}

# ---- 3. validate: platter position should step smoothly ------------------------
$cc = @($msgs | Where-Object { ($_.Status -band 0xF0) -eq 0xB0 -and ($_.D1 -eq 0x00 -or $_.D1 -eq 0x02) })
Write-Host ''
Write-Host '=== Q4  platter position ===' -ForegroundColor Cyan
if ($cc.Count -gt 2) {
    $vals = $cc | ForEach-Object { $_.D2 }
    Write-Host ("  messages                  : {0}" -f $cc.Count)
    Write-Host ("  value range               : {0} .. {1}   (7-bit means 0..127)" -f `
        ($vals | Measure-Object -Minimum).Minimum, ($vals | Measure-Object -Maximum).Maximum)
    $d = @(); $wraps = 0
    for ($k = 1; $k -lt $cc.Count; $k++) {
        $x = $cc[$k].D2 - $cc[$k - 1].D2
        if ($x -lt -64) { $wraps++; $x += 128 } elseif ($x -gt 64) { $x -= 128 }
        $d += $x
    }
    $ds = $d | Measure-Object -Average -Minimum -Maximum
    Write-Host ("  delta per message         : mean {0:N3}, min {1}, max {2}" -f $ds.Average, $ds.Minimum, $ds.Maximum)
    Write-Host ("  wrap events               : {0}" -f $wraps)
    $clean = @($d | Where-Object { $_ -ge 0 -and $_ -le 8 }).Count
    Write-Host ("  deltas in 0..8            : {0:P2}   (a clean stream is ~100%)" -f ($clean / $d.Count))
}

# ---- 4. validate: pitch-bend as a timestamp ------------------------------------
$pb = @($msgs | Where-Object { ($_.Status -band 0xF0) -eq 0xE0 })
Write-Host ''
Write-Host '=== Q2  pitch-bend: timestamp or position? ===' -ForegroundColor Cyan
if ($pb.Count -gt 2) {
    # only pairs closer than 5 ms: the 14-bit counter wraps every ~5.8 ms at
    # 2.8 MHz, so a longer gap aliases and cannot be unwrapped
    $sum = 0.0; $n = 0
    for ($k = 1; $k -lt $pb.Count; $k++) {
        $dt = $pb[$k].T - $pb[$k - 1].T
        if ($dt -le 0 -or $dt -gt 0.005) { continue }
        $dv = ($pb[$k].Val14 - $pb[$k - 1].Val14) % 16384
        if ($dv -lt 0) { $dv += 16384 }
        $sum += $dv / $dt; $n++
    }
    if ($n) {
        $rate = $sum / $n
        Write-Host ("  usable pairs (<5 ms)      : {0}" -f $n)
        Write-Host ("  mean advance              : {0:N0} units/sec" -f $rate)
        Write-Host ("  vs 2,822,400 Hz           : {0:P2}" -f (($rate - 2822400) / 2822400))
    }
}

Write-Host ''
Write-Host '=== sample, as parsed from the stream ===' -ForegroundColor Cyan
foreach ($m in ($msgs | Select-Object -First $Sample)) {
    if ($null -ne $m.Val14) {
        Write-Host ("  t={0,10:N6}  E0  pb={1,5}" -f $m.T, $m.Val14)
    } else {
        Write-Host ("  t={0,10:N6}  {1:X2} {2:X2} {3,3}" -f $m.T, $m.Status, $m.D1, $m.D2)
    }
}

if ($Csv) {
    if ([string]::IsNullOrWhiteSpace($CsvPath)) { $CsvPath = [IO.Path]::ChangeExtension($Tsv, 'parsed.csv') }
    $msgs | Select-Object T, Status, D1, D2, Val14 | Export-Csv -NoTypeInformation -Path $CsvPath
    Write-Host ''
    Write-Host "wrote $CsvPath" -ForegroundColor Green
}
