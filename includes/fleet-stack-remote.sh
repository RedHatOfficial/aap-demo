#!/usr/bin/env bash

# Replace only our block; reject malformed markers instead of losing local edits.
fleet_stack_replace_block() {
  local path="$1" content="$2" temp
  temp=$(mktemp "${path}.aap-demo.XXXXXX") || return 1
  if ! awk '
    $0 == "# BEGIN AAP-DEMO STACK" { if (inside || seen++) exit 1; inside=1; next }
    $0 == "# END AAP-DEMO STACK" { if (!inside) exit 1; inside=0; next }
    !inside { print }
    END { if (inside) exit 1 }
  ' "$path" >"$temp"; then
    rm -f "$temp"
    printf 'Malformed AAP-DEMO block in %s\n' "$path" >&2
    return 1
  fi
  printf '# BEGIN AAP-DEMO STACK\n%s\n# END AAP-DEMO STACK\n' "$content" >>"$temp"
  chmod --reference="$path" "$temp" || { rm -f "$temp"; return 1; }
  chown --reference="$path" "$temp" || { rm -f "$temp"; return 1; }
  # /etc/hosts may be a bind mount, so retain the original inode.
  cat "$temp" >"$path" || { rm -f "$temp"; return 1; }
  rm -f "$temp"
}

fleet_stack_apply() {
  local path=/home/admin/.ssh config
  # Refuse unmanaged aliases that would shadow the generated hosts entries.
  local unmanaged names
  unmanaged=$(awk '/^# BEGIN AAP-DEMO STACK$/{skip=1;next} /^# END AAP-DEMO STACK$/{skip=0;next} !skip' /etc/hosts)
  names=$(printf '%s\n' "$stack_hosts" | awk '!/^#/ {for(i=2;i<=NF;i++) print $i}')
  if ! awk -v names="$names" '
    BEGIN {split(names, list, "\n"); for(i in list) managed[tolower(list[i])]=1}
    {sub(/#.*/, ""); for(i=2;i<=NF;i++) if(tolower($i) in managed) {
      print "Unmanaged /etc/hosts alias conflicts with stack: " $i >"/dev/stderr"; bad=1
    }}
    END {exit bad}
  ' <<<"$unmanaged"; then return 1; fi
  fleet_stack_replace_block /etc/hosts "$stack_hosts" || return 1
  fleet_stack_replace_block "$path/authorized_keys" "$stack_keys" || return 1
  printf '%s\n' "$stack_config" >"$path/aap-demo-config"
  printf '%s\n' "$stack_known_hosts" >"$path/aap-demo-known_hosts"
  touch "$path/config"
  config=$(cat "$path/config")
  # Include first so managed aliases take precedence over a user's Host * defaults.
  if ! grep -Fxq 'Include ~/.ssh/aap-demo-config' "$path/config"; then
    printf 'Include ~/.ssh/aap-demo-config\n%s\n' "$config" >"$path/config"
  fi
  chown admin:admin "$path"/{authorized_keys,config,aap-demo-config,aap-demo-known_hosts}
  chmod 600 "$path"/{authorized_keys,config,aap-demo-config,aap-demo-known_hosts}
  if command -v restorecon >/dev/null; then restorecon -R "$path" /etc/hosts; fi
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  set -euo pipefail
  fleet_stack_apply
fi
