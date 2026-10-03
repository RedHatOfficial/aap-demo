import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { getAddonTogglePresentation, sortAddons } from '../src/webview/addon-ui';

const dashboardHtml = readFileSync(resolve(__dirname, '../src/webview/index.html'), 'utf8');

describe('getAddonTogglePresentation', () => {
  it('uses a green enabled toggle that disables the add-on when clicked', () => {
    expect(getAddonTogglePresentation('fleet', 'enabled')).toEqual({
      className: 'addon-toggle enabled',
      action: 'disable',
      label: 'fleet',
      ariaLabel: 'Disable fleet',
    });
  });

  it('uses a red disabled toggle that enables the add-on when clicked', () => {
    expect(getAddonTogglePresentation('fleet', 'disabled')).toEqual({
      className: 'addon-toggle disabled',
      action: 'enable',
      label: 'fleet',
      ariaLabel: 'Enable fleet',
    });
  });

  it('does not offer a toggle for an unknown state', () => {
    expect(getAddonTogglePresentation('fleet', 'unknown')).toBeUndefined();
  });

  it('sorts add-ons alphabetically without mutating the status array', () => {
    const addons = [{ name: 'portal' }, { name: 'ao' }, { name: 'fleet' }];

    expect(sortAddons(addons).map(addon => addon.name)).toEqual(['ao', 'fleet', 'portal']);
    expect(addons.map(addon => addon.name)).toEqual(['portal', 'ao', 'fleet']);
  });

  it('labels the section and explains the toggle colors', () => {
    expect(dashboardHtml).toContain('<h2>Addons</h2>');
    expect(dashboardHtml).toContain('green means enabled and grey means disabled');
    expect(dashboardHtml).not.toContain('Add-on actions');
  });

  it('keeps prerequisites inside the Status card', () => {
    const statusStart = dashboardHtml.indexOf('<div class="status" id="status">');
    const statusEnd = dashboardHtml.indexOf('<div class="actions">', statusStart);

    expect(dashboardHtml.slice(statusStart, statusEnd)).toContain('<h2>Status</h2>');
    expect(dashboardHtml.slice(statusStart, statusEnd)).toContain('id="prerequisite-list"');
    expect(dashboardHtml).not.toContain('<h3>Prerequisites</h3>');
    expect(dashboardHtml).not.toContain('<section class="card" id="prerequisites">');
  });
});
