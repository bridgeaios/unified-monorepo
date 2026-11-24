#!/usr/bin/env pwsh
# merge-inventory.ps1
#
# Merges the main scanner's projects.json with deep-scan subagent results
# (docs\deep-scan-*.json) into one unified projects.json + projects.csv.
#
# Dedup: by FullPath (case-insensitive); the main scanner's version wins on conflict.
# Noise paths are dropped.
#
# Outputs:
#   OutputJson  - merged JSON array
#   OutputCsv   - same rows as CSV
# Exit codes: 0 success; 1 when main projects.json is missing AND no deep-scan files exist.

param(
    [string]$MainJson   = "C:\Users\supas\Desktop\ProjectInventory\projects.json",
    [string]$DeepScanDir = "E:\AOE\unified-monorepo\docs\",
    [string]$OutputJson  = "C:\Users\supas\Desktop\ProjectInventory\projects.json",
    [string]$OutputCsv   = "C:\Users\supas\Desktop\ProjectInventory\projects.csv"
)

$ErrorActionPreference = "Continue"

# Noise path segments (case-insensitive substring match against FullPath)
$noiseSegments = @(
    "site-packages","node_modules",".next",".nuxt","__pycache__",
    "dist","build","target",".turbo",".cache","coverage",
    ".gradle",".cargo",".npm","Windows.old",
    '$Recycle.Bin',"System Volume Information","FileHistory",
    "AppData","Program Files","\Windows\"
)

function Test-NoisePath {
    param([string]$Path)
    $lower = $Path.ToLowerInvariant()
    foreach ($seg in $noiseSegments) {
        if ($lower -contains $seg.ToLowerInvariant()) {
            return $true
        }
    }
    return $false
}

function To-Bool {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    $s = [string]$Value
    return ($s -eq "True" -or $s -eq "true" -or $s -eq "1")
}

function Normalize-Project {
    param([object]$Source)

    $fullPath = [string]$Source.FullPath
    if ([string]::IsNullOrWhiteSpace($fullPath)) { return $null }
    if (Test-NoisePath $fullPath) { return $null }

    $name = [string]$Source.Name
    if ([string]::IsNullOrWhiteSpace($name)) { $name = Split-Path $fullPath -Leaf }

    $drive = ""
    if ($fullPath -match "^([A-Za-z]):") { $drive = $Matches[1].ToUpper() + ":" }

    $markers = @($Source.Markers)
    if ($markers.Count -eq 1 -and [string]::IsNullOrWhiteSpace($markers[0])) { $markers = @() }

    [PSCustomObject]@{
        Name      = $name
        FullPath  = $fullPath
        Drive     = $drive
        Stack     = [string]$Source.Stack
        Category  = [string]$Source.Category
        Markers   = $markers
        GitRepo   = To-Bool $Source.GitRepo
        Remote    = [string]$Source.Remote
        Migration = To-Bool $Source.Migration
    }
}

# ---------------------------------------------------------------------------
# Load main scanner inventory
# ---------------------------------------------------------------------------
$mainProjects = @()
$mainCount = 0
$mainFileExists = Test-Path -LiteralPath $MainJson -PathType Leaf
if ($mainFileExists) {
    try {
        $raw = Get-Content -Raw -LiteralPath $MainJson -ErrorAction Stop
        $parsed = ConvertFrom-Json $raw -ErrorAction Stop
        $mainProjects = @($parsed)
        $mainCount = $mainProjects.Count
        Write-Host ("Main scanner: {0} projects" -f $mainCount) -ForegroundColor Gray
    }
    catch {
        Write-Host "WARNING: could not read main projects.json '$MainJson' : $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host "Main projects.json not found (will use deep-scan results only)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Load deep-scan subagent results (deep-scan-*.json arrays)
# ---------------------------------------------------------------------------
$deepFiles    = @()
$deepProjects = @()
$deepFileInfo = [System.Collections.Generic.List[PSCustomObject]]::new()

if (Test-Path -LiteralPath $DeepScanDir -PathType Container) {
    $deepFiles = @(Get-ChildItem -LiteralPath $DeepScanDir -Filter "deep-scan-*.json" -File | Sort-Object Name)
    Write-Host ("Found {0} deep-scan file(s)" -f $deepFiles.Count) -ForegroundColor Gray
}

foreach ($file in $deepFiles) {
    try {
        $raw   = Get-Content -Raw -LiteralPath $file.FullName -ErrorAction Stop
        $parsed = ConvertFrom-Json $raw -ErrorAction Stop
        $items = @($parsed)
        $count = $items.Count
        $deepFileInfo.Add([PSCustomObject]@{ File = $file.Name; Count = $count })
        $deepProjects += $items
        Write-Host ("  {0}: {1} projects" -f $file.Name, $count) -ForegroundColor Gray
    }
    catch {
        Write-Host "WARNING: could not read deep scan file '$($file.FullName)' : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Fail only when there is nothing to merge
# ---------------------------------------------------------------------------
if (-not $mainFileExists -and $deepFiles.Count -eq 0) {
    Write-Host "ERROR: Main projects.json not found at '$MainJson'" -ForegroundColor Red
    Write-Host "       and no deep-scan-*.json files found in '$DeepScanDir'." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Merge + dedupe (main scanner wins), case-insensitive on FullPath
# ---------------------------------------------------------------------------
$merged = [System.Collections.Generic.List[object]]::new()
$seen   = @{}

$allSources = @($mainProjects) + @($deepProjects)
Write-Host ("Total raw projects to merge: {0}" -f $allSources.Count) -ForegroundColor Gray

foreach ($src in $allSources) {
    if ($null -eq $src) { continue }
    $n = Normalize-Project $src
    if (-not $n) { continue }

    $key = $n.FullPath.ToLowerInvariant()
    if (-not $seen.ContainsKey($key)) {
        $seen[$key] = $true
        $merged.Add($n)
    }
}

# ---------------------------------------------------------------------------
# Write outputs
# ---------------------------------------------------------------------------
$jsonDir = Split-Path -Parent $OutputJson
if (-not [string]::IsNullOrEmpty($jsonDir)) { New-Item -ItemType Directory -Force -Path $jsonDir | Out-Null }

$merged | Sort-Object FullPath | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath $OutputJson -Encoding UTF8

$csvDir = Split-Path -Parent $OutputCsv
if (-not [string]::IsNullOrEmpty($csvDir)) { New-Item -ItemType Directory -Force -Path $csvDir | Out-Null }

$csvRows = $merged | Sort-Object FullPath | ForEach-Object {
    [PSCustomObject]@{
        Name      = $_.Name
        FullPath  = $_.FullPath
        Drive     = $_.Drive
        Stack     = $_.Stack
        Category  = $_.Category
        Markers   = ($_.Markers -join "; ")
        GitRepo   = $_.GitRepo
        Remote    = $_.Remote
        Migration = $_.Migration
    }
}
$csvRows | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------------------
# Console summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "MERGE INVENTORY SUMMARY" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Gray
Write-Host "Total projects from main scanner : $mainCount"
foreach ($info in $deepFileInfo) {
    Write-Host ("Total projects from {0,-28} : {1}" -f $info.File, $info.Count)
}
Write-Host "Total unique projects after merge/dedup : $($merged.Count)" -ForegroundColor Green
Write-Host ""

Write-Host "Breakdown by stack:" -ForegroundColor Gray
$merged | Group-Object Stack | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,-22} : {1}" -f $_.Name, $_.Count)
}
Write-Host ""

Write-Host "Breakdown by drive:" -ForegroundColor Gray
foreach ($d in @("C:","D:","E:")) {
    $c = ($merged | Where-Object { $_.Drive -eq $d }).Count
    Write-Host ("  {0,-5} : {1}" -f $d, $c)
}
Write-Host ""

$gitCount = ($merged | Where-Object { $_.GitRepo -eq $true }).Count
Write-Host ("Git repos count : {0}" -f $gitCount)
Write-Host ""
Write-Host "Output JSON : $OutputJson" -ForegroundColor Cyan
Write-Host "Output CSV  : $OutputCsv" -ForegroundColor Cyan
Write-Host "MERGE INVENTORY COMPLETE" -ForegroundColor Cyan

exit 0
