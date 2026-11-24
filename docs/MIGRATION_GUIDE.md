# Migration Guide

Migrating external projects into the unified monorepo and launching them as one system.

## Prerequisites

- [pnpm](https://pnpm.io) installed (`pnpm --version`)
- PowerShell 7+ (`pwsh`)
- Git

---

## Steps

### Step 1: Run Discover-Projects.ps1

Discovery scans your workspace for projects and writes `projects.json`.

```pwsh
pwsh ./scripts/discover/Discover-Projects.ps1
```

Output: `projects.json` (location configured in the script).

### Step 2: Review projects.json

Open `projects.json` and verify each project has `Name`, `FullPath`, `Stack`,
`Category`, and `GitRepo`. Check for duplicates or paths outside your intended
scope. Edit manually if needed, then re-run discovery to regenerate.

### Step 3: Run analyze-inventory.ps1

Analyzes `projects.json`, detects port/dependency conflicts, and writes a
migration plan.

```pwsh
pwsh ./scripts/discover/analyze-inventory.ps1
```

Outputs:
- `docs/MIGRATION_PLAN.md`
- `docs/migration-plan.json`

Review the plan before migrating.

### Step 4: Run migrate-all.ps1

Migrates all projects in `projects.json` into `services/<service-name>`,
preserving Git history where present.

```pwsh
pwsh ./scripts/migrate/migrate-all.ps1
```

Migrated services are registered as proxy routes in `apps/api-gateway/index.js`.

### Step 5: Run launch-all.ps1

Installs dependencies and starts the full stack (dashboard + api-gateway) as one
system.

```pwsh
pwsh ./scripts/launch/launch-all.ps1
```

Or with custom ports:

```pwsh
pwsh ./scripts/launch/launch-all.ps1 -DashboardPort 3001 -GatewayPort 4001
```

Stop the stack with:

```pwsh
pwsh ./scripts/launch/stop-all.ps1
```

---

## Adding a New Project Manually

1. Copy the project folder into `services/<service-name>`, or run
   `migrate-project.ps1 -SourcePath <path>`.
2. Add a `MIGRATION.md` marker with the source path, date, and service name.
3. Add a proxy route for the service in `apps/api-gateway/index.js`.
4. Add the project to `projects.json` (or re-run `Discover-Projects.ps1`).
5. Re-run `analyze-inventory.ps1` to update the migration plan.
6. Restart the stack with `launch-all.ps1`.

---

## Troubleshooting

### Port conflicts

**Symptom:** `launch-all.ps1` reports a service UNHEALTHY, or the port is already
in use.

- Find what is listening:
  ```pwsh
  Get-NetTCPConnection -LocalPort 3000 -State Listen   # dashboard
  Get-NetTCPConnection -LocalPort 4000 -State Listen   # api-gateway
  ```
- Free the ports:
  ```pwsh
  pwsh ./scripts/launch/stop-all.ps1
  ```
- Or relaunch on different ports:
  ```pwsh
  pwsh ./scripts/launch/launch-all.ps1 -DashboardPort 3001 -GatewayPort 4001
  ```
- For migrated services, pick a port in the 4001+ range and update
  `apps/api-gateway/index.js`.

### Git history

**Symptom:** A migrated service lost its `.git` history.

- `migrate-project.ps1` copies the source `.git` into `services/<name>` and runs
  `git init` + `git remote add origin <source>`. It is read-only on the source.
- If history is missing, the source had no `.git`, or `.git` was excluded by the
  copy filter. Re-run `migrate-project.ps1 -SourcePath <path>`.
- To preserve full remote history, clone rather than copy:
  `git clone <source> services/<name>`.

### Missing dependencies

**Symptom:** `pnpm install` fails, or a service crashes on startup.

- Run `pnpm install` at the monorepo root to sync the workspace.
- Check the service's `package.json` for missing `dependencies` /
  `devDependencies`.
- For non-Node services, ensure the runtime (Python, Go, .NET, etc.) is installed
  and listed in `projects.json` (Stack).

### Logs

- Launcher: `%TEMP%\unified-launch.log`
- API Gateway: `%TEMP%\gateway.log` / `%TEMP%\gateway.err`
- Dashboard: `%TEMP%\dashboard.log` / `%TEMP%\dashboard.err`

Re-run discovery/analyze whenever you change `projects.json`.
