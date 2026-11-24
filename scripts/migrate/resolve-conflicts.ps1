#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Detect and resolve port + dependency conflicts across migrated services.
# Reads docs/conflict-report.json (from conflict-check.ps1), suggests fixes,
# updates apps/api-gateway/services.json with new ports, and writes
# docs/conflict-resolution-report.json.
#
# Parameters:
#   -ConflictReport  Path to conflict-report.json (default: docs/conflict-report.json)
#   -ServicesJson    Path to the gateway services registry
#   -MonoRepoRoot    Monorepo root (default: auto-resolved)
#   -AutoAssign      Automatically assign new ports without prompting
#   -Interactive     Prompt for each conflict (default)
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$ConflictReport,
    [string]$ServicesJson,
    [string]$MonoRepoRoot,
    [switch]$AutoAssign,
    [switch]$Interactive
)

$ErrorActionPreference = "Continue"

if (-not $PSBoundParameters.ContainsKey('MonoRepoRoot')) {
    $MonoRepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
}
if (-not $PSBoundParameters.ContainsKey('ConflictReport')) {
    $ConflictReport = Join-Path $MonoRepoRoot "docs\conflict-report.json"
}
if (-not $PSBoundParameters.ContainsKey('ServicesJson')) {
    $ServicesJson = Join-Path $MonoRepoRoot "apps\api-gateway\services.json"
}

if (-not $Interactive -and -not $AutoAssign) {
    $Interactive = $true
}

# ---- Load conflict report -------------------------------------------------
if (-not (Test-Path -LiteralPath $ConflictReport -PathType Leaf)) {
    Write-Host "No conflict report found at $ConflictReport - nothing to resolve." -ForegroundColor Yellow
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ConflictReport) | Out-Null
    $emptyReport = [ordered]@{
    portCollisions       = @()
    dependencyConflicts  = @()
    generatedAt          = (Get-Date -Format o)
}
$emptyReport |
        ConvertTo-Json -Depth 5 | Set-Content -Path $ConflictReport -Encoding UTF8
    exit 0
}

$report = Get-Content -Raw -LiteralPath $ConflictReport | ConvertFrom-Json -ErrorAction Stop
$portCollisions   = @($report.portCollisions)
$dependencyConflicts = @($report.dependencyConflicts)

# ---- Load services registry -----------------------------------------------
function Load-ServicesJson {
    if (-not (Test-Path -LiteralPath $ServicesJson -PathType Leaf)) {
        return @{ services = @() }
    }
    try {
        $raw = Get-Content -Raw -LiteralPath $ServicesJson -ErrorAction Stop
        $parsed = ConvertFrom-Json $raw -ErrorAction Stop
        if (-not $parsed.PSObject.Properties.Name -contains 'services') {
            return @{ services = @() }
        }
        return $parsed
    } catch {
        Write-Warning "Failed to read services.json: $_"
        return @{ services = @() }
    }
}

function Save-ServicesJson {
    param([object]$Registry)
    $dir = Split-Path -Parent $ServicesJson
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $Registry | ConvertTo-Json -Depth 5 | Set-Content -Path $ServicesJson -Encoding UTF8
}

$services = Load-ServicesJson
$resolutionActions = New-Object System.Collections.Generic.List[pscustomobject]

# ---- Resolve port collisions -----------------------------------------------
foreach ($collision in $portCollisions) {
    $port   = [int]$collision.port
    $svcNames = @($collision.services)

    Write-Host ("[PORT COLLISION] Port {0} used by: {1}" -f $port, ($svcNames -join ', ')) -ForegroundColor Yellow

    $resolved = @()
    foreach ($name in $svcNames) {
        $svc = $services.services | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if (-not $svc) {
            Write-Warning "Service '$name' not found in registry, skipping."
            continue
        }

        $newPort = $null
        if ($AutoAssign) {
            $newPort = & (Join-Path $PSScriptRoot "port-allocator.ps1") -MonoRepoRoot $MonoRepoRoot -List 2>$null
            # Re-derive: call Get-NextAvailablePort via dot-sourcing is complex; use inline logic
            $registry = @{ ports = @($services.services | ForEach-Object { [pscustomobject]@{ Port = $_.port; ServiceName = $_.name } }) }
            # Simple scan
            $used = @($services.services.port) + @(3000, 4000)
            for ($p = 4001; $p -le 4999; $p++) {
                if ($used -notcontains $p) { $newPort = $p; break }
            }
        } elseif ($Interactive) {
            $prompt = "Assign new port for '$name' (current: $($svc.port)) or press Enter to skip: "
            $input = Read-Host $prompt
            if ($input -match '^\d+$') { $newPort = [int]$input }
        }

        if ($newPort) {
            $oldPort = $svc.port
            $svc.port = $newPort
            if ($svc.url) {
                try {
                    $url = [uri]$svc.url
                    $svc.url = "$($url.Scheme)://$($url.Host):$newPort$($url.PathAndQuery)"
                } catch {
                    $svc.url = "http://localhost:$newPort"
                }
            }
            $resolutionActions.Add([pscustomobject]@{
                Service   = $name
                Type      = 'PortCollision'
                OldValue  = $oldPort
                NewValue  = $newPort
                Action    = 'Reassigned port'
                Status    = 'Resolved'
            })
            Write-Host ("  -> {0}: port {1} -> {2}" -f $name, $oldPort, $newPort) -ForegroundColor Green
        } else {
            $resolutionActions.Add([pscustomobject]@{
                Service   = $name
                Type      = 'PortCollision'
                OldValue  = $svc.port
                NewValue  = $null
                Action    = 'Skipped'
                Status    = 'Unresolved'
            })
            Write-Host ("  -> {0}: skipped" -f $name) -ForegroundColor Gray
        }
        $resolved += $name
    }
}

# ---- Resolve dependency conflicts ------------------------------------------
foreach ($dep in $dependencyConflicts) {
    $pkgName = $dep.package
    $versions = @($dep.versions)
    $svcNames = @($dep.services)

    Write-Host ("[DEP CONFLICT] {0} versions {1} across: {2}" -f $pkgName, ($versions -join ', '), ($svcNames -join ', ')) -ForegroundColor Yellow

    # Suggest highest version
    $sorted = ($versions | Sort-Object -Descending)
    $suggested = $sorted[0]

    $action = [pscustomobject]@{
        Package    = $pkgName
        Type       = 'DependencyConflict'
        Versions   = ($versions -join ', ')
        Suggested  = $suggested
        Services   = ($svcNames -join ', ')
        Action     = 'Review required'
        Status     = 'Unresolved'
    }

    if ($AutoAssign) {
        $action.Action = "Use shared version $suggested in packages/shared-types"
        $action.Status = 'Suggested'
        Write-Host ("  -> Suggest shared {0}@{1} in packages/shared-types" -f $pkgName, $suggested) -ForegroundColor Green
    } elseif ($Interactive) {
        $prompt = "Use shared version $suggested for $pkgName? (y/n): "
        $input = Read-Host $prompt
        if ($input -eq 'y') {
            $action.Action = "Use shared version $suggested in packages/shared-types"
            $action.Status = 'Resolved'
            Write-Host ("  -> Resolved: $pkgName@$suggested shared") -ForegroundColor Green
        }
    }

    $resolutionActions.Add($action)
}

# ---- Save services registry ------------------------------------------------
Save-ServicesJson $services

# ---- Write resolution report -----------------------------------------------
$resolutionReport = @{
    generatedAt       = (Get-Date -Format o)
    portCollisionsResolved   = ($resolutionActions | Where-Object { $_.Type -eq 'PortCollision' -and $_.Status -eq 'Resolved' }).Count
    portCollisionsUnresolved = ($resolutionActions | Where-Object { $_.Type -eq 'PortCollision' -and $_.Status -eq 'Unresolved' }).Count
    dependencyConflictsResolved = ($resolutionActions | Where-Object { $_.Type -eq 'DependencyConflict' -and $_.Status -eq 'Resolved' }).Count
    dependencyConflictsUnresolved = ($resolutionActions | Where-Object { $_.Type -eq 'DependencyConflict' -and $_.Status -eq 'Unresolved' }).Count
    actions = $resolutionActions
}
$resolutionPath = Join-Path $MonoRepoRoot "docs\conflict-resolution-report.json"
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolutionPath) | Out-Null
$resolutionReport | ConvertTo-Json -Depth 5 | Set-Content -Path $resolutionPath -Encoding UTF8

# ---- Summary ---------------------------------------------------------------
Write-Host "`n=== Conflict Resolution Summary ===" -ForegroundColor Cyan
Write-Host ("Port collisions resolved:   {0}" -f $resolutionReport.portCollisionsResolved) -ForegroundColor Green
Write-Host ("Port collisions unresolved: {0}" -f $resolutionReport.portCollisionsUnresolved) -ForegroundColor Red
Write-Host ("Dependency conflicts resolved: {0}" -f $resolutionReport.dependencyConflictsResolved) -ForegroundColor Green
Write-Host ("Dependency conflicts unresolved: {0}" -f $resolutionReport.dependencyConflictsUnresolved) -ForegroundColor Red
Write-Host ("Report written to: $resolutionPath")
Write-Host ("Services registry updated: $ServicesJson")

exit 0
