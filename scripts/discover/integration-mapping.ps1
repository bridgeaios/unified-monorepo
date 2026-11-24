#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Generate the integration plan from docs/categorized-inventory.json.
# Produces:
#   - docs/integration-mapping.json  (machine-readable)
#   - docs/INTEGRATION_PLAN.md       (human-readable plan)
#
# Parameters:
#   -CategorizedJson   Path to categorized-inventory.json (default: docs/categorized-inventory.json)
#   -OutputDir         Output directory (default: docs/)
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$CategorizedJson,
    [string]$OutputDir
)

$ErrorActionPreference = "Continue"

$scriptDir = $PSScriptRoot
$monoRoot  = Resolve-Path (Join-Path $scriptDir "..\..")

if (-not $PSBoundParameters.ContainsKey('CategorizedJson')) {
    $CategorizedJson = Join-Path $monoRoot "docs\categorized-inventory.json"
}
if (-not $PSBoundParameters.ContainsKey('OutputDir')) {
    $OutputDir = Join-Path $monoRoot "docs"
}

if (-not (Test-Path -LiteralPath $CategorizedJson -PathType Leaf)) {
    Write-Host "ERROR: Categorized inventory not found: $CategorizedJson" -ForegroundColor Red
    Write-Host "Run categorize-projects.ps1 first." -ForegroundColor Yellow
    exit 1
}

$raw = Get-Content -Raw -LiteralPath $CategorizedJson -ErrorAction Stop
$inventory = ConvertFrom-Json $raw -ErrorAction Stop
$projects = @($inventory.projects)

# ---- Build mapping entries -------------------------------------------------
$mappingEntries = @()
$gatewayRoutes  = @()
$dockerServices = @()
$sharedPackages = @('shared-types', 'api-client')

$port = 4001
foreach ($p in $projects) {
    $serviceName = if ($p.suggestedServiceName) { $p.suggestedServiceName } else { "project-$($p.name)" }
    $destPath    = if ($p.destination -eq 'services/') { "services/$serviceName" } elseif ($p.destination -eq 'apps/dashboard') { 'apps/dashboard' } elseif ($p.destination -eq 'apps/api-gateway') { 'apps/api-gateway' } else { $p.destination }

    # Guess health endpoint
    $healthGuess = '/health'
    if ($p.stack -eq 'Python') { $healthGuess = '/health' }
    if ($p.stack -eq 'Go') { $healthGuess = '/health' }
    if ($p.stack -eq 'Rust') { $healthGuess = '/health' }

    # Environment variables
    $envVars = @()
    if ($p.port) { $envVars += "PORT=$($p.port)" }
    if ($p.stack -eq 'Node.js') { $envVars += 'NODE_ENV=production' }
    if ($p.stack -eq 'Python') { $envVars += 'PYTHONUNBUFFERED=1' }

    $entry = [pscustomobject]@{
        project         = $p.name
        stack           = $p.stack
        category        = $p.category
        destination     = $destPath
        serviceName     = $serviceName
        port            = $p.port
        integrationMode = $p.integrationMode
        healthEndpoint  = $healthGuess
        envVars         = $envVars
        sharedPackages  = $sharedPackages
        gitRemote       = $p.gitRemote
    }
    $mappingEntries += $entry

    # Gateway proxy route (only for proxy/embed modes that expose HTTP)
    if ($p.integrationMode -in @('proxy', 'embed') -and $p.port) {
        $gatewayRoutes += [pscustomobject]@{
            route       = "/$serviceName"
            target      = "http://localhost:$($p.port)"
            service     = $serviceName
            pathRewrite = @{ ("^/$serviceName") = '' }
        }
    }

    # Docker compose entry (for containerized or all services)
    $dockerServices += [pscustomobject]@{
        service     = $serviceName
        stack       = $p.stack
        build       = "./infrastructure/docker/$serviceName"
        ports       = @("$($p.port):$($p.port)")
        environment = $envVars
        depends_on  = @('api-gateway')
        network     = 'unified-net'
        healthcheck = @{
            test     = @("CMD", "curl", "-f", "http://localhost:$($p.port)$healthGuess")
            interval = '30s'
            timeout  = '10s'
            retries  = 3
        }
    }
}

# ---- Write integration-mapping.json ----------------------------------------
$mapping = [pscustomobject]@{
    generated         = (Get-Date -Format o)
    generatedBy       = 'integration-mapping.ps1'
    source            = $CategorizedJson
    totalProjects     = $mappingEntries.Count
    gatewayRoutes     = $gatewayRoutes
    dockerServices    = $dockerServices
    sharedPackages    = $sharedPackages
    migrationOrder    = @('packages/* first', 'services/ (dependencies first)', 'apps/api-gateway', 'apps/dashboard')
    entries           = $mappingEntries
}

$mappingPath = Join-Path $OutputDir "integration-mapping.json"
if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
$mapping | ConvertTo-Json -Depth 6 | Set-Content -Path $mappingPath -Encoding UTF8

# ---- Write INTEGRATION_PLAN.md ---------------------------------------------
$mdPath = Join-Path $OutputDir "INTEGRATION_PLAN.md"
$lines = @()
$lines += "# Integration Plan - Unified Monorepo"
$lines += ""
$lines += "Generated: $($mapping.generated)"
$lines += "Source: $($mapping.source)"
$lines += "Total projects: $($mapping.totalProjects)"
$lines += ""
$lines += "## Migration Order"
$lines += "1. Build shared packages first (`packages/shared-types`, `packages/api-client`)"
$lines += "2. Migrate services into `services/` (dependencies first, then dependents)"
$lines += "3. Build and register the API Gateway (`apps/api-gateway`)"
$lines += "4. Build and launch the Dashboard (`apps/dashboard`)"
$lines += ""
$lines += "## API Gateway Routes"
$lines += ""
$lines += "| Route | Target | Service |"
$lines += "|-------|--------|---------|"
foreach ($r in $gatewayRoutes) {
    $lines += "| $($r.route) | $($r.target) | $($r.service) |"
}
$lines += ""
$lines += "## Docker Compose Services"
$lines += ""
$lines += "| Service | Stack | Port | Build Context |"
$lines += "|---------|-------|------|---------------|"
foreach ($d in $dockerServices) {
    $lines += "| $($d.service) | $($d.stack) | $($d.port) | $($d.build) |"
}
$lines += ""
$lines += "## Shared Packages to Consume"
$lines += ""
foreach ($pkg in $sharedPackages) {
    $lines += "- @unified/$pkg"
}
$lines += ""
$lines += "## Project Mapping Table"
$lines += ""
$lines += "| Project | Stack | Category | Destination | Port | Mode | Health |"
$lines += "|---------|-------|----------|-------------|------|------|--------|"
foreach ($e in $mappingEntries) {
    $lines += "| $($e.project) | $($e.stack) | $($e.category) | $($e.destination) | $($e.port) | $($e.integrationMode) | $($e.healthEndpoint) |"
}
$lines += ""
$lines += "## Environment Variables"
$lines += ""
foreach ($e in $mappingEntries) {
    if ($e.envVars.Count -gt 0) {
        $lines += "### $($e.serviceName)"
        foreach ($env in $e.envVars) { $lines += "- $env" }
        $lines += ""
    }
}
$lines += "## Related Docs"
$lines += "- `docs/API_REFERENCE.md` - gateway endpoints"
$lines += "- `docs/RUNBOOK.md` - operations runbook"
$lines += "- `docs/ARCHITECTURE.md` - system design"
$lines += "- `docs/MERGED_PROJECTS.md` - migration tracking"
$lines += ""

$lines | Set-Content -Path $mdPath -Encoding UTF8

# ---- Print summary ---------------------------------------------------------
Write-Host "`n=== Integration Plan ===" -ForegroundColor Cyan
Write-Host ("Total projects: {0}" -f $mapping.totalProjects)
Write-Host ("Gateway routes: {0}" -f $gatewayRoutes.Count)
Write-Host ("Docker services: {0}" -f $dockerServices.Count)
Write-Host ("Shared packages: {0}" -f ($sharedPackages -join ', '))
Write-Host ""
Write-Host ("Mapping JSON: $mappingPath")
Write-Host ("Plan markdown: $mdPath")

exit 0
