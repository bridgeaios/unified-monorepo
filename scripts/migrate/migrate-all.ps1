#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Batch-migrate every project in projects.json into the unified monorepo
# under services/. Continues on error; writes migration-summary.json.
#
# Parameters:
#   -InventoryJson   Path to the Phase-1 scanner inventory
#                    (default: ..\..\..\..\Desktop\ProjectInventory\projects.json)
#   -MonoRepoRoot    Target monorepo root (default: auto-resolved,
#                    two levels above this script's location)
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$InventoryJson,
    [string]$MonoRepoRoot
)

# ---- Resolve defaults -----------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('InventoryJson')) {
    $InventoryJson = Join-Path $PSScriptRoot "..\..\..\..\Desktop\ProjectInventory\projects.json"
}
try {
    $InventoryJson = Resolve-Path $InventoryJson -ErrorAction Stop
} catch {
    Write-Host "ERROR: Inventory file not found: $InventoryJson" -ForegroundColor Red
    exit 1
}
if (-not $PSBoundParameters.ContainsKey('MonoRepoRoot')) {
    $MonoRepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
}

$servicesDir = Join-Path $MonoRepoRoot "services"
New-Item -ItemType Directory -Force -Path $servicesDir | Out-Null

$migrateProjectScript = Join-Path $PSScriptRoot "migrate-project.ps1"
if (-not (Test-Path -LiteralPath $migrateProjectScript)) {
    Write-Host "ERROR: migrate-project.ps1 not found at $migrateProjectScript" -ForegroundColor Red
    exit 1
}

# ---- Helper functions -----------------------------------------------------
function Sanitize-ServiceName {
    param([string]$Name)
    $s = ($Name -replace '[^a-z0-9]+', '-').ToLower().Trim('-')
    if (-not $s) { $s = 'project' }
    return "project-$s"
}

function Get-ProjectProperty {
    param($item, [string[]]$Names)
    foreach ($n in $Names) {
        if ($item.PSObject.Properties.Name -contains $n) {
            return $item.$n
        }
    }
    return $null
}

# ---- Load inventory -------------------------------------------------------
Write-Host "Reading inventory: $InventoryJson" -ForegroundColor Cyan
$raw = Get-Content -Raw -LiteralPath $InventoryJson -ErrorAction Stop
$inventory = ConvertFrom-Json $raw -ErrorAction Stop

$projects = @()
if ($inventory -is [array]) {
    $projects = @($inventory)
} elseif ($inventory.PSObject.Properties.Name -contains 'projects') {
    $projects = @($inventory.projects)
} else {
    $projects = @($inventory)
}

if ($projects.Count -eq 0) {
    Write-Host "No projects found in inventory." -ForegroundColor Yellow
}

# ---- Migrate each project -------------------------------------------------
$results = New-Object System.Collections.Generic.List[pscustomobject]

foreach ($idx in 0..($projects.Count - 1)) {
    $p = $projects[$idx]

    $sourcePath = Get-ProjectProperty $p @('path', 'sourcePath', 'fullName', 'fullpath', 'folder', 'directory', 'root', 'location')
    $name       = Get-ProjectProperty $p @('name', 'projectName', 'serviceName', 'title')

    if (-not $sourcePath) {
        $record = [pscustomobject]@{
            Name        = $name
            ServiceName = $null
            Status      = 'ERROR'
            Destination = $null
            Reason      = "No path property found in inventory entry"
        }
        $results.Add($record)
        Write-Host ("[ERROR] {0} - {1}" -f $name, $record.Reason) -ForegroundColor Red
        continue
    }

    if (-not [System.IO.Path]::IsPathRooted($sourcePath)) {
        $sourcePath = Join-Path (Split-Path -Parent $InventoryJson) $sourcePath
    }
    $sourcePath = Resolve-Path $sourcePath -ErrorAction SilentlyContinue
    if (-not $sourcePath) {
        $record = [pscustomobject]@{
            Name        = $name
            ServiceName = $null
            Status      = 'ERROR'
            Destination = $null
            Reason      = "Source path not found"
        }
        $results.Add($record)
        Write-Host ("[ERROR] {0} - {1}" -f $name, $record.Reason) -ForegroundColor Red
        continue
    }

    if (-not $name) {
        $name = Split-Path $sourcePath -Leaf
    }
    $serviceName = Sanitize-ServiceName $name

    $dest = Join-Path $servicesDir $serviceName

    # Skip if already migrated
    if (Test-Path -LiteralPath $dest -PathType Container) {
        $record = [pscustomobject]@{
            Name        = $name
            ServiceName = $serviceName
            Status      = 'SKIP'
            Destination = $dest
            Reason      = "Already exists"
        }
        $results.Add($record)
        Write-Host ("[SKIP] {0} already exists" -f $serviceName) -ForegroundColor Yellow
        continue
    }

    # Call migrate-project.ps1 in its own process so a failure never
    # aborts the batch (continue on error).
    $invocation = & pwsh -NoProfile -File $migrateProjectScript `
        -SourcePath $sourcePath `
        -ServiceName $serviceName `
        -MonoRepoRoot $MonoRepoRoot
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        $record = [pscustomobject]@{
            Name        = $name
            ServiceName = $serviceName
            Status      = 'OK'
            Destination = $dest
            Reason      = $null
        }
        $results.Add($record)
        Write-Host ("[OK] {0} -> services\{1}" -f $serviceName, $serviceName) -ForegroundColor Green
    } else {
        $record = [pscustomobject]@{
            Name        = $name
            ServiceName = $serviceName
            Status      = 'ERROR'
            Destination = $dest
            Reason      = "migrate-project.ps1 exited with code $exitCode"
        }
        $results.Add($record)
        Write-Host ("[ERROR] {0} - {1}" -f $serviceName, $record.Reason) -ForegroundColor Red
    }
}

# ---- Summary --------------------------------------------------------------
$total   = $results.Count
$migrated = ($results | Where-Object { $_.Status -eq 'OK' }).Count
$skipped  = ($results | Where-Object { $_.Status -eq 'SKIP' }).Count
$errors   = ($results | Where-Object { $_.Status -eq 'ERROR' }).Count

$summaryPath = Join-Path $PSScriptRoot "migration-summary.json"
$summary = @{
    total      = $total
    migrated   = $migrated
    skipped    = $skipped
    errors     = $errors
    timestamp  = (Get-Date -Format o)
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $summaryPath -Encoding UTF8

Write-Host ""
Write-Host "=== Migration Summary ===" -ForegroundColor Cyan
Write-Host ("Total:   {0}" -f $total)
Write-Host ("Migrated:{0}" -f $migrated) -ForegroundColor Green
Write-Host ("Skipped: {0}" -f $skipped) -ForegroundColor Yellow
Write-Host ("Errors:  {0}" -f $errors) -ForegroundColor Red
Write-Host ("Summary written to: $summaryPath")

Write-Host ""
Write-Host "=== Per-project results ===" -ForegroundColor Cyan
$results |
    Sort-Object Name |
    Format-Table @{ Name = 'Status'; Expression = { $_.Status } }, Name, ServiceName, Destination, Reason -AutoSize

exit 0
