import { describe, expect, it } from 'vitest';
import * as os from 'node:os';
import * as path from 'node:path';
import { augmentPath, resolveConfiguredExecutable, resolveExecutablePath } from '../src/executable-path';

describe('resolveExecutablePath', () => {
  it('finds an executable in the supplied PATH', () => {
    expect(resolveExecutablePath('sh', '/bin:/usr/bin')).toBe('/bin/sh');
  });

  it('accepts an explicit executable path', () => {
    expect(resolveExecutablePath('/bin/sh', '')).toBe('/bin/sh');
  });

  it('returns undefined when the executable cannot be found', () => {
    expect(resolveExecutablePath('definitely-not-installed', '/bin:/usr/bin')).toBeUndefined();
  });
});

describe('resolveConfiguredExecutable', () => {
  it('returns the absolute path for a configured executable name', () => {
    expect(resolveConfiguredExecutable('sh', '/bin:/usr/bin')).toBe('/bin/sh');
  });

  it('preserves an unresolved configured value for a useful spawn error', () => {
    expect(resolveConfiguredExecutable('definitely-not-installed', '/bin:/usr/bin')).toBe(
      'definitely-not-installed',
    );
  });

  it('expands a leading tilde in a configured executable path', () => {
    expect(resolveConfiguredExecutable('~/missing/aap-demo', '/bin:/usr/bin')).toBe(
      path.join(os.homedir(), 'missing', 'aap-demo'),
    );
  });
});

describe('augmentPath', () => {
  it('adds common user and package-manager executable directories', () => {
    const augmented = augmentPath('/usr/bin:/bin');

    expect(augmented.split(path.delimiter)).toEqual(expect.arrayContaining([
      '/usr/bin',
      '/bin',
      '/usr/local/bin',
      '/opt/homebrew/bin',
      path.join(os.homedir(), '.crc', 'bin'),
      path.join(os.homedir(), '.local', 'bin'),
    ]));
  });
});
