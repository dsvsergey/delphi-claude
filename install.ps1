# Registers (or removes) the Claude Code package in the Delphi 13 IDE (32- and 64-bit).
# Close RAD Studio before running.
#   powershell -ExecutionPolicy Bypass -File install.ps1            # install
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall # remove
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$BdsVersion = '37.0'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$base = "HKCU:\Software\Embarcadero\BDS\$BdsVersion"
$description = 'Claude Code IDE Integration'

if (Get-Process bds -ErrorAction SilentlyContinue) {
    Write-Warning 'RAD Studio is running. Close it first, otherwise it will overwrite the package list on exit.'
}

$targets = @(
    @{ Key = "$base\Known Packages";     Bpl = Join-Path $root 'bin\Win32\ClaudeCodeIDE370.bpl' },
    @{ Key = "$base\Known Packages x64"; Bpl = Join-Path $root 'bin\Win64\ClaudeCodeIDE370.bpl' }
)

foreach ($t in $targets) {
    if (-not (Test-Path $t.Key)) {
        Write-Host "Skipping $($t.Key) (not found)"
        continue
    }
    # Drop any previous registration of this package, wherever it was built.
    $props = (Get-ItemProperty $t.Key).PSObject.Properties |
        Where-Object { $_.Name -like '*ClaudeCodeIDE*.bpl' }
    foreach ($p in $props) {
        Remove-ItemProperty -Path $t.Key -Name $p.Name
        Write-Host "Removed $($p.Name)"
    }
    if (-not $Uninstall) {
        if (-not (Test-Path $t.Bpl)) {
            throw "$($t.Bpl) not found. Run build.bat first."
        }
        New-ItemProperty -Path $t.Key -Name $t.Bpl -Value $description -PropertyType String -Force | Out-Null
        Write-Host "Registered $($t.Bpl)"
    }
}
