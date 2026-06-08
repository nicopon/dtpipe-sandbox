#!/usr/bin/env pwsh
<#
.SYNOPSIS
    PowerShell benchmark orchestrator — delegates to benchmarks.sh via bash.

.DESCRIPTION
    Self-contained competitive benchmark runner for Windows (PowerShell 7+).
    Locates a bash executable (WSL > Git Bash > system bash) and delegates
    all orchestration to benchmarks.sh.

    The actual benchmark work runs INSIDE Docker containers; bash is only
    required on the host to drive the Docker commands.

.PARAMETER Rows
    Number of source rows (default: 250000).

.PARAMETER Repetitions
    Number of runs per benchmark (default: 3).

.PARAMETER Scope
    Restrict to a single pipeline: all | B01 … B12 (default: all).

.PARAMETER Tool
    Restrict to a single tool: all | dtpipe | pandas | meltano | sling |
    ingestr | native (default: all).

.PARAMETER SkipInfra
    Skip DB infrastructure startup (use when containers are already running).

.PARAMETER InfraCompose
    Path to a custom infrastructure docker-compose file.

.PARAMETER CleanArtifacts
    Remove previous tool output files before running.

.EXAMPLE
    # Full benchmark with defaults:
    .\benchmarks.ps1

    # 1 million rows, 5 repetitions:
    .\benchmarks.ps1 -Rows 1000000 -Repetitions 5

    # Single tool, single pipeline, infra already up:
    .\benchmarks.ps1 -Tool dtpipe -Scope B01 -SkipInfra

.NOTES
    Requires:
      - Docker Desktop (or Docker Engine) with the Compose plugin
      - One of: WSL, Git for Windows, or a native bash in PATH
    
    On Linux / macOS run benchmarks.sh directly.
#>

[CmdletBinding()]
param(
    [int]    $Rows           = 250000,
    [int]    $Repetitions    = 3,
    [string] $Scope          = "all",
    [string] $Tool           = "all",
    [switch] $SkipInfra,
    [switch] $CleanArtifacts,
    [string] $InfraCompose   = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$BashScript = Join-Path $ScriptDir "benchmarks.sh"

# ─────────────────────────────────────────────────────────────
# 1. Prerequisite checks
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║       Competitive Benchmark — dtpipe vs the field            ║" -ForegroundColor Green
Write-Host "║  dtpipe · pandas · meltano · sling · ingestr · native        ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

# Docker check
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "Error: Docker is not installed or not in PATH." -ForegroundColor Red
    Write-Host "Install Docker Desktop: https://docs.docker.com/desktop/install/windows-install/" -ForegroundColor Yellow
    exit 1
}

# ─────────────────────────────────────────────────────────────
# 2. Locate a bash executable
# ─────────────────────────────────────────────────────────────
$BashExe  = $null
$BashMode = $null

# 2a. WSL (preferred on Windows — best POSIX compatibility)
if (Get-Command wsl -ErrorAction SilentlyContinue) {
    # Verify WSL actually has bash
    $wslTest = & wsl bash --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $BashExe  = "wsl"
        $BashMode = "wsl"
    }
}

# 2b. Git for Windows bash
if (-not $BashExe) {
    $gitBashPaths = @(
        "$Env:ProgramFiles\Git\bin\bash.exe",
        "$Env:ProgramFiles\Git\usr\bin\bash.exe",
        "${Env:ProgramFiles(x86)}\Git\bin\bash.exe"
    )
    foreach ($p in $gitBashPaths) {
        if (Test-Path $p) {
            $BashExe  = $p
            $BashMode = "gitbash"
            break
        }
    }
}

# 2c. System bash (macOS / Linux / WSL2 native)
if (-not $BashExe) {
    $sysBash = Get-Command bash -ErrorAction SilentlyContinue
    if ($sysBash) {
        $BashExe  = $sysBash.Source
        $BashMode = "native"
    }
}

if (-not $BashExe) {
    Write-Host ""
    Write-Host "Error: No bash executable found. benchmarks.sh requires bash." -ForegroundColor Red
    Write-Host ""
    Write-Host "Please install one of the following:" -ForegroundColor Yellow
    Write-Host "  • WSL (Windows Subsystem for Linux)" -ForegroundColor Yellow
    Write-Host "    wsl --install" -ForegroundColor Cyan
    Write-Host "  • Git for Windows (includes Git Bash)" -ForegroundColor Yellow
    Write-Host "    https://git-scm.com/download/win" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}

Write-Host "  Bash:  $BashMode ($BashExe)" -ForegroundColor Cyan
Write-Host "  Rows:  $Rows" -ForegroundColor Cyan
Write-Host "  Runs:  $Repetitions" -ForegroundColor Cyan
Write-Host "  Scope: $Scope" -ForegroundColor Cyan
Write-Host "  Tool:  $Tool" -ForegroundColor Cyan
Write-Host ""

# ─────────────────────────────────────────────────────────────
# 3. Build argument list for benchmarks.sh
# ─────────────────────────────────────────────────────────────
$BashArgs = @(
    "--rows",        $Rows,
    "--repetitions", $Repetitions,
    "--scope",       $Scope,
    "--tool",        $Tool
)
if ($SkipInfra)      { $BashArgs += "--skip-infra" }
if ($CleanArtifacts) { $BashArgs += "--clean-artifacts" }
if ($InfraCompose)   { $BashArgs += @("--infra-compose", $InfraCompose) }

# ─────────────────────────────────────────────────────────────
# 4. Execute via the detected bash
# ─────────────────────────────────────────────────────────────
if ($BashMode -eq "wsl") {
    # Convert Windows path to WSL path: C:\foo\bar → /mnt/c/foo/bar
    $WslScript = $BashScript `
        -replace '\\', '/' `
        -replace '^([A-Za-z]):', { "/mnt/$($_.Groups[1].Value.ToLower())" }

    & wsl bash $WslScript @BashArgs
}
elseif ($BashMode -eq "gitbash") {
    # Git Bash accepts forward-slash Windows paths
    $FwdScript = $BashScript -replace '\\', '/'
    & $BashExe $FwdScript @BashArgs
}
else {
    # Native bash (macOS / Linux / WSL2 shell)
    & $BashExe $BashScript @BashArgs
}

exit $LASTEXITCODE
