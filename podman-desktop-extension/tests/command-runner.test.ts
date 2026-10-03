import { describe, expect, it } from 'vitest';
import { CommandRunner } from '../src/command-runner';

describe('CommandRunner', () => {
  it('captures stdout and stderr from a successful command', async () => {
    const runner = new CommandRunner();

    const result = await runner.run(process.execPath, [
      '-e',
      "process.stdout.write('ready'); process.stderr.write('notice');",
    ]);

    expect(result).toEqual({
      exitCode: 0,
      stdout: 'ready',
      stderr: 'notice',
    });
  });

  it('rejects with the captured output when a command exits unsuccessfully', async () => {
    const runner = new CommandRunner();

    await expect(
      runner.run(process.execPath, [
        '-e',
        "process.stderr.write('failed'); process.exitCode = 7;",
      ]),
    ).rejects.toMatchObject({
      exitCode: 7,
      stderr: 'failed',
    });
  });
  it('streams output chunks while the command is running', async () => {
    const runner = new CommandRunner();
    const stdout: string[] = [];
    const stderr: string[] = [];

    await runner.run(
      process.execPath,
      ['-e', "process.stdout.write('out'); process.stderr.write('err');"],
      {
        onStdout: chunk => stdout.push(chunk),
        onStderr: chunk => stderr.push(chunk),
      },
    );

    expect(stdout.join('')).toBe('out');
    expect(stderr.join('')).toBe('err');
  });
});
