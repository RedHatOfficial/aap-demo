# Bash completion for aap-demo.
# Installed by install.sh into ~/.local/share/bash-completion/completions/aap-demo.

_aap_demo_complete_words() {
  local words="$1"
  COMPREPLY=($(compgen -W "$words" -- "$cur"))
}

_aap_demo_complete_files() {
  COMPREPLY=($(compgen -f -- "$cur"))
  compopt -o filenames 2>/dev/null || true
}

_aap_demo() {
  local cur prev command subcommand
  local commands addons global_options

  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"
  command="${COMP_WORDS[1]:-}"
  subcommand="${COMP_WORDS[2]:-}"

  commands="create deploy deploy-all status system-info dashboard watch clean maintenance credentials destroy start restart stop service repair trust-ca setup ssh kubeconfig enable disable fleet keycloak wire idle preflight diagnose must-gather config redeploy redeploy-all redhat-status rh-status update v2 version help"
  addons="fleet mcp-server ao ao-pr-testing ollama setup-pah portal portal-operator apme-eap keycloak product-demos product-demo-satellite opa local-cache satellite-manifest lightspeed"
  global_options="--kubeconfig --context --branch --backend --no-import --json --redact --output --no-open --full-demo --satellite --show-secrets --ai --reset --skip-cache --force --refresh-catalog --purge-data --purge-creds --help --version"

  case "$prev" in
    --kubeconfig | --output)
      _aap_demo_complete_files
      return 0
      ;;
    --context)
      local contexts
      contexts=$(kubectl config get-contexts -o name 2>/dev/null)
      _aap_demo_complete_words "$contexts"
      return 0
      ;;
    --branch)
      local branches
      branches=$(git branch --format='%(refname:short)' 2>/dev/null)
      _aap_demo_complete_words "$branches"
      return 0
      ;;
    --image)
      if [[ "$cur" == */* || "$cur" == .* || "$cur" == ~* ]]; then
        _aap_demo_complete_files
      else
        _aap_demo_complete_words "rhel9 rhel10"
      fi
      return 0
      ;;
  esac

  case "$cur" in
    --kubeconfig=* | --output=*)
      local option_prefix="${cur%%=*}="
      local option_value="${cur#*=}"
      cur="$option_value"
      _aap_demo_complete_files
      COMPREPLY=("${COMPREPLY[@]/#/$option_prefix}")
      return 0
      ;;
    --context=*)
      local context_prefix="${cur%%=*}="
      local context_value="${cur#*=}"
      local contexts
      contexts=$(kubectl config get-contexts -o name 2>/dev/null)
      cur="$context_value"
      _aap_demo_complete_words "$contexts"
      COMPREPLY=("${COMPREPLY[@]/#/$context_prefix}")
      return 0
      ;;
    --branch=*)
      local branch_prefix="${cur%%=*}="
      local branch_value="${cur#*=}"
      local branches
      branches=$(git branch --format='%(refname:short)' 2>/dev/null)
      cur="$branch_value"
      _aap_demo_complete_words "$branches"
      COMPREPLY=("${COMPREPLY[@]/#/$branch_prefix}")
      return 0
      ;;
    --image=*)
      local image_prefix="${cur%%=*}="
      local image_value="${cur#*=}"
      cur="$image_value"
      if [[ "$cur" == */* || "$cur" == .* || "$cur" == ~* ]]; then
        _aap_demo_complete_files
      else
        _aap_demo_complete_words "rhel9 rhel10"
      fi
      COMPREPLY=("${COMPREPLY[@]/#/$image_prefix}")
      return 0
      ;;
  esac

  if [ "$COMP_CWORD" -eq 1 ]; then
    if [[ "$cur" == -* ]]; then
      _aap_demo_complete_words "$global_options"
    else
      _aap_demo_complete_words "$commands"
    fi
    return 0
  fi

  case "$command" in
    create)
      _aap_demo_complete_words "--full-demo --no-open"
      ;;
    status)
      _aap_demo_complete_words "--json --show-secrets"
      ;;
    system-info)
      _aap_demo_complete_words "--json --redact --output"
      ;;
    dashboard)
      _aap_demo_complete_words "--no-open"
      ;;
    destroy)
      _aap_demo_complete_words "--reset --skip-cache"
      ;;
    maintenance)
      _aap_demo_complete_words "uninstall --apply"
      ;;
    credentials)
      if [ "$COMP_CWORD" -eq 2 ]; then
        _aap_demo_complete_words "keepalive"
      elif [ "$subcommand" = keepalive ]; then
        _aap_demo_complete_words "setup enable status disable run"
      fi
      ;;
    service)
      if [ "$COMP_CWORD" -eq 2 ]; then
        _aap_demo_complete_words "install retention status backups backup disable"
      elif [ "$subcommand" = install ]; then
        _aap_demo_complete_words "--keep --force-stop --stop-timeout"
      fi
      ;;
    idle)
      _aap_demo_complete_words "true false"
      ;;
    diagnose)
      _aap_demo_complete_words "--ai"
      ;;
    update)
      _aap_demo_complete_words "--branch"
      ;;
    enable)
      if [ "$COMP_CWORD" -eq 2 ]; then
        _aap_demo_complete_words "$addons"
      elif [ "$subcommand" = local-cache ]; then
        _aap_demo_complete_words "save load clear"
      elif [ "$subcommand" = fleet ]; then
        _aap_demo_complete_words "--force --refresh-catalog"
      fi
      ;;
    disable)
      if [ "$COMP_CWORD" -eq 2 ]; then
        _aap_demo_complete_words "$addons"
      else
        _aap_demo_complete_words "--purge-data --purge-creds"
      fi
      ;;
    fleet)
      if [ "$COMP_CWORD" -eq 2 ]; then
        _aap_demo_complete_words "auth add register rhc-connect start ssh list remove destroy"
      else
        case "$subcommand" in
          auth)
            _aap_demo_complete_words "configure status reset"
            ;;
          add)
            _aap_demo_complete_words "--image rhel9 rhel10"
            ;;
        esac
      fi
      ;;
    *)
      if [[ "$cur" == -* ]]; then
        _aap_demo_complete_words "$global_options"
      fi
      ;;
  esac
  return 0
}

complete -F _aap_demo aap-demo
complete -F _aap_demo aap-demo.sh
