import { existsSync } from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { resolveExecutablePath } from './executable-path';

const MINIMUM_MEMORY = 16_384;

export interface PrerequisiteSettings {
  crcPath: string;
  pullSecretPath?: string;
  memory?: number;
}

export interface PrerequisiteStatus {
  crc: { available: boolean; path?: string };
  pullSecret: { configured: boolean; exists: boolean; path?: string };
  memory: { value: number; valid: boolean; minimum: number };
  ready: boolean;
}

function findPullSecret(configuredPath?: string): {
  configured: boolean;
  exists: boolean;
  path?: string;
} {
  if (configuredPath?.trim()) {
    const resolvedPath = configuredPath.trim();
    return {
      configured: true,
      exists: existsSync(resolvedPath),
      path: resolvedPath,
    };
  }

  const candidates = [
    path.join(os.homedir(), '.aap-demo', 'pull-secret.txt'),
    path.join(os.homedir(), '.aap-demo', 'pull-secret.json'),
    path.join(os.homedir(), '.aap-demo', 'pull-secret'),
  ];
  const existingPath = candidates.find(candidate => existsSync(candidate));
  return existingPath
    ? { configured: true, exists: true, path: existingPath }
    : { configured: false, exists: false };
}

export function checkPrerequisites(
  settings: PrerequisiteSettings,
  pathValue = process.env.PATH ?? '',
): PrerequisiteStatus {
  const crcPath = resolveExecutablePath(settings.crcPath, pathValue);
  const pullSecret = findPullSecret(settings.pullSecretPath);
  const memory = settings.memory ?? 24_576;
  const memoryStatus = {
    value: memory,
    valid: Number.isFinite(memory) && memory >= MINIMUM_MEMORY,
    minimum: MINIMUM_MEMORY,
  };

  return {
    crc: crcPath ? { available: true, path: crcPath } : { available: false },
    pullSecret,
    memory: memoryStatus,
    ready: Boolean(crcPath && pullSecret.exists && memoryStatus.valid),
  };
}
