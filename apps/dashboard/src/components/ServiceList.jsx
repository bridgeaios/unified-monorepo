import { useState, useEffect } from 'react';
import { getServices } from '../services/api';
import ServiceCard from './ServiceCard';

export default function ServiceList() {
  const [services, setServices] = useState([]);
  const [loading, setLoading] = useState(true);

  const load = async () => {
    setLoading(true);
    try {
      const data = await getServices();
      setServices(Array.isArray(data) ? data : []);
    } catch {
      setServices([]);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
  }, []);

  if (loading) {
    return <p style={{ color: '#6b7280', textAlign: 'center' }}>Loading services…</p>;
  }

  if (services.length === 0) {
    return (
      <div style={{
        padding: 40,
        textAlign: 'center',
        color: '#6b7280',
      }}>
        <p style={{ fontSize: 15, marginBottom: 8 }}>No services discovered yet.</p>
        <p style={{ fontSize: 13 }}>Add one in the "Add Service" tab or wait for the project scanner to populate projects.json.</p>
      </div>
    );
  }

  return (
    <div style={{
      display: 'grid',
      gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))',
      gap: 16,
    }}>
      {services.map((service, index) => (
        <ServiceCard key={service.name || `service-${index}`} service={service} />
      ))}
    </div>
  );
}
