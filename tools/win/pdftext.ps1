<#
  Minimal PDF text extractor.

  Written because this machine has no poppler/pdftoppm and the Numark V7
  quickstart guide was the authoritative source for which panel carries the
  line input - a detail the docs had already flip-flopped on once.

  Inflates FlateDecode content streams and pulls the strings out of the text
  operators. Good enough to read a manual; not a general PDF parser.

  Usage: .\pdftext.ps1 -Path file.pdf [-Match 'input']
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Match = '',
    [int]$Context = 0
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Path)) { throw "not found: $Path" }

$bytes = [System.IO.File]::ReadAllBytes($Path)
# latin1 maps bytes 1:1 to chars, so byte offsets stay valid
$raw = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)

$out = New-Object System.Text.StringBuilder
$idx = 0
$streams = 0

while ($true) {
    $s = $raw.IndexOf('stream', $idx)
    if ($s -lt 0) { break }
    $e = $raw.IndexOf('endstream', $s)
    if ($e -lt 0) { break }

    # skip the EOL after the 'stream' keyword
    $start = $s + 6
    if ($raw[$start] -eq "`r") { $start++ }
    if ($raw[$start] -eq "`n") { $start++ }

    $len = $e - $start
    if ($len -gt 0) {
        $chunk = New-Object byte[] $len
        [Array]::Copy($bytes, $start, $chunk, 0, $len)
        try {
            # zlib header is 2 bytes; DeflateStream wants raw deflate
            $ms = New-Object System.IO.MemoryStream(, $chunk[2..($len - 1)])
            $ds = New-Object System.IO.Compression.DeflateStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
            $sr = New-Object System.IO.StreamReader($ds, [System.Text.Encoding]::GetEncoding(28591))
            $text = $sr.ReadToEnd()
            $sr.Close()
            $streams++

            # (literal) Tj   and   [(a) k (b)] TJ
            foreach ($m in [regex]::Matches($text, '\((?:\\.|[^\\()])*\)')) {
                $v = $m.Value.Substring(1, $m.Value.Length - 2)
                $v = $v -replace '\\([()\\])', '$1'
                [void]$out.Append($v)
            }
            [void]$out.AppendLine()
        } catch { }
    }
    $idx = $e + 9
}

$result = $out.ToString()
# collapse the runs of single-glyph draws that PDFs produce
$result = $result -replace '[ \t]{2,}', ' '

Write-Host "inflated $streams streams, $($result.Length) chars" -ForegroundColor DarkGray

if ([string]::IsNullOrWhiteSpace($Match)) {
    $result
} else {
    $lines = $result -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $Match) {
            $lo = [math]::Max(0, $i - $Context)
            $hi = [math]::Min($lines.Count - 1, $i + $Context)
            for ($j = $lo; $j -le $hi; $j++) { Write-Host $lines[$j] }
            Write-Host '---'
        }
    }
}
