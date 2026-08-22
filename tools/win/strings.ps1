<#
  Extract printable ASCII and UTF-16LE strings from a binary.

  Used for static analysis of the Numark/Ploytec vendor driver binaries
  (v7_usb.sys etc.) alongside the dynamic USB capture - the driver's own
  strings often name registry keys, IOCTLs and error paths that hint at the
  init / keepalive / recovery logic OpenV7 has to reproduce.

  Usage: .\strings.ps1 -Path C:\Windows\System32\drivers\v7_usb.sys [-Min 5]
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Min = 5,
    [switch]$Unicode,
    [switch]$Ascii
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Path)) { throw "not found: $Path" }
if (-not $Unicode -and -not $Ascii) { $Ascii = $true; $Unicode = $true }

$bytes = [System.IO.File]::ReadAllBytes($Path)
$pattern = "[\x20-\x7E]{$Min,}"
$results = New-Object System.Collections.Generic.HashSet[string]

if ($Ascii) {
    # latin1 maps bytes 1:1 onto chars, so offsets stay meaningful
    $s = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    foreach ($m in [regex]::Matches($s, $pattern)) { [void]$results.Add($m.Value) }
}
if ($Unicode) {
    $s = [System.Text.Encoding]::Unicode.GetString($bytes)
    foreach ($m in [regex]::Matches($s, $pattern)) { [void]$results.Add($m.Value) }
}

$results
