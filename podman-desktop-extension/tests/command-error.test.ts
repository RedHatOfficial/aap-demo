import { describe, expect, it } from 'vitest';
import { CommandExecutionError } from '../src/command-runner';
import { formatCommandError } from '../src/command-error';

describe('formatCommandError', () => {
  it('includes captured stderr and stdout from a failed command', () => {
    const error = new CommandExecutionError('Command exited unsuccessfully: aap-demo', {
      exitCode: 1,
      signal: null,
      stderr: 'Start with: aap-demo create',
      stdout: 'Cluster: not running',
    });

    expect(formatCommandError(error)).toBe(
      'Command exited unsuccessfully: aap-demo\nStart with: aap-demo create\nCluster: not running',
    );
  });

  it('formats ordinary errors without adding empty output lines', () => {
    expect(formatCommandError(new Error('not found'))).toBe('not found');
  });
});
