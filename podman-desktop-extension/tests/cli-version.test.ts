import { describe, expect, it } from 'vitest';
import type { CommandResult } from '../src/command-runner';
import { detectCliVersion, parseCliVersion } from '../src/cli-version';
import type { CommandExecutor } from '../src/aap-demo-service';

class VersionExecutor implements CommandExecutor {
  public readonly calls: Array<{ command: string; args: readonly string[] }> = [];

  constructor(private readonly result: CommandResult | Error) {}

  async run(command: string, args: readonly string[] = []): Promise<CommandResult> {
    this.calls.push({ command, args });
    if (this.result instanceof Error) throw this.result;
    return this.result;
  }
}

describe('parseCliVersion', () => {
  it('extracts a semantic version from the CLI banner', () => {
    expect(parseCliVersion('aap-demo 1.0.48\n  built: 2026-10-01')).toBe('1.0.48');
  });

  it('removes a leading v from a version string', () => {
    expect(parseCliVersion('aap-demo v1.2.3')).toBe('1.2.3');
  });

  it('returns unknown when no semantic version is reported', () => {
    expect(parseCliVersion('aap-demo development build')).toBe('unknown');
  });
});

describe('detectCliVersion', () => {
  it('runs the configured CLI with --version', async () => {
    const executor = new VersionExecutor({
      exitCode: 0,
      stdout: 'aap-demo 1.0.48\n',
      stderr: '',
    });

    await expect(detectCliVersion(executor, '/custom/aap-demo')).resolves.toBe('1.0.48');
    expect(executor.calls).toEqual([{ command: '/custom/aap-demo', args: ['--version'] }]);
  });

  it('does not prevent extension activation when version detection fails', async () => {
    const executor = new VersionExecutor(new Error('not found'));

    await expect(detectCliVersion(executor, 'aap-demo')).resolves.toBe('unknown');
  });
});
