/**
 * Generated API client for calling the unified API gateway.
 */

interface ServiceInfo {
  name: string;
  url: string;
  stack: string;
  category: string;
  port: number;
  status: string;
  gitRepo: string;
  remote: string;
  migratedAt: string;
}

interface HealthCheck {
  status: 'healthy' | 'unhealthy' | 'degraded';
  timestamp: string;
  service: string;
}

interface RegisterServicePayload {
  name: string;
  url: string;
  stack?: string;
  category?: string;
  port?: number;
  gitRepo?: string;
  remote?: string;
}

class ApiClient {
  private baseUrl: string;

  constructor(baseUrl = 'http://localhost:4000') {
    this.baseUrl = baseUrl.replace(/\/+$/, '');
  }

  private async request<T>(input: RequestInfo, init?: RequestInit): Promise<T> {
    const res = await fetch(input, init);
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new Error(
        `API request failed: ${res.status} ${res.statusText}${body ? ` - ${body}` : ''}`
      );
    }
    return res.json() as Promise<T>;
  }

  async getServices(): Promise<ServiceInfo[]> {
    return this.request<ServiceInfo[]>(`${this.baseUrl}/services`);
  }

  async registerService(payload: RegisterServicePayload): Promise<ServiceInfo> {
    return this.request<ServiceInfo>(`${this.baseUrl}/services/register`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
  }

  async checkHealth(serviceUrl: string): Promise<HealthCheck> {
    const url = new URL(serviceUrl);
    return this.request<HealthCheck>(`${url.origin}/health`);
  }
}

export default new ApiClient('http://localhost:4000');
export { ApiClient };
