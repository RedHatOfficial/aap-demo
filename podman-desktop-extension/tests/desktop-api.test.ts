import { describe, expect, it, vi } from 'vitest';
import { acquireDesktopApi, type DesktopApi } from '../src/webview/desktop-api';

describe('acquireDesktopApi', () => {
  it('acquires the Podman Desktop webview API from the host', () => {
    const api: DesktopApi = { postMessage: vi.fn() };
    const factory = vi.fn(() => api);

    expect(acquireDesktopApi(factory)).toBe(api);
    expect(factory).toHaveBeenCalledOnce();
  });

  it('returns undefined when the host API is unavailable', () => {
    expect(acquireDesktopApi(undefined)).toBeUndefined();
  });
});
