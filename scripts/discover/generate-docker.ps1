#!/usr/bin/env pwsh
# ==============================================================================
# generate-docker.ps1
# Generates Dockerfiles + docker-compose entries for every project listed in
# docs/categorized-inventory.json so the whole unified-monorepo can run as
# linked container services.
#
# Input : docs/categorized-inventory.json
# Output: infrastructure/docker/<service-name>/Dockerfile   (one per project)
#         infrastructure/docker/docker-compose.yml          (all services)
#         infrastructure/docker/docker-generation-report.json
#
# Run: pwsh ./scripts/discover/generate-docker.ps1
# ==============================================================================

[CmdletBinding()]
param(
    [string]$InventoryJson = "..\..\docs\categorized-inventory.json",
    [string]$OutputDir     = "..\..\infrastructure\docker",
    [string]$ComposeFile   = "docker-compose.yml",
    [string]$ReportFile    = "docker-generation-report.json"
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# --------------------------------------------------------------------------
# Resolve paths. Allow the script to be invoked from any working directory.
# --------------------------------------------------------------------------
function Resolve-RelativePath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    $candidate = Join-Path $PSScriptRoot $Path
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $Path
}

$inventoryPath = Resolve-RelativePath $InventoryJson
$outputDir     = Resolve-RelativePath $OutputDir
$composePath   = Join-Path $outputDir $ComposeFile
$reportPath    = Join-Path $outputDir $ReportFile
$repoRoot      = Resolve-Path (Join-Path $PSScriptRoot "..\..") | Select-Object -ExpandProperty Path

if (-not (Test-Path -LiteralPath $inventoryPath)) {
    Write-Host "ERROR: categorized-inventory.json not found at $inventoryPath" -ForegroundColor Red
    Write-Host "Run project discovery first, or pass -InventoryJson <path>." -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$inventoryRoot = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
$projects = if ($inventoryRoot.PSObject.Properties.Name -contains "projects") { $inventoryRoot.projects } else { $inventoryRoot }

# --------------------------------------------------------------------------
# Port allocation: core services keep their fixed ports; migrated services
# get the next free port starting at 4001 unless an explicit port is set.
# --------------------------------------------------------------------------
$nextMigratedPort = 4001
$usedPorts = @{}

function Get-ProjectPort($p) {
    if ($p.Port -and [int]$p.Port -gt 0) {
        $port = [int]$p.Port
    } elseif ($p.Name -eq "api-gateway") {
        $port = 4000
    } elseif ($p.Name -eq "dashboard") {
        $port = 3000
    } else {
        while ($usedPorts.ContainsKey($nextMigratedPort)) { $nextMigratedPort++ }
        $port = $nextMigratedPort
        $nextMigratedPort++
    }
    $usedPorts[$port] = $true
    return $port
}

function Get-ComposeServiceName($p) {
    if ($p.SuggestedService -and $p.SuggestedService.Trim()) {
        return $p.SuggestedService
    }
    return ("project-" + ($p.Name -replace '[^a-z0-9]', '-')).ToLower().Trim('-')
}

function Is-CoreService($p) {
    $p.Category -eq "Core Service" -or $p.Name -in @("api-gateway", "dashboard")
}

# --------------------------------------------------------------------------
# Dockerfile snippet helpers
# --------------------------------------------------------------------------
function New-NonRootUserSnippet($stack) {
    switch ($stack) {
        "Node.js" {
            @"
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
RUN chown -R appuser:appgroup /app
USER appuser
"@
        }
        "Python" {
            @"
RUN groupadd -r appgroup && useradd -r -g appgroup appuser
RUN chown -R appuser:appgroup /app
USER appuser
"@
        }
        "Go" {
            @"
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
RUN chown -R appuser:appgroup /app
USER appuser
"@
        }
        "Rust" {
            @"
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
RUN chown -R appuser:appgroup /app
USER appuser
"@
        }
        "Java" {
            @"
RUN groupadd -r appgroup && useradd -r -g appgroup appuser
RUN chown -R appuser:appgroup /app
USER appuser
"@
        }
        ".NET" {
            @"
RUN useradd -m -s /bin/bash appuser
RUN chown -R appuser:appuser /app
USER appuser
"@
        }
        default { "" }
    }
}

function New-HealthcheckSnippet($stack, $port) {
    $cmd = switch ($stack) {
        "Node.js" { "wget --no-verbose --tries=1 --spider http://localhost:${port}/" }
        "Python"  { "python -c `"import urllib.request; urllib.request.urlopen('http://localhost:${port}/health')`"" }
        "Go"      { "wget --no-verbose --tries=1 --spider http://localhost:${port}/" }
        "Rust"    { "wget --no-verbose --tries=1 --spider http://localhost:${port}/" }
        "Java"    { "curl -f http://localhost:${port}/ || exit 1" }
        ".NET"    { "curl -f http://localhost:${port}/ || exit 1" }
        default   { "wget --no-verbose --tries=1 --spider http://localhost:${port}/ || exit 1" }
    }
    @"
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 CMD ${cmd}
"@
}

function New-ComposeHealthcheckTest($stack, $port) {
    switch ($stack) {
        "Node.js" { return @("CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:${port}/") }
        "Python"  { return @("CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:${port}/health')") }
        "Go"      { return @("CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:${port}/") }
        "Rust"    { return @("CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:${port}/") }
        "Java"    { return @("CMD", "curl", "-f", "http://localhost:${port}/") }
        ".NET"    { return @("CMD", "curl", "-f", "http://localhost:${port}/") }
        default   { return @("CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:${port}/") }
    }
}

function New-ComposeEnvironment($p, $port) {
    $env = [System.Collections.Generic.List[string]]::new()
    $env.Add("PORT=${port}")
    switch ($p.Stack) {
        "Node.js" { $env.Add("NODE_ENV=production") }
        "Python"  {
            $env.Add("PYTHONDONTWRITEBYTECODE=1")
            $env.Add("PYTHONUNBUFFERED=1")
        }
        ".NET"    { $env.Add("ASPNETCORE_URLS=http://+:${port}") }
    }
    if ($p.Name -eq "dashboard") { $env.Add("VITE_API_URL=http://api-gateway:4000") }
    return $env
}

# --------------------------------------------------------------------------
# Dockerfile generators per stack
# --------------------------------------------------------------------------
function New-NodeDockerfile($p, $port) {
    @"
FROM node:18-alpine

ENV PORT=${port}
ENV NODE_ENV=production

WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev
COPY . .

EXPOSE ${port}
$(New-HealthcheckSnippet "Node.js" $port)
$(New-NonRootUserSnippet "Node.js")

CMD ["npm", "start"]
"@
}

function New-PythonDockerfile($p, $port) {
    $cmd = if ($p.entrypoint) { '["' + ($p.entrypoint -join '","') + '"]' } else { '["python", "main.py"]' }
    @"
FROM python:3.11-slim

ENV PORT=${port}
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

EXPOSE ${port}
$(New-HealthcheckSnippet "Python" $port)
$(New-NonRootUserSnippet "Python")

CMD ${cmd}
"@
}

function New-GoDockerfile($p, $port, $binary) {
    $binary = if ($binary) { $binary } else { $p.Name }
    @"
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -o /app/bin/${binary} .

FROM alpine:3.18
RUN apk --no-cache add ca-certificates
ENV PORT=${port}
WORKDIR /app
COPY --from=builder /app/bin/${binary} /app/${binary}

EXPOSE ${port}
$(New-HealthcheckSnippet "Go" $port)
$(New-NonRootUserSnippet "Go")

CMD ["/app/${binary}"]
"@
}

function New-RustDockerfile($p, $port, $binary) {
    $binary = if ($binary) { $binary } else { $p.Name }
    @"
FROM rust:1.75 AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
RUN cargo fetch
COPY . .
RUN cargo build --release

FROM alpine:3.18
RUN apk --no-cache add ca-certificates
ENV PORT=${port}
WORKDIR /app
COPY --from=builder /app/target/release/${binary} /app/${binary}

EXPOSE ${port}
$(New-HealthcheckSnippet "Rust" $port)
$(New-NonRootUserSnippet "Rust")

CMD ["/app/${binary}"]
"@
}

function New-JavaDockerfile($p, $port, $artifact) {
    $artifact = if ($artifact) { $artifact } else { "target/*.jar" }
    @"
FROM maven:3.9 AS builder
WORKDIR /app
COPY pom.xml ./
RUN mvn dependency:go-offline
COPY . .
RUN mvn package -DskipTests

FROM openjdk:17-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
ENV PORT=${port}
WORKDIR /app
COPY --from=builder /app/${artifact} /app/app.jar

EXPOSE ${port}
$(New-HealthcheckSnippet "Java" $port)
$(New-NonRootUserSnippet "Java")

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
"@
}

function New-DotnetDockerfile($p, $port, $artifact, $entrypoint) {
    $dll = if ($entrypoint -and $entrypoint.Count -ge 2) { $entrypoint[-1] } else { "${p.Name}.dll" }
    $dll = $dll -replace '^/app/', ''
    @"
FROM mcr.microsoft.com/dotnet/sdk:8 AS builder
WORKDIR /app
COPY *.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:8
ENV PORT=${port}
ENV ASPNETCORE_URLS=http://+:${port}
WORKDIR /app
COPY --from=builder /app/publish .

EXPOSE ${port}
$(New-HealthcheckSnippet ".NET" $port)
$(New-NonRootUserSnippet ".NET")

ENTRYPOINT ["dotnet", "/app/${dll}"]
"@
}

function Generate-Dockerfile($p) {
    $port = Get-ProjectPort $p
    $stack = $p.Stack
    $content = switch ($stack) {
        "Node.js" { New-NodeDockerfile $p $port }
        "Python"  { New-PythonDockerfile $p $port }
        "Go"      { New-GoDockerfile $p $port $p.binary }
        "Rust"    { New-RustDockerfile $p $port $p.binary }
        "Java"    { New-JavaDockerfile $p $port $p.artifact }
        ".NET"    { New-DotnetDockerfile $p $port $p.artifact $p.entrypoint }
        "Docker"  { $null } # handled separately: copy existing Dockerfile
        default   {
            Write-Host "WARNING: unknown stack '$stack' for $($p.Name); falling back to Node.js" -ForegroundColor Yellow
            New-NodeDockerfile $p $port
        }
    }

    $serviceName = Get-ComposeServiceName $p
    $targetDir   = Join-Path $outputDir $serviceName
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    $targetPath  = Join-Path $targetDir "Dockerfile"

    if ($stack -eq "Docker") {
        $sourceDockerfile = Join-Path $repoRoot $p.FullPath "Dockerfile"
        if (Test-Path -LiteralPath $sourceDockerfile) {
            Copy-Item -LiteralPath $sourceDockerfile -Destination $targetPath -Force
            $content = Get-Content -LiteralPath $targetPath -Raw
            Write-Host "COPIED existing Dockerfile for $($p.Name) -> $targetPath" -ForegroundColor Cyan
        } else {
            Write-Host "WARNING: stack is Docker but no Dockerfile at $sourceDockerfile; writing a stub" -ForegroundColor Yellow
            $content = "FROM alpine:3.18`nLABEL generated=stub-for-$($p.Name)`nCMD [`"echo`", `"no source Dockerfile found`"]`n"
            Set-Content -Path $targetPath -Value $content -Encoding UTF8
        }
    } else {
        Set-Content -Path $targetPath -Value $content -Encoding UTF8
        Write-Host "GENERATED $stack Dockerfile for $($p.Name) -> $targetPath" -ForegroundColor Cyan
    }

    return [PSCustomObject]@{
        ProjectName    = $p.Name
        FullPath       = $p.FullPath
        ServiceName    = $serviceName
        Stack          = $stack
        Category       = $p.Category
        Port           = $port
        DockerfilePath = $targetPath
        ComposeService = $serviceName
        Context        = ("..\..\" + $p.FullPath) -replace '\\', '/'
        Status         = "OK"
    }
}

# --------------------------------------------------------------------------
# Generate per-project Dockerfiles
# --------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()
$tableRows = [System.Collections.Generic.List[object]]::new()

foreach ($p in $projects) {
    $result = Generate-Dockerfile $p
    $results.Add($result)
    $tableRows.Add([PSCustomObject]@{
        Service          = $result.ServiceName
        Stack            = $result.Stack
        "Dockerfile Path" = $result.DockerfilePath
        Port             = $result.Port
        "Compose Service Name" = $result.ComposeService
    })
}

# --------------------------------------------------------------------------
# Write docker-compose.yml with every generated service
# --------------------------------------------------------------------------
$composeLines = [System.Collections.Generic.List[string]]::new()

$composeLines.Add("# ----------------------------------------------------------------")
$composeLines.Add("# docker-compose.yml — GENERATED BY scripts/discover/generate-docker.ps1")
$composeLines.Add("# Re-run the generator to regenerate this file from categorized-inventory.json")
$composeLines.Add('# All services run on the shared `unified-net` bridge network.')
$composeLines.Add("# ----------------------------------------------------------------")
$composeLines.Add("")
$composeLines.Add("services:")

foreach ($r in $results) {
    $svc   = $r.ComposeService
    $ctx   = $r.Context
    $dockerfile = "../../infrastructure/docker/${svc}/Dockerfile" -replace '\\', '/'
    $port = $r.Port
    $stack = $r.Stack
    $proj = $projects | Where-Object { (Get-ComposeServiceName $_) -eq $svc } | Select-Object -First 1

    $composeLines.Add("")
    $composeLines.Add("  ${svc}:")
    $composeLines.Add("    build:")
    $composeLines.Add("      context: ${ctx}")
    $composeLines.Add("      dockerfile: ${dockerfile}")
    $composeLines.Add("    ports:")
    $composeLines.Add("      - `"${port}:${port}`"")
    $composeLines.Add("    networks:")
    $composeLines.Add("      - unified-net")

    $env = New-ComposeEnvironment $proj $port
    if ($env.Count) {
        $composeLines.Add("    environment:")
        foreach ($e in $env) { $composeLines.Add("      - `"${e}`"") }
    }

    if (-not (Is-CoreService $proj)) {
        $composeLines.Add("    depends_on:")
        $composeLines.Add("      - api-gateway")
    }

    $test = New-ComposeHealthcheckTest $stack $port
    $testJson = '["' + ($test -join '","') + '"]'
    $composeLines.Add("    healthcheck:")
    $composeLines.Add("      test: ${testJson}")
    $composeLines.Add("      interval: 30s")
    $composeLines.Add("      timeout: 3s")
    $composeLines.Add("      retries: 3")
    $composeLines.Add("      start_period: 10s")
    $composeLines.Add("    restart: unless-stopped")
}

# node_modules shared volumes for Node.js services
$nodeServices = $results | Where-Object { $_.Stack -eq "Node.js" }

$composeLines.Add("")
$composeLines.Add("networks:")
$composeLines.Add("  unified-net:")
$composeLines.Add("    driver: bridge")
$composeLines.Add("    name: unified-net")
$composeLines.Add("")
$composeLines.Add("volumes:")
foreach ($r in $nodeServices) {
    $composeLines.Add("  $($r.ComposeService)_node_modules:")
}
if (-not $nodeServices.Count) {
    $composeLines.Add("  # (no Node.js services — add shared node_modules volumes here)")
}

Set-Content -Path $composePath -Value ($composeLines -join "`n") -Encoding UTF8
Write-Host "" -ForegroundColor Cyan
Write-Host "COMPOSE UPDATED: $composePath" -ForegroundColor Cyan
Write-Host "Services defined: $($results.Count)" -ForegroundColor Cyan

# --------------------------------------------------------------------------
# Write generation report JSON
# --------------------------------------------------------------------------
$report = [PSCustomObject]@{
    generated       = Get-Date -Format "o"
    inventory       = $inventoryPath
    outputDir       = $outputDir
    composeFile     = $composePath
    totalProjects   = $results.Count
    services        = $results
}
$report | ConvertTo-Json -Depth 5 | Set-Content -Path $reportPath -Encoding UTF8
Write-Host "REPORT WRITTEN: $reportPath" -ForegroundColor Cyan

# --------------------------------------------------------------------------
# Print summary table: Service | Stack | Dockerfile Path | Port | Compose Service Name
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "DOCKER GENERATION SUMMARY" -ForegroundColor Cyan
Write-Host "=========================" -ForegroundColor Cyan
$tableRows | Format-Table -AutoSize

Write-Host ""
Write-Host "DOCKER GENERATION COMPLETE" -ForegroundColor Green
Write-Host "Dockerfiles : infrastructure/docker/<service>/Dockerfile" -ForegroundColor Gray
Write-Host "Compose     : infrastructure/docker/docker-compose.yml" -ForegroundColor Gray
Write-Host "Report      : infrastructure/docker/docker-generation-report.json" -ForegroundColor Gray
