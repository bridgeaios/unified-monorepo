#!/usr/bin/env pwsh
# consolidate-inventory.ps1
#
# Consolidates Phase 1 project-discovery output into a single normalized,
# migration-ready inventory for the unified-monorepo migration pipeline.
#
# Input (in order of preference):
#   1. C:\Users\supas\Desktop\ProjectInventory\projects.json
#      (produced by Discover-Projects.ps1; accepted as array, {projects: [...]},
#      or a single object)
#   2. Fallback: parse [PROJECT] lines from the scanner shell log
#      C:\Users\supas\.local\share\opencode\shell\<run>\sh_<id>.out
#
# Outputs (under E:\AOE\unified-monorepo\docs\):
#   consolidated-inventory.json   normalized project array + summary metadata
#   CONSOLIDATED_INVENTORY.md     human-readable summary
#
# Each project is normalized to:
#   { name, fullPath, stack, category, markers, gitRepo, remote, suggestedServiceName }
#   suggestedServiceName = "project-" + (name with non-alphanumeric replaced by "-",
#                                     lowercased, trimmed)

param(
    [string]$InputJson  = "C:\Users\supas\Desktop\ProjectInventory\projects.json",
    [string]$ShellLog   = "C:\Users\supas\.local\share\opencode\shell\a20c1e9b0074009c150bc9fdd25fc43925ad94fe\sh_1f31b3c11001jmFzsYxmg4vVa9.out",
    [string]$OutputDir  = "$PSScriptRoot\..\..\docs",
    [string]$OutputJson = "consolidated-inventory.json",
    [string]$OutputMd   = "CONSOLIDATED_INVENTORY.md"
)

$ErrorActionPreference = "Continue"

# Resolve output dir relative to this script (...\scripts\discover -> ...\docs)
$OutputDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $OutputDir))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$jsonOut = Join-Path $OutputDir $OutputJson
$mdOut   = Join-Path $OutputDir $OutputMd

# ---------------------------------------------------------------------------
# Noise paths to filter out (build caches, package stores, system junk)
# ---------------------------------------------------------------------------
$noise = @(
    "site-packages","node_modules",".next",".nuxt","__pycache__",
    "dist","build","target",".turbo",".cache","coverage",
    ".gradle",".cargo",".npm","Windows.old",
    '$Recycle.Bin',"System Volume Information"
)

function Test-NoisePath {
    param([string]$Path)
    foreach ($n in $noise) {
        if ($Path.IndexOf($n, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Get-PropValue {
    param([object]$Object, [string]$Name, $Default = $null)
    foreach ($prop in $Object.PSObject.Properties) {
        if ($prop.Name -eq $Name) { return $prop.Value }
    }
    return $Default
}

function New-SuggestedServiceName {
    param([string]$Name)
    $s = $Name.ToLower()
    $s = $s -replace '[^a-z0-9]', '-'
    $s = $s.Trim().Trim('-')
    return "project-$s"
}

function Normalize-Project {
    param([object]$Source)
    $name  = [string](Get-PropValue $Source "Name")
    $path  = [string](Get-PropValue $Source "FullPath")
    if ([string]::IsNullOrEmpty($path)) { $path = [string](Get-PropValue $Source "fullPath") }
    $stack = [string](Get-PropValue $Source "Stack")
    $cat   = [string](Get-PropValue $Source "Category")
    $marks = [string](Get-PropValue $Source "Markers")
    $git   = [bool](Get-PropValue $Source "GitRepo" $false)
    $remote= [string](Get-PropValue $Source "Remote" "")

    if ([string]::IsNullOrEmpty($name)) {
        $name = Split-Path $path -Leaf
        if ([string]::IsNullOrEmpty($name)) { $name = Split-Path (Split-Path $path -Parent) -Leaf }
    }
    if ([string]::IsNullOrEmpty($stack)) { $stack = "Unknown" }
    if ([string]::IsNullOrEmpty($cat))   { $cat   = "Unknown" }
    if ([string]::IsNullOrEmpty($marks)) { $marks = "" }

    [PSCustomObject]@{
        name                 = $name
        fullPath             = $path
        stack                = $stack
        category             = $cat
        markers              = $marks
        gitRepo              = $git
        remote               = $remote
        suggestedServiceName = (New-SuggestedServiceName $name)
    }
}

# ---------------------------------------------------------------------------
# Load raw discovery data
# ---------------------------------------------------------------------------
Write-Host "CONSOLIDATE INVENTORY" -ForegroundColor Cyan
Write-Host "Input JSON : $InputJson" -ForegroundColor Gray
Write-Host "Shell log  : $ShellLog"   -ForegroundColor Gray
Write-Host "Output dir : $OutputDir"  -ForegroundColor Gray

$rawProjects = @()
$sourceUsed  = $null
$noiseFiltered = 0

if (Test-Path -LiteralPath $InputJson) {
    $sourceUsed = $InputJson
    $raw = Get-Content -LiteralPath $InputJson -Raw -ErrorAction Stop
    $doc = $raw | ConvertFrom-Json -ErrorAction Stop

    if ($null -eq $doc) {
        $rawProjects = @()
    }
    elseif ($doc -is [array]) {
        $rawProjects = @($doc)
    }
    elseif ($doc.PSObject.Properties.Name -contains "projects") {
        $rawProjects = @($doc.projects)
    }
    else {
        $rawProjects = @($doc)
    }

    Write-Host "Loaded $($rawProjects.Count) raw project(s) from projects.json" -ForegroundColor Green
}
elseif (Test-Path -LiteralPath $ShellLog) {
    $sourceUsed = $ShellLog
    $pattern = "^\[PROJECT\]\s+(.+)$"
    $lines   = Get-Content -LiteralPath $ShellLog -ErrorAction Stop
    $seen    = @{}
    foreach ($line in $lines) {
        if ($line -match $pattern) {
            $path = $matches[1].Trim()
            $key  = $path.ToLower()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $rawProjects += [PSCustomObject]@{
                Name     = (Split-Path $path -Leaf)
                FullPath = $path
                Stack    = "Unknown"
                Category = "Unknown"
                Markers  = "[shell log fallback]"
                GitRepo  = (Test-Path -LiteralPath (Join-Path $path ".git"))
                Remote   = ""
            }
        }
    }
    Write-Host "Parsed $($rawProjects.Count) [PROJECT] line(s) from shell log" -ForegroundColor Green
}
else {
    Write-Host "WARNING: projects.json not found and shell log not found." -ForegroundColor Yellow
    Write-Host "         Producing an empty inventory." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Normalize + filter noise + de-duplicate by full path
# ---------------------------------------------------------------------------
$projects = [System.Collections.Generic.List[object]]::new()
$seenPaths = @{}

foreach ($src in $rawProjects) {
    $path = [string](Get-PropValue $src "FullPath")
    if ([string]::IsNullOrEmpty($path)) { continue }
    if (Test-NoisePath $path) {
        $noiseFiltered++
        continue
    }
    $key = $path.ToLower()
    if ($seenPaths.ContainsKey($key)) { continue }
    $seenPaths[$key] = $true
    $projects.Add((Normalize-Project $src))
}

# ---------------------------------------------------------------------------
# Summary computations
# ---------------------------------------------------------------------------
$total      = $projects.Count
$gitCount   = ($projects | Where-Object { $_.gitRepo -eq $true }).Count

# Stack breakdown (Discover-Projects stores comma-separated stacks)
$stackCounts = @{}
foreach ($p in $projects) {
    foreach ($s in ($p.stack -split ',')) {
        $t = $s.Trim()
        if ([string]::IsNullOrEmpty($t)) { $t = "(none)" }
        $stackCounts[$t] = ($stackCounts[$t] + 1)
    }
}

# Category breakdown
$catCounts = @{}
foreach ($p in $projects) {
    $c = if ([string]::IsNullOrEmpty($p.category)) { "(none)" } else { $p.category }
    $catCounts[$c] = ($catCounts[$c] + 1)
}

# Drives covered
$driveCounts = @{}
foreach ($p in $projects) {
    $d = [System.IO.Path]::GetPathRoot($p.fullPath).TrimEnd('\').ToUpper()
    if ($d) { $driveCounts[$d] = ($driveCounts[$d] + 1) }
}

function Test-DriveCovered {
    param([string]$Drive)
    return $driveCounts.ContainsKey($Drive.ToUpper())
}

# ---------------------------------------------------------------------------
# Write consolidated-inventory.json
# ---------------------------------------------------------------------------
$summary = [PSCustomObject]@{
    generatedAt      = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    source           = $sourceUsed
    sourceType       = if ($sourceUsed -eq $InputJson) { "projects.json" } else { "shell-log" }
    totalProjects    = $total
    noiseFiltered    = $noiseFiltered
    gitRepoCount     = $gitCount
    stacks           = $stackCounts
    categories       = $catCounts
    drivesCovered    = $driveCounts
    projects         = @($projects)
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonOut -Encoding UTF8

# ---------------------------------------------------------------------------
# Write CONSOLIDATED_INVENTORY.md
# ---------------------------------------------------------------------------
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Consolidated Project Inventory")
$lines.Add("")
$lines.Add("Generated: $($summary.generatedAt) UTC")
$lines.Add("Source: $($summary.source)")
$lines.Add("")
$lines.Add("## Summary")
$lines.Add("")
$lines.Add("| Metric | Value |")
$lines.Add("|---|---|")
$lines.Add("| Total projects found | $total |")
$lines.Add("| Git repositories | $gitCount |")
$lines.Add("| Noise-filtered paths | $noiseFiltered |")
$lines.Add("")
$lines.Add("### Breakdown by stack")
$lines.Add("| Stack | Projects |")
$lines.Add("|---|---|")
foreach ($kv in $stackCounts.GetEnumerator() | Sort-Object Value -Descending) {
    $lines.Add("| $($kv.Key) | $($kv.Value) |")
}
$lines.Add("")
$lines.Add("### Breakdown by category")
$lines.Add("| Category | Projects |")
$lines.Add("|---|---|")
foreach ($kv in $catCounts.GetEnumerator() | Sort-Object Value -Descending) {
    $lines.Add("| $($kv.Key) | $($kv.Value) |")
}
$lines.Add("")
$lines.Add("### Drives covered")
$lines.Add("| Drive | Covered |")
$lines.Add("|---|---|")
foreach ($d in @("C:","D:","E:")) {
    $lines.Add("| $d | $([bool](Test-DriveCovered $d)) |")
}
$lines.Add("")
$lines.Add("## Projects")
$lines.Add("| # | Name | Full Path | Stack | Category | Git | Suggested Service |")
$lines.Add("|---|------|-----------|-------|----------|-----|-------------------|")
$i = 1
foreach ($p in $projects | Sort-Object fullPath) {
    $safeName  = $p.name.Replace("|","\|")
    $safePath  = $p.fullPath.Replace("|","\|")
    $lines.Add("| $i | $safeName | $safePath | $($p.stack) | $($p.category) | $($p.gitRepo) | $($p.suggestedServiceName) |")
    $i++
}

$lines | Set-Content -LiteralPath $mdOut -Encoding UTF8

# ---------------------------------------------------------------------------
# Print summary table to console
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "CONSOLIDATION COMPLETE" -ForegroundColor Cyan
Write-Host "Total projects found : $total"
Write-Host "Git repositories     : $gitCount"
Write-Host "Noise filtered       : $noiseFiltered"
Write-Host "Drives covered       : $($driveCounts.Keys -join ', ')"
Write-Host "JSON output          : $jsonOut"
Write-Host "Markdown output      : $mdOut"
Write-Host ""
$projects | Sort-Object fullPath |
    Format-Table name, fullPath, stack, category, gitRepo, suggestedServiceName -AutoSize |
    Out-String | Write-Host
