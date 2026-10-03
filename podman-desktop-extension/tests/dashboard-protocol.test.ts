import { describe, expect, it } from 'vitest';
import { isDashboardMessage, unwrapDashboardMessage } from '../src/dashboard-protocol';

describe('isDashboardMessage', () => {
  it('accepts the webview ready handshake', () => {
    expect(isDashboardMessage({ type: 'ready' })).toBe(true);
  });

  it('accepts supported lifecycle actions', () => {
    expect(isDashboardMessage({ type: 'run', action: 'status' })).toBe(true);
  });

  it('accepts safe external URL requests', () => {
    expect(isDashboardMessage({ type: 'open-url', url: 'https://example.test/path' })).toBe(true);
  });

  it('rejects unsupported messages', () => {
    expect(isDashboardMessage({ type: 'run', action: 'shell' })).toBe(false);
    expect(isDashboardMessage({ type: 'open-url', url: 'file:///etc/passwd' })).toBe(false);
    expect(isDashboardMessage({ type: 'open-url', url: 'javascript:alert(1)' })).toBe(false);
  });
});

describe('unwrapDashboardMessage', () => {
  it('keeps direct messages unchanged', () => {
    const message = { type: 'status' };
    expect(unwrapDashboardMessage(message)).toBe(message);
  });

  it('unwraps string and envelope payloads', () => {
    const message = { type: 'status' };
    expect(unwrapDashboardMessage(JSON.stringify(message))).toEqual(message);
    expect(unwrapDashboardMessage({ message })).toBe(message);
  });

  it('unwraps nested data and payload envelopes', () => {
    const message = { type: 'status' };
    expect(unwrapDashboardMessage({ data: { payload: message } })).toBe(message);
  });
});
