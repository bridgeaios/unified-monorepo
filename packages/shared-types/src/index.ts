/**
 * Shared TypeScript types across frontend and backend.
 */

/**
 * Describes a single migrated project service.
 */
export interface ServiceInfo {
  name: string;
  url: string;
  stack: string;
  category: string;
  port: number;
  status: 'online' | 'offline' | 'degraded' | 'migrating';
  gitRepo: string;
  remote: string;
  migratedAt: string;
}

/**
 * Snapshot of a project discovered during inventory analysis.
 */
export interface ProjectInventory {
  name: string;
  fullPath: string;
  stack: string;
  category: string;
  markers: string[];
  gitRepo: string;
  remote: string;
}

/**
 * Outcome of migrating a single project/service.
 */
export interface MigrationResult {
  serviceName: string;
  sourcePath: string;
  status: 'pending' | 'in-progress' | 'completed' | 'failed';
  notes: string[];
}

/**
 * Result of a health check against a service.
 */
export interface HealthCheck {
  status: 'healthy' | 'unhealthy' | 'degraded';
  timestamp: string;
  service: string;
}
