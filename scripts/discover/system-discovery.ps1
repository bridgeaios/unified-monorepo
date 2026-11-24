#!/usr/bin/env pwsh
# =============================================================================
# system-discovery.ps1
#
# System-level discovery for the unified monorepo. Goes beyond manifest files to
# find Windows services, IIS sites / app pools, Docker containers / images,
# installed programs, and startup apps that should be linked into the monorepo.
#
# Output: E:\AOE\unified-monorepo\docs\system-discovery.json
# =============================================================================

$ErrorActionPreference = "Continue"

# Resolve paths relative to this script so it works from any working directory.
$scriptDir    = $PSScriptRoot
$monorepoRoot = Resolve-Path (Join-Path $scriptDir "..\..")
$docsDir      = Join-Path $monorepoRoot "docs"
$outputJson   = Join-Path $docsDir "system-discovery.json"

if (-not (Test-Path -LiteralPath $docsDir)) {
    New-Item -ItemType Directory -LiteralPath $docsDir -Force | Out-Null
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

function Get-BindingPort {
    param([string]$BindingInfo)
    # IIS bindingInformation looks like ":80:" or "*:443:example.com".
    # Splitting on ':' yields [.., port, ..] -> port is index 1.
    if ([string]::IsNullOrWhiteSpace($BindingInfo)) { return $null }
    $parts = $BindingInfo -split ':'
    if ($parts.Count -ge 2 -and [string]::IsNullOrWhiteSpace($parts[1]) -eq $false) {
        return $parts[1]
    }
    return $null
}

# ---------------------------------------------------------------------------
# Discovery container
# ---------------------------------------------------------------------------
$discovery = [PSCustomObject]@{
    generatedAt       = (Get-Date).ToString("o")
    generator         = "system-discovery.ps1"
    sourceMachine     = $env:COMPUTERNAME
    services          = @()
    iisSites          = @()
    iisAppPools       = @()
    dockerContainers  = @()
    dockerImages      = @()
    installedPrograms = @()
    startupApps       = @()
}

$counts = @{}

Write-Host "=== SYSTEM DISCOVERY ===" -ForegroundColor Cyan
Write-Host ("Machine : {0}" -f $env:COMPUTERNAME) -ForegroundColor Gray
Write-Host ("Output  : {0}" -f $outputJson) -ForegroundColor Gray
Write-Host ""

# =============================================================================
# 1. Windows services (StartType == Automatic AND Status == Running)
# =============================================================================
try {
    Write-Host "[1/6] Enumerating Windows services ..." -ForegroundColor Cyan
    # Get-Service supplies Name/DisplayName/Status. Win32_Service supplies
    # StartType (StartMode) and PathName, which Get-Service does not expose.
    $running = Get-Service | Where-Object { $_.Status -eq 'Running' }
    $cim     = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop

    $svcList = foreach ($s in $running) {
        $c = $cim | Where-Object { $_.Name -eq $s.Name } | Select-Object -First 1
        [PSCustomObject]@{
            Name        = Get-SafeString $s.Name
            DisplayName = Get-SafeString $s.DisplayName
            Status      = Get-SafeString $s.Status
            StartType   = if ($c) { Get-SafeString $c.StartMode } else { $null }
            PathName    = if ($c) { Get-SafeString $c.PathName } else { $null }
        }
    } | Where-Object { $_.StartType -eq 'Auto' }

    if ($null -eq $svcList) { $svcList = @() }
    $discovery.services = $svcList
    $counts["services"] = $svcList.Count
    Write-Host ("  services: {0}" -f $svcList.Count) -ForegroundColor Green
}
catch {
    Write-Warning "[1/6] Failed to enumerate services: $_"
    $counts["services"] = 0
}

# =============================================================================
# 2. IIS sites (requires WebAdministration module)
# =============================================================================
$iisAvailable = $false
try {
    Write-Host "[2/6] Checking IIS (WebAdministration) ..." -ForegroundColor Cyan
    if (Get-Module -ListAvailable WebAdministration -ErrorAction SilentlyContinue) {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        $iisAvailable = $true
    }
    if ($iisAvailable) {
        $sites = @(Get-Website -ErrorAction SilentlyContinue)
        $siteList = foreach ($site in $sites) {
            $bindings = @($site.bindings | ForEach-Object { Get-SafeString $_.bindingInformation })
            [PSCustomObject]@{
                Name         = Get-SafeString $site.name
                PhysicalPath = Get-SafeString $site.physicalPath
                Bindings     = $bindings
                Port         = ($bindings | ForEach-Object { Get-BindingPort $_ } | Where-Object { $_ }) | Select-Object -First 1
            }
        }
        if ($null -eq $siteList) { $siteList = @() }
        $discovery.iisSites = $siteList
        $counts["iisSites"] = $siteList.Count
        Write-Host ("  iisSites: {0}" -f $siteList.Count) -ForegroundColor Green
    }
    else {
        Write-Host "  WebAdministration module not available — skipping IIS sites." -ForegroundColor Yellow
        $counts["iisSites"] = 0
    }
}
catch {
    Write-Warning "[2/6] Failed to enumerate IIS sites: $_"
    $counts["iisSites"] = 0
}

# =============================================================================
# 3. IIS app pools (requires WebAdministration module)
# =============================================================================
try {
    if ($iisAvailable) {
        Write-Host "[3/6] Enumerating IIS app pools ..." -ForegroundColor Cyan
        $pools = @(Get-ChildItem IIS:\AppPools\* -ErrorAction SilentlyContinue)
        $poolList = foreach ($p in $pools) {
            [PSCustomObject]@{
                Name           = Get-SafeString $p.name
                State          = Get-SafeString $p.state
                RuntimeVersion = Get-SafeString $p.managedRuntimeVersion
                PipelineMode   = Get-SafeString $p.managedPipelineMode
            }
        }
        if ($null -eq $poolList) { $poolList = @() }
        $discovery.iisAppPools = $poolList
        $counts["iisAppPools"] = $poolList.Count
        Write-Host ("  iisAppPools: {0}" -f $poolList.Count) -ForegroundColor Green
    }
    else {
        $counts["iisAppPools"] = 0
    }
}
catch {
    Write-Warning "[3/6] Failed to enumerate IIS app pools: $_"
    $counts["iisAppPools"] = 0
}

# =============================================================================
# 4. Docker containers + images (requires docker in PATH)
# =============================================================================
try {
    Write-Host "[4/6] Checking Docker ..." -ForegroundColor Cyan
    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if ($dockerCmd) {
        # --- containers ------------------------------------------------------
        $rawContainers = & docker ps -a --format json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($rawContainers)) {
            $rawContainers = & docker ps -a --format "{{json .}}" 2>$null
        }
        $contList = @()
        foreach ($line in ($rawContainers -split "`n" | Where-Object { $_.Trim() })) {
            try {
                $c = $line | ConvertFrom-Json -ErrorAction Stop
                $contList += [PSCustomObject]@{
                    Id        = Get-SafeString $c.ID
                    Names     = Get-SafeString $c.Names
                    Image     = Get-SafeString $c.Image
                    Ports     = Get-SafeString $c.Ports
                    Status    = Get-SafeString $c.Status
                }
            }
            catch { /* skip malformed lines */ }
        }
        if ($null -eq $contList) { $contList = @() }
        $discovery.dockerContainers = $contList
        $counts["dockerContainers"] = $contList.Count
        Write-Host ("  dockerContainers: {0}" -f $contList.Count) -ForegroundColor Green

        # --- images ----------------------------------------------------------
        $rawImages = & docker images --format json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($rawImages)) {
            $rawImages = & docker images --format "{{json .}}" 2>$null
        }
        $imgList = @()
        foreach ($line in ($rawImages -split "`n" | Where-Object { $_.Trim() })) {
            try {
                $i = $line | ConvertFrom-Json -ErrorAction Stop
                $imgList += [PSCustomObject]@{
                    ID          = Get-SafeString $i.ID
                    Repository  = Get-SafeString $i.Repository
                    Tag         = Get-SafeString $i.Tag
                    Size        = Get-SafeString $i.Size
                }
            }
            catch { /* skip malformed lines */ }
        }
        if ($null -eq $imgList) { $imgList = @() }
        $discovery.dockerImages = $imgList
        $counts["dockerImages"] = $imgList.Count
        Write-Host ("  dockerImages: {0}" -f $imgList.Count) -ForegroundColor Green
    }
    else {
        Write-Host "  docker not found in PATH — skipping containers/images." -ForegroundColor Yellow
        $counts["dockerContainers"] = 0
        $counts["dockerImages"] = 0
    }
}
catch {
    Write-Warning "[4/6] Failed to enumerate Docker: $_"
    $counts["dockerContainers"] = 0
    $counts["dockerImages"] = 0
}

# =============================================================================
# 5. Installed programs via registry uninstall keys
# =============================================================================
try {
    Write-Host "[5/6] Enumerating installed programs (registry) ..." -ForegroundColor Cyan
    $uninstallPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $progList = @()
    $keys = @(Get-ChildItem -LiteralPath $uninstallPath -ErrorAction SilentlyContinue)
    foreach ($k in $keys) {
        try {
            $it = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $it -or [string]::IsNullOrWhiteSpace(Get-SafeString $it.DisplayName)) { continue }
            $progList += [PSCustomObject]@{
                DisplayName    = Get-SafeString $it.DisplayName
                DisplayVersion = Get-SafeString $it.DisplayVersion
                InstallLocation= Get-SafeString $it.InstallLocation
                Publisher      = Get-SafeString $it.Publisher
            }
        }
        catch { /* skip individual key failures */ }
    }
    if ($null -eq $progList) { $progList = @() }
    $discovery.installedPrograms = $progList
    $counts["installedPrograms"] = $progList.Count
    Write-Host ("  installedPrograms: {0}" -f $progList.Count) -ForegroundColor Green
}
catch {
    Write-Warning "[5/6] Failed to enumerate installed programs: $_"
    $counts["installedPrograms"] = 0
}

# =============================================================================
# 6. Startup apps (HKCU + HKLM Run keys)
# =============================================================================
try {
    Write-Host "[6/6] Enumerating startup apps (Run keys) ..." -ForegroundColor Cyan
    $runPaths = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
    )
    $startList = @()
    foreach ($rp in $runPaths) {
        if (-not (Test-Path -LiteralPath $rp -ErrorAction SilentlyContinue)) { continue }
        try {
            $props = Get-ItemProperty -LiteralPath $rp -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            $skip = @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')
            foreach ($name in $props.PSObject.Properties.Name) {
                if ($name -in $skip) { continue }
                $startList += [PSCustomObject]@{
                    Name   = Get-SafeString $name
                    Command= Get-SafeString $props.$name
                    Source = $rp
                }
            }
        }
        catch { /* skip individual key failures */ }
    }
    if ($null -eq $startList) { $startList = @() }
    $discovery.startupApps = $startList
    $counts["startupApps"] = $startList.Count
    Write-Host ("  startupApps: {0}" -f $startList.Count) -ForegroundColor Green
}
catch {
    Write-Warning "[6/6] Failed to enumerate startup apps: $_"
    $counts["startupApps"] = 0
}

# =============================================================================
# Write output JSON
# =============================================================================
$discovery | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $outputJson -Encoding UTF8

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== SYSTEM DISCOVERY SUMMARY ===" -ForegroundColor Cyan
Write-Host ("{0,-22} : {1}" -f "services",           $counts["services"])
Write-Host ("{0,-22} : {1}" -f "iisSites",          $counts["iisSites"])
Write-Host ("{0,-22} : {1}" -f "iisAppPools",       $counts["iisAppPools"])
Write-Host ("{0,-22} : {1}" -f "dockerContainers",  $counts["dockerContainers"])
Write-Host ("{0,-22} : {1}" -f "dockerImages",      $counts["dockerImages"])
Write-Host ("{0,-22} : {1}" -f "installedPrograms", $counts["installedPrograms"])
Write-Host ("{0,-22} : {1}" -f "startupApps",       $counts["startupApps"])
Write-Host ("{0,-22} : {1}" -f "output",          $outputJson) -ForegroundColor Green
Write-Host "DISCOVERY COMPLETE" -ForegroundColor Cyan
