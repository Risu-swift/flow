<#
.SYNOPSIS
    Build this fork of flow and install it to the user bin directory.

.DESCRIPTION
    Builds with the pinned Zig 0.16.0 toolchain and copies flow.exe into
    ~/.local/bin. Windows locks a running executable, so an in-use binary is
    renamed aside rather than overwritten; the new build takes effect the next
    time flow starts.
#>
[CmdletBinding()]
param(
    [string]$Zig = 'D:\zig-0.16.0\zig.exe',
    [string]$InstallDir = (Join-Path $HOME '.local\bin'),
    [ValidateSet('ReleaseFast', 'ReleaseSafe', 'ReleaseSmall', 'Debug')]
    [string]$Optimize = 'ReleaseFast'
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not (Test-Path $Zig)) {
    throw "Zig 0.16.0 not found at $Zig. Pass -Zig <path> or reinstall the toolchain."
}

Write-Host "building flow ($Optimize) with $Zig" -ForegroundColor Cyan
& $Zig build "-Doptimize=$Optimize"
if ($LASTEXITCODE -ne 0) { throw "build failed with exit code $LASTEXITCODE" }

$built = Join-Path $PSScriptRoot 'zig-out\bin\flow.exe'
if (-not (Test-Path $built)) { throw "build produced no binary at $built" }

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

$target = Join-Path $InstallDir 'flow.exe'
$running = Get-Process flow -ErrorAction SilentlyContinue

if ($running) {
    Write-Warning "flow is running (PID $($running.Id -join ', ')); the new build applies on next start"
    # A previously displaced binary may still be executing, so it cannot be
    # deleted or reused as a rename target. Move aside under a unique name and
    # sweep up whatever is no longer locked.
    if (Test-Path $target) {
        $stale = Join-Path $InstallDir ("flow-stale-{0}.exe" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item $target $stale -Force
    }
    Get-ChildItem -Path $InstallDir -Filter 'flow-stale-*.exe' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

Copy-Item $built $target -Force

# Capture in full before trimming: piping a native command into Select-Object
# -First closes the pipe early and surfaces a bogus exit code.
$versionLines = @(& $target --version)
Write-Host "installed to $target" -ForegroundColor Green
Write-Host (($versionLines | Select-Object -First 3) -join "`n")
exit 0
