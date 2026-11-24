# API Reference — Unified API Gateway

**Base URL:** `http://localhost:4000`

**Authentication:** None (internal network). Future versions may add API keys or OAuth.

## Endpoints

| Method | Path | Description | Request Body | Response |
|--------|------|-------------|--------------|----------|
| GET | `/health` | Gateway self health + service count | — | `{ status, service, timestamp, servicesCount }` |
| GET | `/services` | List all registered services | — | `{ services: [...] }` |
| POST | `/services/register` | Register a new service | `{ name, url, stack, category, port }` | `{ service, message }` |
| POST | `/services/unregister` | Remove a service | `{ name }` | `{ service, message }` |
| GET | `/services/:name/health` | Proxy a service's `/health` endpoint | — | Service's health response |
| GET | `/health/all` | Aggregated health of all registered services | — | `{ status, timestamp, servicesCount, results: [...] }` |
| GET | `/health/ready` | Kubernetes readiness probe | — | `{ status: 'ready', ... }` |
| GET | `/health/live` | Kubernetes liveness probe | — | `{ status: 'live', ... }` |

### Service object

```json
{
  "name": "project-example",
  "url": "http://localhost:4001",
  "stack": "Node.js",
  "category": "Backend / Service",
  "port": 4001,
  "registeredAt": "2026-11-19T00:00:00.000Z"
}
```

### Error response format

```json
{
  "error": "string describing the error",
  "statusCode": 400
}
```

### Status codes

| Code | Meaning |
|------|---------|
| 200 | OK |
| 201 | Created (service registered) |
| 400 | Bad request (missing required fields) |
| 404 | Not found (service not registered) |
| 409 | Conflict (duplicate service name or port) |
| 503 | Service unavailable (aggregated health unhealthy) |

## Examples

### Register a service

```bash
curl -X POST http://localhost:4000/services/register \
  -H "Content-Type: application/json" \
  -d '{"name":"project-foo","url":"http://localhost:4001","stack":"Python","category":"Backend / Service","port":4001}'
```

Response:
```json
{
  "service": { "name": "project-foo", "url": "http://localhost:4001", "stack": "Python", "category": "Backend / Service", "port": 4001 },
  "message": "Registered project-foo -> http://localhost:4001"
}
```

### List all services

```bash
curl http://localhost:4000/services
```

### Check all service health

```bash
curl http://localhost:4000/health/all
```

### Proxy to a service

The gateway mounts each registered service at `/<service-name>`:

```bash
curl http://localhost:4000/project-foo/health
```

## Proxy routes

Each registered service is proxied at `GET /<service-name>/*` → `service.url/*`.
For example, a service registered at `http://localhost:4001` is reachable via
`http://localhost:4000/project-foo/`.
