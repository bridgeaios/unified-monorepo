#!/usr/bin/env pwsh
# scan-drives-deep.ps1
#
# Supplementary deep scanner for projects the main scanner (Discover-Projects.ps1)
# may have missed. Scans a fixed list of deep locations with a bounded -Depth so
# it cannot hang, matches known manifest files, and writes newly found projects
# to docs\deep-scan-findings.json.
#
# Default locations scanned:
#   C:\Users\supas\projects
#   C:\Users\supas\SUPA1
#   C:\Users\supas\SUPA1-test
#   C:\Users\supas\temp-antigravity
#   C:\tmp
#   D:\  (if available)
#   E:\  (if available)
#
# A "newly found" project is one whose directory is not already listed in
# docs\consolidated-inventory.json (if that file exists).

param(
    [string[]]$Locations = @(
        "C:\Users\supas\projects",
        "C:\Users\supas\SUPA1",
        "C:\Users\supas\SUPA1-test",
        "C:\Users\supas\temp-antigravity",
        "C:\tmp",
        "D:\",
        "E:\"
    ),
    [int]$Depth      = 6,
    [string]$OutputDir  = "$PSScriptRoot\..\..\docs",
    [string]$OutputJson = "deep-scan-findings.json"
)

$ErrorActionPreference = "Continue"

# Resolve output dir relative to this script (...\scripts\discover -> ...\docs)
$OutputDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $OutputDir))
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$jsonOut = Join-Path $OutputDir $OutputJson

# ---------------------------------------------------------------------------
# Manifest files that mark a project root
# ---------------------------------------------------------------------------
$manifestExact = @(
    "package.json","pnpm-workspace.yaml","pyproject.toml","requirements.txt",
    "Pipfile","manage.py","Cargo.toml","go.mod","pom.xml","build.gradle",
    "composer.json","Gemfile","Dockerfile","docker-compose.yml","compose.yaml",
    "angular.json","CMakeLists.txt","pubspec.yaml","global.json"
)
$manifestWildcard = @("next.config.*","vite.config.*","*.sln","*.slnx","*.csproj","*.fsproj","*.vbproj","*.uproject")

# ---------------------------------------------------------------------------
# Noise segments: skip files whose directory path contains these
# (keeps the deep scan fast and free of build-cache noise)
# ---------------------------------------------------------------------------
$dirNoise = @(
    "site-packages","node_modules",".next",".nuxt","__pycache__",
    "dist","build","target",".turbo",".cache","coverage",
    ".gradle",".cargo",".npm","Windows.old",
    '$Recycle.Bin',"System Volume Information",".git"
)

function Test-DirNoise {
    param([string]$Path)
    foreach ($n in $dirNoise) {
        if ($Path.IndexOf($n, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Is-ManifestFile {
    param([string]$Name)
    if ($manifestExact -contains $Name) { return $true }
    foreach ($pat in $manifestWildcard) {
        if ($Name -like $pat) { return $true }
    }
    return $false
}

function New-SuggestedServiceName {
    param([string]$Name)
    $s = $Name.ToLower()
    $s = $s -replace '[^a-z0-9]', '-'
    $s = $s.Trim().Trim('-')
    return "project-$s"
}

function Infer-Stack {
    param([string[]]$Manifests)
    $stacks = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $Manifests) {
        $l = $m.ToLower()
        if (($l -eq "package.json" -or $l -eq "pnpm-workspace.yaml") -and ($stacks -notcontains "Node.js")) { $stacks.Add("Node.js") }
        elseif ($l -like "next.config.*" -and ($stacks -notcontains "Next.js")) { $stacks.Add("Next.js") }
        elseif ($l -like "vite.config.*" -and ($stacks -notcontains "Vite")) { $stacks.Add("Vite") }
        elseif ($l -eq "angular.json" -and ($stacks -notcontains "Angular")) { $stacks.Add("Angular") }
        elseif (($l -eq "pyproject.toml" -or $l -eq "requirements.txt" -or $l -eq "pipfile") -and ($stacks -notcontains "Python")) { $stacks.Add("Python") }
        elseif ($l -eq "manage.py") {
            if ($stacks -notcontains "Python") { $stacks.Add("Python") }
            if ($stacks -notcontains "Django")   { $stacks.Add("Django") }
        }
        elseif ($l -eq "cargo.toml" -and ($stacks -notcontains "Rust")) { $stacks.Add("Rust") }
        elseif ($l -eq "go.mod" -and ($stacks -notcontains "Go")) { $stacks.Add("Go") }
        elseif (($l -eq "pom.xml" -or $l -eq "build.gradle") -and ($stacks -notcontains "Java")) { $stacks.Add("Java") }
        elseif ($l -eq "composer.json" -and ($stacks -notcontains "PHP")) { $stacks.Add("PHP") }
        elseif (($l -eq "dockerfile" -or $l -eq "docker-compose.yml" -or $l -eq "compose.yaml") -and ($stacks -notcontains "Docker")) { $stacks.Add("Docker") }
        elseif (($l -like "*.sln" -or $l -like "*.slnx" -or $l -like "*.csproj" -or $l -like "*.fsproj" -or $l -like "*.vbproj") -and ($stacks -notcontains ".NET")) { $stacks.Add(".NET") }
        elseif ($l -like "*.uproject" -and ($stacks -notcontains "Unreal Engine")) { $stacks.Add("Unreal Engine") }
    }
    if ($stacks.Count -eq 0) { $stacks.Add("Unknown") }
    return ($stacks -join ", ")
}

function Infer-Category {
    param([string[]]$Manifests)
    foreach ($m in $Manifests) {
        $l = $m.ToLower()
        if ($l -like "next.config.*" -or $l -like "vite.config.*" -or $l -eq "angular.json") { return "Frontend" }
    }
    foreach ($m in $Manifests) {
        $l = $m.ToLower()
        if ($l -eq "manage.py" -or $l -eq "requirements.txt" -or $l -eq "go.mod" -or $l -eq "pom.xml") { return "Backend / Service" }
    }
    foreach ($m in $Manifests) {
        $l = $m.ToLower()
        if ($l -eq "pnpm-workspace.yaml") { return "Existing Monorepo" }
    }
    return "Library / Other"
}

# ---------------------------------------------------------------------------
# Already-known paths (from consolidated inventory) are excluded so the output
# contains only newly found projects
# ---------------------------------------------------------------------------
$known = @{}
$consolidated = Join-Path $OutputDir "consolidated-inventory.json"
if (Test-Path -LiteralPath $consolidated) {
    try {
        $doc = Get-Content -LiteralPath $consolidated -Raw | ConvertFrom-Json
        $arr = if ($doc.PSObject.Properties.Name -contains "projects") { @($doc.projects) }
               elseif ($doc -is [array]) { @($doc) } else { @() }
        foreach ($p in $arr) {
            $path = [string](if ($p.PSObject.Properties.Name -contains "fullPath") { $p.fullPath } else { $p.FullPath })
            if ($path) { $known[$path.ToLower()] = $true }
        }
    }
    catch {
        Write-Host "WARNING: could not read consolidated inventory: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------
Write-Host "DEEP SCAN" -ForegroundColor Cyan
Write-Host "Depth limit : $Depth" -ForegroundColor Gray

$scannedLocations = [System.Collections.Generic.List[string]]::new()
$findings = [System.Collections.Generic.List[object]]::new()
$dupSkipped = 0
$errorCount = 0

foreach ($loc in $Locations) {
    if (-not (Test-Path -LiteralPath $loc)) {
        Write-Host "SKIP (not found): $loc" -ForegroundColor Yellow
        continue
    }

    $scannedLocations.Add($loc)
    Write-Host "Scanning $loc -Depth $Depth" -ForegroundColor Cyan

    try {
        $items = Get-ChildItem -LiteralPath $loc -Recurse -Depth $Depth -Force -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR scanning $loc : $($_.Exception.Message)" -ForegroundColor Red
        $errorCount++
        continue
    }

    $files = @($items | Where-Object { -not $_.PSIsContainer })
    $dirManifests = @{}

    foreach ($f in $files) {
        $dir = $f.DirectoryName
        if (Test-DirNoise $dir) { continue }
        if (-not (Is-ManifestFile $f.Name)) { continue }
        if (-not $dirManifests.ContainsKey($dir)) {
            $dirManifests[$dir] = [System.Collections.Generic.List[string]]::new()
        }
        $dirManifests[$dir].Add($f.Name)
    }

    foreach ($dir in $dirManifests.Keys) {
        if ($known.ContainsKey($dir.ToLower())) {
            $dupSkipped++
            continue
        }

        $mrefs = @($dirManifests[$dir])
        $stack = Infer-Stack $mrefs
        $cat   = Infer-Category $mrefs
        $git   = Test-Path -LiteralPath (Join-Path $dir ".git")
        $remote = ""
        if ($git -and (Get-Command git -ErrorAction SilentlyContinue)) {
            $remote = (& git -C $dir remote get-url origin 2>$null | Out-String).Trim()
        }
        $name = Split-Path $dir -Leaf
        if ([string]::IsNullOrEmpty($name)) { $name = $dir }

        $findings.Add([PSCustomObject]@{
            name                 = $name
            fullPath             = $dir
            stack                = $stack
            category             = $cat
            markers              = ($mrefs -join ", ")
            gitRepo              = $git
            remote               = $remote
            suggestedServiceName = (New-SuggestedServiceName $name)
        })
    }
}

# ---------------------------------------------------------------------------
# Write deep-scan-findings.json
# ---------------------------------------------------------------------------
$out = [PSCustomObject]@{
    generatedAt       = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    depth             = $Depth
    locationsScanned  = @($scannedLocations)
    totalFound        = $findings.Count
    duplicatesSkipped = $dupSkipped
    scanErrors        = $errorCount
    findings          = @($findings)
}

$out | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonOut -Encoding UTF8

# ---------------------------------------------------------------------------
# Console summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "DEEP SCAN COMPLETE" -ForegroundColor Cyan
Write-Host "Locations scanned    : $($scannedLocations.Count)"
Write-Host "Newly found projects : $($findings.Count)"
Write-Host "Already known        : $dupSkipped  (skipped, already in consolidated inventory)"
Write-Host "Scan errors          : $errorCount"
Write-Host "Output               : $jsonOut"
Write-Host ""
$findings | Sort-Object fullPath |
    Format-Table name, fullPath, stack, category, gitRepo, suggestedServiceName -AutoSize |
    Out-String | Write-Host
