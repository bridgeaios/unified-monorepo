#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Health-check all services registered with the API gateway.
# Reads services from http://localhost:4000/services, polls each /health
# endpoint, and prints a status table. Exits 0 if all healthy, 1 otherwise.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$GatewayUrl = 'http://localhost:4000',
    [int]$TimeoutMs = 5000
)

$ErrorActionPreference = "Continue"

function Invoke-HealthCheck {
    param([string]$Url, [int]$TimeoutMs)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-RestMethod -Uri "$Url/health" -Method Get `
            -TimeoutMilliseconds $TimeoutMs -ErrorAction Stop
        $stopwatch.Stop()
        return [pscustomobject]@{
            Status       = 'healthy'
            ResponseTime = $stopwatch.ElapsedMilliseconds
            Details      = $response
            Error        = $null
        }
    } catch {
        $stopwatch.Stop()
        return [pscustomobject]@{
            Status       = 'unhealthy'
            ResponseTime = $stopwatch.ElapsedMilliseconds
            Details      = $null
            Error        = $_.Exception.Message
        }
    }
}

# ---- Fetch services from gateway -----------------------------------------
$services = @()
try {
    $registry = Invoke-RestMethod -Uri "$GatewayUrl/services" -Method Get `
        -TimeoutMilliseconds $TimeoutMs -ErrorAction Stop
    $services = @($registry.services)
} catch {
    Write-Host ("ERROR: Cannot reach gateway at {0}/services" -f $GatewayUrl) -ForegroundColor Red
    Write-Host ("  {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host "Is the API gateway running? Start it with: pwsh ./scripts/launch/launch-all.ps1" -ForegroundColor Yellow
    exit 1
}

if ($services.Count -eq 0) {
    Write-Host "No services registered with the gateway." -ForegroundColor Yellow
    exit 0
}

# ---- Check each service ---------------------------------------------------
$results = New-Object System.Collections.Generic.List[pscustomobject]
foreach ($svc in $services) {
    $name   = $svc.name
    $url    = $svc.url
    $healthUrl = "$url/health"

    $result = Invoke-HealthCheck -Url $url -TimeoutMs $TimeoutMs

    $results.Add([pscustomobject]@{
        Service       = $name
        URL           = $url
        Status        = $result.Status
        ResponseTime  = "{0} ms" -f $result.ResponseTime
        LastChecked   = (Get-Date -Format o)
        Error         = $result.Error
    })

    $color = if ($result.Status -eq 'healthy') { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1} -> {2} ({3} ms)" -f $result.Status.ToUpper(), $name, $url, $result.ResponseTime) -ForegroundColor $color
    if ($result.Error) {
        Write-Host ("      Error: {0}" -f $result.Error) -ForegroundColor Gray
    }
}

# ---- Summary --------------------------------------------------------------
$healthy  = ($results | Where-Object { $_.Status -eq 'healthy' }).Count
$unhealthy = ($results | Where-Object { $_.Status -eq 'unhealthy' }).Count

Write-Host "`n=== Health Check Summary ===" -ForegroundColor Cyan
Write-Host ("Total:   {0}" -f $results.Count)
Write-Host ("Healthy: {0}" -f $healthy) -ForegroundColor Green
Write-Host ("Unhealthy: {0}" -f $unhealthy) -ForegroundColor Red

if ($unhealthy -gt 0) {
    Write-Host "`nSome services are unhealthy. Check logs and dependencies." -ForegroundColor Yellow
    exit 1
}

Write-Host "`nAll services are healthy." -ForegroundColor Green
exit 0
