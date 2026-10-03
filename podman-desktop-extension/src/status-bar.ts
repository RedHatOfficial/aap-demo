import type { AapDemoStatus } from './status-parser';

export function formatStatusBarText(status: AapDemoStatus): string {
  const state = status.cluster.state.replace('-', ' ').replace(/\b\w/g, character => character.toUpperCase());
  const clusterName = status.cluster.name ? ` (${status.cluster.name})` : '';
  return `AAP Demo: ${state}${clusterName}`;
}
