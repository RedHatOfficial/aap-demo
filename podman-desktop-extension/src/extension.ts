import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import type { ExtensionContext, WebviewPanel } from '@podman-desktop/api';
import * as extensionApi from '@podman-desktop/api';
import {
  AapDemoService,
  type AddonAction,
  type AapDemoAction,
  type AapDemoSettings,
} from './aap-demo-service';
import { formatCommandError } from './command-error';
import { CommandRunner } from './command-runner';
import { detectCliVersion } from './cli-version';
import { isDashboardMessage } from './dashboard-protocol';
import { augmentPath, resolveConfiguredExecutable, resolveExecutablePath } from './executable-path';
import { checkPrerequisites } from './prerequisites';
import { parseStatusOutput } from './status-parser';
import { formatStatusBarText } from './status-bar';

async function renderWebviewHtml(
  panel: WebviewPanel,
  extensionContext: ExtensionContext,
): Promise<string> {
  const htmlPath = path.join(extensionContext.extensionUri.fsPath, 'media', 'index.html');
  let html = await fs.readFile(htmlPath, 'utf8');
  const resourcePattern = /(src|href)="(\.\/[^\"]+)"/g;

  html = html.replace(resourcePattern, (_match, attribute: string, resourcePath: string) => {
    const localPath = resourcePath.slice(2);
    const resourceUri = extensionApi.Uri.joinPath(
      extensionContext.extensionUri,
      'media',
      ...localPath.split('/'),
    );
    return `${attribute}="${panel.webview.asWebviewUri(resourceUri)}"`;
  });

  return html;
}

async function checkCrc(crcCommand: string): Promise<void> {
  const crcPath = resolveExecutablePath(crcCommand);
  if (!crcPath) {
    await extensionApi.window.showWarningMessage(
      'AAP Demo requires OpenShift Local (CRC). Install it or set aap-demo.crcPath to the CRC executable.',
    );
    return;
  }

  console.log(`[aap-demo] OpenShift Local found at ${crcPath}`);
}

export async function activate(extensionContext: ExtensionContext): Promise<void> {
  const runner = new CommandRunner();
  const configuration = extensionApi.configuration.getConfiguration('aap-demo');
  const cliPath = resolveConfiguredExecutable(configuration.get('cliPath', 'aap-demo'));
  const crcPath = configuration.get('crcPath', 'crc');
  const settings: AapDemoSettings = {
    pullSecretPath: configuration.get('pullSecretPath', ''),
    memory: configuration.get('memory', 24_576),
    pathValue: augmentPath(),
  };
  const service = new AapDemoService(runner, cliPath, settings);
  const cliVersion = await detectCliVersion(runner, cliPath);
  const cliTool = extensionApi.cli.createCliTool({
    name: 'aap-demo',
    displayName: 'AAP Demo CLI',
    markdownDescription: 'The command-line interface for the local AAP Demo environment.',
    images: {},
    version: cliVersion,
    path: cliPath,
  });
  extensionContext.subscriptions.push(cliTool);
  try {
    await configuration.update('cliVersion', cliVersion);
  } catch (error) {
    console.warn('[aap-demo] Could not persist the detected CLI version', error);
  }
  let panel: WebviewPanel | undefined;
  const postDashboardMessage = async (message: unknown): Promise<boolean> => {
    const currentPanel = panel;
    if (!currentPanel) return false;
    const delivered = await currentPanel.webview.postMessage(message);
    if (!delivered) {
      console.warn('[aap-demo] Dashboard webview did not accept a message', message);
    }
    return delivered;
  };
  const statusBar = extensionApi.window.createStatusBarItem(extensionApi.StatusBarAlignLeft, 100);
  statusBar.text = 'AAP Demo: Unknown';
  statusBar.tooltip = 'Open the AAP Demo dashboard';
  statusBar.command = 'aap-demo.openDashboard';
  statusBar.show();
  extensionContext.subscriptions.push(statusBar);

  const runAction = async (action: AapDemoAction, idleState?: boolean): Promise<void> => {
    try {
      const result = await service.run(action, idleState, {
        onStdout: chunk => {
          console.log(`[aap-demo] ${chunk.trimEnd()}`);
          if (action !== 'status') {
            void postDashboardMessage({ type: 'command-output', stream: 'stdout', text: chunk });
          }
        },
        onStderr: chunk => {
          console.warn(`[aap-demo] ${chunk.trimEnd()}`);
          void postDashboardMessage({ type: 'command-output', stream: 'stderr', text: chunk });
        },
      });

      if (action === 'status') {
        const status = parseStatusOutput(result.stdout);
        statusBar.text = formatStatusBarText(status);
        statusBar.tooltip = `Open the AAP Demo dashboard (${status.cluster.state})`;
        await postDashboardMessage({
          type: 'status',
          status,
        });
        return;
      }

      await postDashboardMessage({
        type: 'command-result',
        action,
        stdout: result.stdout,
        stderr: result.stderr,
      });
      await extensionApi.window.showInformationMessage(`AAP Demo ${action} completed.`);
      void runAction('status');
    } catch (error) {
      const message = formatCommandError(error);
      await postDashboardMessage({ type: 'command-error', action, message });
      await extensionApi.window.showWarningMessage(`AAP Demo ${action} failed: ${message}`);
    }
  };

  const runAddon = async (action: AddonAction, addon: string): Promise<void> => {
    try {
      const result = await service.runAddon(action, addon, {
        onStdout: chunk => {
          console.log(`[aap-demo] ${chunk.trimEnd()}`);
          void postDashboardMessage({ type: 'command-output', stream: 'stdout', text: chunk });
        },
        onStderr: chunk => {
          console.warn(`[aap-demo] ${chunk.trimEnd()}`);
          void postDashboardMessage({ type: 'command-output', stream: 'stderr', text: chunk });
        },
      });
      await postDashboardMessage({
        type: 'addon-result',
        action,
        addon,
        stdout: result.stdout,
        stderr: result.stderr,
      });
      await extensionApi.window.showInformationMessage(`AAP Demo add-on ${addon} ${action}d.`);
      await runAction('status');
    } catch (error) {
      const message = formatCommandError(error);
      await postDashboardMessage({ type: 'command-error', action, addon, message });
      await extensionApi.window.showWarningMessage(`AAP Demo add-on ${addon} failed: ${message}`);
    }
  };

  const openDashboard = extensionApi.commands.registerCommand('aap-demo.openDashboard', async () => {
    if (panel) {
      panel.reveal();
      return;
    }

    panel = extensionApi.window.createWebviewPanel('aap-demo.dashboard', 'AAP Demo Dashboard', {
      localResourceRoots: [extensionApi.Uri.joinPath(extensionContext.extensionUri, 'media')],
    });
    let initialized = false;
    let initializationTimer: ReturnType<typeof setTimeout> | undefined;
    const initializeDashboard = async (): Promise<void> => {
      if (initialized) return;
      initialized = true;
      await new Promise(resolve => setTimeout(resolve, 200));
      await runAction('status');
      await postDashboardMessage({
        type: 'prerequisites',
        prerequisites: checkPrerequisites({ crcPath, ...settings }),
      });
    };
    const messageSubscription = panel.webview.onDidReceiveMessage(async message => {
      if (isDashboardMessage(message)) {
        if (message.type === 'ready') {
          void initializeDashboard();
        } else if (message.type === 'addon') {
          await runAddon(message.action, message.addon);
        } else if (message.type === 'open-url') {
          const opened = await extensionApi.env.openExternal(extensionApi.Uri.parse(message.url, true));
          if (!opened) {
            await extensionApi.window.showWarningMessage(`Could not open ${message.url}`);
          }
        } else {
          await runAction(message.action, message.idleState);
        }
      }
    });
    panel.webview.html = await renderWebviewHtml(panel, extensionContext);
    initializationTimer = setTimeout(() => void initializeDashboard(), 2_000);
    const statusPoll = setInterval(() => void runAction('status'), 30_000);
    extensionContext.subscriptions.push(
      messageSubscription,
      panel.onDidDispose(() => {
        if (initializationTimer) clearTimeout(initializationTimer);
        clearInterval(statusPoll);
        panel = undefined;
      }),
    );
  });
  extensionContext.subscriptions.push(openDashboard);

  for (const action of ['create', 'deploy', 'destroy', 'status', 'diagnose'] as const) {
    extensionContext.subscriptions.push(
      extensionApi.commands.registerCommand(`aap-demo.${action}`, () => runAction(action)),
    );
  }
  extensionContext.subscriptions.push(
    extensionApi.commands.registerCommand(
      'aap-demo.idle',
      (idleState: boolean = true) => runAction('idle', idleState),
    ),
  );

  await checkCrc(crcPath);
}

export function deactivate(): void {
  // Command and panel resources are owned by ExtensionContext subscriptions.
}
