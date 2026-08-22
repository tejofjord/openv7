<#
  Rebuild OpenV7Midi.dll from the C# sources in this folder.

  The DLL is a build artifact, but compiling it takes ~20s via Add-Type, so the
  scripts here load the prebuilt assembly instead of recompiling every run.

  Run:  powershell -ExecutionPolicy Bypass -File .\tools\win\build.ps1
#>

$ErrorActionPreference = 'Stop'
$dll = Join-Path $PSScriptRoot 'OpenV7Midi.dll'

# A loaded assembly is locked; a stale copy just means "close other PS sessions".
if (Test-Path $dll) { Remove-Item $dll -Force }

Add-Type -Path (Join-Path $PSScriptRoot 'MidiMon.cs'), (Join-Path $PSScriptRoot 'MidiEnum.cs') `
         -OutputAssembly $dll -OutputType Library

if (Test-Path $dll) {
    Write-Host ("built {0} ({1:N1} KB)" -f $dll, ((Get-Item $dll).Length / 1KB)) -ForegroundColor Green
} else {
    throw 'build failed'
}
