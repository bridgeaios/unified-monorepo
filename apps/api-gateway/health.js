'use strict';

const http = require('node:http');

const HEALTH_TIMEOUT_MS = 5000;

/**
 * Fetch the /health endpoint of a single service with a timeout.
 * Returns a normalized health result object. Never throws.
 */
async function fetchServiceHealth(service) {
  const start = Date.now();
  try {
    const url = new URL(`${service.url.replace(/\/$/, '')}/health`);
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), HEALTH_TIMEOUT_MS);

    const response = await fetch(url, {
      signal: controller.signal,
      method: 'GET',
    });
    clearTimeout(timeoutId);

    const body = await response.json();
    const responseTimeMs = Date.now() - start;

    return {
      status: body.status || 'healthy',
      timestamp: new Date().toISOString(),
      service: service.name,
      responseTimeMs,
      details: body,
    };
  } catch (err) {
    return {
      status: 'unhealthy',
      timestamp: new Date().toISOString(),
      service: service.name,
      responseTimeMs: Date.now() - start,
      details: null,
      error: err.message,
    };
  }
}

/**
 * Aggregated health across all services.
 */
async function getHealthStatus(services) {
  const results = await Promise.all(services.map(fetchServiceHealth));

  const unhealthyCount = results.filter((r) => r.status === 'unhealthy').length;
  const overall = unhealthyCount === 0
    ? 'healthy'
    : unhealthyCount === results.length
      ? 'unhealthy'
      : 'degraded';

  return {
    status: overall,
    timestamp: new Date().toISOString(),
    servicesCount: results.length,
    healthyCount: results.filter((r) => r.status === 'healthy').length,
    unhealthyCount,
    results,
  };
}

/**
 * Register health-check routes on the Express app.
 * - GET /health              gateway self health + service count
 * - GET /health/all          aggregated health of all services
 * - GET /health/:name        individual service health (proxied)
 * - GET /health/ready        Kubernetes readiness probe
 * - GET /health/live         Kubernetes liveness probe
 */
function registerHealthRoutes(app, services) {
  app.get('/health', (_req, res) => {
    res.json({
      status: 'ok',
      service: 'api-gateway',
      timestamp: new Date().toISOString(),
      servicesCount: services.length,
    });
  });

  app.get('/health/all', async (_req, res) => {
    const health = await getHealthStatus(services);
    res.status(health.status === 'healthy' ? 200 : 503).json(health);
  });

  app.get('/health/:serviceName', async (req, res) => {
    const { serviceName } = req.params;
    const service = services.find((s) => s.name === serviceName);
    if (!service) {
      return res.status(404).json({ error: `Service not found: ${serviceName}` });
    }
    const health = await fetchServiceHealth(service);
    res.status(health.status === 'healthy' ? 200 : 503).json(health);
  });

  app.get('/health/ready', (_req, res) => {
    res.json({ status: 'ready', service: 'api-gateway', timestamp: new Date().toISOString() });
  });

  app.get('/health/live', (_req, res) => {
    res.json({ status: 'live', service: 'api-gateway', timestamp: new Date().toISOString() });
  });
}

module.exports = {
  getHealthStatus,
  fetchServiceHealth,
  registerHealthRoutes,
  HEALTH_TIMEOUT_MS,
};
