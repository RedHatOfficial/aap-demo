#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../includes/json-utils.sh
source "${repo_root}/includes/json-utils.sh"

payload='{"crcStatus":"Running","openshiftStatus":"Unreachable","diskUse":25,"diskSize":100}'

if [ "$(aap_demo_json_value crcStatus "$payload")" != 'Running' ]; then
  echo '✗ JSON utility did not read a top-level value' >&2
  exit 1
fi
if [ "$(aap_demo_json_value openshiftStatus "$payload")" != 'Unreachable' ]; then
  echo '✗ JSON utility did not read the OpenShift status' >&2
  exit 1
fi
if [ "$(aap_demo_json_disk_percent "$payload")" != '25' ]; then
  echo '✗ JSON utility did not calculate disk percentage' >&2
  exit 1
fi

echo 'JSON utility checks passed'
