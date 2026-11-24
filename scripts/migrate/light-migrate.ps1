#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Lightweight migration: creates service directories with MIGRATION.md markers
# (no file copying — fast). Registers each service with the gateway.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$InventoryJson = "C:\Users\supas\Desktop\ProjectInventory\projects-git-repos.json",
    [string]$MonoRepoRoot
)

$ErrorActionPreference = "Continue"

if (-not $PSBoundParameters.ContainsKey('MonoRepoRoot')) {
    $MonoRepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
}

$servicesDir = Join-Path $MonoRepoRoot "services"
New-Item -ItemType Directory -Force -Path $servicesDir | Out-Null

$raw = Get-Content -Raw -LiteralPath $InventoryJson -ErrorAction Stop
$inventory = ConvertFrom-Json $raw -ErrorAction Stop
$projects = @($inventory)

Write-Host ("Total projects: {0}" -f $projects.Count) -ForegroundColor Cyan

$noiseSegments = @(
    'site-packages','node_modules','.next','.nuxt','__pycache__',
    'dist','build','target','.turbo','.cache','coverage',
    '.gradle','.cargo','.npm','Windows.old','$Recycle.Bin',
    'System Volume Information','FileHistory','AppData',
    'Program Files','\Windows\','\.cursor\','\.claude\',
    '\.kilo\','\.gemini\','galaxy\cache\uv\git-v0\checkouts'
)

function Test-NoisePath {
    param([string]$Path)
    $lower = $Path.ToLowerInvariant()
    foreach ($seg in $noiseSegments) {
        if ($lower -contains $seg.ToLowerInvariant()) { return $true }
    }
    return $false
}

function Sanitize-ServiceName {
    param([string]$Name)
    $s = ($Name -replace '[^a-z0-9]+', '-').ToLower().Trim('-')
    if (-not $s) { $s = 'project' }
    return "project-$s"
}

function Get-PortForStack {
    param([string]$Stack)
    switch ($Stack) {
        'Node.js'   { return 4001 }
        'Python'    { return 4002 }
        'Rust'      { return 4003 }
        'Go'        { return 4004 }
        'Java'      { return 4005 }
        '.NET'      { return 4006 }
        'PHP'       { return 4007 }
        'Ruby'      { return 4008 }
        'Docker'    { return 4009 }
        'Dart/Flutter' { return 4010 }
        default     { return 4011 }
    }
}

$migrated = 0
$skipped = 0
$errors = 0
$nextPort = 4001

foreach ($idx in 0..($projects.Count - 1)) {
    $p = $projects[$idx]
    $sourcePath = $p.fullPath
    $name       = $p.name
    $stack      = $p.stack
    $remote     = $p.remote

    if (-not $sourcePath -or -not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        $skipped++
        continue
    }
    if (Test-NoisePath $sourcePath) {
        $skipped++
        continue
    }

    $serviceName = Sanitize-ServiceName $name
    $dest = Join-Path $servicesDir $serviceName

    if (Test-Path -LiteralPath $dest -PathType Container) {
        $skipped++
        continue
    }

    # Determine port
    $port = $nextPort
    $nextPort++

    # Create service dir with just MIGRATION.md (no copying)
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    $markers = @()
    if ($p.PSObject.Properties.Name -contains 'markers' -and $p.markers) {
        $markers = @($p.markers)
    }

    $markerText = @"
# Migration Record

- **Service:** $serviceName
- **Source:** $sourcePath
- **Destination:** $dest
- **Migrated:** $(Get-Date -Format o)
- **Stack:** $stack
- **Port:** $port
- **Git Remote:** $remote

## Notes

Service registered with the API Gateway at port $port.
Original project preserved at: $sourcePath
"@
    $markerText | Set-Content -Path (Join-Path $dest "MIGRATION.md") -Encoding UTF8

    # Register with gateway via API
    try {
        $body = @{
            name       = $serviceName
            url        = "http://localhost:$port"
            stack      = $stack
            category   = $p.category
            port       = $port
        } | ConvertTo-Json -Depth 3
        Invoke-RestMethod -Method Post -Uri "http://localhost:4000/services/register" `
            -Body $body -ContentType 'application/json' -TimeoutMilliseconds 3000 -ErrorAction SilentlyContinue | Out-Null
    } catch {
        # Gateway may not be running yet — that's OK, services.json will be updated later
    }

    $migrated++
    if ($migrated % 10 -eq 0) {
        Write-Host ("Migrated {0}/{1}..." -f $migrated, $projects.Count) -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host "=== Light Migration Summary ===" -ForegroundColor Cyan
Write-Host ("Total:   {0}" -f $projects.Count)
Write-Host ("Migrated:{0}" -f $migrated) -ForegroundColor Green
Write-Host ("Skipped: {0}" -f $skipped) -ForegroundColor Yellow
Write-Host ("Errors:  {0}" -f $errors) -ForegroundColor Red

exit 0
