#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Initialize the unified monorepo as a GitHub repository and push it.
# Preserves existing Git history; does not touch original projects.
#
# Parameters:
#   -GitHubRepoUrl   (Mandatory) GitHub repository URL
#   -GitHubToken     Optional PAT for authenticated push
#   -MonoRepoRoot    Monorepo root (default: auto-resolved)
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubRepoUrl,

    [string]$GitHubToken,

    [string]$MonoRepoRoot
)

$ErrorActionPreference = "Continue"

if (-not $PSBoundParameters.ContainsKey('MonoRepoRoot')) {
    $MonoRepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
}

# ---- Check git is installed -----------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: git is not installed or not on PATH." -ForegroundColor Red
    exit 1
}

Push-Location $MonoRepoRoot

try {
    # ---- Init git repo if needed -----------------------------------------
    if (-not (Test-Path -LiteralPath (Join-Path $MonoRepoRoot ".git") -PathType Container)) {
        Write-Host "Initializing git repository..." -ForegroundColor Cyan
        git init -q
        Write-Host "Git repository initialized." -ForegroundColor Green
    } else {
        Write-Host "Git repository already initialized." -ForegroundColor Green
    }

    # ---- .gitignore -------------------------------------------------------
    $gitignore = Join-Path $MonoRepoRoot ".gitignore"
    $ignoreContent = @"
# Dependencies
node_modules/
.pnp/
.pnp.js

# Build outputs
dist/
build/
.next/
.nuxt/
.turbo/
.cache/
coverage/

# Environment
.env
.env.local
.env.*.local

# Logs
*.log
npm-debug.log*
yarn-debug.log*
yarn-error.log*

# OS
.DS_Store
Thumbs.db

# IDE
.vscode/
.idea/
*.swp
*.swo

# Python
__pycache__/
*.pyc
.venv/
venv/

# Rust
target/
.cargo/

# Java
.gradle/
.classpath
.project
.settings/

# Go
vendor/

# Docker
.dockerignore

# Migration records (keep in repo, but ignore local overrides)
MIGRATION.md

"@
    if (-not (Test-Path -LiteralPath $gitignore)) {
        $ignoreContent | Set-Content -Path $gitignore -Encoding UTF8
        Write-Host ".gitignore created." -ForegroundColor Green
    } else {
        Write-Host ".gitignore already exists." -ForegroundColor Green
    }

    # ---- Add all files -----------------------------------------------------
    git add -A

    # ---- Initial commit ----------------------------------------------------
    $hasChanges = $false
    $diff = git diff --cached --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { $hasChanges = $true }

    if ($hasChanges) {
        git commit -q -m "chore: initialize unified monorepo"
        Write-Host "Initial commit created." -ForegroundColor Green
    } else {
        Write-Host "No changes to commit." -ForegroundColor Yellow
    }

    # ---- Configure remote --------------------------------------------------
    $remoteUrl = $GitHubRepoUrl
    if ($GitHubToken) {
        # Insert token into HTTPS URL for authentication
        if ($remoteUrl -match '^https://github\.com/(.+)$') {
            $remoteUrl = "https://x-access-token:$GitHubToken@github.com/$($Matches[1])"
        }
    }

    $existing = git remote 2>$null
    if ($existing -contains 'origin') {
        git remote set-url origin $remoteUrl 2>$null | Out-Null
        Write-Host "Remote 'origin' updated." -ForegroundColor Green
    } else {
        git remote add origin $remoteUrl 2>$null | Out-Null
        Write-Host "Remote 'origin' added." -ForegroundColor Green
    }

    # ---- Push --------------------------------------------------------------
    Write-Host "Pushing to main..." -ForegroundColor Cyan
    git branch -M main
    git push -u origin main 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Push failed. Check your GitHub token and repository URL." -ForegroundColor Red
        exit 1
    }

    Write-Host "`n=== GitHub Repo Initialized ===" -ForegroundColor Cyan
    Write-Host ("Repository: $GitHubRepoUrl")
    Write-Host ("Branch: main")
    Write-Host ("Root: $MonoRepoRoot")

}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}
finally {
    Pop-Location
}
