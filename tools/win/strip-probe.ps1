<#
  OpenV7 - characterise the Numark V7's strip search (needle strip).

  The strip's ADDRESS is already confirmed - CC 0x45 on deck A, 0x4D on deck B,
  reporting an absolute 7-bit position. What this establishes is its BEHAVIOUR,
  which the address alone does not tell you:

    - does the value track continuously across a drag, and which end is 0?
    - does a tap give an instant absolute position (needle-drop)?
    - does it reach true 0 and true 127, or stop short of the physical ends?
    - does it repeat while held still, or go silent?
    - and the one that matters most: DOES ANYTHING ARRIVE ON RELEASE?

  That last question decides real behaviour in a DJ app. If lifting a finger
  sends nothing, the host must treat the last value as still current. If lifting
  sends 0, a naive mapping jumps the track to the start every time you let go -
  which looks like a broken mapping but is really a misread of the protocol.

  Messages are grouped into gestures: a gap of more than 300 ms starts a new one.

  Run:  powershell -ExecutionPolicy Bypass -File .\tools\win\strip-probe.ps1
#>

[CmdletBinding()]
param(
    [int]$Seconds = 120,
    [int]$GestureGapMs = 300
)

$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'OpenV7Midi.dll')

$dev = [MidiEnum]::FindIn('V7')
if ($dev -lt 0) { throw 'No Numark V7 MIDI input port found.' }
if ([MidiMon]::OpenIn($dev) -ne 0) { throw 'midiInOpen failed - another app may hold the port.' }

[MidiMon]::RecordRaw(60000)
[MidiMon]::Reset()

Write-Host ''
Write-Host "Recording for $Seconds s. Work the STRIP SEARCH now." -ForegroundColor Green
Write-Host '  1. slow drag end to end, then lift'
Write-Host '  2. tap the middle, lift'
Write-Host '  3. tap one end, lift; tap the other end, lift'
Write-Host '  4. press and hold still ~3 s, then lift'
Write-Host ''
for ($i = $Seconds; $i -gt 0; $i -= 5) {
    Write-Host -NoNewline ("`r  {0,4}s remaining " -f $i)
    Start-Sleep -Seconds 5
}
Write-Host "`r  done.                "

$raw = [MidiMon]::Raw()
[MidiMon]::CloseIn()

$ev = @()
foreach ($r in $raw) {
    $p = $r -split ' '
    if ([int]$p[1] -ne 0xB0) { continue }
    $d1 = [int]$p[2]
    if ($d1 -ne 0x45 -and $d1 -ne 0x4D) { continue }   # strip search, deck A / B
    $ev += [pscustomobject]@{ Ms = [int64]$p[0]; CC = $d1; Val = [int]$p[3] }
}

Write-Host ''
Write-Host "strip-search messages: $($ev.Count)" -ForegroundColor Cyan
if ($ev.Count -eq 0) {
    Write-Host 'Nothing captured - was the strip touched during the window?' -ForegroundColor Yellow
    return
}

$g = 0; $prev = $null; $vals = @()
foreach ($e in $ev) {
    if ($null -eq $prev -or ($e.Ms - $prev) -gt $GestureGapMs) {
        if ($vals.Count) {
            Write-Host ("      {0} messages, {1} -> {2}, range {3}..{4}" -f `
                $vals.Count, $vals[0], $vals[-1],
                ($vals | Measure-Object -Minimum).Minimum, ($vals | Measure-Object -Maximum).Maximum)
        }
        $g++
        $vals = @()
        Write-Host ''
        Write-Host ("--- gesture {0}  (CC 0x{1:X2}) ---" -f $g, $e.CC) -ForegroundColor Cyan
    }
    $gap = if ($null -eq $prev) { 0 } else { $e.Ms - $prev }
    if ($vals.Count -lt 6) { Write-Host ("  +{0,5} ms  val {1,3}" -f $gap, $e.Val) }
    elseif ($vals.Count -eq 6) { Write-Host '  ...' }
    $vals += $e.Val
    $prev = $e.Ms
}
if ($vals.Count) {
    Write-Host ("      {0} messages, {1} -> {2}, range {3}..{4}" -f `
        $vals.Count, $vals[0], $vals[-1],
        ($vals | Measure-Object -Minimum).Minimum, ($vals | Measure-Object -Maximum).Maximum)
}

Write-Host ''
Write-Host 'Key question: does the LAST value of each gesture look like a real' -ForegroundColor Yellow
Write-Host 'finger position, or does it snap to 0 on release?' -ForegroundColor Yellow
