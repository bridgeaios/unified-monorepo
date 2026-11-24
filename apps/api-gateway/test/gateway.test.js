'use strict';

/**
 * API Gateway integration tests.
 *
 * Spins up a real, in-process Express gateway bound to a dedicated test port
 * (4099) so it never collides with a dev gateway running on :4000. No external
 * network calls are made: the /services/:name/health proxy route is only
 * exercised for an unknown service, which returns 404 before any proxying.
 *
 * Usage:
 *   node apps/api-gateway/test/gateway.test.js
 *   (also loadable by Jest via the root jest.config.js)
 */

const http = require('http');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const REGISTRY_PATH = path.join(__dirname, '..', 'services.json');
const TEST_PORT = 4099;
const BASE = `http://localhost:${TEST_PORT}`;

// Force the gateway onto a test port before loading the module (module load
// starts app.listen()).
process.env.PORT = String(TEST_PORT);
require('../index'); // starts the gateway server

let passed = 0;
let failed = 0;

function resetRegistry() {
  fs.writeFileSync(REGISTRY_PATH, JSON.stringify({ services: [] }, null, 2) + '\n', 'utf8');
}

function request({ method, path: p, body }) {
  return new Promise((resolve, reject) => {
    const url = new URL(p, BASE);
    const payload = body ? JSON.stringify(body) : null;
    const opts = {
      hostname: url.hostname,
      port: url.port,
      path: url.pathname + url.search,
      method,
      headers: payload
        ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload).toString() }
        : {},
    };
    const req = http.request(opts, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => {
        let parsed;
        try {
          parsed = data.length ? JSON.parse(data) : null;
        } catch {
          parsed = data;
        }
        resolve({ statusCode: res.statusCode, headers: res.headers, body: parsed, raw: data });
      });
    });
    req.on('error', reject);
    req.setTimeout(5000, () => req.destroy(new Error('request timed out')));
    if (payload) req.write(payload);
    req.end();
  });
}

async function waitForGateway(timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await request({ method: 'GET', path: '/health' });
      if (res.statusCode === 200) return;
    } catch {
      // gateway not listening yet
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('gateway did not start on port ' + TEST_PORT + ' in time');
}

async function run(name, fn) {
  process.stdout.write(`    - ${name} ... `);
  try {
    await fn();
    passed += 1;
    console.log('ok');
  } catch (err) {
    failed += 1;
    console.log('FAIL');
    console.log(`      ${err.message}`);
  }
}

(async () => {
  await waitForGateway();

  const originalRegistry = fs.existsSync(REGISTRY_PATH)
    ? fs.readFileSync(REGISTRY_PATH, 'utf8')
    : null;

  try {
    // --- suite ---
    await run('GET /health returns 200 with { status: "ok" }', async () => {
      const res = await request({ method: 'GET', path: '/health' });
      assert.strictEqual(res.statusCode, 200);
      assert.strictEqual(res.body.status, 'ok');
    });

    await run('GET /services returns 200 with services array', async () => {
      await resetRegistry();
      const res = await request({ method: 'GET', path: '/services' });
      assert.strictEqual(res.statusCode, 200);
      assert.ok(Array.isArray(res.body.services));
    });

    await run('POST /services/register valid body returns 201 and adds service', async () => {
      await resetRegistry();
      const res = await request({
        method: 'POST',
        path: '/services/register',
        body: { name: 'orders-api', url: 'http://localhost:5001', stack: 'Node.js', category: 'backend', port: 5001 },
      });
      assert.strictEqual(res.statusCode, 201);
      assert.strictEqual(res.body.service.name, 'orders-api');
      assert.strictEqual(res.body.service.url, 'http://localhost:5001');
      const list = await request({ method: 'GET', path: '/services' });
      assert.ok(list.body.services.some((s) => s.name === 'orders-api'));
    });

    await run('POST /services/register duplicate name returns 409', async () => {
      await resetRegistry();
      await request({
        method: 'POST',
        path: '/services/register',
        body: { name: 'duplicate-api', url: 'http://localhost:5002', stack: 'Node.js', category: 'backend' },
      });
      const res = await request({
        method: 'POST',
        path: '/services/register',
        body: { name: 'duplicate-api', url: 'http://localhost:5003', stack: 'Node.js', category: 'backend' },
      });
      assert.strictEqual(res.statusCode, 409);
    });

    await run('POST /services/register missing required fields returns 400', async () => {
      await resetRegistry();
      const res = await request({
        method: 'POST',
        path: '/services/register',
        body: { url: 'http://localhost:5004' }, // missing name
      });
      assert.strictEqual(res.statusCode, 400);
    });

    await run('POST /services/unregister valid name returns 200', async () => {
      await resetRegistry();
      await request({
        method: 'POST',
        path: '/services/register',
        body: { name: 'retire-api', url: 'http://localhost:5005', stack: 'Go', category: 'infra' },
      });
      const res = await request({ method: 'POST', path: '/services/unregister', body: { name: 'retire-api' } });
      assert.strictEqual(res.statusCode, 200);
      assert.strictEqual(res.body.service.name, 'retire-api');
      const list = await request({ method: 'GET', path: '/services' });
      assert.ok(!list.body.services.some((s) => s.name === 'retire-api'));
    });

    await run('POST /services/unregister unknown name returns 404', async () => {
      await resetRegistry();
      const res = await request({ method: 'POST', path: '/services/unregister', body: { name: 'no-such-service' } });
      assert.strictEqual(res.statusCode, 404);
    });

    await run('GET /services/:name/health unknown service returns 404', async () => {
      await resetRegistry();
      const res = await request({ method: 'GET', path: '/services/no-such-service/health' });
      assert.strictEqual(res.statusCode, 404);
      assert.ok(res.body.error || res.raw);
    });
  } finally {
    // Restore the registry so tests leave no side effects on services.json.
    if (originalRegistry !== null) {
      fs.writeFileSync(REGISTRY_PATH, originalRegistry, 'utf8');
    } else {
      try {
        fs.unlinkSync(REGISTRY_PATH);
      } catch {
        /* ignore */
      }
    }
  }

  console.log('');
  console.log(`Gateway tests: ${passed} passed, ${failed} failed`);

  const isDirect = require.main === module;
  if (isDirect) {
    process.exit(failed > 0 ? 1 : 0);
  } else {
    process.exitCode = failed > 0 ? 1 : 0;
  }
})();
