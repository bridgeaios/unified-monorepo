#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Detect orphaned services: registry entries without a services/ directory,
# and services/ directories not registered in the gateway.
#
# Parameters:
#   -ServicesJson    Path to the gateway services registry (default: apps/api-gateway/services.json)
#   -MonoRepoRoot    Monorepo root (default: auto-resolved)
#   -Clean           Automatically remove orphaned registry entries
#   -Register        Automatically register unregistered services (guesses URL from port)
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$ServicesJson,
    [string]$MonoRepoRoot,
    [switch]$Clean,
    [switch]$Register
)

$ErrorActionPreference = "Continue"

if (-not $PSBoundParameters.ContainsKey('MonoRepoRoot')) {
    $MonoRepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
}
if (-not $PSBoundParameters.ContainsKey('ServicesJson')) {
    $ServicesJson = Join-Path $MonoRepoRoot "apps\api-gateway\services.json"
}

$servicesDir = Join-Path $MonoRepoRoot "services"

# ---- Load registry --------------------------------------------------------
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

$registry = Load-ServicesJson
$svcNamesInRegistry = @($registry.services | ForEach-Object { $_.name })

# ---- Discover services on disk --------------------------------------------
$svcDirsOnDisk = @()
if (Test-Path -LiteralPath $servicesDir -PathType Container) {
    $svcDirsOnDisk = @(Get-ChildItem -LiteralPath $servicesDir -Directory | ForEach-Object { $_.Name })
}

# ---- Orphaned registry entries (in registry but no directory) -------------
$orphaned = @($registry.services | Where-Object { $svcDirsOnDisk -notcontains $_.name })

# ---- Unregistered services (on disk but not in registry) ------------------
$unregistered = @($svcDirsOnDisk | Where-Object { $svcNamesInRegistry -notcontains $_ })

# ---- Report ---------------------------------------------------------------
Write-Host "`n=== Orphaned Service Detection ===" -ForegroundColor Cyan
Write-Host ("Services in registry: {0}" -f $svcNamesInRegistry.Count)
Write-Host ("Services on disk:     {0}" -f $svcDirsOnDisk.Count)

if ($orphaned.Count -gt 0) {
    Write-Host "`n[ORPHANED REGISTRY ENTRIES] (in services.json but no services/ directory)" -ForegroundColor Yellow
    $orphaned | Format-Table @{ Name='Service'; Expression={$_.name} },
                              @{ Name='URL'; Expression={$_.url} },
                              @{ Name='Port'; Expression={$_.port} } -AutoSize
} else {
    Write-Host "`nNo orphaned registry entries." -ForegroundColor Green
}

if ($unregistered.Count -gt 0) {
    Write-Host "`n[UNREGISTERED SERVICES] (on disk but not in services.json)" -ForegroundColor Yellow
    $unregistered | Format-Table @{ Name='Service'; Expression={$_} } -AutoSize
} else {
    Write-Host "`nNo unregistered services." -ForegroundColor Green
}

# ---- Clean: remove orphaned registry entries ------------------------------
if ($Clean -and $orphaned.Count -gt 0) {
    foreach ($o in $orphaned) {
        $registry.services = @($registry.services | Where-Object { $_.name -ne $o.name })
        Write-Host ("Removed orphaned registry entry: {0}" -f $o.name) -ForegroundColor Green
    }
    Save-ServicesJson $registry
    Write-Host ("services.json updated ({0} entries removed)" -f $orphaned.Count) -ForegroundColor Cyan
}

# ---- Register: add unregistered services ----------------------------------
if ($Register -and $unregistered.Count -gt 0) {
    $migrateProject = Join-Path $PSScriptRoot "..\..\discover\analyze-inventory.ps1"
    foreach ($name in $unregistered) {
        $dir = Join-Path $servicesDir $name
        # Guess port from MIGRATION.md or package.json
        $port = $null
        $migrationMd = Join-Path $dir "MIGRATION.md"
        if (Test-Path -LiteralPath $migrationMd -PathType Leaf) {
            $content = Get-Content -Raw -LiteralPath $migrationMd -ErrorAction SilentlyContinue
            if ($content -match 'port.*?(\d+)') { $port = [int]$Matches[1] }
        }
        if (-not $port) {
            $pkg = Join-Path $dir "package.json"
            if (Test-Path -LiteralPath $pkg -PathType Leaf) {
                try {
                    $pj = Get-Content -Raw -LiteralPath $pkg | ConvertFrom-Json
                    $port = $pj.port
                } catch {}
            }
        }
        if (-not $port) { $port = 4001 }
        $url = "http://localhost:$port"

        $registry.services += [pscustomobject]@{
            name       = $name
            url        = $url
            stack      = $null
            category   = $null
            port       = $port
            registeredAt = (Get-Date -Format o)
        }
        Write-Host ("Registered unregistered service: {0} -> {1}" -f $name, $url) -ForegroundColor Green
    }
    Save-ServicesJson $registry
    Write-Host ("services.json updated ({0} entries added)" -f $unregistered.Count) -ForegroundColor Cyan
}

# ---- Write orphan report --------------------------------------------------
$report = @{
    generatedAt       = (Get-Date -Format o)
    orphanedRegistry  = @($orphaned | ForEach-Object { @{ name = $_.name; url = $_.url; port = $_.port } })
    unregisteredOnDisk = @($unregistered)
}
$reportPath = Join-Path $MonoRepoRoot "docs\orphan-report.json"
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $reportPath) | Out-Null
$report | ConvertTo-Json -Depth 5 | Set-Content -Path $reportPath -Encoding UTF8
Write-Host ("Orphan report written to: $reportPath")

exit 0
