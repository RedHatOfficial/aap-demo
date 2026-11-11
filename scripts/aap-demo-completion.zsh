#!/usr/bin/env zsh
#compdef aap-demo aap-demo.sh
# Zsh completion for aap-demo

_aap_demo() {
  local -a commands options

  options=(
    '--infra=[Infrastructure type (minc, vm, lab)]:infra type:(minc vm lab)'
    '--kubeconfig=[Path to kubeconfig file]:kubeconfig file:_files'
    '--context=[kubectl context to use]:context:->contexts'
    '--ansible[Use Ansible playbook]'
    '--apply[Apply maintenance cleanup or uninstall]'
    '--full-demo[Create the complete AAP local demo environment]'
    '--show-secrets[Reveal credentials for interactive status]'
  )

  commands=(
    # All infrastructure types
    'deploy:Deploy AAP (operator + CR)'
    'deploy-all:Deploy AAP (alias for deploy)'
    'status:Show cluster and AAP status'
    'start:Resume demo or restore the latest service-managed backup'
    'restart:Save state and restart the demo'
    'service:Manage shutdown backups and boot restore'
    'clean:Remove AAP deployment (keeps cluster)'
    'maintenance:Clean safe VM data or fully uninstall aap-demo'
    'credentials:Manage encrypted credentials and token keepalive'
    'watch:Watch AAP deployment status'
    'redeploy:Clean and redeploy AAP'
    'redhat-status:Check Red Hat registry status'
    'rh-status:Check Red Hat registry status (alias)'
    'config:Configure aap-demo settings'
    'update:Pull latest code and reinstall'
    'help:Show help'
    # MINC only
    'create:Create cluster; use --full-demo for the complete demo'
    'destroy:Delete entire MINC cluster (MINC)'
    'stop:Stop MINC cluster gracefully (MINC)'
    'repair:Repair MINC after podman crash (MINC)'
    'setup:Run setup only - storage, coredns (MINC)'
    'kubeconfig:Sync MINC kubeconfig (MINC)'
    'redeploy-all:Destroy cluster and redeploy fresh (MINC)'
    'keycloak:Configure local Keycloak OIDC consumers'
  )

  if (( CURRENT == 3 )) && [[ "${words[2]}" == "maintenance" ]]; then
    _values 'maintenance action' \
      'uninstall[Preview full environment removal]' \
      '--apply[Apply the selected maintenance action]'
    return
  fi
  if [[ "${words[2]}" == "service" ]]; then
    _values 'service action' install retention status backups backup disable --keep --force-stop --stop-timeout
    return
  fi

  case "$state" in
    contexts)
      local -a contexts
      contexts=(${(f)"$(kubectl config get-contexts -o name 2>/dev/null)"})
      _describe -t contexts 'kubectl context' contexts
      ;;
    *)
      _arguments -C $options \
        ':command:->command' && return 0

      case "$state" in
        command)
          _describe -t commands 'commands' commands
          ;;
      esac
      ;;
  esac
}

_aap_demo "$@"
