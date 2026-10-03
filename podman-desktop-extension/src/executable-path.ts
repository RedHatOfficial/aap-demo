import { accessSync, constants, statSync } from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

function isExecutable(candidate: string): boolean {
  try {
    accessSync(candidate, constants.X_OK);
    return statSync(candidate).isFile();
  } catch {
    return false;
  }
}

function expandHome(command: string): string {
  if (command === '~') return os.homedir();
  if (command.startsWith('~/') || command.startsWith('~\\')) {
    return path.join(os.homedir(), command.slice(2));
  }
  return command;
}

function fallbackDirectories(): string[] {
  return [
    '/usr/local/bin',
    '/opt/homebrew/bin',
    path.join(os.homedir(), '.crc', 'bin'),
    path.join(os.homedir(), '.local', 'bin'),
  ];
}

export function augmentPath(pathValue = process.env.PATH ?? ''): string {
  return [...new Set([...pathValue.split(path.delimiter), ...fallbackDirectories()])]
    .filter(Boolean)
    .join(path.delimiter);
}

export function resolveExecutablePath(
  command: string,
  pathValue = process.env.PATH ?? '',
): string | undefined {
  const expandedCommand = expandHome(command);
  if (path.isAbsolute(expandedCommand)) {
    return isExecutable(expandedCommand) ? expandedCommand : undefined;
  }

  const directories = augmentPath(pathValue).split(path.delimiter);

  for (const directory of directories) {
    if (!directory) continue;
    const candidate = path.join(directory, expandedCommand);
    if (isExecutable(candidate)) return candidate;
  }

  return undefined;
}

export function resolveConfiguredExecutable(
  command: string,
  pathValue = process.env.PATH ?? '',
): string {
  const expandedCommand = expandHome(command);
  return resolveExecutablePath(expandedCommand, pathValue) ?? expandedCommand;
}
