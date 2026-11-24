/**
 * Thin fetch wrapper around the API gateway (http://localhost:4000).
 * All functions throw on non-ok responses so callers can handle errors uniformly.
 */
const baseUrl = 'http://localhost:4000';

async function request(path, options = {}) {
  const res = await fetch(`${baseUrl}${path}`, {
    headers: {
      'Content-Type': 'application/json',
      ...options.headers,
    },
    ...options,
  });

  // 204 No Content has no body to parse.
  if (res.status === 204) return null;

  if (!res.ok) {
    let message = `Request failed: ${res.status}`;
    try {
      const text = await res.text();
      if (text) message = text;
    } catch {
      // ignore body read errors
    }
    throw new Error(message);
  }

  const contentType = res.headers.get('content-type') || '';
  if (contentType.includes('application/json')) return res.json();
  return res.text();
}

/**
 * Fetch the list of registered services from the gateway.
 * Tolerates both an array body and { services: [...] } shapes.
 */
export function getServices() {
  return request('/services').then(data => {
    if (Array.isArray(data)) return data;
    if (data && Array.isArray(data.services)) return data.services;
    if (data && Array.isArray(data.items)) return data.items;
    return [];
  });
}

/**
 * Register a new service with the gateway.
 * @param {Object} service - { name, url, stack, category, port }
 */
export function registerService(service) {
  return request('/services', {
    method: 'POST',
    body: JSON.stringify(service),
  });
}

/**
 * Check the health of a service by hitting its /health endpoint.
 * @param {string} serviceUrl - base URL of the service, e.g. http://localhost:5001
 * @param {number} timeoutMs - abort timeout in milliseconds
 */
export function checkHealth(serviceUrl, timeoutMs = 5000) {
  const url = String(serviceUrl).replace(/\/$/, '') + '/health';
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  return fetch(url, { signal: controller.signal })
    .then(async res => {
      clearTimeout(timer);
      if (!res.ok) {
        throw new Error(`Health check failed: ${res.status}`);
      }
      const contentType = res.headers.get('content-type') || '';
      if (contentType.includes('application/json')) return res.json();
      return { status: 'ok', raw: await res.text() };
    })
    .catch(err => {
      clearTimeout(timer);
      throw err;
    });
}

export { baseUrl };
