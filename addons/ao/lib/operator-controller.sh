#!/usr/bin/env bash

AO_OPERATOR_NAME="${AO_OPERATOR_NAME:-automation-orchestrator-operator}"
AO_OPERATOR_DEFAULT_DEPLOYMENT="${AO_OPERATOR_DEFAULT_DEPLOYMENT:-automation-orchestrator-operator-controller-manager}"

_ao_operator_controller_namespaces() {
  local _namespace="$1" _olm_namespace="${2:-}" _extra_namespace="${3:-}" _ns _seen=""
  for _ns in "$_olm_namespace" "$_namespace" "$_extra_namespace" "${AO_OPERATOR_CONTROLLER_NAMESPACE:-}" "openshift-operators"; do
    [ -n "$_ns" ] || continue
    case " ${_seen} " in
      *" ${_ns} "*) continue ;;
    esac
    _seen="${_seen} ${_ns}"
    printf '%s\n' "$_ns"
  done
}

_ao_operator_labeled_deployment() {
  local _namespace="$1"
  kubectl get deployment -n "$_namespace" -l olm.owner.kind=ClusterServiceVersion \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.olm\.owner}{"\n"}{end}' \
    2>/dev/null \
    | awk -F'|' -v operator="${AO_OPERATOR_NAME}" \
      '$1 != "" && $2 ~ "^" operator "\\." { print $1; exit }'
}

ao_operator_controller_namespace() {
  local _namespace="$1" _olm_namespace="${2:-}" _extra_namespace="${3:-}" _ns
  while IFS= read -r _ns; do
    if kubectl get deployment "${AO_OPERATOR_DEFAULT_DEPLOYMENT}" -n "$_ns" >/dev/null 2>&1; then
      echo "$_ns"
      return 0
    fi
  done < <(_ao_operator_controller_namespaces "$_namespace" "$_olm_namespace" "$_extra_namespace")

  while IFS= read -r _ns; do
    if [ -n "$(_ao_operator_labeled_deployment "$_ns")" ]; then
      echo "$_ns"
      return 0
    fi
  done < <(_ao_operator_controller_namespaces "$_namespace" "$_olm_namespace" "$_extra_namespace")

  echo "${_olm_namespace:-$_namespace}"
}

ao_operator_controller_deployment() {
  local _namespace="$1" _olm_namespace="${2:-}" _extra_namespace="${3:-}" _ns _deployment
  while IFS= read -r _ns; do
    if kubectl get deployment "${AO_OPERATOR_DEFAULT_DEPLOYMENT}" -n "$_ns" >/dev/null 2>&1; then
      echo "${AO_OPERATOR_DEFAULT_DEPLOYMENT}"
      return 0
    fi
  done < <(_ao_operator_controller_namespaces "$_namespace" "$_olm_namespace" "$_extra_namespace")

  while IFS= read -r _ns; do
    _deployment="$(_ao_operator_labeled_deployment "$_ns")"
    if [ -n "$_deployment" ]; then
      echo "$_deployment"
      return 0
    fi
  done < <(_ao_operator_controller_namespaces "$_namespace" "$_olm_namespace" "$_extra_namespace")

  echo "${AO_OPERATOR_DEFAULT_DEPLOYMENT}"
}