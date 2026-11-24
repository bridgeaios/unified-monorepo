'use strict';

const fs = require('fs');
const path = require('path');

const REGISTRY_PATH = path.join(__dirname, 'services.json');

/**
 * Read the service registry from disk. Falls back to an empty registry
 * if the file is missing or corrupt so the gateway can still boot.
 */
function readRegistry() {
  try {
    if (!fs.existsSync(REGISTRY_PATH)) {
      return { services: [] };
    }
    const data = fs.readFileSync(REGISTRY_PATH, 'utf8');
    const parsed = JSON.parse(data);
    if (!parsed || !Array.isArray(parsed.services)) {
      return { services: [] };
    }
    return parsed;
  } catch (err) {
    return { services: [] };
  }
}

/**
 * Atomically write the registry to disk.
 * Writes to a temp file first, then replaces services.json (unlink + rename
 * to stay Windows-safe, since rename-over-existing can fail there).
 */
function writeRegistry(registry) {
  const tmpPath = REGISTRY_PATH + '.tmp';
  const json = JSON.stringify(registry, null, 2) + '\n';
  fs.writeFileSync(tmpPath, json, 'utf8');
  if (fs.existsSync(REGISTRY_PATH)) {
    fs.unlinkSync(REGISTRY_PATH);
  }
  fs.renameSync(tmpPath, REGISTRY_PATH);
}

/**
 * Extract the port from a service URL (e.g. http://localhost:4001 -> 4001).
 * Returns null when the URL has no explicit port.
 */
function extractPort(url) {
  try {
    const parsed = new URL(url);
    if (parsed.port) {
      return parseInt(parsed.port, 10);
    }
    return parsed.protocol === 'https:' ? 443 : 80;
  } catch (err) {
    return null;
  }
}

/**
 * Return the full list of registered services.
 */
function getServices() {
  return readRegistry().services;
}

/**
 * Register a new service. Validates that the name is unique and that no
 * other service is already bound to the same port (parsed from `url`).
 */
function registerService(name, url, stack, category) {
  if (!name || !url) {
    throw new Error('Service name and url are required');
  }

  const services = getServices();

  if (services.some((svc) => svc.name === name)) {
    throw new Error(`Service already registered: ${name}`);
  }

  const port = extractPort(url);
  if (port !== null) {
    const conflict = services.find((svc) => {
      const existingPort = extractPort(svc.url);
      return existingPort !== null && existingPort === port;
    });
    if (conflict) {
      throw new Error(`Port conflict: port ${port} is already in use by "${conflict.name}"`);
    }
  }

  const service = {
    name,
    url,
    stack: stack || null,
    category: category || null,
    port,
    registeredAt: new Date().toISOString(),
  };

  services.push(service);
  writeRegistry({ services });
  return service;
}

/**
 * Remove a service by name. Throws if the service is not found.
 */
function unregisterService(name) {
  const services = getServices();
  const index = services.findIndex((svc) => svc.name === name);
  if (index === -1) {
    throw new Error(`Service not found: ${name}`);
  }
  const removed = services.splice(index, 1)[0];
  writeRegistry({ services });
  return removed;
}

module.exports = {
  getServices,
  registerService,
  unregisterService,
  REGISTRY_PATH,
};
