#!/usr/bin/env pwsh
# Unified launcher: starts dashboard (frontend) + api-gateway (backend)
# Reads discovered services and registers them as proxy routes.
#
# Parameters:
#   -DashboardPort   Port for the dashboard frontend (default: 3000)
#   -GatewayPort     Port for the API gateway backend (default: 4000)
#
# Log file: %TEMP%\unified-launch.log
# PID file:   %TEMP%\unified-launch-pids.json  (used by stop-all.ps1)

param(
    [string]$MonoRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")),
    [int]$DashboardPort   = 3000,
    [int]$GatewayPort     = 4000
)

$ErrorActionPreference = "Continue"
$LogPath   = Join-Path $env:TEMP "unified-launch.log"
$PidFile   = Join-Path $env:TEMP "unified-launch-pids.json"
$GatewayLog = Join-Path $env:TEMP "gateway.log"
$GatewayErr = Join-Path $env:TEMP "gateway.err"
$DashLog   = Join-Path $env:TEMP "dashboard.log"
$DashErr   = Join-Path $env:TEMP "dashboard.err"

# --- Logging helper (console + %TEMP%\unified-launch.log) ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    $line | Out-File -FilePath $LogPath -Append -Encoding UTF8
    Write-Host $line
}

# Reset the launcher log for this run
"=== Unified launcher started $(Get-Date) ===" | Out-File -FilePath $LogPath -Encoding UTF8

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  UNIFIED MONOREPO LAUNCHER" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Dashboard (Frontend):  http://localhost:$DashboardPort"
Write-Host "API Gateway (Backend): http://localhost:$GatewayPort"
Write-Host ""
Write-Log "Launcher started. Dashboard port=$DashboardPort, Gateway port=$GatewayPort"
Write-Log "Monorepo root: $MonoRepoRoot"

# --- Validate pnpm is installed ---
if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    $msg = "ERROR: pnpm not found. Install: https://pnpm.io"
    Write-Host $msg -ForegroundColor Red
    Write-Log $msg "ERROR"
    exit 1
}
Write-Log "pnpm found: $(pnpm --version)"

Push-Location $MonoRepoRoot | Out-Null

# --- Run pnpm install at monorepo root ---
Write-Host "Installing dependencies..." -ForegroundColor Yellow
Write-Log "Running pnpm install at monorepo root"
$installOut = pnpm install 2>&1
if ($LASTEXITCODE -ne 0) {
    $msg = "ERROR: pnpm install failed. See $LogPath"
    Write-Host $msg -ForegroundColor Red
    Write-Log $msg "ERROR"
    $installOut | Out-File -FilePath $LogPath -Append -Encoding UTF8
    Pop-Location | Out-Null
    exit 1
}
Write-Log "pnpm install completed"

# --- Start API Gateway (pnpm --filter api-gateway dev) ---
Write-Host "Starting API Gateway on port $GatewayPort..." -ForegroundColor Green
Write-Log "Starting api-gateway: pnpm --filter api-gateway dev"
$gatewayProc = Start-Process pnpm -ArgumentList @("--filter", "api-gateway", "dev") `
    -WorkingDirectory $MonoRepoRoot -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $GatewayLog -RedirectStandardError $GatewayErr

# --- Start Dashboard (pnpm --filter dashboard dev -- --port <port>) ---
Write-Host "Starting Dashboard on port $DashboardPort..." -ForegroundColor Green
Write-Log "Starting dashboard: pnpm --filter dashboard dev -- --port $DashboardPort"
$dashboardProc = Start-Process pnpm -ArgumentList @("--filter", "dashboard", "dev", "--", "--port", $DashboardPort) `
    -WorkingDirectory $MonoRepoRoot -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $DashLog -RedirectStandardError $DashErr

# Write PID file so stop-all.ps1 can kill by PID
$pids = [PSCustomObject]@{
    Gateway        = $gatewayProc.Id
    Dashboard      = $dashboardProc.Id
    GatewayPort    = $GatewayPort
    DashboardPort  = $DashboardPort
    StartedAt      = (Get-Date -Format o)
}
$pids | ConvertTo-Json | Set-Content -Path $PidFile -Encoding UTF8

# --- Health check helper ---
function Wait-Reachable {
    param([string]$Url, [int]$TimeoutSeconds = 30, [string]$ServiceName = "service")
    $start = Get-Date
    while ((Get-Date) - $start).TotalSeconds -lt $TimeoutSeconds) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -Method GET -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                Write-Log "$ServiceName reachable at $Url (HTTP $($resp.StatusCode))"
                return $true
            }
        } catch {
            # Service not up yet; keep polling.
        }
        Start-Sleep -Seconds 1
    }
    Write-Log "$ServiceName NOT reachable at $Url after ${TimeoutSeconds}s" "WARN"
    return $false
}

# --- Wait for gateway health endpoint, then dashboard ---
Write-Host ""
Write-Host "Waiting for services to become healthy..." -ForegroundColor Yellow
$gatewayOk  = Wait-Reachable -Url "http://localhost:$GatewayPort/health" -TimeoutSeconds 30 -ServiceName "API Gateway"
$dashboardOk = Wait-Reachable -Url "http://localhost:$DashboardPort/" -TimeoutSeconds 30 -ServiceName "Dashboard"

# --- Summary table: Service | Port | URL | PID | Status ---
$rows = [System.Collections.Generic.List[PSCustomObject]]::new()
$rows.Add([PSCustomObject]@{
    Service = "API Gateway"
    Port    = $GatewayPort
    URL     = "http://localhost:$GatewayPort/"
    PID     = $gatewayProc.Id
    Status  = if ($gatewayOk)  { "HEALTHY" } else { "UNHEALTHY" }
})
$rows.Add([PSCustomObject]@{
    Service = "Dashboard"
    Port    = $DashboardPort
    URL     = "http://localhost:$DashboardPort/"
    PID     = $dashboardProc.Id
    Status  = if ($dashboardOk) { "HEALTHY" } else { "UNHEALTHY" }
})

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LAUNCH SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$table = $rows | Format-Table -AutoSize | Out-String
Write-Host $table
Write-Log "Launch summary:`n$table"

if (-not $gatewayOk -or -not $dashboardOk) {
    $warn = "WARNING: One or more services did not become healthy. Check logs in $env:TEMP"
    Write-Host $warn -ForegroundColor Yellow
    Write-Log $warn "WARN"
}

Write-Host ""
Write-Host "Press Ctrl+C to stop all services." -ForegroundColor Yellow

# --- Graceful shutdown on Ctrl+C ---
$stopRequested = $false
$cancelHandler = [System.ConsoleCancelEventHandler]{
    param($sender, $event)
    $event.Cancel = $true
    $stopRequested = $true
    Write-Host "`nCtrl+C received. Shutting down services..." -ForegroundColor Yellow
    Write-Log "Ctrl+C received. Shutting down."
}
[System.Console]::CancelKeyPress.Add($cancelHandler)

try {
    while (-not $stopRequested) {
        Start-Sleep -Seconds 2
        # Exit if both processes exited on their own
        if ($gatewayProc.HasExited -and $dashboardProc.HasExited) {
            Write-Host "Both services have exited." -ForegroundColor Yellow
            break
        }
    }
}
finally {
    [System.Console]::CancelKeyPress.Remove($cancelHandler)

    # Remove PID file on clean shutdown
    if (Test-Path -LiteralPath $PidFile) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue | Out-Null
    }

    Write-Host "Stopping child processes..." -ForegroundColor Yellow
    Write-Log "Stopping gateway PID $($gatewayProc.Id), dashboard PID $($dashboardProc.Id)"

    foreach ($proc in @($gatewayProc, $dashboardProc)) {
        try {
            if (-not $proc.HasExited) {
                $proc.Kill()
                $proc.WaitForExit(5000) | Out-Null
            }
        } catch {
            Write-Log "Failed to stop PID $($proc.Id): $_" "WARN"
        }
    }

    Pop-Location | Out-Null
    Write-Host "All services stopped." -ForegroundColor Cyan
    Write-Log "Launcher stopped."
}