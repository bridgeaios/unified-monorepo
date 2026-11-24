#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Migrate a single discovered project into the unified monorepo under services/
# Preserves original Git history. Read-only on the source project.
#
# Parameters:
#   -SourcePath      (Mandatory) Full path to the project to migrate
#   -ServiceName     Optional custom service name
#                    (default: project-<sanitized source folder name>)
#   -MonoRepoRoot    Optional; defaults to the unified-monorepo root
#                    (two levels above this script's location)
#
# Exit codes: 0 = success, 1 = failure
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [string]$ServiceName,

    [string]$MonoRepoRoot
)

$ErrorActionPreference = "Stop"

try {
    # Resolve monorepo root (default: two levels above scripts\migrate\)
    if (-not $PSBoundParameters.ContainsKey('MonoRepoRoot')) {
        $MonoRepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    }

    # Validate source
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        Write-Host "ERROR: Source not found: $SourcePath" -ForegroundColor Red
        exit 1
    }

    # Suggest a service name from the source folder name
    if (-not $ServiceName) {
        $leaf = Split-Path $SourcePath -Leaf
        if (-not $leaf -or $leaf -eq '\') { $leaf = "project" }
        $sanitized = ($leaf -replace '[^a-z0-9]+', '-').ToLower().Trim('-')
        if (-not $sanitized) { $sanitized = "project" }
        $ServiceName = "project-$sanitized"
    }

    $dest = Join-Path $MonoRepoRoot "services\$ServiceName"

    Write-Host "Migrating: $SourcePath" -ForegroundColor Cyan
    Write-Host "Destination: $dest" -ForegroundColor Cyan

    # -----------------------------------------------------------------------
    # Skip list: build outputs, dependency caches, and git (handled separately)
    # -----------------------------------------------------------------------
    $skipList = @(
        'node_modules', '.next', '.nuxt', '.venv', 'venv', '__pycache__',
        'dist', 'build', 'target', '.turbo', '.cache', 'coverage',
        '.gradle', '.cargo', '.npm', '.git'
    )

    # 1. Create destination
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    # 2. Copy project files (read-only on the source)
    Get-ChildItem -LiteralPath $SourcePath -Force |
        Where-Object { $skipList -notcontains $_.Name } |
        ForEach-Object {
            $target = Join-Path $dest $_.Name
            if ($_.PSIsContainer) {
                Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
            } else {
                Copy-Item -LiteralPath $_.FullName -Destination $target -Force
            }
        }

    # 3. Preserve Git history if present
    $gitSrc = Join-Path $SourcePath ".git"
    if (Test-Path -LiteralPath $gitSrc) {
        try {
            Write-Host "Preserving Git history..." -ForegroundColor Green
            Push-Location $dest
            git init -q
            if ((git remote 2>$null) -notcontains 'origin') {
                git remote add origin $SourcePath 2>$null | Out-Null
            } else {
                git remote set-url origin $SourcePath 2>$null | Out-Null
            }
            $fetchOut = git fetch origin 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "git fetch from $SourcePath returned non-zero: $fetchOut"
            }

            # Pick the default branch of origin
            $defaultBranch = $null
            $headRef = git symbolic-ref refs/remotes/origin/HEAD 2>$null
            if ($headRef) {
                $defaultBranch = ($headRef -replace '^refs/remotes/origin/', '').Trim()
            }
            if (-not $defaultBranch) {
                $first = (git branch -r 2>$null |
                    Where-Object { $_.Trim() -like 'origin/*' } |
                    Select-Object -First 1)
                if ($first) {
                    $defaultBranch = (($first.Trim()) -replace '^origin/', '').Trim()
                }
            }
            if (-not $defaultBranch) { $defaultBranch = 'master' }

            # Original history lives on branch migrated-from-original
            $originBranch = "refs/remotes/origin/$defaultBranch"
            if ((git rev-parse --verify --quiet $originBranch 2>$null)) {
                git branch -f migrated-from-original $originBranch 2>$null | Out-Null
            } elseif ((git rev-parse --verify --quiet FETCH_HEAD 2>$null)) {
                git branch -f migrated-from-original FETCH_HEAD 2>$null | Out-Null
            } else {
                Write-Warning "No fetchable branches found in $SourcePath; history branch not created."
            }

            # Working tree = copied files, committed as the migrated state
            git add -A
            git diff --cached --quiet 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                git commit -q -m "chore: initial migrated state of $ServiceName"
            }

            Pop-Location
        } catch {
            Write-Warning ("Git preservation failed for {0}: {1}" -f $SourcePath, $_)
        }
    }

    # 4. Stack markers
    $markers = @()
    $stackChecks = @(
        @{ File = 'package.json';                 Label = 'Node.js' },
        @{ File = 'requirements.txt';             Label = 'Python' },
        @{ File = 'pyproject.toml';               Label = 'Python' },
        @{ File = 'Cargo.toml';                   Label = 'Rust' },
        @{ File = 'go.mod';                       Label = 'Go' },
        @{ File = 'pom.xml';                      Label = 'Java' },
        @{ File = 'build.gradle';                 Label = 'Java' },
        @{ File = 'build.gradle.kts';             Label = 'Java/Kotlin' },
        @{ File = '*.csproj';                     Label = '.NET' },
        @{ File = '*.sln';                        Label = '.NET' },
        @{ File = 'composer.json';                Label = 'PHP' },
        @{ File = 'Gemfile';                      Label = 'Ruby' },
        @{ File = 'mix.exs';                      Label = 'Elixir' },
        @{ File = 'pubspec.yaml';                 Label = 'Dart/Flutter' }
    )
    foreach ($check in $stackChecks) {
        $match = Get-ChildItem -LiteralPath $SourcePath -Filter $check.File -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($match) { $markers += $check.Label }
    }

    # 5. MIGRATION.md
    $markerText = @"
# Migration Record

- **Service:** $ServiceName
- **Source:** $SourcePath
- **Destination:** $dest
- **Migrated:** $(Get-Date -Format o)
- **Stack:** $(if ($markers.Count) { $markers -join ', ' } else { 'unknown' })

## Git

Original Git history is preserved on branch `migrated-from-original` (remote `origin` points
at the read-only source: $SourcePath). The working tree contains the copied project files
with build outputs and dependency caches excluded.

## Excluded from copy

$($skipList -join ', ')
"@
    $markerPath = Join-Path $dest "MIGRATION.md"
    $markerText | Set-Content -Path $markerPath -Encoding UTF8

    Write-Host "Migration complete: $dest" -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}
