import { useState } from 'react';
import { registerService } from '../services/api';

export default function ProjectLauncher({ onServiceAdded }) {
  const [form, setForm] = useState({ name: '', url: '', stack: '', category: '', port: '' });
  const [submitting, setSubmitting] = useState(false);
  const [message, setMessage] = useState(null);

  const handleChange = e => {
    setForm({ ...form, [e.target.name]: e.target.value });
  };

  const handleSubmit = async e => {
    e.preventDefault();
    setSubmitting(true);
    setMessage(null);

    try {
      await registerService({
        name: form.name,
        url: form.url,
        stack: form.stack,
        category: form.category,
        port: form.port ? Number(form.port) : undefined,
      });
      setForm({ name: '', url: '', stack: '', category: '', port: '' });
      setMessage({ type: 'success', text: 'Service registered successfully.' });
      onServiceAdded?.();
    } catch (err) {
      setMessage({ type: 'error', text: err.message || 'Failed to register service.' });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div style={{
      border: '1px solid #e5e7eb',
      borderRadius: 10,
      padding: 20,
      background: '#fff',
    }}>
      <h2 style={{ margin: '0 0 16px 0', fontSize: 18, color: '#111827' }}>Register a New Service</h2>
      <p style={{ margin: '0 0 16px 0', fontSize: 13, color: '#6b7280' }}>
        Manually add a service to the gateway. Fields marked * are required.
      </p>

      <form onSubmit={handleSubmit} style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 12, alignItems: 'end' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <label style={{ fontSize: 12, fontWeight: 600, color: '#374151' }}>Service name *</label>
          <input
            name="name"
            value={form.name}
            onChange={handleChange}
            placeholder="e.g. orders-api"
            style={{
              padding: '8px 10px',
              borderRadius: 6,
              border: '1px solid #d1d5db',
              fontSize: 13,
              boxSizing: 'border-box',
            }}
          />
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <label style={{ fontSize: 12, fontWeight: 600, color: '#374151' }}>Service URL *</label>
          <input
            name="url"
            value={form.url}
            onChange={handleChange}
            placeholder="http://localhost:5001"
            style={{
              padding: '8px 10px',
              borderRadius: 6,
              border: '1px solid #d1d5db',
              fontSize: 13,
              boxSizing: 'border-box',
            }}
          />
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <label style={{ fontSize: 12, fontWeight: 600, color: '#374151' }}>Stack</label>
          <input
            name="stack"
            value={form.stack}
            onChange={handleChange}
            placeholder="e.g. Node.js"
            style={{
              padding: '8px 10px',
              borderRadius: 6,
              border: '1px solid #d1d5db',
              fontSize: 13,
              boxSizing: 'border-box',
            }}
          />
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <label style={{ fontSize: 12, fontWeight: 600, color: '#374151' }}>Category</label>
          <input
            name="category"
            value={form.category}
            onChange={handleChange}
            placeholder="e.g. backend"
            style={{
              padding: '8px 10px',
              borderRadius: 6,
              border: '1px solid #d1d5db',
              fontSize: 13,
              boxSizing: 'border-box',
            }}
          />
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <label style={{ fontSize: 12, fontWeight: 600, color: '#374151' }}>Port</label>
          <input
            name="port"
            type="number"
            value={form.port}
            onChange={handleChange}
            placeholder="e.g. 5001"
            style={{
              padding: '8px 10px',
              borderRadius: 6,
              border: '1px solid #d1d5db',
              fontSize: 13,
              boxSizing: 'border-box',
            }}
          />
        </div>
      </form>

      <div style={{ marginTop: 16, display: 'flex', gap: 10, alignItems: 'center' }}>
        <button
          type="submit"
          disabled={submitting}
          style={{
            padding: '8px 16px',
            borderRadius: 6,
            border: 'none',
            background: '#2563eb',
            color: '#fff',
            fontSize: 13,
            fontWeight: 600,
            cursor: submitting ? 'not-allowed' : 'pointer',
            opacity: submitting ? 0.6 : 1,
          }}
        >
          {submitting ? 'Registering…' : 'Register Service'}
        </button>
      </div>

      {message && (
        <div style={{
          marginTop: 12,
          padding: 10,
          borderRadius: 6,
          fontSize: 12,
          background: message.type === 'success' ? '#f0fdf4' : '#fef2f2',
          border: `1px solid ${message.type === 'success' ? '#bbf7d0' : '#fecaca'}`,
          color: message.type === 'success' ? '#166534' : '#991b1b',
        }}>
          {message.text}
        </div>
      )}
    </div>
  );
}
