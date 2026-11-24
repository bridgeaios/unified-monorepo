# Merged Projects — Migration Tracking Template

**Purpose:** Track every project migrated into the unified monorepo. One row per project.  
**Owner:** Platform Engineering (placeholder)  
**Last updated:** 2026-11-19

---

## Merged Projects

| Project | Original Path | Monorepo Path | Stack | Port | Git Remote | Migration Date | Status |
|---------|---------------|---------------|-------|------|------------|----------------|--------|
| api-gateway | E:\AOE\apps\api-gateway | apps/api-gateway | Node.js/Express | 4000 | (monorepo) | 2026-11-19 | Active |
| dashboard | E:\AOE\apps\dashboard | apps/dashboard | Node.js/Vite/React | 3000 | (monorepo) | 2026-11-19 | Active |
| example-project | E:\AOE\projects\example-project | services/example-project | Python/Django | 4001 | https://git.example.com/example-project.git | 2026-11-19 | Active |

---

## Instructions for Adding New Rows

After each migration, add a row to this table:

1. **Copy the last row** as a template, or use the header row format above.
2. **Project:** the service name used in the gateway (e.g. `project-example-project`).
3. **Original Path:** full path to the project before migration (read-only source location).
4. **Monorepo Path:** `services/<service-name>` for migrated services, or `apps/<name>` for core services.
5. **Stack:** runtime from `projects.json` (e.g. Node.js/Express, Python/Django).
6. **Port:** the port the service listens on (core: 3000/4000; migrated: 4001+).
7. **Git Remote:** URL of the source remote, or `(monorepo)` for core services with no external remote.
8. **Migration Date:** ISO date (YYYY-MM-DD) the migration was completed.
9. **Status:** one of `Active`, `Degraded`, `Retired`, `Rolled back`.
10. Run `pwsh ./scripts/discover/analyze-inventory.ps1` to confirm no port/dependency conflicts.
11. Commit the updated table with the migration PR.

---

## Status Definitions

| Status | Meaning |
|--------|---------|
| Active | Service is healthy and registered with the gateway. |
| Degraded | Service is running but has known issues (see `docs/TROUBLESHOOTING.md`). |
| Retired | Service is decommissioned; row kept for historical reference. |
| Rolled back | Migration was reverted; see `docs/RUNBOOK.md` § Rollback Procedure. |

---

## Related Docs

- `docs/API_REFERENCE.md` — gateway endpoint reference
- `docs/RUNBOOK.md` — operations runbook (adding projects, rollback)
- `docs/ARCHITECTURE.md` — component and data-flow diagrams
- `docs/TROUBLESHOOTING.md` — common issues and fixes
- `docs/MIGRATION_GUIDE.md` — how to migrate projects into the monorepo
