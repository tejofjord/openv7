<#
  OpenV7 - generate a proportional SVG of the V7's top panel.

  Built from the camera photographs rather than drawn by eye, so the layout
  matches the real unit and the LED markers land where the lamps actually are.

  Two photos were used and they have different framing: a wide shot that shows
  the whole deck including the top edge, and a close-up (in which the top edge
  is cropped) that the LED sweep ran against. The platter appears in both, so it
  serves as the registration feature - every measurement below is expressed in
  PLATTER RADII relative to the platter centre, which makes the two frames
  directly comparable without needing them to share a scale.

  Usage: .\make-panel-svg.ps1
#>

[CmdletBinding()]
param(
    [string]$LedJson = '',
    [string]$OutSvg = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($LedJson)) { $LedJson = Join-Path $repo 'captures\v7-led-cam-final.json' }
if ([string]::IsNullOrWhiteSpace($OutSvg)) { $OutSvg = Join-Path $repo 'docs\img\v7-panel.svg' }
New-Item -ItemType Directory -Force -Path (Split-Path $OutSvg) | Out-Null

# --- registration: the platter, as measured in the close-up frame ------------
$PC_X = 702.0; $PC_Y = 320.0; $PR = 237.0

# --- panel extent, measured in the WIDE shot and converted to platter radii ---
# wide shot: platter centre (700,305) r=130; panel x 443..950, y 95..545
$L = -1.977; $R = 1.923; $T = -1.615; $B = 1.846
$W = $R - $L      # panel width  in platter radii
$H = $B - $T      # panel height in platter radii

# Close-up pixel -> normalised panel coords (0..1 across, 0..1 down).
# Every operand is pulled through an explicit [double] cast: read from the
# enclosing scope these arrive wrapped as PSObject, and the arithmetic then
# fails with a missing op_Subtraction.
function ToU([double]$px) {
    [double]$cx = $script:PC_X; [double]$rad = $script:PR
    [double]$lo = $script:L;    [double]$wid = $script:W
    return ((($px - $cx) / $rad) - $lo) / $wid
}
function ToV([double]$py) {
    [double]$cy = $script:PC_Y; [double]$rad = $script:PR
    [double]$to = $script:T;    [double]$hei = $script:H
    return ((($py - $cy) / $rad) - $to) / $hei
}

# --- output canvas ------------------------------------------------------------
$PAD = 30
$CW = 900.0
$CH = [math]::Round($CW * $H / $W)

function X([double]$u) { [double]$p = $script:PAD; [double]$w = $script:CW; return [math]::Round($p + $u * $w, 1) }
function Y([double]$v) { [double]$p = $script:PAD; [double]$h = $script:CH; return [math]::Round($p + $v * $h, 1) }
function S([double]$u) { [double]$w = $script:CW; return [math]::Round($u * $w, 1) }   # scalar span

$sb = New-Object System.Text.StringBuilder
function W2($s) { [void]$sb.AppendLine($s) }

W2 ('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f ($CW + 2*$PAD), ($CH + 2*$PAD))
W2 '  <defs>'
W2 '    <style>'
W2 '      .panel { fill:#1b1d21; stroke:#4a4f57; stroke-width:2; }'
W2 '      .slot  { fill:#0e1013; stroke:#5c636d; }'
W2 '      .metal { fill:none; stroke:#9aa3ad; stroke-width:3; }'
W2 '      .ctl   { fill:#2a2e34; stroke:#565c65; stroke-width:1.5; }'
W2 '      .led   { fill:#ff3b30; stroke:#ffb3ae; stroke-width:1; }'
W2 '      .lbl   { fill:#8b939d; font-family:Consolas,monospace; font-size:11px; }'
W2 '      .ledlbl{ fill:#ffd9d6; font-family:Consolas,monospace; font-size:10px; }'
W2 '      .title { fill:#e6e9ed; font-family:Segoe UI,sans-serif; font-size:18px; font-weight:600; }'
W2 '    </style>'
W2 '  </defs>'
W2 ('  <rect x="0" y="0" width="{0}" height="{1}" fill="#0b0c0e"/>' -f ($CW + 2*$PAD), ($CH + 2*$PAD))

# panel body
W2 ('  <rect class="panel" x="{0}" y="{1}" width="{2}" height="{3}" rx="10"/>' -f $PAD, $PAD, $CW, $CH)

# platter: centre and radius in normalised units
$pcu = ToU $PC_X; $pcv = ToV $PC_Y
$prU = (1.0 / $W)                       # one platter radius as a fraction of panel width
W2 ('  <circle class="metal" cx="{0}" cy="{1}" r="{2}"/>' -f (X $pcu), (Y $pcv), (S $prU))
W2 ('  <circle cx="{0}" cy="{1}" r="{2}" fill="#141619" stroke="#3a3f46" stroke-width="1"/>' -f (X $pcu), (Y $pcv), (S ($prU * 0.86)))
W2 ('  <circle cx="{0}" cy="{1}" r="{2}" fill="#7d2b2b" stroke="#a33" stroke-width="1"/>' -f (X $pcu), (Y $pcv), (S ($prU * 0.30)))
W2 ('  <text class="lbl" x="{0}" y="{1}" text-anchor="middle">PLATTER</text>' -f (X $pcu), (Y ($pcv + $prU * 0.46)))

# --- panel features, measured from the close-up ------------------------------
function Slot([double]$x1, [double]$y1, [double]$x2, [double]$y2, [string]$label) {
    # cast explicitly: without it these arrive as PSObject and arithmetic on
    # them fails with a missing op_Subtraction
    [double]$u1 = ToU $x1; [double]$v1 = ToV $y1
    [double]$u2 = ToU $x2; [double]$v2 = ToV $y2
    W2 ('  <rect x="{0}" y="{1}" width="{2}" height="{3}" rx="4" fill="#0e1013" stroke="#5c636d" stroke-width="1.5"/>' -f `
        (X $u1), (Y $v1), (S ($u2 - $u1)), ([math]::Round(($v2 - $v1) * $CH, 1)))
    if ($label) {
        W2 ('  <text class="lbl" x="{0}" y="{1}" text-anchor="middle">{2}</text>' -f `
            (X (($u1 + $u2) / 2)), (Y ($v2 + 0.035)), $label)
    }
}

Slot 1020 215 1085 430 'STRIP SEARCH'      # right-hand vertical slot
Slot  445 568  690 622 'PITCH FADER'       # long fader, bottom centre
Slot  355 195  415 455 ''                  # left button column housing
Slot  905 485 1045 645 ''                  # bottom-right lamp block

# --- LED markers --------------------------------------------------------------
$leds = Get-Content $LedJson -Raw | ConvertFrom-Json
$strong = @($leds | Where-Object { $_.CellPixels -ge 60 })
foreach ($led in $strong) {
    # parenthesise: [double]$led.X would cast $led THEN take .X, which throws
    [double]$px = $led.X
    [double]$py = $led.Y
    $u = ToU $px; $v = ToV $py
    if ($u -lt -0.02 -or $u -gt 1.02 -or $v -lt -0.02 -or $v -gt 1.02) { continue }
    W2 ('  <circle class="led" cx="{0}" cy="{1}" r="5"/>' -f (X $u), (Y $v))
    W2 ('  <text class="ledlbl" x="{0}" y="{1}">{2}</text>' -f ((X $u) + 8), ((Y $v) + 4), $led.Hex)
}

W2 ('  <text class="title" x="{0}" y="{1}">Numark V7 - panel layout</text>' -f $PAD, ($PAD - 10))
W2 ('  <text class="lbl" x="{0}" y="{1}">{2} LED positions measured by camera - proportions from photographs</text>' -f `
    ($PAD + 250), ($PAD - 10), $strong.Count)
W2 '</svg>'

$sb.ToString() | Set-Content -Path $OutSvg -Encoding utf8
Write-Host "wrote $OutSvg ($($strong.Count) LEDs, canvas $([int]($CW+2*$PAD))x$([int]($CH+2*$PAD)))" -ForegroundColor Green

