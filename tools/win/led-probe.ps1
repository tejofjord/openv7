<#
  OpenV7 - Numark V7 LED / output map

  Maps host -> device messages to whatever they light up. There is no feedback
  channel for LEDs (a CC/note sweep provokes no reply), so a human has to watch
  the panel. Prompting once per message would mean 256 prompts, so instead this
  sweeps automatically and you just tap SPACE whenever something lights.

  Pass 1  sweep: every message is sent in turn, held briefly, then cleared.
          Tap SPACE the moment you see anything change. The message that was
          active is recorded, along with the one just before it, since it is
          easy to react a beat late.
  Pass 2  replay: each flagged message is re-sent on its own so you can name
          the exact control it drives.

  Run: powershell -ExecutionPolicy Bypass -File .\tools\win\led-probe.ps1
#>

[CmdletBinding()]
param(
    [int]$HoldMs = 700,
    [string]$OutDir = '',
    [switch]$NotesOnly,
    [switch]$CcOnly
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $repo 'captures' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

Add-Type -Path (Join-Path $PSScriptRoot 'OpenV7Midi.dll')
$outDev = [MidiEnum]::FindOut('V7')
if ($outDev -lt 0) { Write-Host ([MidiEnum]::ListAll()); throw 'No Numark V7 MIDI output port found.' }
$rc = [MidiMon]::OpenOut($outDev)
if ($rc -ne 0) { throw "midiOutOpen failed (rc=$rc)" }

# Motor commands - excluded so the platter cannot start mid-sweep.
# BOTH decks: deck A is 0x41-0x49 (+0x69 trim LSB), deck B is that block +0x0A,
# i.e. 0x4B-0x53 (+0x73). Missing the deck-B half would spin the platter with
# the A/B switch in the B position.
$MOTOR_CC = @(0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x69) +
            @(0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52, 0x53, 0x73)

function New-Msg($kind, $num) {
    [pscustomobject]@{
        Kind = $kind
        Num  = $num
        Label = if ($kind -eq 'note') { 'NoteOn  0x{0:X2}' -f $num } else { 'CC      0x{0:X2}' -f $num }
    }
}

$plan = New-Object System.Collections.ArrayList
if (-not $CcOnly) { for ($n = 0; $n -le 0x7F; $n++) { [void]$plan.Add((New-Msg 'note' $n)) } }
if (-not $NotesOnly) {
    for ($c = 0; $c -le 0x7F; $c++) {
        if ($MOTOR_CC -contains $c) { continue }
        [void]$plan.Add((New-Msg 'cc' $c))
    }
}

function Set-Msg($m, $on) {
    if ($m.Kind -eq 'note') {
        if ($on) { [void][MidiMon]::Send(0x90, [byte]$m.Num, 0x7F) }
        else     { [void][MidiMon]::Send(0x80, [byte]$m.Num, 0x00) }
    } else {
        if ($on) { [void][MidiMon]::Send(0xB0, [byte]$m.Num, 0x7F) }
        else     { [void][MidiMon]::Send(0xB0, [byte]$m.Num, 0x00) }
    }
}

function Clear-All {
    for ($n = 0; $n -le 0x7F; $n++) { [void][MidiMon]::Send(0x80, [byte]$n, 0x00) }
    for ($c = 0; $c -le 0x7F; $c++) {
        if ($MOTOR_CC -contains $c) { continue }
        [void][MidiMon]::Send(0xB0, [byte]$c, 0x00)
    }
}

$flagged = New-Object System.Collections.ArrayList

try {
    Clear-All
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkGray
    Write-Host ' PASS 1 - watch the panel, tap SPACE when anything lights up' -ForegroundColor Yellow
    Write-Host ('=' * 74) -ForegroundColor DarkGray
    Write-Host "  $($plan.Count) messages, ~$([math]::Round($plan.Count * $HoldMs / 1000.0 / 60.0, 1)) minutes."
    Write-Host '  Watch buttons, pads, rings, and any display. Tap SPACE for each.'
    Write-Host '  q = abort the sweep and go straight to replay.'
    Write-Host ''
    [void](Read-Host '  Press ENTER to start')

    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }

    $prev = $null
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $m = $plan[$i]
        Write-Host -NoNewline ("`r  [{0,3}/{1}]  {2}          " -f ($i + 1), $plan.Count, $m.Label)
        Set-Msg $m $true

        $waited = 0
        $abort = $false
        while ($waited -lt $HoldMs) {
            Start-Sleep -Milliseconds 40
            $waited += 40
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.KeyChar -eq 'q') { $abort = $true; break }
                if ($k.Key -eq 'Spacebar') {
                    if (-not ($flagged | Where-Object { $_.Kind -eq $m.Kind -and $_.Num -eq $m.Num })) {
                        [void]$flagged.Add($m)
                    }
                    # also keep the previous message - reacting a beat late is normal
                    if ($prev -and -not ($flagged | Where-Object { $_.Kind -eq $prev.Kind -and $_.Num -eq $prev.Num })) {
                        [void]$flagged.Add($prev)
                    }
                    Write-Host ("`r  flagged: {0}                    " -f $m.Label) -ForegroundColor Green
                }
            }
        }
        Set-Msg $m $false
        $prev = $m
        if ($abort) { Write-Host ''; Write-Host '  sweep aborted.' -ForegroundColor Yellow; break }
    }

    Clear-All
    Write-Host ''
    Write-Host ''
    Write-Host ("  $($flagged.Count) messages flagged.") -ForegroundColor Cyan

    # ------------------------------------------------------------- pass 2
    $map = New-Object System.Collections.ArrayList
    if ($flagged.Count -gt 0) {
        Write-Host ''
        Write-Host ('=' * 74) -ForegroundColor DarkGray
        Write-Host ' PASS 2 - name each flagged output' -ForegroundColor Yellow
        Write-Host ('=' * 74) -ForegroundColor DarkGray
        Write-Host '  Each message is held on until you answer. Type what it lights,'
        Write-Host '  or s to discard it as a false positive. q finishes.'
        Write-Host ''
        foreach ($m in ($flagged | Sort-Object Kind, Num)) {
            Clear-All
            Set-Msg $m $true
            Write-Host ("  now ON: {0}" -f $m.Label) -ForegroundColor Cyan
            $name = Read-Host '    what lit up? (s=nothing/false positive, q=finish)'
            Set-Msg $m $false
            if ($name -eq 'q') { break }
            if ($name -eq 's' -or [string]::IsNullOrWhiteSpace($name)) { continue }
            [void]$map.Add([pscustomobject]@{ Kind = $m.Kind; Num = $m.Num; Label = $m.Label; Control = $name })
        }
    }

    # ---------------------------------------------------------- brightness
    # For anything that lit, check whether it is on/off or has intermediate
    # states - some Numark gear has dim/bright or multi-colour pads.
    if ($map.Count -gt 0) {
        Write-Host ''
        Write-Host ('=' * 74) -ForegroundColor DarkGray
        Write-Host ' PASS 3 - value behaviour (on/off vs graded)' -ForegroundColor Yellow
        Write-Host ('=' * 74) -ForegroundColor DarkGray
        foreach ($e in $map) {
            Clear-All
            Write-Host ("  {0} ({1}) - cycling values 00, 01, 40, 7F" -f $e.Control, $e.Label) -ForegroundColor Cyan
            foreach ($v in @(0x00, 0x01, 0x40, 0x7F)) {
                if ($e.Kind -eq 'note') { [void][MidiMon]::Send(0x90, [byte]$e.Num, [byte]$v) }
                else { [void][MidiMon]::Send(0xB0, [byte]$e.Num, [byte]$v) }
                Write-Host ("      value 0x{0:X2}" -f $v)
                Start-Sleep -Milliseconds 900
            }
            $b = Read-Host '    on/off only, or graded? (onoff / graded / other text)'
            Add-Member -InputObject $e -NotePropertyName Behaviour -NotePropertyValue $b -Force
        }
    }

    # -------------------------------------------------------------- output
    $jsonPath = Join-Path $OutDir 'v7-led-map.json'
    $mdPath = Join-Path $OutDir 'v7-led-map.md'
    [pscustomobject]@{
        device = 'Numark V7 (USB 15E4:0075) via Windows vendor driver 2.9.64'
        outputs = $map
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding utf8

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Numark V7 - LED / output map (learned)')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('Host -> device messages and what they light, observed on the panel.')
    [void]$sb.AppendLine('These go out on bulk `0x04`, one MIDI message per 42-byte frame.')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Control | Message | Bytes | Behaviour |')
    [void]$sb.AppendLine('|---|---|---|---|')
    foreach ($e in ($map | Sort-Object Kind, Num)) {
        $bytes = if ($e.Kind -eq 'note') { '`90 {0:X2} vv`' -f $e.Num } else { '`B0 {0:X2} vv`' -f $e.Num }
        [void]$sb.AppendLine("| $($e.Control) | $($e.Label) | $bytes | $($e.Behaviour) |")
    }
    $sb.ToString() | Set-Content -Path $mdPath -Encoding utf8

    Write-Host ''
    Write-Host "Mapped $($map.Count) outputs." -ForegroundColor Green
    Write-Host "  $jsonPath"
    Write-Host "  $mdPath"
}
finally {
    Clear-All
    [MidiMon]::CloseOut()
    Write-Host 'all outputs cleared.' -ForegroundColor DarkGray
}
