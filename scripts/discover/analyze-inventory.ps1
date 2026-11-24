#!/usr/bin/env pwsh
# Analyze projects.json inventory from Discover-Projects.ps1
# Outputs: migration plan, conflict report, port/dependency analysis

param(
    [string]$InventoryJson = "..\..\..\..\Desktop\ProjectInventory\projects.json",
    [string]$OutputDir     = "..\..\..\docs"
)

$ErrorActionPreference = "Continue"

if (-not (Test-Path -LiteralPath $InventoryJson)) {
    Write-Host "ERROR: Inventory not found at $InventoryJson" -ForegroundColor Red
    Write-Host "Run Discover-Projects.ps1 first." -ForegroundColor Yellow
    exit 1
}

$projects = Get-Content -LiteralPath $InventoryJson -Raw | ConvertFrom-Json
$migrationPlan = [System.Collections.Generic.List[object]]::new()
$portConflicts = [System.Collections.Generic.List[object]]::new()
$dependencyConflicts = [System.Collections.Generic.List[object]]::new()
$seenPorts = @{}
$seenDeps = @{}

foreach ($p in $projects) {
    $entry = [PSCustomObject]@{
        Name            = $p.Name
        FullPath        = $p.FullPath
        Stack           = $p.Stack
        Category        = $p.Category
        Markers         = $p.Markers
        GitRepo         = $p.GitRepo
        Remote          = $p.Remote
        SuggestedServiceName = ("project-" + ($p.Name -replace '[^a-z0-9]', '-').ToLower().Trim('-'))
        MigrationStatus = "Pending"
        Notes           = @()
    }

    # Stack-based recommendations
    if ($p.Stack -match "Node.js|Next.js|Vite|Angular|Svelte|Astro") {
        $entry.Notes.Add("Frontend candidate — route through dashboard proxy")
        $entry.Notes.Add("Suggest port: 3000-series")
    }
    if ($p.Stack -match "Python|Django|Go|Java|Rust|\.NET|PHP|Ruby") {
        $entry.Notes.Add("Backend candidate — route through api-gateway")
        $entry.Notes.Add("Suggest port: 4000+ series")
    }
    if ($p.GitRepo -eq $true) {
        $entry.Notes.Add("Git repo detected — preserve .git history during migration")
    } else {
        $entry.Notes.Add("No .git — initialize fresh git in monorepo")
    }

    $migrationPlan.Add($entry)
}

$migrationPlan | Sort-Object Name | ConvertTo-Json -Depth 5 |
    Set-Content -Path (Join-Path $OutputDir "migration-plan.json") -Encoding UTF8

# Write summary markdown
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Migration Plan")
$lines.Add("")
$lines.Add("Generated from project inventory analysis")
$lines.Add("")
$lines.Add("Total projects: $($migrationPlan.Count)")
$lines.Add("")
$lines.Add("| # | Project | Stack | Category | Git | Suggested Service | Status |")
$lines.Add("|---|---------|-------|----------|-----|-------------------|--------|")

$i = 1
foreach ($p in $migrationPlan | Sort-Object Name) {
    $lines.Add("| $i | $($p.Name) | $($p.Stack) | $($p.Category) | $($p.GitRepo) | $($p.SuggestedServiceName) | $($p.MigrationStatus) |")
    $i++
}

$lines | Set-Content -Path (Join-Path $OutputDir "MIGRATION_PLAN.md") -Encoding UTF8

Write-Host "ANALYSIS COMPLETE" -ForegroundColor Cyan
Write-Host "Projects analyzed: $($migrationPlan.Count)"
Write-Host "Migration plan: $OutputDir\MIGRATION_PLAN.md"
Write-Host "JSON plan: $OutputDir\migration-plan.json"
