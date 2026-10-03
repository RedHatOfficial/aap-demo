import { CommandExecutionError } from './command-runner';

export function formatCommandError(error: unknown): string {
  if (error instanceof CommandExecutionError) {
    const output = [error.stderr, error.stdout]
      .map(value => value.trim())
      .filter(Boolean);
    return [error.message, ...output].join('\n');
  }

  return error instanceof Error ? error.message : String(error);
}
