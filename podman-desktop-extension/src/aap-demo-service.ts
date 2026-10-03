import type {
  CommandResult,
  CommandRunnerOptions,
} from './command-runner';

export type AapDemoAction = 'create' | 'deploy' | 'destroy' | 'status' | 'idle' | 'diagnose';
export type AddonAction = 'enable' | 'disable';

export interface AapDemoSettings {
  pullSecretPath?: string;
  memory?: number;
  pathValue?: string;
}

export interface CommandExecutor {
  run(
    command: string,
    args?: readonly string[],
    options?: CommandRunnerOptions,
  ): Promise<CommandResult>;
}

export class AapDemoService {
  constructor(
    private readonly executor: CommandExecutor,
    private readonly cliPath = 'aap-demo',
    private readonly settings: AapDemoSettings = {},
  ) {}

  run(
    action: AapDemoAction,
    idleState?: boolean,
    options?: CommandRunnerOptions,
  ): Promise<CommandResult> {
    const args = action === 'idle'
      ? ['idle', String(idleState ?? true)]
      : [action];

    return this.executor.run(this.cliPath, args, this.withSettings(options));
  }

  runAddon(
    action: AddonAction,
    addon: string,
    options?: CommandRunnerOptions,
  ): Promise<CommandResult> {
    return this.executor.run(this.cliPath, [action, addon], this.withSettings(options));
  }

  private withSettings(options?: CommandRunnerOptions): CommandRunnerOptions | undefined {
    if (!options && !this.settings.pullSecretPath && !this.settings.memory && !this.settings.pathValue) {
      return undefined;
    }
    const configuredEnvironment: NodeJS.ProcessEnv = {
      ...(options?.env ?? process.env),
    };
    if (this.settings.pullSecretPath) {
      configuredEnvironment.PULL_SECRET_PATH = this.settings.pullSecretPath;
    }
    if (this.settings.memory) {
      configuredEnvironment.CRC_MEMORY = String(this.settings.memory);
    }
    if (this.settings.pathValue) {
      configuredEnvironment.PATH = this.settings.pathValue;
    }

    return {
      ...options,
      env: configuredEnvironment,
    };
  }
}
