#!/usr/bin/env pwsh
# stop-all.ps1 — Stop the unified monorepo launcher services.
#
# Kills processes listening on ports 3000 (dashboard) and 4000 (api-gateway),
# or by PID file if launch-all.ps1 wrote one (%TEMP%\unified-launch-pids.json).
# Reports which ports were freed.

param(
    [int[]]$Ports    = @(3000, 4000),
    [string]$PidFile = (Join-Path $env:TEMP "unified-launch-pids.json")
)

$ErrorActionPreference = "Continue"
$killed = [System.Collections.Generic.List[string]]::new()
$freed  = [System.Collections.Generic.List[string]]::new()

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  UNIFIED MONOREPO STOP" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# --- 1. Kill by PID file (graceful path from launch-all.ps1) ---
if (Test-Path -LiteralPath $PidFile) {
    Write-Host "Found PID file: $PidFile" -ForegroundColor Green
    $pids = Get-Content -LiteralPath $PidFile -Raw | ConvertFrom-Json

    foreach ($name in @("Gateway", "Dashboard")) {
        $pid = $pids.PSObject.Properties.Name | Where-Object { $_ -eq $name }
        if (-not $pid) { continue }
        $pidValue = $pids.$name
        if (-not $pidValue) { continue }

        try {
            $proc = Get-Process -Id $pidValue -ErrorAction Stop
            Write-Host "Killing $name (PID $pidValue)..." -ForegroundColor Yellow
            $proc.Kill()
            $proc.WaitForExit(5000) | Out-Null
            $killed.Add("$name (PID $pidValue)")
        } catch {
            Write-Host "Could not kill $name (PID $pidValue): $_" -ForegroundColor Red
        }
    }

    # Clean up the PID file
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue | Out-Null
    Write-Host ""
}

# --- 2. Kill by listening port ---
foreach ($port in $Ports) {
    $before = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    $count  = ($before | Measure-Object).Count

    foreach ($c in $before) {
        try {
            $proc = Get-Process -Id $c.OwningProcess -ErrorAction Stop
            Write-Host "Port $port: killing PID $($c.OwningProcess) ($($proc.ProcessName))..." -ForegroundColor Yellow
            $proc.Kill()
            $proc.WaitForExit(5000) | Out-Null
            $killed.Add("Port $port (PID $($c.OwningProcess), $($proc.ProcessName))")
        } catch {
            Write-Host "Port $port: could not kill PID $($c.OwningProcess): $_" -ForegroundColor Red
        }
    }

    # Re-check whether the port is now free
    Start-Sleep -Seconds 1
    $after = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    $still = ($after | Measure-Object).Count

    if ($still -eq 0) {
        $freed.Add("Port $port")
        Write-Host "Port $port is now free." -ForegroundColor Green
    } else {
        Write-Host "Port $port is still in use ($still listener(s))." -ForegroundColor Red
        $freed.Add("Port $port (NOT freed)")
    }
}

# --- Result ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  RESULT" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($killed.Count -gt 0) {
    Write-Host "Killed processes:" -ForegroundColor Green
    $killed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Green }
} else {
    Write-Host "No processes were killed." -ForegroundColor Yellow
}

Write-Host ""
if ($freed.Count -gt 0) {
    Write-Host "Ports freed:" -ForegroundColor Green
    $freed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Green }
}

if ($killed.Count -eq 0 -and $freed.Count -eq 0) {
    Write-Host "No listeners found on ports $($Ports -join ', '). Nothing to do." -ForegroundColor Yellow
}