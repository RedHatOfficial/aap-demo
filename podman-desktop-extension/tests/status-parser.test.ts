import { describe, expect, it } from 'vitest';
import { parseStatusOutput } from '../src/status-parser';

describe('parseStatusOutput', () => {
  it('extracts cluster details, routes, credentials, and add-ons', () => {
    const output = `
\x1b[1mAAP Demo Status\x1b[0m
===============
Tool:        0.4.0
Built:       2026-10-02T12:00:00Z

Infra:       OpenShift Local (CRC)
Cluster:     \x1b[1;32mrunning\x1b[0m (crc-microshift)

Kubeconfig:  /Users/example/.aap-demo/kubeconfig.microshift

AAP Deployments:
----------------
  https://aap-aap-operator.apps.127.0.0.1.nip.io

Credentials:
------------
  aap-operator:       admin / sample-value

Addons:
-------
  mcp-server      enabled
  portal          https://portal.apps.example.test
  ao              disabled
`;

    expect(parseStatusOutput(output)).toEqual({
      toolVersion: '0.4.0',
      built: '2026-10-02T12:00:00Z',
      infra: 'OpenShift Local (CRC)',
      cluster: { state: 'running', name: 'crc-microshift' },
      kubeconfig: '/Users/example/.aap-demo/kubeconfig.microshift',
      routes: ['https://aap-aap-operator.apps.127.0.0.1.nip.io'],
      credentials: [{ namespace: 'aap-operator', username: 'admin', password: 'sample-value' }], // pragma: allowlist secret
      addons: [
        { name: 'mcp-server', state: 'enabled' },
        { name: 'portal', state: 'enabled', url: 'https://portal.apps.example.test' },
        { name: 'ao', state: 'disabled' },
      ],
    });
  });

  it('represents a stopped cluster without requiring deployment sections', () => {
    expect(
      parseStatusOutput('Infra: OpenShift Local (CRC)\nCluster: stopped\nStart with: crc start'),
    ).toMatchObject({
      infra: 'OpenShift Local (CRC)',
      cluster: { state: 'stopped' },
      routes: [],
      credentials: [],
      addons: [],
    });
  });

  it('stops parsing add-ons when a later status section begins', () => {
    const status = parseStatusOutput(`Addons:
-------
  portal enabled

Fleet:
------
  node-1 running`);

    expect(status.addons).toEqual([{ name: 'portal', state: 'enabled' }]);
  });
});
