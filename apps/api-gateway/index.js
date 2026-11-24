'use strict';

const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const { createProxyMiddleware } = require('http-proxy-middleware');
const { getServices, registerService, unregisterService } = require('./registry');
const logRequest = require('./middleware/log-request');
const { registerHealthRoutes } = require('./health');

const app = express();
const PORT = process.env.PORT || 4000;

app.use(helmet());
app.use(cors());
app.use(express.json());
app.use(logRequest);

// Health check routes (aggregated + per-service)
registerHealthRoutes(app, getServices());

// Full registry
app.get('/services', (req, res) => {
  res.json({ services: getServices() });
});

// Register a new service (body: name, url, stack, category, port)
app.post('/services/register', (req, res) => {
  try {
    const { name, url, stack, category, port } = req.body || {};
    const service = registerService(name, url, stack, category);
    if (port) {
      service.port = parseInt(port, 10);
    }
    res.status(201).json({ service, message: `Registered ${name} -> ${service.url}` });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// Unregister a service (body: name)
app.post('/services/unregister', (req, res) => {
  try {
    const { name } = req.body || {};
    const removed = unregisterService(name);
    res.json({ service: removed, message: `Unregistered ${name}` });
  } catch (err) {
    const status = err.message.startsWith('Service not found') ? 404 : 400;
    res.status(status).json({ error: err.message });
  }
});

// Proxy a service's own /health endpoint: GET /services/:name/health
app.get('/services/:name/health', (req, res, next) => {
  const { name } = req.params;
  const service = getServices().find((svc) => svc.name === name);
  if (!service) {
    return res.status(404).json({ error: `Service not found: ${name}` });
  }
  const proxy = createProxyMiddleware({
    target: service.url,
    changeOrigin: true,
    pathRewrite: { '^/services/[^/]+': '' }, // /services/<name>/health -> /health
  });
  proxy(req, res, next);
});

/**
 * Build dynamic proxy routes from the registry on startup.
 * Each registered service is mounted at /<service-name> -> service.url.
 */
function setupRoutes() {
  const services = getServices();
  for (const svc of services) {
    app.use(`/${svc.name}`, createProxyMiddleware({
      target: svc.url,
      changeOrigin: true,
      pathRewrite: { [`^/${svc.name}`]: '' },
    }));
    console.log(`Proxy route: /${svc.name} -> ${svc.url}`);
  }
}

setupRoutes();

app.listen(PORT, () => {
  console.log(`API Gateway listening on http://localhost:${PORT}`);
});
