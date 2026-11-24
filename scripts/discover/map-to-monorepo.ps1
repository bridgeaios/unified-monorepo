#!/usr/bin/env pwsh
# =============================================================================
# map-to-monorepo.ps1
#
# Maps discovered system components (system-discovery.json) into the unified
# monorepo layout, cross-referenced against consolidated-inventory.json when
# available.
#
#   Windows service with a path into a project directory  -> services/<name>
#   IIS site                                              -> port mapping + proxy route
#   Docker container                                      -> infrastructure/docker/<name>
#   Installed program with InstallLocation + manifest     -> inventory entry
#
# Output: E:\AOE\unified-monorepo\docs\system-to-monorepo-mapping.json
# =============================================================================

param(
    [string]$DiscoveryJson = "",
    [string]$InventoryJson = "",
    [string]$OutputJson    = ""
)

$ErrorActionPreference = "Continue"

$scriptDir    = $PSScriptRoot
$monorepoRoot = Resolve-Path (Join-Path $scriptDir "..\..")
$docsDir      = Join-Path $monorepoRoot "docs"

if ([string]::IsNullOrWhiteSpace($DiscoveryJson)) { $DiscoveryJson = Join-Path $docsDir "system-discovery.json" }
if ([string]::IsNullOrWhiteSpace($InventoryJson))   { $InventoryJson   = Join-Path $docsDir "consolidated-inventory.json" }
if ([string]::IsNullOrWhiteSpace($OutputJson))      { $OutputJson      = Join-Path $docsDir "system-to-monorepo-mapping.json" }

if (-not (Test-Path -LiteralPath $DiscoveryJson)) {
    Write-Host "ERROR: Discovery file not found: $DiscoveryJson" -ForegroundColor Red
    Write-Host "Run system-discovery.ps1 first." -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-SafeString {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return $s
}

function Truncate {
    param([string]$s, [int]$len = 40)
    if ([string]::IsNullOrEmpty($s)) { return "" }
    if ($s.Length -gt $len) { return $s.Substring(0, $len - 3) + "..." }
    return $s
}

function Get-KebabName {
    param([string]$name)
    $name -replace '[^a-z0-9]', '-' -replace '-+', '-' -trim('-') |
        ForEach-Object { $_.ToLower() }
}

# Manifests that mark a directory as a migratable project.
$manifestFilters = @(
    'package.json','*.csproj','*.vbproj','*.fsproj','*.sln',
    'requirements.txt','setup.py','pyproject.toml',
    'go.mod','Cargo.toml','composer.json','pom.xml','build.gradle'
)

function Test-ProjectDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container -ErrorAction SilentlyContinue)) { return $false }
    foreach ($f in $manifestFilters) {
        if (Get-ChildItem -LiteralPath $Path -Filter $f -File -ErrorAction SilentlyContinue | Select-Object -First 1) {
            return $true
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Load inputs
# ---------------------------------------------------------------------------
$discovery = Get-Content -LiteralPath $DiscoveryJson -Raw -ErrorAction Stop | ConvertFrom-Json

$inventory = $null
$inventoryExists = Test-Path -LiteralPath $InventoryJson
if ($inventoryExists) {
    try {
        $inventory = Get-Content -LiteralPath $InventoryJson -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        $inventory = $null
        Write-Warning "Could not read inventory file: $_"
    }
}

$entries = [System.Collections.Generic.List[object]]::new()
$inventoryAdditions = [System.Collections.Generic.List[object]]::new()
$stats = @{
    servicesSuggested     = 0
    iisRoutesSuggested    = 0
    dockerInfraSuggested  = 0
    inventoryAdded        = 0
}

Write-Host "=== SYSTEM-TO-MONOREPO MAPPING ===" -ForegroundColor Cyan
Write-Host ("Discovery : {0}" -f $DiscoveryJson) -ForegroundColor Gray
Write-Host ("Inventory : {0} (exists={1})" -f $InventoryJson, $inventoryExists) -ForegroundColor Gray
Write-Host ""

# =============================================================================
# Windows services -> services/<name>
#   (service whose binary path points into a project directory)
# =============================================================================
foreach ($s in @($discovery.services)) {
    $path = Get-SafeString $s.PathName
    if ([string]::IsNullOrWhiteSpace($path)) { continue }

    # Executable is the first whitespace-delimited token, quotes stripped.
    $exe  = ($path -split '\s+')[0].Trim('"').Trim("'")
    $dir  = Split-Path -Parent $exe -ErrorAction SilentlyContinue
    if (-not (Test-ProjectDirectory $dir)) { continue }

    $name     = Get-SafeString $s.Name
    $suggest  = if ([string]::IsNullOrWhiteSpace($name)) { "service" } else { (Get-KebabName $name) }
    $location = Join-Path "services" $suggest
    $mapped   = "suggested service"

    $entries.Add([PSCustomObject]@{
        SystemComponent = $name
        Type            = "Windows Service"
        PathPort        = $path
        MappedTo        = $mapped
        MonorepoLocation= $location
        Suggestion      = "Executable '$exe' lives in project directory '$dir'; migrate as a monorepo service."
        StartType       = Get-SafeString $s.StartType
        Status          = Get-SafeString $s.Status
    })
    $stats["servicesSuggested"]++
}

# =============================================================================
# IIS sites -> port mapping + proxy route
#   (proxy routes are registered in apps/api-gateway/index.js per inventory doc)
# =============================================================================
foreach ($site in @($discovery.iisSites)) {
    $name   = Get-SafeString $site.Name
    $port   = Get-SafeString $site.Port
    $phys   = Get-SafeString $site.PhysicalPath
    $bind   = Get-SafeString $site.Bindings

    $routeName = if ([string]::IsNullOrWhiteSpace($name)) { "site" } else { (Get-KebabName $name) }
    $location  = Join-Path "apps/api-gateway/index.js" ("proxy route: " + $routeName)
    $mapped    = "proxy route"

    $pathPortDisplay = if ($port) { "http://localhost:$port" } else { $phys }

    $entries.Add([PSCustomObject]@{
        SystemComponent = $name
        Type            = "IIS Site"
        PathPort        = $pathPortDisplay
        MappedTo        = $mapped
        MonorepoLocation= $location
        Suggestion      = "Bind IIS site '$name' ($bind) to a monorepo proxy route; physical path '$phys'."
        Port            = $port
        PhysicalPath    = $phys
        Bindings        = $bind
    })
    $stats["iisRoutesSuggested"]++
}

# =============================================================================
# Docker containers -> infrastructure/docker/<name>
# =============================================================================
foreach ($c in @($discovery.dockerContainers)) {
    $name   = Get-SafeString $c.Names
    $image  = Get-SafeString $c.Image
    $ports  = Get-SafeString $c.Ports
    $status = Get-SafeString $c.Status
    $cid    = Get-SafeString $c.Id

    $suggest = if ([string]::IsNullOrWhiteSpace($name)) { (Get-KebabName $cid) } else { (Get-KebabName $name) }
    $location = Join-Path "infrastructure/docker" $suggest
    $mapped   = "infrastructure service"

    $entries.Add([PSCustomObject]@{
        SystemComponent = if ($name) { $name } else { $cid }
        Type            = "Docker Container"
        PathPort        = if ($ports) { $ports } else { $image }
        MappedTo        = $mapped
        MonorepoLocation= $location
        Suggestion      = "Container '$name' (image $image, status $status) as an infrastructure service."
        ContainerId     = $cid
        Image           = $image
        Status          = $status
        Ports           = $ports
    })
    $stats["dockerInfraSuggested"]++
}

# =============================================================================
# Installed programs with InstallLocation containing a manifest -> inventory
# =============================================================================
foreach ($p in @($discovery.installedPrograms)) {
    $name     = Get-SafeString $p.DisplayName
    $loc      = Get-SafeString $p.InstallLocation
    $version  = Get-SafeString $p.DisplayVersion
    $publisher= Get-SafeString $p.Publisher

    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    if (-not (Test-ProjectDirectory $loc)) { continue }

    $suggest  = (Get-KebabName $name)
    $location = Join-Path "services" $suggest

    $entries.Add([PSCustomObject]@{
        SystemComponent = $name
        Type            = "Installed Program"
        PathPort        = $loc
        MappedTo        = "inventory entry"
        MonorepoLocation= $location
        Suggestion      = "Installed program '$name' v$version ($publisher) has a manifest at '$loc'; register in inventory."
        Version         = $version
        Publisher       = $publisher
    })
    $inventoryAdditions.Add([PSCustomObject]@{
        DisplayName       = $name
        DisplayVersion    = $version
        InstallLocation   = $loc
        Publisher         = $publisher
        SuggestedName     = $suggest
        MonorepoLocation  = $location
    })
    $stats["inventoryAdded"]++
}

# Optionally merge inventory additions into consolidated-inventory.json
# (non-destructive: only adds / overwrites a new top-level key).
if ($inventoryExists -and $inventoryAdditions.Count -gt 0) {
    try {
        if ($null -eq $inventory) { $inventory = [PSCustomObject]@{} }
        $inventory | Add-Member -MemberType NoteProperty -Name "systemDiscoveredPrograms" -Value $inventoryAdditions.ToArray() -Force
        $inventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $InventoryJson -Encoding UTF8
        Write-Host ("  Merged {0} discovered programs into {1}" -f $inventoryAdditions.Count, $InventoryJson) -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not update inventory file: $_"
    }
}
elseif ($inventoryAdditions.Count -gt 0) {
    Write-Host ("  Inventory file not found; {0} discoveries recorded in mapping output only." -f $inventoryAdditions.Count) -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Write output JSON
# ---------------------------------------------------------------------------
$mapping = [PSCustomObject]@{
    generatedAt       = (Get-Date).ToString("o")
    generator         = "map-to-monorepo.ps1"
    sourceDiscovery   = $DiscoveryJson
    sourceInventory   = $InventoryJson
    sourceInventoryExists = $inventoryExists
    entries           = $entries.ToArray()
    inventoryAdditions= $inventoryAdditions.ToArray()
    summary           = [PSCustomObject]@{
        servicesSuggested     = $stats["servicesSuggested"]
        iisRoutesSuggested    = $stats["iisRoutesSuggested"]
        dockerInfraSuggested  = $stats["dockerInfraSuggested"]
        inventoryAdded        = $stats["inventoryAdded"]
        totalMappings         = $entries.Count
    }
}

if (-not (Test-Path -LiteralPath $docsDir)) { New-Item -ItemType Directory -LiteralPath $docsDir -Force | Out-Null }
$mapping | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputJson -Encoding UTF8

# ---------------------------------------------------------------------------
# Print summary + mapping table
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== MAPPING SUMMARY ===" -ForegroundColor Cyan
Write-Host ("{0,-26} : {1}" -f "Windows services suggested", $stats["servicesSuggested"])
Write-Host ("{0,-26} : {1}" -f "IIS proxy routes suggested", $stats["iisRoutesSuggested"])
Write-Host ("{0,-26} : {1}" -f "Docker infra services suggested", $stats["dockerInfraSuggested"])
Write-Host ("{0,-26} : {1}" -f "Inventory additions", $stats["inventoryAdded"])
Write-Host ("{0,-26} : {1}" -f "Total mappings", $entries.Count)
Write-Host ("Output    : {0}" -f $OutputJson) -ForegroundColor Green

Write-Host ""
Write-Host "=== SYSTEM COMPONENT | TYPE | PATH/PORT | MAPPED TO | MONOREPO LOCATION ===" -ForegroundColor Cyan
$sep = "-" * 132
Write-Host $sep -ForegroundColor Gray
Write-Host ("{0,-34} | {1,-16} | {2,-28} | {3,-20} | {4}" -f "System Component","Type","Path/Port","Mapped To","Monorepo Location") -ForegroundColor Gray
Write-Host $sep -ForegroundColor Gray
foreach ($e in $entries) {
    Write-Host ("{0,-34} | {1,-16} | {2,-28} | {3,-20} | {4}" -f
        (Truncate (Get-SafeString $e.SystemComponent) 34),
        (Truncate (Get-SafeString $e.Type) 16),
        (Truncate (Get-SafeString $e.PathPort) 28),
        (Truncate (Get-SafeString $e.MappedTo) 20),
        (Truncate (Get-SafeString $e.MonorepoLocation) 60))
}
Write-Host $sep -ForegroundColor Gray
Write-Host "MAPPING COMPLETE" -ForegroundColor Cyan
