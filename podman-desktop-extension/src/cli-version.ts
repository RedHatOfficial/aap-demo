import type { CommandExecutor } from './aap-demo-service';

const semanticVersionPattern = /\bv?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\b/;

export function parseCliVersion(output: string): string {
  return output.match(semanticVersionPattern)?.[1] ?? 'unknown';
}

export async function detectCliVersion(
  executor: CommandExecutor,
  cliPath: string,
): Promise<string> {
  try {
    const result = await executor.run(cliPath, ['--version']);
    return parseCliVersion(`${result.stdout}\n${result.stderr}`);
  } catch {
    return 'unknown';
  }
}
