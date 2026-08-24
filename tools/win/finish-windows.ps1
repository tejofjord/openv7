<#
  OpenV7 - the last MIDI-port questions, in one pass.

  Everything here needs the V7's MIDI port, so VirtualDJ must be CLOSED - it
  holds that port exclusively while it runs.

  Three phases, each with an on-screen countdown so the operator controls the
  timing rather than trying to synchronise with someone else:

    1. Strip search behaviour. The address is known (CC 0x45 deck A, 0x4D deck
       B, absolute 7-bit). What is not known is what happens on RELEASE, and
       that decides whether a needle-drop mapping works or flings the track to
       the start every time a finger lifts.

    2. The library trio 0x09 / 0x0A / 0x0B. These appear in no published
       mapping. Pressing them in a stated order identifies each from the
       arrival sequence.

    3. 0x08. The Mixxx map gives it the same function as 0x0D, which is proven
       to be LOAD PREPARE, so 0x08 is something else.

  Run:  powershell -ExecutionPolicy Bypass -File .\tools\win\finish-windows.ps1
#>

[CmdletBinding()]
param([string]$OutDir = '')

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $repo 'captures' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Transcript rather than output redirection: this script talks to the operator
# with Write-Host, which bypasses the pipeline, so redirecting stdout would
# capture nothing AND hide the countdowns they need to follow.
$transcript = Join-Path $OutDir 'finish-windows.log'
try { Start-Transcript -Path $transcript -Force | Out-Null } catch { }

Add-Type -Path (Join-Path $PSScriptRoot 'OpenV7Midi.dll')
. (Join-Path $PSScriptRoot 'ControlMap.ps1')

$vdj = Get-Process -Name '*virtualdj*' -ErrorAction SilentlyContinue
if ($vdj) {
    Write-Host 'ERROR: VirtualDJ is still running - it holds the MIDI port.' -ForegroundColor Red
    Write-Host '  Close it and run this again.' -ForegroundColor Red
    exit 1
}

$dev = [MidiEnum]::FindIn('V7')
if ($dev -lt 0) { throw 'No Numark V7 MIDI input port found.' }
if ([MidiMon]::OpenIn($dev) -ne 0) { throw 'midiInOpen failed - something still holds the port.' }
[MidiMon]::RecordRaw(200000)

function Countdown([int]$sec) {
    for ($i = $sec; $i -gt 0; $i--) {
        Write-Host -NoNewline ("`r    {0,3}s " -f $i)
        Start-Sleep -Seconds 1
    }
    Write-Host "`r    done.   "
}

function Phase([int]$n, [string]$title, [string[]]$steps, [int]$sec) {
    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkGray
    Write-Host " PHASE $n - $title" -ForegroundColor Yellow
    Write-Host ('=' * 68) -ForegroundColor DarkGray
    foreach ($s in $steps) { Write-Host "   $s" }
    Write-Host ''
    Write-Host '   starting in 5 seconds...' -ForegroundColor Cyan
    Start-Sleep -Seconds 5
    [MidiMon]::Reset()
    Countdown $sec
    return [MidiMon]::Raw()
}

function Show-Order($raw, $skipPlatter = $true) {
    $seen = @{}
    $out = @()
    $prev = $null
    foreach ($r in $raw) {
        $p = $r -split ' '
        $t = [int64]$p[0]; $st = [int]$p[1]; $d1 = [int]$p[2]; $d2 = [int]$p[3]
        $type = $st -band 0xF0
        if ($type -eq 0xE0) { continue }
        if ($skipPlatter -and $type -eq 0xB0 -and ($d1 -eq 0x00 -or $d1 -eq 0x02)) { continue }
        if ($type -eq 0x90 -and $d2 -eq 0) { continue }
        $k = '{0:X2}:{1:X2}' -f $st, $d1
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $gap = if ($null -eq $prev) { 0 } else { [math]::Round(($t - $prev) / 1000.0, 2) }
        $prev = $t
        $exp = Get-Expected $st $d1
        $tag = if ($exp) { "-> $exp" } else { '*** NOT DOCUMENTED ***' }
        $name = switch ($type) {
            0x90 { 'NoteOn  0x{0:X2}' -f $d1 }
            0xB0 { 'CC      0x{0:X2}' -f $d1 }
            default { 'st 0x{0:X2} d1 0x{1:X2}' -f $st, $d1 }
        }
        $out += ('  {0,2}. +{1,6}s  {2,-16} {3}' -f ($out.Count + 1), $gap, $name, $tag)
    }
    if ($out.Count) { $out | ForEach-Object { Write-Host $_ } }
    else { Write-Host '  (nothing captured)' -ForegroundColor DarkGray }
}

try {
    # ---------------------------------------------------------------- phase 1
    $raw = Phase 1 'STRIP SEARCH - what happens on release?' @(
        '1. slow drag end to end, then LIFT your finger'
        '2. tap the middle, lift'
        '3. tap one end, lift; tap the other end, lift'
        '4. press and hold still ~3 s, then lift'
    ) 60

    $ev = @()
    foreach ($r in $raw) {
        $p = $r -split ' '
        if ([int]$p[1] -ne 0xB0) { continue }
        $d1 = [int]$p[2]
        if ($d1 -ne 0x45 -and $d1 -ne 0x4D) { continue }
        $ev += [pscustomobject]@{ Ms = [int64]$p[0]; Val = [int]$p[3] }
    }
    Write-Host ''
    Write-Host "  strip messages: $($ev.Count)" -ForegroundColor Cyan
    if ($ev.Count) {
        $g = 0; $prev = $null; $vals = @()
        foreach ($e in $ev) {
            if ($null -eq $prev -or ($e.Ms - $prev) -gt 300) {
                if ($vals.Count) {
                    Write-Host ("     n={0,-4} first={1,-4} LAST={2,-4} range {3}..{4}" -f `
                        $vals.Count, $vals[0], $vals[-1],
                        ($vals | Measure-Object -Minimum).Minimum, ($vals | Measure-Object -Maximum).Maximum)
                }
                $g++; $vals = @()
                Write-Host ("   gesture $g" ) -ForegroundColor Cyan
            }
            $vals += $e.Val; $prev = $e.Ms
        }
        if ($vals.Count) {
            Write-Host ("     n={0,-4} first={1,-4} LAST={2,-4} range {3}..{4}" -f `
                $vals.Count, $vals[0], $vals[-1],
                ($vals | Measure-Object -Minimum).Minimum, ($vals | Measure-Object -Maximum).Maximum)
        }
        Write-Host ''
        Write-Host '  KEY: if every LAST value is 0, releasing sends zero and a naive' -ForegroundColor Yellow
        Write-Host '  mapping jumps the track to the start on every finger-lift.' -ForegroundColor Yellow
    }

    # ---------------------------------------------------------------- phase 2
    $raw = Phase 2 'LIBRARY TRIO - press in THIS order' @(
        '1. CRATES     (wait ~3 s)'
        '2. PREPARE    (wait ~3 s)'
        '3. FILES'
    ) 40
    Write-Host ''
    Write-Host '  arrival order:' -ForegroundColor Cyan
    Show-Order $raw

    # ---------------------------------------------------------------- phase 3
    $raw = Phase 3 'ANY REMAINING BUTTONS' @(
        'Press anything in the browse/library area not covered yet -'
        'and anything anywhere on the panel we may have missed.'
        'One at a time, a few seconds apart.'
    ) 45
    Write-Host ''
    Write-Host '  arrival order:' -ForegroundColor Cyan
    Show-Order $raw
}
finally {
    [MidiMon]::CloseIn()
    Write-Host ''
    Write-Host 'Done - Claude can read the transcript, no need to copy anything.' -ForegroundColor Yellow
    try { Stop-Transcript | Out-Null } catch { }
    Start-Sleep -Seconds 3
}
