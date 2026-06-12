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
    )

    commands=(
        # All infrastructure types
        'deploy:Deploy AAP (operator + CR)'
        'deploy-all:Deploy AAP (alias for deploy)'
        'deploy-operator:Deploy operator only, skip AAP CR'
        'deploy-aap:Apply AAP CR only (assumes operator installed)'
        'status:Show cluster and AAP status'
        'clean:Remove AAP deployment (keeps cluster)'
        'watch:Watch AAP deployment status'
        'redeploy:Clean and redeploy AAP'
        'redhat-status:Check Red Hat registry status'
        'rh-status:Check Red Hat registry status (alias)'
        'config:Configure aap-demo settings'
        'update:Pull latest code and reinstall'
        'help:Show help'
        # MINC only
        'create:Create MINC cluster only (MINC)'
        'destroy:Delete entire MINC cluster (MINC)'
        'stop:Stop MINC cluster gracefully (MINC)'
        'start:Start stopped MINC cluster (MINC)'
        'repair:Repair MINC after podman crash (MINC)'
        'setup:Run setup only - storage, coredns, mkcert (MINC)'
        'kubeconfig:Sync MINC kubeconfig (MINC)'
        'redeploy-all:Destroy cluster and redeploy fresh (MINC)'
    )

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
