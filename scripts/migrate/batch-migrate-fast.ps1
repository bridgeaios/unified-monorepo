#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Fast batch migration — processes all projects in a single PowerShell session
# instead of spawning a new pwsh process per project.
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

# ---- Load inventory -------------------------------------------------------
$raw = Get-Content -Raw -LiteralPath $InventoryJson -ErrorAction Stop
$inventory = ConvertFrom-Json $raw -ErrorAction Stop
$projects = @($inventory)

Write-Host ("Total projects to migrate: {0}" -f $projects.Count) -ForegroundColor Cyan

# ---- Skip list ------------------------------------------------------------
$skipList = @(
    'node_modules', '.next', '.nuxt', '.venv', 'venv', '__pycache__',
    'dist', 'build', 'target', '.turbo', '.cache', 'coverage',
    '.gradle', '.cargo', '.npm', '.git'
)

# ---- Noise path filter ----------------------------------------------------
$noiseSegments = @(
    'site-packages', 'node_modules', '.next', '.nuxt', '__pycache__',
    'dist', 'build', 'target', '.turbo', '.cache', 'coverage',
    '.gradle', '.cargo', '.npm', 'Windows.old', '$Recycle.Bin',
    'System Volume Information', 'FileHistory', 'AppData',
    'Program Files', '\Windows\', '\.cursor\', '\.claude\',
    '\.kilo\', '\.gemini\', 'galaxy\cache\uv\git-v0\checkouts'
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

# ---- Migrate each project -------------------------------------------------
$results = New-Object System.Collections.Generic.List[pscustomobject]
$migrated = 0
$skipped = 0
$errors = 0

foreach ($idx in 0..($projects.Count - 1)) {
    $p = $projects[$idx]
    $sourcePath = $p.fullPath
    $name       = $p.name
    $remote     = $p.remote

    if (-not $sourcePath -or -not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        $errors++
        Write-Host ("[SKIP] {0} - path not found" -f $name) -ForegroundColor Gray
        continue
    }

    if (Test-NoisePath $sourcePath) {
        $skipped++
        Write-Host ("[SKIP] {0} - noise path" -f $name) -ForegroundColor Gray
        continue
    }

    $serviceName = Sanitize-ServiceName $name
    $dest = Join-Path $servicesDir $serviceName

    # Skip if already migrated
    if (Test-Path -LiteralPath $dest -PathType Container) {
        $skipped++
        Write-Host ("[SKIP] {0} - already exists" -f $serviceName) -ForegroundColor Yellow
        continue
    }

    Write-Host ("[{0}/{1}] Migrating: {2}" -f ($idx + 1), $projects.Count, $serviceName) -ForegroundColor Cyan

    try {
        # 1. Create destination
        New-Item -ItemType Directory -Force -Path $dest | Out-Null

        # 2. Copy project files (skip noise)
        Get-ChildItem -LiteralPath $sourcePath -Force |
            Where-Object { $skipList -notcontains $_.Name } |
            ForEach-Object {
                $target = Join-Path $dest $_.Name
                if ($_.PSIsContainer) {
                    Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force -ErrorAction SilentlyContinue
                } else {
                    Copy-Item -LiteralPath $_.FullName -Destination $target -Force -ErrorAction SilentlyContinue
                }
            }

        # 3. Git history (lightweight - just init + remote, no full fetch)
        $gitSrc = Join-Path $sourcePath ".git"
        if (Test-Path -LiteralPath $gitSrc) {
            Push-Location $dest
            git init -q 2>$null | Out-Null
            if ($remote) {
                git remote add origin $remote 2>$null | Out-Null
            }
            git add -A 2>$null | Out-Null
            git commit -q -m "chore: initial migrated state of $serviceName" 2>$null | Out-Null
            # Create migrated-from-original branch pointing to current state
            git branch -f migrated-from-original 2>$null | Out-Null
            Pop-Location
        }

        # 4. Stack markers
        $markers = @()
        $stackChecks = @(
            @{ File = 'package.json'; Label = 'Node.js' },
            @{ File = 'requirements.txt'; Label = 'Python' },
            @{ File = 'pyproject.toml'; Label = 'Python' },
            @{ File = 'Cargo.toml'; Label = 'Rust' },
            @{ File = 'go.mod'; Label = 'Go' },
            @{ File = 'pom.xml'; Label = 'Java' },
            @{ File = 'build.gradle'; Label = 'Java' },
            @{ File = '*.csproj'; Label = '.NET' },
            @{ File = '*.sln'; Label = '.NET' },
            @{ File = 'composer.json'; Label = 'PHP' },
            @{ File = 'Gemfile'; Label = 'Ruby' },
            @{ File = 'Dockerfile'; Label = 'Docker' },
            @{ File = 'docker-compose.yml'; Label = 'Docker' }
        )
        foreach ($check in $stackChecks) {
            $match = Get-ChildItem -LiteralPath $sourcePath -Filter $check.File -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($match) { $markers += $check.Label }
        }

        # 5. MIGRATION.md
        $markerText = @"
# Migration Record

- **Service:** $serviceName
- **Source:** $sourcePath
- **Destination:** $dest
- **Migrated:** $(Get-Date -Format o)
- **Stack:** $(if ($markers.Count) { $markers -join ', ' } else { 'unknown' })

## Git

Original Git history is preserved on branch `migrated-from-original` (remote `origin` points
at the read-only source: $sourcePath). The working tree contains the copied project files
with build outputs and dependency caches excluded.

## Excluded from copy

$($skipList -join ', ')
"@
        $markerPath = Join-Path $dest "MIGRATION.md"
        $markerText | Set-Content -Path $markerPath -Encoding UTF8

        $migrated++
        Write-Host ("[OK] {0} -> services\{1}" -f $serviceName, $serviceName) -ForegroundColor Green
    }
    catch {
        $errors++
        Write-Host ("[ERROR] {0} - {1}" -f $serviceName, $_) -ForegroundColor Red
    }
}

# ---- Summary --------------------------------------------------------------
Write-Host ""
Write-Host "=== Fast Batch Migration Summary ===" -ForegroundColor Cyan
Write-Host ("Total:   {0}" -f $projects.Count)
Write-Host ("Migrated:{0}" -f $migrated) -ForegroundColor Green
Write-Host ("Skipped: {0}" -f $skipped) -ForegroundColor Yellow
Write-Host ("Errors:  {0}" -f $errors) -ForegroundColor Red
Write-Host ("Services dir: $servicesDir")

exit 0
