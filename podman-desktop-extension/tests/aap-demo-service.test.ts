import { describe, expect, it } from 'vitest';
import type { CommandResult, CommandRunnerOptions } from '../src/command-runner';
import { AapDemoService, type CommandExecutor } from '../src/aap-demo-service';

class RecordingExecutor implements CommandExecutor {
  public readonly calls: Array<{
    command: string;
    args: readonly string[];
    options?: CommandRunnerOptions;
  }> = [];

  async run(
    command: string,
    args: readonly string[],
    options?: CommandRunnerOptions,
  ): Promise<CommandResult> {
    this.calls.push({ command, args, ...(options ? { options } : {}) });
    return { exitCode: 0, stdout: '', stderr: '' };
  }
}

describe('AapDemoService', () => {
  it.each([
    ['create', ['create']],
    ['deploy', ['deploy']],
    ['destroy', ['destroy']],
    ['status', ['status']],
    ['diagnose', ['diagnose']],
  ] as const)('runs the %s action through the configured CLI', async (action, args) => {
    const executor = new RecordingExecutor();
    const service = new AapDemoService(executor, '/custom/bin/aap-demo');

    await service.run(action);

    expect(executor.calls).toEqual([
      { command: '/custom/bin/aap-demo', args },
    ]);
  });

  it('passes the desired idle state to the CLI', async () => {
    const executor = new RecordingExecutor();
    const service = new AapDemoService(executor);

    await service.run('idle', false);

    expect(executor.calls).toEqual([{ command: 'aap-demo', args: ['idle', 'false'] }]);
  });

  it('runs add-on enable and disable actions with the selected add-on', async () => {
    const executor = new RecordingExecutor();
    const service = new AapDemoService(executor);

    await service.runAddon('enable', 'mcp-server');
    await service.runAddon('disable', 'mcp-server');

    expect(executor.calls).toEqual([
      { command: 'aap-demo', args: ['enable', 'mcp-server'] },
      { command: 'aap-demo', args: ['disable', 'mcp-server'] },
    ]);
  });

  it('passes configured pull secret and memory settings to the CLI', async () => {
    const executor = new RecordingExecutor();
    const service = new AapDemoService(executor, 'aap-demo', {
      pullSecretPath: '/tmp/pull-secret.txt',
      memory: 24576,
    });

    await service.run('create');

    expect(executor.calls[0]?.options?.env).toMatchObject({
      PULL_SECRET_PATH: '/tmp/pull-secret.txt',
      CRC_MEMORY: '24576',
    });
  });

  it('passes the augmented executable search path to the CLI', async () => {
    const executor = new RecordingExecutor();
    const service = new AapDemoService(executor, 'aap-demo', {
      pathValue: '/usr/bin:/bin:/usr/local/bin',
    });

    await service.run('status');

    expect(executor.calls[0]?.options?.env?.PATH).toBe('/usr/bin:/bin:/usr/local/bin');
  });
});
