#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/aap-demo-completion.bash
source "$ROOT_DIR/scripts/aap-demo-completion.bash"

COMP_WORDS=(aap-demo en)
COMP_CWORD=1
_aap_demo || true
[[ " ${COMPREPLY[*]-} " == *" enable "* ]] || {
  echo "FAIL: top-level completion missing enable" >&2
  exit 1
}

for command in enable disable; do
  COMP_WORDS=(aap-demo "$command" eda)
  COMP_CWORD=2
  _aap_demo || true
  [[ " ${COMPREPLY[*]-} " == *" eda-playground "* ]] || {
    echo "FAIL: $command completion missing eda-playground" >&2
    exit 1
  }
done

echo "PASS: EDA Playground Bash completion"
