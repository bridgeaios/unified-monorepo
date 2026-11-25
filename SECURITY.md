# Security Policy

## Supported Versions

| Version | Supported | Notes |
|---------|-----------|-------|
| 1.0.x   | ✅        | Current stable release |

## Reporting Vulnerabilities

Please disclose security vulnerabilities responsibly. Do **not** open a public
GitHub issue for security concerns.

Contact the platform team through your organization's security channel. Include:

- Description of the vulnerability
- Steps to reproduce
- Affected components (gateway, dashboard, services, packages)
- Suggested fix (if any)

## Secret Management

- **Never commit `.env` files, tokens, or passwords.**
- Use GitHub Secrets / Actions secrets for CI/CD credentials.
- Use Azure DevOps variable groups for Azure Pipelines.
- Local development: create `.env.local` (gitignored) for local overrides.
- The `.gitignore` excludes `*.env`, `.env.local`, and `*.log`.

## Dependency Scanning

- CI runs `pnpm install` with the pnpm store cached.
- `conflict-check.ps1` detects dependency version conflicts across services.
- Shared dependencies should live in `packages/shared-types` to avoid drift.

## Service Isolation

- Original projects are **never modified** — migration is read-only on the source.
- Migrated services run under their own ports (4001–4999) to limit blast radius.
- The API gateway proxies `/<service-name>` to each service URL.
- Docker containers run on `unified-net` bridge network with healthchecks.

## Git History

- Original Git history is preserved on branch `migrated-from-original` per service.
- Remote `origin` points at the read-only source project.
