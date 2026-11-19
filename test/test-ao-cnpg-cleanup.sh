#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../addons/ao/lib/postgres-storage.sh
source "${REPO_ROOT}/addons/ao/lib/postgres-storage.sh"

CLUSTER_PRESENT=1
FOREIGN_DATABASE=""
FAIL_DATABASE=""
DELETED=()

kubectl() {
  case "$*" in
    "get crd clusters.postgresql.cnpg.io"*) printf 'crd/clusters\n' ;;
    "get clusters.postgresql.cnpg.io orchestrator-postgres"*)
      if [ "$CLUSTER_PRESENT" -eq 1 ]; then printf 'cluster/orchestrator-postgres\n'; fi
      ;;
    "delete clusters.postgresql.cnpg.io orchestrator-postgres"*) CLUSTER_PRESENT=0 ;;
    "get crd databases.postgresql.cnpg.io"*) printf 'crd/databases\n' ;;
    "get database "*)
      local database="${3:-}"
      [ "$database" = "$FAIL_DATABASE" ] && return 1
      if [ "$database" = "$FOREIGN_DATABASE" ]; then printf 'other-cluster\n'; else printf 'orchestrator-postgres\n'; fi
      ;;
    "delete database "*) DELETED+=("$3") ;;
    "delete pvc orchestrator-postgres-1"*) ;;
    *)
      echo "unexpected kubectl call: $*" >&2
      return 1
      ;;
  esac
}

ao_remove_cnpg_storage automation-orchestrator orchestrator-postgres
[ "${DELETED[*]}" = "orchestrator temporal temporal-visibility" ]
echo 'PASS: CNPG cleanup deletes only the owned AO databases'

DELETED=()
CLUSTER_PRESENT=1
FOREIGN_DATABASE=temporal
if ao_remove_cnpg_storage automation-orchestrator orchestrator-postgres 2>/dev/null; then
  echo 'FAIL: CNPG cleanup accepted a database owned by another cluster' >&2
  exit 1
fi
[ "${DELETED[*]}" = "orchestrator" ]
echo 'PASS: CNPG cleanup stops on an unrelated database'

DELETED=()
CLUSTER_PRESENT=1
FOREIGN_DATABASE=''
FAIL_DATABASE=temporal
if ao_remove_cnpg_storage automation-orchestrator orchestrator-postgres 2>/dev/null; then
  echo 'FAIL: CNPG cleanup ignored a database lookup failure' >&2
  exit 1
fi
[ "${DELETED[*]}" = "orchestrator" ]
echo 'PASS: CNPG cleanup stops on a database lookup failure'
