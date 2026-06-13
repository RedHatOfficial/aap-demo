# Bash completion for aap-demo
# Source this file or add to ~/.bash_completion.d/

_aap_demo() {
    local cur prev commands options infra_types
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    commands="deploy deploy-all deploy-operator deploy-aap status clean destroy stop repair setup create watch update config redeploy redeploy-all redhat-status rh-status kubeconfig help"
    options="--infra --kubeconfig --context --ansible"
    infra_types="minc vm lab"

    # Handle option value completion
    case "$prev" in
        --infra|--infra=)
            COMPREPLY=( $(compgen -W "$infra_types" -- "$cur") )
            return 0
            ;;
        --context|--context=)
            # Complete with available kubectl contexts
            local contexts
            contexts=$(kubectl config get-contexts -o name 2>/dev/null)
            COMPREPLY=( $(compgen -W "$contexts" -- "$cur") )
            return 0
            ;;
    esac

    # Handle --infra= and --context= inline completion
    if [[ "$cur" == --infra=* ]]; then
        local prefix="${cur%%=*}="
        local value="${cur#*=}"
        COMPREPLY=( $(compgen -W "$infra_types" -- "$value") )
        COMPREPLY=( "${COMPREPLY[@]/#/$prefix}" )
        return 0
    fi

    if [[ "$cur" == --context=* ]]; then
        local prefix="${cur%%=*}="
        local value="${cur#*=}"
        local contexts
        contexts=$(kubectl config get-contexts -o name 2>/dev/null)
        COMPREPLY=( $(compgen -W "$contexts" -- "$value") )
        COMPREPLY=( "${COMPREPLY[@]/#/$prefix}" )
        return 0
    fi

    # Complete options if starting with --
    if [[ "$cur" == --* ]]; then
        COMPREPLY=( $(compgen -W "$options" -- "$cur") )
        return 0
    fi

    # Complete commands
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    return 0
}

complete -F _aap_demo aap-demo
complete -F _aap_demo aap-demo.sh
