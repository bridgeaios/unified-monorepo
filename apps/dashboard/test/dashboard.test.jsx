import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import '@testing-library/jest-dom';
import React from 'react';

import App from '../src/App';
import ServiceCard from '../src/components/ServiceCard';
import ServiceList from '../src/components/ServiceList';
import ProjectLauncher from '../src/components/ProjectLauncher';
import * as api from '../src/services/api';

beforeEach(() => {
  vi.restoreAllMocks();
  // Stub the gateway API so no real network calls are made.
  vi.spyOn(api, 'getServices').mockResolvedValue([]);
  vi.spyOn(api, 'checkHealth').mockResolvedValue({ status: 'ok' });
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('App', () => {
  it('renders the "Unified Project Launcher" header', () => {
    render(<App />);
    expect(screen.getByText('Unified Project Launcher')).toBeInTheDocument();
  });

  it('shows the empty state when no services are registered', async () => {
    render(<App />);
    // ServiceList starts in a loading state, then resolves to an empty list.
    await waitFor(() => expect(screen.getByText(/No services/)).toBeInTheDocument());
  });

  it('shows a green gateway health indicator when the gateway is online', async () => {
    render(<App />);
    await waitFor(() => expect(screen.getByText(/Gateway ok/)).toBeInTheDocument());
    expect(screen.getByText(/Gateway ok/)).toHaveStyle({ backgroundColor: 'rgb(22, 163, 74)' });
  });

  it('shows a red gateway health indicator when the gateway is offline', async () => {
    vi.spyOn(api, 'checkHealth').mockRejectedValue(new Error('gateway down'));
    render(<App />);
    await waitFor(() => expect(screen.getByText(/Gateway offline/)).toBeInTheDocument());
    expect(screen.getByText(/Gateway offline/)).toHaveStyle({ backgroundColor: 'rgb(220, 38, 38)' });
  });
});

describe('ServiceCard', () => {
  it('displays name, stack, category and a status badge', () => {
    const service = {
      name: 'orders-api',
      url: 'http://localhost:5001',
      stack: 'Node.js',
      category: 'backend',
      port: 5001,
      status: 'online',
    };
    render(<ServiceCard service={service} />);
    expect(screen.getByText('orders-api')).toBeInTheDocument();
    expect(screen.getByText('Node.js')).toBeInTheDocument();
    expect(screen.getByText('backend')).toBeInTheDocument();
    expect(screen.getByText('Online')).toBeInTheDocument();
  });
});

describe('ServiceList', () => {
  it('renders a list of services from the mock API', async () => {
    vi.spyOn(api, 'getServices').mockResolvedValue([
      { name: 'orders-api', url: 'http://localhost:5001', stack: 'Node.js', category: 'backend' },
      { name: 'web-frontend', url: 'http://localhost:5002', stack: 'React', category: 'frontend' },
    ]);
    render(<ServiceList />);
    await waitFor(() => expect(screen.getByText('orders-api')).toBeInTheDocument());
    await waitFor(() => expect(screen.getByText('web-frontend')).toBeInTheDocument());
    expect(screen.queryByText(/No services/)).not.toBeInTheDocument();
  });
});

describe('ProjectLauncher', () => {
  it('submits the form and calls registerService', async () => {
    const registerSpy = vi.spyOn(api, 'registerService').mockResolvedValue({});
    const onServiceAdded = vi.fn();
    render(<ProjectLauncher onServiceAdded={onServiceAdded} />);

    fireEvent.change(screen.getByPlaceholderText('e.g. orders-api'), { target: { value: 'new-svc' } });
    fireEvent.change(screen.getByPlaceholderText('http://localhost:5001'), { target: { value: 'http://localhost:5010' } });
    fireEvent.change(screen.getByPlaceholderText('e.g. Node.js'), { target: { value: 'Node.js' } });
    fireEvent.change(screen.getByPlaceholderText('e.g. backend'), { target: { value: 'backend' } });

    fireEvent.click(screen.getByRole('button', { name: 'Register Service' }));

    await waitFor(() =>
      expect(registerSpy).toHaveBeenCalledWith(
        expect.objectContaining({ name: 'new-svc', url: 'http://localhost:5010', stack: 'Node.js', category: 'backend' })
      )
    );
    await waitFor(() => expect(onServiceAdded).toHaveBeenCalled());
    expect(screen.getByText('Service registered successfully.')).toBeInTheDocument();
  });
});
