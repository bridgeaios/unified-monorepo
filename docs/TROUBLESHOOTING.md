# Troubleshooting — Unified Monorepo

Common issues, symptoms, causes, and solutions.

---

## 1. Gateway won't start

**Symptom:** `pwsh ./scripts/launch/launch-all.ps1` fails; `http://localhost:4000` unreachable.

**Cause:**
- Port 4000 already in use.
- Missing `node_modules` (run `pnpm install`).
- Syntax error in `apps/api-gateway/index.js`.

**Solution:**
```powershell
# Check what's on port 4000
netstat -ano | findstr :4000

# Install dependencies
pnpm install

# Start gateway alone
cd apps/api-gateway && node index.js
```

**Verification:** `curl http://localhost:4000/health` returns `{ "status": "ok" }`.

---

## 2. Dashboard can't reach gateway

**Symptom:** Dashboard shows empty service list or connection errors.

**Cause:**
- `VITE_API_URL` not pointing to `http://localhost:4000`.
- CORS blocking the request.
- Gateway not running.

**Solution:**
```powershell
# Confirm gateway is up
curl http://localhost:4000/services

# Check dashboard env (apps/dashboard/.env or .env.local)
VITE_API_URL=http://localhost:4000

# Restart dashboard
pnpm --filter dashboard dev
```

**Verification:** Dashboard loads and shows registered services.

---

## 3. Service not appearing in list

**Symptom:** Migrated service exists under `services/` but not in the dashboard list.

**Cause:**
- Service not registered with the gateway (`services.json`).
- Wrong URL/port in registry.

**Solution:**
```powershell
# Check current registry
curl http://localhost:4000/services

# Register the service
Invoke-RestMethod -Method Post -Uri http://localhost:4000/services/register `
  -Body @{ name='project-foo'; url='http://localhost:4001'; stack='Node.js'; category='Backend'; port=4001 } `
  -ContentType 'application/json'
```

**Verification:** Service appears in `GET /services` and on the dashboard.

---

## 4. Port collision

**Symptom:** `conflict-check.ps1` reports two services on the same port; gateway rejects registration.

**Cause:** Two services assigned the same port (4001–4999).

**Solution:**
```powershell
# Run conflict check
pwsh ./scripts/migrate/conflict-check.ps1

# Auto-resolve conflicts
pwsh ./scripts/migrate/resolve-conflicts.ps1 -AutoAssign

# Or manually assign via port-allocator
pwsh ./scripts/migrate/port-allocator.ps1
```

Then update `services.json` and restart affected services.

**Verification:** `conflict-check.ps1` exits 0; each service has a unique port.

---

## 5. Git history not preserved

**Symptom:** Migrated service has no `migrated-from-original` branch.

**Cause:**
- Source project had no `.git` directory.
- `git fetch` from source failed.
- `migrate-project.ps1` git block hit an error (logged as warning).

**Solution:**
```powershell
# Check if source is a git repo
Test-Path <source-path>\.git

# Link history manually
pwsh ./scripts/migrate/link-project-git-history.ps1 `
  -ServicePath services/project-foo `
  -OriginalRepoUrl https://github.com/org/original-repo.git
```

**Verification:** `git -C services/project-foo branch` shows `migrated-from-original` (or `original-history`).

---

## 6. Docker build fails

**Symptom:** `docker-compose up --build` fails for a service.

**Cause:**
- Wrong base image for the stack.
- Missing `Dockerfile` in build context.
- `package.json` / `requirements.txt` not copied.

**Solution:**
```powershell
# Regenerate Dockerfiles from inventory
pwsh ./scripts/discover/generate-docker.ps1

# Rebuild
docker-compose -f infrastructure/docker/docker-compose.yml up --build
```

Check `infrastructure/docker/docker-generation-report.json` for per-service results.

---

## 7. Migration script fails

**Symptom:** `migrate-project.ps1` or `migrate-all.ps1` exits non-zero.

**Cause:**
- Source path doesn't exist or isn't readable.
- Destination already exists (skipped, not an error).
- Disk space or permission issues.

**Solution:**
- Verify source path: `Test-Path <source-path>`
- Check `migration-summary.json` for per-project errors.
- Re-run `migrate-all.ps1`; already-migrated services are skipped.

---

## 8. Rollback a migration

**Symptom:** A migrated service is broken and needs to be removed.

**Procedure (see `docs/RUNBOOK.md`):**

1. Unregister from gateway:
   ```powershell
   Invoke-RestMethod -Method Post -Uri http://localhost:4000/services/unregister `
     -Body @{ name='project-foo' } -ContentType 'application/json'
   ```
2. Remove the service directory:
   ```powershell
   Remove-Item -Recurse -Force services\project-foo
   ```
3. Remove the row from `docs/MERGED_PROJECTS.md`.
4. Commit and push.

Original project is unaffected (migration was read-only on the source).
