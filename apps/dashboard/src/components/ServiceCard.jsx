import { useState } from 'react';
import { checkHealth } from '../services/api';

const STATUS_COLORS = {
  online: '#16a34a',
  offline: '#dc2626',
  unknown: '#ca8a04',
};

export default function ServiceCard({ service }) {
  const [health, setHealth] = useState(null);
  const [checking, setChecking] = useState(false);
  const [error, setError] = useState(null);

  const handleHealthCheck = async () => {
    setChecking(true);
    setError(null);
    try {
      const data = await checkHealth(service.url);
      setHealth(data);
    } catch (err) {
      setError(err.message || 'Health check failed');
      setHealth(null);
    } finally {
      setChecking(false);
    }
  };

  const status = (service.status || 'unknown').toLowerCase();
  const badgeColor = STATUS_COLORS[status] || STATUS_COLORS.unknown;

  return (
    <div style={{
      border: '1px solid #e5e7eb',
      borderRadius: 10,
      padding: 16,
      marginBottom: 16,
      background: '#fff',
      display: 'flex',
      flexDirection: 'column',
      gap: 12,
      boxSizing: 'border-box',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
        <div>
          <div style={{ fontSize: 17, fontWeight: 600, color: '#111827' }}>{service.name}</div>
          <div style={{
            display: 'flex',
            alignItems: 'center',
            gap: 10,
            color: '#6b7280',
            fontSize: 13,
            marginTop: 4,
            flexWrap: 'wrap',
          }}>
            <span>{service.stack || '-'}</span>
            <span style={{ color: '#9ca3af' }}>&middot;</span>
            <span>{service.category || '-'}</span>
            {service.port ? (
              <>
                <span style={{ color: '#9ca3af' }}>&middot;</span>
                <span>: {service.port}</span>
              </>
            ) : null}
          </div>
        </div>
        <span style={{
          display: 'inline-block',
          padding: '4px 10px',
          borderRadius: 999px,
          fontSize: 12,
          fontWeight: 700,
          color: '#fff',
          backgroundColor: badgeColor,
        }}>
          {status.charAt(0).toUpperCase() + status.slice(1)}
        </span>
      </div>

      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
        <a
          href={service.url}
          target="_blank"
          rel="noopener noreferrer"
          style={{
            padding: '6px 14px',
            borderRadius: 6,
            background: '#2563eb',
            color: '#fff',
            textDecoration: 'none',
            fontSize: 13,
            fontWeight: 500,
          }}
        >
          Open
        </a>
        <button
          onClick={handleHealthCheck}
          disabled={checking}
          style={{
            padding: '6px 14px',
            borderRadius: 6,
            border: '1px solid #e5e7eb',
            background: '#fff',
            cursor: checking ? 'not-allowed' : 'pointer',
            fontSize: 13,
            fontWeight: 500,
            opacity: checking ? 0.6 : 1,
          }}
        >
          {checking ? 'Checking…' : 'Health'}
        </button>
      </div>

      {health && (
        <div style={{
          marginTop: 4,
          padding: 10,
          borderRadius: 6,
          background: '#f0fdf4',
          border: '1px solid #bbf7d0',
          color: '#166534',
          fontSize: 12,
        }}>
          <div style={{ fontWeight: 600, marginBottom: 4 }}>Health: OK</div>
          <pre style={{ margin: 0, fontSize: 11, whiteSpace: 'pre-wrap', wordBreak: 'break-all' }}>
            {JSON.stringify(health, null, 2)}
          </pre>
        </div>
      )}

      {error && (
        <div style={{
          marginTop: 4,
          padding: 10,
          borderRadius: 6,
          background: '#fef2f2',
          border: '1px solid #fecaca',
          color: '#991b1b',
          fontSize: 12,
        }}>
          Health check failed: {error}
        </div>
      )}
    </div>
  );
}
