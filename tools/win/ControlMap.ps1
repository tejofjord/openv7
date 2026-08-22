<#
  OpenV7 - the documented Numark V7 control addresses, from docs/CONTROL-MAP.md.

  Shared by midi-learn.ps1 (interactive naming) and midi-observe.ps1 (free-form
  capture), so the expected map lives in exactly one place.

  Keys are "STATUS:DATA1" in hex with the channel nibble masked off.
#>

$EXPECTED = @{
    'B0:00' = 'platter position, deck A'
    'B0:02' = 'platter position, deck B'
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

function Get-ExpectedKey($st, $d1) {
    if ($null -eq $st) { return $null }
    return '{0:X2}:{1:X2}' -f ($st -band 0xF0), $d1
}

function Get-Expected($st, $d1) {
    $k = Get-ExpectedKey $st $d1
    if ($k -and $EXPECTED.ContainsKey($k)) { return $EXPECTED[$k] }
    return $null
}
