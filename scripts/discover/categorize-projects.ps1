#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Categorize discovered projects into stacks, categories, and monorepo
# destinations. Reads docs/consolidated-inventory.json and writes
# docs/categorized-inventory.json.
#
# Parameters:
#   -InventoryJson   Path to consolidated-inventory.json (default: docs/consolidated-inventory.json)
#   -OutputJson      Path to write categorized-inventory.json (default: docs/categorized-inventory.json)
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$InventoryJson,
    [string]$OutputJson
)

$ErrorActionPreference = "Continue"

# ---- Resolve paths relative to script location -----------------------------
$scriptDir = $PSScriptRoot
$monoRoot  = Resolve-Path (Join-Path $scriptDir "..\..")

if (-not $PSBoundParameters.ContainsKey('InventoryJson')) {
    $InventoryJson = Join-Path $monoRoot "docs\consolidated-inventory.json"
}
if (-not $PSBoundParameters.ContainsKey('OutputJson')) {
    $OutputJson = Join-Path $monoRoot "docs\categorized-inventory.json"
}

# ---- Load inventory --------------------------------------------------------
if (-not (Test-Path -LiteralPath $InventoryJson -PathType Leaf)) {
    Write-Host "ERROR: Inventory not found: $InventoryJson" -ForegroundColor Red
    Write-Host "Run consolidate-inventory.ps1 first." -ForegroundColor Yellow
    exit 1
}

$raw = Get-Content -Raw -LiteralPath $InventoryJson -ErrorAction Stop
$inventory = ConvertFrom-Json $raw -ErrorAction Stop

$projects = @()
if ($inventory.PSObject.Properties.Name -contains 'projects') {
    $projects = @($inventory.projects)
} elseif ($inventory -is [array]) {
    $projects = @($inventory)
} else {
    $projects = @($inventory)
}

if ($projects.Count -eq 0) {
    Write-Host "No projects to categorize." -ForegroundColor Yellow
    exit 0
}

# ---- Stack detection from markers ------------------------------------------
function Detect-Stack {
    param([array]$Markers)
    $markerList = @($Markers | ForEach-Object { $_.ToString() })
    $text = ($markerList -join ' ').ToLower()

    if ($text -match 'next\.config|vite\.config|angular\.json|svelte\.config|astro\.config') { return 'Frontend (Node.js)' }
    if ($markerList -contains 'package.json') { return 'Node.js' }
    if ($markerList -contains 'requirements.txt' -or $markerList -contains 'pyproject.toml' -or $markerList -contains 'manage.py') { return 'Python' }
    if ($markerList -contains 'Cargo.toml') { return 'Rust' }
    if ($markerList -contains 'go.mod') { return 'Go' }
    if ($markerList -contains 'pom.xml' -or $markerList -contains 'build.gradle' -or $markerList -contains 'build.gradle.kts') { return 'Java' }
    if ($markerList -contains '*.csproj' -or $markerList -contains '*.sln') { return '.NET' }
    if ($markerList -contains 'composer.json') { return 'PHP' }
    if ($markerList -contains 'Gemfile') { return 'Ruby' }
    if ($markerList -contains 'mix.exs') { return 'Elixir' }
    if ($markerList -contains 'pubspec.yaml') { return 'Dart/Flutter' }
    if ($markerList -contains 'Dockerfile' -or $markerList -contains 'docker-compose.yml') { return 'Docker' }
    return 'Unknown'
}

function Detect-Category {
    param([string]$Stack, [array]$Markers)
    $markerList = @($Markers | ForEach-Object { $_.ToString() })
    $text = ($markerList -join ' ').ToLower()

    if ($Stack -like 'Frontend*') { return 'Frontend' }
    if ($text -match 'next\.config|vite\.config|angular\.json') { return 'Frontend' }
    if ($Stack -eq 'Docker') { return 'Container / Infrastructure' }
    if ($Stack -eq 'Rust') { return 'Worker / AI' }
    if ($Stack -eq 'Python' -and ($text -match 'django|flask|fastapi')) { return 'Backend / Service' }
    if ($Stack -eq 'Node.js') { return 'Backend / Service' }
    if ($Stack -eq 'Go') { return 'Backend / Service' }
    if ($Stack -eq 'Java') { return 'Backend / Service' }
    if ($Stack -eq '.NET') { return 'Backend / Service' }
    if ($text -match 'turbo\.json|nx\.json|pnpm-workspace\.yaml|lerna\.json') { return 'Existing Monorepo' }
    return 'Library / Other'
}

function Detect-Destination {
    param([string]$Category, [string]$Stack)
    switch ($Category) {
        'Frontend' { return 'apps/dashboard' }
        'Backend / Service' { return 'services/' }
        'Existing Monorepo' { return 'services/ (sub-monorepo)' }
        'Container / Infrastructure' { return 'infrastructure/docker/' }
        'Worker / AI' { return 'services/' }
        'Library / Other' { return 'packages/' }
        default { return 'services/' }
    }
}

function Suggest-Port {
    param([string]$Category)
    switch ($Category) {
        'Frontend' { return 3000 }
        'Backend / Service' { return $null } # assigned 4001+
        'Existing Monorepo' { return $null }
        'Container / Infrastructure' { return $null }
        'Worker / AI' { return $null }
        'Library / Other' { return $null }
        default { return $null }
    }
}

function Detect-IntegrationMode {
    param([string]$Category, [string]$Stack)
    switch ($Category) {
        'Frontend' { return 'embed' }
        'Backend / Service' { return 'proxy' }
        'Existing Monorepo' { return 'link' }
        'Container / Infrastructure' { return 'container' }
        'Worker / AI' { return 'container' }
        'Library / Other' { return 'embed' }
        default { return 'proxy' }
    }
}

# ---- Next available port for migrated services -----------------------------
$nextPort = 4001
$usedPorts = @($projects | Where-Object { $_.port } | ForEach-Object { [int]$_.port })

function Get-NextPort {
    while ($usedPorts -contains $nextPort) { $nextPort++ }
    $p = $nextPort
    $nextPort++
    return $p
}

# ---- Categorize each project -----------------------------------------------
$categorized = @()
foreach ($p in $projects) {
    $name        = $p.name
    $fullPath    = $p.fullPath
    $markers     = @($p.markers)
    $stack       = Detect-Stack $markers
    $category    = Detect-Category $stack $markers
    $destination = Detect-Destination $category $stack
    $port        = if ($p.PSObject.Properties.Name -contains 'port' -and $p.port) { [int]$p.port } else { (Suggest-Port $category) }
    if (-not $port) { $port = Get-NextPort }
    $integration = Detect-IntegrationMode $category $stack

    $gitRemote = $null
    if ($p.PSObject.Properties.Name -contains 'remote' -and $p.remote) { $gitRemote = $p.remote }
    elseif ($p.PSObject.Properties.Name -contains 'gitRepo' -and $p.gitRepo) { $gitRemote = $p.gitRepo }

    $deps = @()
    if ($p.PSObject.Properties.Name -contains 'dependencies') { $deps = @($p.dependencies) }

    $categorized += [pscustomobject]@{
        name                = $name
        fullPath            = $fullPath
        stack               = $stack
        category            = $category
        destination         = $destination
        port                = $port
        integrationMode     = $integration
        markers             = $markers
        dependencies        = $deps
        gitRemote           = $gitRemote
        suggestedServiceName = $p.suggestedServiceName
        gitRepo             = $p.gitRepo
    }
}

# ---- Sort: core services first, then migrated ------------------------------
$categorized = $categorized | Sort-Object @{ Expression = { $_.category } }, @{ Expression = { $_.name } }

# ---- Build output ----------------------------------------------------------
$output = [pscustomobject]@{
    generated        = (Get-Date -Format o)
    generatedBy      = 'categorize-projects.ps1'
    source           = $InventoryJson
    totalProjects    = $categorized.Count
    ports            = @{
        dashboard      = 3000
        apiGateway     = 4000
        migratedStart  = 4001
    }
    projects         = $categorized
}

# ---- Write output ----------------------------------------------------------
$outDir = Split-Path -Parent $OutputJson
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
$output | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputJson -Encoding UTF8

# ---- Print summary table ---------------------------------------------------
Write-Host "`n=== Categorized Inventory ===" -ForegroundColor Cyan
Write-Host ("Total projects: {0}" -f $categorized.Count)
$categorized |
    Format-Table @{ Name='Project'; Expression={$_.name} },
                  @{ Name='Stack'; Expression={$_.stack} },
                  @{ Name='Category'; Expression={$_.category} },
                  @{ Name='Destination'; Expression={$_.destination} },
                  @{ Name='Port'; Expression={$_.port} },
                  @{ Name='Mode'; Expression={$_.integrationMode} },
                  @{ Name='Git Remote'; Expression={$_.gitRemote} } -AutoSize

# ---- Stack breakdown -------------------------------------------------------
$stackBreakdown = $categorized | Group-Object stack
Write-Host "`n--- By Stack ---" -ForegroundColor Cyan
foreach ($g in $stackBreakdown) { Write-Host ("  {0}: {1}" -f $g.Name, $g.Count) }

# ---- Category breakdown ----------------------------------------------------
$catBreakdown = $categorized | Group-Object category
Write-Host "`n--- By Category ---" -ForegroundColor Cyan
foreach ($g in $catBreakdown) { Write-Host ("  {0}: {1}" -f $g.Name, $g.Count) }

Write-Host "`nCategorized inventory written to: $OutputJson" -ForegroundColor Green
exit 0
