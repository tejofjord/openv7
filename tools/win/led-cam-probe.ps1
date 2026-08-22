<#
  OpenV7 - map the V7's LEDs automatically, using a webcam.

  The device has no feedback channel for LEDs (a full CC and note sweep at the
  raw USB level draws no reply), so the only way to learn which command drives
  which lamp is to look at the panel. This does the looking with a camera
  instead of a person:

    1. turn every LED off, photograph the panel  -> baseline
    2. for each candidate CC: send it, photograph, diff against the baseline
    3. the brightest changed cluster is that command's lamp

  More reliable than tapping a key at each step - no reaction-time error, it
  catches dim lamps and simultaneous changes, and it records WHERE each lamp is
  rather than just that something happened.

  The camera must see the whole panel and must not move during the run.

  Usage:
    .\led-cam-probe.ps1 -First 0x00 -Last 0x40
#>

[CmdletBinding()]
param(
    [int]$First = 0x00,
    [int]$Last = 0x40,
    [byte]$OnValue = 0x7F,
    # Measured noise floor on this camera: two identical static frames differ by
    # ~1900 pixels at threshold 28, scattered across the whole image. Frames are
    # temporally averaged to suppress that, and detection uses the densest CELL
    # rather than a global count, because noise spreads and an LED does not.
    # Measured on this rig: with 20 settling frames and exposure normalisation,
    # two static frames differ by at most 3 pixels in any one cell at th=45.
    # A lit LED is far above that, so 25 leaves a wide margin.
    [int]$Threshold = 45,
    [int]$Cell = 24,             # hotspot cell size in pixels
    [int]$MinCellPixels = 25,    # changed pixels within one cell to call it lit
    [int]$SettleFrames = 20,     # frames discarded so auto-exposure settles
    # An LED changes a few hundred pixels. If a frame differs from the baseline
    # by more than this, something moved in shot or the lighting changed, and
    # the comparison is meaningless - a whole run was once silently ruined by a
    # person drifting into the corner of frame. Flag it instead of reporting it.
    [int]$MaxTotalPixels = 4000,
    [int]$SettleMs = 250,
    [string]$Camera = 'Integrated Camera',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $repo 'captures' }
$camDir = Join-Path $OutDir 'cam'
New-Item -ItemType Directory -Force -Path $camDir | Out-Null

$ff = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe"
if (-not (Test-Path $ff)) {
    $c = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($c) { $ff = $c.Source } else { throw 'ffmpeg not found' }
}

Add-Type -Path (Join-Path $PSScriptRoot 'OpenV7Midi.dll')
Add-Type -Path (Join-Path $PSScriptRoot 'ImageDiff.cs') -ReferencedAssemblies System.Drawing

$out = [MidiEnum]::FindOut('V7')
if ($out -lt 0) { throw 'No Numark V7 MIDI output port found.' }
if ([MidiMon]::OpenOut($out) -ne 0) { throw 'midiOutOpen failed' }

# Motor commands, BOTH decks - never send these, the platter would spin.
$MOTOR = @(0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x69) +
         @(0x4B,0x4C,0x4D,0x4E,0x4F,0x50,0x51,0x52,0x53,0x73)

function Get-Frame([string]$path) {
    if (Test-Path $path) { Remove-Item $path -Force }
    # Grab N frames with -update so each overwrites the last, keeping only the
    # final settled one. Deliberately NOT tmix: averaging a sliding window pulls
    # in ffmpeg's initial garbage frames and made the noise floor 200x worse
    # (best-cell 576 vs 3) because every run averaged a different mix of junk.
    & $ff -hide_banner -loglevel error -f dshow -video_size 1280x720 `
        -i "video=$Camera" -frames:v $SettleFrames -update 1 -y $path 2>&1 | Out-Null
    return (Test-Path $path)
}

function Set-AllLeds([byte]$v) {
    for ($cc = 0; $cc -le 0x7F; $cc++) {
        if ($MOTOR -contains $cc) { continue }
        [void][MidiMon]::Send(0xB0, [byte]$cc, $v)
    }
}

$results = New-Object System.Collections.ArrayList
$contaminated = 0

try {
    Write-Host 'Turning all LEDs off and taking the baseline...' -ForegroundColor Cyan
    Set-AllLeds 0x00
    Start-Sleep -Milliseconds 700
    $baseline = Join-Path $camDir 'baseline.png'
    if (-not (Get-Frame $baseline)) { throw 'camera capture failed' }
    Write-Host "  baseline -> $baseline" -ForegroundColor DarkGray

    $total = 0
    for ($cc = $First; $cc -le $Last; $cc++) { if ($MOTOR -notcontains $cc) { $total++ } }
    Write-Host ("Sweeping {0} CCs (0x{1:X2}-0x{2:X2})..." -f $total, $First, $Last) -ForegroundColor Cyan

    $n = 0
    for ($cc = $First; $cc -le $Last; $cc++) {
        if ($MOTOR -contains $cc) { continue }
        $n++
        # Paired off/on capture rather than one shared baseline. A single
        # baseline degrades over a long run - ambient light drifts, and the
        # laptop's own screen (which faces the deck) changes brightness as this
        # script prints. Taking the OFF frame immediately before the ON frame
        # keeps the two seconds apart, so almost nothing but the LED differs.
        $ref = Join-Path $camDir 'ref.png'
        if (-not (Get-Frame $ref)) {
            Write-Host ("  [{0,3}/{1}] CC 0x{2:X2}  ref capture failed" -f $n,$total,$cc) -ForegroundColor Red
            continue
        }

        [void][MidiMon]::Send(0xB0, [byte]$cc, $OnValue)
        Start-Sleep -Milliseconds $SettleMs

        $shot = Join-Path $camDir ('cc{0:X2}.png' -f $cc)
        $ok = Get-Frame $shot
        [void][MidiMon]::Send(0xB0, [byte]$cc, 0x00)

        if (-not $ok) { Write-Host ("  [{0,3}/{1}] CC 0x{2:X2}  capture failed" -f $n,$total,$cc) -ForegroundColor Red; continue }

        $d = [ImageDiff]::Hotspot($ref, $shot, $Threshold, $Cell)
        $p = $d -split ','
        if ($p[0] -eq 'ERR') { Write-Host "  CC 0x$('{0:X2}' -f $cc): $d" -ForegroundColor Red; continue }
        $totalPx = [int]$p[0]; $bestPx = [int]$p[1]

        if ($totalPx -gt $MaxTotalPixels) {
            $contaminated++
            Write-Host ("  [{0,3}/{1}] CC 0x{2:X2}  !! SCENE CHANGED ({3} px) - not counted" -f `
                $n, $total, $cc, $totalPx) -ForegroundColor Red
            Remove-Item $shot -Force -ErrorAction SilentlyContinue
            continue
        }

        if ($bestPx -ge $MinCellPixels) {
            $rec = [pscustomobject]@{
                CC = $cc; Hex = ('0x{0:X2}' -f $cc)
                CellPixels = $bestPx; TotalPixels = $totalPx
                X = [int]$p[2]; Y = [int]$p[3]; Peak = [int]$p[4]
                Shot = $shot
            }
            [void]$results.Add($rec)
            Write-Host ("  [{0,3}/{1}] CC 0x{2:X2}  *** LIT ***  cell={3} total={4} at ({5},{6}) peak={7}" -f `
                $n, $total, $cc, $bestPx, $totalPx, $rec.X, $rec.Y, $rec.Peak) -ForegroundColor Green
        } else {
            Write-Host ("  [{0,3}/{1}] CC 0x{2:X2}  -  (cell={3} total={4})" -f `
                $n, $total, $cc, $bestPx, $totalPx) -ForegroundColor DarkGray
            Remove-Item $shot -Force -ErrorAction SilentlyContinue
        }
    }
}
finally {
    Set-AllLeds 0x00
    [MidiMon]::CloseOut()
}

Write-Host ''
if ($contaminated -gt 0) {
    Write-Host "WARNING: $contaminated frames rejected - the scene changed mid-run." -ForegroundColor Yellow
    Write-Host '         Keep the camera, the deck and the lighting still, and re-run' -ForegroundColor Yellow
    Write-Host '         the affected range.' -ForegroundColor Yellow
    Write-Host ''
}
Write-Host "LEDs found: $($results.Count)" -ForegroundColor Green
foreach ($r in $results) {
    Write-Host ("  {0}  {1,5} px  at ({2,4},{3,4})  box [{4},{5} - {6},{7}]" -f `
        $r.Hex, $r.Pixels, $r.X, $r.Y, $r.MinX, $r.MinY, $r.MaxX, $r.MaxY)
}

if ($results.Count -gt 0) {
    $marks = $results | ForEach-Object { '{0}:{1}:{2}' -f $_.X, $_.Y, $_.Hex }
    $annotated = Join-Path $camDir 'led-map-annotated.png'
    [void][ImageDiff]::Annotate($baseline, $annotated, $marks)
    Write-Host ''
    Write-Host "annotated map -> $annotated" -ForegroundColor Green
}

$json = Join-Path $OutDir 'v7-led-cam-map.json'
$results | ConvertTo-Json -Depth 5 | Set-Content -Path $json -Encoding utf8
Write-Host "json -> $json" -ForegroundColor DarkGray
