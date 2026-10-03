import { describe, expect, it } from 'vitest';
import { formatStatusBarText } from '../src/status-bar';

describe('formatStatusBarText', () => {
  it('includes the cluster name when the demo is running', () => {
    expect(formatStatusBarText({
      cluster: { state: 'running', name: 'aap-demo' },
      routes: [],
      credentials: [],
      addons: [],
    })).toBe('AAP Demo: Running (aap-demo)');
  });

  it('formats non-running states for the status bar', () => {
    expect(formatStatusBarText({
      cluster: { state: 'not-running' },
      routes: [],
      credentials: [],
      addons: [],
    })).toBe('AAP Demo: Not Running');
  });
});
