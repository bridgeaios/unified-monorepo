import { useState, useEffect, useRef } from 'react';
import { getServices, checkHealth } from './services/api';
import ServiceList from './components/ServiceList';
import ProjectLauncher from './components/ProjectLauncher';

/**
 * Custom hook: runs `callback` every `delay` milliseconds.
 */
function useInterval(callback, delay) {
  const saved = useRef(callback);

  useEffect(() => {
    saved.current = callback;
  }, [callback]);

  useEffect(() => {
    if (delay == null) return undefined;
    const id = setInterval(() => saved.current(), delay);
    return () => clearInterval(id);
  }, [delay]);
}

function StatCard({ label, value, color }) {
  return (
    <div style={{
      padding: 14,
      borderRadius: 8,
      background: '#fff',
      border: '1px solid #e5e7eb',
      textAlign: 'center',
    }}>
      <div style={{ fontSize: 12, color: '#6b7280', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 6 }}>
        {label}
      </div>
      <div style={{ fontSize: 26, fontWeight: 700, color: color || '#111827' }}>
        {value}
      </div>
    </div>
  );
}

export default function App() {
  const [services, setServices] = useState([]);
  const [gatewayHealth, setGatewayHealth] = useState({ status: 'checking...' });
  const [tab, setTab] = useState('services');

  const fetchServices = async () => {
    try {
      const data = await getServices();
      const list = Array.isArray(data) ? data : (data.services || []);
      setServices(list);
    } catch {
      setServices([]);
    }
  };

  const fetchGatewayHealth = async () => {
    try {
      const data = await checkHealth('http://localhost:4000');
      setGatewayHealth({ status: 'ok', ...data });
    } catch {
      setGatewayHealth({ status: 'offline' });
    }
  };

  // Poll /services every 10 seconds and /health every 5 seconds.
  useEffect(() => {
    fetchServices();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useInterval(fetchServices, 10000);

  useEffect(() => {
    fetchGatewayHealth();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useInterval(fetchGatewayHealth, 5000);

  const handleServiceAdded = () => {
    fetchServices();
    setTab('services');
  };

  const onlineCount = services.filter(s => (s.status || '').toLowerCase() === 'online').length;
  const offlineCount = services.filter(s => (s.status || '').toLowerCase() === 'offline').length;
  const gatewayOnline = gatewayHealth.status === 'ok';

  const tabStyle = active => ({
    padding: '8px 14px',
    borderRadius: 6,
    border: `1px solid ${active ? '#2563eb' : '#e5e7eb'}`,
    background: active ? '#2563eb' : '#fff',
    color: active ? '#fff' : '#374151',
    fontSize: 13,
    fontWeight: 500,
    cursor: 'pointer',
  });

  return (
    <div style={{
      fontFamily: 'system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
      margin: 0,
      background: '#f8fafc',
      minHeight: '100vh',
    }}>
      <header style={{
        background: '#1f2937',
        color: '#fff',
        padding: '18px 24px',
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <span style={{ fontSize: 19, fontWeight: 700 }}>Unified Project Launcher</span>
          <span style={{
            display: 'inline-flex',
            alignItems: 'center',
            gap: 6,
            fontSize: 11.5,
            padding: '2px 8px',
            borderRadius: 999px,
            background: gatewayOnline ? '#16a34a' : '#dc2626',
            color: '#fff',
          }}>
            <span style={{ width: 6, height: 6, borderRadius: '50%', background: '#fff', display: 'inline-block' }} />
            Gateway {gatewayHealth.status === 'checking...' ? 'checking…' : gatewayHealth.status}
          </span>
        </div>
      </header>

      <div style={{ padding: 24 }}>
        {/* Stats row */}
        <div style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(170px, 1fr))',
          gap: 12,
          marginBottom: 24,
        }}>
          <StatCard label="Total services" value={services.length} />
          <StatCard label="Online" value={onlineCount} color="#16a34a" />
          <StatCard label="Offline" value={offlineCount} color="#dc2626" />
          <StatCard label="Gateway" value={gatewayOnline ? 'online' : 'offline'} color={gatewayOnline ? '#16a34a' : '#dc2626'} />
        </div>

        {/* Tabs */}
        <div style={{
          display: 'flex',
          gap: 8,
          marginBottom: 16,
          borderBottom: '1px solid #e5e7eb',
          paddingBottom: 10,
        }}>
          <button onClick={() => setTab('services')} style={tabStyle(tab === 'services')}>
            Services
          </button>
          <button onClick={() => setTab('add')} style={tabStyle(tab === 'add')}>
            Add Service
          </button>
        </div>

        {/* Tab panels */}
        <div style={{ minHeight: 300 }}>
          {tab === 'services' ? (
            <ServiceList />
          ) : (
            <ProjectLauncher onServiceAdded={handleServiceAdded} />
          )}
        </div>
      </div>
    </div>
  );
}
