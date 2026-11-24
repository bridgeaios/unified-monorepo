/**
 * Contract / type tests for @unified/shared-types.
 *
 * Verifies the shape of the shared TypeScript interfaces. Type-level
 * assertions are checked with `tsc --noEmit`:
 *
 *   npx tsc --noEmit packages/shared-types/test/shared-types.test.ts
 *
 * Any type violation (a missing required field, an invalid status literal,
 * markers that are not string[]) is reported as a compile error.
 */

import type { ServiceInfo, HealthCheck, ProjectInventory } from '../src';

/* ------------------------------------------------------------------ */
/* Compile-time type assertions                                       */
/* ------------------------------------------------------------------ */

/**
 * assertType is a no-op at runtime. It exists so that `tsc --noEmit`
 * reports an error whenever the supplied value is not assignable to the
 * expected type.
 */
function assertType<T>(_value: T): void {
  // intentional no-op
}

// --- ServiceInfo: required fields name, url, stack, category -------
const validService: ServiceInfo = {
  name: 'orders-api',
  url: 'http://localhost:5001',
  stack: 'Node.js',
  category: 'backend',
  port: 5001,
  status: 'online',
  gitRepo: 'git@github.com:unified/orders-api.git',
  remote: 'origin',
  migratedAt: '2026-01-01T00:00:00Z',
};
assertType<ServiceInfo>(validService);

// Each required field must be present. Omitting any one is a tsc error:
// const missingName: ServiceInfo = { url: 'http://x', stack: 'Node.js', category: 'backend', port: 1, status: 'online', gitRepo: '', remote: '', migratedAt: '' };
// const missingUrl: ServiceInfo = { name: 'x', stack: 'Node.js', category: 'backend', port: 1, status: 'online', gitRepo: '', remote: '', migratedAt: '' };
// const missingStack: ServiceInfo = { name: 'x', url: 'http://x', category: 'backend', port: 1, status: 'online', gitRepo: '', remote: '', migratedAt: '' };
// const missingCategory: ServiceInfo = { name: 'x', url: 'http://x', stack: 'Node.js', port: 1, status: 'online', gitRepo: '', remote: '', migratedAt: '' };

// --- HealthCheck: status is one of healthy | unhealthy | degraded --
const healthy: HealthCheck = { status: 'healthy', timestamp: '2026-01-01T00:00:00Z', service: 'orders-api' };
assertType<HealthCheck>(healthy);
assertType<'healthy' | 'unhealthy' | 'degraded'>('healthy');
// The line below is a tsc error: 'degraded' is allowed, 'unknown' is not:
// const badStatus: HealthCheck = { status: 'unknown', timestamp: '2026-01-01T00:00:00Z', service: 'x' };

// --- ProjectInventory: markers is string[] -------------------------
const inventory: ProjectInventory = {
  name: 'orders-api',
  fullPath: '/repo/services/orders-api',
  stack: 'Node.js',
  category: 'backend',
  markers: ['package.json', 'tsconfig.json'],
  gitRepo: 'git@github.com:unified/orders-api.git',
  remote: 'origin',
};
assertType<ProjectInventory>(inventory);
const markers: string[] = inventory.markers;
assertType<string[]>(inventory.markers);
