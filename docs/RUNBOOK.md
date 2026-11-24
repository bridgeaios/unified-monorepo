# Operations Runbook — Unified Monorepo

**Owner:** Platform Engineering (placeholder)  
**Review cadence:** Quarterly  
**Last updated:** 2026-11-19

This runbook covers day-to-day operations for the unified monorepo system: dashboard, API gateway, and migrated services.

---

## 1. Daily Checks

Perform these checks at the start of each shift / day.

### 1.1 Health Dashboard

1. Open the dashboard at `http://localhost:3000`.
2. Confirm the dashboard loads without console errors.
3. Check the service list shows all expected services (see `docs/MERGED_PROJECTS.md` for the expected roster).
4. Verify no services are marked red/unhealthy.

### 1.2 Gateway Status

Run the gateway health checks:

```bash
curl -s http://localhost:4000/health | pjson
curl -s http://localhost:4000/health/ready | pjson
curl -s http://localhost:4000/health/live | pjson
curl -s http://localhost:4000/health/all | pjson
```

Expected results:
- `/health/ready` → `200 { "status": "ready" }`
- `/health/live` → `200 { "status": "alive" }`
- `/health/all` → `200` with `summary.unhealthy === 0`

### 1.3 Service List

```bash
curl -s http://localhost:4000/services | pjson
```

Compare the returned service list against `docs/MERGED_PROJECTS.md`. Any service listed in the table but missing from `/services` needs investigation (see "Service not appearing in list" in `docs/TROUBLESHOOTING.md`).

**Escalate if:** any core service (dashboard, api-gateway) is unhealthy, or more than one migrated service is down.

---

## 2. Adding a New Project

Follow this step-by-step procedure to bring a new project into the monorepo.

### Step 1: Discover

Run project discovery to scan for candidate projects:

```pwsh
pwsh ./scripts/discover/Discover-Projects.ps1
```

Review the output (`projects.json` / `docs/PROJECT_INVENTORY.md`). Confirm the new project has `Name`, `FullPath`, `Stack`, `Category`, and `GitRepo` populated.

### Step 2: Categorize

Assign the project a category and target service name:

| Field | Guidance |
|-------|----------|
| Category | `Core Service`, `Migrated Service`, `Library`, or `Tool` |
| Service name | `project-<slug>` (e.g. `project-example-project`) |
| Stack | Runtime from `projects.json` (Node.js, Python, Go, .NET, …) |
| Suggested port | `4001+` for migrated services (avoid 3000/4000) |

### Step 3: Migrate

Migrate the project into `services/<service-name>` while preserving Git history:

```pwsh
pwsh ./scripts/migrate/migrate-project.ps1 -SourcePath <path-to-project>
```

Or batch:
```pwsh
pwsh ./scripts/migrate/migrate-all.ps1
```

Verify:
- `services/<service-name>` exists.
- `.git` history is present (run `git -C services/<service-name> log --oneline | head`).
- A `MIGRATION.md` marker exists with source path, date, and service name.

### Step 4: Register

Add a proxy route for the service in `apps/api-gateway/index.js`, then restart the gateway:

```pwsh
pwsh ./scripts/launch/stop-all.ps1
pwsh ./scripts/launch/launch-all.ps1
```

Confirm registration:
```bash
curl -s http://localhost:4000/services | pjson
```

### Step 5: Verify

1. Hit the service's health endpoint through the gateway:
   ```bash
   curl -s http://localhost:4000/services/<service-name>/health | pjson
   ```
2. Confirm the service appears in the dashboard service list.
3. Add a row to `docs/MERGED_PROJECTS.md` (see instructions at the bottom of that file).
4. Re-run `pwsh ./scripts/discover/analyze-inventory.ps1` to update the migration plan.

---

## 3. Handling Port Conflicts

### Detect

Before launch, run the conflict checker:

```pwsh
pwsh ./scripts/discover/analyze-inventory.ps1
```

Or check a specific port:
```pwsh
Get-NetTCPConnection -LocalPort 4000 -State Listen   # gateway
Get-NetTCPConnection -LocalPort 3000 -State Listen   # dashboard
```

Symptom: `launch-all.ps1` reports a service UNHEALTHY, or "port already in use".

### Resolve

1. Stop the stack:
   ```pwsh
   pwsh ./scripts/launch/stop-all.ps1
   ```
2. Identify the process holding the port:
   ```pwsh
   Get-Process -Id (Get-NetTCPConnection -LocalPort <port> -State Listen).OwningProcess
   ```
3. Either stop the conflicting process, or reassign the service to a free port (`4001+` range for services).
4. Update the service's port in `apps/api-gateway/index.js` (proxy route target URL).
5. Restart the stack:
   ```pwsh
   pwsh ./scripts/launch/launch-all.ps1
   ```

### Update Registry

After changing a service's port, re-register it with the gateway:
```bash
curl -X POST http://localhost:4000/services/unregister -H "Content-Type: application/json" -d '{"name":"<service-name>"}'
curl -X POST http://localhost:4000/services/register -H "Content-Type: application/json" -d '{"name":"<service-name>","url":"http://localhost:<new-port>","healthPath":"/health","stack":"<stack>"}'
```

Verify:
```bash
curl -s http://localhost:4000/services/<service-name>/health | pjson
```

---

## 4. Service Down Procedure

When a service is reported down or unhealthy:

### 4.1 Check Logs

- Gateway logs: `%TEMP%\gateway.log` / `%TEMP%\gateway.err`
- Dashboard logs: `%TEMP%\dashboard.log` / `%TEMP%\dashboard.err`
- Launcher log: `%TEMP%\unified-launch.log`
- Service logs: check inside `services/<name>` for runtime logs, or stdout captured by the launcher.

### 4.2 Restart

```pwsh
pwsh ./scripts/launch/stop-all.ps1
pwsh ./scripts/launch/launch-all.ps1
```

For a single service, restart just that service process (or re-register it via the gateway API).

### 4.3 Check Dependencies

Verify the service's dependencies are up:
- Is its database / cache / backing service reachable?
- Is `pnpm install` current at the monorepo root?
- For non-Node services, is the required runtime installed?

### 4.4 Escalate

If the service remains down after restart and dependency checks:

1. Page the on-call engineer (see Emergency Contacts below).
2. Create an incident ticket.
3. If the service is non-critical, proceed with rollback (Section 6) to protect the rest of the stack.

---

## 5. Git History Recovery

Migrated services preserve their original Git history on the `original-history` branch.

### Access the original-history branch

```bash
git -C services/<service-name> branch -a
git -C services/<service-name> log --oneline original-history | head -20
git -C services/<service-name> show original-history --stat
```

### If history is missing

1. Confirm the source project had a `.git` folder before migration.
2. Check the remote is configured:
   ```bash
   git -C services/<service-name> remote -v
   ```
3. Re-run migration to restore history:
   ```pwsh
   pwsh ./scripts/migrate/migrate-project.ps1 -SourcePath <original-path>
   ```
4. Or clone fresh to preserve full remote history:
   ```bash
   git clone <source-url> services/<service-name>
   ```

> Migration is read-only on the source — original projects in their original locations are never modified.

---

## 6. Rollback Procedure

Use this to remove a migrated service from the monorepo (e.g. after a bad migration).

### Step 1: Revert the migration

```bash
git -C services/<service-name> log --oneline -5   # review before removing
```

If the migration commit should be undone within the service repo:
```bash
git -C services/<service-name> revert <migration-commit-sha>
```

### Step 2: Remove from services/

```bash
rm -rf services/<service-name>
```

### Step 3: Unregister from the gateway

```bash
curl -X POST http://localhost:4000/services/unregister \
  -H "Content-Type: application/json" \
  -d '{"name":"<service-name>"}'
```

Then remove the proxy route from `apps/api-gateway/index.js` and restart:
```pwsh
pwsh ./scripts/launch/stop-all.ps1
pwsh ./scripts/launch/launch-all.ps1
```

### Step 4: Update tracking

- Remove the row from `docs/MERGED_PROJECTS.md`.
- Re-run `pwsh ./scripts/discover/analyze-inventory.ps1`.
- Verify the service no longer appears at `GET /services`.

---

## 7. Emergency Contacts / On-Call Rotation

| Role | Name / Slack | Phone / Pager | Hours |
|------|--------------|---------------|-------|
| Primary on-call | TBD | TBD | 08:00–20:00 |
| Secondary on-call | TBD | TBD | 20:00–08:00 |
| Platform Engineering lead | TBD | TBD | Business hours |
| Security escalation | TBD | TBD | 24/7 |

> **Placeholder:** Replace these entries with actual contacts and an on-call rotation schedule (e.g. PagerDuty/Opsgenie integration) before the first production launch.

**Incident severity definitions:**
- **SEV-1:** Core stack (dashboard or api-gateway) down → page primary on-call immediately.
- **SEV-2:** One or more migrated services down, core stack healthy → page primary within 1 hour.
- **SEV-3:** Degraded health / port conflict / documentation gap → handle during business hours.

---

## Related Docs

- `docs/API_REFERENCE.md` — gateway endpoint reference
- `docs/ARCHITECTURE.md` — component and data-flow diagrams
- `docs/TROUBLESHOOTING.md` — common issues and fixes
- `docs/MERGED_PROJECTS.md` — merged project tracking table
- `docs/MIGRATION_GUIDE.md` — how to migrate projects into the monorepo
