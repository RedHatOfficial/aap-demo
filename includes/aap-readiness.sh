#!/usr/bin/env bash

# Return success only for a terminal, non-failed AAP condition state.
#
# AAP 2.7 can report Successful=False with reason=Successful while its
# Running=True condition indicates that reconciliation has completed. Running
# alone is not terminal: it is also present while workloads are still starting.
aap_condition_is_complete() {
  local successful="${1:-}"
  local running="${2:-}"
  local successful_reason="${3:-}"
  local failure="${4:-}"

  [ "$failure" != "True" ] || return 1
  [ "$successful" = "True" ] && return 0

  [ "$successful" = "False" ] \
    && [ "$running" = "True" ] \
    && [ "$successful_reason" = "Successful" ]
}
