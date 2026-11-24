#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Port allocator for the unified monorepo.
# Maintains docs/port-registry.json and allocates ports in the 4001-4999 range
# for migrated services (3000 = dashboard, 4000 = api-gateway are reserved).
#
# Parameters:
#   -MonoRepoRoot   Monorepo root (default: auto-resolved)
#   -PortRegistry   Path to port-registry.json (default: docs/port-registry.json)
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$MonoRepoRoot,
    [string]$PortRegistry
)

$ErrorActionPreference = "Continue"

if (-not $PSBoundParameters.ContainsKey('MonoRepoRoot')) {
    $MonoRepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
}
if (-not $PSBoundParameters.ContainsKey('PortRegistry')) {
    $PortRegistry = Join-Path $MonoRepoRoot "docs\port-registry.json"
}

# Reserved ports: dashboard (3000) and api-gateway (4000)
$RESERVED_PORTS = @(3000, 4000)
$PORT_START = 4001
$PORT_END   = 4999

function Load-PortRegistry {
    if (-not (Test-Path -LiteralPath $PortRegistry -PathType Leaf)) {
        return @{ ports = @() }
    }
    try {
        $raw = Get-Content -Raw -LiteralPath $PortRegistry -ErrorAction Stop
        $reg = ConvertFrom-Json $raw -ErrorAction Stop
        if (-not $reg.PSObject.Properties.Name -contains 'ports') {
            $reg = @{ ports = @() }
        }
        return $reg
    } catch {
        Write-Warning "Failed to read port registry: $_"
        return @{ ports = @() }
    }
}

function Save-PortRegistry {
    param([object]$Registry)
    $dir = Split-Path -Parent $PortRegistry
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $Registry | ConvertTo-Json -Depth 5 | Set-Content -Path $PortRegistry -Encoding UTF8
}

function Get-UsedPorts {
    param([object]$Registry)
    @($Registry.ports | ForEach-Object { $_.Port }) | Where-Object { $_ -ne $null }
}

function Test-PortInUse {
    param([int]$Port)
    # Quick TCP check on localhost
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $result = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
        $success = $result.AsyncWaitHandle.WaitOne(100, $false)
        if ($success) {
            $tcp.EndConnect($result)
            $tcp.Close()
            return $true
        }
        $tcp.Close()
        return $false
    } catch {
        return $false
    }
}

function Get-NextAvailablePort {
    param(
        [int]$StartPort = $PORT_START,
        [int]$EndPort   = $PORT_END,
        [array]$Exclude = @()
    )
    $registry = Load-PortRegistry
    $used     = @(Get-UsedPorts $registry) + @($Exclude) + @($RESERVED_PORTS)
    $used     = $used | Sort-Object -Unique

    for ($p = $StartPort; $p -le $EndPort; $p++) {
        if ($used -notcontains $p) {
            if (-not (Test-PortInUse $p)) {
                return $p
            }
        }
    }
    return $null
}

function Reserve-Port {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [string]$Purpose = ''
    )
    $registry = Load-PortRegistry
    if (@($registry.ports | Where-Object { $_.ServiceName -eq $ServiceName })) {
        Write-Warning "Port already reserved for service: $ServiceName"
        return $false
    }
    if (@($registry.ports | Where-Object { $_.Port -eq $Port })) {
        Write-Warning "Port $Port is already reserved"
        return $false
    }
    if (Test-PortInUse $Port) {
        Write-Warning "Port $Port is already in use on localhost"
        return $false
    }

    $entry = [pscustomobject]@{
        ServiceName = $ServiceName
        Port        = $Port
        Purpose     = $Purpose
        reservedAt  = (Get-Date -Format o)
    }
    $registry.ports += $entry
    Save-PortRegistry $registry
    Write-Host ("Reserved port {0} for {1}" -f $Port, $ServiceName) -ForegroundColor Green
    return $true
}

function Release-Port {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )
    $registry = Load-PortRegistry
    $count = $registry.ports.Count
    $registry.ports = @($registry.ports | Where-Object { $_.ServiceName -ne $ServiceName })
    if ($registry.ports.Count -lt $count) {
        Save-PortRegistry $registry
        Write-Host ("Released port reservation for {0}" -f $ServiceName) -ForegroundColor Green
        return $true
    }
    Write-Warning "No port reservation found for service: $ServiceName"
    return $false
}

function Show-PortTable {
    $registry = Load-PortRegistry
    $used = Get-UsedPorts $registry
    Write-Host "`n=== Port Allocations ===" -ForegroundColor Cyan
    if ($registry.ports.Count -eq 0) {
        Write-Host "No ports reserved." -ForegroundColor Yellow
    } else {
        $registry.ports |
            Sort-Object Port |
            Format-Table @{ Name='Port'; Expression={$_.Port} },
                          @{ Name='Service'; Expression={$_.ServiceName} },
                          @{ Name='Purpose'; Expression={$_.Purpose} },
                          @{ Name='Reserved'; Expression={$_.reservedAt} } -AutoSize
    }
    Write-Host ("Reserved (core): {0}" -f ($RESERVED_PORTS -join ', '))
    Write-Host "Available range: {0}-{1}`n" -f $PORT_START, $PORT_END
}

# ---- Entry point ----------------------------------------------------------
if ($PSBoundParameters.ContainsKey('List')) {
    Show-PortTable
    exit 0
}

# Default: show the table when run with no arguments
Show-PortTable
