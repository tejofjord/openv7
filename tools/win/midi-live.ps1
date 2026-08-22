<#
  OpenV7 - live MIDI monitor for the Numark V7 (Windows vendor driver)

  Prints a running tally of every distinct MIDI message the V7 emits, refreshed
  in place. Use it to sanity-check that the control stream is flowing at all,
  and to eyeball what a given control sends.

  Run:  powershell -ExecutionPolicy Bypass -File .\tools\win\midi-live.ps1
  Quit: q
#>

[CmdletBinding()]
param([int]$InDevice = -1)

$ErrorActionPreference = 'Stop'
$dll = Join-Path $PSScriptRoot 'OpenV7Midi.dll'
if (-not (Test-Path $dll)) { throw "OpenV7Midi.dll missing - run tools/win/build.ps1" }
Add-Type -Path $dll

if ($InDevice -lt 0) { $InDevice = [MidiEnum]::FindIn('V7') }
if ($InDevice -lt 0) { $InDevice = [MidiEnum]::FindIn('Numark') }
if ($InDevice -lt 0) { Write-Host ([MidiEnum]::ListAll()); throw 'No Numark V7 MIDI input port found.' }

$rc = [MidiMon]::OpenIn($InDevice)
if ($rc -ne 0) { throw "midiInOpen failed (rc=$rc). Another app may hold the port." }
[MidiMon]::Reset()

function Get-MsgName($st, $d1) {
    $type = $st -band 0xF0
    $ch = ($st -band 0x0F) + 1
    switch ($type) {
        0x80 { return ("NoteOff   ch{0} note 0x{1:X2}" -f $ch, $d1) }
        0x90 { return ("NoteOn    ch{0} note 0x{1:X2}" -f $ch, $d1) }
        0xA0 { return ("PolyAT    ch{0} note 0x{1:X2}" -f $ch, $d1) }
        0xB0 { return ("CC        ch{0} cc   0x{1:X2}" -f $ch, $d1) }
        0xC0 { return ("PgmChange ch{0}" -f $ch) }
        0xD0 { return ("ChanAT    ch{0}" -f $ch) }
        0xE0 { return ("PitchBend ch{0}" -f $ch) }
        default { return ("status 0x{0:X2}" -f $st) }
    }
}

Clear-Host
Write-Host "OpenV7 live MIDI monitor - device $InDevice" -ForegroundColor Green
Write-Host "Operate the controller. Press q to quit." -ForegroundColor Yellow
Write-Host ''

$tick = 0
while ($true) {
    if ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        if ($k.KeyChar -eq 'q') { break }
    }
    Start-Sleep -Milliseconds 250
    $tick++

    $total = [MidiMon]::Total
    $sum = [MidiMon]::Summary()

    [Console]::SetCursorPosition(0, 3)
    $spin = '|/-\'[$tick % 4]
    Write-Host ("$spin  total messages: {0,-10}  distinct: {1,-6}" -f $total, $sum.Count) -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  message                       count    value range   distinct   last seen' -ForegroundColor DarkGray
    Write-Host '  ----------------------------  -------  -----------   --------   ---------' -ForegroundColor DarkGray

    $rows = @()
    foreach ($line in $sum) {
        $p = $line -split ','
        if ($p[0] -eq 'SYSEX') {
            $rows += [pscustomobject]@{ Sort = 0; Text = ('  SysEx: {0}' -f $p[1]) }
            continue
        }
        $st = [int]$p[0]; $d1 = [int]$p[1]; $cnt = [int]$p[2]
        $mn = [int]$p[3]; $mx = [int]$p[4]; $dst = [int]$p[5]
        $rows += [pscustomobject]@{
            Sort = -$cnt
            Text = ('  {0,-28}  {1,7}  {2,4}..{3,-4}  {4,8}   {5}' -f `
                    (Get-MsgName $st $d1), $cnt, $mn, $mx, $dst, $p[7].Split('|')[0])
        }
    }
    foreach ($r in ($rows | Sort-Object Sort | Select-Object -First 30)) {
        Write-Host ($r.Text.PadRight(100).Substring(0, 100))
    }
    # clear any stale rows from a previous, longer render
    for ($i = $rows.Count; $i -lt 30; $i++) { Write-Host (' ' * 100) }
}

[MidiMon]::CloseIn()
Write-Host ''
Write-Host 'stopped.' -ForegroundColor Yellow
