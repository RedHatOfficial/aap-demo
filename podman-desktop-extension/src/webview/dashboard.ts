import type { AapDemoStatus } from '../status-parser';
import type { PrerequisiteStatus } from '../prerequisites';
import { unwrapDashboardMessage } from '../dashboard-protocol';
import { acquireDesktopApi, type DesktopApi } from './desktop-api';
import { getAddonTogglePresentation, sortAddons } from './addon-ui';

export {};

interface DashboardStatusMessage {
  type: 'status';
  status: AapDemoStatus;
}

interface DashboardPrerequisitesMessage {
  type: 'prerequisites';
  prerequisites: PrerequisiteStatus;
}

interface DashboardCommandMessage {
  type: 'command-result' | 'addon-result' | 'command-output' | 'command-error';
  action?: string;
  addon?: string;
  stream?: string;
  text?: string;
  stdout?: string;
  stderr?: string;
  message?: string;
}

declare function acquirePodmanDesktopApi(): DesktopApi;

const desktopApi = acquireDesktopApi(
  typeof acquirePodmanDesktopApi === 'function' ? acquirePodmanDesktopApi : undefined,
);
const output = document.querySelector<HTMLPreElement>('#output');
const statusSummary = document.querySelector<HTMLParagraphElement>('#status-summary');
const statusState = document.querySelector<HTMLSpanElement>('#status-state');
const statusDot = document.querySelector<HTMLSpanElement>('#status-dot');
const lastUpdated = document.querySelector<HTMLSpanElement>('#last-updated');
const infra = document.querySelector<HTMLParagraphElement>('#infra');
const kubeconfig = document.querySelector<HTMLParagraphElement>('#kubeconfig');
const toolVersion = document.querySelector<HTMLParagraphElement>('#tool-version');
const routes = document.querySelector<HTMLDivElement>('#routes');
const credentials = document.querySelector<HTMLDivElement>('#credentials');
const addonActions = document.querySelector<HTMLDivElement>('#addon-actions');
const prerequisiteList = document.querySelector<HTMLDivElement>('#prerequisite-list');
const idleToggle = document.querySelector<HTMLButtonElement>('#idle-toggle');
let idleState = true;

function clear(element: Element | null): void {
  if (element) element.replaceChildren();
}

function emptyMessage(text: string): HTMLParagraphElement {
  const element = document.createElement('p');
  element.className = 'empty';
  element.textContent = text;
  return element;
}

function formatState(state: string): string {
  return state.replaceAll('-', ' ').replace(/\b\w/g, character => character.toUpperCase());
}

function writeOutput(text: string): void {
  if (output) output.textContent = text || 'No command output.';
}

function appendOutput(text: string): void {
  if (output) output.textContent = `${output.textContent === 'Ready.' ? '' : output.textContent}${text}`;
  if (output) output.scrollTop = output.scrollHeight;
}

function postToHost(message: unknown): void {
  if (!desktopApi) {
    const messageText = 'The Podman Desktop host bridge is unavailable. Open this dashboard from the installed extension.';
    if (statusSummary) statusSummary.textContent = messageText;
    writeOutput(messageText);
    if (statusDot) statusDot.className = 'status-dot error';
    return;
  }
  desktopApi.postMessage(message);
}

function postAction(action: string, idleStateValue?: boolean): void {
  if (statusSummary) statusSummary.textContent = `Running ${action}...`;
  postToHost({ type: 'run', action, idleState: idleStateValue });
}

function addExternalLink(link: HTMLAnchorElement, url: string): void {
  link.href = url;
  link.target = '_blank';
  link.rel = 'noreferrer';
  link.addEventListener('click', event => {
    event.preventDefault();
    postToHost({ type: 'open-url', url });
  });
}

function renderRoutes(status: AapDemoStatus): void {
  clear(routes);
  if (!routes || status.routes.length === 0) {
    routes?.append(emptyMessage('No routes available.'));
    return;
  }
  for (const route of status.routes) {
    const row = document.createElement('div');
    row.className = 'list-row';
    const link = document.createElement('a');
    addExternalLink(link, route);
    link.textContent = route;
    row.append(link);
    routes.append(row);
  }
}

function renderCredentials(status: AapDemoStatus): void {
  clear(credentials);
  if (!credentials || status.credentials.length === 0) {
    credentials?.append(emptyMessage('No credentials available.'));
    return;
  }
  for (const credential of status.credentials) {
    const row = document.createElement('div');
    row.className = 'list-row';
    const label = document.createElement('span');
    label.textContent = `${credential.namespace} / ${credential.username}`;
    const password = document.createElement('code');
    password.textContent = '••••••••';
    const reveal = document.createElement('button');
    reveal.className = 'small';
    reveal.textContent = 'Show';
    reveal.addEventListener('click', () => {
      const visible = password.textContent === credential.password;
      password.textContent = visible ? '••••••••' : credential.password;
      reveal.textContent = visible ? 'Show' : 'Hide';
    });
    const copy = document.createElement('button');
    copy.className = 'small';
    copy.textContent = 'Copy';
    copy.addEventListener('click', async () => {
      await navigator.clipboard?.writeText(credential.password);
      copy.textContent = 'Copied';
      window.setTimeout(() => { copy.textContent = 'Copy'; }, 1200);
    });
    const value = document.createElement('span');
    value.append(password, reveal, copy);
    row.append(label, value);
    credentials.append(row);
  }
}

function renderAddons(status: AapDemoStatus): void {
  clear(addonActions);
  if (!addonActions || status.addons.length === 0) {
    addonActions?.append(emptyMessage('No add-on actions available.'));
    return;
  }
  for (const addon of sortAddons(status.addons)) {
    const presentation = getAddonTogglePresentation(addon.name, addon.state);
    if (presentation) {
      const control = document.createElement('div');
      control.className = 'addon-control';
      const button = document.createElement('button');
      button.className = presentation.className;
      button.textContent = presentation.label;
      button.setAttribute('aria-label', presentation.ariaLabel);
      button.addEventListener('click', () => {
        button.disabled = true;
        button.textContent = `${presentation.label}...`;
        postToHost({ type: 'addon', action: presentation.action, addon: addon.name });
      });
      control.append(button);
      addonActions.append(control);
    }
  }
  if (!addonActions.childElementCount) addonActions.append(emptyMessage('No add-on actions available.'));
}

function renderStatus(status: AapDemoStatus): void {
  const state = formatState(status.cluster.state);
  if (statusState) statusState.textContent = state;
  if (statusDot) statusDot.className = `status-dot ${status.cluster.state}`;
  if (statusSummary) {
    const clusterName = status.cluster.name ? ` (${status.cluster.name})` : '';
    statusSummary.textContent = `${status.infra ?? 'Infrastructure unknown'}${clusterName}`;
  }
  if (lastUpdated) lastUpdated.textContent = `Updated ${new Date().toLocaleTimeString()}`;
  if (infra) infra.textContent = `Infrastructure: ${status.infra ?? 'unknown'}`;
  if (kubeconfig) kubeconfig.textContent = `Kubeconfig: ${status.kubeconfig ?? 'unknown'}`;
  if (toolVersion) toolVersion.textContent = `CLI: ${status.toolVersion ?? 'unknown'}`;
  renderRoutes(status);
  renderCredentials(status);
  renderAddons(status);
}

function renderPrerequisites(prerequisites: PrerequisiteStatus): void {
  clear(prerequisiteList);
  if (!prerequisiteList) return;
  const checks = [
    {
      label: 'OpenShift Local (CRC)',
      valid: prerequisites.crc.available,
      detail: prerequisites.crc.path ?? 'Set aap-demo.crcPath in settings',
    },
    {
      label: 'Pull secret',
      valid: prerequisites.pullSecret.exists,
      detail: prerequisites.pullSecret.path ?? 'Set aap-demo.pullSecretPath in settings',
    },
    {
      label: 'Memory',
      valid: prerequisites.memory.valid,
      detail: `${prerequisites.memory.value} MiB (minimum ${prerequisites.memory.minimum} MiB)`,
    },
  ];
  for (const check of checks) {
    const row = document.createElement('div');
    row.className = `prerequisite ${check.valid ? 'ready' : 'failed'}`;
    const label = document.createElement('strong');
    label.textContent = `${check.valid ? '✓' : '!'} ${check.label}`;
    const detail = document.createElement('span');
    detail.className = 'muted';
    detail.textContent = check.detail;
    row.append(label, detail);
    prerequisiteList.append(row);
  }
}

for (const button of document.querySelectorAll<HTMLButtonElement>('[data-action]')) {
  button.addEventListener('click', () => {
    const action = button.dataset.action;
    if (action) postAction(action);
  });
}

idleToggle?.addEventListener('click', () => {
  postAction('idle', idleState);
  idleState = !idleState;
  idleToggle.textContent = idleState ? 'Set idle' : 'Wake AAP';
});

window.addEventListener('message', event => {
  const message = unwrapDashboardMessage(event.data) as DashboardStatusMessage | DashboardPrerequisitesMessage | DashboardCommandMessage;
  if (!message || typeof message !== 'object' || typeof message.type !== 'string') return;
  if (message.type === 'prerequisites') {
    renderPrerequisites(message.prerequisites);
    return;
  }
  if (message.type === 'status') {
    renderStatus(message.status);
    return;
  }
  if (message.type === 'command-output') {
    appendOutput(message.text ?? '');
    return;
  }
  if (message.type === 'command-result' || message.type === 'addon-result') {
    writeOutput([message.stdout, message.stderr].filter(Boolean).join('\n'));
    if (statusSummary) statusSummary.textContent = `${formatState(message.action ?? 'command')} completed`;
    return;
  }
  if (message.type === 'command-error') {
    writeOutput(message.message ?? 'Command failed.');
    if (statusDot) statusDot.className = 'status-dot error';
    if (statusSummary) statusSummary.textContent = message.message ?? 'Command failed.';
  }
});

if (desktopApi) {
  desktopApi.postMessage({ type: 'ready' });
} else {
  postToHost({ type: 'ready' });
}
