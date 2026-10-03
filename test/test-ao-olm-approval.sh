#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$(cat "${repo_root}/addons/ao/deploy.sh")"

if ! grep -q '^pending_installplans()' <<<"$script"; then
  echo '✗ AO install must have a shell-native pending InstallPlan helper' >&2
  exit 1
fi
if ! grep -q 'spec.approved' <<<"$script"; then
  echo '✗ AO install must inspect InstallPlan approval state' >&2
  exit 1
fi
if ! grep -q 'ResolutionFailed' <<<"$script"; then
  echo '✗ AO install must detect subscription resolution failures' >&2
  exit 1
fi

echo 'AO OLM approval checks passed'
