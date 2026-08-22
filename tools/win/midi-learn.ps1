<#
  OpenV7 - Numark V7 control-surface learn tool (Windows / vendor driver)

  Maps every physical control to its MIDI message by listening to the stock
  Numark V7 MIDI port. Fills the gap ROADMAP.md calls out:
  "Confirm the full per-control MIDI map on hardware".

  It first measures the device's idle chatter, then watches for activity that
  is NOT that chatter. Each burst is captured until the control goes quiet,
  summarised, and you name it. No prior knowledge of the panel is required -
  just walk around the controller operating one thing at a time.

  Aggregation happens inside OpenV7Midi.dll; this script only polls counters,
  so a fast control (platter, fader) cannot swamp it.

  Run:  powershell -ExecutionPolicy Bypass -File .\tools\win\midi-learn.ps1
#>

[CmdletBinding()]
param(
    [int]$InDevice = -1,          # -1 = auto-detect the Numark port
    [int]$BaselineSeconds = 8,    # idle-chatter measurement window
    [int]$QuietMs = 1200,         # silence that ends a gesture
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $repo 'captures' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$dll = Join-Path $PSScriptRoot 'OpenV7Midi.dll'
if (-not (Test-Path $dll)) { throw "OpenV7Midi.dll missing - run tools/win/build.ps1 first" }
Add-Type -Path $dll

if ($InDevice -lt 0) { $InDevice = [MidiEnum]::FindIn('V7') }
if ($InDevice -lt 0) { $InDevice = [MidiEnum]::FindIn('Numark') }
if ($InDevice -lt 0) { Write-Host ([MidiEnum]::ListAll()); throw 'No Numark V7 MIDI input port found.' }

$rc = [MidiMon]::OpenIn($InDevice)
if ($rc -ne 0) { throw "midiInOpen failed on device $InDevice (rc=$rc). Another app may hold the port." }
Write-Host "Listening on MIDI IN device $InDevice" -ForegroundColor Green

# ------------------------------------------------- documented expectations ---
# From docs/CONTROL-MAP.md. These are the cross-referenced (unconfirmed) rows;
# when a gesture matches one, the tool says so, which turns this from "name 89
# controls from scratch" into "press things and watch them get confirmed".
# Keyed "STATUS:DATA1" in hex.
$EXPECTED = @{
    'B0:00' = 'platter position, deck A (CONFIRMED)'
    'B0:02' = 'platter position, deck B (CONFIRMED)'
    'B0:04' = 'pitch fader A (coarse)';  'B0:24' = 'pitch fader A (fine)'
    'B0:05' = 'pitch fader B (coarse)';  'B0:25' = 'pitch fader B (fine)'
    'B0:44' = 'browse / track select knob'
    'B0:45' = 'strip search A';          'B0:4D' = 'strip search B'
    'B0:46' = 'motor START TIME knob A'; 'B0:4E' = 'motor START TIME knob B'
    'B0:47' = 'motor STOP TIME knob A';  'B0:4F' = 'motor STOP TIME knob B'
    'B0:56' = 'FX parameter';            'B0:58' = 'FX parameter'
    'B0:57' = 'FX slider A (coarse)';    'B0:77' = 'FX slider A (fine)'
    'B0:59' = 'FX slider B (coarse)';    'B0:79' = 'FX slider B (fine)'
    'B0:5A' = 'FX select';               'B0:5B' = 'FX select'
    '90:06' = 'browse BACK';             '90:07' = 'browse FWD'
    '90:08' = 'LOAD';                    '90:0D' = 'LOAD'
    '90:0C' = 'LOAD deck A';             '90:0E' = 'LOAD deck B'
    '90:0F' = 'SYNC A';                  '90:30' = 'SYNC B'
    '90:10' = 'CUE A';                   '90:31' = 'CUE B'
    '90:11' = 'PLAY A';                  '90:32' = 'PLAY B'
    '90:12' = 'SHIFT A';                 '90:33' = 'SHIFT B'
    '90:13' = 'HOT CUE 1 A';             '90:34' = 'HOT CUE 1 B'
    '90:14' = 'HOT CUE 2 A';             '90:35' = 'HOT CUE 2 B'
    '90:15' = 'HOT CUE 3 A';             '90:36' = 'HOT CUE 3 B'
    '90:16' = 'HOT CUE 4 A';             '90:37' = 'HOT CUE 4 B'
    '90:17' = 'HOT CUE 5 A';             '90:38' = 'HOT CUE 5 B'
    '90:18' = 'PITCH BEND - A';          '90:39' = 'PITCH BEND - B'
    '90:19' = 'PITCH BEND + A';          '90:3A' = 'PITCH BEND + B'
    '90:1A' = 'PITCH RANGE A';           '90:3B' = 'PITCH RANGE B'
    '90:1B' = 'KEY LOCK A';              '90:3C' = 'KEY LOCK B'
    '90:1C' = 'REVERSE/CENSOR A';        '90:3D' = 'REVERSE/CENSOR B'
    '90:1D' = 'REVERSE/CENSOR A (2)';    '90:3E' = 'REVERSE/CENSOR B (2)'
    '90:1E' = 'TAP A';                   '90:3F' = 'TAP B'
    '90:21' = 'MOTOR ON/OFF A';          '90:42' = 'MOTOR ON/OFF B'
    '90:22' = 'LOOP 1/2 A';              '90:43' = 'LOOP 1/2 B'
    '90:23' = 'LOOP x2 A';               '90:44' = 'LOOP x2 B'
    '90:24' = 'RELOOP/EXIT A';           '90:45' = 'RELOOP/EXIT B'
    '90:25' = 'LOOP SHIFT < A';          '90:46' = 'LOOP SHIFT < B'
    '90:26' = 'LOOP SHIFT > A';          '90:47' = 'LOOP SHIFT > B'
    '90:27' = 'LOOP MODE A';             '90:48' = 'LOOP MODE B'
    '90:28' = 'LOOP IN A';               '90:49' = 'LOOP IN B'
    '90:29' = 'LOOP OUT A';              '90:4A' = 'LOOP OUT B'
    '90:2A' = 'SELECT A';                '90:4B' = 'SELECT B'
    '90:2B' = 'RELOOP A';                '90:4C' = 'RELOOP B'
    '90:52' = 'FX ON A';                 '90:59' = 'FX ON B'
    '90:53' = 'FX SELECT A';             '90:5A' = 'FX SELECT B'
    '90:54' = 'MASTER L';                '90:5B' = 'MASTER R'
    '90:5C' = 'DECK SELECT L';           '90:7D' = 'DECK SELECT R'
}

function Get-Expected($st, $d1) {
    if ($null -eq $st) { return $null }
    $k = '{0:X2}:{1:X2}' -f ($st -band 0xF0), $d1   # ignore channel nibble
    if ($EXPECTED.ContainsKey($k)) { return $EXPECTED[$k] }
    return $null
}

# ---------------------------------------------------------------- helpers ----
function Get-MsgName($st, $d1) {
    $type = $st -band 0xF0
    $ch = ($st -band 0x0F) + 1
    switch ($type) {
        0x80 { return ("NoteOff ch{0} note 0x{1:X2}" -f $ch, $d1) }
        0x90 { return ("NoteOn ch{0} note 0x{1:X2}" -f $ch, $d1) }
        0xA0 { return ("PolyAT ch{0} note 0x{1:X2}" -f $ch, $d1) }
        0xB0 { return ("CC ch{0} cc 0x{1:X2}" -f $ch, $d1) }
        0xC0 { return ("PgmChange ch{0}" -f $ch) }
        0xD0 { return ("ChanAT ch{0}" -f $ch) }
        0xE0 { return ("PitchBend ch{0}" -f $ch) }
        default { return ("status 0x{0:X2}" -f $st) }
    }
}

# Summary() lines -> objects. SysEx lines carry a hex blob instead of bytes.
function ConvertFrom-Summary($lines) {
    $out = @()
    foreach ($line in $lines) {
        $p = $line -split ','
        if ($p[0] -eq 'SYSEX') {
            $out += [pscustomobject]@{
                Key = 'SYSEX:' + $p[1]; IsSysex = $true; Desc = 'SysEx'; Sysex = $p[1]
                Status = $null; D1 = $null; Count = 1; Min = $null; Max = $null
                Distinct = $null; SpanMs = 0; Samples = $p[1]
            }
            continue
        }
        $st = [int]$p[0]; $d1 = [int]$p[1]
        $out += [pscustomobject]@{
            Key = ('{0:X2}:{1:X2}' -f $st, $d1); IsSysex = $false
            Desc = (Get-MsgName $st $d1); Sysex = $null
            Status = $st; D1 = $d1; Count = [int]$p[2]; Min = [int]$p[3]; Max = [int]$p[4]
            Distinct = [int]$p[5]; SpanMs = [int64]$p[6]; Samples = $p[7]
        }
    }
    return $out
}

function Show-Rows($rows) {
    foreach ($r in ($rows | Sort-Object -Property @{e={-$_.Count}})) {
        $tag = ''
        $col = 'White'
        if ($r.Idle) { $tag = '(idle/heartbeat)'; $col = 'DarkGray' }
        if ($r.IsSysex) {
            Write-Host ('    SysEx  {0}' -f $r.Sysex) -ForegroundColor $col
            continue
        }
        Write-Host ('    {0,-24} n={1,-6} val {2}..{3} ({4} distinct) {5}' -f `
            $r.Desc, $r.Count, $r.Min, $r.Max, $r.Distinct, $tag) -ForegroundColor $col
        if (-not $r.Idle) {
            $exp = Get-Expected $r.Status $r.D1
            if ($exp) {
                Write-Host ('        -> MATCHES documented: {0}' -f $exp) -ForegroundColor Green
            } else {
                Write-Host '        -> NOT in the documented map (new finding)' -ForegroundColor Yellow
            }
            Write-Host ('        raw: {0}' -f ($r.Samples -replace '\|', ' | ')) -ForegroundColor DarkGray
        }
    }
}

# ------------------------------------------- 1. baseline / idle chatter -------
Write-Host ''
Write-Host ('=' * 74) -ForegroundColor DarkGray
Write-Host " BASELINE - hands OFF the controller for $BaselineSeconds seconds" -ForegroundColor Yellow
Write-Host ('=' * 74) -ForegroundColor DarkGray
[void](Read-Host '  Press ENTER, then do not touch anything')
[MidiMon]::Reset()
for ($i = $BaselineSeconds; $i -gt 0; $i--) {
    Write-Host -NoNewline ("`r  measuring idle chatter... {0,2}s " -f $i)
    Start-Sleep -Seconds 1
}
$baseTotal = [MidiMon]::Total
$baseRows = ConvertFrom-Summary ([MidiMon]::Summary())
$idleKeys = @{}
foreach ($r in $baseRows) { $idleKeys[$r.Key] = [math]::Round($r.Count / $BaselineSeconds, 1) }

Write-Host ("`r  idle chatter: {0} msgs in {1}s                    " -f $baseTotal, $BaselineSeconds)
if ($baseTotal -eq 0) {
    Write-Host '    (silent at idle - every message from here is a real control event)' -ForegroundColor DarkGray
} else {
    foreach ($r in $baseRows) {
        Write-Host ('    {0}  {1}/s' -f $r.Desc, $idleKeys[$r.Key]) -ForegroundColor DarkGray
    }
}

# --------------------------------------------------------- 2. learn loop ------
$map = New-Object System.Collections.ArrayList
Write-Host ''
Write-Host ('=' * 74) -ForegroundColor DarkGray
Write-Host ' LEARN - operate ONE control at a time' -ForegroundColor Yellow
Write-Host ('=' * 74) -ForegroundColor DarkGray
Write-Host '  Press a button (press AND release), sweep a fader end to end, turn an'
Write-Host '  encoder a few detents, or touch/spin the platter. The tool detects the'
Write-Host '  gesture, then asks what it was.'
Write-Host ''
Write-Host '  Controls whose address matches docs/CONTROL-MAP.md are recognised'
Write-Host '  automatically - just press ENTER to confirm one. Type a name only'
Write-Host '  when the tool guesses wrong or the control is not in the map.'
Write-Host ''
Write-Host '  At the name prompt:  ENTER = confirm  |  <name> = correct it'
Write-Host '                       s = discard      |  q = finish'
Write-Host ''

$finished = $false
while (-not $finished) {
    Write-Host -NoNewline '  waiting for a control...  (press q to finish)' -ForegroundColor DarkGray

    # --- wait for activity ---
    [MidiMon]::Reset()
    $seen = 0
    while ($seen -eq 0) {
        Start-Sleep -Milliseconds 60
        $seen = [MidiMon]::Total
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.KeyChar -eq 'q') { $finished = $true; break }
        }
    }
    if ($finished) { break }

    Write-Host -NoNewline "`r  capturing gesture...                          " -ForegroundColor Cyan

    # --- collect until it goes quiet ---
    $quiet = 0
    $last = [MidiMon]::Total
    while ($quiet -lt $QuietMs) {
        Start-Sleep -Milliseconds 60
        $quiet += 60
        $now = [MidiMon]::Total
        if ($now -ne $last) { $quiet = 0; $last = $now }
    }

    $rows = ConvertFrom-Summary ([MidiMon]::Summary())
    foreach ($r in $rows) {
        Add-Member -InputObject $r -NotePropertyName Idle -NotePropertyValue ($idleKeys.ContainsKey($r.Key)) -Force
    }

    Write-Host ("`r  gesture captured: {0} messages                 " -f $last) -ForegroundColor Cyan
    Show-Rows $rows

    # If the gesture matched a documented address, ENTER just confirms it -
    # so a full verification pass is one keypress per control, not 89 names.
    $suggested = $null
    foreach ($r in ($rows | Sort-Object -Property @{e = { -$_.Count } })) {
        if ($r.Idle -or $r.IsSysex) { continue }
        $e = Get-Expected $r.Status $r.D1
        if ($e) { $suggested = $e; break }
    }

    if ($suggested) {
        $name = Read-Host "  ENTER to confirm '$suggested', or type a correction (s=discard, q=finish)"
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $suggested }
    } else {
        $name = Read-Host '  name this control (s=discard, q=finish)'
    }

    if ($name -eq 'q') { break }
    if ($name -eq 's' -or [string]::IsNullOrWhiteSpace($name)) {
        Write-Host '  discarded.' -ForegroundColor DarkGray
        Write-Host ''
        continue
    }
    [void]$map.Add([pscustomobject]@{ Control = $name; Rows = $rows; Total = $last })
    Write-Host "  recorded '$name'." -ForegroundColor Green
    Write-Host ''
}

[MidiMon]::CloseIn()

# ------------------------------------------------------- 3. write results -----
$jsonPath = Join-Path $OutDir 'v7-control-map.json'
$mdPath = Join-Path $OutDir 'v7-control-map.md'

[pscustomobject]@{
    device      = 'Numark V7 (USB 15E4:0075) via Windows vendor driver 2.9.64'
    idleChatter = $idleKeys
    controls    = $map
} | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding utf8

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# Numark V7 - control map (learned)')
[void]$sb.AppendLine()
[void]$sb.AppendLine('Captured on Windows through the stock Numark/Ploytec vendor driver 2.9.64,')
[void]$sb.AppendLine('which exposes the V7 control stream as a normal MIDI port. These are the')
[void]$sb.AppendLine('same bytes the device puts on bulk IN `0x83`, with the `0xFD` padding stripped.')
[void]$sb.AppendLine()
if ($idleKeys.Count -gt 0) {
    [void]$sb.AppendLine('## Idle chatter (suppressed during learning)')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Message | Rate |')
    [void]$sb.AppendLine('|---|---|')
    foreach ($r in $baseRows) {
        [void]$sb.AppendLine("| $($r.Desc) | $($idleKeys[$r.Key])/s |")
    }
    [void]$sb.AppendLine()
} else {
    [void]$sb.AppendLine('The port is **silent at idle** - the vendor driver strips the `0xFD` filler')
    [void]$sb.AppendLine('and heartbeat, so every message below is a real control event.')
    [void]$sb.AppendLine()
}
[void]$sb.AppendLine('## Controls')
[void]$sb.AppendLine()
[void]$sb.AppendLine('| Control | Message | Bytes | Value range | Distinct | Count |')
[void]$sb.AppendLine('|---|---|---|---|---|---|')
foreach ($c in $map) {
    foreach ($r in ($c.Rows | Sort-Object -Property @{e={-$_.Count}})) {
        if ($r.Idle) { continue }
        if ($r.IsSysex) {
            [void]$sb.AppendLine("| $($c.Control) | SysEx | ``$($r.Sysex)`` | | | |")
            continue
        }
        [void]$sb.AppendLine(('| {0} | {1} | `{2:X2} {3:X2} vv` | {4}..{5} | {6} | {7} |' -f `
            $c.Control, $r.Desc, $r.Status, $r.D1, $r.Min, $r.Max, $r.Distinct, $r.Count))
    }
}
$sb.ToString() | Set-Content -Path $mdPath -Encoding utf8

Write-Host ''
Write-Host "Learned $($map.Count) controls." -ForegroundColor Green
Write-Host "  $jsonPath"
Write-Host "  $mdPath"
Write-Host 'Tell Claude the learn pass is done.' -ForegroundColor Yellow
