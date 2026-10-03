export type AddonToggleState = 'enabled' | 'disabled' | 'unknown';
export type AddonToggleAction = 'enable' | 'disable';

export interface AddonTogglePresentation {
  className: string;
  action: AddonToggleAction;
  label: string;
  ariaLabel: string;
}

export function sortAddons<T extends { name: string }>(addons: T[]): T[] {
  return [...addons].sort((left, right) => left.name.localeCompare(right.name));
}

export function getAddonTogglePresentation(
  name: string,
  state: AddonToggleState,
): AddonTogglePresentation | undefined {
  if (state === 'enabled') {
    return {
      className: 'addon-toggle enabled',
      action: 'disable',
      label: name,
      ariaLabel: `Disable ${name}`,
    };
  }
  if (state === 'disabled') {
    return {
      className: 'addon-toggle disabled',
      action: 'enable',
      label: name,
      ariaLabel: `Enable ${name}`,
    };
  }
  return undefined;
}
