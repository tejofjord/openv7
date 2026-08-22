<#
  OpenV7 - free-form control observation.

  Non-interactive counterpart to midi-learn.ps1. Rather than prompting once per
  control, it just records for a fixed window while the operator works the whole
  panel, then reports every distinct address that arrived and matches it against
  the documented map in ControlMap.ps1.

  That confirms the ADDRESS SET without anyone typing 89 names:
    - documented addresses that actually appeared  -> confirmed
    - addresses that appeared but are NOT documented -> new findings
    - documented addresses that never appeared      -> still unconfirmed

  It cannot confirm which physical control owns which address - for that, run a
  short window while operating a single control (-Seconds 5) and read the one
  address that shows up.

  Usage:
    .\midi-observe.ps1 -Seconds 90
    .\midi-observe.ps1 -Seconds 5 -Label 'PLAY'
#>

[CmdletBinding()]
param(
    [int]$Seconds = 90,
    [string]$Label = '',
    [switch]$IncludePlatter,
    # Report addresses in the order they FIRST appeared. Operate controls in a
    # known order and the sequence identifies them without naming each one.
    [switch]$Ordered,
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $repo 'captures' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type -Path (Join-Path $PSScriptRoot 'OpenV7Midi.dll')
. (Join-Path $PSScriptRoot 'ControlMap.ps1')

$dev = [MidiEnum]::FindIn('V7')
if ($dev -lt 0) { throw 'No Numark V7 MIDI input port found.' }
$rc = [MidiMon]::OpenIn($dev)
if ($rc -ne 0) { throw "midiInOpen failed (rc=$rc) - another app may hold the port." }

function Get-MsgName($st, $d1) {
    switch ($st -band 0xF0) {
        0x80 { return ('NoteOff  0x{0:X2}' -f $d1) }
        0x90 { return ('NoteOn   0x{0:X2}' -f $d1) }
        0xA0 { return ('PolyAT   0x{0:X2}' -f $d1) }
        0xB0 { return ('CC       0x{0:X2}' -f $d1) }
        0xE0 { return 'PitchBend' }
        default { return ('status 0x{0:X2}' -f $st) }
    }
}

try {
    if ($Label) { Write-Host "=== observing: $Label ===" -ForegroundColor Yellow }
    if ($Ordered) { [MidiMon]::RecordRaw(200000) }
    Write-Host "Recording for $Seconds s. Operate the controls now." -ForegroundColor Green
    [MidiMon]::Reset()
    Start-Sleep -Seconds $Seconds
    $total = [MidiMon]::Total
    $summary = [MidiMon]::Summary()
    Write-Host "captured $total messages, $($summary.Count) distinct addresses" -ForegroundColor Cyan
    Write-Host ''

    $rows = @()
    foreach ($line in $summary) {
        $p = $line -split ','
        if ($p[0] -eq 'SYSEX') {
            $rows += [pscustomobject]@{ Key='SYSEX'; Desc='SysEx'; Status=$null; D1=$null
                                        Count=1; Min=0; Max=0; Distinct=0; Expected='(sysex)'; Sample=$p[1] }
            continue
        }
        $st = [int]$p[0]; $d1 = [int]$p[1]
        # Pitch-bend is the platter's paired timestamp, not a control of its own
        if (($st -band 0xF0) -eq 0xE0 -and -not $IncludePlatter) { continue }
        if (($st -band 0xF0) -eq 0xB0 -and ($d1 -eq 0x00 -or $d1 -eq 0x02) -and -not $IncludePlatter) { continue }
        $rows += [pscustomobject]@{
            Key = (Get-ExpectedKey $st $d1); Desc = (Get-MsgName $st $d1)
            Status = $st; D1 = $d1
            Count = [int]$p[2]; Min = [int]$p[3]; Max = [int]$p[4]; Distinct = [int]$p[5]
            Expected = (Get-Expected $st $d1); Sample = $p[7]
        }
    }

    $known = @($rows | Where-Object { $_.Expected })
    $new = @($rows | Where-Object { -not $_.Expected })

    Write-Host "--- CONFIRMED: documented addresses that appeared ($($known.Count)) ---" -ForegroundColor Green
    foreach ($r in ($known | Sort-Object Status, D1)) {
        Write-Host ('  {0,-16} n={1,-5} val {2,3}..{3,-3} distinct={4,-3} -> {5}' -f `
            $r.Desc, $r.Count, $r.Min, $r.Max, $r.Distinct, $r.Expected)
    }

    Write-Host ''
    Write-Host "--- NEW: addresses NOT in the documented map ($($new.Count)) ---" -ForegroundColor Yellow
    if ($new.Count -eq 0) {
        Write-Host '  (none - the device emitted nothing outside the documented map)'
    } else {
        foreach ($r in ($new | Sort-Object Status, D1)) {
            Write-Host ('  {0,-16} n={1,-5} val {2,3}..{3,-3} distinct={4,-3}  raw: {5}' -f `
                $r.Desc, $r.Count, $r.Min, $r.Max, $r.Distinct, ($r.Sample -replace '\|', ' | '))
        }
    }

    if ($Ordered) {
        Write-Host ''
        Write-Host '--- FIRST-SEEN ORDER (matches the order you operated things) ---' -ForegroundColor Cyan
        $seen = @{}
        $order = New-Object System.Collections.ArrayList
        foreach ($r in [MidiMon]::Raw()) {
            $p = $r -split ' '
            $t = [int64]$p[0]; $st = [int]$p[1]; $d1 = [int]$p[2]; $d2 = [int]$p[3]
            $type = $st -band 0xF0
            if ($type -eq 0xE0) { continue }
            if ($type -eq 0xB0 -and ($d1 -eq 0x00 -or $d1 -eq 0x02) -and -not $IncludePlatter) { continue }
            # a release (velocity 0) is not a new control
            if ($type -eq 0x90 -and $d2 -eq 0) { continue }
            $k = '{0:X2}:{1:X2}' -f $st, $d1
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            [void]$order.Add([pscustomobject]@{ Ms = $t; Status = $st; D1 = $d1 })
        }
        $n = 0
        $prev = $null
        foreach ($o in $order) {
            $n++
            $gap = if ($null -eq $prev) { 0 } else { [math]::Round(($o.Ms - $prev) / 1000.0, 2) }
            $prev = $o.Ms
            $exp = Get-Expected $o.Status $o.D1
            $tag = if ($exp) { "-> $exp" } else { '*** NOT DOCUMENTED ***' }
            Write-Host ('  {0,3}. +{1,6}s  {2,-16} {3}' -f $n, $gap, (Get-MsgName $o.Status $o.D1), $tag)
        }
    }

    $stamp = $Label
    if ([string]::IsNullOrWhiteSpace($stamp)) { $stamp = 'freeform' }
    $safe = ($stamp -replace '[^A-Za-z0-9_-]', '_')
    $path = Join-Path $OutDir "v7-observed-$safe.json"
    [pscustomobject]@{
        label = $stamp; seconds = $Seconds; totalMessages = $total
        confirmed = $known; undocumented = $new
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding utf8
    Write-Host ''
    Write-Host "written: $path" -ForegroundColor DarkGray
}
finally {
    [MidiMon]::CloseIn()
}
