#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Link a migrated service's Git history to its original repository.
# Fetches the original remote (read-only), creates an original-history branch,
# and merges it into the service's working tree with --allow-unrelated-histories.
#
# Parameters:
#   -ServicePath      (Mandatory) Path to the service under services/
#   -OriginalRepoUrl  (Mandatory) Original project's Git remote URL
#   -MonoRepoRoot     Monorepo root (default: auto-resolved)
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServicePath,

    [Parameter(Mandatory = $true)]
    [string]$OriginalRepoUrl,

    [string]$MonoRepoRoot
)

$ErrorActionPreference = "Continue"

if (-not $PSBoundParameters.ContainsKey('MonoRepoRoot')) {
    $MonoRepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
}

# Resolve service path (relative to monorepo root or absolute)
if (-not [System.IO.Path]::IsPathRooted($ServicePath)) {
    $ServicePath = Join-Path $MonoRepoRoot $ServicePath
}

if (-not (Test-Path -LiteralPath $ServicePath -PathType Container)) {
    Write-Host "ERROR: Service path not found: $ServicePath" -ForegroundColor Red
    exit 1
}

$serviceName = Split-Path $ServicePath -Leaf
Push-Location $ServicePath

try {
    # Ensure git is initialized
    if (-not (Test-Path -LiteralPath (Join-Path $ServicePath ".git") -PathType Container)) {
        Write-Host "Initializing git in service directory..." -ForegroundColor Cyan
        git init -q
    }

    # Add original remote (read-only fetch)
    $remotes = git remote 2>$null
    if ($remotes -notcontains 'original') {
        git remote add original $OriginalRepoUrl 2>$null | Out-Null
        Write-Host "Added remote 'original' -> $OriginalRepoUrl" -ForegroundColor Green
    } else {
        git remote set-url original $OriginalRepoUrl 2>$null | Out-Null
        Write-Host "Updated remote 'original'." -ForegroundColor Green
    }

    # Fetch all branches/tags from original
    Write-Host "Fetching original history..." -ForegroundColor Cyan
    $fetchOut = git fetch original 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "git fetch from original returned non-zero: $fetchOut"
    }

    # Determine original default branch
    $defaultBranch = $null
    $headRef = git symbolic-ref refs/remotes/original/HEAD 2>$null
    if ($headRef) {
        $defaultBranch = ($headRef -replace '^refs/remotes/original/', '').Trim()
    }
    if (-not $defaultBranch) {
        $first = (git branch -r 2>$null |
            Where-Object { $_.Trim() -like 'original/*' } |
            Select-Object -First 1)
        if ($first) {
            $defaultBranch = (($first.Trim()) -replace '^original/', '').Trim()
        }
    }
    if (-not $defaultBranch) { $defaultBranch = 'master' }

    # Create local branch original-history from original's default branch
    $originBranch = "refs/remotes/original/$defaultBranch"
    if ((git rev-parse --verify --quiet $originBranch 2>$null)) {
        git branch -f original-history $originBranch 2>$null | Out-Null
    } elseif ((git rev-parse --verify --quiet FETCH_HEAD 2>$null)) {
        git branch -f original-history FETCH_HEAD 2>$null | Out-Null
    } else {
        Write-Warning "No fetchable branches found in $OriginalRepoUrl; history branch not created."
        exit 1
    }

    # Merge original-history into current branch with --allow-unrelated-histories
    Write-Host "Merging original history into current branch..." -ForegroundColor Cyan
    $mergeOut = git merge original-history --allow-unrelated-histories --no-commit -m "preserve: original git history for $serviceName" 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Merge may have conflicts; attempt to commit anyway
        Write-Warning "Merge had conflicts or warnings: $mergeOut"
    }
    git add -A 2>$null | Out-Null
    git commit -q -m "preserve: original git history for $serviceName" 2>$null | Out-Null

    # Tag the merge
    $tagName = "original-history-$serviceName"
    git tag -a $tagName -m "Original history for $serviceName from $OriginalRepoUrl" 2>$null | Out-Null

    $commitHash = (git rev-parse --short HEAD 2>$null).Trim()
    Write-Host "`n=== Git History Linked ===" -ForegroundColor Cyan
    Write-Host ("Service:   $serviceName")
    Write-Host ("Branch:    original-history (from $defaultBranch)")
    Write-Host ("Tag:       $tagName")
    Write-Host ("Commit:    $commitHash")

}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}
finally {
    Pop-Location
}
