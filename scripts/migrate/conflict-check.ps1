#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Conflict check for migrated services under services/.
#
# Scans each service's package.json, requirements.txt, .env, .env.example,
# *.js, *.ts and *.py files for:
#   * port declarations ("port": 3000, "PORT": 5000, app.listen(3000),
#     PORT=3000, --port 3000, ...)
#   * dependency declarations (package.json dependencies/devDependencies,
#     requirements.txt name==version pins)
#
# Reports port collisions between services and duplicate dependency names
# declared with different versions. Writes conflict-report.json.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$MonoRepoRoot,
    [string]$ReportPath
)

if (-not $PSBoundParameters.ContainsKey('MonoRepoRoot')) {
    $MonoRepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
}
$servicesDir = Join-Path $MonoRepoRoot "services"
if (-not $PSBoundParameters.ContainsKey('ReportPath')) {
    $ReportPath = Join-Path $PSScriptRoot "conflict-report.json"
}

# ---- Port declaration regexes (case-insensitive) --------------------------
$portRegexes = @(
    '"port"\s*:\s*(\d+)',
    '"PORT"\s*:\s*(\d+)',
    'port\s*:\s*(\d+)',
    'app\.listen\s*\(\s*(\d+)',
    'listen\s*\(\s*(\d+)',
    'PORT\s*=\s*(\d+)',
    'port\s*=\s*(\d+)',
    '--port\s+(\d+)'
)

# Files scanned for ports
$portScanFilters = @('package.json', 'requirements.txt', '.env', '.env.example', '*.js', '*.ts', '*.py')

# ---- Collect per-service data ---------------------------------------------
$serviceInfos = New-Object System.Collections.Generic.List[pscustomobject]

if (-not (Test-Path -LiteralPath $servicesDir -PathType Container)) {
    Write-Host "No services directory found at $servicesDir" -ForegroundColor Yellow
}

foreach ($svcDir in (Get-ChildItem -LiteralPath $servicesDir -Directory)) {
    $serviceName = $svcDir.Name

    $ports = New-Object 'System.Collections.Generic.HashSet[string]'
    $deps  = @{}

    # --- scan files for ports -------------------------------------------
    foreach ($filter in $portScanFilters) {
        Get-ChildItem -LiteralPath $svcDir.FullName -Filter $filter -File -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    $content = Get-Content -Raw -LiteralPath $_.FullName -ErrorAction Stop
                    foreach ($rx in $portRegexes) {
                        [regex]::Matches($content, $rx, 'IgnoreCase') |
                            ForEach-Object { $null = $ports.Add($_.Groups[1].Value) }
                    }
                } catch {
                    # ignore unreadable files
                }
            }
    }

    # --- package.json dependencies --------------------------------------
    $pkgJson = Join-Path $svcDir.FullName "package.json"
    if (Test-Path -LiteralPath $pkgJson -PathType Leaf) {
        try {
            $pkg = Get-Content -Raw -LiteralPath $pkgJson -ErrorAction Stop |
                ConvertFrom-Json -ErrorAction Stop
            foreach ($propName in @('dependencies', 'devDependencies')) {
                $depObj = $pkg.$propName
                if ($null -ne $depObj) {
                    foreach ($prop in $depObj.PSObject.Properties) {
                        $deps[$prop.Name] = $prop.Value.ToString()
                    }
                }
            }
        } catch {
            Write-Warning "Could not parse $pkgJson : $_"
        }
    }

    # --- requirements.txt -----------------------------------------------
    $reqTxt = Join-Path $svcDir.FullName "requirements.txt"
    if (Test-Path -LiteralPath $reqTxt -PathType Leaf) {
        try {
            Get-Content -LiteralPath $reqTxt -ErrorAction Stop |
                Where-Object { $_ -match '^\s*([A-Za-z0-9_.\-]+)\s*(==|===)\s*([^\s#]+)' } |
                ForEach-Object {
                    $name  = $Matches[1]
                    $ver   = $Matches[3]
                    if (-not $deps.ContainsKey($name)) { $deps[$name] = $ver }
                }
        } catch {
            Write-Warning "Could not read $reqTxt : $_"
        }
    }

    $serviceInfos.Add([pscustomobject]@{
        Service = $serviceName
        Path    = $svcDir.FullName
        Ports   = @($ports | Sort-Object)
        Deps    = $deps
    })
}

# ---- Port collisions ------------------------------------------------------
$portToServices = @{}
foreach ($s in $serviceInfos) {
    foreach ($port in $s.Ports) {
        if (-not $portToServices.ContainsKey($port)) {
            $portToServices[$port] = New-Object 'System.Collections.Generic.List[string]'
        }
        $null = $portToServices[$port].Add($s.Service)
    }
}
$portCollisions = foreach ($entry in $portToServices.GetEnumerator()) {
    if ($entry.Value.Count -gt 1) {
        [pscustomobject]@{
            port    = [int]$entry.Key
            services = @($entry.Value)
        }
    }
}
$portCollisions = @($portCollisions | Sort-Object port)

# ---- Dependency conflicts -------------------------------------------------
$depToServiceVersions = @{}
foreach ($s in $serviceInfos) {
    foreach ($name in $s.Deps.Keys) {
        if (-not $depToServiceVersions.ContainsKey($name)) {
            $depToServiceVersions[$name] = @{}
        }
        $depToServiceVersions[$name][$s.Service] = $s.Deps[$name]
    }
}
$dependencyConflicts = foreach ($entry in $depToServiceVersions.GetEnumerator()) {
    $versions = @($entry.Value.Values | Select-Object -Unique)
    if ($versions.Count -gt 1) {
        [pscustomobject]@{
            name     = $entry.Key
            versions = $entry.Value
        }
    }
}
$dependencyConflicts = @($dependencyConflicts | Sort-Object name)

# ---- Report ---------------------------------------------------------------
$report = @{
    generatedAt     = (Get-Date -Format o)
    monoRepoRoot    = $MonoRepoRoot
    servicesScanned = $serviceInfos.Count
    portCollisions  = $portCollisions
    dependencyConflicts = $dependencyConflicts
    summary         = @{
        portCollisions     = $portCollisions.Count
        dependencyConflicts = $dependencyConflicts.Count
    }
}
$report | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportPath -Encoding UTF8

# ---- Console output -------------------------------------------------------
Write-Host "=== Service conflict check ===" -ForegroundColor Cyan
Write-Host ("Services scanned: {0}" -f $serviceInfos.Count)
Write-Host ("Report written to: $ReportPath")

if ($portCollisions.Count -gt 0) {
    Write-Host ""
    Write-Host "PORT COLLISIONS:" -ForegroundColor Red
    foreach ($c in $portCollisions) {
        Write-Host ("  port {0} used by: {1}" -f $c.port, ($c.services -join ', ')) -ForegroundColor Red
    }
} else {
    Write-Host "No port collisions detected." -ForegroundColor Green
}

if ($dependencyConflicts.Count -gt 0) {
    Write-Host ""
    Write-Host "DEPENDENCY CONFLICTS (same name, different versions):" -ForegroundColor Red
    foreach ($c in $dependencyConflicts) {
        $detail = ($c.versions.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }) -join ', '
        Write-Host ("  {0}: {1}" -f $c.name, $detail) -ForegroundColor Red
    }
} else {
    Write-Host "No dependency version conflicts detected." -ForegroundColor Green
}

exit 0
