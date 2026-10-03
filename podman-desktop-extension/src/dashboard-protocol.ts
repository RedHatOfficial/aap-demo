import type { AddonAction, AapDemoAction } from './aap-demo-service';

const supportedActions = new Set<AapDemoAction>([
  'create',
  'deploy',
  'destroy',
  'status',
  'idle',
  'diagnose',
]);

export type DashboardMessage =
  | { type: 'ready' }
  | { type: 'run'; action: AapDemoAction; idleState?: boolean }
  | { type: 'addon'; action: AddonAction; addon: string }
  | { type: 'open-url'; url: string };

function isSafeExternalUrl(url: unknown): url is string {
  if (typeof url !== 'string') return false;
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  } catch {
    return false;
  }
}

export function unwrapDashboardMessage(message: unknown): unknown {
  let current = message;
  for (let depth = 0; depth < 4; depth += 1) {
    if (typeof current === 'string') {
      try {
        current = JSON.parse(current) as unknown;
      } catch {
        return current;
      }
      continue;
    }

    if (typeof current !== 'object' || current === null) return current;
    const wrapped = current as { data?: unknown; message?: unknown; payload?: unknown };
    if ('message' in wrapped) {
      current = wrapped.message;
      continue;
    }
    if ('data' in wrapped) {
      current = wrapped.data;
      continue;
    }
    if ('payload' in wrapped) {
      current = wrapped.payload;
      continue;
    }
    return current;
  }
  return current;
}

export function isDashboardMessage(message: unknown): message is DashboardMessage {
  if (typeof message !== 'object' || message === null) return false;
  const candidate = message as Partial<DashboardMessage>;
  if (candidate.type === 'ready') return true;
  if (candidate.type === 'run') {
    return supportedActions.has(candidate.action as AapDemoAction);
  }
  if (candidate.type === 'open-url') {
    return isSafeExternalUrl(candidate.url);
  }
  return (
    candidate.type === 'addon' &&
    (candidate.action === 'enable' || candidate.action === 'disable') &&
    typeof candidate.addon === 'string' &&
    candidate.addon.length > 0
  );
}
