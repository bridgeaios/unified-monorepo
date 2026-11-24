#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# run-all-tests.ps1
# Unified monorepo test runner.
#
#   1. pnpm --recursive run test --if-present
#   2. node apps\api-gateway\test\gateway.test.js
#   3. scripts\migrate\conflict-check.ps1  (reports port/dependency conflicts)
#
# Prints a pass/fail summary and exits non-zero if any test fails.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$script:total = 0
$script:passed = 0
$script:failed = 0

function Record-Result {
  param([string]$Name, [bool]$Ok, [string]$Detail = '')
  $script:total++
  if ($Ok) {
    $script:passed++
    Write-Host ("PASS  {0} {1}" -f $Name, $Detail) -ForegroundColor Green
  } else {
    $script:failed++
    Write-Host ("FAIL  {0} {1}" -f $Name, $Detail) -ForegroundColor Red
  }
}

$monoRepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Write-Host "=== Unified Monorepo Test Runner ===" -ForegroundColor Cyan
Write-Host ("Root: {0}" -f $monoRepoRoot)
Write-Host ""

# ---------------------------------------------------------------------------
# 1. pnpm --recursive run test --if-present
# ---------------------------------------------------------------------------
Write-Host "→ pnpm --recursive run test --if-present" -ForegroundColor Yellow
$pnpmOut = pnpm --recursive run test --if-present 2>&1
$pnpmOk = $LASTEXITCODE -eq 0
Record-Result 'pnpm recursive test' $pnpmOk
if ($pnpmOut) {
  $pnpmOut | ForEach-Object { if ($_ -match '\S') { Write-Host ("  {0}" -f $_) } }
}

# ---------------------------------------------------------------------------
# 2. API gateway tests (node apps\api-gateway\test\gateway.test.js)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "→ node apps\api-gateway\test\gateway.test.js" -ForegroundColor Yellow
$gwDir = Join-Path $monoRepoRoot 'apps\api-gateway'
Push-Location $gwDir
try {
  $gwOut = & node test\gateway.test.js 2>&1
  $gwOk = $LASTEXITCODE -eq 0
  if ($gwOut) {
    $gwOut | ForEach-Object { if ($_ -match '\S') { Write-Host ("  {0}" -f $_) } }
    # Parse "Gateway tests: N passed, M failed" from the suite output.
    $parsed = $false
    foreach ($line in $gwOut) {
      if ($line -match 'Gateway tests:\s*(?<passed>\d+)\s*passed,\s*(?<failed>\d+)\s*failed') {
        $script:passed += [int]$matches.passed
        $script:failed += [int]$matches.failed
        $script:total  += [int]$matches.passed + [int]$matches.failed
        $parsed = $true
        break
      }
    }
    if (-not $parsed) {
      Record-Result 'gateway tests' $gwOk
    }
  } else {
    Record-Result 'gateway tests' $gwOk
  }
} finally {
  Pop-Location
}

# ---------------------------------------------------------------------------
# 3. Service conflict check (scripts\migrate\conflict-check.ps1)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "→ scripts\migrate\conflict-check.ps1" -ForegroundColor Yellow
$ccReport = Join-Path $monoRepoRoot 'scripts\migrate\conflict-report.json'
$ccOut = & pwsh ./scripts/migrate/conflict-check.ps1 2>&1
$ccOk = $LASTEXITCODE -eq 0
if ($ccOut) {
  $ccOut | ForEach-Object { if ($_ -match '\S') { Write-Host ("  {0}" -f $_) } }
}
$ccDetail = ''
if (Test-Path -LiteralPath $ccReport) {
  try {
    $report = Get-Content -LiteralPath $ccReport -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $ports = @($report.portCollisions).Count
    $deps = @($report.dependencyConflicts).Count
    $ccDetail = "(port collisions: $ports, dependency conflicts: $deps)"
    Write-Host ("  summary: {0}" -f $ccDetail) -ForegroundColor Cyan
  } catch {
    $ccDetail = '(could not parse conflict-report.json)'
  }
}
Record-Result 'service conflict check' $ccOk $ccDetail

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Test Summary ===" -ForegroundColor Cyan
Write-Host ("Total tests: {0}" -f $script:total) -ForegroundColor Cyan
Write-Host ("Passed:      {0}" -f $script:passed) -ForegroundColor Green
Write-Host ("Failed:      {0}" -f $script:failed) -ForegroundColor (if ($script:failed -eq 0) { 'Green' } else { 'Red' })
$exitCode = if ($script:failed -gt 0) { 1 } else { 0 }
Write-Host ("Exit code:   {0}" -f $exitCode) -ForegroundColor (if ($exitCode -eq 0) { 'Green' } else { 'Red' })
exit $exitCode
