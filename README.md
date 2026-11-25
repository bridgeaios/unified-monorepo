# Unified Monorepo

Consolidated home for all discovered projects, with a unified frontend GUI and backend API gateway.

## Structure

```
unified-monorepo/
├── apps/              # Unified Frontend GUI & API Gateway
│   ├── dashboard/     # Frontend: project launcher, dashboard, logs, configuration
│   └── api-gateway/   # Backend: auth, routing, orchestration, health checks
├── services/          # Migrated project services (project-001, project-002, ...)
├── packages/          # Shared libraries (shared-ui, shared-types, api-client)
├── infrastructure/    # Docker, monitoring, secrets
├── scripts/           # discover, migrate, launch
└── docs/              # PROJECT_INVENTORY.md (scan source of truth)
```

## Principles

- **Read-only discovery**: The scanner never modifies original projects.
- **Preserve Git history**: Each migrated service keeps its original `.git` history.
- **No overwrites**: Original projects remain untouched in their original locations.
- **Identify conflicts**: Port and dependency conflicts are logged before migration.

## Getting Started

1. Run the project scanner: `powershell -NoProfile -ExecutionPolicy Bypass -File ..\Discover-Projects.ps1`
2. Review `docs/PROJECT_INVENTORY.md` and `projects.json`
3. Analyze inventory: `pnpm discover:analyze`
4. Migrate projects: `pnpm migrate:project <path>`
5. Launch unified stack: `pnpm launch`
